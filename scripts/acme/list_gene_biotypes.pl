#!/usr/bin/env perl

### list_gene_biotypes.pl

use strict;
use warnings;

use Bio::Otter::Lace::Defaults;
use Bio::Otter::Server::Config;

{
    my $dataset_name = 'human';

    my $usage = sub { exec('perldoc', $0) };
    # This do_getopt() call is needed to parse the otter config files
    # even if you aren't giving any arguments on the command line.
    Bio::Otter::Lace::Defaults::do_getopt(
        'h|help!'       => $usage,
        'dataset=s'     => \$dataset_name,
        ) or $usage->();
    $usage->() unless $dataset_name;
    
    # Client communicates with otter HTTP server
#    my $cl = Bio::Otter::Lace::Defaults::make_Client();
    
    # DataSet interacts directly with an otter database
    my $ds = Bio::Otter::Server::Config->SpeciesDat->dataset($dataset_name);

    my $chr_list = join(', ', map { "'$_'" } (1..22, 'X', 'Y'));

    my $sql_query = qq{
        SELECT g.biotype
          , g.status
          , g.gene_id
          , g.stable_id
          , t.biotype
          , t.status
        FROM (gene g
              , transcript t
              , seq_region chr
              , seq_region_attrib sra_chr
              , coord_system cs)
        LEFT JOIN transcript_attrib ta
          ON t.transcript_id = ta.transcript_id
          AND ta.attrib_type_id = 54
          AND ta.value = 'not for VEGA'
        LEFT JOIN gene_attrib ga
          ON t.gene_id = ga.gene_id
          AND ga.attrib_type_id = 54
          AND ga.value = 'not for VEGA'
        WHERE g.gene_id = t.gene_id
          AND g.seq_region_id = chr.seq_region_id
          AND g.is_current = 1
          AND ta.transcript_id IS NULL
          AND ga.gene_id IS NULL
          AND t.biotype != 'artifact'
          AND chr.coord_system_id = cs.coord_system_id
          AND chr.seq_region_id = sra_chr.seq_region_id
          AND sra_chr.attrib_type_id = 130
          AND cs.version = 'Otter'
          AND g.biotype = 'processed_transcript'
          AND sra_chr.value in ($chr_list)
    };
    die $sql_query;
    my $dba = $ds->otter_dba;
    my $dbc = $dba->dbc;
    my $sth = $dbc->prepare($sql_query);
    $sth->execute;

    my %gene_tsct_biotypes;
    while (my ($gene_biotype, $gene_status, $gene_id, $gsid, $tsct_biotype, $tsct_status) = $sth->fetchrow) {
        next if $tsct_biotype eq 'artifact';
        $gene_status ||= '';
        $tsct_status ||= '';
        my $gene_data = $gene_tsct_biotypes{$gene_id} ||= {};
        $gene_data->{'biotype'}   = $gene_biotype;
        $gene_data->{'status'}    = $gene_status;
        $gene_data->{'stable_id'} = $gsid;
        $gene_data->{'tsct_biotype'}{$tsct_biotype}++;
        $gene_data->{'tsct_status'}{$tsct_status}++;
    }

    foreach my $gene_id (sort { $a <=> $b } keys %gene_tsct_biotypes) {
        my $gene_data         = $gene_tsct_biotypes{$gene_id};
        # my $gene_biotype      = $gene_data->{'biotype'};
        my $gene_status       = $gene_data->{'status'};
        my $stable_id         = $gene_data->{'stable_id'};
        my $tsct_biotype_hash = $gene_data->{'tsct_biotype'};
        my $tsct_status_hash  = $gene_data->{'tsct_status'};
        my ($new_biotype, $new_status) =
          set_biotype_status_from_transcripts($gene_status, $tsct_biotype_hash, $tsct_status_hash);
        print "$stable_id\t$new_biotype\n";
    }
}

# Edited version of method in Bio::Vega::Gene
sub set_biotype_status_from_transcripts {

    # my ($self) = @_;
    my ($gene_status, $tsct_biotype_hash, $tsct_status_hash) = @_;

    my (%tsct_biotype, %tsct_status);

    # TSCT: foreach my $tsct (@{$self->get_all_Transcripts}) {
    #     foreach my $attrib (@{ $self->get_all_Attributes('remark') }) {
    #         if ($attrib->value eq 'not for VEGA') {
    #             # Skip transcripts tagged with "not for VEGA"
    #             next TSCT;
    #         }
    #     }
    #     $tsct_biotype{$tsct->biotype}++;
    #     $tsct_status{ $tsct->status }++;
    # }

    %tsct_biotype = %$tsct_biotype_hash;
    %tsct_status  = %$tsct_status_hash;

    my $biotype = 'processed_transcript';
    if (my @pseudo = grep { /pseudo/i } keys %tsct_biotype) {
        if (@pseudo > 1) {
            die "More than one pseudogene type in gene\n";
        }
        else {
            if ($tsct_biotype{'protein_coding'}) {
                $biotype = 'polymorphic';
            }
            else {
                $biotype = $pseudo[0];
            }
        }
    }
    elsif ($tsct_biotype{'protein_coding'}
        or $tsct_biotype{'nonsense_mediated_decay'}
        or $tsct_biotype{'non_stop_decay'})
    {
        $biotype = 'protein_coding';
    }
    elsif ($tsct_biotype{'retained_intron'} or $tsct_biotype{'ambiguous_orf'}) {
        $biotype = 'processed_transcript';
    }
    elsif (keys %tsct_biotype == 1) {

        # If there is just 1 transcript biotype, then the gene gets it too.
        ($biotype) = keys %tsct_biotype;
    }

    # $self->biotype($biotype);

    # Have already set status to KNOWN if Known was set in acedb.
    # unless ($self->is_known) {
    my $status = '';
    if ($gene_status eq 'KNOWN') {
        $status = 'KNOWN';
    }
    else {

        # Not setting gene status to KNOWN if there is a transcript
        # with status KNOWN.  So KNOWN is only set if radio button in
        # otterlace is checked.
        if ($tsct_status{'PUTATIVE'} and keys(%tsct_status) == 1) {

            # Gene status is PUTATIVE if that is the only kind of transcript
            $status = 'PUTATIVE';
        }
        elsif ($tsct_status{'NOVEL'} or ($biotype !~ /pseudo/i and $biotype ne 'TEC')) {
            $status = 'NOVEL';
        }

        # $self->status($status);
    }

    return ($biotype, $status);
}



__END__

=head1 NAME - list_gene_biotypes.pl

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

