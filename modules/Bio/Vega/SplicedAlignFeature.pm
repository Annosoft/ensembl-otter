
### Bio::Vega::SplicedAlignFeature

package Bio::Vega::SplicedAlignFeature;

use strict;
use warnings;

no if $] >= 5.018, warnings => "experimental::smartmatch";
use feature 'switch';

use List::MoreUtils;
use Bio::Otter::Log::Log4perl 'logger';

use Bio::EnsEMBL::Exon;
use Bio::EnsEMBL::Intron;

use Bio::EnsEMBL::Utils::Argument qw(rearrange);
use Bio::EnsEMBL::Utils::Exception qw(throw);

use Bio::Otter::GappedAlignment;
use Bio::Otter::Utils::Constants qw(intron_minimum_length);
use Bio::Otter::Utils::FeatureSort qw( feature_sort );
use Bio::Otter::Vulgar;

use base 'Bio::EnsEMBL::BaseAlignFeature';

use Bio::Vega::Utils::EnsEMBL2GFF; # enrich base class

sub new {
    my ($caller, @args) = @_;
    my $class = ref($caller) || $caller;

    my $self;

    my @opts = qw(CIGAR_STRING   VULGAR_COMPS_STRING   VULGAR_STRING   VULGAR   FEATURES);
    my          ($cigar_string, $vulgar_comps_string, $vulgar_string, $vulgar, $features) = rearrange(\@opts, @args);

    my $count_args = 0;
    map { $count_args++ if $_ } ( $cigar_string, $vulgar_comps_string, $vulgar_string, $vulgar, $features );

    for ($count_args) {

        my @all_but_last = @opts;
        my $last_opt = pop @all_but_last;
        my $most_opts = join(', ', @all_but_last);

        when ($_ < 1) {
            throw("One of $most_opts or $last_opt argument is required");
        }

        when ($_ > 1) {
            throw("Only one of $most_opts and $last_opt arguments is permitted.");
        }

        when ($_ == 1) {

            if ($features) {

                # Delete -features from @args
                my $idx = List::MoreUtils::first_index { uc $_ eq '-FEATURES' } @args;
                splice(@args, $idx, 2);

                $self = $class->my_SUPER_new(@args, -cigar_string => 'M'); # dummy match, replaced by:
                $self->_parse_features($features);
            }

            if ($cigar_string) {
                $self = $class->my_SUPER_new(@args);
                $self->cigar_string($cigar_string);
            }

            my %from_vulgar;
            if ($vulgar_string) {
                $vulgar = Bio::Otter::Vulgar->new($vulgar_string);
                # drop through to process $vulgar...
            }

            if ($vulgar) {
                unless ($vulgar->isa('Bio::Otter::Vulgar')) {
                    my $actual = ref($vulgar);
                    throw("Feature must be a 'Bio::Otter::Vulgar' (not a '$actual')");
                }
                $vulgar_comps_string = $vulgar->align_comps_string;
                my ($t_start, $t_end, $t_strand) = $vulgar->target_ensembl_coords;
                my ($q_start, $q_end, $q_strand) = $vulgar->query_ensembl_coords;
                %from_vulgar = (
                    -seqname => $vulgar->target_id,
                    -start   => $t_start,
                    -end     => $t_end,
                    -strand  => $t_strand,
                    -hseqname => $vulgar->query_id,
                    -hstart   => $q_start,
                    -hend     => $q_end,
                    -hstrand  => $q_strand,
                    -score    => $vulgar->score,
                    );
                # drop through to process $vulgar_comps_string...
            }

            if ($vulgar_comps_string) {
                $self = $class->my_SUPER_new(@args, %from_vulgar, -cigar_string => 'M'); # dummy match, replaced by:
                $self->vulgar_comps_string($vulgar_comps_string);
            }

        }
    }

    delete $self->{cigar_string}; # replaced by alignment_string here
    return $self;
}

# Currently an alias for alignment_string
#
sub vulgar_comps_string {
    my ($self, @args) = @_;
    return $self->alignment_string(@args);
}

# Currently fixed as 'vulgar_exonerate_components'
#
sub alignment_type {
    return 'vulgar_exonerate_components';
}

