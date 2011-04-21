
package Bio::Otter::MFetcher;

# Previously a part of ServerScriptSupport,
# this module only deals with data layer:
# interprets the metakeys to create and manage DBAdaptors
# and performs mapping between assemblies.
#
# Author: lg4

use strict;
use warnings;
use Carp;

use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Variation::DBSQL::DBAdaptor;
use Bio::Vega::DBSQL::DBAdaptor;

use base ('Bio::Otter::SpeciesDat');

sub new { # just to make it possible to instantiate an object
    my ($pkg, @arguments) = @_;

    my $self = bless { @arguments }, $pkg;

    return $self;
}

sub dataset_name {
    my( $self, $dataset_name ) = @_;

    if($dataset_name) {
        $self->{'_dataset_name'} = $dataset_name;
    }
    return $self->{'_dataset_name'};
}

sub current_dataset_param {
    my ($self, $param_name) = @_;

    return $self->get_dataset_param( $self->dataset_name() , $param_name);
}

sub otter_dba {
    my ($self, @args) = @_;

    if($self->{'_odba'} && !scalar(@args)) {   # cached value and no override
        return $self->{'_odba'};
    }

    my $adaptor_class = 'Bio::Vega::DBSQL::DBAdaptor';

    if(@args) { # let's check that the class is ok
        my $odba = shift @args;
        if(eval { $odba->isa($adaptor_class) }) {
            return $self->{'_odba'} = $odba;
        } else {
            die "The object you assign to otter_dba must be a '$adaptor_class'";
        }
    }


    my( $odba, $dnadb );

    if(my $dbname = $self->current_dataset_param('DBNAME')) {
        die "Failed opening otter database [$@]" unless eval {
           $odba = $adaptor_class->new( -host       => $self->current_dataset_param('HOST'),
                                        -port       => $self->current_dataset_param('PORT'),
                                        -user       => $self->current_dataset_param('USER'),
                                        -pass       => $self->current_dataset_param('PASS'),
                                        -dbname     => $dbname,
                                        -group      => 'otter',
                                        -species    => $self->dataset_name,
                                        );
           1;
        };

        warn "Connected to otter database\n";
    } else {
        die "Failed opening otter database [No database name]";
    }

    if(my $dna_dbname = $self->current_dataset_param('DNA_DBNAME')) {
        die "Failed opening dna database [$@]" unless eval {
            $dnadb = new Bio::EnsEMBL::DBSQL::DBAdaptor( -host      => $self->current_dataset_param('DNA_HOST'),
                                                         -port      => $self->current_dataset_param('DNA_PORT'),
                                                         -user      => $self->current_dataset_param('DNA_USER'),
                                                         -pass      => $self->current_dataset_param('DNA_PASS'),
                                                         -dbname    => $dna_dbname,
                                                         -group     => 'dnadb',
                                                         -species   => $self->dataset_name,
                                                         );
            1;
        };
        $odba->dnadb($dnadb);

        warn "Connected to dna database\n";
    }

    return $self->{'_odba'} = $odba;
}

sub default_assembly {
    my ($self, $dba) = @_;

    my ($asm_def) = @{ $dba->get_MetaContainer()->list_value_by_key('assembly.default') };

    return $asm_def || 'UNKNOWN';
}

sub pipeline_dba {
    my ($self) = @_;
    return $self->satellite_dba('pipeline_db_head');
}

sub satellite_dba {
    my ($self, $metakey) = @_;

    $metakey ||= 'pipeline_db_head';

    # check for a cached dba
    my $dba_cached = $self->{_sdba}{$metakey};
    return $dba_cached if $dba_cached;

    # get and check the options
    my $options = $self->satellite_dba_options($metakey);
    die "metakey '$metakey' is not defined" unless $options;

    # special case, '.' means the Otter database
    return $self->otter_dba if $options eq '.';

    # create the adaptor
    my $adaptor_class = "Bio::EnsEMBL::DBSQL::DBAdaptor";
    my $dba = $self->satellite_dba_make($metakey, $adaptor_class, $options);

    # re-bless if necessary
    bless $dba,'Bio::Vega::DBSQL::DBAdaptor'
        if lc($self->default_assembly($dba)) eq 'otter';

    # create the variation database (if there is one)
    my $vdba = $self->variation_satellite_dba_make("${metakey}_variation");
    $vdba->dnadb($dba) if $vdba;

    return $dba;
}

