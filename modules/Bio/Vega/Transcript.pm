package Bio::Vega::Transcript;

use strict;
use warnings;
use Bio::EnsEMBL::Utils::Argument qw ( rearrange );
use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::Vega::Utils::Attributes;
use Bio::Vega::Evidence;
use Bio::Vega::Translation;

use base 'Bio::EnsEMBL::Transcript';

sub new {
  my ($class, @args) = @_;
  my $self = $class->SUPER::new(@args);
  my ($transcript_author,$evidence_list)  = rearrange([qw(AUTHOR EVIDENCE)],@args);
  $self->transcript_author($transcript_author);
  if (defined($evidence_list)) {
      if (ref($evidence_list) eq "ARRAY") {
          $self->evidence_list($evidence_list);
      } else {
          $self->throw( "Argument to evidence must be an array ref. Currently [$evidence_list]");
      }
  }
  return $self;
}

sub new_dissociated_copy {
    my ($self) = @_;

    my $pkg = ref($self);
    my $copy = $pkg->new_fast(+{
        map { $_ => $self->{$_} } (
            'analysis',         # ok to share object?
            'biotype',
            'created_date',
            'description',
            'display_xref',     # ok to share object?
            'edits_enabled',
            'end',
            'external_db',
            'external_name',
            'external_status',
            'is_current',
            'modified_date',
            'slice',            # ok to share object?
            'source',           # unsed here, when introduced in e75
            'stable_id',
            'start',
            'status',
            'strand',
            'transcript_author',
            'version',
        )
                               });

    my ($start_exon, $end_exon);
    my ($new_start_exon, $new_end_exon);
    my $translation = $self->translation;
    if ($translation) {
        $start_exon = $translation->start_Exon;
        $end_exon   = $translation->end_Exon;
    }

    foreach my $ex ( @{$self->get_all_Exons} ) {
        my $new_ex = $ex->new_dissociated_copy;
        $copy->add_Exon($new_ex);
        if ($translation) {
            $new_start_exon = $new_ex if $start_exon == $ex;
            $new_end_exon   = $new_ex if $end_exon   == $ex;
        }
    }

    my @evidence_list;
    foreach my $ev ( @{$self->evidence_list} ) {
        my $ev_pkg = ref($ev);
        push @evidence_list, $ev_pkg->new(-name => $ev->name, -type => $ev->type);
    }
    $copy->evidence_list(\@evidence_list);

    $copy->translation($translation->new_dissociated_copy($copy, $new_start_exon, $new_end_exon)) if $translation;

    foreach my $at ( @{$self->get_all_Attributes} ) {
        my $at_pkg = ref($at);
        $copy->add_Attributes($at_pkg->new_fast({%$at}));
    }

    return $copy;
}

sub get_all_Exons_ref {
    my ($self) = @_;

    $self->get_all_Exons;
    my $ref = $self->{'_trans_exon_array'};
    $self->throw("'_trans_exon_array' not set") unless $ref;
    return $ref;
}

sub transcript_author {
  my ($self, $value) = @_;
  if( defined $value) {
      if ($value->isa("Bio::Vega::Author")) {
          $self->{'transcript_author'} = $value;
      } else {
          throw("Argument to transcript_author must be a Bio::Vega::Author object.  Currently is [$value]");
      }
  }
  return $self->{'transcript_author'};
}

sub evidence_list {
    my ($self, $given_list) = @_;

    my $stored_list = $self->{'evidence_list'} ||= [];

    if ($given_list) {
            # don't copy the arrayref, copy the elements instead:
        my $class = 'Bio::Vega::Evidence';
        foreach my $evidence (@$given_list) {
            unless( $evidence->isa($class) ) {
                throw( "evidence_list can only store objects of '$class', not $evidence" );
            }
        }
        push @$stored_list, @$given_list;
    }
    return $stored_list;
}

