
### Bio::Otter::GappedAlignment::Element::MatchT

package Bio::Otter::GappedAlignment::Element::MatchT;

use strict;
use warnings;

use base 'Bio::Otter::GappedAlignment::ElementI';

sub validate {
    my $self = shift;
    ($self->query_length and $self->target_length)
        or $self->logger->logconfess("query_length and target_length must be > 0");
    return;
}

sub cigar_type {
    return 'M';
}

sub is_match {
    return 1;
}

1;

__END__

=head1 NAME - Bio::Otter::GappedAlignment::Element::Match

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

# EOF
