
### Bio::Otter::GappedAlignment

package Bio::Otter::GappedAlignment;

use strict;
use warnings;

use Bio::Otter::GappedAlignment::Element;

use Bio::EnsEMBL::DnaDnaAlignFeature;
use Bio::EnsEMBL::DnaPepAlignFeature;

use Log::Log4perl;
use Readonly;

Readonly our @SUGAR_ORDER => qw(
    _query_id
    _query_start
    _query_end
    _query_strand
    _target_id
    _target_start
    _target_end
    _target_strand
    _score
);

sub _new {
    my ($class, %sugar) = @_;

    my $pkg = ref($class) || $class;
    ## no critic (Anacode::ProhibitRebless)
    my $self = bless { %sugar }, $pkg;
    $self->_clear_elements;

    return $self;
}

sub _new_copy_basics {
    my $self = shift;

    ## no critic (Anacode::ProhibitRebless)
    my $new = bless { %$self }, ref($self);
    $new->_clear_elements;

    return $new;
}

sub from_vulgar {
    my ($pkg, $vulgar) = @_;

    my @vulgar_parts = split(' ', $vulgar);
    my (%sugar_result, @vulgar_comps);
    (@sugar_result{@SUGAR_ORDER}, @vulgar_comps) = @vulgar_parts;

    # FIXME: error handling on %sugar_result

    my $self = $pkg->_new(%sugar_result);

    while (@vulgar_comps) {
        my ($type, $q_len, $t_len) = splice(@vulgar_comps, 0, 3); # shift off 1st three
        unless ($type and defined $q_len and defined $t_len) {
            $self->logger->logdie("Ran out of vulgar components in mid-triplet");
        }
        my $element = Bio::Otter::GappedAlignment::Element->new($type, $q_len, $t_len);
        $self->add_element($element);
    }

    return $self;
}

=head2 intronify_by_transcript_exons

Insert introns into the alignment according to the exon boundaries in the supplied transcript.

=cut

sub intronify_by_transcript_exons {
    my ($self, $transcript) = @_;

    return unless @{$self->elements};

    $self->logger->logcroak('Already contains introns') if $self->has_introns;

    $self->logger->debug("Intronify for q:'", $self->query_id, "', t: '", $self->target_id, "'");
    $self->logger->debug("   vulgar comps: ", $self->vulgar_comps_string);

    my $intron_ga;

    if ($self->target_strand eq '-') {

        my $reversed = $self->reverse_alignment;
        $intron_ga = $reversed->_do_intronify($transcript);

        $intron_ga = $intron_ga->reverse_alignment;

    } else {
        $intron_ga = $self->_do_intronify($transcript);
    }

    return $intron_ga;
}

sub _do_intronify {
    my ($self, $transcript) = @_;

    my $ts_strand = $transcript->strand;

    $self->logger->debug("Considering transcript ", $transcript->start, " - ", $transcript->end,
                         " (", $ts_strand, ")\t[", ref($transcript), "]");
    $self->logger->debug("            alignment  ", $self->target_start+1, " - ", $self->target_end,
                         " (", $self->target_strand, ")");

    my @exons = $transcript->get_all_Exons_in_transcript_order;

    my %data;
    my $intron_ga;

    $data{elements}               = [ @{$self->elements} ];  # make a copy we can consume
    $data{intron_ga} = $intron_ga = $self->_new_copy_basics; # this is what we're building!

    $data{protein_query} = ($self->query_type eq 'P');

    # $data{offset} is offset between transcript in genomic or clone coords, and spliced transcript (cDNA)

    if ($ts_strand == 1) {
        $data{fwd} = 1;
        $data{offset} = $transcript->start - 1; # transcript is base 1
    } elsif ($ts_strand == -1) {
        $data{offset} = $transcript->end + 1;
        $intron_ga->swap_target_strand;
    } else {
        $self->logger->logcroak("Illegal transcript strand value '$ts_strand'");
    }

    $data{t_splice_pos} = $self->target_start+1; # current spliced target pos, base 1

    $self->_walk_exons(\@exons, \&_intronify_do_exon, \&_intronify_do_intron, \%data);

    $self->logger->debug("Done (offset $data{offset})");

    $self->_verify_lengths($intron_ga) if $self->logger->is_debug;

    return $intron_ga;
}

