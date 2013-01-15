package Bio::Otter::Lace::OnTheFly::Ace;

## Moose provides these, but webpublish doesn't know that!
##
use strict;
use warnings;
##

use namespace::autoclean;

# Designed to mix in with Bio::Otter::Lace::OnTheFly::ResultSet
#
use Moose::Role;

with 'MooseX::Log::Log4perl';

use Bio::Otter::Utils::FeatureSort qw( feature_sort );

requires 'analysis_name';
requires 'by_query_id';
requires 'query_ids';
requires 'query_seq_by_name';
requires 'target';
requires 'type';

sub ace {
    my $self = shift;

    my $contig_name = $self->target->name;

    unless ($self->query_ids) {
        $self->logger->warn("No hits found on '$contig_name'");
        return;
    }

    my $is_protein = ($self->type =~ /protein/i);

    my $method_tag  = $self->analysis_name;
    my $acedb_homol_tag = $method_tag . '_homol';
    my $hit_homol_tag = 'DNA_homol';

    my $offset = $self->target->start - 1;

    my $ace = '';

    foreach my $hname (sort $self->query_ids) {

        my $prefix = $is_protein ? 'Protein' : 'Sequence';

        $ace       .= qq{\nSequence : "$contig_name"\n};
        my $hit_length = $self->query_seq_by_name($hname)->sequence_length;
        my $hit_ace = qq{\n$prefix : "$hname"\nLength $hit_length\n};

        foreach my $ga (sort {
                $a->target_start <=> $b->target_start
                ||
                $a->query_start  <=> $b->query_start
                        } @{ $self->by_query_id($hname) }) {

            foreach my $fp ( feature_sort $ga->ensembl_features ) {

                # In acedb strand is encoded by start being greater
                # than end if the feature is on the negative strand.
                my $strand  = $fp->strand;
                my $start   = $fp->start + $offset;
                my $end     = $fp->end + $offset;
                my $hstart  = $fp->hstart;
                my $hend    = $fp->hend;
                my $hstrand = $fp->hstrand;

                if ($hstrand ==-1){
                    $self->logger->debug('Hit on reverse strand: swapping strands for ', $hname);
                    $fp->reverse_complement;
                    $hstrand = $fp->hstrand;
                    $strand  = $fp->strand;
                }

                if ($strand == -1){
                    ($start, $end) = ($end, $start);
                }

                # Show coords in hit back to genomic sequence. (The annotators like this.)
                $hit_ace .=
                    sprintf qq{Homol %s "%s" "%s" %.3f %d %d %d %d\n},
                    $hit_homol_tag, $contig_name, $method_tag, $fp->percent_id,
                    $hstart, $hend, $start, $end;

                # The first part of the line is all we need if there are no
                # gaps in the alignment between genomic sequence and hit.
                my $query_line =
                    sprintf qq{Homol %s "%s" "%s" %.3f %d %d %d %d},
                    $acedb_homol_tag, $hname, $method_tag, $fp->percent_id,
                    $start, $end, $hstart, $hend;

                my @ugfs = $fp->ungapped_features;
                if (@ugfs > 1) {
                    # Gapped alignments need two or more Align blocks to describe
                    # them. The information at the start of the line is needed for
                    # each block so that they all end up under the same tag once
                    # they are parsed into acedb.
                    foreach my $ugf (@ugfs){
                        my $ref_coord   = ($strand  == -1 ? $ugf->end  : $ugf->start) + $offset;
                        my $match_coord = $hstrand == -1 ? $ugf->hend : $ugf->hstart;
                        my $length      = ($ugf->hend - $ugf->hstart) + 1;
                        $ace .=
                            $query_line
                            . ($is_protein ? " AlignDNAPep" : " Align")
                            . " $ref_coord $match_coord $length\n";
                    }
                } else {
                    $ace .= $query_line . "\n";
                }
            }
        }

        $ace .= $hit_ace;
    }

    return $ace;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

# EOF
