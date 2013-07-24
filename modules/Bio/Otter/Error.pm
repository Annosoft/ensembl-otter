
package Bio::Otter::Error;

use strict;
use warnings;

use Try::Tiny;
use TransientWindow::LogWindow;

# redefine Tk::Error() 
{
    no warnings qw( redefine ); ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    sub Tk::Error {
        my ($w, $error, @messages) = @_;
        # nb. @messages are a stacktrace, truncated by Tk where we
        # emerged from innermost event handler
        return Bio::Otter::Error->show($w, $error, @messages);
    }

}

sub show {
    my ($pkg, $w, $error, @messages) = @_;

    my $message = $error =~ /web server/
            ? 'There seems to be a problem with the web server, please try again later.'
            : "Unidentified problem: $error\n\nI suggest you raise a helpdesk ticket!"
            ;

    my @log = ("Tk::Error: $error", map { qq( $_\n) } @messages);

    try {
        my $err_log = TransientWindow::LogWindow->show_for($w);
        $err_log->message_highlight($message);
        # This GUI-only highlight can appear ~1000 lines above the
        # logged error, when the log window was previously not open;
        # or other distances when logs are accumulating fast.
    } catch {
        warn "GUI error during Tk::Error: $_\n";
    };
    print STDERR @log;          # dump to the log

#    $w->break; # ignores further errors
    return;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