sub _walk_exons {
    my ($self, $exons, $exon_callback, $intron_callback, $data) = @_;

    my $prev_exon;

  EXON: foreach my $exon (@$exons) {

      if ($prev_exon) {

          my ($intron_start, $intron_end);
          if ($prev_exon->end < $exon->start) { # forward
              $intron_start = $prev_exon->end + 1;
              $intron_end   = $exon->start - 1;
          } else {                              # reverse
              $intron_start = $exon->end + 1;
              $intron_end   = $prev_exon->start - 1;
          }

          $self->logger->debug("Processing intron ", $intron_start, "-", $intron_end,
                               " len ", $intron_end - $intron_start + 1);

          $intron_callback->($self, $intron_start, $intron_end, $data);
      }
      $prev_exon = $exon;

      $self->logger->debug("Processing exon ", $exon->start, " - ", $exon->end, "\t(", ref($exon), ")");

      $exon_callback->($self, $exon, $data);

  } # EXON

    return;
}

sub _intronify_do_exon {
    my ($self, $exon, $data) = @_;

    my ($e_start, $e_end);
    if ($data->{fwd}) {
        $e_start = $exon->start - $data->{offset};
        $e_end   = $exon->end   - $data->{offset};
    } else {
        $e_start = $data->{offset} - $exon->end;
        $e_end   = $data->{offset} - $exon->start;
    }

    $self->logger->debug(" Moved to        ", $e_start,      " - ", $e_end, " (offset ", $data->{offset}, ")");
    $self->logger->debug(" CF t_splice     ", $data->{t_splice_pos}, " - ", $self->target_end, " :");

    if ($e_end   < $data->{t_splice_pos}) {
        $self->logger->debug("  not there yet");
        return;
    }
    if ($e_start > $self->target_end) {
        $self->logger->debug("  beyond");
        return;
    }

    $self->logger->debug("  in alignment");

    my $intron_ga = $data->{intron_ga};

    my $t_split_pos;
    if ($data->{fwd}) {
        $t_split_pos = $data->{t_splice_pos} + $data->{offset} - 1;
    } else {
        $t_split_pos = $data->{offset} - $data->{t_splice_pos};
    }

    unless ($data->{in_alignment}) {
        # First time in
        $data->{in_alignment} = 1;
        $intron_ga->target_start($t_split_pos);
        # $intron_ga->query_start unchanged
        $intron_ga->target_end($intron_ga->target_start); # will be updated by add_element_track_lengths()
        $intron_ga->query_end( $intron_ga->query_start ); # --"--
        $data->{query_pos} = $self->query_start;
    }

  ELEMENTS: while (my $ele = shift @{$data->{elements}}) {

      $self->logger->debug("Considering: ", $ele->string);

      if ($ele->is_intronic) {
          $self->logger->logcroak(sprintf 'Alignment already contains intronic element (%s)', $ele->string);
      }

      my $overlap = $e_end - $data->{t_splice_pos} + 1;

      if ($ele->target_length <= $overlap) {

          # Whole ele fits in exon, add a copy
          $self->logger->debug("Adding whole element");

          $intron_ga->add_element_track_lengths($ele->make_copy);
          $data->{t_splice_pos} += $ele->target_length;
          $data->{query_pos}    += $ele->query_length * $intron_ga->query_strand_sense;

      } elsif ($overlap > 0) {

          # Time to split an element
          # ...do splitting, put remainder back
          $self->logger->debug("Adding ", $overlap, " of ", $ele->target_length);

          my ($in_exon_eles, $remaining_eles) = $ele->divide($overlap, $data->{protein_query});

          foreach my $ele (@{$in_exon_eles}) {
              $intron_ga->add_element_track_lengths($ele);

              $data->{t_splice_pos} += $ele->target_length;
              $data->{query_pos}    += $ele->query_length * $intron_ga->query_strand_sense;
          }
          unshift @{$data->{elements}}, @{$remaining_eles};

          last ELEMENTS;

      } else {
          # Put whole element back for next time
          unshift @{$data->{elements}}, $ele;
          last ELEMENTS;
      }

  } # ELEMENTS

    $self->logger->debug("Have alignment: ", $intron_ga->vulgar_comps_string);

    if ($data->{in_alignment} and not @{$data->{elements}}) {
        $self->logger->debug("Ran out of elements so no longer in alignment");
        $data->{in_alignment} = 0;
    }

    return;
}