sub alignment_string {
    my ($self, @args) = @_;
    ($self->{'alignment_string'}) = @args if @args;
    my $alignment_string = $self->{'alignment_string'};
    return $alignment_string;
}

# Currently read-only - any need for it to be read-write?
#
sub vulgar_string {
    my ($self) = @_;
    $self->_verify_attribs;
    my $gapped_alignment = $self->gapped_alignment;
    return $gapped_alignment->vulgar_string;
}

# Used by adaptors
#
sub check_fetch_alignment {
    my ($self) = @_;

    my $alignment_type = $self->alignment_type();
    unless ($alignment_type ) {
        throw( "SplicedAlignFeature does not define an alignment_type." );
    }
    if ( $alignment_type ne 'vulgar_exonerate_components' ) {
        throw( "alignment_type '$alignment_type' not supported." );
    }

    # This'll need to be pluggable if we support more than one alignment_type
    my $alignment_string = $self->alignment_string();
    unless ($alignment_string) {
        throw( "SplicedAlignFeature does not define an alignment_string." );
    }

    return ($alignment_type, $alignment_string);
}

sub cigar_string {
    my ($self, @args) = @_;
    my $cigar_string;
    if (@args) {
        ($cigar_string) = @args;
        my $vulgar_comps_string = $self->_cigar_to_vulgar_comps($cigar_string);
        $self->vulgar_comps_string($vulgar_comps_string);
    } else {
        $cigar_string = $self->_vulgar_comps_to_cigar;
    }
    return $cigar_string;
}

sub _parse_features {
    my ($self, $features) = @_;

    # FIXME: a lot of the sanity checks are duplicated from Bio::EnsEMBL::BaseAlignFeature :-(

    # Basic sanity checks
    #
    unless (ref($features) eq 'ARRAY') {
        my $actual = ref($features);
        throw("features must be an array reference (not a '$actual')");
    }
    unless (@$features) {
        throw("must supply at least one feature");
    }

    my $afc = $self->_align_feature_class;
    foreach my $feature ( @$features ) {
        unless ($feature->isa($afc)) {
            my $actual = ref($feature);
            throw("Feature must be a '$afc' (not a '$actual')");
        }
    }

    # Sort the features on their start position
    # Ascending order on positive strand, descending on negative strand
    #
    my $strand  = $features->[0]->strand  // 1;
    my $hstrand = $features->[0]->hstrand // 1;
    my $fwd     = ($strand  == 1);
    my $hfwd    = ($hstrand == 1);

    my @f;
    if ($fwd) {
        @f = sort {$a->start <=> $b->start} @$features;
    } else {
        @f = sort {$b->start <=> $a->start} @$features;
    }

    $self->_sanity_check_feature_list(\@f);

    # Now do the work

    # Set the basics from the first feature. Some will be overwritten later.
    #
    my $first_f = $f[0];
    foreach my $attrib ( $self->_our_attribs ) {
        $self->$attrib($first_f->$attrib());
    }

    if ($fwd) {
        $self->end($f[-1]->end);
    } else {
        $self->start($f[-1]->start);
    }

    if ($hfwd) {
        $self->hend($f[-1]->hend);
    } else {
        $self->hstart($f[-1]->hstart);
    }

    my @vulgar_comps_strings;
    my ($prev, $hprev);
    while (my $f = shift @f) {

        if (defined $prev) {

            my $gap_length =  ($fwd  ? $f->start  - $prev  : $prev  - $f->end)  - 1;
            my $hgap_length = ($hfwd ? $f->hstart - $hprev : $hprev - $f->hend) - 1;

            my @comps = $self->_process_gap($gap_length, $hgap_length);
            push @vulgar_comps_strings, @comps;

        }

        push @vulgar_comps_strings, $self->_cigar_to_vulgar_comps($f->cigar_string);

        $prev  = $fwd  ? $f->end  : $f->start;
        $hprev = $hfwd ? $f->hend : $f->hstart;
    }
    my $vcs = join(' ', @vulgar_comps_strings);
    $self->vulgar_comps_string($vcs);

    # For testing
    my $ga = $self->gapped_alignment;
    $ga->verify_element_lengths($ga);

    return $self;
}

