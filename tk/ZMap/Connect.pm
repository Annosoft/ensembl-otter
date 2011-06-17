package ZMap::Connect;

=pod

=head1 NAME 

ZMap::Connect

=head1 DESCRIPTION

For  connecting  to ZMap  and  makes  the  X11::XRemote module  more
useable as a server.

=cut

use strict;
use warnings;
use XML::Simple;
use X11::XRemote;
use Tk::X;

my $DEBUG_CALLBACK = 0;
my $DEBUG_EVENTS   = 0;

=head1 METHODS

=head2 new([-option => "value"])

Creates a new ZMap::Connect Object.

=cut

sub new{
    my ($pkg) = @_;
    my $self = { };
    bless($self, $pkg);
    return $self;
}


=head2 init(Tk, [handler, [data]])

Initialises  the new  object  so  it is  useable. 
Requires the  B<Tk> object.  The  B<handler> is 
the callback which  gets called  when the window
is sent a message via an  atom.  It is called by
THIS module as C<<< $callback->($self, $request,
@data) >>>.  Note the data supplied as a  list
ref  to this  function gets  dereferenced when 
passed  to the callback.   The request  string 
is  supplied free  of  charge so  the callback
does  not have to  navigate its way  to it from 
this module (supplied as $self above).

 Usage:

 my $fruits = [qw(apples pears bananas)];
 my $veg    = [qw(carrots potatoes)];
 my $callback = sub{ 
     my ($zmap, $req, $f, $v) = @_;
     if($req =~ /fruits/){
        print "I know about these fruits: " . join(", ", @$f) . "\n";
     }elsif($req =~ /veg/){
        print "I know about these vegetables: " . join(", ", @$v) . "\n";
     }
     return (200, "printed my knowledge.");
 };

 my $zmap = ZMap::Connect->new();
 $zmap->init($tk, $callback, [$fruits, $veg]);

=cut

sub init{
    my ($self, $tk, $callback, $data) = @_;
    unless($tk){
        warn "usage: ".__PACKAGE__."->init(Tk_Object, [SubRoutine_Ref, [Data_Array_Ref]]);\n"; 
        return;
    }

    $self->widget($tk);
    $self->respond_handler($callback, $data);

    return;
}

=head2 connect_request( )

This maybe  used to  get the  string for registering  the server  as a
remote window  of the  zmap client.  ZMap  should honour  this request
creating a  client with  the window  id of the  request widget  as its
remote window.

=cut

sub connect_request{
    my ($self) = @_;

    my $fmt = q!<zmap>
 <request action="%s">
  <client xwid="%s" request_atom="%s" response_atom="%s"/>
 </request>
</zmap>!;

    return sprintf($fmt, 
                   "register_client", 
                   $self->server_window_id, 
                   $self->request_name,
                   $self->response_name
                   );
}

sub client_registered_response{
    my ($self) = @_;

    my $out  = {
        response => {
            client => [
                {
                    created => 1,
                    exists  => 1,
                }
            ]
        }
    };
    $self->protocol_add_meta($out);
    my $reponse =make_xml($out);

    return $reponse;
}

=head2 server_window_id( )

Just the window id of the request widget.

=cut


sub server_window_id{
    my ($self) = @_;
    return $self->widget->id();
}

=head2 xremote( )

The xremote Object [C<<< X11::XRemote >>>].

=cut

sub xremote{
    my ($self, $id) = @_;
    my $xr = $self->{'_xremote'};
    if (!$xr) {
        if (defined $id) {
            $xr = X11::XRemote->new(
                -server => 1,
                -id     => $id
                );
        }
        else {
            die "ZMap::Connect::xremote called as server without providing a window ID";
        }
        $self->{'_xremote'} = $xr;
    }
    return $xr;
}



=head1 ERROR

 Currently just the one to help the user with consistency.

=head2 basic_error($message)

Some xml which should be used in callback for error messages.

 sub cb {
   ...
   # On error
   my $errno = 404;
   my $xml = $Connect->basic_error("Unknown Command"); 
   ...
   return ($errno, $xml);
 }

=cut

sub handled_response {
    my ($self, $value) = @_;
    
    my $hash = {
        response => {
                handled => $value ? 1 : 0,
            }
        };
#    $self->protocol_add_request($hash);
    $self->protocol_add_meta($hash);
    return make_xml($hash);
}

