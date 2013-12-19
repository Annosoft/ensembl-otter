
### Bio::Otter::Lace::AccessionTypeCache

package Bio::Otter::Lace::AccessionTypeCache;

use strict;
use warnings;
use Try::Tiny;
use Hum::ClipboardUtils qw{ accessions_from_text };

my (%client, %DB);

sub DESTROY {
    my ($self) = @_;

    warn "Destroying a ", ref($self), "\n";

    delete $client{$self};
    delete $DB{$self};

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
    my $response = $self->Client->get_accession_types(@to_fetch);

    my $save_alias = $dbh->prepare(q{
        INSERT INTO otter_full_accession(name, accession_sv) VALUES (?,?)
    });

    $dbh->begin_work;
    try {
        foreach my $line (split /\n/, $response) {
            my ($name, $evi_type, $acc_sv, $source_db, $seq_length, $taxon_list, $description) = split /\t/, $line;
            my ($tax_id, @other_tax);
            ($tax_id, @other_tax) = split /,/, $taxon_list if $taxon_list; # /; # emacs highlighting workaround
            if (@other_tax) {
                # Some SwissProt entries contain the same protein and multiple species.
                warn "Discarding taxon info from '$taxon_list' for '$acc_sv'; keeping only '$tax_id'";
            }
            # Don't overwrite existing info
            $check_full->execute($acc_sv);
            my ($have_full) = $check_full->fetchrow;
            unless ($have_full) {
                # It is new, so save it
                $self->save_accession_info($acc_sv, $tax_id, $evi_type, $description, $source_db, $seq_length);
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

    return;
}

{
    my %save_acc_info_sth;

    my $save_acc_info_sql = q{
        INSERT OR REPLACE INTO otter_accession_info (
              accession_sv
              , taxon_id
              , evi_type
              , description
              , source_db
              , length)
        VALUES (?,?,?,?,?,?)
    };

    sub save_accession_info {
        my ($self, $accession_sv, $taxon_id, $evi_type, $description, $source_db, $length) = @_;
        my $sth = $save_acc_info_sth{$self} ||= $DB{$self}->dbh->prepare($save_acc_info_sql);
        confess "Cannot save without evi_type" unless defined $evi_type;

        return $sth->execute($accession_sv, $taxon_id, $evi_type, $description, $source_db, $length);
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
          , source_db
        FROM otter_accession_info
        WHERE accession_sv = ?
        });
    my $alias_fetch = $dbh->prepare(q{
        SELECT ai.evi_type
          , ai.accession_sv
          , ai.source_db
        FROM otter_accession_info ai
          , otter_full_accession f
        WHERE ai.accession_sv = f.accession_sv
          AND f.name = ?
        });
    my $part_fetch = $dbh->prepare(q{
        SELECT evi_type
          , accession_sv
          , source_db
        FROM otter_accession_info
        WHERE accession_sv LIKE ?
        });

    # First look at our SQLite db, to find out what kind of accession it is
    my $type_name = {};
    foreach my $acc (@$acc_list) {
        $full_fetch->execute($acc);
        my ($type, $full_name, $source_db) = $full_fetch->fetchrow;
        unless ($type) {
            # If the SV was left off, try the otter_full_accession table first to
            # ensure that the most recent version is returned, if cached.
            $alias_fetch->execute($acc);
            ($type, $full_name, $source_db) = $alias_fetch->fetchrow;
        }
        unless ($type) {
            # Last, try a LIKE query, assuming the SV was missed off
            $part_fetch->execute("$acc.%");
            ($type, $full_name, $source_db) = $part_fetch->fetchrow;
        }
        unless ($type and $full_name) {
            next;
        }
        if ($source_db) {
            my $prefix = ucfirst lc substr($source_db, 0, 2);
            $full_name = "$prefix:$full_name";
        }
        my $name_list = $type_name->{$type} ||= [];
        push(@$name_list, $full_name);
    }

    return $type_name;
}

{
    my $feature_accession_info_sql = q{
        SELECT source_db, taxon_id, description FROM otter_accession_info WHERE accession_sv = ?
    };

    sub feature_accession_info {
        my ($self, $feature_name) = @_;
        my $row = $DB{$self}->dbh->selectrow_arrayref($feature_accession_info_sql, {}, $feature_name);
        return $row;
    }
}

sub begin_work { my ($self) = @_; return $DB{$self}->dbh->begin_work; }
sub commit     { my ($self) = @_; return $DB{$self}->dbh->commit;     }
sub rollback   { my ($self) = @_; return $DB{$self}->dbh->rollback;   }

1;

__END__

=head1 NAME - Bio::Otter::Lace::AccessionTypeCache

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

