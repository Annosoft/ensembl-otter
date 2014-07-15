package Bio::Otter::Server::Config;
use strict;
use warnings;

use Try::Tiny;
use List::MoreUtils 'uniq';
# require YAML::Any; # sometimes (below), but it is a little slow

use Bio::Otter::SpeciesDat;
use Bio::Otter::SpeciesDat::Database;
use Bio::Otter::Version;


=head1 NAME

Bio::Otter::Server::Config - obtain config data for Otter Server

=head1 DESCRIPTION

This module contains only class methods.

=head1 CLASS METHODS

=head2 data_dir()

Return the default Otter Server config directory, as configured with
the webserver or from some "well known" central place.

This does not allow for per-developer configuration override.  See
also L</data_filename> which does.

=cut

sub data_dir {
    my ($pkg) = @_;

    my ($root, $src, $webtree) =
      ($ENV{'DOCUMENT_ROOT'}, '$DOCUMENT_ROOT', 1); # has first priority

    if (!defined $root) {
        # Let client scripts be given explicit config.  RT#398147
        #
        # It must contain the full tree (dev or live branch)
        # not just a root- or version- branch.
        ($root, $src, $webtree) =
          ($ENV{'ANACODE_SERVER_CONFIG'}, '$ANACODE_SERVER_CONFIG', 0);
    } else {
        warn '$ANACODE_SERVER_CONFIG ignored because $DOCUMENT_ROOT was set'
          if defined $ENV{'ANACODE_SERVER_CONFIG'};
    }

    if (!defined $root) {
        # For internal non-web machines, provide the central copy to
        # remove the need to pretend we have DOCUMENT_ROOT .
        #
        # Web machines shouldn't have a fallback, too magical.
        # (They don't have /software/ )
        ($root, $src, $webtree) =
          ("/nfs/anacode/WEBVM_docs.live/htdocs", # DUP also in team_tools pubweblish
           'fallback', 1)
          if -d '/software/anacode';
    }

    die "Cannot find data_dir via DOCUMENT_ROOT, ANACODE_SERVER_CONFIG or fallback"
      unless defined $root;

    my $data = $root;
    if ($webtree) {
        # Trim off the trailing /dir (usually htdocs)
        $data =~ s{/[^/]+$}{}
          or die "Unexpected DOCUMENT_ROOT format '$root' from $src";
        $data = join('/', $data, 'data', 'otter');
        $src .= " near root '$root'";
    }

    die "data_dir $data (from $src): not found"
      unless -d $data;

    my $vsn = Bio::Otter::Version->version;
    my @want = ("species.dat", "users.txt",
                "$vsn/otter_config", "$vsn/otter_styles.ini");
    my @lack = grep { ! -f "$data/$_" } @want;
    die "data_dir $data (from $src): lacks expected files (@lack)"
      if @lack;

    return $data;
}


=head mid_url_args()

Return a hashref of key-value items taken from C<$1> of URL
C<http://server:port/cgi-bin/otter([^/]*)/\d+/\w+>

This is empty in normal production use, and will be empty if the
pattern doesn't match (no errors raised).

In DEVEL mode servers it may be used to point L</data_filename>
elsewhere.  CGI escapes are %-decoded and the result is re-tainted.

=cut

sub mid_url_args {
    my ($pkg) = @_;
    my %out;
    my $retaint = substr("$0$^X",0,0); # CGI.pm 3.49 does this too

    if (!defined $ENV{REQUEST_URI}) {
        # Running outside the normal CGI environment, probably for
        # test & debug purposes.
        #
        # $ANACODE_SERVER_CONFIG could point at config
    } elsif ($ENV{REQUEST_URI} =~ m{^/cgi-bin/otter([^/]*)/\d+(_[^/]+)?/}) {
        # cf. webvm.git apps/50otter.conf ScriptAliasMatch
        # ^/cgi-bin/otter([^/]+)/(\d+(?:_[^/]+)?)/([^/]+)$
        my $mu = $1;
        foreach my $arg (split /;/, $mu) {
            if ($arg =~ m{^~([-a-z0-9]{1,16})$}) {
                # short case for a username, detainted
                $out{'~'} = $1;
            } elsif ($arg =~ m{^([-a-zA-Z0-9_.]+)=(.*)$}) {
                # regex is not intended to de-taint!
                my ($k, $v) = ($1, $2);
                foreach ($k, $v) {
                    s/%([0-9a-f]{2})/chr(hex($1))/eig;
                }
                $out{$k} = $v . $retaint;
            } else {
                warn "mid_url_args($arg): not understood";
            }
        }
    } else {
        warn "No mid_url_args: SCRIPT_NAME mismatch";
    }
    return \%out;
}


