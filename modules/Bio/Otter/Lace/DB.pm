
### Bio::Otter::Lace::DB

package Bio::Otter::Lace::DB;

use strict;
use warnings;
use Carp qw( confess cluck );
use DBI;

use Bio::Otter::Lace::DB::ColumnAdaptor;
use Bio::Otter::Lace::DB::OTFRequestAdaptor;
use Bio::Vega::CoordSystemFactory;

use parent qw( Bio::Otter::Log::WithContextMixin );

my(
    %species,
    %dbh,
    %file,
    %vega_dba,
    %session_slice,
    %whole_slice,
    %ColumnAdaptor,
    %OTFRequestAdaptor,
    %log_context,
    );

sub DESTROY {
    my ($self) = @_;

    delete($species{$self});
    delete($dbh{$self});
    delete($file{$self});
    delete($vega_dba{$self});
    delete($session_slice{$self});
    delete($whole_slice{$self});
    delete($ColumnAdaptor{$self});
    delete($OTFRequestAdaptor{$self});
    delete($log_context{$self});

    return;
}

sub new {
    my ($pkg, %args) = @_;

    my ($species, $home, $client, $log_context) = @args{qw( species home client log_context )};

    my $ref = "";
    my $self = bless \$ref, $pkg;
    $self->log_context($log_context);

    unless ($home) {
        $self->logger->logconfess("Cannot create SQLite database without home parameter");
    }

    $self->species($species);

    my $file = "$home/otter.sqlite";
    $self->file($file);

    $self->logger->debug("new() connecting to '$file'");
    $self->init_db($client);

    return $self;
}

sub species {
    my ($self, $arg) = @_;

    if ($arg) {
        $species{$self} = $arg;
    }
    return $species{$self};
}

sub dbh {
    my ($self, $arg) = @_;

    if ($arg) {
        $dbh{$self} = $arg;
    }
    return $dbh{$self};
}

sub ColumnAdaptor {
    my ($self) = @_;

    return $ColumnAdaptor{$self} ||=
        Bio::Otter::Lace::DB::ColumnAdaptor->new($self->dbh);
}

sub OTFRequestAdaptor {
    my ($self) = @_;

    return $OTFRequestAdaptor{$self} ||=
        Bio::Otter::Lace::DB::OTFRequestAdaptor->new($self->dbh);
}

sub file {
    my ($self, $arg) = @_;

    if ($arg) {
        $file{$self} = $arg;
    }
    return $file{$self};
}

sub vega_dba {
    my ($self) = @_;

    return $vega_dba{$self} if $vega_dba{$self};

    $self->_is_loaded('dataset_info') or
        $self->logger->logconfess("Cannot create Vega adaptor until dataset info is loaded");

    $vega_dba{$self} = $self->_dba;

    return $vega_dba{$self};
}

sub _dba {
    my ($self, $suffix) = @_;

    # This pulls in EnsEMBL, so we only do it if required, to reduce the footprint of filter_get &co.
    require Bio::Vega::DBSQL::DBAdaptor;

    # We need a unique species per session to avoid confusing the EnsEMBL API.
    #
    # We also need a separate species name for our throw-away adaptor when storing coord_systems
    # and mappings.
    my $db_species = sprintf('%s:::%s', $self->species, $self->log_context);
    $db_species .= $suffix if $suffix;
    $self->logger->debug("Connecting for '$db_species'");

    return Bio::Vega::DBSQL::DBAdaptor->new(
        -driver  => 'SQLite',
        -dbname  => $self->file,
        -species => $db_species,
        -reconnect_when_connection_lost => 1, # to cope with Registry->clear disconnecting everything
        -no_cache => 1,                       # for sanity in FromHumAce
        );
}

sub session_slice {
    my ($self, $ensembl_slice) = @_;

    my $session_slice = $session_slice{$self};
    return $session_slice if $session_slice;

    $ensembl_slice or
        $self->logger->logconfess("ensembl_slice must be supplied when creating or recovering session_slice");

    # Slice should have been created by Bio::Vega::Region::Store->store()

    my $db_seq_region = $self->_fetch_seq_region_for_slice($ensembl_slice);
    $whole_slice{$self} = $db_seq_region;

    $session_slice = $db_seq_region->sub_Slice($ensembl_slice->start, $ensembl_slice->end);
    return $session_slice{$self} = $session_slice;
}

sub whole_slice {
    my ($self) = @_;

    my $whole_slice = $whole_slice{$self};
    unless ($whole_slice) {
        $self->logger->logconfess("cannot call whole_slice() before setting session_slice()");
    }

    return $whole_slice;
}

sub _fetch_seq_region_for_slice {
    my ($self, $slice) = @_;

    my $slice_adaptor = $self->vega_dba->get_SliceAdaptor;
    my $db_seq_region = $slice_adaptor->fetch_by_region($slice->coord_system->name, $slice->seq_region_name);

    unless ($db_seq_region) {
        $self->logger->logconfess(sprintf("slice not found in SQLite for '%s' [%s]",
                                          $slice->seq_region_name, $slice->coord_system->name));
    }

    return $db_seq_region;
}

sub get_tag_value {
    my ($self, $tag) = @_;

    my $sth = $dbh{$self}->prepare(q{ SELECT value FROM otter_tag_value WHERE tag = ? });
    $sth->execute($tag);
    my ($value) = $sth->fetchrow;
    return $value;
}

sub set_tag_value {
    my ($self, $tag, $value) = @_;

    unless (defined $value) {
        $self->logger->logconfess("No value provided");
    }

    my $sth = $dbh{$self}->prepare(q{ INSERT OR REPLACE INTO otter_tag_value (tag, value) VALUES (?,?) });
    $sth->execute($tag, $value);

    return;
}

