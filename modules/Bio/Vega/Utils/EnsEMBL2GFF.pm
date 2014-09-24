### Bio::Vega::Utils::EnsEMBL2GFF

package Bio::Vega::Utils::EnsEMBL2GFF;

use strict;
use warnings;

use Try::Tiny;

use Bio::EnsEMBL::Utils::Exception qw(verbose);

# This module allows conversion of ensembl/otter objects to GFF by
# inserting to_gff (and supporting _gff_hash) methods into the
# necessary feature classes

my $_feature_id = 0;

# an anonymous sub in a lexical variable is easy to call from other packages
my $_new_feature_id_sub = sub {
    my ($prefix) = @_;
    $_feature_id++;
    my $feature_id = sprintf "%s_%06d", $prefix, $_feature_id;
    return $feature_id;
};

## no critic (Modules::ProhibitMultiplePackages)

{

    package Bio::EnsEMBL::Feature;

    sub to_gff {
        my ($self, %args) = @_;
        my $gff = $self->_gff_hash(%args);
        my $gff_str = $self->_gff_hash_to_gff($gff, \%args);
        return $gff_str;
    }

    sub _gff_hash {
        my ($self, %args) = @_;

        my $gff_seqname = $args{'gff_seqname'} || $self->slice->seq_region_name;
        my $gff_source  = $args{'gff_source'} || $self->_gff_source;
        my $gff_feature = $args{'gff_feature'} || $self->_gff_feature;

        my $gff = {
            seqname => $gff_seqname,
            source  => $gff_source,
            feature => $gff_feature,
            start   => $self->seq_region_start,
            end     => $self->seq_region_end,
            strand  => $self->strand,
        };

        return $gff;
    }

    sub _gff_hash_to_gff {
        my ($self, $gff, $args) = @_;

        if (my $extra_attrs = $args->{'extra_attrs'}) {
            $gff->{'attributes'} = {} unless defined $gff->{'attributes'};
            @{ $gff->{'attributes'} }{ keys %$extra_attrs } = values %$extra_attrs;
        }

        my $gff_format = $args->{'gff_format'};
        my $gff_str =
            $gff_format->gff_line(
                @{$gff}{qw( seqname source feature start end score strand phase attributes )},
                $args);

        return $gff_str;
    }

    sub _gff_source {
        my ($self) = @_;

        if ($self->analysis) {
            return $self->analysis->gff_source
                || $self->analysis->logic_name;
        }
        else {
            return ref($self);
        }
    }

    sub _gff_feature {
        my $feature = 'sequence_feature';
        return $feature;
    }
}

{

    package Bio::EnsEMBL::SimpleFeature;

    sub _gff_hash {
        my ($self, @args) = @_;

        my $gff = $self->SUPER::_gff_hash(@args);

        $gff->{'score'}   = $self->score;

        $gff->{'attributes'}{'Name'} =
            $self->display_label ||
            $self->analysis->logic_name;

        return $gff;
    }
}

{

    package Bio::EnsEMBL::MiscFeature;

    sub _gff_hash {
        my ($self, @args) = @_;

        my $gff = $self->SUPER::_gff_hash(@args);

        # display_id() looks for a 'name' attribute
        #
        $gff->{'attributes'}{'Name'} =
            $self->display_id ||
            $self->analysis->logic_name;

        # This relies on us setting a note attribute
        #
        my $descs = $self->get_all_attribute_values('note');
        if ($descs and @$descs) {
            $gff->{'attributes'}{'Note'} = join ',', @$descs;
        }

        my $url = $self->get_all_attribute_values('url');
        if ($url and $url->[0]) {
            $gff->{'attributes'}{'url'} = $url->[0];
        }

        return $gff;
    }
}

{

    package Bio::EnsEMBL::FeaturePair;

    sub _gff_hash {
        my ($self, %args) = @_;

        my $gff = $self->SUPER::_gff_hash(%args);

        $gff->{'score'} = $self->score;
        my $name = $self->hseqname;
        $gff->{'attributes'}{'Name'} = $name;
        my $target = [ $name, $self->hstart, $self->hend, $self->hstrand ];
        $gff->{'attributes'}{'Target'}    = $target;
        $gff->{'attributes'}{'percentID'} = $self->percent_id;

        return $gff;
    }

    sub _gff_feature {
        my $feature = 'match';
        return $feature;
    }
}

