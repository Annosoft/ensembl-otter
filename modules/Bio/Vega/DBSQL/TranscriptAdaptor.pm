package Bio::Vega::DBSQL::TranscriptAdaptor;

use strict;
use warnings;

use Bio::EnsEMBL::DBSQL::BaseAdaptor;
use Bio::Vega::Transcript;
use Bio::Vega::Evidence;
use Bio::EnsEMBL::Utils::Exception qw(throw warning);

use base 'Bio::EnsEMBL::DBSQL::TranscriptAdaptor';

sub fetch_transcript_author {
  my ($self,$transcript)=@_;

  my $author= $self->db->get_AuthorAdaptor->fetch_transcript_author($transcript->dbID);
  $transcript->transcript_author($author);

  return $transcript;
}

sub fetch_evidence {
  my ($self, $transcript)=@_;

  if( !ref($transcript) || !$transcript->isa('Bio::EnsEMBL::Transcript') ) {
    throw('Transcript argument is required.');
  }
  my $tid = $transcript->dbID();
  if(!defined($tid)) {
    throw("Transcript must have dbID.");
  }
  my $sth = $self->prepare("SELECT name, type FROM evidence WHERE transcript_id = ? ");
  $sth->execute($tid);
  my $results = [];
  while  (my $ref = $sth->fetchrow_hashref) {
      my $obj=Bio::Vega::Evidence->new;
      $obj->name($ref->{name});
      $obj->type($ref->{type});
      push @$results, $obj;
  }
  $sth->finish();

  return $results;
}

sub store_Evidence {
  my ($self,$transcript_id,$evidence_list) = @_;

  unless ($evidence_list || $transcript_id) {
      throw("evidence object list :$evidence_list and transcript_id:$transcript_id must be entered to store an evidence");
  }
  # Insert new evidence
  my $sth = $self->prepare(q{
        INSERT INTO evidence(transcript_id, name, type) VALUES (?,?,?)
        });

  foreach my $evidence (@$evidence_list) {
      my $name = $evidence->name;
      my $type = $evidence->type;
      $sth->execute($transcript_id, $name, $type);
  }

  return;
}

sub remove_evidence {
    my ($self, $transcript) = @_;

    my $sth = $self->prepare(q{
        DELETE FROM evidence WHERE transcript_id = ?
        });
    $sth->execute($transcript->dbID);
    return;
}

sub reincarnate_transcript {
    my ($self, $transcript) = @_;

    my $this_class = 'Bio::Vega::Transcript';

    if ($transcript->isa($this_class)) {
        # warn "Transcript is already $this_class, probably due to caching\n";
        return $transcript;
    }

    bless $transcript, $this_class;
    $self->fetch_transcript_author($transcript);

    if (my $transl = $transcript->translation) {
        bless $transl, 'Bio::Vega::Translation';
    }

    $transcript->evidence_list($self->fetch_evidence($transcript));

    return $transcript;
}

sub fetch_by_dbID {
  my ($self, $dbID) = @_;

  my ($transcript) = $self->SUPER::fetch_by_dbID($dbID);
  if ($transcript){
      $self->reincarnate_transcript($transcript);
  }

  return $transcript;
}

sub fetch_by_stable_id  {
  my ($self, $stable_id) = @_;

  my ($transcript) = $self->SUPER::fetch_by_stable_id($stable_id);
  if ($transcript){
      $self->reincarnate_transcript($transcript);
  }

  return $transcript;
}

sub fetch_by_stable_id_version  {
  my ($self, $stable_id, $version) = @_;

  my $constraint = "t.stable_id = '$stable_id' AND t.version = $version ORDER BY t.modified_date DESC, t.transcript_id DESC LIMIT 1";
  my ($transcript) = @{ $self->generic_fetch($constraint) };
  if ($transcript){
      $self->reincarnate_transcript($transcript);
  }

  return $transcript;
}

sub fetch_all_by_Slice  {
  my ($self,$slice,$load_exons,$logic_name)  = @_;

  my ($transcripts) = $self->SUPER::fetch_all_by_Slice($slice,$load_exons,$logic_name);
  if ($transcripts){
      foreach my $transcript(@$transcripts){
          $self->reincarnate_transcript($transcript);
      }
  }

  return $transcripts;
}

sub fetch_all_by_Gene  {
  my ($self,$gene)  = @_;

  my ($transcripts) = $self->SUPER::fetch_all_by_Gene($gene);
  if ($transcripts){
      foreach my $transcript(@$transcripts){
          $self->reincarnate_transcript($transcript);
      }
  }

  return $transcripts;
}

sub get_deleted_Transcript_by_slice{
  my ($self, $transcript,$tran_version) = @_;

  unless ($transcript || $tran_version){
      throw("no transcript passed on to fetch old transcript or no version supplied");
  }
  my $tran_slice=$transcript->slice;
  my $tran_stable_id=$transcript->stable_id;
  my $db_tran;
  my @out = grep { $_->stable_id eq $tran_stable_id and $_->version eq $tran_version }
    @{$self->SUPER::fetch_all_by_Slice_constraint($tran_slice,'t.is_current = 0 ')};
  if ($#out > 1) {
      ##test
      @out = sort {$a->dbID <=> $b->dbID} @out;
      $db_tran=pop @out;
      ##test
      #die "there are more than one transcript retrived\n".$db_tran->dbID;
  }
  else {
      $db_tran=$out[0];
  }

  if ($db_tran){
      $self->reincarnate_transcript($db_tran);
  }

  return $db_tran;
}

sub get_current_Transcript_by_slice {
  my ($self, $transcript) = @_;

  unless ($transcript){
      throw("no transcript passed on to fetch old transcript");
  }
  my $tran_slice=$transcript->slice;
  my $tran_stable_id=$transcript->stable_id;
  my @out = grep { $_->stable_id eq $tran_stable_id }
    @{ $self->fetch_all_by_Slice_constraint($tran_slice,'t.is_current = 1 ')};
  if ($#out > 1) {
      die "there are more than one transcript retrived\n";
  }
  my $db_tran=$out[0];
  if ($db_tran){
      $self->reincarnate_transcript($db_tran);
  }

  return $db_tran;
}

sub fetch_latest_by_stable_id {
  my ($self, $stable_id) = @_;

  my $constraint = "t.stable_id = '$stable_id' ORDER BY t.is_current DESC, t.modified_date DESC, t.transcript_id DESC LIMIT 1";
  my ($transcript) = @{ $self->generic_fetch($constraint) };
  if($transcript) {
    $self->reincarnate_transcript($transcript);
  }
  return $transcript;
}

sub store {
    my ($self, $transcript, $gene_dbID, $analysis_id) = @_;

    if( ! ref $transcript || !$transcript->isa('Bio::Vega::Transcript') ) {
        throw("$transcript is not a Vega transcript - not storing");
    }

    my $transcript_dbID = $self->SUPER::store($transcript, $gene_dbID, $analysis_id);

    my $author_adaptor = $self->db->get_AuthorAdaptor;
    my $transcript_author=$transcript->transcript_author;
    $author_adaptor->store($transcript_author);
    $author_adaptor->store_transcript_author($transcript_dbID, $transcript_author->dbID);

    $self->store_Evidence($transcript_dbID, $transcript->evidence_list );

    return $transcript_dbID;
}

sub remove {
    my ($self, $transcript) = @_;

    # Evidence
    $self->remove_evidence($transcript);

    # Author
    if (my $author = $transcript->transcript_author) {
        $self->db->get_AuthorAdaptor->remove_transcript_author($transcript->dbID, $author->dbID);
    }

    $self->SUPER::remove($transcript);

    return;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk


