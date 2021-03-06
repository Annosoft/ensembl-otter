package Bio::Otter::Utils::AccessionInfo::Serialise;

use strict;
use warnings;

use Readonly;

use base qw( Exporter );
our @EXPORT_OK = qw(
    fasta_header_column_order
    escape_fasta_description
    unescape_fasta_description
);

=head1 NAME

Bio::Otter::Utils::AccessionInfo::Serialise - definitions and subroutines for serialising AccessionInfo results

=cut

Readonly my @FASTA_HEADER_COLUMN_ORDER => qw(
    acc_sv
    taxon_id
    evi_type
    description
    source
    sequence_length
    currency
);

sub fasta_header_column_order { return @FASTA_HEADER_COLUMN_ORDER; }

{
    my %esc = (
        '|' => '~p',
        '~' => '~t',
        );

    my %unesc = reverse %esc;

    sub escape_fasta_description {
        my ($description) = @_;
        $description =~ s/([|~])/$esc{$1}/g;
        return $description;
    }

    sub unescape_fasta_description {
        my ($description) = @_;
        $description =~ s/(~[pt])/$unesc{$1}/g;
        return $description;
    }
}


=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

=cut

1;
