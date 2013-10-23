
package Bio::Otter::Server::GFF::DAS;

use strict;
use warnings;

use base qw( Bio::Otter::Server::GFF );

use Try::Tiny;

use Bio::Das::Lite;
use Bio::EnsEMBL::SimpleFeature;
use Bio::Vega::PredictionTranscript;
use Bio::EnsEMBL::PredictionExon;
use Bio::EnsEMBL::DnaDnaAlignFeature;

my %LangDesc = (

    SimpleFeature => {
        -constructor => 'Bio::EnsEMBL::SimpleFeature',
    },

    PredictionTranscript => {
        -constructor  => 'Bio::Vega::PredictionTranscript',
        -get_all_cmps => 'get_all_Exons',
    },

    PredictionExon => {
        -constructor => 'Bio::EnsEMBL::PredictionExon',
        -add_one_cmp => [ 'PredictionTranscript', 'add_Exon' ],
    },

    DnaDnaAlignFeature => {
        -constructor => sub {
            return Bio::EnsEMBL::DnaDnaAlignFeature->new_fast({});
        },
    },

    );

sub struct_traverse_path {
    my ($struct, $path) = @_;

    if(ref($path->[0]) eq 'ARRAY') {
        # recursive application of self to the parts
        my $join = join(
            ';', map {
                my $foo = struct_traverse_path($struct, $_);
                defined($foo) ? $foo : 'UnDeF';
            } @$path );
        return ($join=~/UnDeF/) ? undef : $join;
    }

    foreach my $step (@$path) {
        if(ref($struct) eq 'HASH') {
            $struct = $struct->{$step};
        } elsif(ref($struct) eq 'ARRAY') {
            $struct = $struct->[$step];
        } else {
            return;
        }
    }
    return $struct;
}

sub struct_show_path {
    my ($struct, $path) = @_;

    if(ref($path->[0]) eq 'ARRAY') {
        # recoursive application of self to the parts
        return join('.', map { struct_show_path($struct, $_) } @$path );
    }

    my $output = '$feature->';

    foreach my $step (@$path) {
        if(ref($struct) eq 'HASH') {
            $output .= '{'.$step.'}';
            $struct = $struct->{$step};
        } elsif(ref($struct) eq 'ARRAY') {
            $output .= '['.$step.']';
            $struct = $struct->[$step];
        } else {
            $output .= '?'.$step.'?';
        }
    }
    return $output;
}