sub truncate_to_Slice {
  my ($self, $slice) = @_;
  # start and end exon are set to zero so that we can
  # safely use them in "==" without generating warnings
  # as we loop through the list of exons.
  ### Not used until we enable translation truncating
  my $start_exon = 0;
  my $end_exon   = 0;
  my( $tsl );
  if ($tsl = $self->translation) {
      $start_exon = $tsl->start_Exon;
      $end_exon   = $tsl->end_Exon;
  }
  my $exons_truncated = 0;
  my $in_translation_zone = 0;
  my $slice_length = $slice->length;

  # Ref to list of exons for inplace editing
  my $ex_list = $self->get_all_Exons_ref;

  for (my $i = 0; $i < @$ex_list;) {
      my $exon = $ex_list->[$i];
      my $exon_start = $exon->start;
      my $exon_end   = $exon->end;
      # now compare slice names instead of slice references
      # slice references can be different not the slice names
      if ($exon->slice->name ne $slice->name or $exon_end < 1 or $exon_start > $slice_length) {
          #warn "removing exon that is off slice";
          splice(@$ex_list, $i, 1);
          $exons_truncated++;
      } else {
          #warn sprintf
          #    "Checking if exon %s is within slice %s of length %d\n"
          #    . "  being attached to %s and extending from %d to %d\n",
          #    $exon->stable_id, $slice, $slice_length, $exon->contig, $exon_start, $exon_end;
          $i++;
          my $trunc_flag = 0;
          if ($exon->start < 1) {
              #warn "truncating exon that overlaps start of slice";
              $trunc_flag = 1;
              $exon->start(1);
          }
          if ($exon->end > $slice_length) {
              #warn "truncating exon that overlaps end of slice";
              $trunc_flag = 1;
              $exon->end($slice_length);
          }
          $exons_truncated++ if $trunc_flag;
      }
  }
  ### Hack until we fiddle with translation stuff
  if ($exons_truncated) {
      $self->{'translation'}     = undef;
      $self->{'_translation_id'} = undef;
      my $attrib = $self->get_all_Attributes;
      for (my $i = 0; $i < @$attrib;) {
          my $this = $attrib->[$i];
          # Should not have CDS start/end not found attributes
          # if there is no CDS!
          if ($this->code =~ /^cds_(start|end)_NF$/) {
              splice(@$attrib, $i, 1);
          } else {
              $i++;
          }
      }
  }
  return $exons_truncated;
}

sub vega_hashkey {
  my ($self) = @_;

  my $seq_region_name   = $self->seq_region_name
      || throw(  'seq_region_name must be set to generate correct vega_hashkey.');
  my $seq_region_start  = $self->seq_region_start
      || throw( 'seq_region_start must be set to generate correct vega_hashkey.');
  my $seq_region_end    = $self->seq_region_end
      || throw(   'seq_region_end must be set to generate correct vega_hashkey.');
  my $seq_region_strand = $self->seq_region_strand
      || throw('seq_region_strand must be set to generate correct vega_hashkey.');
  my $biotype           = $self->biotype
      || throw(          'biotype must be set to generate correct vega_hashkey.');
  my $status            = $self->status
      || throw(           'status must be set to generate correct vega_hashkey.');
  my $source          = $self->source
      || throw(           'source must be set to generate correct vega_hashkey');

  my $exon_count = scalar @{$self->get_all_Exons}
      || throw("there are no exons for this transcript to generate correct vega_hashkey");
  my $description = $self->{'description'} ? $self->{'description'}: '' ;
  my $attrib_string = $self->Bio::Vega::Utils::Attributes::all_Attributes_string;

  my $evidence_count = scalar(@{$self->evidence_list});

  return join '-'
      , $seq_region_name, $seq_region_start, $seq_region_end, $seq_region_strand
      , $biotype, $status, $source, $exon_count, $description, $evidence_count, $attrib_string
      ;
}

sub vega_hashkey_structure {
    return join '-', qw(
        seq_region_name
        seq_region_start
        seq_region_end
        seq_region_strand
        biotype
        status
        source
        exon_count
        description
        evidence_count
        attrib_string
        );
}

sub vega_hashkey_sub {
  my ($self) = @_;

  my $evidence=$self->evidence_list();
  my $vega_hashkey_sub={};

  if (defined $evidence) {
      foreach my $evi (@$evidence){
          my $e=$evi->name.$evi->type;
          $vega_hashkey_sub->{$e}='evidence';
      }
  }
  my $exons=$self->get_all_Exons;

  foreach my $exon (@$exons){
      $vega_hashkey_sub->{$exon->stable_id}='exon_stable_id';
  }
  return $vega_hashkey_sub;

}

sub translatable_Exons_vega_hashkey {
    my ($self) = @_;

    return join('+', map { $_->vega_hashkey } @{$self->get_all_translateable_Exons});
}

# This is to be used by storing mechanism of GeneAdaptor,
# to simplify the loading during comparison.

sub last_db_version {
    my ($self, @args) = @_;

    if(@args) {
        $self->{_last_db_version} = shift @args;
    }
    return $self->{_last_db_version};
}


1;

__END__

=head1 NAME - Bio::Vega::Transcript

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

