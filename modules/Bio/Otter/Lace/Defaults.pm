
### Bio::Otter::Lace::Defaults

package Bio::Otter::Lace::Defaults;

use strict;
use warnings;
use Carp;
use Getopt::Long 'GetOptions';
use Config::IniFiles;
use File::Temp;


my $CLIENT_STANZA   = 'client';
my $DEBUG_CONFIG    = 0;
#-------------------------------
my $CONFIG_INIFILES = [];

my $HARDWIRED =Config::IniFiles->new(-file => \*DATA);
push(@$CONFIG_INIFILES, $HARDWIRED);

# The config object for the GetOptions variables
my $GETOPT = Config::IniFiles->new;

my $HOME_DIR = (getpwuid($<))[7];
my $CALLED = "$0 @ARGV";

my @CLIENT_OPTIONS = qw(
    url=s
    author=s
    email=s
    write_access!
    gene_type_prefix=s
    debug=i
    );

# @CLIENT_OPTIONS is Getopt::GetOptions() keys which will be included in the
# $CLIENT_STANZA config.  To add another client option just include in above
# and if necessary add to hardwired defaults in do_getopt().

# not a method
sub save_option {
    my ($option, $value) = @_;
    $GETOPT->newval($CLIENT_STANZA, $option, $value);
    return;
}

# not a method
sub save_deep_option {
    my (undef, $getopt) = @_; # ignore the option name
    my ($option, $value) = split(/=/, $getopt, 2);
    $option = [ split(/\./, $option) ];
    my $param = pop @$option;
    return unless @$option;
    my $opt_str = join('.', @$option);
    $GETOPT->newval($opt_str, $param, $value);
    return;
}

################################################
#
## PUBLIC METHODS
#
################################################


=head2 do_getopt

 A wrapper function around GetOptions

    We get options from:
     - files provided by list_config_files()
     - command line
     - hardwired defaults (in this subroutine)
    overriding as we go.

Returns true on success, but on failure does:

  exec('perldoc', $0)

Suggested usage:

  Bio::Otter::Lace::Defaults::do_getopt(
    -dataset => \$dataset,
    );

=cut

my $DONE_GETOPT = 0;
sub do_getopt {
    my (@script_args) = @_;

    confess "do_getopt already called" if $DONE_GETOPT;
    $DONE_GETOPT = 1;

    ## If you have any 'local defaults' that you want to take precedence
    #  over the configuration files' settings, unshift them into @ARGV
    #  before running do_getopt()

    push(@$CONFIG_INIFILES, parse_available_config_files());
    ############################################################################
    ############################################################################
    my $start = "Called as:\n\t$CALLED\nGetOptions() Error parsing options:";
    GetOptions(
        'h|help!' => \&show_help,

        # map {} makes these lines dynamically from @CLIENT_OPTIONS
        # 'host=s'        => \&save_option,
        (map { $_ => \&save_option } @CLIENT_OPTIONS),

        # this allows setting of options as in the config file
        'cfgstr=s' => \&save_deep_option,

        # this is just a synonym feel free to add more
        'view' => sub { $GETOPT->newval($CLIENT_STANZA, 'write_access', 0) },

        # this allows multiple extra config file to be used
        'cfgfile=s' => sub {
            push(@$CONFIG_INIFILES, options_from_file(pop));
        },

        # 'prebinpath=s' => sub { $ENV{PATH} = "$_[1]:$ENV{PATH}"; },

        # these are the caller script's options
        @script_args,
      )
      or show_help();
    ############################################################################
    ############################################################################

    push(@$CONFIG_INIFILES, $GETOPT);

    # now safe to call any subs which are required to setup stuff

    return 1;
}

sub save_server_otter_config {
    my ($config) = @_;

    my $tmp = File::Temp->new
      (TEMPLATE => 'server_otter_config.XXXXXX',
       TMPDIR => 1, SUFFIX => '.ini');
    unless ((print {$tmp} $config) && close $tmp) {
        die sprintf('Error writing to %s; %s', $tmp->filename, $!);
    }
    my $ini = options_from_file($tmp->filename);
    undef $tmp; # DESTROY unlinks it

    # Server config file should be second in list, just after HARDWIRED
    splice(@$CONFIG_INIFILES, 1, 0, $ini);

    return;
}

sub show_help {
    exec('perldoc', $0);
}

sub make_Client {
    require Bio::Otter::Lace::Client;
    return Bio::Otter::Lace::Client->new;
}

sub parse_available_config_files {
    my @conf_files = ("/etc/otter_config");
    if ($ENV{'OTTER_HOME'}) {
        push(@conf_files, "$ENV{OTTER_HOME}/otter_config");
    }
    push(@conf_files, "$HOME_DIR/.otter_config");

    my @ini;
    foreach my $file (@conf_files) {
        next unless -e $file;
        if (my $file_opts = options_from_file($file)) {
            push(@ini, $file_opts);
        }
    }
    return @ini;
}

sub options_from_file {
    my ($file) = @_;

    return unless -e $file;

    warn "Trying $file\n" if $DEBUG_CONFIG;
    my $ini = Config::IniFiles->new( -file => $file );

    return $ini;
}

sub config_value {
    my ($section, $key) = @_;

    my $value;
    foreach my $ini ( @$CONFIG_INIFILES ) {
        if (my $v = $ini->val($section, $key)) {
            $value = $v;
        }
    }

    return $value;
}

