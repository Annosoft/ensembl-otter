
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

sub new { # just to make it possible to instantiate an object
    my ($pkg, @arguments) = @_;

    my $self = bless { @arguments }, $pkg;

    return $self;
}

sub dataset {
    my( $self, $dataset ) = @_;

    if($dataset) {
        $self->{'_dataset'} = $dataset;
    }

    return $self->{'_dataset'} ||=
        $self->dataset_default;
}

sub dataset_default {
    die "no default dataset";
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

    return $self->{'_odba'} ||=
        $self->dataset->otter_dba;
}

sub get_slice {
    my ($self, $dba, $cs, $name, $type, $start, $end, $csver) = @_;

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

    my $slice = $dba->get_SliceAdaptor()->fetch_by_region(
        $cs,
        $segment_name,
        $start,
        $end,
        1,      # somehow strand parameter is needed
        $csver,
    );

    die "Could not get a slice, probably not (yet) loaded into satellite db"
        unless $slice;

    return $slice;
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
        if (my $have_a_type = $aeh->{$equiv_asm}{$equiv_chr}) {
            die "Already have chromosome '$have_a_type' for '$equiv_asm.$equiv_chr', will not overwrite with '$atype'";
        }
        else {
            $aeh->{$equiv_asm}{$equiv_chr} = $atype;
        }
    }
    return $aeh;
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

sub _default_assembly {
    my ($dba) = @_;
    my ($assembly) = @{ $dba->get_MetaContainer()->list_value_by_key('assembly.default') };
    die "no default assembly" unless $assembly;
    return $assembly;
}

sub fetch_mapped_features_ensembl {
    my ($self, $fetching_method, $call_parms, $map, $metakey) = @_;

    my ($cs, $name, $type, $start, $end, $csver_orig, $csver_remote) =
        @{$map}{qw( cs name type start end csver csver_remote )};

    confess "invalid coordinate system: '${cs}'"
        unless $cs eq 'chromosome';
    confess "invalid coordinate system version: '${csver_orig}'"
        unless $csver_orig eq 'Otter';

    if (! $csver_remote && $metakey) {
        my $sdba = $self->dataset->satellite_dba( $metakey );
        my $assembly = _default_assembly($sdba);
        $csver_remote = $map->{csver_remote} = $assembly
    }

    my $features = [];

    if(!$metakey) { # fetch from the pipeline
        my $pdba = $self->dataset->pipeline_dba;
        my $slice = $self->get_slice($pdba, $cs, $name, $type, $start, $end, $csver_orig);
        $features = $slice->$fetching_method(@$call_parms);
    }
    elsif( ($self->otter_assembly_equiv_hash()->{$csver_remote}{$name} || '') eq $type) {
        # no mapping, just (cross)-fetching:
        warn "Assuming the mappings to be identical, just fetching from {$metakey}$cs:$csver_remote\n";
        my $sdba = $self->dataset->satellite_dba( $metakey );
        my $original_slice = $self->get_slice($sdba, $cs, $name, $type, $start, $end, $csver_remote);
        $features = $original_slice->$fetching_method(@$call_parms);
    } else { # let's try to do the mapping:
        warn "Proceeding with mapping code\n";

        my $odba = $self->otter_dba;
        my $original_slice_2 = $self->get_slice($odba, $cs, $name, $type, $start, $end, $csver_orig);
        my $proj_slices_2 = $self->fetch_mapped_slices($original_slice_2, $map);

        my $sdba = $self->dataset->satellite_dba( $metakey );
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

          # foreach my $target_feature (@$target_fs_on_target_segment) {
          # This is supposed to be faster:
          while (my $target_feature = shift @$target_fs_on_target_segment) {

              if($target_feature->can('propagate_slice')) {
                  $target_feature->propagate_slice($projected_slice_2);
              } else {
                  $target_feature->slice($projected_slice_2);
              }

              if( my $transferred = $target_feature->transfer($original_slice_2) ) {
                  push @$features, $transferred;
                  warn "Transfer OK".ref($transferred)."\n";
              } else {
                  warn "Transfer failed\n";
              }
          } # for each feature
      } # for each segment
    }

    return $features;
}

