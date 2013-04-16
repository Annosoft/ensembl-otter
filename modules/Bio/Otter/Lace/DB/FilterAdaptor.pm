
### Bio::Otter::Lace::DB::FilterAdaptor

package Bio::Otter::Lace::DB::FilterAdaptor;

use strict;
use warnings;

use Carp;
use Bio::Otter::Lace::DB::Filter;

sub new {
    my ($pkg, $dbh) = @_;

    confess "dbh must be supplied" unless $dbh;

    my $self = bless {}, $pkg;
    $self->dbh($dbh);

    return $self;
}

sub dbh {
    my ($self, @args) = @_;
    ($self->{'dbh'}) = @args if @args;
    my $dbh = $self->{'dbh'};
    return $dbh;
}

my @columns = qw( filter_name wanted failed done gff_file process_gff );

my $all_columns = join(', ', @columns);

my %SQL = (
    store =>            qq{ INSERT INTO otter_filter ( ${all_columns} )
                                              VALUES ( ?, ?, ?, ?, ?, ? )
                          },
    update =>            q{ UPDATE otter_filter
                               SET wanted = ?, failed = ?, done = ?, gff_file = ?, process_gff = ?
                             WHERE filter_name = ?
                          },
    delete =>            q{ DELETE FROM otter_filter WHERE filter_name = ?
                          },
    fetch_by_name =>    qq{ SELECT ${all_columns} FROM otter_filter WHERE filter_name = ?
                          },
    fetch_all     =>    qq{ SELECT ${all_columns} FROM otter_filter
                          },
    fetch_where_stem => qq{ SELECT ${all_columns} FROM otter_filter WHERE
                           },
    update_for_filter_get => qq{ UPDATE otter_filter
                                    SET done = 1, failed = 0, gff_file = ?, process_gff = ?
                                  WHERE filter_name = ?
                               },
);

sub store {
    my ($self, $filter) = @_;
    $self->_check_filter($filter);
    confess "filter already stored" if $filter->is_stored;

    my $result = $self->_store_sth->execute(@{$filter}{@columns});
    $filter->is_stored(1) if $result;

    return $result;
}

sub update {
    my ($self, $filter) = @_;
    $self->_check_filter($filter);
    confess "filter not stored" unless $filter->is_stored;

    my $result = $self->_update_sth->execute(
        @{$filter}{qw(wanted failed done gff_file process_gff)},
        $filter->filter_name
        );
    return $result;
}

sub delete {
    my ($self, $filter) = @_;
    $self->_check_filter($filter);
    confess "filter not stored" unless $filter->is_stored;

    my $result = $self->_delete_sth->execute($filter->filter_name);
    $filter->is_stored(0) if $result;

    return $result;
}

sub _check_filter {
    my ($self, $filter) = @_;

    confess "filter must be supplied" unless $filter;
    confess "filter not a Bio::Otter::Lace::DB::Filter" unless $filter->isa('Bio::Otter::Lace::DB::Filter');

    return $filter;
}

sub fetch_by_name {
    my ($self, $name) = @_;

    my $sth = $self->_fetch_by_name_sth;
    $sth->execute($name);
    my $attribs = $self->_fetch_by_name_sth->fetchrow_hashref;
    return unless $attribs;

    return Bio::Otter::Lace::DB::Filter->new(%$attribs, is_stored => 1);
}

sub fetch_all {
    my ($self) = @_;
    my $sth = $self->_fetch_all_sth;
    return $self->_do_fetch_multi($sth);
}

sub fetch_where {
    my ($self, $condition) = @_;
    my $sql = sprintf('%s %s', $SQL{'fetch_where_stem'}, $condition);
    my $sth = $self->_prepare_cached('_fetch_where_' . $condition, $sql);
    return $self->_do_fetch_multi($sth);
}

sub _do_fetch_multi {
    my ($self, $sth) = @_;
    my @filters;
    $sth->execute;
    while (my $attribs = $sth->fetchrow_hashref) {
        push @filters, Bio::Otter::Lace::DB::Filter->new(%$attribs, is_stored => 1);
    }
    return @filters;
}

# Special atomic update for filter_get script.
#
sub update_for_filter_get {
    my ($self, $filter_name, $gff_file, $process_gff) = @_;
    my $sth = $self->dbh->prepare($SQL{update_for_filter_get});
    return $sth->execute($gff_file, $process_gff, $filter_name);
}

sub _store_sth         { return shift->_prepare_canned('store'); }
sub _update_sth        { return shift->_prepare_canned('update'); }
sub _delete_sth        { return shift->_prepare_canned('delete'); }
sub _fetch_by_name_sth { return shift->_prepare_canned('fetch_by_name'); }
sub _fetch_all_sth     { return shift->_prepare_canned('fetch_all'); }

sub _prepare_canned {
    my ($self, $name) = @_;
    return $self->_prepare_cached("_${name}_sth", $SQL{$name});
}

sub _prepare_cached {
    my ($self, $name, $sql) = @_;
    return $self->{$name} if $self->{$name};

    return $self->{$name} = $self->dbh->prepare($sql);
}

1;

__END__

=head1 NAME - Bio::Otter::Lace::DB::FilterAdaptor

=head1 DESCRIPTION

Stores, retrieves and updates Bio::Otter::Lace::DB::Filter
entries in the otter_filter table of the SQLite database.

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

# EOF
