
### Bio::Vega::Region::Ace

package Bio::Vega::Region::Ace;

use strict;
use warnings;
use Carp;

use Hum::Ace::AceText;
use Hum::Ace::Assembly;
use Hum::Ace::Clone;
use Hum::Ace::Exon;
use Hum::Ace::Locus;
use Hum::Ace::SubSeq;
use Hum::Ace::SeqFeature::Simple;

use Bio::Vega::Utils::ExonPhase                   'exon_phase_EnsEMBL_to_Ace';
use Bio::Vega::Utils::GeneTranscriptBiotypeStatus 'biotype_status2method';


sub new {
    my ($class, %args) = @_;
    my $self = bless {}, $class;
    return $self;
}


sub get_first_attrib_value {
    my ($obj, $attrib_code) = @_;

    if (my ($attrib) = @{$obj->get_all_Attributes($attrib_code)}) {
        return $attrib->value;
    } else {
        return;
    }
}

sub make_assembly_name {
    my ($self, $region) = @_;

    my $chr_slice = $region->slice;
    return sprintf "%s_%d-%d",
        $chr_slice->seq_region_name,
        $chr_slice->start,
        $chr_slice->end;
}

my %remark_handlers = (
    'method' => 'add_remark',
    );

my %contig_attrib_decoder = (

    'description'     => { 'method' => 'description' },

    'annotated'       => { 'cnd'    => sub { my ($value) = @_; return $value eq 'T'; },
                           'method' => 'add_remark',
                           'value'  => 'annotated',
    },
    'hidden_remark'   => \%remark_handlers,
    'remark'          => \%remark_handlers,

    'intl_clone_name' => { 'method' => 'clone_name' },

    'embl_acc'        => { 'method' => 'accession' },

    'embl_version'    => { 'method' => 'sequence_version' },

    ### Keywords should be turned off once they are
    ### automatically added to EMBL dumps from otter.
    'keyword'         => { 'method' => 'add_keyword' },

    );

sub _process_contig_attribs {
    my ($self, $clone_sequence, $clone) = @_;

    my $attrib_list = $clone_sequence->ContigInfo->get_all_Attributes();
    foreach my $at (@$attrib_list) {
        my ($code, $value) = ($at->code, $at->value);

        my $decoder = $contig_attrib_decoder{$code};
        unless ($decoder) {
            warn "Don't know how to handle contig attrib '$code'\n";
            next;
        };

        my $condition_sub = $decoder->{'cnd'};
        if ($condition_sub) {
            next unless $condition_sub->($value);
        }

        my $value_override = $decoder->{'value'};
        if ($value_override) {
            $value = $value_override;
        }
        next unless $value;

        my $method = $decoder->{'method'};
        $clone->$method($value);
    }
    return;
}


# ---------- build a Hum::Ace::Assembly from region, a la express_data_fetch ----------

sub make_assembly {
    my ($self, $region, $attrs) = @_;

    my $assembly = $self->_make_assembly($region, $attrs);
    $self->_add_simple_features($assembly, $region->seq_features);
    $self->_add_contigs(        $assembly, $region->sorted_clone_sequences);
    $self->_add_genes(          $assembly, $region->genes);
    return $assembly;
}

sub _make_assembly {
    my ($self, $region, $attrs) = @_;

    my $chr_slice = $region->slice;

    my $assembly = Hum::Ace::Assembly->new;
    if ($attrs) {
        foreach my $key ( keys %$attrs ) {
            $assembly->$key($attrs->{$key});
        }
    }
    $assembly->species($region->species);
    $assembly->name(         $self->make_assembly_name($region));
    $assembly->assembly_name($chr_slice->seq_region_name);

    $assembly->Sequence($self->_dna($region, $assembly->name));

    return $assembly;
}