sub _has_table {
    my ($self, $table) = @_;
    my $sth = $dbh{$self}->table_info(undef, 'main', $table, 'TABLE');
    my $table_info = $sth->fetchrow_hashref;
    return unless $table_info;
    return $table_info->{TABLE_NAME};
}

sub _is_loaded {
    my ($self, $name, $value) = @_;

    my $has_tag_table = $self->_has_table('otter_tag_value');

    if (defined $value) {
        $self->logger->logdie("No otter_tag_value table when setting '$name' tag.") unless $has_tag_table;
        return $self->set_tag_value($name, $value);
    }

    return unless $has_tag_table;
    return $self->get_tag_value($name);
}

sub init_db {
    my ($self, $client) = @_;

    my $file = $self->file or $self->logger->logconfess("Cannot create SQLite database: file not set");

    my $done_file = $file;
    $done_file =~ s{/([^/]+)$}{.done/$1};
    if (!-f $file && -f $done_file) {
        $self->logger->logcluck("Running late?\n  Absent: $file\n  Exists: $done_file");
        # Diagnostics because I saw it after RT395938 Zircon 13e593c10ce4cb1ccdfd362a293a1e940e24e26d
    }

    my $dbh = DBI->connect("dbi:SQLite:dbname=$file", undef, undef, {
        RaiseError => 1,
        AutoCommit => 1,
        sqlite_use_immediate_transaction => 1,
        sqlite_allow_multiple_statements => 1,
        });
    $dbh{$self} = $dbh;

    $self->create_tables($client->get_otter_schema,  'schema_otter')  unless $self->_is_loaded('schema_otter');
    $self->create_tables($client->get_loutre_schema, 'schema_loutre') unless $self->_is_loaded('schema_loutre');

    return 1;
}

sub create_tables {
    my ($self, $schema, $name) = @_;

    $self->logger->debug("create_tables for '$name'");

    my $dbh = $dbh{$self};
    $dbh->begin_work;
    $dbh->do($schema);
    $dbh->commit;

    $self->_is_loaded($name, 1);

    return;
}

sub load_dataset_info {
    my ($self, $dataset) = @_;
    return if $self->_is_loaded('dataset_info');

    $self->_is_loaded('schema_loutre') or
        $self->logger->logconfess("Cannot load dataset info: loutre schema not loaded");

    my $dbh = $dbh{$self};

    my $meta_sth = $dbh->prepare(q{ INSERT INTO meta (species_id, meta_key, meta_value) VALUES (?, ?, ?) });
    my $meta_hash = $dataset->meta_hash;

    my @cs_cols = qw(                                        coord_system_id  species_id  name  version  rank  attrib );
    my $cs_sth  = $dbh->prepare(q{ INSERT INTO coord_system (coord_system_id, species_id, name, version, rank, attrib)
                                                     VALUES (?, ?, ?, ?, ?, ?) });

    # I'm not really sure we need to do this - we could just use a local version
    #
    my $cs_chr  = $dataset->get_db_info_item('coord_system.chromosome');
    my $local_cs_spec = {
        $cs_chr->{name} => {
            '-version'        => $cs_chr->{version},
            '-rank'           => $cs_chr->{rank},
            '-default'        => $cs_chr =~ m/default_version/,
            '-sequence_level' => $cs_chr =~ m/sequence_level/,
        },
    };

    my @at_cols = qw(                                       attrib_type_id  code  name  description );
    my $at_sth  = $dbh->prepare(q{ INSERT INTO attrib_type (attrib_type_id, code, name, description)
                                                    VALUES (?, ?, ?, ?) });
    my $at_list = $dataset->get_db_info_item('attrib_type');

    my $_dba = $self->_dba('_coords');     # we throw this one away

    my $cs_factory = Bio::Vega::CoordSystemFactory->new(
        dba           => $_dba,
        create_in_db  => 1,
        override_spec => $local_cs_spec,
        );

    my %local_meta = (
        'assembly.mapping' => {
            species_id => 1,
            values     => [
                $cs_factory->assembly_mappings,
            ],
        },
        );

    $dbh->begin_work;

    # Meta first, so that CoordSystemAdaptor doesn't complain about missing schema_version
    #
    while (my ($key, $details) = each %$meta_hash) {
        next if $key eq 'assembly.mapping'; # we do our own mapping, below...
        foreach my $value (@{$details->{values}}) {
            $meta_sth->execute($details->{species_id}, $key, $value);
        }
    }

    # Attributes
    #
    foreach my $row (@$at_list) {
        $at_sth->execute(@$row{@at_cols});
    }

    $dbh->commit;

    $dbh->begin_work;

    # Coord systems via factory
    #
    $cs_factory->instantiate_all;

    # Mappings
    #
    my $mca = $_dba->get_MetaContainer;
    while (my ($key, $details) = each %local_meta) {
        foreach my $value (@{$details->{values}}) {
            $mca->store_key_value($key, $value);
        }
    }

    $dbh->commit;

    $self->_is_loaded('dataset_info', 1);

    return;
}

# Required by Bio::Otter::Log::WithContextMixin
# (default version is not inside-out compatible!)
sub log_context {
    my ($self, $arg) = @_;

    if ($arg) {
        $log_context{$self} = $arg;
    }

    return $log_context{$self} if $log_context{$self};
    return '-B-O-L-DB unnamed-';
}

1;

__END__

=head1 NAME - Bio::Otter::Lace::DB

=head1 DESCRIPTION

The SQLite db stored in the local AceDatabase directory.

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

