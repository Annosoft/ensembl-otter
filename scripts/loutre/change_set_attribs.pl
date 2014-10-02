#!/usr/bin/env perl

=head1 NAME

change_set_attribs.pl

=head1 SYNOPSIS

 change_set_attribs.pl -dataset dinosaur -old -set chr1-04,chr2-07
 change_set_attribs.pl -dataset dinosaur -new      chr1-09 chr2-09

or in the older connection-parameter style

 change_set_attribs.pl -host otterlive -port 3324 -user pipuser -pass ***** \
   -dbname loutre_human -visible -read ...

=head1 DESCRIPTION

This script is used to change the visibility and writability of a sequence set in
any loutre database.

=head1 OPTIONS

    -host (default:otterlive)   host name of the database with missing contig dna
    -dbname (no default)  For RDBs, what database to connect to
    -user (check the ~/.netrc file)  For RDBs, what username to connect as
    -pass (check the ~/.netrc file)  For RDBs, what password to use
    -port (check the ~/.netrc file)   For RDBs, what port to use

    -dataset <species>   consult Otter Server for the database
    -[loutre|pipe]       make the change on one database.  Default: both

        -dbname and -dataset are mutually exclusive.
        Only one database is touched when using -dbname.

    -[write|read]        make the set writable or read-only
    -[visible|hide]      make the set visible or hide it
    -csver <name>        change coordinate_system version (e.g. Otter, OtterArchive)

    -new                 means "-write -visible -csver Otter"
    -old                 means "-read  -hide    -csver OtterArchive"

    -set                 comma separated list of sequence sets.
        These may also be passed as space-separated trailing
        arguments, for convenience with shell globbing.


    -help|h              displays this documentation with PERLDOC

=head1 SQL

  UPDATE seq_region_attrib
  SET value = '0'
  WHERE attrib_type_id = 128
    AND seq_region_id IN
  (SELECT seq_region_id
      FROM seq_region
      WHERE name like '%_20101111')


=head1 SEE ALSO

F<scripts/loutre/sync_set_attributes_and_coord_systems>

=head1 CONTACT

Mustapha Larbaoui B<email> ml6@sanger.ac.uk

=cut

use strict;
use warnings;
use Getopt::Long;
use DBI;
use Net::Netrc;
use Bio::EnsEMBL::Utils::Exception qw(throw warning);

{

    my $user;
    my $pass;
    my $port;
    my $host = 'otterlive';
    my $dbname;

    my $dataset;
    my ($sel_loutre, $sel_pipe);

    my $set;
    my $write;
    my $read;
    my $visible;
    my $csver;
    my $hide;

    my $usage = sub { exec('perldoc', $0); };


    GetOptions
      ('host=s'   => \$host,
       'port=n'   => \$port,
       'dbname=s' => \$dbname,
       'user=s'   => \$user,
       'pass=s'   => \$pass,

       'dataset|D=s' => \$dataset,
       'loutre!'  => \$sel_loutre,
       'pipe!'    => \$sel_pipe,

       'write!'   => \$write,
       'read!'    => \$read,
       'visible!' => \$visible,
       'hide!'    => \$hide,
       'csver=s'  => \$csver,

       'new|N!'   => sub { $write = $visible = 1; $csver = 'Otter' },
       'old|O!'   => sub { $read  = $hide    = 1; $csver = 'OtterArchive' },

       'set=s'    => \$set,
       'h|help!'  => $usage) or $usage->();

    throw("-dbname and -dataset are mutually exclusive")
      if (defined $dbname && defined $dataset);
    throw("-loutre and -pipe options require -dataaset")
      if (($sel_loutre || $sel_pipe) && !$dataset);

    throw("Need a target pipeline database name (-dbname or -dataset)")
      unless ($dbname || $dataset);

    my @sets;
    push @sets, split /,/, $set if defined $set;
    push @sets, @ARGV;

    throw("Must provide a list of set names") unless @sets;

    if ($write && $read) {
        throw("Make the set either writable or read-only, not both !");
    }
    if ($visible && $hide) {
        throw("Make the set either visible or hidden, not both !");
    }

    my @dbh;
    if ($dbname) {
        # Reading the DB connexion parameters from ~/.netrc
        my $ref = Net::Netrc->lookup($host);
        if (!$ref) {
            print STDERR "No entry found in ~/.netrc for host $host\n";
            next;
        }
        $user = $ref->login;
        $pass = $ref->password;
        $port = $ref->account;

        # Creating the DB connection
        my $dsn = "DBI:mysql:database=$dbname;host=$host;port=$port";
        push @dbh, DBI->connect($dsn, $user, $pass, { 'RaiseError' => 1 });
    } else {
        if (!$sel_loutre || $sel_pipe) {
            # default: both
            $sel_loutre = $sel_pipe = 1;
        }
        push @dbh, otter_client_dbhs($dataset, $sel_loutre, $sel_pipe);
    }


    foreach my $dbh (@dbh) {
        printf "Operating on %s \@ %s\n", $dbh->selectrow_array('select DATABASE(), @@hostname');
        change_props($dbh, $write, $read, $visible, $hide, $csver, @sets);
    }
}


