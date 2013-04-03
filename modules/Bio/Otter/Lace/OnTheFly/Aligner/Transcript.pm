package Bio::Otter::Lace::OnTheFly::Aligner::Transcript;

## Moose provides these, but webpublish doesn't know that!
##
use strict;
use warnings;
##

use namespace::autoclean;
use Moose;

extends 'Bio::Otter::Lace::OnTheFly::Aligner';

has transcript => ( is => 'ro', isa => 'Hum::Ace::SubSeq', required => 1 );

augment '_build_default_options'    => sub { return { } };
augment '_build_default_qt_options' => sub {
    return {
        protein => { '--model' => 'protein2dna',  '--exhaustive' => undef },
        dna     => { '--model' => 'affine:local', '--exhaustive' => undef },
    };
};

around 'parse' => sub {
    my ($orig, $self, @args) = @_;

    my $basic = $self->$orig(@args);

    foreach my $query ( $basic->query_ids ) {
        my $split = $self->_split_alignment($basic->by_query_id($query));
    }

    return $basic;              # temporary
};

sub _split_alignment {
    my ($self, $gapped_alignments) = @_;
    my $ga = $gapped_alignments->[0];

    if (scalar(@{$gapped_alignments}) > 1) {
        $self->log->warn(sprintf("More than one gapped alignment for '%s', using first.", $ga->query_id));
    }

    return $ga->intronify_by_transcript_exons($self->transcript)->exon_gapped_alignments;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

# EOF