sub variation_satellite_dba_make {
    my ($self, $metakey) = @_;

    # check for a cached dba
    my $dba = $self->{_sdba}{$metakey};
    return $dba if $dba;

    # get and check the options
    my $options = $self->satellite_dba_options($metakey);
    return unless $options;

    # special case, '.' means the Otter database
    die "cannot specify the otter database for a variation database"
        if $options eq '.';

    # create the adaptor
    my $adaptor_class = "Bio::EnsEMBL::Variation::DBSQL::DBAdaptor";
    $dba = $self->satellite_dba_make($metakey, $adaptor_class, $options);

    return $dba;
}

sub satellite_dba_make {
    my ($self, $metakey, $adaptor_class, $options) = @_;

    warn "connecting to the satellite DB '$metakey'...\n";

    my @options;
    {
        ## no critic(BuiltinFunctions::ProhibitStringyEval)
        @options = eval $options;
    }
    die "Error evaluating '$options' : $@" if $@;

    my %anycase_options = (
         -group     => $metakey,
         -species   => $self->dataset_name,
        @options,
    );

    my %uppercased_options = ();
    while( my ($k,$v) = each %anycase_options) {
        $uppercased_options{uc($k)} = $v;
    }

    my $dba = $adaptor_class->new(%uppercased_options);
    die "Couldn't connect to '$metakey' satellite db"
        unless $dba;

    warn "... with parameters: ".join(', ', map { "$_=".$uppercased_options{$_} } keys %uppercased_options )."\n";

    $self->{_sdba}{$metakey} = $dba;

    return $dba;
}

sub satellite_dba_options {
    my ($self, $metakey) = @_;

    return '.' if $metakey eq '.'; # special value, means otter_dba()

    my $meta_container = $self->otter_dba->get_MetaContainer;

    while(1) {
        my ($options) = @{ $meta_container->list_value_by_key($metakey) };

        return unless $options; # nothing found, give up
        return '.' if $options eq '=otter';  # special value, means otter_dba()

        # check for redirects
        if ($options eq '=pipeline') { # redirect to the pipeline
            $metakey = 'pipeline_db_head';
            next;
        }
        if ($options =~ /^\=(\w+)$/) { # redirect to another metakey
            $options = $1;
            next;
        }

        return $options;
    }

    return;
}

sub get_slice {
    my ($self, $dba, $cs, $name, $type, $start, $end, $csver) = @_;

    my $slice;

    $cs ||= 'chromosome'; # can't make a slice without cs

    if(!$csver && ($cs eq 'chromosome')) {
        $csver = 'Otter';
    }

    # The following statement ensures
    # that we use 'assembly type' as the chromosome name
    # only for Otter chromosomes.
    # EnsEMBL chromosomes will have simple names.
    my ($segment_attr, $segment_name) = (($cs eq 'chromosome') && ($csver eq 'Otter'))
        ? ('type', $type)
        : ('name', $name);

    die "$cs '$segment_attr' attribute not set" unless $segment_name;

    $slice =  $dba->get_SliceAdaptor()->fetch_by_region(
        $cs,
        $segment_name,
        $start,
        $end,
        1,      # somehow strand parameter is needed
        $csver,
    );
    
    # $self->check_slice($slice);

    die "Could not get a slice, probably not (yet) loaded into satellite db"
        unless $slice;

    return $slice;
}

sub check_slice {
    my ($self, $slice) = @_;
    
    my $slice_projection = $slice->project('contig');

    my (%contig_strand, @both_strands_used);
    foreach my $seg (@$slice_projection) {
        my $contig_slice = $seg->to_Slice();
        my $name    = $contig_slice->seq_region_name;
        my $strand  = $contig_slice->strand;
        if (my $ns = $contig_strand{$name}) {
            if ($ns ne 'BOTH' and $ns != $strand) {
                push(@both_strands_used, $name);
                $contig_strand{$name} = 'BOTH';
            }
        }
        else {
            $contig_strand{$name} = $strand;
        }
    }
    if (@both_strands_used) {
        my $ctg = @both_strands_used == 1 ? 'this contig uses' : 'these contigs use';
        die "Smap will fail because $ctg both strands in the assembly: @both_strands_used";
    }

    return;
}

