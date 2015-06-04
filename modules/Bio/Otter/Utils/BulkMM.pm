package Bio::Otter::Utils::BulkMM;

use strict;
use warnings;

use DBI;
use Readonly;
use Time::HiRes qw( gettimeofday tv_interval );

=pod

Notes on the MM schema

All cells in the entry.accession columns match
/'^[[:alnum:]]+(-[[:digit:]]+)?\.[[:digit:]]+$'/

=cut

# NB: databases will be searched in the order in which they appear in this list

Readonly my @ALL_DB_CATEGORIES => qw(
    emblnew
    emblrelease
    uniprot
    uniprot_archive
    refseq
    mushroom
);

Readonly my $UNIPARC => 'uniprot_archive';

Readonly my @DEFAULT_DB_CATEGORIES => qw(
    emblnew
    emblrelease
    uniprot
    uniprot_archive
);

Readonly my %DB_NAME_TO_SOURCE => (
    emblnew     => 'EMBL',
    emblrelease => 'EMBL',
    refseq      => 'RefSeq',
    );

Readonly my %CLASS_TO_SOURCE => (
    STD => 'SwissProt',
    PRE => 'TrEMBL',
    ISO => 'SwissProt',  # we don't think TrEMBL can have isoforms
    );

Readonly my %DEFAULT_OPTIONS => (
    host => 'cbi5d',
    port => 3306,
    user => 'genero',
    name => 'mm_ini',
    db_categories => [ @DEFAULT_DB_CATEGORIES ],
    );

my $BULK = 1000; # how many placeholders in SQL == max fetch chunk size
my $SLOW_FETCH = 0.6; # estimated worst-case fetch time, sec/each


sub new {
    my ($class, @args) = @_;

    my %options = ( %DEFAULT_OPTIONS, @args );
    $options{t_budget} ||= 604800; # default = 1 week, in seconds

    my $self = bless \%options, $class;
    $self->t_reset;
    $self->_build_sql;

    return $self;
}

sub t_reset {
    my ($self) = @_;
    return $self->{t0} = [ gettimeofday() ];
}

sub t_used {
    my ($self) = @_;
    return tv_interval($self->{t0});
}

sub t_budget {
    my ($self) = @_;
    return $self->{t_budget};
}


sub _get_connection {
    my ($self, $category) = @_;

    my $dbh;

    # get a connection to mm_ini to look up the correct tables/databases
    my $dsn_mm_ini = "DBI:mysql:".
        "database=".$self->name.
        ";host=".$self->host.
        ";port=".$self->port;

    my $dbh_mm_ini = DBI->connect($dsn_mm_ini, $self->user, '', { 'RaiseError' => 1 });

    if ($category eq $UNIPARC) {

        # find the correct host and db to connect to from the connections table

        my $arch_sth = $dbh_mm_ini->prepare(qq{
            SELECT db_name, port, username, host, poss_nodes
            FROM connections
            WHERE is_active = 'yes'
            LIMIT 1
        });

        $arch_sth->execute or die "Couldn't execute statement: " . $arch_sth->errstr;

        my $db_details = $arch_sth->fetchrow_hashref or die "Failed to find active $UNIPARC";

        my $dsn = "DBI:mysql:".
            "database=".$db_details->{'db_name'}.
            ";host=".$db_details->{'host'}.$db_details->{'poss_nodes'}.
            ";port=".$db_details->{'port'};

        $dbh = DBI->connect($dsn, $db_details->{'username'}, '', { 'RaiseError' => 1 });
    }
    else {

        # look for the current and available table for this category from the ini table

        my $ini_sth = $dbh_mm_ini->prepare(qq{
            SELECT database_name
            FROM ini
            WHERE database_category = ?
            AND current = 'yes'
            AND available = 'yes'
        });

        $ini_sth->execute($category) or die "Couldn't execute statement: " . $ini_sth->errstr;

        my $db_details = $ini_sth->fetchrow_hashref;
        unless ($db_details) {
            if ($category eq 'emblnew') {
                return;
            }
            else {
                die "Failed to find available db for $category";
            }
        }

        my $dsn = "DBI:mysql:".
            "database=".$db_details->{'database_name'}.
            ";host=".$self->host.
            ";port=".$self->port;

        $dbh = DBI->connect($dsn, $self->user, '', { 'RaiseError' => 1 });
    }

    return $dbh;
}

sub dbh {
    my ($self, $category) = @_;

    die "DB category required" unless $category;

    die "Invalid DB category: $category"
      unless grep { /^$category$/ } @ALL_DB_CATEGORIES;

    unless ($self->{'_dbh_cache'}{$category}) {
        $self->{'_dbh_cache'}{$category} = $self->_get_connection($category);
    }

    return $self->{'_dbh_cache'}{$category};
}

