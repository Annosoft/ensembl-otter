
### Bio::Otter::Lace::DB

package Bio::Otter::Lace::DB;

use strict;
use warnings;
use Carp;
use DBI;

my(
    %dbh,
    %file,
    );

sub DESTROY {
    my ($self) = @_;
    
    delete($dbh{$self});
    delete($file{$self});

    return;
}

sub new {
    my ($pkg, $home) = @_;
    
    unless ($home) {
        confess "Cannot create SQLite database without home parameter";
    }
    my $ref = "";
    my $self = bless \$ref, $pkg;
    my $file = "$home/otter.sqlite";
    $self->file($file);
    $self->init_db;
    
    return $self;
}

sub dbh {
    my ($self, $arg) = @_;
    
    if ($arg) {
        $dbh{$self} = $arg;
    }
    return $dbh{$self};
}

sub file {
    my ($self, $arg) = @_;
    
    if ($arg) {
        $file{$self} = $arg;
    }
    return $file{$self};
}

sub init_db {
    my ($self) = @_;
    
    my $file = $self->file or confess "Cannot create SQLite database: file not set";
    my $dbh = DBI->connect("dbi:SQLite:dbname=$file", undef, undef, {
        RaiseError => 1,
        AutoCommit => 1,
        });
    $dbh{$self} = $dbh;
    
    $self->create_tables;
    
    return 1;
}

{
    my %table_defs = (
        otter_filter  => q{
            filter_name     TEXT PRIMARY KEY
            , wanted        INTEGER DEFAULT 0
            , failed        INTEGER DEFAULT 0
            , done          INTEGER DEFAULT 0
            , gff_file      TEXT
            , process_gff   INTEGER DEFAULT 0
        },
        accession_info  => q{
            accession_sv    TEXT PRIMARY KEY
            , taxon_id      INTEGER
            , evi_type      TEXT
            , description   TEXT
            , source_db     TEXT
            , length        INTEGER
            , sequence      TEXT
        },
        full_accession  => q{
            name            TEXT PRIMARY KEY
            , accession_sv  TEXT
        },
        species_info => q{
            taxon_id        INTEGER PRIMARY KEY
            , genus         TEXT
            , species       TEXT
            , common_name   TEXT
        },
    );

    my %index_defs = (
        idx_full_accession  => q{ full_accession( accession_sv, name ) },
    );

    sub create_tables {
        my ($self) = @_;

        my $dbh = $dbh{$self};
        $dbh->begin_work;

        my %existing_table = map {$_->[0] => 1}
            @{ $dbh->selectall_arrayref(q{SELECT name FROM sqlite_master WHERE type = 'table'}) };

        foreach my $tab (sort keys %table_defs) {
            unless ($existing_table{$tab}) {
                $dbh->do("CREATE TABLE $tab ($table_defs{$tab})");
            }
        }
        
        my %existing_index = map {$_->[0] => 1}
            @{ $dbh->selectall_arrayref(q{SELECT name FROM sqlite_master WHERE type = 'index'}) };

        foreach my $idx (sort keys %index_defs) {
            unless ($existing_index{$idx}) {
                $dbh->do("CREATE INDEX $idx ON $index_defs{$idx}");
            }
        }
        $dbh->commit;

        return;
    }
}

1;

__END__

=head1 NAME - Bio::Otter::Lace::DB

=head1 DESCRIPTION

The SQLite db stored in the local AceDatabase directory.

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

