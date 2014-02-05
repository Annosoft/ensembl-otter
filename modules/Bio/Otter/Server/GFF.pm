
package Bio::Otter::Server::GFF;

use strict;
use warnings;

use Bio::Vega::Enrich::SliceGetAllAlignFeatures;
use Bio::Vega::Utils::GFF;
use Bio::Vega::Utils::EnsEMBL2GFF;

use base qw( Bio::Otter::Server::Support::Web );

my @gff_keys = qw(
    gff_source
    gff_seqname
    );

my $call_args = {

    # EnsEMBL
    SimpleFeature => [
        ['analysis' => undef],
        ],
    RepeatFeature => [
        ['analysis' => undef],
        ['repeat_type' => undef],
        ['dbtype' => undef],
    ],
    MarkerFeature => [
        ['analysis' => undef],
        ['priority' => undef],
        ['map_weight' => undef],
    ],
    DitagFeature => [
        ['ditypes', undef, qr/,/],
        ['analysis' => undef],
    ],

    # Vega
    DnaDnaAlignFeature => [
        ['analysis' => undef],
        ['score' => undef],
        ['dbtype' => undef],
    ],
    DnaPepAlignFeature => [
        ['analysis' => undef],
        ['score' => undef],
        ['dbtype' => undef],
    ],
    PredictionTranscript => [
        ['analysis' => undef],
        ['load_exons' => 1],
    ],

    # dummy
    ExonSupportingFeature => [
        ['analysis' => undef],
    ],

};

sub send_requested_features {
    my ($pkg) = @_;

    $pkg->send_response(
        -compression => 1,
        sub {
            my ($self) = @_;
            my $features = $self->get_requested_features;
            my $features_gff = $self->_features_gff($features);
            my $gff = $self->gff_header . $features_gff;
            return $gff;
        });

    return;
}

sub get_requested_features {

    my ($self) = @_;

    my @feature_kinds  = split(/,/, $self->require_argument('feature_kind'));
    my $analysis_list = $self->param('analysis');
    my @analysis_names = $analysis_list ? split(/,/, $analysis_list) : ( undef );
    my $filter_module = $self->param('filter_module');

    my $map = $self->make_map;
    my @feature_list = ();

    my $metakey = $self->param('metakey');
    foreach my $analysis_name (@analysis_names) {
        foreach my $feature_kind (@feature_kinds) {
            my $getter_method = "get_all_${feature_kind}s";
            my $param_list =
                $feature_kind eq 'VariationFeature'
                ? [ undef, undef, undef, "${metakey}_variation" ]
                : $self->_param_list($analysis_name, $feature_kind);
            my $features = $self->fetch_mapped_features_ensembl($getter_method, $param_list, $map, $metakey);
            push @feature_list, @$features;
        }
    }

    if ($filter_module) {

        # detaint the module string

        my ($module_name) = $filter_module =~ /^((\w+::)*\w+)$/;

        # for the moment be very conservative in what we allow

        if ($module_name =~ /^Bio::Vega::ServerAnalysis::\w+$/) {

            eval "require $module_name" ## no critic (BuiltinFunctions::ProhibitStringyEval,Anacode::ProhibitEval)
                or die "Failed to 'require' module $module_name: $@";

            my $filter = $module_name->new;

            warn scalar(@feature_list)." features before filtering...\n";

            @feature_list = $filter->run(\@feature_list);

            warn scalar(@feature_list)." features after filtering...\n";
        }
        else {
            die "Invalid filter module: $filter_module";
        }
    }

    # workaround: some of our pipelines put features on the wrong strand
    if ( $self->param('swap_strands') ) {
        for my $f (@feature_list) {
            if ($f->can('hstrand') && $f->hstrand == -1) {
                $f->hstrand($f->hstrand * -1);
                $f->strand($f->strand * -1);
                $f->cigar_string(join '', reverse($f->cigar_string =~ /(\d*[A-Za-z])/g))
            }
        }
    }

    return \@feature_list;
}

sub _param_list {
    my ($self, $analysis_name, $feature_kind) = @_;

    my $param_descs = $call_args->{$feature_kind};
    my @param_list = ( );

    foreach my $param_desc (@$param_descs) {
        my ($param_name, $param_def_value, $param_separator) = @$param_desc;

        my $param_value = (scalar(@$param_desc)==1)
            ? $self->require_argument($param_name)
            : defined($self->param($param_name))
            ? $self->param($param_name)
            : $param_def_value;
        if($param_value && $param_separator) {
            $param_value = [split(/$param_separator/,$param_value)];
        }
        $param_value = $analysis_name
            if $param_value && $param_value =~ /$analysis_name/;
        push @param_list, $param_value;
    }

    return \ @param_list;
}

sub gff_header {

    my ($self) = @_;

    my $gff_version = $self->param('gff_version');
    my $name    = $self->param('type');
    my $start   = $self->param('start');
    my $end     = $self->param('end');

    return Bio::Vega::Utils::GFF::gff_header($gff_version, $name, $start, $end);
}

sub _features_gff {
    my ($self, $features) = @_;

    my %gff_args = ();
    $gff_args{$_} = $self->param($_) for $self->_gff_keys;
    my $gff_version = $self->param('gff_version');
    $gff_args{'gff_format'} = Bio::Vega::Utils::GFF::gff_format($gff_version);
    my $features_gff = join '', map { $_->to_gff(%gff_args) || '' } @{$features};

    return $features_gff;
};

sub _gff_keys {
    return @gff_keys;
}

# a Bio::EnsEMBL::Slice method to handle the dummy ExonSupportingFeature feature type
sub Bio::EnsEMBL::Slice::get_all_ExonSupportingFeatures {
    my ($self, $logic_name, $dbtype) = @_;

    my $load_exons = 1;

    if(!$self->adaptor()) {
        warning('Cannot get Transcripts without attached adaptor');
        return [];
    }

    return
        [ map { @{$_->get_all_supporting_features} }
          map { @{$_->get_all_Exons} }
          @{$self->get_all_Transcripts($load_exons, $logic_name, $dbtype)}
          ];
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

