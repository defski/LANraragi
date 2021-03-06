package Shinobu;

# LANraragi File Watcher.
#  Uses inotify watches to keep track of filesystem happenings.
#  My main tasks are:
#
#    Tracking all files in the content folder and making sure they're sync'ed with the database
#    Automatically cleaning the temporary folder when it reaches a certain size
#

use strict;
use warnings;
use utf8;
use feature qw(say);
use Cwd;

use FindBin;
use Parallel::Loops;
use Sys::CpuAffinity;
use Storable qw(lock_store);
use Mojo::JSON qw(to_json);

#As this is a new process, reloading the LRR libs into INC is needed.
BEGIN { unshift @INC, "$FindBin::Bin/../lib"; }

use Mojolicious;
use File::ChangeNotify;
use File::Find;
use File::Basename;
use Encode;

use LANraragi::Utils::Database qw(invalidate_cache compute_id);
use LANraragi::Utils::TempFolder qw(get_temp clean_temp_partial);
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::Generic qw(is_archive);

use LANraragi::Model::Config;
use LANraragi::Model::Plugins;
use LANraragi::Utils::Plugins;    # Needed here since Shinobu doesn't inherit from the main LRR package
use LANraragi::Model::Search;     # idem

# Filemap hash, global to all subs and exposed to the server through serialization
my %filemap;

# Logger and Database objects
my $logger = get_logger( "Shinobu", "shinobu" );
my $redis  = LANraragi::Model::Config->get_redis;

#Subroutine for new and deleted files that takes inotify events
my $inotifysub = sub {
    my $e    = shift;
    my $name = $e->path;
    my $type = $e->type;
    $logger->debug("Received inotify event $type on $name");

    if ( $type eq "create" || $type eq "modify" ) {
        new_file_callback($name);
    }

    if ( $type eq "delete" ) {
        deleted_file_callback($name);
    }

};

sub initialize_from_new_process {

    my $userdir = LANraragi::Model::Config->get_userdir;

    $logger->info("Shinobu Background Worker started.");
    $logger->info( "Working dir is " . cwd );

    build_filemap();
    $logger->info("Adding watcher to content folder $userdir");

    # Add watcher to content directory
    my $contentwatcher = File::ChangeNotify->instantiate_watcher(
        directories     => [$userdir],
        filter          => qr/\.(?:zip|rar|7z|tar|tar\.gz|lzma|xz|cbz|cbr|pdf|epub|)$/,
        follow_symlinks => 1,
        exclude         => [ 'thumb', '.' ],                                              #excluded subdirs
    );

    my $class = ref($contentwatcher);
    $logger->debug("Watcher class is $class");

    # Add watcher to tempfolder
    my $tempwatcher = File::ChangeNotify->instantiate_watcher( directories => [ get_temp() ] );

    # manual event loop
    $logger->info("All done! Now dutifully watching your files. ");

    while (1) {

        # Check events on files
        for my $event ( $contentwatcher->new_events ) {
            $inotifysub->($event);
        }

        # Check the current temp folder size and clean it if necessary
        for my $event ( $tempwatcher->new_events ) {
            clean_temp_partial();
        }

        sleep 2;
    }
}

#Build the filemap hash from scratch. This acts as a masterlist of what's in the content directory.
#This computes IDs for all archives and henceforth is rather expensive !
sub build_filemap {

    $logger->info("Scanning content folder for changes...");

    # Delete previously serialized filemap
    unlink '.shinobu-filemap' || $logger->warn("Couldn't delete previous filemap data.");

    # Clear hash
    %filemap = ();
    my $dirname = LANraragi::Model::Config->get_userdir;
    my @files;

    # Get all files in content directory and subdirectories.
    find(
        {   wanted => sub {
                return if -d $_;    #Directories are excluded on the spot
                push @files, $_;    #Push files to array
            },
            no_chdir    => 1,
            follow_fast => 1
        },
        $dirname
    );

    # Now that we have all files, process them...with multithreading!
    my $numCpus = Sys::CpuAffinity::getNumCpus();
    my $pl      = Parallel::Loops->new($numCpus);
    $pl->share( \%filemap );

    $logger->debug("Number of available cores for processing: $numCpus");

    # Split the workload equally between all CPUs with an array of arrays
    my @sections;
    while (@files) {
        foreach ( 0 .. $numCpus - 1 ) {
            if (@files) {
                push @{ $sections[$_] }, shift @files;
            }
        }
    }

    $pl->foreach(
        \@sections,
        sub {
            # This sub "magically" executed in parallel forked child
            # processes
            foreach my $file (@$_) {
                add_to_filemap($file);
            }
        }
    );

    # Done, serialize filemap for main process to consume
    # The filemap hash has been modified into an object by Parallel::Loops...
    # It's better to make a clean hash copy and serialize that instead.
    my $copy = {%filemap};
    lock_store $copy, '.shinobu-filemap';
}

