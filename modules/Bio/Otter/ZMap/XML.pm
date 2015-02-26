
package Bio::Otter::ZMap::XML;

use strict;
use warnings;

use Hum::XmlWriter;

sub update_SimpleFeatures_xml {
    my ($old_assembly, $new_assembly, $offset) = @_;

    my $delete_featureset_xml = { };
    my $create_featureset_xml = { };
    my $old_featuresets = _group_by_method_name($old_assembly->get_all_SimpleFeatures);
    my $new_featuresets = _group_by_method_name($new_assembly->get_all_SimpleFeatures);

    my %featuresets = map { $_ => 1 } (keys %$old_featuresets, keys %$new_featuresets);
    for my $fs_name (keys %featuresets) {
        my $old_xml = _featureset_xml($old_featuresets->{$fs_name}, $offset);
        my $new_xml = _featureset_xml($new_featuresets->{$fs_name}, $offset);
        $delete_featureset_xml->{$fs_name} =
            _list_subtract($old_xml, $new_xml);
        $create_featureset_xml->{$fs_name} =
            _list_subtract($new_xml, $old_xml);
    }

    return (
        _xml_string($delete_featureset_xml),
        _xml_string($create_featureset_xml),
        );
}

sub _group_by_method_name {
    my @features = @_;

    my $featuresets = {};
    foreach my $f (@features) {
        my $group = $featuresets->{$f->method_name} ||= [];
        push @$group, $f;
    }
    return $featuresets;
}

sub _featureset_xml {
    my ($feature_list, $offset) = @_;
    $feature_list ||= [ ];
    return [ map { $_->zmap_xml_feature_tag($offset) } @{$feature_list} ];
}

sub _xml_string {
    my ($featureset_xml_hash) = @_;

    # ZMap does not handle XML requests with no features, so we remove
    # all empty lists.

    for ( keys %{$featureset_xml_hash} ) {
        delete $featureset_xml_hash->{$_} unless @{$featureset_xml_hash->{$_}};
    }

    my $xml = Hum::XmlWriter->new;

    while ( my ($fs, $fs_xml) = each %$featureset_xml_hash ) {
        $xml->open_tag('featureset', {name => $fs});
        $xml->add_raw_data_with_indent(join '', @{$fs_xml});
        $xml->close_tag;
    }

    $xml->close_all_open_tags;

    return $xml->flush;
}

sub _list_subtract {
    my ($l0, $l1) = @_;
    my %l1 = map { $_ => 1 } @$l1;
    return [ grep { ! $l1{$_} } @$l0 ];
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

