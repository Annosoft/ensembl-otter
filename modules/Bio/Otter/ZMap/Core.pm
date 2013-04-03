
package Bio::Otter::ZMap::Core;

#  The transport/protocol independent code to manage ZMap processes.

use strict;
use warnings;

use Carp;
use Scalar::Util qw( weaken );
use POSIX ();

use Bio::Vega::Utils::MacProxyConfig qw{ mac_os_x_set_proxy_vars };

my @_list = ( );

sub list {
    my ($pkg) = @_;
    # filter the list because weak references may become undef
    my $list = [ grep { defined } @_list ];
    return $list;
}

my $_string_zmap_hash = { };

sub from_string {
    my ($pkg, $string) = @_;
    my $zmap = $_string_zmap_hash->{$string};
    return $zmap;
}

sub new {
    my ($pkg, %arg_hash) = @_;
    my $new = { };
    bless($new, $pkg);
    push @_list, $new;
    weaken $_list[-1];
    $_string_zmap_hash->{"$new"} = $new;
    weaken $_string_zmap_hash->{"$new"};
    $new->_init(\%arg_hash);
    return $new;
}

sub _init {
    my ($self, $arg_hash) = @_;
    $self->{'_id_view_hash'} = { };
    $self->{'_view_list'} = [ ];
    $self->{'_conf_dir'} = $self->_conf_dir;
    $self->{'_short_title'} = delete $arg_hash->{'-short_title'}; # goes in config
    $self->_make_conf;
    $self->launch_zmap($arg_hash);
    return;
}

sub _conf_dir {
    my $conf_dir = q(/var/tmp);
    my $user = getpwuid($<);
    my $dir_name = "otter_${user}";
    my $key = sprintf "%09d", int(rand(1_000_000_000));
    for ($dir_name, 'ZMap', $key) {
        $conf_dir .= "/$_";
        -d $conf_dir
            or mkdir $conf_dir
            or die sprintf "mkdir('%s') failed: $!", $conf_dir;
    }
    return $conf_dir;
}

sub _conf_txt {
    my ($self) = @_;
    my $shorttl = $self->{'_short_title'} ? 'true' : 'false';
    return <<"CONF";

[ZMap]
show-mainwindow = false
abbrev-window-title = $shorttl
CONF
}

sub _make_conf {
    my ($self) = @_;
    my $conf_file = sprintf "%s/ZMap", $self->conf_dir;
    open my $conf_file_h, '>', $conf_file
        or die sprintf
        "failed to open the configuration file '%s': $!"
        , $conf_file;
    print $conf_file_h $self->_conf_txt;
    close $conf_file_h
        or die sprintf
        "failed to close the configuration file '%s': $!"
        , $conf_file;
    return;
}

sub launch_zmap {
    my ($self, $arg_hash) = @_;

    if ($^O eq 'darwin') {
        # Sadly, if someone moves network after launching zmap, it
        # won't see new proxy variables.
        mac_os_x_set_proxy_vars(\%ENV);
    }

    my @e = ('zmap', @{$self->zmap_arg_list($arg_hash)} );
    warn "Running: @e\n";
    my $pid = fork;
    confess "Error: couldn't fork()\n" unless defined $pid;
    return if $pid;
    { exec @e; }
    # DUP: EditWindow::PfamWindow::initialize $launch_belvu
    # DUP: Hum::Ace::LocalServer
    warn "exec '@e' failed : $!";
    close STDERR; # _exit does not flush
    close STDOUT;
    POSIX::_exit(127); # avoid triggering DESTROY

    return; # unreached, quietens perlcritic
}

sub zmap_arg_list {
    my ($self, $arg_hash) = @_;
    my $zmap_arg_list = [
        '--conf_dir' => $self->conf_dir,
    ];
    my $arg_list = $arg_hash->{'-arg_list'};
    push @{$zmap_arg_list}, @{$arg_list} if $arg_list;
    return $zmap_arg_list;
}

sub add_view {
    my ($self, $id, $view) = @_;
    $self->id_view_hash->{$id} = $view;
    weaken $self->id_view_hash->{$id};
    push @{$self->_view_list}, $view;
    weaken $self->_view_list->[-1];
    return;
}

# waiting

sub wait {
    my ($self) = @_;
    $self->{'_wait'} = 1;
    $self->widget->waitVariable(\ $self->{'_wait'});
    return;
}

sub wait_finish {
    my ($self) = @_;
    $self->{'_wait'} = 0;
    delete $self->{'_wait'};
    return;
}

# attributes

sub conf_dir {
    my ($self) = @_;
    my $conf_dir = $self->{'_conf_dir'};
    return $conf_dir;
}

sub id_view_hash {
    my ($self) = @_;
    my $id_view_hash = $self->{'_id_view_hash'};
    return $id_view_hash;
}

sub view_list {
    my ($self) = @_;
    # filter the list because weak references may become undef
    my $view_list = [ grep { defined } @{$self->_view_list} ];
    return $view_list;
}

sub _view_list {
    my ($self) = @_;
    my $view_list = $self->{'_view_list'};
    return $view_list;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

