
### Bio::Otter::Lace::AccessionTypeCache

package Bio::Otter::Lace::AccessionTypeCache;

use strict;
use warnings;
use Try::Tiny;
use Hum::ClipboardUtils qw{ accessions_from_text };
use Hum::Sort qw{ ace_sort };
use Carp qw( cluck );

my (
    %client,
    %DB,
    %acc_sv_exists_sth,
    %save_acc_info_sth,
    %latest_acc_sv_sth,
    %save_tax_info_sth,
    %full_acc_sv_sth,
);

sub DESTROY {
    my ($self) = @_;

    warn "Destroying a ", ref($self), "\n";

    delete $client{$self};
    delete $DB{$self};
    delete $acc_sv_exists_sth{$self};
    delete $save_acc_info_sth{$self};
    delete $latest_acc_sv_sth{$self};
    delete $save_acc_info_sth{$self};
    delete $full_acc_sv_sth{$self};

    return;
}

sub new {
    my ($pkg) = @_;

    my $str;
    return bless \$str, $pkg;
}

sub Client {
    my ($self, $client) = @_;

    if ($client) {
        $client{$self} = $client;
    }
    return $client{$self};
}

sub DB {
    my ($self, $DB) = @_;

    if ($DB) {
        $DB{$self} = $DB;
    }
    return $DB{$self};
}

sub populate {
    my ($self, $name_list) = @_;

    # Will fetch the latest version of any ACCESSION supplied without a SV.

    my $dbh = $DB{$self}->dbh;
    my $check_full  = $dbh->prepare(q{ SELECT count(*) FROM otter_accession_info WHERE accession_sv = ? });
    my $check_alias = $dbh->prepare(q{ SELECT count(*) FROM otter_full_accession WHERE name = ? });

    my (@to_fetch);
    foreach my $name (@$name_list) {
        $check_full->execute($name);
        my ($have_full) = $check_full->fetchrow;
        if ($have_full) {
            next;
        }
        else {
            $check_alias->execute($name);
            my ($have_alias) = $check_alias->fetchrow;
            if ($have_alias) {
                next;
            }
            else {
                push(@to_fetch, $name);
            }
        }
    }
    return unless @to_fetch;

    # Query the webserver (mole database) for the information.
    my $results = $self->Client->get_accession_info(@to_fetch);

    my $save_alias = $dbh->prepare(q{
        INSERT INTO otter_full_accession(name, accession_sv) VALUES (?,?)
    });

    my %taxon_id_map;
    $dbh->begin_work;
    try {
        foreach my $entry (values %$results) {
            my ($name, $acc_sv, $taxon_list) = @$entry{qw( name acc_sv taxon_list )};
            my ($tax_id, @other_tax);
            ($tax_id, @other_tax) = split /,/, $taxon_list if $taxon_list; # /; # emacs highlighting workaround
            if (@other_tax) {
                # Some SwissProt entries contain the same protein and multiple species.
                warn "Discarding taxon info from '$taxon_list' for '$acc_sv'; keeping only '$tax_id'";
            }
            $entry->{taxon_id} = $tax_id;
            # Don't overwrite existing info
            $check_full->execute($acc_sv);
            my ($have_full) = $check_full->fetchrow;
            unless ($have_full) {
                # It is new, so save it
                $self->save_accession_info($entry);
                $taxon_id_map{$tax_id} = 1;
            }
            if ($name ne $acc_sv) {
                $save_alias->execute($name, $acc_sv);
            }
        }
    }
    catch {
        $dbh->rollback;
        die "Error saving accession info: $_";
    };

    $dbh->commit;

    $self->populate_taxonomy([keys %taxon_id_map]) if keys %taxon_id_map;

    return;
}

{
    my $save_acc_info_sql = q{
        INSERT OR REPLACE INTO otter_accession_info (
              accession_sv
              , taxon_id
              , evi_type
              , description
              , source
              , currency
              , length
              , sequence )
        VALUES (?,?,?,?,?,?,?,?)
    };

    sub save_accession_info {
        my ($self, $entry) = @_;

        my $sth = $save_acc_info_sth{$self} ||= $DB{$self}->dbh->prepare($save_acc_info_sql);

        return $sth->execute(
            @$entry{qw(acc_sv taxon_id evi_type description source currency sequence_length sequence)}
            );
    }
}

sub populate_taxonomy {
    my ($self, $id_list) = @_;

    my $dbh = $DB{$self}->dbh;

    # filter out those we already have
    my $id_list_fetched = $dbh->selectcol_arrayref(q{ SELECT taxon_id FROM otter_species_info });
    my $id_list_fetched_hash = { map { $_ => 1 } @{$id_list_fetched} };
    my @id_list_fetch = grep { ! $id_list_fetched_hash->{$_} } @{$id_list};
    @id_list_fetch or return;

    # Query the webserver (mole database) for the information.
    my $response = $self->Client->get_taxonomy_info(@id_list_fetch);

    $dbh->begin_work;
    try {
        foreach my $info ( @$response ) {
            $self->save_taxonomy_info($info);
        }
    }
    catch {
        $dbh->rollback;
        die "Error saving taxon info: $_";
    };

    $dbh->commit;

    return;
}

{
    my $save_tax_info_sql = q{
        INSERT OR REPLACE INTO otter_species_info (
                taxon_id
              , scientific_name
              , common_name
              )
        VALUES (?,?,?)
    };

    sub save_taxonomy_info {
        my ($self, $info) = @_;
        my $sth = $save_tax_info_sth{$self} ||= $DB{$self}->dbh->prepare($save_tax_info_sql);

        return $sth->execute(@{$info}{qw( id scientific_name common_name )});
    }
}

