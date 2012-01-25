package Bio::Vega::DBSQL::ExonAdaptor;

use strict;
use warnings;
use base 'Bio::EnsEMBL::DBSQL::ExonAdaptor';
use Bio::EnsEMBL::Utils::Exception qw(throw warning);

use Bio::Vega::Exon;

    # trying to substitute the class in all possible places at once (a hack)
sub _objs_from_sth { ## no critic(Subroutines::ProhibitUnusedPrivateSubroutines)
    my ($self, @arguments) = @_;

    my $array = $self->SUPER::_objs_from_sth(@arguments);

    for my $exon (@$array) {
        bless $exon, 'Bio::Vega::Exon';
    }

    return $array;
}

sub update  {

  my ($self, $exon) = @_;

  if ( !$exon || !ref $exon || !$exon->isa('Bio::Vega::Exon') ) {
    throw("Must update an exon object, not a $exon");
  }

  my $sth = $self->prepare(qq{
       UPDATE exon
          SET
              is_current = ?
        WHERE exon_id = ?
  });

  $sth->execute( $exon->is_current, $exon->dbID );

  return;
}

sub fetch_by_stable_id_version {

  my ($self, $stable_id,$version) = @_;

  my $constraint = "e.stable_id = '$stable_id' AND e.version = $version ORDER BY e.modified_date DESC, e.exon_id DESC LIMIT 1";
  my ($exon) = @{ $self->generic_fetch($constraint) };

  return $exon;
}

sub fetch_latest_by_stable_id {
  my ($self, $stable_id) = @_;

  my $constraint = "e.stable_id = '$stable_id' ORDER BY e.is_current DESC, e.modified_date DESC, e.exon_id DESC LIMIT 1";
  my ($exon) = @{ $self->generic_fetch($constraint) };

  return $exon;
}


1;

__END__

=head1 NAME - Bio::Vega::DBSQL::ExonAdaptor

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

