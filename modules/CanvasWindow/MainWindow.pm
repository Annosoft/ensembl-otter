
### CanvasWindow::MainWindow

package CanvasWindow::MainWindow;

use strict;
use warnings;

use Tk;

# Work around UTF8 conversion bug
# "selection conversion left too many bytes unconverted"
$Tk::encodeFallback = 1; ## no critic (Variables::ProhibitPackageVars)

use base qw( MainWindow );

sub new {
    my ($pkg, $title) = @_;

    $title ||= 'Canvas Window';

    my $mw = $pkg->SUPER::new(
        -class => 'CanvasWindow',
        -title => $title,
        #-colormap   => 'new',
        );
    $mw->configure(
        -background     => '#bebebe',
        );
    $mw->scaling(1);    # Sets 1 screen pixel = 1 point.
                        # This is important. Without it text and objects
                        # on the canvas are rendered with different
                        # relative sizes on screen and when printed.

    #warn "Scaling = ", $mw->scaling, "\n";

    $mw->add_default_options;

    $mw->add_default_bindings;

    return $mw;
}

sub add_default_bindings {
    my ($mw) = @_;

    my $exit = sub{ exit; };
    $mw->bind('<Control-q>', $exit);
    $mw->bind('<Control-Q>', $exit);

    return;
}

sub add_default_options {
    my ($mw) = @_;

    # Get warnings about "possible comments in qw"
    no warnings "qw"; ## no critic (TestingAndDebugging::ProhibitNoWarnings)

    # Priority level of 40 is equivalent to an
    # application specific startup file.
    my $priority = 40;

    my @opt_val = qw{
        CanvasWindow*color                      #ffd700
        CanvasWindow*background                 #bebebe
        CanvasWindow*foreground                 black
        CanvasWindow*selectBackground           gold
        CanvasWindow*selectColor                gold
        CanvasWindow*activeBackground           #dfdfdf
        CanvasWindow*troughColor                #aaaaaa
        CanvasWindow*activecolor                #ffd700
        CanvasWindow*borderWidth                1
        CanvasWindow*activeborderWidth          1
        CanvasWindow*font                       -*-helvetica-medium-r-*-*-12-*-*-*-*-*-*-*
        CanvasWindow*fontFixed                  lucidatypewriter
        CanvasWindow*TopLevel*background        #bebebe
        CanvasWindow*Frame.borderWidth          0
        CanvasWindow*Scrollbar.width            11
        CanvasWindow*Menubutton.padX            6
        CanvasWindow*Menubutton.padY            6
        CanvasWindow*Balloon*background         #ffffcc
        CanvasWindow*Text*background            white
        CanvasWindow*ProgressBar*troughColor    #aaaaaa
        CanvasWindow*ProgressBar*relief         sunken
        CanvasWindow*ProgressBar*foreground     gold
        };

    for (my $i = 0; $i < @opt_val; $i += 2) {
        my ($opt, $val) = @opt_val[$i, $i + 1];
        #warn "Adding '$opt' : '$val'\n";
        $mw->optionAdd($opt, $val, $priority);
    }

    my @entry_class = qw{ Entry NoPasteEntry };
    foreach my $class (@entry_class) {
        $mw->optionAdd("CanvasWindow\*$class.relief",       'sunken',       $priority);
        $mw->optionAdd("CanvasWindow\*$class.foreground",   'black',        $priority);
        $mw->optionAdd("CanvasWindow\*$class.background",   'white',        $priority);
        $mw->optionAdd("CanvasWindow\*$class.font",
            '-*-lucidatypewriter-medium-r-normal-*-14-140-*-*-*-*-*-*',     $priority);
    }

    return;
}


1;

__END__

=head1 NAME - CanvasWindow::MainWindow

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

