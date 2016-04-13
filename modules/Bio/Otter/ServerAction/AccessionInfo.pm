package Bio::Otter::ServerAction::AccessionInfo;

use strict;
use warnings;

use Try::Tiny;

use Bio::Otter::Utils::AccessionInfo;
use Bio::Otter::Utils::ENA;
use Bio::Vega::Evidence::Types qw(evidence_is_sra_sample_accession);

use base 'Bio::Otter::ServerAction';

=head1 NAME

Bio::Otter::ServerAction::AccessionInfo - serve requests for accession info.

=cut

# Parent constructor is fine unaugmented.

### Methods

sub get_accession_info {
    my $self = shift;

    my $acc_list = $self->deserialise_id_list($self->server->require_argument('accessions'));

    # Separate out any accessions that look like they come from the Sequence Read Archive (SRA) at ENA.
    my @sra_accessions;
    for (my $i = 0; $i < @$acc_list;) {
        my $acc = $acc_list->[$i];
        if (evidence_is_sra_sample_accession($acc)) {
            push @sra_accessions, splice(@$acc_list, $i, 1);
        }
        else {
            $i++;
        }
    }

    my ($info);
    try {
        my $ai = Bio::Otter::Utils::AccessionInfo->new;
        $info = $ai->get_accession_info($acc_list);
        1;
    }
    catch {
        die "Failed to fetch AccessionInfo accession type info: $_";
    };

    if (@sra_accessions) {
        my ($ena_types);
        try {
            my $ena = Bio::Otter::Utils::ENA->new;
            $ena_types = $ena->get_sample_accession_types(@sra_accessions);
            1;
        }
        catch {
            die "Failed to fetch ENA accession type info: $_";
        };

        while (my ($name, $data) = each %$ena_types) {
            $info->{$name} = $data;
        }
    }

    return $info;
}

sub get_accession_types {
    my $self = shift;

    my $acc_list = $self->deserialise_id_list($self->server->require_argument('accessions'));

    my (@ai_acc_list, @sra_acc_list);
    foreach my $acc ( @$acc_list ) {
        if (evidence_is_sra_sample_accession($acc)) {
            push @sra_acc_list, $acc;
        } else {
            push @ai_acc_list, $acc;
        }
    }

    my $ai_types;
    try {
        my $ai = Bio::Otter::Utils::AccessionInfo->new;
        $ai_types = $ai->get_accession_info_no_sequence(\@ai_acc_list);
        1;
    }
    catch {
        die "Failed to fetch AccessionInfo accession type info: $_";
    };

    my $ena_types;
    try {
        my $ena = Bio::Otter::Utils::ENA->new;
        $ena_types = $ena->get_sample_accession_types(@sra_acc_list);
        1;
    }
    catch {
        die "Failed to fetch ENA accession type info: $_";
    };

    my $combined  = { %$ai_types, %$ena_types };
    return $combined;
}

# Null deserialiser, overridden in B:O:SA:TSV::AccessionInfo
sub deserialise_id_list {
    my ($self, $id_list) = @_;
    return $id_list;
}


=head2 get_taxonomy_info
=cut

sub get_taxonomy_info {
    my ($self) = @_;

    my $id_list = $self->deserialise_id_list($self->server->require_argument('id'));
    my $info = Bio::Otter::Utils::AccessionInfo->new->get_taxonomy_info($id_list);

    return $info;
}

# FIXME: deserialisation is in the wrong place at the moment (in AccessionTypeCache.pm)


=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

=cut

1;