{

    package Bio::EnsEMBL::BaseAlignFeature;

    sub _gff_hash {
        my ($self, %args) = @_;

        my $gff = $self->SUPER::_gff_hash(%args);
        $gff->{'attributes'}{'cigar_ensembl'} = $self->cigar_string;
        return $gff;
    }
}

{

    package Bio::EnsEMBL::DnaPepAlignFeature;

    sub _gff_feature {
        my $feature = 'protein_match';
        return $feature;
    }
}

{

    package Bio::EnsEMBL::DnaDnaAlignFeature;

    sub _gff_feature {
        my $feature = 'nucleotide_match';
        return $feature;
    }
}

{

    package Bio::EnsEMBL::Gene;

    use Bio::Vega::Utils::Detaint qw( detaint_pfam_url_fmt );

    sub to_gff {
        my ($self, %args) = @_;

        # Get URL parameter
        # Choose ensembl or Pfam style naming and URL filling

        # filter the transcripts according to the transcript_analyses
        # param
        my @tsct_all = @{$self->get_all_Transcripts};
        my $transcript_analyses = $args{'transcript_analyses'};
        my @tsct_for_gff =
            $transcript_analyses
            ? ( _tsct_filter($transcript_analyses, @tsct_all) )
            : (@tsct_all);

        # my $gff_string = $self->SUPER::to_gff(%args);
        my $gff_string = '';
        if (@tsct_for_gff) {
            my $extra_attrs = $self->make_extra_attributes(%args);
            if (my $sgn = delete( $extra_attrs->{'synthetic_gene_name'} )) {
                $args{'gene_name'} = $sgn;
            }
            foreach my $tsct (@tsct_for_gff) {
                $gff_string .= $tsct->to_gff(%args, extra_attrs => $extra_attrs);
            }
            $gff_string .= "###\n";
        }

        return $gff_string;
    }

    sub _tsct_filter {
        my ($analyses, @tsct_all) = @_;
        my $analyses_hash = { map { $_ => 1 } split(/,/, $analyses) };
        my @tsct = grep { $analyses_hash->{$_->analysis->logic_name} } @tsct_all;
        return @tsct;
    }

    my $gene_count = 0;
    sub make_extra_attributes {
        my ($self, %args) = @_;

        my $gene_numeric_id = $self->dbID || ++$gene_count;

        my $extra_attrs = {};

        if (my $stable = $self->stable_id) {
            $extra_attrs->{'locus_stable_id'} = $stable;
        }

        if (my $url_string = $args{'url_string'}) {
            my $url_fmt = detaint_pfam_url_fmt($url_string);
            die "Cannot detaint url_string='$url_string'" unless $url_fmt;
            if ($url_fmt =~ s{%\{pfam\}}{%s}) {
                my $kv = $self->_urlsubst_pfam($url_fmt, $gene_numeric_id);
                @{$extra_attrs}{ keys %$kv } = values %$kv;
            }
            else {
                # Assume it is an ensembl gene
                my $url = sprintf $url_fmt, $self->stable_id;
                $extra_attrs->{'url'} = $url;
            }
        }

        unless ($extra_attrs->{'locus'}) {
            if (my $xr = $self->display_xref) {
                $extra_attrs->{'synthetic_gene_name'} = $xr->display_id;
                my $name = sprintf "%s.%d", $xr->display_id, $gene_numeric_id;
                $extra_attrs->{'locus'} = $name;
            }
            elsif (my $stable = $self->stable_id) {
                $extra_attrs->{'locus'} = $stable;
            }
            else {
                my $disp = $self->display_id;
                $extra_attrs->{'locus'} = $disp;
            }
        }

        return $extra_attrs;
    }

    sub _urlsubst_pfam {
        my ($self, $url_fmt, $gene_numeric_id) = @_;
        my %out;
        foreach my $xr (@{$self->get_all_DBEntries}) {
            if ($xr->dbname() eq 'PFAM') {
                $out{'synthetic_gene_name'} = $xr->display_id;
                my $name = sprintf "%s.%d", $xr->display_id, $gene_numeric_id;
                my $url = sprintf $url_fmt, $xr->primary_id;
                $out{'locus'} = $name;
                $out{'url'}   = $url;
            }
        }
        unless (keys %out) {
            die "Couldn't find PFAM XRef";
        }
        return \%out;
    }
}