sub basic_error {
    my ($self, $message) = @_;

    $message ||=  (caller(1))[3] . " was lazy";

    my $hash   = { 
        error => {
            message => [ $message ],
        }
    }; 
    $self->protocol_add_request($hash);
    $self->protocol_add_meta($hash);
    return make_xml($hash);
}

sub protocol_add_request {
    my ($self, $hash) = @_;
    
    $hash->{'request'} = [ xml_escape($self->_current_request_string) ];

    return;
}

sub protocol_add_meta {
    my ($self, $hash) = @_;

    $hash->{'meta'} = {
        display     => $ENV{DISPLAY},
        windowid    => $self->server_window_id,
        application => $self->xremote->application,
        version     => $self->xremote->version,
    };

    return;
}

sub request_name{
    return X11::XRemote::client_request_name;
}

sub response_name{
    return X11::XRemote::client_response_name;
}

=head2 widget( )

Set/Get the widget.

=cut

sub widget{
    my ($self, $tk) = @_;
    my $widget = $self->{'_widget'};
    if($tk && !$widget){
        my $qName = $self->request_name();
        my $sName = $self->response_name();
        # we create a new widget so our binding stay alive
        # and our users bindings don't get trampled on.
        $widget = $tk->Label(
                             -text => "${qName}|${sName}|Widget",
                             )->pack(-side => 'left');
        
        $self->{'_widget'} = $widget;
        
        my $id = $self->server_window_id();
        
        # we need to wait until the widget is mapped by the x server so that we 
        # can reliably initialise the xremote protocol so we must wait for the
        # <Map> event
        
        my $mapped; # a flag used in waitVariable below to indicate that the widget is mapped
        
        $widget->bind('<Map>' => sub {
            $widget->packForget;
            my $xr = $self->xremote($id);
            $xr->request_name($self->request_name);
            $xr->response_name($self->response_name);
            $mapped = 1;
        });

        # this call will essentially block until the widget is mapped and the
        # xremote protocol is initialised (the tk event loop will continue though)
        $widget->waitVariable(\$mapped);
    }
    return $widget;
}

=head2 respond_handler( )

Set/Get the callback which will get called.

=cut

sub respond_handler{
    my ($self, $callback, $data) = @_;
    $self->__callback($callback);
    $self->__callback_data($data);
    my $handler = \&_do_callback;
    if(my $widget = $self->widget){
        $widget->bind('<Property>', [ $handler , $self ] );
        $widget->bind('<Destroy>', sub {
            $self->{'_xremote'}       = undef;
            $self->{'_callback_data'} = undef; 
            $self = undef;
        });
    }else{
        warn "Suggested usage:\n" . 
            "my \$c = ".__PACKAGE__."->new([options]);\n" .
            "\$c->init(\$tk, \$callback, \$callback_data);\n";
    }

    return;
}


sub post_respond_handler{
    my ($self, $callback, $data) = @_;
    if($callback && $data){
        $self->__post_callback($callback);
        $self->__post_callback_data($data);
    }else{
        $self->{'_post_callback_data'} = $self->{'_post_callback'} = undef;
    }
        
    return 1;
}

# ======================================================== #
#                      INTERNALS                           #
# ======================================================== #

my @xml_request_parse_parameters =
    (
     KeyAttr    => { feature => 'name' },
     ForceArray => [ 'feature', 'subfeature' ],
    );