# We construct a matrix of queries: (plain, with-iso) x (exact, like)
# Each has $BULK number of placeholders.
sub _build_sql {
    my ($self) = @_;

    # May be dangerous to assume that the most recent entries in uniprot_archive
    # will have the biggest entry_id

    my $common_sql = q{
SELECT e.entry_id
  , e.molecule_type
  , e.data_class
  , e.accession_version AS acc_sv
  , e.sequence_length
  , GROUP_CONCAT(t.ncbi_tax_id) as taxon_list
  , d.description
%s
WHERE e.accession_version %s
GROUP BY e.entry_id
ORDER BY e.entry_id ASC
};

    my $join_sql = q{
FROM entry e
JOIN description d ON e.entry_id = d.entry_id
JOIN taxonomy    t ON e.entry_id = t.entry_id };

    my $PHs = __bulk_ph();
    my $LIKEs = join ' OR e.accession_version ', ('LIKE ?') x $BULK;
    my $bulk_sv_sql = sprintf( $common_sql, $join_sql, $PHs );
    my $like_sv_sql = sprintf( $common_sql, $join_sql, $LIKEs );

    # For uniprot_archive, we need to use the isoform table for splice variants
    my $join_iso_sql = q{
FROM entry e
JOIN description d ON e.entry_id = d.entry_id
JOIN isoform     i ON e.entry_id = i.isoform_entry_id
JOIN taxonomy    t ON i.parent_entry_id = t.entry_id };

    my $bulk_sv_iso_sql = sprintf( $common_sql, $join_iso_sql, $PHs );
    my $like_sv_iso_sql = sprintf( $common_sql, $join_iso_sql, $LIKEs );

    $self->{_sql} = {
        plain => {
            bulk => $bulk_sv_sql,
            like => $like_sv_sql,
        },
        iso => {
            bulk => $bulk_sv_iso_sql,
            like => $like_sv_iso_sql,
        },
    };

    return;
}

sub __bulk_ph {
    return join ',', " IN ( /* $BULK */ ?", ('?') x ($BULK - 2), '?)';
}


# Return and cache the statement handle based on db_name, iso-ness and search type
#
sub _sth_for {
    my ($self, $db_name, $iso_key, $search_key) = @_;

    my $dbh = $self->dbh($db_name) or return;

    my $sth = $self->{_sth}{$dbh}{$iso_key}{$search_key};
    return $sth if $sth;

    my $sql = $self->{_sql}{$iso_key}{$search_key};
    $sth = $dbh->prepare($sql);
    return $self->{_sth}{$dbh}{$iso_key}{$search_key} = $sth;
}

sub _seq_sth_for {
    my ($self, $db_name) = @_;

    my $dbh = $self->dbh($db_name) or return;
    my $sth = $self->{_seq_sth}{$dbh};
    return $sth if $sth;

    my $PHs = __bulk_ph();
    my $sql = qq{
SELECT   entry_id, sequence
FROM     sequence
WHERE    entry_id $PHs
ORDER BY entry_id ASC, split_counter ASC
    };

    $sth = $dbh->prepare($sql);
    return $self->{_seq_sth}{$dbh} = $sth;
}

# How many can we fetch, hoping to stay inside the time budget?
sub _chunk_size {
    my ($self, $n_fetched) = @_;
    my $t_used = $self->t_used;
    my $t_ea_avg = $n_fetched ? ($t_used / $n_fetched) : $SLOW_FETCH;
    my $t_left = $self->t_budget - $t_used;
    $t_left -= 2 * $SLOW_FETCH; # avoid overrun due to a couple of slow
    my $max = int($t_left / $t_ea_avg);
    $max = $BULK if $max > $BULK;
    $max = 0 if $max < 0;
    return $max;
}

sub get_accession_types {
    my ($self, $accs) = @_;
    return $self->_get_accessions(
        acc_list      => $accs,
        db_categories => [ @DEFAULT_DB_CATEGORIES ],
        sv_search     => 1,
        );
}

sub get_accession_info {
    my ($self, $accs) = @_;
    return $self->_get_accessions_managed(
        acc_list      => $accs,
        db_categories => $self->db_categories,
        sv_search     => 1,
        );
}

sub _get_accessions_managed {
    my ($self, %opts) = @_;
    my $results = $opts{existing_results} = {};
    my @want = @{ delete $opts{acc_list} };

    my $n_wanted = @want;
    while (@want) {
        my $already_asked = $n_wanted - @want;
        my @ask = splice @want, 0, $self->_chunk_size($already_asked);
        last if !@ask; # out of time
        $self->_get_accessions(%opts, acc_list => \@ask);
    }

    return $results;
}


