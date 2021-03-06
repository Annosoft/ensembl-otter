package Bio::Otter::ServerAction::LoutreDB;

use strict;
use warnings;

use base 'Bio::Otter::ServerAction';

=head1 NAME

Bio::Otter::ServerAction::LoutreDB - serve requests for info from loutre db.

=cut

# Parent constructor is fine unaugmented.

### Methods

=head2 get_meta
=cut

my $select_meta_sql = <<'SQL'
    SELECT species_id, meta_key, meta_value
      FROM meta
  ORDER BY meta_id
SQL
    ;

my @white_list = qw(
    assembly
    patch
    prefix
    schema_type
    schema_version
    species
);

my %white_list = map { $_ => 1 } @white_list;

sub get_meta {
    my ($self) = @_;
    my $server = $self->server;

    my $key_pattern;
    if (my $key_param = $server->param('key')) {
        $key_pattern = qr/^${key_param}/;
    }

    my $sth = $server->otter_dba()->dbc()->prepare($select_meta_sql);
    $sth->execute;

    my $counter = 0;
    my %meta_hash;

    while (my ($species_id, $meta_key, $meta_value) = $sth->fetchrow) {

        my ($key_prefix) = $meta_key =~ /^(\w+)\.?/;
        next unless $white_list{$key_prefix};

        if ($key_pattern) {
            next unless $meta_key =~ $key_pattern;
        }

        $meta_hash{$meta_key}->{species_id} = $species_id;
        push @{$meta_hash{$meta_key}->{values}}, $meta_value; # as there can be multiple values for one key
        $counter++;
    }

    warn "Total of $counter meta table pairs whitelisted\n";

    return \%meta_hash;
}


=head2 get_db_info
=cut

my $select_cs_sql = <<'SQL';
    SELECT coord_system_id, species_id, name, version, rank, attrib
      FROM coord_system
     WHERE name = 'chromosome' AND version = 'Otter'
SQL

my $select_at_sql = <<'SQL';
    SELECT attrib_type_id, code, name, description
      FROM attrib_type
SQL

sub get_db_info {
    my ($self) = @_;

    my %results;

    my $dbc = $self->server->otter_dba()->dbc();

    my $cs_sth = $dbc->prepare($select_cs_sql);
    $cs_sth->execute;
    my $cs_chromosome = $cs_sth->fetchrow_hashref;
    $results{'coord_system.chromosome'} = $cs_chromosome;

    my $at_sth = $dbc->prepare($select_at_sql);
    $at_sth->execute;
    my $at_rows = $at_sth->fetchall_arrayref({});
    $results{'attrib_type'} = $at_rows;

    return \%results;
}

### Accessors

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

=cut

1;
