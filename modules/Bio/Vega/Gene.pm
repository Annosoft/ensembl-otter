package Bio::Vega::Gene;

use strict;
use warnings;
use Bio::EnsEMBL::Utils::Argument qw ( rearrange );
use Bio::EnsEMBL::Utils::Exception qw ( throw warning );
use Bio::Vega::Utils::Attributes;
use base 'Bio::EnsEMBL::Gene';


sub new {
  my ($class, @args) = @_;
  my $self = $class->SUPER::new(@args);
  my ($gene_author)  = rearrange([qw(AUTHOR)],@args);
  $self->gene_author($gene_author);
  return $self;
}

sub gene_author {
  my ($self, $value) = @_;
  if( defined $value) {
      if ($value->isa("Bio::Vega::Author")) {
          $self->{'gene_author'} = $value;
      } else {
          throw("Argument to gene_author must be a Bio::Vega::Author object.  Currently is [$value]");
      }
  }
  return $self->{'gene_author'};
}

sub source  {
  my ($self, @args) = @_;

  $self->{'source'} = shift @args if( @args );
  return ( $self->{'source'} || "havana" );
}

sub vega_hashkey {
    my ($self) = @_;

    my $seq_region_name = $self->seq_region_name
        || throw(  'seq_region_name must be set to generate vega_hashkey');
    my $start           = $self->seq_region_start
        || throw( 'seq_region_start must be set to generate vega_hashkey');
    my $end             = $self->seq_region_end 
        || throw(   'seq_region_end must be set to generate vega_hashkey');
    my $strand          = $self->seq_region_strand
        || throw('seq_region_strand must be set to generate vega_hashkey');
    my $biotype         = $self->biotype        
        || throw(          'biotype must be set to generate vega_hashkey');
    my $status          = $self->status         
        || throw(           'status must be set to generate vega_hashkey');
    my $source          = $self->source         
        || throw(           'source must be set to generate vega_hashkey');

    my $tran_count = scalar @{$self->get_all_Transcripts}
        || throw("there are no transcripts for this gene to generate correct vega_hashkey");

    my $description = $self->description || '';
    my $attrib_string = $self->Bio::Vega::Utils::Attributes::all_Attributes_string;

    return join '-'
        , $seq_region_name, $start, $end, $strand
        , $biotype, $status, $source, $description, $tran_count, $attrib_string
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
        description
        transcript_count
        all_attrib_string
        );
}

sub vega_hashkey_sub {

  my ($self) = @_;
  my $vega_hashkey_sub={};
  my $trans=$self->get_all_Transcripts;
  foreach my $tran (@$trans){
      $vega_hashkey_sub->{$tran->stable_id}='transcript-stable-id';
  }
  return $vega_hashkey_sub;

}


=head2 truncated_flag

Either TRUE or FALSE (1 or 0), it flags whether
the gene contains all its components that are
stored in the database, and hence whether it is
editable in the client.  Defaults to 0.

=cut