sub config_value_list {
    my ($key1, $key2, $name) = @_;
    my $keys = [ "default.$key2", "$key1.$key2" ];
    return [ map { _config_value_list_ini_keys_name($_, $keys, $name); } @$CONFIG_INIFILES, ];
}

sub _config_value_list_ini_keys_name {
    my ($ini, $keys, $name) = @_;
    return map { $ini->val($_, $name); } @{$keys};
}

sub config_value_list_merged {
    my ($key1, $key2, $name) = @_;

    my @keys = ( "default.$key2", "$key1.$key2" );

    my $values;
    foreach my $ini ( @$CONFIG_INIFILES ) {
        foreach my $key ( @keys ) {
            my @vs = $ini->val($key, $name);
            next unless @vs;
            my $vs = \@vs;
            if ( $values ) {
                _config_value_list_merge($values, $vs);
            }
            else {
                $values = $vs;
            }
        }
    }

    return $values;
}

sub _config_value_list_merge {
    my ($values, $vs) = @_;

    # hash the new values
    my $vsh = { };
    $vsh->{$_}++ foreach @{$vs};

    # find the position of the first new value in the current list
    my $pos = 0;
    foreach ( @{$values} ) {
        last if $vsh->{$_};
        $pos++;
    }

    # remove any existing copies of the new values
    @{$values} = grep { ! $vsh->{$_} } @{$values};

    # splice the new values into place
    splice @{$values}, $pos, 0, @{$vs};

    return;
}

sub config_section {
    my ($key1, $key2) = @_;
    my $keys = [ "default.$key2", "$key1.$key2" ];
    return { map { _config_section_ini_keys($_, $keys) } @$CONFIG_INIFILES };
}

sub _config_section_ini_keys {
    my ($ini, $keys) = @_;
    return map { _config_section_ini_key($ini, $_); } @{$keys};
}

sub _config_section_ini_key {
    my ($ini, $key) = @_;
    return
        $ini->SectionExists($key)
        ? ( map {
            $_ => _config_section_ini_key_name($ini, $key, $_);
            } $ini->Parameters($key) )
        : ( );
}

sub _config_section_ini_key_name {
    my ($ini, $key, $name) = @_;
    my @val = $ini->val($key, $name);
    # convert a multi-value into an arrayref
    my $val =
        defined $ini->GetParameterEOT($key, $name)
        ? [ @val ] : $val[0];
    return $val;
}

sub config_keys {
    my ($key1, $key2) = @_;
    my $keys = [ "default.$key2", "$key1.$key2" ];
    return [ map { _config_keys_ini_keys($_, $keys) } @$CONFIG_INIFILES ];
}

sub _config_keys_ini_keys {
    my ($ini, $keys) = @_;
    return map { _config_keys_ini_key($ini, $_); } @{$keys};
}

sub _config_keys_ini_key {
    my ($ini, $key) = @_;
    return map { _section_key($_, $key) } $ini->Sections;
}

sub _section_key {
    my ($section, $key) = @_;
    return unless my ( $key1, $key2 ) = $section =~ /^([^\.]*\.[^\.]*)\.(.*)$/;
    return unless $key1 eq $key;
    return $key2;
}

1;

=head1 NAME - Bio::Otter::Lace::Defaults

=head1 DESCRIPTION

Loads default values needed for creation of an
otter client from:

  command line
  anything that you have unshifted into @ARGV before running do_getopt
  ~/.otter_config
  $ENV{'OTTER_HOME'}/otter_config
  /etc/otter_config
  hardwired defaults (in this module)

in that order.  The values filled in, which can
be given by command line options of the same
name, are:

=over 4

=item B<url>

Defaults to B<http://www.sanger.ac.uk/cgi-bin/otter>

=item B<author>

Defaults to user name

=item B<email>

Defaults to user name

=item B<write_access>

Defaults to B<0>

=back


=head1 EXAMPLE

Here's an example config file:


  [client]
  port=33999

  [default.use_filters]
  trf=1
  est2genome_mouse=1

  [zebrafish.use_filters]
  est2genome_mouse=0

  [default.filter.est2genome_mouse]
  module=Bio::EnsEMBL::Ace::Filter::Similarity::DnaSimilarity
  max_coverage=12


You can also specify options on the command line 
using the B<cfgstr> option.  Thus:

    -cfgstr zebrafish.use_filters.est2genome_mouse=0

will switch off est2genome_mouse for the
zebrafish dataset exactly as the config file example
above does.

=head1 SYNOPSIS

  use Bio::Otter::Lace::Defaults;

  # Script can add Getopt::Long compatible options:
  my $foo = 'bar';

  # or override the defaults from .otter_config onwards
  # (but allow the user's command line options to take precedence) :
  unshift @ARGV, '--port=33977', '--host=ottertest';

  Bio::Otter::Lace::Defaults::do_getopt(
      'foo=s'   => \$foo,     
      );

  # Make a Bio::Otter::Lace::Client
  my $client = Bio::Otter::Lace::Defaults::make_Client();

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

=cut


__DATA__

# This is where the HARDWIRED ABSOLUTE DEFAULTS are stored

[client]
url=http://www.sanger.ac.uk/cgi-bin/otter
write_access=0
debug=1
log_level=INFO
short_window_title_prefix=1