sub otter_assembly_equiv_hash { # $self->{_aeh}{NCBI36}{11} = 'chr11-02';
    my ($self) = @_;

    if (my $aeh = $self->{'_aeh'}) {
        return $aeh;
    }

    my $sql = qq{
        SELECT ae_val.value
          , cn_val.value
          , sr.name
        FROM seq_region sr
          , seq_region_attrib ae_val
          , seq_region_attrib cn_val
          , seq_region_attrib hi_val
          , attrib_type ae_at
          , attrib_type cn_at
          , attrib_type hi_at
        WHERE sr.seq_region_id = ae_val.seq_region_id
          AND ae_val.attrib_type_id = ae_at.attrib_type_id
          AND ae_at.code = 'equiv_asm'
          AND sr.seq_region_id = cn_val.seq_region_id
          AND cn_val.attrib_type_id = cn_at.attrib_type_id
          AND cn_at.code = 'chr'
          AND hi_at.code = 'hidden'
          AND hi_val.attrib_type_id = hi_at.attrib_type_id
          AND sr.seq_region_id = hi_val.seq_region_id
          AND hi_val.value = 0
        };

    my $sth = $self->otter_dba->dbc()->prepare($sql);
    $sth->execute();

    my $aeh = $self->{'_aeh'} = {};
    while( my ($equiv_asm, $equiv_chr, $atype) = $sth->fetchrow()) {
        $aeh->{$equiv_asm}{$equiv_chr} = $atype;
    }
    return $aeh;
}

sub init_csver {
    my ($self, $cs, $metakey) = @_; # metakey can even be '.' or ''

    if($cs eq 'chromosome') {
        if(!$metakey || ($metakey eq '.')) {
            return 'Otter'; # just for saving time,
                            # as we know already that otter and pipeline databases should have 'Otter'
                            # as their meta.'assembly.default' value
        } else {
            return $self->default_assembly($self->satellite_dba($metakey));
        }
    } else {
        return;  # defaults to NULL in the DB
    }
}

    # fetch things from Otter chromosome and map them to another assembly
sub fetch_and_export {
    my ($self, $fetching_method, $call_parms,
        $cs, $name, $type, $start, $end, $csver_orig, $csver_target,
    ) = @_;

    my $odba = $self->otter_dba();
    my $slice = $self->get_slice($odba, $cs, $name, $type, $start, $end, $csver_orig);

    my $orig_features = $slice->$fetching_method(@$call_parms);

    unless($orig_features) {
        die "Fetching failed";
    }

    if ($self->otter_assembly_equiv_hash()->{$csver_target}{$name} eq $type) {
        # no transformation is needed:

        return $orig_features;

    } else {
        my $transformed_features = [];
        foreach my $orig_feature (@$orig_features) {
            if( my $target_feature = $orig_feature->transform($cs, $csver_target) ) {
                push @$transformed_features, $target_feature;
                warn "Transformed $csver_orig:".$slice->name.":".$orig_feature->start().'..'.$orig_feature->end()
                    ." --> $csver_target:".$target_feature->start().'..'.$target_feature->end()."\n";
            } else {
                warn "Could not transform the feature ".$slice->name." ".
                    $orig_feature->start().'..'.$orig_feature->end();
            }
        }

        return $transformed_features;
    }
}

sub map_remote_slice_back {
    my ($self, $remote_slice) = @_;

    my $cs              = $remote_slice->coord_system()->name();
    my $csver_remote    = $remote_slice->coord_system()->version();

    unless($cs eq 'chromosome') {
        warn "We do not yet perform mapping from $cs:$csver_remote to Otter chromosomes\n";
        return [];
    }

    my $remote_chr_name = $remote_slice->seq_region_name();
    my $odba = $self->otter_dba();
    my $local_sa = $odba->get_SliceAdaptor();

    if(my $otter_chr_name = $self->otter_assembly_equiv_hash()->{$csver_remote}{$remote_chr_name}) {
            # chromosomes are equivalent, re-create the slice on loutre_db:

        my $local_slice = $local_sa->fetch_by_region(
            'chromosome',
            $otter_chr_name,
            $remote_slice->start(),
            $remote_slice->end(),
            $remote_slice->strand(),
            'Otter',
        );

        return [ $local_slice ];

    } else {
        my $remote_slice_2 = $local_sa->fetch_by_region(
            $remote_slice->coord_system()->name(),
            $remote_slice->seq_region_name(),
            $remote_slice->start(),
            $remote_slice->end(),
            $remote_slice->strand(),
            $remote_slice->coord_system()->version(),
            );

        my @local_slices = ();
        foreach my $proj_segment (@{ $remote_slice_2->project('chromosome', 'Otter') }) {
            my $local_slice_2 = $proj_segment->to_Slice();

            my $local_slice = $local_sa->fetch_by_region(
                $local_slice_2->coord_system()->name(),
                $local_slice_2->seq_region_name(),
                $local_slice_2->start(),
                $local_slice_2->end(),
                $local_slice_2->strand(),
                $local_slice_2->coord_system()->version(),
                );
            push @local_slices, $local_slice;
        }

        if(my $results = scalar(@local_slices)) {
            if($results>1) {
                warn "Could not uniquely map '$csver_remote' slice to 'Otter' (got $results pieces)\n";
            }
        } else {
            warn "Could not map '$csver_remote' slice to 'Otter' at all\n";
        }
        return \@local_slices;
    }

    return [];
}

