
package Bio::Otter::Server::GFF::FuncGen;

use strict;
use warnings;

use base qw( Bio::Otter::Server::GFF );

# Inject the necessary get_all_ method into slice
#
sub Bio::EnsEMBL::Slice::get_all_SegmentationFeatures {
    my ($slice, $featuretype_name, $featureset_name) = @_;

    my $funcgen_dba = $slice->adaptor->efgdb;

    my $featuretype;
    if ($featuretype_name) {
        # Just a check for existence, whilst we are using grep below...
        my $featuretype_adaptor = $funcgen_dba->get_adaptor('featuretype');
        $featuretype = $featuretype_adaptor->fetch_by_name($featuretype_name);
        die "Cannot get featuretype for '$featuretype_name'" unless $featuretype;
    }

    # ...but we really use this one in the API fetch_all_by... call
    my $featureset_adaptor = $funcgen_dba->get_adaptor('featureset');
    my $featureset = $featureset_adaptor->fetch_by_name($featureset_name);
    die "Cannot get featureset for '$featureset_name'" unless $featureset;

    my $segmentation_feature_adaptor = $funcgen_dba->get_adaptor('segmentationfeature');
    my $seg_features = $segmentation_feature_adaptor->fetch_all_by_Slice_FeatureSets($slice, [ $featureset ]);


    if ($featuretype_name) {
        # It would be better to do this in the fetch query, but that would mean extending / injecting into
        # Bio::EnsEMBL::Funcgen::SegmentedFeatureAdaptor (probably via SetFeatureAdaptor).
        # (and anyway at time of writing we are not using the feature_type selector in the config)
        $seg_features = [ grep { $_->feature_type->name eq $featuretype_name } @$seg_features ];
    }

    # Truncate to slice to keep ZMap happy.
    my $start = $slice->start;
    my $end   = $slice->end;
    foreach my $sf (@$seg_features) {
        $sf->start(1)            if $sf->seq_region_start < $start;
        $sf->end($slice->length) if $sf->seq_region_end   > $end;
    }

    return $seg_features;
}

sub ensembl_adaptor_class {
    my ($self) = @_;
    return 'Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor';
}

# TODO: make the call_args list sub-classable in Bio::Otter::Server::GFF so that we can do away
#       with reimplementing this - especially if we need to add other feature_kinds.

sub get_requested_features {
    my ($self) = @_;

    my $map = $self->make_map;

    my $feature_kind    = $self->require_argument('feature_kind');
    die "feature_kind '$feature_kind' not supported" unless $feature_kind eq 'SegmentationFeature';

    my $metakey          = $self->require_argument('metakey'); # to find funcgen db
    my $featureset_name  = $self->require_argument('feature_set');
    my $featuretype_name = $self->param('feature_type');

    return $self->fetch_mapped_features_ensembl('get_all_SegmentationFeatures',
                                                [ $featuretype_name, $featureset_name ],
                                                $map, $metakey);
}

1;

__END__

=head1 NAME - Bio::Otter::LogFile

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