{

    package Bio::EnsEMBL::Transcript;

    my $tsct_count = 0;
    sub _gff_hash {
        my ($self, %args) = @_;

        my $gff = $self->SUPER::_gff_hash(%args);

        if (my $stable = $self->stable_id) {
            $gff->{'attributes'}{'stable_id'} = $stable;
        }

        my $tsct_numeric_id = $self->dbID || ++$tsct_count;
        # Each transcript must have a (unique) name for GFF grouping purposes
        my $name;
        if (my $gene_name = $args{'gene_name'}) {
            $name = "$gene_name.$tsct_numeric_id";
        }
        elsif (my $xr = $self->display_xref) {
            $name = $xr->display_id;
        }
        elsif (my $stable = $self->stable_id) {
            $name = $stable;
        }
        elsif (my $ana = $self->analysis) {
            $name = sprintf "%s.%d", $ana->logic_name, $tsct_numeric_id;
        }
        $gff->{'attributes'}{'Name'} = $name;
        return $gff;
    }

    my %ens_phase_to_gff_phase = (
        0  => 0,
        1  => 2,
        2  => 1,
        -1 => 0,    # Start phase is (always?) -1 for first coding exon
        );

    sub to_gff {
        my ($self, %args) = @_;

        return '' unless $self->get_all_Exons && @{ $self->get_all_Exons };

        ### hack to help differentiate the various otter transcripts
        if ($self->analysis && $self->analysis->logic_name eq 'Otter') {
            $self->analysis->gff_source('Otter_' . $self->biotype);
        }

        $args{'extra_attrs'} ||= { };
        my %args_super = ( %args );
        my $id = $_new_feature_id_sub->('transcript');
        $args_super{'extra_attrs'}->{'ID'} = $id;
        my $gff = $self->SUPER::to_gff(%args_super);
        my $gff_hash = $self->_gff_hash(%args);

        my $name = $gff_hash->{'attributes'}{'Name'};

        # add gff lines for each of the exons
        my %args_exon = ( %args );
        $args_exon{'extra_attrs'} = { %{$args_exon{'extra_attrs'}} };
        my $extra_attrs = $args_exon{'extra_attrs'};
        delete @{$extra_attrs}{qw( ID locus url )};
        @{$extra_attrs}{qw( Name Parent )} = ( $name, $id );
        foreach my $feat (@{ $self->get_all_Exons }) {

            # exons don't have analyses attached, so temporarily give
            # them the transcript's one
            $feat->analysis($self->analysis);

            # and add the feature's gff line to our string, including
            # the sequence name and the parent
            $gff .= $feat->to_gff(%args_exon);

            # to be on the safe side, get rid of the analysis we temporarily attached
            # (someone might rely on there not being one later)
            $feat->analysis(undef);
        }

        if (my $tsl = $self->translation) {

            # build up the CDS line - it's not really worth creating a
            # Translation->to_gff method, as most of the fields are
            # derived from the Transcript and Translation doesn't
            # inherit from Feature

            my $start = $self->coding_region_start + $self->slice->start - 1;
            my $end   = $self->coding_region_end   + $self->slice->start - 1;

            my $ens_phase = $tsl->start_Exon->phase;
            my $gff_phase =
                defined $ens_phase ? $ens_phase_to_gff_phase{$ens_phase} : 0;

            my $attrib_hash = {
                Name  => $name,
                Parent => $id,
            };
            if (my $stable = $tsl->stable_id) {
                $attrib_hash->{'stable_id'} = $stable;
            }
            my $gff_format = $args{'gff_format'};
            $gff .= $gff_format->gff_line(
                $gff_hash->{'seqname'},
                $gff_hash->{'source'},
                'CDS',    # feature
                $start,
                $end,
                '.',      # score
                $gff_hash->{'strand'},
                $gff_phase,
                $attrib_hash,
                );
        }

        return $gff;
    }

    sub _gff_feature {
        my $feature = 'transcript';
        return $feature;
    }
}

{

    package Bio::EnsEMBL::Exon;

    sub _gff_hash {
        my ($self, @args) = @_;
        my $gff = $self->SUPER::_gff_hash(@args);
        if (my $stable = $self->stable_id) {
            $gff->{'attributes'}{'stable_id'} = $stable;
        }
        return $gff;
    }

    sub _gff_feature {
        my $feature = 'exon';
        return $feature;
    }
}

{

    package Bio::EnsEMBL::Intron;

    sub _gff_feature {
        my $feature = 'intron';
        return $feature;
    }
}

