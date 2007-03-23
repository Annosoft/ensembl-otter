package Bio::Vega::DBSQL::AssemblyTagAdaptor;

use strict;
use Bio::Vega::AssemblyTag;
use Bio::EnsEMBL::Utils::Exception qw(throw warning);

use base 'Bio::EnsEMBL::DBSQL::BaseFeatureAdaptor';

sub _tables {
  my $self = shift;
  return ['assembly_tag', 'at'];
}

sub _columns {
  my $self = shift;
  return qw(at.tag_id at.seq_region_id at.seq_region_start at.seq_region_end at.seq_region_strand at.tag_type at.tag_info);
}

sub _objs_from_sth {
  my ($self, $sth) = @_;
  my $a_tags = [];
  my $hashref;
  while ($hashref = $sth->fetchrow_hashref()) {
    my $atags = Bio::Vega::AssemblyTag->new();
    $atags->seq_region_id($hashref->{seq_region_id});
    $atags->seq_region_strand  ($hashref->{seq_region_strand});
    $atags->seq_region_start   ($hashref->{seq_region_start});
    $atags->seq_region_end     ($hashref->{seq_region_end});
    $atags->tag_type($hashref->{tag_type});
    !$hashref->{tag_info} ?  ($atags->tag_info("-")) : ($atags->tag_info($hashref->{tag_info}));
    push @$a_tags, $atags;
  }
  return $a_tags;
}

sub list_dbIDs {
   my ($self) = @_;
   return $self->_list_dbIDs("assembly_tag");
}

sub remove {
  my ($self, $del_at) = @_;
  my $sth;
  eval {
	 my $sql = "DELETE FROM assembly_tag where tag_id = ?";
	 $sth = $self->prepare($sql);
	 $sth->execute($del_at->dbID);
  };
  if ($@){
	 throw "problem with deleting assembly_tag ".$del_at->dbID;
  }
  my $num=$sth->rows;
  if ($num == 0) {
	 throw "assembly tag with ".$del_at->dbID." not deleted , tag_id may not be present\n";
  }
  warning "----- assembly_tag tag_id ", $del_at->dbID, " is deleted -----\n";

  #assembly tag is on a chromosome slice,transform to get a clone_slice
  my $new_at = $del_at->transform('clone');
  my $clone_slice=$new_at->slice;
  my $sa=$self->db->get_SliceAdaptor();
  my $clone_id=$sa->get_seq_region_id($clone_slice);
  eval{
	 $self->update_assembly_tagged_clone($clone_id,"no");
  };
  if ($@){
	 throw "delete of assembly_tag failed :$@";
  }
  return 1;
}

sub update_assembly_tagged_contig {
  my ($self, $seq_region_id) = @_;

  my $num;
  eval{
	my $sql = "UPDATE assembly_tagged_contig SET transferred = 'yes' WHERE seq_region_id = $seq_region_id";
	warn "$sql\n";
	my $sth = $self->prepare(qq{$sql});
	$sth->execute();
	$num=$sth->rows;
  };
  if ($@) {
	 throw "update of assembly_tagged_contig failed for seq_region_id $seq_region_id:$@";
  }
  if ($num == 0){
	 #throw "update of assembly_tagged_contig failed:$seq_region_id may not be present";
	 warn "update of assembly_tagged_contig failed: $seq_region_id may not be present\n";
  }
  return 1;
}

sub store {
  my ($self, $at) = @_;
  if (!ref $at || !$at->isa('Bio::Vega::AssemblyTag') ) {
    throw("Must store an AssemblyTag object, not a $at");
  }
  if ($at->is_stored($self->db->dbc)) {
    return $at->dbID();
  }

  # check assembly tag is on a chromosome slice,transform to get a contig_slice if not already
  # id, XML dump has atags on chr. slice, but fetch_assembly_tags script prepares atags in contig slice

  my $contig_slice;

  if ( $at->slice->coord_system->name ne "contig") {

    my $at_c = $at->transform('contig');
    unless ($at_c){
      throw("assembly tag $at cannot be transformed onto a contig slice from chromosome \n" .
            "assembly tag not loaded tag_info:".$at->tag_info." tag_type:".$at->tag_type.
            " seq_region_start:".$at->seq_region_start." seq_region_end:".$at->seq_region_end);
    }

    $contig_slice = $at_c->slice;

    unless ($contig_slice) {	
      throw "AssemblyTag does not have a contig slice attached to it, cannot store AssemblyTag\n";
    }
  }
  else {
    $contig_slice = $at->slice;
  }

  my $sa = $self->db->get_SliceAdaptor();
  my $seq_region_id=$sa->get_seq_region_id($contig_slice);

  map { print "$_ -> ", $at->{$_}, " " } keys %$at;
  print "\n";
  my $sql = "REPLACE INTO assembly_tag (seq_region_id, seq_region_start, seq_region_end, seq_region_strand, tag_type, tag_info) VALUES (?,?,?,?,?,?)";
  my $sth = $self->prepare($sql);

  eval{
	 $sth->execute($seq_region_id, $at->seq_region_start, $at->seq_region_end, $at->seq_region_strand, $at->tag_type, $at->tag_info);
  };
  if ($@){
	 throw "insert of assembly_tag failed:$@";
  }

  $self->update_assembly_tagged_contig($seq_region_id); # is contig_id

  return 1;
}


1;

__END__

=head1 NAME - Bio::Vega::DBSQL::AssemblyTagAdaptor

=head1 AUTHOR

Chao-Kung Chen ck1@sanger.ac.uk

Re-engineered by Sindhu Pillai sp1@sanger.ac.uk