# Accept configuration from another user iff they exist and are a
# member of our primary group.
sub _dev_config {
    my ($pkg) = @_;
    my $developer = $pkg->mid_url_args->{'~'};
    return () unless defined $developer;

    my ($dev_home, $dev_group) = (getpwnam($developer))[7, 3];
    die "Developer config for $developer: unknown user" unless defined $dev_home;

    my $ok_group = $(;
    my ($gname, $gmemb) = (getgrgid( $ok_group ))[0, 3];
    my @ok_user = split / /, $gmemb;
    die "Developer config for $developer: not a member of group $gname"
      unless $dev_group == $ok_group || grep { $developer eq $_ } @ok_user;

    my $dir = "$dev_home/.otter/server-config";
    die "Developer config $dir: not a readable directory"
      unless -d $dir && -r _;

    return $dir;
}


=head2 data_filename($fn, $add_vsn)

Return the full pathname of Otter Server Config file C<$fn>, prefixed
with the current major version number if C<$add_vsn> is true.  In list
context, return also the description of the config source.

This method accepts (via L</mid_url_args> containing a C<~username>
element) files from a developer's local configuration, to ease the
process of testing new configuration.

It can return the name of a file which does not exist, or die failing
to obtain configuration.

=cut

sub data_filename {
    my ($pkg, $fn, $add_vsn) = @_;

    my $vsn = Bio::Otter::Version->version;
    $fn =~ s{^/*}{$vsn/} if $add_vsn;

    my $data_dir = $pkg->data_dir;
    my @out;

    # Possible override for testing config
    my $dev_cfg = $pkg->_dev_config;

    if (!defined $dev_cfg) {
        @out = ("$data_dir/$fn", 'default');
    } elsif (-f "$dev_cfg/species.dat" && -f "$dev_cfg/$vsn/otter_config") {
        @out = ("$dev_cfg/$fn", 'developer (full)');
    } else {
        # We have a partial override, e.g. checkout of a major version
        # branch.  This is needed for cherry-picking but interferes
        # with having neat developer config.
        #
        # Brush the mess under this small carpet.
        my ($want_vsn, $vsn_file) = $fn =~ m{^(\d{2,4})/(.+)$};
        ($want_vsn, $vsn_file) = (root => $fn) unless defined $want_vsn;
        my ($have_vsn, $cfg_branch) = try { __git_head($dev_cfg) }
          catch { die "Examining config from $dev_cfg: $_" };
        if ($have_vsn eq $want_vsn) {
            @out = ("$dev_cfg/$vsn_file",
                    "developer ($have_vsn from $cfg_branch)");
        } else {
            @out = ("$data_dir/$fn",
                    "default; developer checkout is $cfg_branch");
        }
    }
    return wantarray ? @out : $out[0];
}

sub __git_head {
    my ($dir) = @_;
    my $head_fn = "$dir/.git/HEAD";
    open my $fh, '<', $head_fn or die "$!";
    my $txt = <$fh>;
    chomp $txt;
    die "detached HEAD ($txt)" unless $txt =~ m{^ref: (\S+)$};
    my $branch = $1;
    my $vsn;
    if ($branch =~ m{^refs/heads/(root|\d+)$}) {
        # simple branch checkouts
        $vsn = $1;
    } elsif ($branch =~ m{^refs/heads/(?:\w+/)?(root|\d+)-}) {
        # recognisable developer branch
        $vsn = $1;
    } else {
        die "branch name '$branch' does not tell me (major version|root)";
    }
    return ($vsn, $branch);
}


=head2 databases()

Return a reference to the hash of C<database_key> to
L<Bio::Otter::SpeciesDat::Database> objects from the Otter Server
config directory (since v81).

=cut

sub databases {
    my ($pkg) = @_;
    require YAML::Any;
    my $fn = $pkg->data_filename('/databases.yaml');
    my ($h) = YAML::Any::LoadFile($fn);
    my $dbs = $h->{dbspec};
    die "No dbspec in $fn" unless $dbs;
    return Bio::Otter::SpeciesDat::Database->new_many_from_dbspec($dbs);
}


=head2 SpeciesDat()

Return a fresh instance of L<Bio::Otter::SpeciesDat> from the Otter
Server config directory.

=cut

sub SpeciesDat {
    my ($pkg) = @_;
    my $fn = $pkg->data_filename('/species.dat');
    return Bio::Otter::SpeciesDat->new($fn);
}


=head2 designations()

Return hashref of intended version designations, name to version
number.  Versions may be C<major> or C<major.minor>.

All versions of the code will return the same centrally configured
result, unless some config files are out of sync.

Pointers to clients in various places should match this hash, else
something needs updating.

This replaces the old version controlled F<dist/conf/track> file.

=cut

sub designations {
    my ($pkg) = @_;
    my $fn = $pkg->data_filename('designations.txt');
    return $pkg->_desig($fn);
}

sub _desig {
    my ($pkg, $fn) = @_;
    my %desig;
    open my $fh, '<', $fn
      or die "Error reading version designations $fn: $!";
    while (<$fh>) {
        next if /^\s+$|^#/;
        if (m{^(\S+)\s+(\d+(?:\.\d+)?(?:_\w+)?)$}) {
            $desig{$1} = $2;
        } else {
            warn "Skipped bad version designation $_"
        }
    }
    close $fh;
    return \%desig;
}


=head2 extant_versions()

Consulting L</designations>, return a list of (uniq and ascending)
major version numbers which should exist on the server.

=cut

sub extant_versions {
    my ($called) = @_;
    my $desig = $called->designations;
    my $desig_re = qr{^(\d{2,4})(?:\.\d+)?$};
    my @version = map {
        ## no critic (RegularExpressions::ProhibitCaptureWithoutTest)
        ($desig->{$_} =~ $desig_re
         ? $1 # <-- capture var in test.  Perlcritic bug?
         : die "Didn't understand desig($_ => $desig->{$_}) with $desig_re");
    } keys %$desig;
    @version = uniq(sort {$a <=> $b} @version);

    die unless wantarray;
    return @version;
}


=head2 users_hash()

Return a freshly loaded hash C<< ->{$user}{$dataset} = 1 >> from the
Otter Server config directory.

=cut

sub users_hash {
    my ($pkg) = @_;
    my $usr_file = $pkg->data_filename('users.txt');
    return $pkg->_read_user_file($usr_file);
}

sub _read_user_file {
    my ($pkg, $usr_file) = @_;

    my $usr_hash = {};

    open my $list, '<', $usr_file
        or die "Error opening '$usr_file'; $!";
    while (<$list>) {
        s/#.*//;            # Remove comments
        s/(^\s+|\s+$)//g;   # Remove leading or trailing spaces
        next if /^$/;       # Skip lines which are now blank
        my ($user_name, @allowed_datasets) = split;
        $user_name = lc($user_name);
        $usr_hash->{$user_name} ||= {}; # accept "authorised for no datasets", for code testing
        foreach my $ds (@allowed_datasets) {
            $usr_hash->{$user_name}{$ds} = 1;
        }
    }
    close $list or die "Error closing '$usr_file'; $!";

    return $usr_hash;
}



=head2 get_file($name)

Return the contents of the Otter Server config file C<$name> for the
current major version.

=cut

sub get_file {
    my ($pkg, $name) = @_;

    my $path = $pkg->data_filename($name, 1);
    open my $fh, '<', $path or die "Can't read '$path' : $!";
    local $/ = undef;
    my $content = <$fh>;
    close $fh;

    return $content;
}


=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

=cut

1;