sub add_to_filemap {

    my ($file) = shift;

    if ( is_archive($file) ) {

        $logger->debug("Adding $file to Shinobu filemap.");

        #Freshly created files might not be complete yet.
        #We have to wait before doing any form of calculation.
        while (1) {
            last unless -e $file;    # Sanity check to avoid sticking in this loop if the file disappears
            last if open( my $handle, '<', $file );
            $logger->debug("Waiting for file to be openable");
            sleep(1);
        }

        # Wait for file to be more than 512 KBs or bailout after 5s and assume that file is smaller
        my $cnt = 0;
        while (1) {
            last if ( ( ( -s $file ) >= 512000 ) || $cnt >= 5 );
            $logger->debug("Waiting for file to be fully written");
            sleep(1);
            $cnt++;
        }

        #Compute the ID of the archive and add it to the hash
        my $id = "";
        eval { $id = compute_id($file); };

        if ($@) {
            $logger->error("Couldn't open $file for ID computation: $@");
            $logger->error("Giving up on adding it to the filemap.");
            return;
        }

        $logger->debug("Computed ID is $id.");

        #If the hash already exists, throw a warning about duplicates
        if ( exists( $filemap{$id} ) ) {

            if ( $file eq $filemap{$id} ) {
                $logger->debug(
                    "$file was logged again but is already in the filemap, duplicate inotify events? Cleaning cache just to make sure"
                );
                invalidate_cache();
            } else {
                $logger->warn( "$file is a duplicate of the existing file " . $filemap{$id} . ". You should delete it." );
            }
            return;
        } else {
            $filemap{$id} = $file;
        }

        # Filename sanity check
        if ( $redis->exists($id) ) {

            my $filecheck = $redis->hget( $id, "file" );

            #Update the real file path and title if they differ from the saved one
            #This is meant to always track the current filename for the OS.
            unless ( $file eq $filecheck ) {
                $logger->debug("File name discrepancy detected between DB and filesystem!");
                $logger->debug("Filesystem: $file");
                $logger->debug("Database: $filecheck");
                my ( $name, $path, $suffix ) = fileparse( $file, qr/\.[^.]*/ );
                $redis->hset( $id, "file", $file );
                $redis->hset( $id, "name", encode_utf8($name) );
                $redis->wait_all_responses;
                invalidate_cache();
            }
        } else {

            # Add to Redis if not present beforehand
            add_new_file( $id, $file );
            invalidate_cache();
        }
    }
}

# Only handle new files. As per the ChangeNotify doc, it
# "handles the addition of new subdirectories by adding them to the watch list"
sub new_file_callback {
    my $name = shift;

    unless ( -d $name ) {
        add_to_filemap($name);
    }
}

#Deleted files are simply dropped from the filemap.
#Deleted subdirectories trigger deleted events for every file deleted.
sub deleted_file_callback {
    my $name = shift;
    $logger->info("$name was deleted from the content folder!");

    unless ( -d $name ) {

        #Lookup the file in the filemap and prune it
        #As it's a lookup by value it looks kinda ugly...
        delete( $filemap{$_} ) foreach grep { $filemap{$_} eq $name } keys %filemap;

        # Serialize filemap for main process to consume
        my $copy = {%filemap};
        lock_store $copy, '.shinobu-filemap';
        invalidate_cache();
    }
}

sub add_new_file {

    my ( $id, $file ) = @_;
    $logger->info("Adding new file $file with ID $id");

    eval {
        LANraragi::Utils::Database::add_archive_to_redis( $id, $file, $redis );

        #AutoTagging using enabled plugins goes here!
        if ( LANraragi::Model::Config->enable_autotag ) {
            LANraragi::Model::Plugins::exec_enabled_plugins_on_file($id);
        }
    };

    if ($@) {
        $logger->error("Error while adding file: $@");
    }
}

__PACKAGE__->initialize_from_new_process unless caller;

1;
