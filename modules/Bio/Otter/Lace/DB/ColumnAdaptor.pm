
### Bio::Otter::Lace::DB::ColumnAdaptor

package Bio::Otter::Lace::DB::ColumnAdaptor;

use strict;
use warnings;
use Carp;

use base 'Bio::Otter::Lace::DB::Adaptor';

sub columns         { return qw( selected status status_detail gff_file process_gff name ); }
sub key_column_name { return 'name'; }
sub object_class    { return 'Bio::Otter::Lace::Source::Item::Column'; }

my $all_columns = __PACKAGE__->all_columns;

sub SQL {
    return {
    store =>            qq{ INSERT INTO otter_column ( ${all_columns} )
                                              VALUES ( ?, ?, ?, ?, ?, ? )
                          },
    update =>            q{ UPDATE otter_column
                               SET selected = ?
                                 , status = ?
                                 , status_detail = ?
                                 , gff_file = ?
                                 , process_gff = ?
                                 , name = ?
                             WHERE name = ?
                          },
    delete =>            q{ DELETE FROM otter_column WHERE name = ?
                          },
    fetch_by_key  =>    qq{ SELECT ${all_columns} FROM otter_column WHERE name = ?
                          },
    update_for_filter_get => qq{ UPDATE otter_column
                                    SET status = 'Loading', gff_file = ?, process_gff = ?
                                  WHERE name = ?
                               },
    };
}

# Special atomic update for filter_get script.
#
sub update_for_filter_get {
    my ($self, $name, $gff_file, $process_gff) = @_;
    my $sth = $self->dbh->prepare($self->SQL->{update_for_filter_get});
    return $sth->execute($gff_file, $process_gff, $name);
}

sub fetch_ColumnCollection_state {
    my ($self, $clltn) = @_;

    foreach my $col ($clltn->list_Columns) {
        $self->fetch_state($col);
    }

    return;
}

sub store_ColumnCollection_state {
    my ($self, $clltn) = @_;

    $self->begin_work;
    foreach my $col ($clltn->list_Columns) {
        if ($col->is_stored) {
            $self->update($col);
        }
        else {
            $self->store($col);
        }
    }
    $self->commit;

    return;
}

sub store_Column_state {
    my ($self, $col) = @_;

    $self->begin_work;
    my $result;
    if ($col->is_stored) {
        $result = $self->update($col);
    }
    else {
        $result = $self->store($col);
    }
    $self->commit;

    return $result;
}


1;

__END__

=head1 NAME - Bio::Otter::Lace::DB::ColumnAdaptor

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