sub type_and_name_from_accession {
    my ($self, $acc) = @_;

    my $dbh = $DB{$self}->dbh;
    my $sth = $dbh->prepare(q{
        SELECT evi_type
          , accession_sv
        FROM otter_accession_info
        WHERE accession_sv = ?
        });
    $sth->execute($acc);
    my ($type, $acc_sv) = $sth->fetchrow;
    unless ($type and $acc_sv) {
        $sth = $dbh->prepare(q{
            SELECT ai.evi_type, ai.accession_sv
            FROM otter_accession_info ai
              , otter_full_accession f
            WHERE ai.accession_sv = f.accession_sv
            AND f.name = ?
            });
        $sth->execute($acc);
        ($type, $acc_sv) = $sth->fetchrow;
    }
    if ($type and $acc_sv) {
        return ($type, $acc_sv);
    }
    else {
        return;
    }
}

sub accession_list_from_text {
    my ($self, $text) = @_;

    return [accessions_from_text($text)];
}

sub evidence_type_and_name_from_accession_list {
    my ($self, $acc_list) = @_;

    my $dbh = $DB{$self}->dbh;
    my $full_fetch = $dbh->prepare(q{
        SELECT evi_type
          , accession_sv
          , source
        FROM otter_accession_info
        WHERE accession_sv = ?
        });
    my $alias_fetch = $dbh->prepare(q{
        SELECT ai.evi_type
          , ai.accession_sv
          , ai.source
        FROM otter_accession_info ai
          , otter_full_accession f
        WHERE ai.accession_sv = f.accession_sv
          AND f.name = ?
        });
    my $part_fetch = $dbh->prepare(q{
        SELECT evi_type
          , accession_sv
          , source
        FROM otter_accession_info
        WHERE accession_sv LIKE ?
        });

    # First look at our SQLite db, to find out what kind of accession it is
    my $type_name = {};
    foreach my $acc (@$acc_list) {
        $full_fetch->execute($acc);
        my ($type, $full_name, $source) = $full_fetch->fetchrow;
        unless ($type) {
            # If the SV was left off, try the otter_full_accession table first to
            # ensure that the most recent version is returned, if cached.
            $alias_fetch->execute($acc);
            ($type, $full_name, $source) = $alias_fetch->fetchrow;
        }
        unless ($type) {
            # Last, try a LIKE query, assuming the SV was missed off
            $part_fetch->execute("$acc.%");
            ($type, $full_name, $source) = $part_fetch->fetchrow;
        }
        unless ($type and $full_name) {
            next;
        }
        if ($source) {
            my $prefix = ucfirst lc substr($source, 0, 2);
            $full_name = "$prefix:$full_name";
        }
        my $name_list = $type_name->{$type} ||= [];
        push(@$name_list, $full_name);
    }

    return $type_name;
}

{
    my @fai_cols = qw( taxon_id evi_type description source currency length sequence );
    my $cols_spec = join(', ', map { "oai.$_" } @fai_cols);
    my $feature_accession_info_sql = qq{
        SELECT $cols_spec, osi.scientific_name, osi.common_name
        FROM otter_accession_info oai
        LEFT JOIN otter_species_info osi
        USING ( taxon_id )
        WHERE oai.accession_sv = ?
    };

    sub feature_accession_info {
        my ($self, $feature_name) = @_;
        my $row = $DB{$self}->dbh->selectrow_arrayref($feature_accession_info_sql, {}, $feature_name);
        return unless $row;
        my %result;
        @result{@fai_cols, qw( taxon_scientific_name taxon_common_name)} = @$row;
        return \%result;
    }
}

{
    my $latest_acc_sv_sql = q{
        SELECT accession_sv FROM otter_accession_info WHERE accession_sv LIKE ?
    };

    sub latest_acc_sv_for_stem {
        my ($self, $stem) = @_;

        my $sth = $latest_acc_sv_sth{$self} ||= $DB{$self}->dbh->prepare($latest_acc_sv_sql);

        $sth->execute("$stem.%");
        my @all_acc_sv;
        while (my ($acc_sv) = $sth->fetchrow) {
            push(@all_acc_sv, $acc_sv);
        }
        if (@all_acc_sv) {
            my ($first) = sort { ace_sort($b, $a) } @all_acc_sv;
            return $first;
        }
        else {
            return;
        }
    }
}

sub acc_sv_exists {
    my ($self, $acc_sv) = @_;

    my $sth = $acc_sv_exists_sth{$self} ||= $DB{$self}->dbh->prepare(
        "SELECT count(*) FROM otter_accession_info WHERE accession_sv = ?"
        );
    $sth->execute($acc_sv);
    my ($count) = $sth->fetchrow;
    return $count ? 1 : 0;
}

sub full_acc_sv {
    my ($self, $name) = @_;

    my $sth = $full_acc_sv_sth{$self} ||= $DB{$self}->dbh->prepare(
        "SELECT accession_sv FROM otter_full_accession WHERE name = ?"
        );
    $sth->execute($name);
    my ($acc_sv) = $sth->fetchrow;
    return $acc_sv;
}

sub begin_work { my ($self) = @_; return $DB{$self}->dbh->begin_work; }
sub commit     { my ($self) = @_; return $DB{$self}->dbh->commit;     }
sub rollback   { my ($self) = @_; return $DB{$self}->dbh->rollback;   }

1;

__END__

=head1 NAME - Bio::Otter::Lace::AccessionTypeCache

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

