
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
    for my $featureset (keys %featuresets) {
        my $old_xml = _featureset_xml($old_featuresets->{$featureset}, $offset);
        my $new_xml = _featureset_xml($new_featuresets->{$featureset}, $offset);
        $delete_featureset_xml->{$featureset} =
            _list_subtract($old_xml, $new_xml);
        $create_featureset_xml->{$featureset} =
            _list_subtract($new_xml, $old_xml);;
    }

    return (
        _request_xml('delete_feature', $delete_featureset_xml),
        _request_xml('create_feature', $create_featureset_xml),
        );
}

sub _group_by_method_name { ## no critic(Subroutines::RequireArgUnpacking)
    my $featuresets = { };
    push @{$featuresets->{$_->method_name}}, $_ for @_;
    return $featuresets;
}

sub _featureset_xml {
    my ($featureset_list, $offset) = @_;
    $featureset_list ||= [ ];
    return [ map { $_->zmap_xml_feature_tag($offset) } @{$featureset_list} ];
}

sub _request_xml {
    my ($action, $featureset_xml_hash) = @_;

    # ZMap does not handle XML requests with no features, so we remove
    # all empty lists and return nothing if the hash is empty

    for ( keys %{$featureset_xml_hash} ) {
        delete $featureset_xml_hash->{$_} unless @{$featureset_xml_hash->{$_}};
    }
    return unless %{$featureset_xml_hash};

    my $xml = Hum::XmlWriter->new;

    $xml->open_tag('zmap');
    $xml->open_tag('request', {action => $action});
    $xml->open_tag('align');
    $xml->open_tag('block');

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
    my %l1 = map { $_ => 1 } @{$l1};
    return [ grep { ! exists $l1{$_} } @{$l0} ];
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk
