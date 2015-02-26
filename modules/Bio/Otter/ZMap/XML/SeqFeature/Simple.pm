
## no critic (Modules::RequireFilenameMatchesPackage)

package Hum::Ace::SeqFeature::Simple; # mix-in!

use strict;
use warnings;
use Hum::XmlWriter;

sub zmap_xml_feature_tag {
    my ($self, $offset) = @_;

    $offset ||= 0;

    my $xml = Hum::XmlWriter->new;
    $xml->full_tag('feature', [     # Note: using array ref, not hash ref, to preserve order of attributes
        name        => $self->text,
        start       => $offset + $self->seq_start,
        end         => $offset + $self->seq_end,
        strand      => $self->seq_strand == -1 ? '-' : '+',
        style       => $self->Method->style_name,
        score       => 1 * $self->score,    # 0.5 comes from acedb as 0.500000 making old feature appear different to new
        ontology    => 'misc_feature',
    ]);
    return $xml->flush;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