sub _add_simple_features {
    my ($self, $assembly, @seq_features) = @_;

    # FIXME: dup with Hum::Ace::Assembly
    my $coll = $assembly->MethodCollection
      or confess "No MethodCollection attached";

    # We are only interested in the "editable" features on the Assembly.
    my %mutable_method =
      map { lc $_->name, $_ } $coll->get_all_mutable_non_transcript_Methods;

    my @simple_features;
    foreach my $feat (@seq_features) {

        my $type = $feat->analysis->logic_name;
        my $method = $mutable_method{lc $type}
          or next;

        my $ha_feat = Hum::Ace::SeqFeature::Simple->new;
        $ha_feat->seq_Sequence($assembly->Sequence);
        $ha_feat->seq_name(    $type);
        $ha_feat->Method(      $method);
        $ha_feat->seq_start(   $feat->start);
        $ha_feat->seq_end(     $feat->end);
        $ha_feat->seq_strand(  $feat->strand);
        $ha_feat->score(       $feat->score // 1);
        $ha_feat->text(        $feat->display_label);
        $ha_feat->ensembl_dbID($feat->dbID);

        push @simple_features, $ha_feat;
    }
    $assembly->set_SimpleFeature_list(@simple_features);

    return $assembly;
}

sub _dna {
    my ($self, $region, $name) = @_;

    my $dna = lc $region->slice->seq;

    my $seq = Hum::Sequence::DNA->new;
    $seq->name($name);
    $seq->sequence_string($dna);

    warn "Sequence '$name' is ", $seq->sequence_length, " long\n"; # FIXME: logger
    return $seq;
}

sub _add_contigs {
    my ($self, $assembly, @clone_sequences) = @_;

    # Duplication with Hum::Ace::Assembly->express_data_fetch()
    my %name_clone;
    my $chr_offset = $clone_sequences[0]->chr_start - 1;
    foreach my $cs (@clone_sequences) {
        my $start      = $cs->chr_start - $chr_offset;
        my $end        = $cs->chr_end   - $chr_offset;
        my $ctg_slice  = $cs->ContigInfo->slice;
        my $clone_name = $ctg_slice->seq_region_name;
        my $strand     = $ctg_slice->strand;

        if (my $clone = $name_clone{$clone_name}) {
            if ($clone->assembly_strand != $strand) {
                $clone->assembly_strand(0);
            }
            if ($start < $clone->assembly_start) {
                $clone->assembly_start($start);
            }
            if ($end > $clone->assembly_end) {
                $clone->assembly_end($end);
            }
        } else {
            $clone = Hum::Ace::Clone->new;

            $clone->name(            $clone_name);
            $clone->sequence_length( $cs->length);
            warn "Clone sequence '$clone_name' is '", $cs->length, "' bp long\n";

            $clone->assembly_start( $start);
            $clone->assembly_end(   $end);
            $clone->assembly_strand($strand);

            $self->_process_contig_attribs($cs, $clone);

            # Not sure whether we need this, but it allows for deep testing
            $clone->golden_start(1);
            $clone->golden_end($clone->sequence_length);

            $assembly->add_Clone($clone);

            $name_clone{$clone_name} = $clone;
        }
    }
    return $assembly;
}

sub _add_genes {
    my ($self, $assembly, @genes) = @_;

    # DUP Hum::Ace::Assembly->express_data_fetch
    my %name_method = map {$_->name, $_} $assembly->MethodCollection->get_all_transcript_Methods;

    foreach my $gene (@genes) {

        my $locus = Hum::Ace::Locus->new;
        $locus->name(get_first_attrib_value($gene, 'name'));
        $locus->ensembl_dbID($gene->dbID);

        unless ($gene->source eq 'havana') {
            $locus->gene_type_prefix($gene->source);
        }

        $locus->description( $gene->description);
        $locus->is_truncated($gene->truncated_flag) if $gene->truncated_flag;
        $locus->known(       $gene->is_known)       if $gene->is_known;
        $locus->otter_id(    $gene->stable_id);
        $locus->author_name( $gene->gene_author->name);

        $self->_add_attributes_to_HumAce($gene => 'synonym',       $locus => 'set_aliases');
        $self->_add_attributes_to_HumAce($gene => 'remark',        $locus => 'set_remarks');
        $self->_add_attributes_to_HumAce($gene => 'hidden_remark', $locus => 'set_annotation_remarks');

        foreach my $tsct (@{$gene->get_all_Transcripts}) {

            my $subseq = Hum::Ace::SubSeq->new;
            $subseq->name(get_first_attrib_value($tsct, 'name'));
            $subseq->ensembl_dbID($tsct->dbID);

            $subseq->Locus($locus);
            $subseq->clone_Sequence($assembly->Sequence);

            $subseq->author_name($tsct->transcript_author->name);
            $subseq->strand(     $tsct->strand);
            $subseq->otter_id(   $tsct->stable_id);

            my $translation = $tsct->translation;
            if ($translation) {
                $subseq->translation_region($translation->genomic_start, $translation->genomic_end);
                $subseq->translation_otter_id($translation->stable_id);
            }

            $self->_add_attributes_to_HumAce($tsct => 'remark',        $subseq => 'set_remarks');
            $self->_add_attributes_to_HumAce($tsct => 'hidden_remark', $subseq => 'set_annotation_remarks');

            foreach my $exon (@{$tsct->get_all_Exons}) {

                my $ha_exon = Hum::Ace::Exon->new;
                $ha_exon->ensembl_dbID($exon->dbID);

                $ha_exon->start(   $exon->start);
                $ha_exon->end(     $exon->end);
                $ha_exon->otter_id($exon->stable_id);

                $subseq->add_Exon($ha_exon);
            }

            # mRNA and CDS start not found tags
            if (get_first_attrib_value($tsct, 'cds_start_NF')) {

                $translation
                or confess sprintf("Transcript '%s' has 'CDS start not found' set, but does not have a Translation",
                                   $subseq->name);

                my $first_exon_phase = $translation->start_Exon->phase;

                my $ace_phase = exon_phase_EnsEMBL_to_Ace($first_exon_phase)
                or confess "No Ace phase for Ensembl exon phase '$first_exon_phase'";

                $subseq->start_not_found($ace_phase);
            }
            elsif (get_first_attrib_value($tsct, 'mRNA_start_NF')) {
                $subseq->utr_start_not_found(1);
            }

            # mRNA and CDS end not found tags
            if (get_first_attrib_value($tsct, 'cds_end_NF') or
                get_first_attrib_value($tsct, 'mRNA_end_NF'))
            {
                $subseq->end_not_found(1);
            }

            my $method_name = sprintf('%s%s',
                                      biotype_status2method($tsct->biotype, $tsct->status),
                                      $gene->truncated_flag ? '_trunc' : '');
            my $method = $name_method{$method_name};
            unless ($method) {
                confess "No transcript Method called '$method_name'";
            }
            $subseq->GeneMethod($method);

            # DUP Hum::Ace::SubSeq->process_ace_start_end_transcript_seq()
            my %evidence;
            foreach my $ev (@{$tsct->evidence_list}) {
                push @{$evidence{$ev->type}}, $ev->name;
            }
            foreach my $type (keys %evidence) {
                $subseq->add_evidence_list($type, $evidence{$type});
            }

            $assembly->add_SubSeq($subseq);
        }
    }

    return $assembly;
}

sub _add_attributes_to_HumAce {
    my ($self, $vega_obj, $attrib_code, $hum_obj, $hum_method) = @_;

    my @values = map { $_->value } @{$vega_obj->get_all_Attributes($attrib_code)};
    $hum_obj->$hum_method(@values);

    return;
}

1;

__END__

=head1 NAME - Bio::Vega::Region::Ace

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