sub _process_gap {
    my ($self, $gap_length, $hgap_length) = @_;

    my @comps_strings;

    my $gap_intronic = ($gap_length >= intron_minimum_length);

    if ($gap_intronic) {

        my $split_codon_gap;
        if ($self->looks_like_split_codon($gap_length, $hgap_length)) {

            $self->logger->warn("Skipping possible split codon [gap:${gap_length}, hgap:${hgap_length}]");
            $split_codon_gap = Bio::Otter::GappedAlignment::Element::Gap->new($hgap_length, 0)->string;

        } elsif ($hgap_length) {
            $self->logger->logconfess("Unexpected intron hgap [gap:${gap_length}, hgap:${hgap_length}]");
        }

        my $intron = Bio::Otter::GappedAlignment::Element::Intron->new(0, $gap_length);
        push @comps_strings, $intron->string;
        push @comps_strings, $split_codon_gap if $split_codon_gap;

    } else {

        if ($self->looks_like_frameshift($gap_length, $hgap_length)) {

            my $fs = Bio::Otter::GappedAlignment::Element::Frameshift->new(0, $gap_length);
            push @comps_strings, $fs->string;
            if ($hgap_length) {
                my $gap = Bio::Otter::GappedAlignment::Element::Gap->new($hgap_length, 0);
                push @comps_strings, $gap->string;
            }

        } else {

            # short gaps should be added as gaps, not introns

            # if on both sides, add target first? But for now...
            if ($gap_length and $hgap_length) {
                $self->logger->logconfess("Non-frameshift gaps both sides ",
                                          "[gap:${gap_length}, hgap:${hgap_length}]");
            }

            my $gap = Bio::Otter::GappedAlignment::Element::Gap->new($hgap_length, $gap_length);
            push @comps_strings, $gap->string;

        }
    }
    return @comps_strings;
}