sub _get_accessions {
    my ($self, %opts) = @_;

    my %acc_hash = map { $_ => 1 } @{$opts{acc_list}};
    my $results = $opts{existing_results} || {};

  DB: for my $db_name (@{$opts{db_categories}}) {

      my %search;
      my @get_seq; # ($row)s to fill in
    NAME: foreach my $name (keys %acc_hash) {
        my ($sth_type, $search_term) =
          $self->_classify_search($db_name, $name, $opts{sv_search});
        next NAME unless $sth_type;

        $search{$sth_type}{$name} = $search_term;
    } # NAME

      while (my ($sth_type, $terms) = each %search) {
          my @terms = sort { $a cmp $b } values %$terms;

          my ($iso_key, $search_key) = split /,/, $sth_type;
          my $sth = $self->_sth_for($db_name, $iso_key, $search_key) or next;

          while (@terms) {
              my @chunk_of_terms = splice @terms, 0, $BULK;
              my @search_results = $self->_do_query($sth, \@chunk_of_terms);

            RESULT: foreach my $row (@search_results) {
                  # we have to reconstruct $name
                  my $name = $row->{acc_sv};
                  $name =~ s{\.\d+$}{} if $search_key eq 'like';
                  $row->{name} = $name;

                  $self->_set_currency($db_name, $row);
                  $self->_debug_result($db_name, $row) if $self->debug;

                  if ($self->_classify_result($db_name, $row)) {
                      $results->{$name} = $row;
                      push @get_seq, $row;
                  }

                  delete $acc_hash{$name}; # so we don't search for it in next DB if we already have it

              } # RESULT

          } # chunk of terms
      } # search type

      @get_seq = sort { $a->{entry_id} <=> $b->{entry_id} } @get_seq;
      while (@get_seq) {
          my @chunk_of_rows = splice @get_seq, 0, $BULK;
          $self->_get_sequence($db_name, \@chunk_of_rows);
      }

      # We don't need to search any further databases if we've found everything
      last unless keys %acc_hash;

  } # DB

    return $results;
}

sub _do_query {
    my ($self, $sth, $search_terms) = @_;

    my @results;
    my @search = @$search_terms;
    push @search, ('') x ($BULK - @search);
    $sth->execute(@search);
    while (my $row = $sth->fetchrow_hashref) {
        push @results, $row;
    }
    return @results;
}

sub _classify_search {
    my ($self, $db_name, $name, $sv_search) = @_;

    my $is_uniprot_archive = ($db_name eq $UNIPARC);
    my ($sth, $search_term);

      my ($stem, $iso, $sv) = $self->_parse_accession($name);
  SWITCH: {
      if ($is_uniprot_archive and $iso and $sv) {
          $sth = 'iso,bulk';
          $search_term = $name;
          last SWITCH;
      }
      if ($is_uniprot_archive and $iso and $sv_search) {
          $sth = 'iso,like';
          $search_term = "$name.%";
          last SWITCH;
      }
      if ($sv) {
          $sth = 'plain,bulk';
          $search_term = $name;
          last SWITCH;
      }
      if ($sv_search) {
          $sth = 'plain,like';
          $search_term = "$name.%";
          last SWITCH;
      }
      # default
      warn "Bad query: '$name' (sv_search is off)";
      last SWITCH;
  }
    return ($sth, $search_term);
}

sub _classify_result {
    my ($self, $db_name, $row) = @_;

    my ($name, $type, $class) = @$row{qw(name molecule_type data_class)};
    if ($type eq 'protein') {
        $row->{source} = $CLASS_TO_SOURCE{$class}
            || die "Unexpected data class for uniprot entry: '$class'";
        $row->{evi_type} = 'Protein';
    }
    else {
        my $source = $row->{source} = $DB_NAME_TO_SOURCE{$db_name};
        if ($source eq 'EMBL') {
            # Only EMBL nucleotide entires get evi_type - enables use as supporting evidence
            if ($class eq 'EST') {
                $row->{evi_type} = 'EST';
            }
            elsif ($type eq 'mRNA') {
                # Here we return cDNA, which is more technically correct since
                # both ESTs and cDNAs are mRNAs.
                $row->{evi_type} = 'cDNA';
            }
            elsif ($type eq 'other RNA' or $type eq 'transcribed RNA') {
                $row->{evi_type} = 'ncRNA';
            }
        }
    }
    unless ($row->{source}) {
        warn "Cannot classify '$name': molecule_type = '$type', data_class = '$class'\n";
        return;
    }

    return $row;
}