sub _do_callback{
    my ($tk, $self) = @_;
    my $id    = $tk->id();
    my $ev    = $tk->XEvent(); # Get the event
    my $state = ($ev->s ? $ev->s : 0); # assume zero (PropertyDelete I think)
    my $reqnm = $self->request_name(); # atom name of the request
    if ($state == PropertyDelete){
        warn "Event had state 'PropertyDelete', returning...\n" if $DEBUG_EVENTS;
        return ; # Tk->break
    }
    #====================================================================
    # DEBUG STUFF
    warn "//========== _do_callback ========== window id: $id\n" if $DEBUG_CALLBACK;
    if($DEBUG_EVENTS){
        foreach my $m('a'..'z','A'..'Z','#'){
            warn "Event on method '$m' - ". $ev->$m() . " " .sprintf("0x%lx", $ev->$m) . " \n" if $ev->$m();
        }
    }
    unless($ev->T eq 'PropertyNotify'){ warn "Odd Not a propertyNotify\n"; }
    unless($ev->d eq $reqnm){
        warn "Event was NOT for this.\n" if $DEBUG_CALLBACK;
        return ; # Tk->break
    }
    my $request_string = $self->xremote->request_string();
    $self->_current_request_string($request_string);
    warn "Event has request string $request_string\n" if $DEBUG_CALLBACK;
    #=========================================================
    my $cb = $self->__callback();
    my $request = XMLin($request_string, @xml_request_parse_parameters);
    my @data = @{$self->__callback_data};
    my $reply;
    my $fstr  = $self->xremote->format_string;
    my $intSE = $self->basic_error("Internal Server Error");
    my $success = eval{ 
        X11::XRemote::block(); # this gets automatically unblocked for us, besides we have no way to do that!
        my ($status, $xmlstr) = $cb->($self, $request, @data);
        $status ||= 500; # If callback returns undef...
        $xmlstr ||= $intSE;
        $reply = sprintf($fstr, $status, $xmlstr);
        1;
    };
    # $@ needs xml escaping!
    $reply ||= sprintf($fstr, 500, $self->basic_error("Internal Server Error $@"))
        unless $success;
    $reply ||= sprintf($fstr, 500, $intSE);
    $self->_drop_current_request_string;
    warn "Connect $reply\n" if $DEBUG_CALLBACK;
    $self->xremote->send_reply($reply);

    if(my $post_cb = $self->__post_callback()){
        my @post_data = @{$self->__post_callback_data()};
        $post_cb->($self, @post_data);
    }

    return;
}

sub _drop_current_request_string {
    my ($self) = @_;
    
    $self->{'_current_request_string'} = undef;

    return;
}

sub _current_request_string {
    my ($self, $str) = @_;
    
    if ($str) {
        $self->{'_current_request_string'} = $str;
    }
    return $self->{'_current_request_string'};
}

sub __callback_data{
    my($self, $dataRef) = @_;
    $self->{'_callback_data'} = $dataRef if ($dataRef && ref($dataRef) eq 'ARRAY');
    return $self->{'_callback_data'} || [];
}
sub __callback{
    my($self, $codeRef) = @_;
    $self->{'_callback'} = $codeRef if ($codeRef && ref($codeRef) eq 'CODE');
    return $self->{'_callback'} || sub { warn "@_\nNo callback set.\n"; return (500,"") };
}

sub __post_callback_data{
    my($self, $dataRef) = @_;
    $self->{'_post_callback_data'} = $dataRef if ($dataRef && ref($dataRef) eq 'ARRAY');
    return $self->{'_post_callback_data'} || [];
}
sub __post_callback{
    my($self, $codeRef) = @_;
    $self->{'_post_callback'} = $codeRef if ($codeRef && ref($codeRef) eq 'CODE');
    return $self->{'_post_callback'};
}

# ======================================================== #
# DESTROY: Hopefully won't need to do anything             #
# ======================================================== #
sub DESTROY{
    my ($self) = @_;
    warn "Destroying $self";
    return;
}

sub make_xml{
    my ($hash) = @_;
    my $xml = XMLout($hash, rootname => q{}, keeproot => 1);
    return $xml;
}

my $xml_escape_parser = XML::Simple->new(NumericEscape => 1);
sub xml_escape{
    my ($data) = shift;
    my $escaped = $xml_escape_parser->escape_value($data);
    return $escaped;
}

1;
__END__

=head1 A WORD OF WARNING

When  writing the callback to  be called  on receipt of a command, be
careful not to  send the origin window of the  command a command. This
will lead  to a race condition.   The original sender  will be waiting
for the reply  from the callback, while your window  will be sending a
command to a window which cannot respond.

The prevention of this race condition has been coded into this module
and the L<X11::XRemote> module and you will be warned of an C< Avoided 
race condition >.
problem.

The recommended solution to this common problem is to send yourself a
generated event.  This is very easy using L<Tk::event> and the C<<<
$widget->eventGenerate('<EVENT>', -when => 'tail') >>> function should
be sufficient for most cases.

 Example:

 my $callback = sub {
    my ($this, $request, $obj) = @_;
    if($request =~ /something_two_way/){
      $obj->widget->eventGenerate('<ButtonPress>', -when => 'tail');
    }
    return (200, "everything went well");
 };


=head1 AUTHOR

R.Storey <rds@sanger.ac.uk>

=head1 SEE ALSO

L<X11::XRemote>, L<Tk::event>, L<perl>.

=cut
    
