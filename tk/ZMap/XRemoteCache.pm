
package ZMap::XRemoteCache;

use strict;
use warnings;

use X11::XRemote;
use Data::Dumper;

my $CLIENT_DEBUG = 0;
my $CACHE_DEBUG  = 0;

my $object_cache = {
    # 'window_id' => { object  => X11::XRemote, 
    #                  pid     => $process_id, 
    #                  actions => [ qw(actions accepted by window) ],
    # },
};

# A window has  1 pid, 1 pid  has many windows. A window  has a single
# list of  actions, each  list of actions  has many  windows, possibly
# spread over multiple pids.

sub new{
    my $pkg = shift;
    my $self = {};
    $self->{'_self_windows'} = {};
    bless($self, $pkg);

    return $self;
}

sub get_pid_list{
    my ($self) = @_;
    my ($list, $pid_hash);
    
    $list ||= [];

    foreach my $xwid(keys(%$object_cache)){
        my $pid = $object_cache->{$xwid}->{'pid'};
        if(defined $pid){ $pid_hash->{$pid} = 1; }
    }

    push(@$list, keys(%$pid_hash));

    return $list;
}

sub _internal_get_client_for_action_pid{
    my ($self, $cache, $requested_action, $pid) = @_;

    my $client = undef;

    foreach my $id(keys(%$cache)){
        my ($tmp_client, $tmp_pid, $tmp_actions) = ($cache->{$id}->{'object'}, 
                                                    $cache->{$id}->{'pid'}, 
                                                    $cache->{$id}->{'actions'});
        if(defined($pid)){
            next unless $tmp_pid eq $pid;
        }
        $tmp_actions ||= [];
        foreach my $action(@$tmp_actions){
            if($requested_action eq $action){
                $client = $tmp_client;
            }
        }
    }

    return $client;

}

sub get_client_for_action_pid{
    my ($self, $requested_action, $pid) = @_;

    my $client = $self->_internal_get_client_for_action_pid($object_cache, $requested_action, $pid);

    return $client;
}

sub get_own_client_for_action_pid{
    my ($self, $requested_action, $pid) = @_;

    my $cache;

    foreach my $id(keys(%{$self->{'_self_windows'}})){
        $cache->{$id} = $object_cache->{$id};
    }

    my $client = $self->_internal_get_client_for_action_pid($cache, $requested_action, $pid);

    return $client;
}

sub remove_client_with_id{
    my ($self, $id, $name) = @_;

    delete $object_cache->{$id};
    delete $self->{'_self_windows'}->{$id};

    return;
}

sub remove_clients_to_bad_windows{
    my ($self) = @_;

    warn "cleaning up any bad windows" if $CACHE_DEBUG;
    foreach my $id(keys(%$object_cache)){
        if(my $xr = $object_cache->{$id}->{'object'}){
            if ($xr->ping) {
                warn sprintf "  client '%s' not bad", $id if $CACHE_DEBUG;
            } else {
                warn sprintf "  removing bad client '%s'", $id if $CACHE_DEBUG;
                delete $object_cache->{$id};
                delete $self->{'_self_windows'}->{$id};
            }
        }else{
            delete $object_cache->{$id};
            delete $self->{'_self_windows'}->{$id};
        }
            
    }
    return;
}

sub create_client_with_pid_id_actions{
    my ($self, $pid, $id, @actions) = @_;

    my $entry = $object_cache->{$id};
    return $entry->{'object'} if $entry;

    my $client = X11::XRemote->new(-id     => $id, 
                                   -server => 0,
                                   -_DEBUG => $CLIENT_DEBUG);
    $object_cache->{$id} = {
        'object'  => $client,
        'pid'     => $pid,
        'actions' => [ @actions ],
    };
    $self->{'_self_windows'}->{$id} = $id;

    return $client;
}


sub DESTROY{
    my ($self) = @_;

    print Dumper $object_cache if $CACHE_DEBUG;

    return;
}

1;
