#!/usr/bin/perl

use v5.10;
use strict;
use warnings;
use DBD::SQLite;
use DBI;
use Flickr::Upload;
use Data::Dumper;
use Digest::SHA1 ();
use lib::abs;
use File::Find;
use Getopt::Long;
use Image::ExifTool qw( :Public );
use Pod::Usage;

autoflush STDERR 1;
autoflush STDOUT 1;

my $dbh;
my @dirs;
my %changed_files;

# default options
my %options = (
    delete => 1, 
    recursive => 0,
);

get_options();

if ( $options{auth} ) {
    print_auth_token_info();
    exit;
}

connect_db();

my $api = Flickr::Upload->new( {
    key    => $options{key   },
    secret => $options{secret},
} );

my $processed = process_removed_and_changed_files() + process_new_files();

say 'Nothing to be done.' unless $processed;

##################################################################################

sub get_options {
    my $help;
    GetOptions (
        'help|?'       => \$help,
        'key=s'        => \$options{key},
        'secret=s'     => \$options{secret},
        auth           => \$options{auth},
        'auth_token=s' => \$options{auth_token},
         del           => \$options{delete},
        'public=i'     => \$options{is_public},
        'friend=i'     => \$options{is_friend},
        'family=i'     => \$options{is_family},
        'hidden=i'     => \$options{hidden},
        r              => \$options{recursive},
    ) or pod2usage( 2 );
    pod2usage(1) if $help;

    pod2usage( 'Bad options' )
        if grep { !defined } map { $options{ $_ } } qw( key secret );

    return if $options{auth};

    pod2usage( 'Bad options' ) unless $options{auth_token};

    pod2usage( 'No dirs in args' ) unless @ARGV;

    for my $dir ( @ARGV ) {
        unless ( -d $dir ) {
            warn "Directory $dir does not exist and will be skipped.\n";
            next;
        }

        push @dirs, $dir;
    }

    die 'No dirs found' unless @dirs;
}

# Copied from flick_upload of Flickr::Upload module. Thanx!
sub print_auth_token_info {
    my $ua = Flickr::Upload->new( { key => $options{key}, secret => $options{secret} } );
    $ua->env_proxy();

    sub get_frob {
        my ( $ua ) = shift;
     
        my $res = $ua->execute_method( 'flickr.auth.getFrob' );
        return undef unless defined $res and $res->{success};
     
        # FIXME: error checking, please. At least look for the node named 'frob'.
        return $res->{tree}{children}[1]{children}[0]{content};
    }

    sub get_token {
        my ( $ua, $frob ) = @_;
     
        my $res = $ua->execute_method( 'flickr.auth.getToken', { 'frob' => $frob } );
        return undef unless defined $res and $res->{success};
     
        # FIXME: error checking, please.
        return $res->{tree}{children}[1]{children}[1]{children}[0]{content};
    }
 
    # 1. get a frob
    my $frob = get_frob( $ua );
 
    # 2. get a url for the frob
    my $url = $ua->request_auth_url( 'delete', $frob );
 
    # 3. tell the user what to do with it
    say "1. Enter the following URL into your browser\n\n",
          "$url\n\n",
          "2. Follow the instructions on the web page\n",
          "3. Hit <Enter> when finished.\n";
     
    # 4. wait for enter.
    <>;
 
    # 5. Get the token from the frob
    my $auth_token = get_token( $ua, $frob );
    die 'Failed to get authentication token!' unless defined $auth_token;
     
    # 6. Tell the user what they won.
    say "Your authentication token for this application is\n\t\t$auth_token";
}