sub fetch_mapped_features_das {
    my ($self, $fetching_method, $call_parms, $map) = @_;

    my ($cs, $name, $type, $start, $end, $csver_orig, $csver_remote) =
        @{$map}{qw( cs name type start end csver csver_remote )};

    confess "invalid coordinate system: '${cs}'"
        unless $cs eq 'chromosome';
    confess "invalid coordinate system version: '${csver_orig}'"
        unless $csver_orig eq 'Otter';

    if( ($self->otter_assembly_equiv_hash()->{$csver_remote}{$name} || '') eq $type) {
        warn "fetch_mapped_features_das(): no mapping\n";
        my $odba = $self->otter_dba;
        my $slice = $self->get_slice($odba, $cs, $name, $type, $start, $end, $csver_orig);
        return $slice->$fetching_method(@$call_parms);
    }
    else { # let's try to do the mapping:
        warn "fetch_mapped_features_das(): mapping\n";

        my $odba = $self->otter_dba;
        my $slice = $self->get_slice($odba, $cs, $name, $type, $start, $end, $csver_orig);
        my $proj_slices_2 = $self->fetch_mapped_slices($slice, $map);

        # Features are put directly on the mapper target slice and then mapped back.
        my $features = [ ];
        foreach my $projected_slice_2 (@$proj_slices_2) {
            my $target_fs_2_segment
                = $projected_slice_2->$fetching_method(@$call_parms);
            while (my $target_feature = shift @$target_fs_2_segment) {
                if( my $transferred = $target_feature->transfer($slice) ) {
                    push @$features, $transferred;
                    warn "Transfer OK\n";
                } else {
                    warn "Transfer failed\n";
                }
            }
        }

        return $features;

    }
}

sub fetch_mapped_slices {
    my ($self, $slice, $map) = @_;

    my ($cs, $csver_remote) =
        @{$map}{qw( cs csver_remote )};

    my $segments = $self->fetch_mapped_segments($slice, $map);
    warn "Found ".scalar(@$segments)." projection segments on mapper when projecting to $cs:$csver_remote\n";

    # group the projected slices by their chromosome and,
    # for each chromosome, calculate the endpoints of the
    # slice that just covers all the projected slices on
    # that chromosome

    my $amalgamated_endpoints = { };
    foreach my $segment (@$segments) {
        my $segment_slice = $segment->to_Slice;
        my $chromosome = $segment_slice->seq_region_name;
        my $start0 = $amalgamated_endpoints->{$chromosome}[0];
        my $start1 = $segment_slice->start;
        my $end0 = $amalgamated_endpoints->{$chromosome}[1];
        my $end1 = $segment_slice->end;
        $amalgamated_endpoints->{$chromosome}[0] = $start1 unless
            defined $start0 && $start0 <= $start1;
        $amalgamated_endpoints->{$chromosome}[1] = $end1 unless
            defined $end0 && $end0 >= $end1;
    }

    # create the amalgamated slices
    my $strand = $slice->strand;
    my $adaptor = $slice->adaptor;

    return [
        map {
            my $seq_region_name = $_;
            my ( $start, $end ) = @{$amalgamated_endpoints->{$_}};
            $adaptor->fetch_by_region($cs, $seq_region_name,
                                      $start, $end, $strand, $csver_remote,);
        } keys %$amalgamated_endpoints ];
}

sub fetch_mapped_segments {
    my ($self, $slice, $map) = @_;

    my ($cs, $csver_remote) =
        @{$map}{qw( cs csver_remote )};

    my $segments;

    $segments = $slice->project( $cs, $csver_remote );
    return $segments if $segments;

    # Try to map to scaffold if coordinate system exists and mapping
    # to chromosome failed allow getting ensembl objects from Zfish
    # scaffolds

    if($self->otter_dba->get_CoordSystemAdaptor->fetch_by_name('scaffold',$csver_remote)) {
        $segments = $slice->project( 'scaffold', $csver_remote );
    }
    return $segments if $segments;

    die "unable to project";
}

sub Bio::EnsEMBL::Gene::propagate_slice {
    my ($gene, $slice) = @_;

    foreach my $transcript (@{ $gene->get_all_Transcripts }) {

        # We don't call get_all_Exons on the gene because sometimes each
        # transcript has its own copy of each exon (ie: same dbID, but not
        # the same object in memory).
        foreach my $exon (@{ $transcript->get_all_Exons }) {
            $exon->slice($slice);
        }

        # This call has to come after get_all_Exons, or the transcript
        # may attempt to lazy-load exons from the Otter database.
        $transcript->slice($slice);
    }
    $gene->slice($slice);

    return;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