sub truncated_flag {
  my ($self, $flag) = @_;
  if (defined $flag) {
      $self->{'truncated_flag'} = $flag ? 1 : 0;
  }
  return $self->{'truncated_flag'} || 0;
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

sub dissociate {
    my ($self) = @_;

    $self->dbID(undef);
    $self->adaptor(undef);
    foreach my $tran (@{ $self->get_all_Transcripts() }) {
        $tran->dbID(undef);
        $tran->adaptor(undef);
        # NB: exons do not need to be duplicated
        if ($tran->translation){
            $tran->translation->dbID(undef);
            $tran->translation->adaptor(undef);
        }
    }

    return;
}

sub attach_slice {
    my ($self, $slice) = @_;

    $self->slice($slice);
    foreach my $tsct (@{$self->get_all_Transcripts}) {
        $tsct->slice($slice);
    }
    foreach my $exon (@{$self->get_all_Exons}) {
        $exon->slice($slice);
    }

    return;
}

# keep track of all unique exons found so far to avoid making duplicates
# share exons of a gene among all transcripts
# need to be very careful about translation->start_exon and translation->end_Exon
sub prune_Exons {
  my ($self) = @_;

  my( %stable_key, %unique_exons );
  foreach my $tran (@{$self->get_all_Transcripts}) {
      my (@transcript_exons);
      foreach my $exon (@{$tran->get_all_Exons}) {
          my $exon_key = $exon->vega_hashkey;
          if (my $found = $unique_exons{$exon_key}) {
              # Use the found exon in the translation
              if ($tran->translation) {
                  if ($exon == $tran->translation->start_Exon) {
                      $tran->translation->start_Exon($found);
                  }
                  if ($exon == $tran->translation->end_Exon) {
                      $tran->translation->end_Exon($found);
                  }
              }
              # re-use existing exon in this transcript
              $exon = $found;
          } else {
              $unique_exons{$exon_key} = $exon;
          }
          push (@transcript_exons, $exon);
          # Make sure we don't have the same stable IDs
          # for different exons (different keys).
          if (my $stable = $exon->stable_id) {
              if (my $seen_key = $stable_key{$stable}) {
                  if ($seen_key ne $exon_key) {
                      warn  "Exon '$exon_key': already seen exon_id '$stable' on different exon '$seen_key'.\n";
                      $exon->stable_id(undef);
                  }
              } else {
                  $stable_key{$stable} = $exon_key;
              }
          }
      }
      $tran->flush_Exons;
      foreach my $exon (@transcript_exons) {
          $tran->add_Exon($exon);
      }
  }

  return;
}


sub set_biotype_status_from_transcripts {
    my ($self) = @_;

    my (%tsct_biotype, %tsct_status);
    foreach my $tsct (@{$self->get_all_Transcripts}) {
        # Ignore "not for VEGA" transcripts when setting gene biotype
        next if grep {$_->value eq 'not for VEGA'} @{ $tsct->get_all_Attributes('remark') };
        $tsct_biotype{$tsct->biotype}++;
        $tsct_status{ $tsct->status }++;
    }

    # Have already set status to KNOWN if Known was set in acedb.
    unless ($self->is_known) {
        # Not setting gene status to KNOWN if there is a transcript
        # with status KNOWN.  So KNOWN is only set if radio button in
        # otterlace is checked.
        my $status = 'UNKNOWN';
        if ($tsct_status{'PUTATIVE'} and keys(%tsct_status) == 1) {
            # Gene status is PUTATIVE if that is the only kind of transcript
            $status = 'PUTATIVE';
        }
        elsif ($tsct_status{'NOVEL'}

            or $tsct_biotype{'protein_coding'}
            or $tsct_biotype{'nonsense_mediated_decay'}

            or $tsct_biotype{'processed_transcript'}
            or $tsct_biotype{'non_coding'}
            or $tsct_biotype{'ambiguous_orf'}
            or $tsct_biotype{'retained_intron'}
            or $tsct_biotype{'antisense'}
            or $tsct_biotype{'disrupted_domain'}

            )
        {
            $status = 'NOVEL';
        }
        $self->status($status);
    }

    # For each polymorphic gene set the biotype according to that of it's transcripts:
    # 1. transcribed_unprocessed_pseudogene will also have a transcript, call them 'transcribed_unprocessed_pseudogene'
    # 2. same follows for 'transcribed_processed_pseudogene'.
    # 3. unitary_pseudogene with a transcript will be 'transcribed_unitary_pseudogene'.
    # 4. polymorphic_pseudogene with a coding transcript will be 'polymorphic'.
    # 5. polymorphic_pseudogene with a transcript will be 'polymorphic_pseudogene'.


    my $biotype = 'processed_transcript';
    if (my @pseudo = grep { /pseudo/i } keys %tsct_biotype) {
        if (@pseudo > 1) {
            throw(
                sprintf "More than one pseudogene type in gene %s (%s)",
                    $self->get_all_Attributes('name')->[0]->value,
                    join(', ', @pseudo)
                );
        }
        else {
            $biotype = $pseudo[0];
        }
    }
    elsif ($tsct_biotype{'protein_coding'}) {
        $biotype = 'protein_coding';
    }
    elsif (keys %tsct_biotype == 1
        and ($tsct_biotype{'ig_segment'}
          or $tsct_biotype{'ig_gene'}
          or $tsct_biotype{'transposon'}
          or $tsct_biotype{'artifact'}
          or $tsct_biotype{'tec'}
            )
        )
    {
        # If there is just 1 transcript biotype, then the gene gets it too.
        ($biotype) = keys %tsct_biotype;
    }
    $self->biotype($biotype);

    return;
}



1;

__END__

=head1 NAME - Bio::Vega::Gene

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