sub _sanity_check_feature_list {
    my ($self, $features) = @_; # @$features is sorted at this point
    my $fwd  = (($features->[0]->strand // 1) == 1);

    # Sanity checks on subsequent features
    #
    my $first_f = $features->[0];
    my $prev  = $fwd ? $first_f->end : $first_f->start;

    for my $i ( 1 .. $#{$features} ) {
        my $this_f = $features->[$i];
        my $is_same = sub {
            # captures $first_f and $this_f in closure
            my ($what, $method) = @_;
            my $first = $first_f->$what(); my $first_d = defined ($first);
            my $this  = $this_f->$what();  my $this_d  = defined ($this);
            throw("Inconsistent ${what}s in feature array (def/undef)") if ($first_d xor $this_d);
            if ($first_d) {
                my $cmp_ok;
                if ($method eq 'string') {
                    $cmp_ok = ($first eq $this);
                } else {
                    $cmp_ok = ($first == $this);
                }
                throw("Inconsistent ${what}s in feature array") unless $cmp_ok;
            }
        };
        $is_same->('hstrand',    'numeric');
        $is_same->('strand',     'numeric');
        $is_same->('seqname',    'string' );
        $is_same->('hseqname',   'string' );
        $is_same->('score',      'numeric');
        $is_same->('percent_id', 'numeric');
        $is_same->('p_value',    'numeric');
        $is_same->('seqname',    'string' );

        if ($fwd) {
            my $start = $this_f->start;
            if ($start <= $prev) {
                throw("Inconsistent coords in feature array (forward strand):\n" .
                      "Start [$start] should be greater than previous end [$prev].");
            }
        } else {
            my $end = $this_f->end;
            if ($end >= $prev) {
                throw("Inconsistent coords in feature array (reverse strand):\n" .
                      "End [$end] should be less than previous start [$prev].");
            }
        }
    }
    return;
}

sub _cigar_to_vulgar_comps {
    my ($self, $cigar_string) = @_;

    # We could go via a GappedAlignment but that'd be slower, so:
    # Copied from Bio::EnsEMBL::BaseAlignFeature::_parse_cigar()

    my $query_unit = $self->_query_unit();
    my $hit_unit = $self->_hit_unit();

    my @vulgar_comps;

    my @pieces = ( $cigar_string =~ /(\d*[MDI])/g );
    foreach my $piece (@pieces) {

        my ($length) = ( $piece =~ /^(\d*)/ );
        if ($length eq "") { $length = 1 }
        my $mapped_length;

        # explicit if statements to avoid rounding problems
        # and make sure we have sane coordinate systems
        if ($query_unit == 1 && $hit_unit == 3) {
            $mapped_length = $length*3;
        } elsif ($query_unit == 3 && $hit_unit == 1) {
            $mapped_length = $length / 3;
        } elsif ($query_unit == 1 && $hit_unit == 1) {
            $mapped_length = $length;
        } else {
            throw("Internal error $query_unit $hit_unit, currently only " .
                  "allowing 1 or 3 ");
        }

        if (int($mapped_length) != $mapped_length and
            ($piece =~ /M$/ or $piece =~ /D$/)) {
            throw("Internal error with mismapped length of hit, query " .
                  "$query_unit, hit $hit_unit, length $length");
        }

        if (     $piece =~ /M$/) { # MATCH
            push @vulgar_comps, "M ${mapped_length} ${length}";
        } elsif ($piece =~ /I$/) { # INSERTION
            push @vulgar_comps, "G 0 ${length}";
        } elsif ($piece =~ /D$/) { # DELETION
            push @vulgar_comps, "G ${mapped_length} 0";
        } else {
            throw( "Illegal cigar line: '$cigar_string'" );
        }
    }

    return join(' ', @vulgar_comps);
}

sub _vulgar_comps_to_cigar {
    my ($self) = @_;

    my $gapped_alignment = $self->gapped_alignment;

    $self->logger->logcarp('Intron info will be lost in cigar string') if $gapped_alignment->has_introns;
    return $gapped_alignment->ensembl_cigar_string;
}

# These represent which attributes (named as for this module) are present
# in which component modules.

sub _vulgar_attribs {
    return qw(
        start  end  strand  seqname
        hstart hend hstrand hseqname
        score
        );
}

sub _ga_extra_attribs {
    return qw( percent_id );
}

sub _ga_attribs {
    my $self = shift;
    return ( $self->_vulgar_attribs, $self->_ga_extra_attribs );
}

sub _common_extra_attribs {
    return qw(
        slice
        species  coverage
        hspecies hcoverage
        p_value
        analysis external_db_id extra_data
        );
}

sub _common_attribs {
    my $self = shift;
    return ( $self->_ga_attribs, $self->_common_extra_attribs );
}

sub _our_attribs {
    my $self = shift;
    return ( $self->_common_attribs, $self->_extra_attribs );
}

# Warning: dangerous for proteins - doesn't cope with frameshifts and split codons
#
sub as_AlignFeature {
    my ($self) = @_;
    $self->_verify_attribs;

    my $class = $self->_align_feature_class; # inheritance work-around again.

    my %args = map { '-' . $_ => $self->$_() } $self->_our_attribs, 'cigar_string';
    my $align_feature = $class->new(%args);

    return $align_feature;
}

sub as_AlignFeatures {
    my ($self) = @_;

    $self->_verify_attribs;
    my $gapped_alignment = $self->gapped_alignment;
    my @afs = $gapped_alignment->vega_features;

    $self->_augment([ $self->_common_extra_attribs, $self->_extra_attribs ], @afs);
    return @afs;
}

sub _augment {
    my ($self, $attribs, @items) = @_;
    foreach my $item ( @items ) {
        foreach my $attrib ( @$attribs ) {
            $item->$attrib($self->$attrib());
        }
        $item->{_hit_description} = $self->{_hit_description}; # should really be proper attrib
    }
    return @items;
}

sub gapped_alignment {
    my ($self) = @_;

    # We could cache here, if we need to, but would have to invalidate assiduously.

    my $vulgar_comps = $self->vulgar_comps_string;
    my $gapped_alignment = Bio::Otter::GappedAlignment->from_vulgar_comps_string($vulgar_comps);

    my $start  = $self->start;
    my $end    = $self->end;
    my $strand = $self->strand // 1;
    $gapped_alignment->set_target_from_ensembl($start, $end, $strand);

    my $hstart  = $self->hstart;
    my $hend    = $self->hend;
    my $hstrand = $self->_hstrand_or_protein;
    $gapped_alignment->set_query_from_ensembl($hstart, $hend, $hstrand);

    $gapped_alignment->target_id($self->seqname);
    $gapped_alignment->query_id($self->hseqname);
    $gapped_alignment->score($self->score);
    $gapped_alignment->percent_id($self->percent_id);

    return $gapped_alignment;
}

sub _verify_attribs {
    my ($self) = @_;

    $self->start  // $self->logger->logcroak('start not set');
    $self->end    // $self->logger->logcroak('end not set');

    $self->hstart  // $self->logger->logcroak('hstart not set');
    $self->hend    // $self->logger->logcroak('hend not set');

    return;
}

sub get_all_exon_alignments {
    my ($self) = @_;

    $self->_verify_attribs;
    my $gapped_alignment = $self->gapped_alignment;
    my @egas = $gapped_alignment->exon_gapped_alignments;

    # FIXME: redo this as $self->new( -gapped_alignment => $_ )
    my @safs = map { $self->new( -vulgar_string => $_->vulgar_string ) } @egas;
    return $self->_augment( [ $self->_ga_extra_attribs, $self->_common_extra_attribs, $self->_extra_attribs ], @safs);
}

sub get_all_exons {
    my ($self) = @_;
    my @exon_alignments = $self->get_all_exon_alignments;
    return map { $_->as_exon } @exon_alignments;
}

sub get_all_introns {
    my ($self) = @_;
    my @exons = $self->get_all_exons;

    my $n_exons = scalar(@exons);
    return if $n_exons < 2;

    my @introns;
    for my $i ( 0 .. ($n_exons - 2) ) {
        my $intron = Bio::EnsEMBL::Intron->new($exons[$i], $exons[$i+1]);
        push @introns, $intron;
    }

    return @introns;
}

sub as_exon {
    my ($self) = @_;
    my %args = map { '-' . $_ => $self->$_() } qw( slice start end strand seqname phase end_phase dbID );
    my $exon = Bio::EnsEMBL::Exon->new(%args);
    return $exon;
}

sub ungapped_features {
    my ($self) = @_;
    my @exon_alignments = $self->get_all_exon_alignments;
    my @align_features = map { $_->as_AlignFeatures } @exon_alignments;
    my @ungapped_features = map { $_->ungapped_features } @align_features;
    return @ungapped_features;
}

# These two increase the pressure on caching gapped_alignment
#
sub phase {
    my ($self) = @_;
    my $gapped_alignment = $self->gapped_alignment;
    return $gapped_alignment->phase;
}

sub end_phase {
    my ($self) = @_;
    my $gapped_alignment = $self->gapped_alignment;
    return $gapped_alignment->end_phase;
}

# As does this
#
sub reverse_complement {
    my ($self) = @_;

    # reverse strand in both sequences
    $self->strand( ($self->strand  // 1) * -1);
    $self->hstrand(($self->hstrand // 1) * -1) unless $self->_hstrand_or_protein eq '.';

    $self->strands_reversed(not($self->strands_reversed));

    # reverse vulgar_comps_string as consequence
    my $reversed_alignment = $self->gapped_alignment->reverse_alignment;
    $self->vulgar_comps_string($reversed_alignment->vulgar_comps_string);

    return;
}

# Implemented in Protein subclass
sub looks_like_frameshift {
    return;
}

# Implemented in Protein subclass
sub looks_like_split_codon {
    return;
}

sub to_gff {
    my ($self, %args) = @_;

    # For now we process each unspliced feature separately.
    # This will change if we send vulgar strings.
    #
    my $gff = '';
    foreach my $af ( feature_sort $self->as_AlignFeatures) {
        $gff .= $af->to_gff(%args);
    }
    return $gff;
}


1;

__END__

=head1 NAME - Bio::Vega::SplicedAlignFeature

=head1 DESCRIPTION

Base class for Bio::Vega::SplicedAlignFeature::DNA and
Bio::Vega::SplicedAlignFeature::Protein.

Extends Bio::EnsEMBL::BaseAlignFeature.

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

