
### Bio::Vega::Utils::GeneTranscriptBiotypeStatus

package Bio::Vega::Utils::GeneTranscriptBiotypeStatus;

use strict;
use warnings;
use Carp;
use base 'Exporter';
our @EXPORT_OK = qw{ method2biotype_status biotype_status2method };

# Known_CDS will overwrite Known in %biotype_status_to_method, but
# this does not matter since the gene type does not get transmitted
# back to acedb.
# Novel_Transcript will only be found as a gene type, not a transcript.
my @method_biotype_status = qw{

    Known                           protein_coding          KNOWN
    Coding                          protein_coding          -
        Known_CDS                   protein_coding          KNOWN
        Novel_CDS                   protein_coding          NOVEL
        Putative_CDS                protein_coding          PUTATIVE
        Nonsense_mediated_decay     =                       -

    Novel_Transcript                processed_transcript    KNOWN
    Novel_Transcript                processed_transcript    NOVEL
    Transcript                      processed_transcript    -
        Ambiguous_ORF               =                       -
        Retained_intron             =                       -
        Disrupted_domain            =                       -
        IG_segment                  =                       -
        IG_gene                     =                       -
        IG_pseudogene               =                       -
        TR_gene                     =                       -
        Putative                    processed_transcript    PUTATIVE

    Non_coding                      =                       -
        lincRNA                     =                       -
        Antisense                   =                       -
        ncRNA_host                  =                       -
        3'_overlapping_ncRNA        =                       -

    Pseudogene                      =                       -
        Processed_pseudogene        =                       -
        Unprocessed_pseudogene      =                       -
        Expressed_pseudogene        =                       -

    Transposon                      =                       -

    Artifact                        =                       -

    TEC                             =                       -

    Predicted                       protein_coding          PREDICTED

};

if (@method_biotype_status % 3) {
    confess "Method, Biotype, Status list is not a multiple of 3";
}

my (%method_to_biotype_status, %biotype_status_to_method);
for (my $i = 0; $i < @method_biotype_status; $i += 3) {
    my ($method, $biotype, $status) = @method_biotype_status[$i, $i+1, $i+2];

    # biotype defaults to lower case of status
    $biotype = lc $method if $biotype eq '=';
    $status = 'UNKNOWN'   if $status  eq '-';

    $biotype_status_to_method{"$biotype.$status"}   = $method;
    $biotype_status_to_method{$biotype}           ||= $method;

    $method_to_biotype_status{$method} = [$biotype, $status];
}

sub method2biotype_status {
    my ($method) = @_;

    my ($biotype, $status);
    if (my $bs = $method_to_biotype_status{$method}) {
        return @$bs;
    } else {
        return (lc $method, 'UNKNOWN')
    }
}

sub biotype_status2method {
    my $biotype = lc shift;
    my $status  = uc shift;

    #warn "TESTING FOR: '$biotype.$status'";
    return $biotype_status_to_method{"$biotype.$status"}
        || $biotype_status_to_method{$biotype}
        || ucfirst lc $biotype;
}

1;

__END__

=head1 NAME - Bio::Vega::Utils::GeneTranscriptBiotypeStatus

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

