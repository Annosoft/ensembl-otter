package Bio::Otter::Server::Test;
use strict;
use warnings;

use DBI;
use File::Find;
use Try::Tiny;
use Sys::Hostname 'hostname';
use Cwd 'cwd';

use Bio::Otter::ServerScriptSupport;
use Bio::Otter::Version;
use Bio::Otter::Git;
use Bio::Otter::Auth::Pagesmith;
use Bio::Otter::Auth::SSO;


# keep the align-to-centre layout, it's easier to read than YAML
sub __hash2table {
    my ($hashref) = @_;
    my $out;
    foreach my $var (sort keys %$hashref) {
        $out .= sprintf "%35s  %s\n", $var,
          defined $hashref->{$var} ? $hashref->{$var} : '(undef)';
    }
    return $out;
}

# load all our modules, and their deps
sub _require_all {
    my $dir = $INC{'Bio/Otter/ServerScriptSupport.pm'};
    $dir =~ s{Otter/\w+\.pm$}{};

    # some modules need a clean PATH
    $ENV{PATH} = '/bin:/usr/bin';

    my @mods;
    my $wanted = sub {
        if (-f && m{.*/(modules|\d+)/(Bio/.*)\.pm$}) {
            my $modfn = $2; # untainted
            $modfn =~ s{/}{::}g;
            push @mods, $modfn;
        }
        return ();
    };
    find({ wanted => $wanted, no_chdir => 1 }, $dir);

    my %out;
    foreach my $mod (@mods) {
        if (eval "require $mod;") { ## no critic (BuiltinFunctions::ProhibitStringyEval,Anacode::ProhibitEval)
            push @{ $out{loaded} }, $mod;
        } else {
            my $err = $@;
            $err =~ s{ \(\@INC contains: [^()]+\) at }{... at };
            $out{error}->{$mod} = $err;
        }
    }

    return \%out;
}

sub _is_SangerWeb_real {
    my $src = $INC{'SangerWeb.pm'};
    if (!defined $src) {
        return 'None (?!)';
    } elsif (SangerWeb->can('is_dev') && $SangerWeb::VERSION) {
        return "Genuine $SangerWeb::VERSION from $src";
    } else {
        return "Bogus from $src";
    }
}


sub generate {
    my ($called, $server) = @_;

    my $web = $server->sangerweb;

    my $user = $web->username;

    my %out = (ENV => __hash2table(\%ENV),
               CGI_param => '');

    foreach my $var ($server->param) {
        $out{CGI_param} .= sprintf "%24s  %s\n", $var, $server->param($var);
    }

    # avoiding exposing internals (private or verbose)
    my $cgi = $web->cgi;
    $out{SangerWeb} = { cgi => "$cgi",
                        origin => _is_SangerWeb_real(),
                        HTTP_CLIENTREALM => $ENV{HTTP_CLIENTREALM},
                        username =>  $web->username };

    $out{webserver} =
      { hostname => scalar hostname(),
        user => scalar getpwuid($<),
        group => [ map { "$_: ".getgrgid($_) } split / /, $( ],
        cwd => scalar cwd(),
        pid => $$ };

    $out{'B:O:ServerScriptSupport'} =
      { local_user => $server->local_user,
#        BOSSS => $server, # would leak users config & CGI internals
        internal_user => $server->internal_user };

    foreach my $mod (qw( Bio::Otter::Auth::SSO Bio::Otter::Auth::Pagesmith )) {
        $out{ $mod->test_key } = { $mod->auth_user($web, $server->users_hash) };
    }

    $out{'B:O:Server::Config'} =
      { data_dir => Bio::Otter::Server::Config->data_dir,
        data_filename => { root => [ Bio::Otter::Server::Config->data_filename('foo') ],
                           vsn => [ Bio::Otter::Server::Config->data_filename(foo => 1) ] },
        mid_url_args => Bio::Otter::Server::Config->mid_url_args,
        designations => Bio::Otter::Server::Config->designations };

    $out{version} =
      { major => Bio::Otter::Version->version,
        '$^X' => $^X, '$]' => $],
        code => try { Bio::Otter::Git->as_text } catch { "FAIL: $_" } };

    my $dbh = DBI->connect
      ("DBI:mysql:database=pipe_human;host=otp1slave;port=3322",
       "ottro", undef, { RaiseError => 0 });
    $out{DBI} = $dbh ? { connected => "$dbh" } : { error => DBI->errstr };


    if ($server->param('load')) {
        $out{load_modules} = _require_all();
    }

    if ($server->param('more')) {
        $out{Perl} =
          { '${^TAINT}' => ${^TAINT},
            '@INC' => \@INC, '%INC' => __hash2table(\%INC),
          };
    }

    return %out;
}


1;

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

=cut