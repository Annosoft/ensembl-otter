package Bio::Otter::Log::Appender::SafeScreen;

use warnings;
use strict;

use Data::Dumper;

use Bio::Otter::Log::Log4perl;
use base qw(Log::Log4perl::Appender);

sub new {
    my($class, @options) = @_;

    my $self = {
        name   => "unknown name",
        @options,
    };

    open(my $stdout_copy, ">&STDOUT") or die "Can't dup STDOUT";
    $self->{handle} = $stdout_copy;

    bless $self, $class;
    return $self;
}

sub log {
    my($self, %params) = @_;

    $self->{handle}->print($params{message});
    return;
}

1;

__END__

=head1 NAME

Bio::Otter::Log::Appender::SafeScreen - log to a copy of STDOUT

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

=cut

# EOF
