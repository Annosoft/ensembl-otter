package BaseWindow;
use strict;
use warnings;

use Try::Tiny;
use Scalar::Util 'weaken';
use Carp;

use Tk;
use Tk::Font;
use Tk::Config; # do we have XFT=1 ?
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

# Requires methods: top, name.
# Expects these methods to return false to prevent destroy.
sub bind_WM_DELETE_WINDOW {
    my ($self, $method) = @_;

    my $closer = sub {
        if (my $d = $self->{_window_closing}) {
            my $name = try { $self->name } catch { '?' };
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

    $self->top->protocol(WM_DELETE_WINDOW => $closer);

    return $closer; # for binding to KeyPress
}

sub delete_window_dialog {
    my ($self, $dialog) = @_;
    confess "But window is not closing?" unless $self->{_window_closing};
    $self->{_window_closing} = $dialog;
    return;
}

sub balloon {
    my ($self) = @_;

    $self->{'_balloon'} ||= $self->top->Balloon(
        -state  => 'balloon',
        );
    return $self->{'_balloon'};
}


# Fonts are controlled
#   named_font -- here
#   in CW:MainWindow::add_default_options -- Tk uses *font for menus
#   in CW::font* methods -- to become wrappers on this
#   independently by some scripts & modules
sub _bw_fonts {
    my ($self) = @_;

    # fonts exist on the MainWindow, so store ours there
    my $mw = $self->top->Widget('.');
    my $bwf = $mw->{_bw_fonts} ||= {};
    return $bwf if keys %$bwf;

    my $xft = __have_XFT();

    my %font = map {( shift @$_, { @$_ } )}
      ($xft
       ? ([qw[ prop     -family Arial -size  11 ]],
          [qw[ mono     -family Lucida_Sans_Typewriter -size 11 ]],
          [qw[ menu     -family Arial -size 11 -weight normal ]],
          [qw[ head1    -family Arial -size 16 -weight bold ]])
       : ([qw[ prop     -family helvetica        -size 12 -weight normal ]],
          [qw[ mono     -family lucidatypewriter -size 15 ]],
          [qw[ menu     -family helvetica        -size 14 -weight normal ]],
          [qw[ head1    -family helvetica        -size 18 -weight bold ]]));
    # "menu" should match CanvasWindow*font

    # Add variants
    $font{prop_ubold} = { %{$font{prop}}, qw{ -weight bold -underline 1 } };
    $font{listbold}   = { %{$font{mono}}, qw{ -weight bold } };

    while (my ($fontname, $opts) = each %font) {
        $opts->{'-family'} =~ s/_/ /g; # convenience for qw[] above
        my $font = $bwf->{$fontname} = $mw->fontCreate($fontname => %$opts);

        # Check it
        my %cfg = $font->configure;
        my %got = $font->actual;
        delete $cfg{-size};
        delete $got{-size}; # may be -ve (a pixel size), so cannot compare
        my $cfg = join ' ', map {"$_:$cfg{$_}"} sort keys %cfg;
        my $got = join ' ', map {"$_:$got{$_}"} sort keys %got;
        warn "$fontname: ask ($cfg),\n      got ($got)  XFT=$xft\n"
          unless "$cfg" eq "$got";
    }

    return $bwf;
}

sub __have_XFT {
    my $xlib = $Tk::Config::xlib; ## no critic( Variables::ProhibitPackageVars )
    die "Tk::Config::xlib missing" unless defined $xlib;
    my $have_XFT =
      # comp.lang.perl.tk 4/5/2004 3:46:27 PM
      $xlib =~ m{-lXft\b} ? 1 : 0;
    # alternatively,
    #   try { my $e = $win->Entry(-font => 'Mumble Jumble:style=Regular:pixelsize=36'); $e->destroy; 1 } catch { 0 }
    return $have_XFT;
}

sub named_font {
    my ($self, $fontname, @info) = @_;
    my $font = $self->_bw_fonts->{$fontname};
    confess "Font name '$fontname' not defined" unless $font;
    my @out = ($font, map { $self->_font_prop($font, $_) } @info);
    return @out if wantarray;
    croak "info needs list context" unless 1 == @out;
    return $out[0];
}

sub _font_prop {
    my ($self, $font, $prop) = @_;
    if ($prop eq 'linegap') {
		my $size = $self->_font_prop($font, 'linespace');
        return $size + int($size / 6);
    }
    return $font->metrics("-$prop");
}

1;
