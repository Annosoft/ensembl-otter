package Bio::Vega::Region;

use strict;
use warnings;

use Carp;

use Bio::EnsEMBL::SimpleFeature;
use Bio::EnsEMBL::Slice;
use Bio::Otter::Lace::CloneSequence;
use Bio::Vega::ContigInfo;
use Bio::Vega::Utils::Attribute qw( get_first_Attribute_value get_name_Attribute_value );

=head1 NAME

Bio::Vega::Region

=head1 DESCRIPTION

Represents a region as processed by Bio::Otter::ServerAction::Region
in write_region() after XML decoding, and get_region() before XML
encoding.

=cut

sub new {
    my ($class, %options) = @_;

    my $pkg = ref($class) || $class;
    my $self = bless { %options }, $pkg;

    return $self;
}

sub new_from_otter_db {
    my ($class, %options) = @_;

    my $self = $class->new(%options);

    confess "Cannot fetch data without slice" unless $self->slice;
    confess "Cannot fetch data: slice does not have DB adaptor"
        unless ($self->slice->adaptor and $self->slice->adaptor->db);

    $self->fetch_CloneSequences;
    $self->fetch_species;
    $self->fetch_SimpleFeatures;
    $self->fetch_Genes;

    return $self;
}

sub new_dissociated_copy {
    my ($self) = @_;

    my $copy = $self->new( species => $self->species );
    $copy->clone_sequences($self->clone_sequences);

    my $slice = $self->slice;
    my $new_slice;
    if ($slice->adaptor) {
        my $slice_pkg = ref($slice);
        $new_slice = $slice_pkg->new_fast({%$slice});
        delete $new_slice->{adaptor};
        $copy->slice($new_slice);
    }
    # Should $new_slice be propagated to dissociated copies below ?

    my @genes = map { $_->new_dissociated_copy } $self->genes;
    $copy->genes(@genes);

    my @seq_features;
    foreach my $sf ( $self->seq_features ) {
        my $sf_pkg = ref($sf);
        my $new_sf = $sf_pkg->new_fast({%$sf});
        delete $new_sf->{adaptor};
        delete $new_sf->{dbID};
        push @seq_features, $new_sf;
    }
    $copy->seq_features(@seq_features);

    return $copy;
}

sub _slice_dba {
    my ($self) = @_;
    return $self->slice->adaptor->db;
}

sub slice {
    my ($self, @args) = @_;
    ($self->{'slice'}) = @args if @args;
    my $slice = $self->{'slice'};
    return $slice;
}

sub species {
    my ($self, @args) = @_;
    ($self->{'species'}) = @args if @args;
    my $species = $self->{'species'};
    return $species;
}

sub genes {
    my ($self, @args) = @_;
    $self->_gene_list( [ @args ] ) if @args;
    my $genes = $self->_gene_list;
    return @$genes;
}

sub add_genes {
    my ($self, @genes ) = @_;
    push @{$self->_gene_list}, @genes;
    return;
}

sub seq_features {
    my ($self, @args) = @_;
    $self->_seq_feature_list( [ @args ] ) if @args;
    my $seq_features = $self->_seq_feature_list;
    return @$seq_features;
}

sub add_seq_features {
    my ($self, @seq_features ) = @_;
    push @{$self->_seq_feature_list}, @seq_features;
    return;
}

sub clone_sequences {
    my ($self, @args) = @_;
    $self->_clone_seq_list( [ @args ] ) if @args;
    my $clone_sequences = $self->_clone_seq_list;
    return @$clone_sequences;
}

sub sorted_clone_sequences {
    my ($self) = @_;
    my @cs = sort { $a->chr_start() <=> $b->chr_start() } $self->clone_sequences;
    return @cs;
}

sub add_clone_sequences {
    my ($self, @clone_sequences ) = @_;
    push @{$self->_clone_seq_list}, @clone_sequences;
    return;
}

# We assume all clone_sequences belong to same chromosome
#
sub chromosome_name {
    my ($self) = @_;
    my @cs = $self->clone_sequences;
    return unless @cs;
    return $cs[0]->chromosome;
}

sub fetch_CloneSequences {
    my ($self) = @_;

    my $slice_projection = $self->slice->project('contig');
    my $cs_list = $self->_clone_seq_list([]); # empty list
    foreach my $contig_seg (@$slice_projection) {
        my $cs = $self->fetch_CloneSeq($contig_seg);
        push @$cs_list, $cs;
    }

    return @$cs_list;
}