sub _intronify_do_intron {
    my ($self, $start, $end, $data) = @_;

    my $length = $end - $start + 1;

    if ($data->{fwd}) {
        $data->{offset} += $length;
    } else {
        $data->{offset} -= $length;
    }

    if ($data->{in_alignment}) {
        my $intron = Bio::Otter::GappedAlignment::Element::Intron->new(0, $length);
        $data->{intron_ga}->add_element_track_lengths($intron);
    }

    return;
}

sub vulgar_comps_string {
    my $self = shift;
    return unless $self->n_elements;

    my @ele_strings = map { $_->string } @{$self->elements};
    return join(' ', @ele_strings);
}

sub vulgar_string {
    my $self = shift;
    return unless $self->n_elements;

    return sprintf('%s %d %d %s %s %d %d %s %d %s',
                   $self->query_id,  $self->query_start,  $self->query_end,  $self->query_strand,
                   $self->target_id, $self->target_start, $self->target_end, $self->target_strand,
                   $self->score,
                   $self->vulgar_comps_string);
}

sub _coalesce_cigar_strings {
    my ($self, $ele_type_sub, $ele_format_sub) = @_;

    my @elements = ( @{$self->elements} ); # make a copy to consume
    my @ele_strings;
    while (my $this_ele = shift @elements) {
        my $length = $this_ele->cigar_length;
        my $next_ele;
        while (     $next_ele = $elements[0]
                and $ele_type_sub->($this_ele) eq $ele_type_sub->($next_ele) )
        {
            $length += $next_ele->cigar_length; # combine
            shift @elements;                    # and discard
        }
        my $cigar_string = $ele_format_sub->($this_ele, $length, $self);
        push @ele_strings, $cigar_string;
    }
    return @ele_strings;
}

sub ensembl_cigar_string {
    my $self = shift;
    return unless $self->n_elements;

    my @ele_strings = $self->_coalesce_cigar_strings(
        sub { return shift->ensembl_cigar_type; },
        sub {
            my ($ele, $length, $ga) = @_;
            my $type = $ele->ensembl_cigar_type;
            if (   ($type eq 'D' and $ga->query_type eq 'P' and $ga->target_type ne 'P')
                or ($type eq 'I' and $ga->query_type ne 'P' and $ga->target_type eq 'P') )
            {
                $length *= 3;   # peptide -> nucleotide
            }
            return ($length > 1 ? $length : '') . $type;
        },
        );
    return join('', @ele_strings);
}

sub exonerate_cigar_string {
    my $self = shift;
    return unless $self->n_elements;

    my @ele_strings = $self->_coalesce_cigar_strings(
        sub { return shift->cigar_type; },
        sub { my ($ele, $length) = @_; return $ele->cigar_type . ' ' . $length; },
        );
    return join(' ', @ele_strings);
}

# Should these ensembl_* methods be mixed in via a separate module, rather than embedded?
#
sub ensembl_features {
    my $self = shift;
    return unless $self->n_elements;

    my @egas = $self->exon_gapped_alignments;
    return unless @egas;

    @egas = map { $_->_split_at_frameshifts } @egas;

    my @ensembl_features;
    foreach my $ega (@egas) {
        next unless $ega;
        push @ensembl_features, $ega->_strip_for_ensembl->ensembl_feature;
    }

    return @ensembl_features;
}

