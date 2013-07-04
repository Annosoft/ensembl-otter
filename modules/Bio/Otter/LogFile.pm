
### Bio::Otter::LogFile

package Bio::Otter::LogFile;

use strict;
use warnings;
use Carp;

use POSIX ();
use IO::Handle;
use Log::Log4perl qw(:levels);

use Bio::Otter::Log::TieHandle;

my $logfile;

sub make_log {
    my ($file, $level, $config) = @_;
    confess "Already logging to '$logfile'" if $logfile;
    $logfile = $file;

    my $default_conf = qq(
      log4perl.rootLogger = $level, SafeScreen, Logfile

      log4perl.appender.SafeScreen                          = Bio::Otter::Log::Appender::SafeScreen
      log4perl.appender.SafeScreen.layout                   = Log::Log4perl::Layout::PatternLayout
      log4perl.appender.SafeScreen.layout.ConversionPattern = %m%n

      log4perl.appender.Logfile                          = Log::Log4perl::Appender::File
      log4perl.appender.Logfile.filename                 = $logfile
      log4perl.appender.Logfile.layout                   = Bio::Otter::Log::Layout::UseSrcTimestamp
      log4perl.appender.Logfile.layout.ConversionPattern = %d{yyyy-MM-dd HH:mm:ss,SSSS} %c %p: %m%n
      log4perl.appender.Logfile.layout.Debug             = 0
    );

    $config ||= \$default_conf;
    # TODO: Use Log::Log4perl::Config::PropertyConfigurator here, then set filename as necessary.
    Log::Log4perl->init($config);

    my $logger = Log::Log4perl->get_logger;
    $logger->info('In parent, pid ', $$);

    # Unbuffer STDOUT
    STDOUT->autoflush(1);

    if (my $pid = open(STDOUT, "|-")) {

        # Send parent's STDERR to the same place as STDOUT, for subprocesses.
        open STDERR, '>&', \*STDOUT or confess "Can't redirect STDERR to STDOUT";

        # Now for us in perl land, tie STDERR and STDOUT to Log4perl.

        tie *STDERR, 'Bio::Otter::Log::TieHandle',
            level => $WARN, category => "otter.stderr" or die "tie failed ($!)";

        tie *STDOUT, 'Bio::Otter::Log::TieHandle',
            level => $INFO, category => "otter.stdout" or die "tie failed ($!)";

        return $pid; ### Could write a rotate_logfile sub if we record the pid.

    } elsif (defined $pid) {

        $logger->info('In child, pid ', $$);

        my $child_logger = Log::Log4perl->get_logger('otter.children');

        while (<STDIN>) { ## no critic (InputOutput::ProhibitExplicitStdin)
            chomp;
            $child_logger->warn($_);
        }

        # close the output file & screen writer.  _exit does not flush.
        Log::Log4perl->eradicate_appender('Logfile');
        Log::Log4perl->eradicate_appender('SafeScreen');

        # Child must exit here.  Do not called outstanding DESTROY
        # methods (there should be none, but don't assume that)
        POSIX::_exit(0);

    } else {
        confess "Can't fork output filter: $!";
    }

    return (); # not reached
}

sub current_logfile {
    return $logfile;
}

1;

__END__

=head1 NAME - Bio::Otter::LogFile

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