{

    package Bio::EnsEMBL::Variation::VariationFeature;

    ### Should unify with Gene URL stuff.
    my $url_format = 'http://www.ensembl.org/Homo_sapiens/Variation/Summary?v=%s';

    sub _gff_hash {
        my ($self, @args) = @_;

        my $name   = $self->variation->name;

        my $gff = $self->SUPER::_gff_hash(@args);
        my ($start, $end) = @{$gff}{qw( start end )};
        if ($start > $end) {
            @{$gff}{qw( start end )} = ($end, $start);
        }

        $gff->{'attributes'}{'Name'} = $name;
        $gff->{'attributes'}{'ensembl_variation'} = $self->allele_string;
        if ($name =~ /^rs/) {
            my $url = sprintf $url_format, $name;
            $gff->{'attributes'}{'url'}  = $url;
        }

        return $gff;
    }

    sub _gff_feature {
        my ($self) = @_;

        # we require this rather than use it, to free the otter client from
        # a dependency on ensembl-variation.
        #
        require Bio::EnsEMBL::Variation::Utils::Sequence;

        my $feature =
            Bio::EnsEMBL::Variation::Utils::Sequence::SO_variation_class($self->allele_string)
            || 'sequence_alteration';
        return $feature;
    }
}

{

    package Bio::EnsEMBL::RepeatFeature;

    sub _gff_hash {
        my ($self, @args) = @_;
        my $gff = $self->SUPER::_gff_hash(@args);

        if ($self->analysis->logic_name =~ /RepeatMasker/i) {
            my $class = $self->repeat_consensus->repeat_class;

            if ($class =~ /LINE/) {
                $gff->{'source'} .= '_LINE';
            }
            elsif ($class =~ /SINE/) {
                $gff->{'source'} .= '_SINE';
            }

            $gff->{'score'}   = $self->score;

            my $name = $self->repeat_consensus->name;
            $gff->{'attributes'}{'Name'} = $name;
            $gff->{'attributes'}{'Target'} =
                [ $name, $self->hstart, $self->hend, $self->hstrand ];
        }
        elsif ($self->analysis->logic_name =~ /trf/i) {
            $gff->{'score'}   = $self->score;
            my $cons   = $self->repeat_consensus->repeat_consensus;
            my $len    = length($cons);
            my $copies = sprintf "%.1f", ($self->end - $self->start + 1) / $len;
            $gff->{'attributes'}{'Name'} = "$copies copies $len mer $cons";
        }

        return $gff;
    }

    sub _gff_feature {
        my $feature = 'repeat_region';
        return $feature;
    }
}

{

    package Bio::EnsEMBL::Map::DitagFeature;

    sub to_gff {
        my ($self, @args) = @_;

        require Bio::EnsEMBL::DnaDnaAlignFeature;

        my ($start, $end, $hstart, $hend, $cigar_string);

        if ($self->ditag_side eq "F") {
            $start        = $self->start;
            $end          = $self->end;
            $hstart       = $self->hit_start;
            $hend         = $self->hit_end;
            $cigar_string = $self->cigar_line;
        }
        elsif ($self->ditag_side eq "L") {

            # we only return some GFF for L side ditags, as the R side
            # one will be included here

            my ($df1, $df2);
            try {
                ($df1, $df2) =
                    @{$self->adaptor->fetch_all_by_ditagID(
                          $self->ditag_id, $self->ditag_pair_id, $self->analysis->dbID)};
            }
            catch { die "Failed to find matching ditag pair: $_"; };

            (defined $df1 && defined $df2)
                or die "Failed to find matching ditag pair";

            die "Mismatching strands on in a ditag feature pair" unless $df1->strand == $df2->strand;

            ($df1, $df2) = ($df2, $df1) if $df1->start > $df2->start;

            $start = $df1->start;
            $end   = $df2->end;
            my $fw = $df1->strand == 1;
            $hstart = $fw ? $df1->hit_start : $df2->hit_start;
            $hend   = $fw ? $df2->hit_end   : $df1->hit_end;

            my $insert = $df2->start - $df1->end - 1;

            # XXX: gr5: this generates GFF slightly differently from
            # the ace server for instances where the hit_end of df1
            # and the hit_start of df2 are the same e.g. 1-19, 19-37,
            # which seems to occur fairly often. I don't really know
            # what this means (do the pair share a base of the
            # alignment?), but I do not cope with it here, and the GFF
            # will show that such a pair have hit coords 1-19,
            # 20-38. The coords on the genomic sequence will be
            # correct though.

            $cigar_string = $df1->cigar_line . $insert . 'I' . $df2->cigar_line;

        }
        else {

            # we are the R side ditag feature and we don't generate
            # anything

            return '';
        }

        # fake up a DAF which we then convert to GFF as this is the
        # format produced by acedb

        my $daf = Bio::EnsEMBL::DnaDnaAlignFeature->new(
            -slice        => $self->slice,
            -start        => $start - $self->slice->start + 1,
            -end          => $end - $self->slice->start + 1,
            -strand       => $self->strand,
            -hseqname     => $self->ditag->type . ':' . $self->ditag->name,
            -hstart       => $hstart,
            -hend         => $hend,
            -hstrand      => $self->hit_strand,
            -analysis     => $self->analysis,
            -cigar_string => $cigar_string,
            );

        return $daf->to_gff(@args);
    }

}