sub ensembl_feature {
    my $self = shift;
    return unless $self->n_elements;

    my ($t_start, $t_end, $t_strand) = $self->target_ensembl_coords;
    my ($q_start, $q_end, $q_strand) = $self->query_ensembl_coords;

    my $af_type = $self->query_type eq 'P' ? 'Bio::EnsEMBL::DnaPepAlignFeature' : 'Bio::EnsEMBL::DnaDnaAlignFeature';

    return $af_type->new(
        -seqname      => $self->target_id,
        -start        => $t_start,
        -end          => $t_end,
        -strand       => $t_strand,
        -hseqname     => $self->query_id,
        -hstart       => $q_start,
        -hend         => $q_end,
        -hstrand      => $q_strand,
        -score        => $self->score,
        -percent_id   => $self->percent_id,
        -cigar_string => $self->ensembl_cigar_string,
        );
}

sub _split_at_frameshifts {
    my $self = shift;
    my @elements = @{$self->elements};
    return $self unless grep { $_->type eq 'F' } @elements;

    my $target_pos = $self->target_start;
    my $query_pos  = $self->query_start;

    my @splits;
    my $current;

    while (my $ele = shift @elements) {
        if ($ele->type eq 'F') {
            if ($current) {
                push @splits, $current;
                $current = undef;
            }
        } else {
            unless ($current) {
                $current = $self->_new_copy_basics;
                $current->target_start($target_pos);
                $current->query_start( $query_pos);
                $current->target_end($target_pos); # will be updated by add_element_track_lengths()
                $current->query_end( $query_pos);  # --"--
            }
            $current->add_element_track_lengths($ele);
        }
        $target_pos += $self->target_strand_sense * $ele->target_length;
        $query_pos  += $self->query_strand_sense  * $ele->query_length;
    }
    push @splits, $current if $current;

    return @splits;
}

# Remove split codons (which will be at ends) and leading or trailing indels
#
sub _strip_for_ensembl {
    my $self = shift;

    my $stripped = $self->_new_copy_basics;
    my $elements = $stripped->{_elements} = [ @{$self->elements} ];

    # Should these strip repeatedly in a while loop?

    if ($elements->[0] and ($elements->[0]->type eq 'S' or $elements->[0]->type eq 'G')) {
        my $sc = shift(@$elements);
        $stripped->target_start($self->target_start + $self->target_strand_sense * $sc->target_length);
        $stripped->query_start( $self->query_start  + $self->query_strand_sense  * $sc->query_length);
    }

    if ($elements->[-1] and ($elements->[-1]->type eq 'S' or $elements->[-1]->type eq 'G')) {
        my $sc = pop(@$elements);
        $stripped->target_end($self->target_end - $self->target_strand_sense * $sc->target_length);
        $stripped->query_end( $self->query_end  - $self->query_strand_sense  * $sc->query_length);
    }

    return $stripped;
}

sub reverse_alignment {
    my $self = shift;

    my $reversed = $self->_new_copy_basics;
    $reversed->swap_query_strand;
    $reversed->swap_target_strand;
    $reversed->swap_gene_orientation;
    $reversed->{_elements} = [ reverse @{$self->elements} ];

    return $reversed;
}

# FIXME: which of these should be r/w vs r/o ?

sub query_id {
    my ($self, $query_id) = @_;
    if ($query_id) {
        $self->{'_query_id'} = $query_id;
    }
    return $self->{'_query_id'};
}

sub query_start {
    my ($self, $query_start) = @_;
    if (defined $query_start) {
        $self->{'_query_start'} = $query_start;
    }
    return $self->{'_query_start'};
}

sub query_end {
    my ($self, $query_end) = @_;
    if (defined $query_end) {
        $self->{'_query_end'} = $query_end;
    }
    return $self->{'_query_end'};
}

sub query_strand {
    my ($self, $query_strand) = @_;
    return $self->_strand($query_strand, '_query_strand');
}

sub _strand {
    my ($self, $value, $key) = @_;
    if ($value) {
        unless ($value =~ /^[+-]$/) {
            if ($value == 1) {
                $value = '+';
            } elsif ($value == -1) {
                $value = '-';
            } else {
                $self->logger->logcroak("strand '$value' not valid");
            }
        }
        $self->{$key} = $value;
    }
    return $self->{$key};
}

sub query_strand_sense {
    my $self = shift;
    return $self->_strand_sense('query_strand');
}

