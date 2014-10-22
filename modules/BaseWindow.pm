package BaseWindow;
use strict;
use warnings;

use Try::Tiny;
use Scalar::Util 'weaken';
use Carp;

use Bio::Otter::Lace::Client;


# Create a Toplevel, call our ->new for it, initialise;
# or if $$reuse_ref, return the existing one.
sub in_Toplevel {
    my ($pkg, @arg) = @_;
    croak "Method needs ->(%tk_args, { %local_args })" unless @arg % 2;
    my $eo_opt_hash = pop @arg;

    # Options for Tk
    my %tk_opt = @arg;
    $tk_opt{-title} = $pkg unless defined $tk_opt{-title};
    $tk_opt{-title} = $Bio::Otter::Lace::Client::PFX.$tk_opt{-title};
    $tk_opt{Name} = $pkg->_toplevel_name;

    # Options for this code
    my $parent     = delete $eo_opt_hash->{from};   # from which new Toplevel is made
    my $reuse_ref  = delete $eo_opt_hash->{reuse_ref};
    my $raise      = delete $eo_opt_hash->{raise};  # should we raise?
    my $init       = delete $eo_opt_hash->{init};   # link and call initialise?
    my $wait_close = delete $eo_opt_hash->{wait};
    my $transient  = delete $eo_opt_hash->{transient};

    my @eo_unk = sort keys %$eo_opt_hash;
    croak "Unknown tail-hash option keys (@eo_unk)" if @eo_unk;

    # Obtain or create
    my $self;
    $self = $$reuse_ref if $reuse_ref; # a scalar ref, in which we are cached
    if ($self && !Tk::Exists($self->top)) {
        warn "Something held onto old (destroyed but not DESTROYed) $self";
        $self = undef;
    }
    if (!$self) {
        my $top = $parent->Toplevel(%tk_opt);
        $top->transient($parent) if $transient;
        $self = $pkg->new($top);
        $self->_link_and_init(%$init) if $init;
        if ($reuse_ref) {
            $$reuse_ref = $self;
            weaken($$reuse_ref);
        }
    }

    my $top = $self->top;
    if ($raise) {
        $top->deiconify;
        $top->raise;
    }
    $top->waitWindow if $wait_close;

    return $self;
}

sub _toplevel_name {
    my ($called) = @_;
    my $name = ref($called) || $called;
    for ($name) {
        s/::/_/g;
        s/EditWindow/edwin/;
        s/MenuCanvasWindow/mcw/;
        s/CanvasWindow/canvwin/;
    }
    return lc($name);
}

sub _link_and_init {
    my ($self, %link) = @_;

    while (my ($method, $val) = each %link) {
        $self->$method($val);
    }

    return $self->initialise;
}

sub initialize { # deprecated
    my ($self, @arg) = @_;
    carp "$self->initialize: deprecated, use initialise";
    return $self->initialise(@arg);
}

# Requires methods: top_window, name.
# Expects these methods to return false to prevent destroy.
sub bind_WM_DELETE_WINDOW {
    my ($self, $method) = @_;

    my $closer = sub {
        if (my $d = $self->{_window_closing}) {
            my $name = $self->name;
            warn "Dodged nesting call to $method($self) for $name";
            if (Tk::Exists($d)) { # maybe we have the confirmation dialog
                $d->deiconify;
                $d->raise;
            }
            return 0;
        }
        local $self->{_window_closing} = 1;
        return $self->$method;
    };

    $self->top_window->protocol(WM_DELETE_WINDOW => $closer);

    return $closer; # for binding to KeyPress
}

sub delete_window_dialog {
    my ($self, $dialog) = @_;
    confess "But window is not closing?" unless $self->{_window_closing};
    $self->{_window_closing} = $dialog;
    return;
}


1;