{
    package Bio::EnsEMBL::Funcgen::SegmentationFeature;

    # Not ideal to have the DB-side full names hard-coded here :-(
    # Abbreviations defined at
    # http://www.ensembl.org/info/genome/funcgen/regulatory_segmentation.html

    my %feature_type_to_abbrev = (
        'CTCF enriched'                           => 'CTCF',
        'Predicted Weak Enhancer/Cis-reg element' => 'WE',
        'Predicted Transcribed Region'            => 'T',
        'Predicted Enhancer'                      => 'E',
        'Predicted Promoter Flank'                => 'PF',
        'Predicted Repressed/Low Activity'        => 'R',
        'Predicted Promoter with TSS'             => 'TSS',
        );

    sub _gff_hash {
        my ($self, @args) = @_;

        my $feature_type = $self->feature_type->name;
        my $feature_type_abbrev = $feature_type_to_abbrev{$feature_type};
        unless ($feature_type_abbrev) {
            $feature_type_abbrev = $feature_type;
            $feature_type_abbrev =~ s/\s+/-/g;
        }

        my $feature_set = $self->feature_set->name;
        $feature_set =~ s/^Segmentation://; # again, a bit yucky to have this hard-coded

        my $source = "funcgen_${feature_set}_${feature_type_abbrev}";

        my $gff = $self->SUPER::_gff_hash(@args);
        $gff->{'source'} = $source;

        return $gff;
    }

}

{
    package Bio::Vega::DnaDnaAlignFeature;

    sub _gff_hash {
        my ($self, @args) = @_;

        my $gff = $self->SUPER::_gff_hash(@args);

        my $hd = $self->get_HitDescription;
        if ($hd) {
            if (my $hit_length = $hd->hit_length) {
                $gff->{'attributes'}{'length'} = $hit_length;
            }
            if (my $taxon_id = $hd->taxon_id) {
                $gff->{'attributes'}{'taxon_id'} = $taxon_id;
            }
            if (my $db_name = $hd->db_name) {
                $gff->{'attributes'}{'db_name'} = $db_name;
            }
            if (my $desc = $hd->description) {
                $desc =~ s/"/\\"/g;
                $gff->{'attributes'}{'Note'} = $desc;
            }
            if (my $seq = $hd->get_and_unset_hit_sequence_string) {
                $gff->{'attributes'}{'sequence'} = $seq;
            }
        }

        return $gff;
    }
}

{
    package Bio::Vega::DnaPepAlignFeature;

    sub _gff_hash {
        my ($self, @args) = @_;

        my $gff = $self->SUPER::_gff_hash(@args);

        my $hd = $self->get_HitDescription;
        if ($hd) {
            if (my $hit_length = $hd->hit_length) {
                $gff->{'attributes'}{'length'} = $hit_length;
            }
            if (my $taxon_id = $hd->taxon_id) {
                $gff->{'attributes'}{'taxon_id'} = $taxon_id;
            }
            if (my $db_name = $hd->db_name) {
                $gff->{'attributes'}{'db_name'} = $db_name;
            }
            if (my $desc = $hd->description) {
                $desc =~ s/"/\\"/g;
                $gff->{'attributes'}{'Note'} = $desc;
            }
        }

        return $gff;
    }
}

1;

__END__

=head1 NAME - Bio::Vega::Utils::EnsEMBL2GFF

=head1 SYNOPSIS

Inserts to_gff (and supporting _gff_hash) methods into various EnsEMBL
and Otter classes, allowing them to be converted to GFF by calling
C<$object->to_gff>.

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