sub _set_currency {
    my ($self, $db_name, $row) = @_;

    my $currency;
  SWITCH: {

      # only an issue for uniprot_archive
      do { $currency = 'current';  last SWITCH } unless $db_name eq $UNIPARC;

      my ($name, $iso, $sv) = $self->_parse_accession($row->{acc_sv});

      # current non-isoforms would have been found in uniprot
      do { $currency = 'archived'; last SWITCH } unless $iso;

      # Okay, we need to check whether the parent is in uniprot
      my $parent = "$name.$sv";
      my $sth = $self->_sth_for('uniprot', 'plain', 'bulk');
      my @results = $self->_do_query($sth, [ $parent ]);

      $currency = @results ? 'current' : 'archived';
    }

    return $row->{currency} = $currency;
}

sub _parse_accession {
    my ($self, $accession) = @_;
    my ($name, $iso, $sv) = $accession =~ m/^(\S+?)(?:-(\d+))?(?:\.(\d+))?$/;
    return ($name, $iso, $sv);
}

sub _debug_result {
    my ($self, $db_name, $row) = @_;
    my (        $name, $type,        $class,    $acc_sv, @extra_info) =
        @$row{qw(name  molecule_type data_class  acc_sv  sequence_length taxon_list description currency)};
    print "MM result: ", join(',', $name, $acc_sv, $db_name, $type, $class, @extra_info), "\n";
    return;
}

sub _get_sequence {
    my ($self, $db_name, $rows) = @_;

    my $sth = $self->_seq_sth_for($db_name);
    my %rows; # key=entry_id, value=\@row
    # possibility of dup entry_id comes from query hits, one without .SV
    foreach my $row (@$rows) {
        push @{ $rows{ $row->{entry_id} } }, $row;
    }

    my @eid = sort { $a <=> $b } keys %rows;
    push @eid, (undef) x ($BULK - @eid);
    $sth->execute(@eid);

    while (my ($eid, $chunk) = $sth->fetchrow_array) {
        die "Unexpected sequence for entry_id=$eid" unless $rows{$eid};
        foreach my $row (@{ $rows{$eid} }) {
            $row->{sequence} .= $chunk;
        }
    }

    foreach my $row (@$rows) {
        my $name = $row->{name};
        if (!defined $row->{sequence}) {
            warn "No sequence for '$name'\n";
        } else {
            my $got = length($row->{sequence});
            my $want = $row->{sequence_length};
            die "Seq length mismatch for '$name': db=$want, actual=$got\n"
              unless $got == $want;
        }
    }
    return;
}

my @tax_type_list = (
    q(scientific name),
    q(common name),
    );

my $type_key_hash = { };
for my $type (@tax_type_list) {
    my $key = $type;
    $key =~ s/ /_/g;
    $type_key_hash->{$type} = $key;
}

my $taxonomy_info_select_sql_template = '
    select tax.ncbi_tax_id     as id
         , tax_name.name_type  as type
         , tax_name.name       as name
    from       taxonomy      tax
    inner join taxonomy_name tax_name using ( ncbi_tax_id )
    where tax.ncbi_tax_id in ( %s )
    and   name_type       in ( %s )
    ';

sub get_taxonomy_info {
    my ($self, $id_list) = @_;

    my $dbh = $self->dbh('mushroom');
    my $sql = sprintf
        $taxonomy_info_select_sql_template
        , (join ' , ', qw(?) x @{$id_list})
        , (join ' , ', qw(?) x @tax_type_list)
        ;
    my $row_list = $dbh->selectall_arrayref($sql, { 'Slice' => { } }, @{$id_list}, @tax_type_list);

    my $id_info_hash = { };
    for (@{$row_list}) {
        my ($id, $type, $name) = @{$_}{qw( id type name )};
        my $key = $type_key_hash->{$type};
        $id_info_hash->{$id}{'id'} = $id;
        $id_info_hash->{$id}{$key} = $name;
    }
    my $info = [ values %{$id_info_hash} ];

    return $info;
}

sub name {
    my ($self, $name) = @_;
    $self->{name} = $name if $name;
    return $self->{name};
}

sub host {
    my ($self, $host) = @_;
    $self->{host} = $host if $host;
    return $self->{host};
}

sub port {
    my ($self, $port) = @_;
    $self->{port} = $port if $port;
    return $self->{port};
}

sub user {
    my ($self, $user) = @_;
    $self->{user} = $user if $user;
    return $self->{user};
}

sub db_categories {
    my ($self, $db_categories) = @_;
    $self->{db_categories} = $db_categories if $db_categories;
    return $self->{db_categories};
}

sub debug {
    my ($self, $debug) = @_;
    $self->{debug} = $debug if $debug;
    return $self->{debug};
}

1;

__END__

=head1 NAME - Bio::Otter::Utils::BulkMM

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