sub _strand_sense { ## no critic (Subroutines::RequireFinalReturn)
    my ($self, $accessor) = @_;
    my $strand = $self->$accessor;
    return if not defined $strand;

    if ($strand eq '+' or $strand eq '.') {
        return 1;
    } elsif ($strand eq '-') {
        return -1;
    } else {
        $self->logger->logcroak("$accessor not '+', '-' or '.'");
    }
}

sub query_type {
    my $self = shift;
    return $self->_type('query_strand');
}

sub _type {
    my ($self, $accessor) = @_;
    my $strand = $self->$accessor;
    return if not defined $strand;

    if ($strand eq '+' or $strand eq '-') {
        return 'N';
    } elsif ($strand eq '.') {
        return 'P';
    } else {
        $self->logger->logcroak("$accessor not '+', '-' or '.'");
    }
    return;                     # redundant but keeps perlcritic happy
}

sub query_length {
    my $self = shift;
    return $self->_length($self->query_start, $self->query_end);
}

sub _length {
    my ($self, $start, $end) = @_;
    return abs($end - $start);
}

sub target_ensembl_coords {
    my $self = shift;
    return $self->_ensembl_coords('target');
}

sub query_ensembl_coords {
    my $self = shift;
    return $self->_ensembl_coords('query');
}

sub _ensembl_coords {
    my ($self, $which) = @_;

    my ($start_acc, $end_acc, $ss_acc) = map { $which . $_ } qw( _start _end _strand_sense );
    my @coords = sort { $a <=> $b } ($self->$start_acc, $self->$end_acc);
    my $strand = $self->$ss_acc;

    return $coords[0]+1, $coords[1], $strand;
}

sub target_id {
    my ($self, $target_id) = @_;
    if ($target_id) {
        $self->{'_target_id'} = $target_id;
    }
    return $self->{'_target_id'};
}

sub target_start {
    my ($self, $target_start) = @_;
    if (defined $target_start) {
        $self->{'_target_start'} = $target_start;
    }
    return $self->{'_target_start'};
}

sub target_end {
    my ($self, $target_end) = @_;
    if (defined $target_end) {
        $self->{'_target_end'} = $target_end;
    }
    return $self->{'_target_end'};
}

sub target_strand {
    my ($self, $target_strand) = @_;
    return $self->_strand($target_strand, '_target_strand');
}

sub target_strand_sense {
    my $self = shift;
    return $self->_strand_sense('target_strand');
}

sub target_type {
    my $self = shift;
    return $self->_type('target_strand');
}

sub target_length {
    my $self = shift;
    return $self->_length($self->target_start, $self->target_end);
}

sub swap_query_strand {
    my $self = shift;
    my $sense = $self->query_strand_sense;
    $sense *= -1;
    if (   ($sense > 0 and $self->query_start > $self->query_end)
        or ($sense < 0 and $self->query_start < $self->query_end)) {
        # Swap start and end coords
        my $tmp = $self->query_start;
        $self->query_start($self->query_end);
        $self->query_end($tmp);
    }
    return $self->query_strand($sense);
}

sub swap_target_strand {
    my $self = shift;
    my $sense = $self->target_strand_sense;
    $sense *= -1;
    if (   ($sense > 0 and $self->target_start > $self->target_end)
        or ($sense < 0 and $self->target_start < $self->target_end)) {
        # Swap start and end coords
        my $tmp = $self->target_start;
        $self->target_start($self->target_end);
        $self->target_end($tmp);
    }
    return $self->target_strand($sense);
}

sub swap_gene_orientation {
    my $self = shift;
    return unless defined $self->gene_orientation;
    return if $self->gene_orientation eq '.';
    my $sense = $self->_strand_sense('gene_orientation');
    return $self->_strand($sense * -1, '_gene_orientation');
}

sub score {
    my ($self, $score) = @_;
    if (defined $score) {
        $self->{'_score'} = $score;
    }
    return $self->{'_score'};
}

sub percent_id {
    my ($self, $percent_id) = @_;
    if (defined $percent_id) {
        $self->{'_percent_id'} = $percent_id;
    }
    return $self->{'_percent_id'};
}

