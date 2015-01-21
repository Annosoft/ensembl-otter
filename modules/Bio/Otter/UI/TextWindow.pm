
package Bio::Otter::UI::TextWindow;

use strict;
use warnings;

use Scalar::Util 'weaken';

sub new {
    my ($pkg, $parent) = @_;

    my $self = bless {}, $pkg;
    $self->parent($parent);

    my $master = $parent->canvas->toplevel;
    my $top = $master->Toplevel;
    $top->transient($master);

    my $window = $top->Scrolled(
        'ROText',
        -scrollbars             => 'e',
        -font                   => $parent->named_font('mono'),
        -padx                   => 6,
        -pady                   => 6,
        -relief                 => 'groove',
        -background             => 'white',
        -border                 => 2,
        -selectbackground       => 'gold',
        )->pack(
        -expand => 1,
        -fill   => 'both',
        );

    $self->window($window);

    # Frame for buttons
    my $frame = $top->Frame(
        -border => 6,
        )->pack(
        -side   => 'bottom',
        -fill   => 'x',
        );

    my $close_command = $self->buttons($frame, $top);

    if ($close_command) {
        my $exit = $frame->Button(
            -text => 'Close',
            -command => $close_command ,
            )->pack(-side => 'right');
        $top->bind(    '<Control-w>',      $close_command);
        $top->bind(    '<Control-W>',      $close_command);
        $top->bind(    '<Escape>',         $close_command);

        $top->protocol('WM_DELETE_WINDOW', $close_command);
    }
    $self->colour_init;

    return $self;
}

sub size_widget {
    my $self = shift;
    my $window = $self->window;

    my ($lines) = $window->index('end') =~ /(\d+)\./;
    $lines--;
    if ($lines > 40) {
        $window->configure(
            -width  => $self->width,
            -height => 40,
            );
    } else {
        # This has slightly odd behaviour if the ROText starts off
        # big to accomodate a large translation, and is then made
        # smaller.  Does not seem to shrink below a certain minimum
        # height.
        $window->configure(
            -width  => $self->width,
            -height => $lines,
            );
    }
    return;
}

sub parent {
    my ($self, $parent) = @_;
    if ($parent) {
        $self->{'_parent'} = $parent;
        weaken $self->{'_parent'};
    }
    return $self->{'_parent'};
}

sub window {
    my ($self, $window) = @_;
    if ($window) {
        $self->{'_window'} = $window;
    }
    return $self->{'_window'};
}

sub colour_init {
    my ($self) = @_;
    my $P = $self->parent;
    $P->SessionWindow->colour_init( $self->window->toplevel )
      if $P->can('SessionWindow');
    return;
}

1;

__END__

=head1 NAME - Bio::Otter::UI::TextWindow

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

