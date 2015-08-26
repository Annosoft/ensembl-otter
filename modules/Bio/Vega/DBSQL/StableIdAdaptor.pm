package Bio::Vega::DBSQL::StableIdAdaptor;

use strict;
use warnings;

use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::Vega::Author;

use base 'Bio::EnsEMBL::DBSQL::BaseAdaptor';


sub fetch_new_gene_stable_id {
    my ($self) = @_;

    return $self->_fetch_new_by_type('gene', 'G');
}

sub fetch_new_transcript_stable_id {
    my ($self) = @_;

    return $self->_fetch_new_by_type('transcript', 'T');
}

sub fetch_new_exon_stable_id {
    my ($self) = @_;

    return $self->_fetch_new_by_type('exon', 'E');
}

sub fetch_new_translation_stable_id {
    my ($self) = @_;

    return $self->_fetch_new_by_type('translation', 'P');
}

sub _fetch_new_by_type {
    my ($self, $type, $type_prefix) = @_;

    my $id     = $type . "_id";
    my $poolid = $type . "_pool_id";
    my $table  = $type . "_stable_id_pool";

    my $sql = "insert into $table () values()";
    my $sth = $self->prepare($sql);
    $sth->execute;
    my $num = $self->last_insert_id($poolid, undef, $table) or throw("Failed to get autoincremented '$poolid'");

    my $meta_container = $self->db->get_MetaContainer;
    my $prefix =
        ($meta_container->get_primary_prefix || 'OTT')
      . ($meta_container->get_species_prefix || '')
      . $type_prefix;

    # Stable IDs are always 18 characters long
    my $rem = 18 - length($prefix);
    return $prefix . sprintf "\%0${rem}d", $num;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

