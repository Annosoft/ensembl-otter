
### Bio::Otter::GappedAlignment::Element::GapT

package Bio::Otter::GappedAlignment::Element::GapT;

use strict;
use warnings;

use base 'Bio::Otter::GappedAlignment::ElementI';

sub cigar_type {
    my $self = shift;
    if ($self->target_length) {
        return 'D';
    } elsif ($self->query_length) {
        return 'I';
    } else {
        $self->logger->logconfess('Neither of target_length and query_length is non-zero');
    }
}

# At least as far as we're concerned, ensembl do things the wrong way round
#
sub ensembl_cigar_type {
    my $self = shift;
    my $ct = $self->cigar_type;
    return $ct eq 'D' ? 'I' : 'D'; # swap D's and I's
}

sub validate {
    my $self = shift;
    ($self->query_length xor $self->target_length)
        or $self->logger->logconfess("one of query_length or target_length must be 0");
    return;
}

1;

__END__

=head1 NAME - Bio::Otter::GappedAlignment::Element::Match

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

# EOF