sub gene_orientation {
    my ($self, $gene_orientation) = @_;
    if (defined $gene_orientation) {
        $self->{'_gene_orientation'} = $gene_orientation;
    }
    return $self->{'_gene_orientation'};
}

sub elements {
    my $self = shift;
    return $self->{'_elements'};
}

sub add_element {
    my ($self, $element) = @_;
    push @{$self->elements}, $element;
    $self->_set_has_introns if $element->is_intronic;
    return $self->elements;
}

sub add_element_track_lengths {
    my ($self, $element) = @_;

    $self->add_element($element);

    $self->target_end($self->target_end + $self->target_strand_sense * $element->target_length);
    $self->query_end( $self->query_end  + $self->query_strand_sense  * $element->query_length);

    return $self->elements;
}

sub n_elements {
    my $self = shift;
    return scalar @{$self->elements};
}

sub _clear_elements {
    my $self = shift;
    return $self->{'_elements'} = [];
}

sub has_introns {
    my $self = shift;
    return $self->{_has_introns};
}

sub _set_has_introns {
    my $self = shift;
    return $self->{_has_introns} = 1;
}

sub exon_gapped_alignments {
    my ($self, $include_unmatched_introns) = @_;

    my $egas = $self->{_exon_gapped_alignments};

    if (not($egas) or ($self->vulgar_string ne $self->{_ega_fingerprint})) {
        $egas = $self->_generate_exon_gapped_alignments;
    }

    return ( @$egas ) if $include_unmatched_introns;

    my @filtered;
    foreach my $exon ( @$egas ) {
        push @filtered, $exon if $exon;
    }
    return @filtered;
}

sub _generate_exon_gapped_alignments {
    my $self = shift;

    my @egas;

    my $exon_ga;
    my $state = 'idle';
    my $q_pos = $self->query_start;
    my $t_pos = $self->target_start;

    foreach my $ele (@{$self->elements}) {

        if ($ele->is_intronic) {

            if ($state eq 'exon') {
                push @egas, $exon_ga;
                $exon_ga = undef;
            }
            $state = 'intron';

        } else {

            unless ($state eq 'exon') {
                $exon_ga = $self->_new_copy_basics; # note this naively copies score, percent_id, hcoverage, etc.
                $exon_ga->target_start($t_pos);
                $exon_ga->query_start($q_pos);
                $exon_ga->target_end($exon_ga->target_start); # will be updated by add_element_track_lengths()
                $exon_ga->query_end( $exon_ga->query_start ); # --"--
            }
            $state = 'exon';
            $exon_ga->add_element_track_lengths($ele->make_copy);
        }

        $q_pos += $self->query_strand_sense  * $ele->query_length;
        $t_pos += $self->target_strand_sense * $ele->target_length;

    }

    if ($state eq 'exon') {
        # Last one
        push @egas, $exon_ga;
    }
    return $self->_set_exon_gapped_alignments(\@egas);
}

sub _set_exon_gapped_alignments {
    my ($self, $egas) = @_;
    $self->{_ega_fingerprint} = $self->vulgar_string;
    return $self->{_exon_gapped_alignments} = $egas;
}

sub _verify_lengths {
    my ($self, $intron_ga) = @_;
    my ($q_len, $t_len) = (0, 0);
    foreach my $ega ($intron_ga->exon_gapped_alignments) {
        $q_len += $ega->query_length;
        $t_len += $ega->target_length;
    }
    if ($q_len != $self->query_length or $t_len != $self->target_length) {
        $self->logger->fatal("sum(q_len): $q_len vs q_len: ", $self->query_length)  if $q_len != $self->query_length;
        $self->logger->fatal("sum(t_len): $t_len vs t_len: ", $self->target_length) if $t_len != $self->target_length;
        $self->logger->confess('Intronify length mismatch');
    }
    $self->logger->debug('Lengths ok');
    return;
}

sub logger {
    return Log::Log4perl->get_logger;
}

1;

__END__

=head1 NAME - Bio::Otter::GappedAlignment

NB Coordinates are in exonerate 'in-between' system, see:
http://www.ebi.ac.uk/~guy/exonerate/exonerate.man.html

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

# EOF