sub fetch_mapped_features {
    my ($self, $feature_name, $fetching_method, $call_parms,
        $cs, $name, $type, $start, $end, $metakey, $csver_orig, $csver_remote,
        $das_style_mapping,
    ) = @_;

    $metakey      ||= ''; # defaults to pipeline
    $cs           ||= 'chromosome';
    $csver_orig   ||= $self->init_csver($cs, '');
    $csver_remote ||= $self->init_csver($cs, $metakey);

    my $features = [];

    if( ($cs ne 'chromosome') || ($csver_orig eq $csver_remote)
       || ( ($self->otter_assembly_equiv_hash()->{$csver_remote}{$name} || '') eq $type) ) {
                # no mapping, just (cross)-fetching:

        my $csver_target = (!$metakey || ($metakey eq '.'))
                ? $csver_orig
                : $csver_remote;

        warn "Assuming the mappings to be identical, just fetching from {$metakey}$cs:$csver_target\n";

        my $sdba = $self->satellite_dba( $metakey );
        my $original_slice = $self->get_slice($sdba, $cs, $name, $type, $start, $end, $csver_target);

        $features = $original_slice->$fetching_method(@$call_parms);

        unless($features) {
            die "Fetching failed";
        }

    } else { # let's try to do the mapping:
        warn "Proceeding with mapping code\n";

        my $odba = $self->otter_dba();
        my $original_slice_2 = $self->get_slice($odba, $cs, $name, $type, $start, $end, $csver_orig);
        my $proj_segments_2;
        die "Unable to project: $type:$csver_orig($start..$end)->$csver_remote. Check the mapping.\n$@"
            unless eval {
            $proj_segments_2 = $original_slice_2->project( $cs, $csver_remote );
            # Try to map to scaffold if coordinate system exists and mapping to chromosome failed
            # allow getting ensembl objects from Zfish scaffolds
            if(!@$proj_segments_2 && $odba->get_CoordSystemAdaptor->fetch_by_name('scaffold',$csver_remote)) {
                $proj_segments_2 = $original_slice_2->project( 'scaffold', $csver_remote );
            }
            1;
        } && @$proj_segments_2;
        warn "Found ".scalar(@$proj_segments_2)." projection segments on mapper when projecting to $cs:$csver_remote\n";

        # group the projected slices by their chromosome and,
        # for each chromosome, calculate the endpoints of the
        # slice that just covers all the projected slices on
        # that chromosome

        my $amalgamated_endpoints = { };
        my $proj_slices_2;

        foreach my $segment (@$proj_segments_2) {
            my $slice = $segment->to_Slice;
            my $chromosome = $slice->seq_region_name;
            my $start0 = $amalgamated_endpoints->{$chromosome}[0];
            my $start1 = $slice->start;
            my $end0 = $amalgamated_endpoints->{$chromosome}[1];
            my $end1 = $slice->end;
            $amalgamated_endpoints->{$chromosome}[0] = $start1 unless
                defined $start0 && $start0 <= $start1;
            $amalgamated_endpoints->{$chromosome}[1] = $end1 unless
                defined $end0 && $end0 >= $end1;
        }

        # create the amalgamated slices
        my $strand = $original_slice_2->strand;
        my $adaptor = $original_slice_2->adaptor;
        $proj_slices_2 = [ map {
            my $seq_region_name = $_;
            my ( $start, $end ) = @{$amalgamated_endpoints->{$_}};
            $adaptor->fetch_by_region($cs, $seq_region_name,
                                      $start, $end, $strand, $csver_remote,);
                                   } keys %$amalgamated_endpoints ];

        if($das_style_mapping) { # In this mode there is no target_db involved.
            # Features are put directly on the mapper target slice and then mapped back.
            foreach my $projected_slice_2 (@$proj_slices_2) {

                my $target_fs_2_segment
                    = $projected_slice_2->$fetching_method(@$call_parms);

                warn '***** : '.scalar(@$target_fs_2_segment)." ${feature_name}s created on the slice\n";

                while (my $target_feature = shift @$target_fs_2_segment) {
                    my $fname = sprintf( "%s [%d..%d]",
                                         $target_feature->display_id(),
                                         $target_feature->start(),
                                         $target_feature->end() );
                    warn "Transferring $feature_name $fname from {".$target_feature->slice->name
                        ."} onto {".$original_slice_2->name."}\n";
                    if( my $transferred = $target_feature->transfer($original_slice_2) ) {
                        push @$features, $transferred;
                        warn "Transfer OK\n";
                    } else {
                        warn "Transfer failed\n";
                    }
                }
            }

        } else { # full mapping with target database involved

            my $sdba = $self->satellite_dba( $metakey );
            my $sa_on_target = $sdba->get_SliceAdaptor();

          SEGMENT: foreach my $projected_slice_2 (@$proj_slices_2) {

              my $target_slice_on_target = $sa_on_target->fetch_by_region(
                  $projected_slice_2->coord_system()->name(),
                  $projected_slice_2->seq_region_name(),
                  $projected_slice_2->start(),
                  $projected_slice_2->end(),
                  $projected_slice_2->strand(),
                  $projected_slice_2->coord_system()->version(),
                  );

              unless($target_slice_on_target) {
                  warn "MFetcher: cannot create the slice ["
                      .$projected_slice_2->coord_system()->name()
                      .':'
                      .$projected_slice_2->seq_region_name()
                      .':'
                      .$projected_slice_2->start()
                      .':'
                      .$projected_slice_2->end()
                      .':'
                      .$projected_slice_2->strand()
                      .':'
                      .$projected_slice_2->coord_system()->version()
                      ."] on target, please check the target.\n";
                  next SEGMENT; # it may be mappable, but not applicable!
              }

              my $target_fs_on_target_segment
                  = $target_slice_on_target->$fetching_method(@$call_parms);

              unless($target_fs_on_target_segment) {
                  die "Fetching failed";
              }

              warn '***** : '.scalar(@$target_fs_on_target_segment)." ${feature_name}s found on the slice $metakey:".$target_slice_on_target->start().'..'.$target_slice_on_target->end()."\n";

              # foreach my $target_feature (@$target_fs_on_target_segment) {
              # This is supposed to be faster:
              while (my $target_feature = shift @$target_fs_on_target_segment) {

                  if($target_feature->can('propagate_slice')) {
                      $target_feature->propagate_slice($projected_slice_2);
                  } else {
                      $target_feature->slice($projected_slice_2);
                  }

                  my $fname = sprintf( "%s [%d..%d]",
                                       $target_feature->display_id(),
                                       $target_feature->start(),
                                       $target_feature->end() );
                  warn "Transferring $feature_name $fname from {".$target_feature->slice->name
                      ."} onto {".$original_slice_2->name."}\n";
                  if( my $transferred = $target_feature->transfer($original_slice_2) ) {
                      push @$features, $transferred;
                      warn "Transfer OK".ref($transferred)."\n";
                  } else {
                      warn "Transfer failed\n";
                  }
              } # for each feature
          } # for each segment
        }
    }

    warn "Total of ".scalar(@$features).' '.join('/', grep { defined($_) && !ref($_) } @$call_parms)
              ." ${feature_name}s have been sent to the client\n";

    return $features;
}

sub Bio::EnsEMBL::Gene::propagate_slice {
    my ($gene, $slice) = @_;

    foreach my $transcript (@{ $gene->get_all_Transcripts }) {
        $transcript->slice($slice);

        # We don't call get_all_Exons on the gene because sometimes each
        # transcript has its own copy of each exon (ie: same dbID, but not
        # the same object in memory).
        foreach my $exon (@{ $transcript->get_all_Exons }) {
            $exon->slice($slice);
        }
    }
    $gene->slice($slice);

    return;
}

1;

__END__

=head1 AUTHOR

Leo Gordon B<email> lg4@sanger.ac.uk