sub Bio::EnsEMBL::Slice::get_all_features_via_DAS {
    # $feature_kind = 'SimpleFeature' || 'PredictionExon'
    my ($slice, $server, $das, $chr_name, $analysis_name,
        $feature_kind, $sieve, $grouplabel,
        ) = @_;

    my $feature_subhash     = $LangDesc{$feature_kind};
    my $feature_constructor = $feature_subhash->{-constructor};
    my $feature_sub =
        ref $feature_constructor eq "CODE"
        ? $feature_constructor
        : sub { return $feature_constructor->new(); };
    my ($parent_constructor, $add_sub, $parent_feature_type);

    if(my $cmp_uplink = $feature_subhash->{-add_one_cmp}) {
        # component link is two-way (parent keeps a list of its components)
        ($parent_feature_type, $add_sub) = @$cmp_uplink;
        $parent_constructor = $LangDesc{$parent_feature_type}{-constructor};
    }

    my @paths_to_try = $parent_constructor
        ? ( ['group',0,'group_label'],
            ['group',0,'group_id'],
            ['feature_label'],
            ['feature_id'] )
        : ( [['group',0,'group_label'], ['type']],
            [['group',0,'group_id'], ['type']],
            ['type'], ['type_id'], ['feature_label'], ['feature_id'] );

    my $chr_start = $slice->start();
    my $chr_end   = $slice->end();
    my $segment_name  = "$chr_name:$chr_start,$chr_end";

    my ($sieve_field_path, $sieve_sign, $sieve_value) =
        split(/(--CONTAINS--|--LACKS--)/, $sieve);
    $sieve_field_path &&= [ split(/--THEN--/,$sieve_field_path) ];

    my $grouplabel_field_path;
    $grouplabel_field_path = [ split m(/), $grouplabel ] if $grouplabel;

    # DAS servers will give all features if a "type=" argument is not present
    if ($analysis_name and $analysis_name eq 'all') {
        $analysis_name = undef;
    }

    warn sprintf "GET  %s/features?segment=%s%s\n",
                            $das->dsn->[0],
                            $segment_name,
                            $analysis_name ? ";type=$analysis_name" : '';

    my $response = $das->features({
        'segment' => $segment_name,
        $analysis_name ? ('type' => $analysis_name) : (),
    });

    # Bio::DAS::Lite object can do many requests.  We only do one, so we
    # get the value from the statuscodes hash, since the key may change
    # if Bio::DAS::Lite changes how it constructs its URLs.
    my ($code) = values %{$das->statuscodes};
    unless ($code =~ /^200/) {
        die "Error from DAS request: $code\n";
    }

    # collection(hash/array) of top-level features
    # (prediction_transcripts | simple_features)
    my $feature_coll;

    foreach my $das_features (values %$response) {
        if(!$das_features || ref($das_features) ne 'ARRAY') {
            next;
        }

        FEATURE: while(my $das_feature = shift @$das_features) {

            my ($truncated_5_prime, $truncated_3_prime);

                # Filter out introns and other features that may be sent by
                # the server but irrelevant for us:
            if($sieve) {
                my $sieve_field =
                    struct_traverse_path($das_feature, $sieve_field_path);
                if( 
                    # wanted to include it, but it's not here
                    (($sieve_sign eq '--CONTAINS--')
                     && ($sieve_field!~/$sieve_value/i))
                    ||
                    # wanted to exclude it, but it's here
                    (($sieve_sign eq '--LACKS--')
                     && ($sieve_field=~/$sieve_value/i))
                    ) {
                    next FEATURE;
                }
            }

            # Skip features that don't overlap segment
            # (eg: exons in transcript which does overlap)
            # but flag that we have done so in the parent object (if any) 

            if ($das_feature->{'end'} < $chr_start) {
                $truncated_5_prime = 1;
            }

            if ($das_feature->{'start'} > $chr_end) {
                $truncated_3_prime = 1;
            }

            my $pt_label;

            if($grouplabel_field_path) {
                $pt_label =
                    struct_traverse_path($das_feature, $grouplabel_field_path)
                    || 'NONAME?';
            } else {
                warn "Trying to guess a fitting group/label path:\n";
                my $show_path;
                CANDIDATE: foreach my $path (@paths_to_try) {
                    $show_path = struct_show_path($das_feature, $path);
                    if(defined($pt_label =
                               struct_traverse_path($das_feature, $path))) {
                        # by doing this we also ensure we only run this
                        # experiment once
                        $grouplabel_field_path = $path;
                        warn "Trying $show_path - seems suitable\n";
                        last CANDIDATE;
                    } else {
                        warn "Trying $show_path - not suitable\n";
                    }
                }
                if(defined $pt_label) {
                    warn
                        "After much deliberation"
                        . "the following group/label path was selected:"
                        . "$show_path\n";
                } else {
                    die
                        "Could not guess a fitting group/label path,"
                        . "please specify it in the 'grouplabel='"
                        . "parameter of the filter";
                }
            }

            if ($truncated_5_prime || $truncated_3_prime) {
                if($parent_constructor) {
                    my $parent_feature =
                        $feature_coll->{$pt_label} ||=
                        $parent_constructor->new(
                            -dbID => $pt_label, -slice => $slice );

                    if ($parent_feature->can('truncated_5_prime')
                        && $truncated_5_prime) {
                        warn "truncating feature at 5' end";
                        $parent_feature->truncated_5_prime(1);
                    }

                    if ($parent_feature->can('truncated_3_prime')
                        && $truncated_3_prime) {
                        warn "truncating feature at 3' end";
                        $parent_feature->truncated_3_prime(1);
                    }
                }

                next FEATURE;
            }

            my $feature = $feature_sub->();

            $feature->slice(   $slice );
            # Set feature start and end to start and end of segment
            # if it extends beyond
            $feature->start(
                $das_feature->{'start'} < $chr_start
                ? 1 : $das_feature->{'start'} - $chr_start + 1 );
            $feature->end(
                $das_feature->{'end'}   > $chr_end
                ? $chr_end : $das_feature->{'end'}   - $chr_start + 1 );
            $feature->strand( $das_feature->{'orientation'} =~ /^-/ ? -1 : 1 );
            if($feature->can('score')) {
                    ## should we fake the value when it is not available? :
                my $score = $das_feature->{'score'} || '-';
                $feature->score(  ($score eq '-') ? 100 : $score );
            }

            if($parent_constructor) {
                my $parent_feature =
                    $feature_coll->{$pt_label} ||=
                    $parent_constructor->new(
                        -dbID => $pt_label, -slice => $slice );

                if ( $parent_feature->can('display_label') ) {
                    $parent_feature->display_label( $pt_label );
                }
                elsif ( $parent_feature->can('display_id') ) {
                    $parent_feature->display_id( $pt_label );
                }

                try {
                    warn sprintf
                        "adding feature with start=%d and end=%d\n"
                        , $feature->start, $feature->end;
                    $parent_feature->$add_sub($feature);
                }
                catch {
                    ## there may be a collision of exons -
                    ## just ignore it for the moment
                    warn "Could not group feature: $_\n";
                };
            } else {
                if ( $feature->can('display_label') ) {
                    $feature->display_label( $pt_label );
                }
                elsif ( $feature->can('display_id') ) {
                    $feature->display_id( $pt_label );
                }
                push @$feature_coll, $feature;
            }
        }
    }

    if (ref($feature_coll) eq 'HASH') {
        # we need to remove any feature that has no components (so we don't end 
        # up with exon-less transcripts)
        if (my $getter = $LangDesc{$parent_feature_type}{-get_all_cmps}) {
            for my $label (keys %$feature_coll) {
                my $parent = $feature_coll->{$label};
                delete $feature_coll->{$label} unless $parent->$getter();
            }
        }
    }

    return
        (ref($feature_coll) eq 'HASH')
        ? [ values %$feature_coll ]
        : $feature_coll || [];
}

sub get_requested_features {
    my ($self) = @_;

    ## Since in our new schema name is substituted for type,
    ## we need it clean for outer sources
    my $chr_name = $self->param('name');

    my $source        = $self->require_argument('source');
    my $dsn           = $self->require_argument('dsn');
    my $analysis_name = $self->param('analysis'); # defaults to *everything*
    my $feature_kind  = $self->param('feature_kind')  || 'SimpleFeature';
    my $sieve         = $self->param('sieve') || '';
    my $grouplabel    = $self->param('grouplabel') || '';

    my $das = Bio::Das::Lite->new({
        'dsn' => $source.'/'.$dsn,
        'http_proxy' => $ENV{'http_proxy'},
                                  });

    # Default timeout was 5 seconds, which is not long enough for UCSC!
    # Could make it a parameter.
    $das->timeout(2 * 60);

    my $map = $self->make_map;
    my $features = $self->fetch_mapped_features_das(
        'get_all_features_via_DAS',
        [$self, $das, $chr_name, $analysis_name,
         $feature_kind, $sieve, $grouplabel],
        $map);

    return $features;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