# Connects to local DB and creates it if nessessary
sub connect_db {
    $dbh = DBI->connect( 'dbi:SQLite:dbname=flickr.db' ) or die 'Can not connect to local DB';

    my $tables_ref = $dbh->table_info( undef, '%', 'files' )->fetchall_arrayref( {} );

    unless ( @$tables_ref ) {
        say 'Creating local photo DB...';
        $dbh->do( '
            CREATE TABLE files (
                path VARCHAR(300) NOT NULL PRIMARY KEY,
                size INT UNSIGNED NOT NULL,
                hash CHAR(40) NOT NULL,
                flickr_id CHAR(20) NOT NULL
            )
        ' ) or die 'Can not create photo table';
        say 'Created.'
    }

    return $dbh;
}

sub process_removed_and_changed_files {
    my $processed = 0;

    my $db_files_ref = $dbh->selectall_arrayref( 'SELECT * FROM files', { Slice => {} } );

    for my $file_ref ( @$db_files_ref ) {
        # Check if file is (or was) in one of the dirs
        unless ( grep { $file_ref->{path} =~ /^$_/ } @dirs ) {
            warn "File $file_ref->{path} is not in directories. Skipping...\n";
            next;
        }

        # Check if we should remove file remotely
        if ( $options{delete} && !-e $file_ref->{path}  ) {
            print "Found locally removed file $file_ref->{path}. Removing remotely...";
            ++$processed;
            if ( remove_file_from_flickr( $file_ref->{path}, $file_ref->{flickr_id} ) ) {
                say 'done.'
            }
            next;
        }

        next unless -w $file_ref->{path};

        # Check if file was changed
        if ( -s $file_ref->{path} != $file_ref->{size}
            || $file_ref->{hash} ne get_file_hash( $file_ref->{path} )
        ) {
            print "Found locally changed file $file_ref->{path}. Removing remotely...";
            ++$processed;
            if ( remove_file_from_flickr( $file_ref->{path}, $file_ref->{flickr_id} ) ) {
                say 'done.';
                $changed_files{ $file_ref->{path} } = 1;
            }
        }
    }

    return $processed;
}

sub remove_file_from_flickr {
    my ( $path, $id ) = @_;

    my $response = eval {
        $api->execute_method( 'flickr.photos.delete', { auth_token => $options{auth_token}, photo_id => $id } );
    };

    if ( $@ || $response->{error_code} ) {
        warn sprintf "failed: %s\n", $response->{error_message} // $response->{error_code};
        return 0;
    }

    $dbh->do( 'DELETE FROM files WHERE path = ?', undef, $path );

    return 1;
}

# Searches for a new files in dirs and uploads to flickr
sub process_new_files {
    my $processed = 0;

    if ( $options{recursive} ) {
        find( sub { check_and_upload_file( $File::Find::name, \$processed ) }, @dirs );
    }
    else {
        # no recurse
        for my $dir ( @dirs ) {
            check_and_upload_file( $_, \$processed ) for glob "$dir/*";
        }
    }

    return $processed;
}

# Checks if this file should be upload and uploads if nesessary.
sub check_and_upload_file {
    my ( $path, $processed_ref ) = @_;

    return if -d $path;

    return unless -s $path;

    return unless $path =~ /jpe?g$/i;

    # Check if file is already uploaded
    return if scalar $dbh->selectrow_array(
        'SELECT path FROM files WHERE path = ?', undef, $path
    );

    my $new = !exists $changed_files{ $path };

    printf 'Uploading %s file %s (%.1fMb)...', $new ? 'new' : 'changed',
        $path, ( -s $path ) / 1024 / 1024;

    ++$$processed_ref;

    say 'done.' if upload_file_to_flickr( $path );
}

sub upload_file_to_flickr {
    my ( $path ) = @_;

    my $tags = join( ' ', gen_tags( $path ) );

    print "(tags $tags)" || "(no tags)";

    my $id = $api->upload(
        photo      => $path,
        auth_token => $options{auth_token},
        tags       => $tags,
        map { $_ => $options{ $_ } }
            grep { defined $options{ $_ } }
            qw ( is_public is_friend is_family hidden ),
    ) or do {
        warn "failed!\n";
        return undef;
    };

    $dbh->do( '
        INSERT INTO files  ( path, size, hash, flickr_id )
                    VALUES (    ?,    ?,    ?,         ? )
        ', 
        undef,
        $path,
        -s $path,
        get_file_hash( $path ),
        $id,        
    ) or do {
        warn "Internal error while inserting in local DB\n";
        return undef;
    };

    return $id;
}

# Generates tags list for the photo
sub gen_tags {
    my ( $path ) = @_;

    my $info_ref = eval {
        ImageInfo( $path, { DateFormat => "%Y-%m-%d" } )
    } // {};

    my $date = $info_ref->{CreateDate}
            // $info_ref->{DateTimeOriginal}
            // $info_ref->{ModifyDate};

    if ( $@ || !$date ) {
        return ();
    };

    my ( $year ) = split /-/, $date;

    return $year, $date;
}

sub get_file_hash {
    my ( $path ) = @_;

    open my $fh, $path or die "Can not open file. $@";

    my $digest = Digest::SHA1->new->addfile( $fh )->hexdigest;

    close $fh;

    return $digest;
}

__END__
 
=head1 NAME
 
flickr_upload - Upload photos to C<flickr.com>
 
=head1 SYNOPSIS
 
flickr_upload.pl [--auth] --auth_token <auth_token>
    --key <key> --secret <secret> [--r <0|1>]
    [--del <0|1>] [--public <0|1>] [--friend <0|1>]
    [--family <0|1>] [--hidden <0|1>] 
    <directories...>
 
=head1 DESCRIPTION

This script uploads JPEG files to flickr.com account.
It maintains local photo DB to check for file changes of local photos directory.
Files removed locally can be removed from flickr.
Changed files will be reuploaded.
 
L<flickr_upload> may also be useful for generating authentication tokens
against other API keys/secrets (i.e. for embedding in scripts).
 
=head1 OPTIONS
 
=over 4
 
=item --auth
 
The C<--auth> flag will cause L<flickr_upload> to generate an
authentication token against it's API key and secret (or, if you want,
your own specific key and secret).  This process requires the caller
to have a browser handy so they can cut and paste a url. The resulting
token should be kept somewhere since it's necessary
for actually uploading images.
 
=item --auth_token <auth_token>
 
Authentication token. You B<must> get an authentication token using
C<--auth> before you can upload images.
 
=item --public <0|1>
 
Override the default C<is_public> access control. Optional.
 
=item --friend <0|1>
 
Override the default C<is_friend> access control. Optional.
 
=item --family <0|1>
 
Override the default C<is_family> access control. Optional.

=item --hidden <1|2>
 
Override the default C<hidden> option. Hidden files (2) will not be in search results. Optional.

=item --r <0|1>
 
Recurse into directories. Optional.

=item --del <0|1>
 
Remove locally deleted files from flickr. The default is not to delete. Optional.

=item --key <api_key>
 
=item --secret <secret>
 
Your own API key and secret. This is useful if you want to use
L<flickr_upload> in auth mode as a token generator. You need both C<key>
and C<secret>.
 
=item <directories...>
 
List of directories to upload files from.
 
=head1 AUTHOR
 
Alexander Nalobin, L<alexander@nalobin.ru>.
  
=cut