sub change_props {
    my ($dbh, $write, $read, $visible, $hide, $csver, @sets) = @_;

    my $sth_attr = $dbh->prepare(qq{
        UPDATE attrib_type t
          , seq_region s
          , seq_region_attrib a
        SET a.value = ?
        WHERE s.name = ?
          AND s.seq_region_id = a.seq_region_id
          AND t.code = ?
          AND t.attrib_type_id = a.attrib_type_id
    });

    my $sth_cs = $dbh->prepare(q{
        UPDATE seq_region s
         JOIN coord_system cs USING (coord_system_id)
        SET s.coord_system_id =
         (SELECT coord_system_id
          FROM coord_system cs2
          WHERE name = cs.name and version = ?)
        where s.name = ?
    });

    foreach (@sets) {
        my ($r, $w, $v, $h, $cs);

        # Make the set either read-only or visible
        if ($write) {
            $w = $sth_attr->execute(1, $_, 'write_access');
        }
        elsif ($read) {
            $r = $sth_attr->execute(0, $_, 'write_access');
        }

        # Make the set either visible or hidden
        if ($visible) {
            $v = $sth_attr->execute(0, $_, 'hidden');
        }
        elsif ($hide) {
            $h = $sth_attr->execute(1, $_, 'hidden');
        }

        # Change the coordinate_system
        if ($csver) {
            $cs = $sth_cs->execute($csver, $_);
        }

        my $out = "    Made $_\t";
        $out .= "Writable [" .  ($w > 0 ? "OK" : "FAILED") . "] " if $write;
        $out .= "Read-Only [" . ($r > 0 ? "OK" : "FAILED") . "] " if $read;
        $out .= "Visible [" .   ($v > 0 ? "OK" : "FAILED") . "] " if $visible;
        $out .= "Hidden [" .    ($h > 0 ? "OK" : "FAILED") . "] " if $hide;
        $out .= "$csver [" .    ($cs> 0 ? "OK" : "FAILED") . "] " if $csver;

        print $out. "\n";
    }
}


sub otter_client_dbhs {
    my ($dataset_name, $sel_loutre, $sel_pipe) = @_;
    die "expect list context" unless wantarray;

    require Bio::Otter::Server::Config;
    my $ds = Bio::Otter::Server::Config->SpeciesDat->dataset($dataset_name);
    my $otter_dba = $ds->otter_dba;
    my $pipe_dba = $ds->pipeline_dba('rw');

    my @dbh;
    push @dbh, $otter_dba->dbc->db_handle if $sel_loutre;
    push @dbh, $pipe_dba->dbc->db_handle if $sel_pipe;
    return @dbh;
}