sub fetch_CloneSeq {
    my ($self, $contig_seg) = @_;

    my $contig_slice = $contig_seg->to_Slice();

    my $cs = Bio::Otter::Lace::CloneSequence->new;
    $cs->chromosome(get_first_Attribute_value($self->slice, 'chr', confess_if_multiple => 1));
    $cs->contig_name($contig_slice->seq_region_name);

    my $clone_slice = $contig_slice->project('clone')->[0]->to_Slice;
    $cs->accession(     get_first_Attribute_value($clone_slice, 'embl_acc'    , confess_if_multiple => 1) );
    $cs->sv(            get_first_Attribute_value($clone_slice, 'embl_version', confess_if_multiple => 1) );

    if (my $cn = get_first_Attribute_value($clone_slice,'intl_clone_name')) {
        $cs->clone_name($cn);
    } else {
        $cs->clone_name($cs->accession_dot_sv);
    }

    my $assembly_offset = $self->slice->start - 1;
    $cs->chr_start( $contig_seg->from_start + $assembly_offset  );
    $cs->chr_end(   $contig_seg->from_end   + $assembly_offset  );
    $cs->contig_start(  $contig_slice->start                );
    $cs->contig_end(    $contig_slice->end                  );
    $cs->contig_strand( $contig_slice->strand               );
    $cs->length(        $contig_slice->seq_region_length    );

    if (my $ci = $self->_slice_dba->get_ContigInfoAdaptor->fetch_by_contigSlice($contig_slice)) {
        $cs->ContigInfo($ci);
    } else {
        $cs->ContigInfo(Bio::Vega::ContigInfo->new(-slice => $contig_slice));
    }

    return $cs;
}

sub fetch_species {
    my ($self) = @_;
    my $db_species = $self->_slice_dba->species;
    # Drop the session spec - see Bio::Otter::Lace::DB->vega_dba()
    $db_species =~ s/:::.*$//;
    return $self->species($db_species);
}

sub fetch_SimpleFeatures {
    my ($self) = @_;

    my $slice = $self->slice;
    my $features        = $slice->get_all_SimpleFeatures;
    my $slice_length    = $slice->length;

    # Discard features which overlap the ends of the slice
    for (my $i = 0; $i < @$features; ) {
        my $sf = $features->[$i];
        if ($sf->start < 1 or $sf->end > $slice_length) {
            splice(@$features, $i, 1);
        } else {
            $i++;
        }
    }

    $self->_seq_feature_list($features);

    return @$features;
}

sub fetch_Genes {
    my ($self) = @_;

    my $slice = $self->slice;
    my $ga =  $slice->adaptor->db->get_GeneAdaptor();
    my $gene_list = $ga->fetch_all_by_Slice($slice);
    $self->_gene_list($gene_list);

    return @$gene_list;
}

sub check_transcript_stable_ids {
    my ($self) = @_;

    my %stable_id_map;
    my @errors;

    foreach my $g ( $self->genes ) {
        foreach my $t ( @{$g->get_all_Transcripts} ) {
            my $stable_id = $t->stable_id;
            next unless $stable_id;
            my $dbID      = $t->dbID;
            if (my $prev_t = $stable_id_map{$stable_id}) {
                my $prev_dbID = $prev_t->dbID;
                my $prev_name = get_name_Attribute_value($prev_t);
                my $name      = get_name_Attribute_value($t);
                push @errors, "  ${stable_id}:\n    ${prev_name} (${prev_dbID})\n    ${name} (${dbID})";
            } else {
                $stable_id_map{$stable_id} = $t;
            }
        }
    }
    return unless @errors;

    my $details = join "\n", @errors;
    die "Duplicate transcript stable IDs found:\n$details\n";
}

sub _clone_seq_list {
    my ($self, @args) = @_;
    ($self->{'_clone_seq_list'}) = @args if @args;
    my $_clone_seq_list = $self->{'_clone_seq_list'} ||= [];
    return $_clone_seq_list;
}

sub _seq_feature_list {
    my ($self, @args) = @_;
    ($self->{'_seq_feature_list'}) = @args if @args;
    my $_seq_feature_list = $self->{'_seq_feature_list'} ||= [];
    return $_seq_feature_list;
}

sub _gene_list {
    my ($self, @args) = @_;
    ($self->{'_gene_list'}) = @args if @args;
    my $_gene_list = $self->{'_gene_list'} ||= [];
    return $_gene_list;
}

# This mainly for the benefit of scripts.
#
sub server_action {
    my ($self, @args) = @_;
    ($self->{'server_action'}) = @args if @args;
    my $server_action = $self->{'server_action'};
    return $server_action;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk
