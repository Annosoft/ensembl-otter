#! /software/bin/perl-5.12.2
use strict;
use warnings;

use Test::More;
use Digest::MD5 'md5_hex';
use Test::Otter qw( ^db_or_skipall get_BOSDatasets diagdump excused );

use AccessionChecksum;


=head1 DESCRIPTION

Sequence data is fetched through a cache file, from pfetch and falling
back on EMBL SVA.

Check the sequence (its md5sum) and length of all clones for species.

Check sequence of contigs not covered by the first "contig for
entire-clone" check, that it matches what's in the clone.
e.g. CU466435.2.* in pig.

=head2 Not implemented

Check pipedb has either matching sequence, or point to us.

Check all satellite databases with equiv sequence are actually equiv.

Check the API returns, for each clone and/or contig, what we get
direct from dna.sequence.

C<$ENV{TEST_SLOW} or BAIL_OUT> or similar, before proceeding.

=head1 AUTHOR

mca@sanger.ac.uk

=cut


sub main {
    @ARGV = qw(pig) unless @ARGV;
    my @ds = get_BOSDatasets(@ARGV);
    plan tests => 3 * @ds;
    $SIG{INT} = sub { die "Caught SIGINT - tidying up\n" };

    foreach my $ds (@ds) {
        my $name = $ds->name;
        my $O = $ds->otter_dba;
        my $clones = $O->get_SliceAdaptor->fetch_all(clone => undef, 1, 1, 1);
        my $cache = AccessionChecksum->new($name);

        subtest "(p)fetch DNA for $name" => sub {
            plan tests => 1 * @$clones;
            my $fail = pfetch_tt($ds, $cache, $clones);
            diagdump(fail => $fail) if keys %$fail;
        };
        subtest "Whole clones in $name" => sub {
            plan tests => 2 * @$clones;
            my $fail = species_tt($ds, $cache, $clones);
            diagdump(fail => $fail) if keys %$fail;
        };
        subtest "Other DNA in $name" => sub {
            other_dna_tt($ds, $O); # plan inside
        };
    }

    return;
}


# Test that clones' DNA can be/has been fetched into cache.
# Some items are excused failure.
sub pfetch_tt {
    my ($ds, $cache, $clones) = @_;
    my @unfetched = map { $_->seq_region_name } @$clones;

    my %fail;
    while (@unfetched) {
        my ($rname, $pmd5) = $cache->next_md5(\@unfetched);

        excused(like => [ 'clone_dna.t', $ds->name, "$rname fetch" ],
                $pmd5, qr{^[0-9a-f]{32}+$})
          or $fail{$rname} = $pmd5;
    }
    return \%fail;
}


# Test clone properties in database, given prefetched original DNA
sub species_tt {
    my ($ds, $cache, $clones) = @_;
    my $dbname;

    my %fail;
    foreach my $cl (@$clones) {
        $dbname ||= $cl->adaptor->dbc->dbname;
        my $rname = $cl->seq_region_name;

# XXX: tell what chromosome(s) it's on
        my $pmd5 = $cache->get_md5($rname);
        $pmd5 = 'fetcher breakage' unless defined $pmd5;

        my $R = clone_info($cl);
        my $nR = @$R;
        my @b0rk;

      SKIP: {
            excused(is => [ 'clone_dna.t', $ds->name, "$rname one_ctg" ], $nR, 1)
              or $fail{one_ctg}{$rname} = $R;
            skip "$nR rows found", 1 unless 1 == $nR;
            my %r = %{ $R->[0] };

            push @b0rk, "dna.seq.len != sr.len" unless $r{seq_len} == $r{rlen};
            push @b0rk, "sr.name: expect $rname.1.$r{rlen}, got $r{rname}"
              unless $r{rname} eq "$rname.1.$r{rlen}";
            push @b0rk, "cs.name: expect 'contig', got $r{cs_name}"
              unless $r{cs_name} eq 'contig';

            if ($r{seq_md5} eq $pmd5) {
                # OK
            } elsif ($pmd5 =~ m{^!}) {
                # no data - already reported
            } else {
                push @b0rk, 'md5 fail';
                $r{expect_md5} = $pmd5;
            }

            excused(is => [ 'clone_dna.t', $ds->name, "$rname ctg_cmp" ],
                    scalar @b0rk, 0)
              and @b0rk = (); # no detail report when excused

            if (1 == @b0rk) {
                # collect like problems
                $fail{$b0rk[0]}{$rname} = \%r;
            } elsif (@b0rk) {
                # more complex
                $fail{$rname} = [ \%r, @b0rk ];
            } # else no probs
        }

        # debug hook: see what's going on early
        diagdump(b0rk => \@b0rk, R => $R) if @b0rk && $ENV{TEST_EARLY};
    }

    return \%fail;
}


sub clone_info {
    my ($cl) = @_;
    my $rname = $cl->seq_region_name;

    # Find sequence this clone, stored at contig level.  Assume there
    # is a contig covering the entire clone.
    # Doesn't cope with compressed sequence (dnac)
    my $R = $cl->adaptor->dbc->db_handle->selectall_arrayref(q{
 SELECT r.seq_region_id, r.name, r.length, cs.name, length(d.sequence), md5(d.sequence)
 FROM seq_region r
   JOIN dna d USING (seq_region_id)
   JOIN coord_system cs USING (coord_system_id)
 WHERE r.name = ? }, {}, (join '.', $rname, $cl->start, $cl->end));

    return [ map {
        my %row;
        @row{qw{ srid rname rlen cs_name seq_len seq_md5 }} = @$_;
        \%row;
    } @$R ];
}


sub other_dna_tt {
    my ($ds, $O) = @_;
    my $slA = $O->get_SliceAdaptor;
    my $dbh = $O->dbc->db_handle;

    # Contigs covering whole clones were tested (direct from DB).
    # List the clones.
    my $clones = $slA->fetch_all(clone => undef, 1, 1, 1);
    my $n_clone = @$clones;
    my @ctg4clone # expected contig names for clones
      = map { join '.', $_->seq_region_name, $_->start, $_->end } @$clones;
    undef $clones;

    # List all contigs
    my $R = $dbh->selectall_arrayref(q{
 SELECT r.name
 FROM seq_region r
   JOIN coord_system cs USING (coord_system_id)
 WHERE cs.name = 'contig' }, {});
    my $tot_n_ctg = @$R;

    # Collect the not-whole-clone ones
    my %ctg4clone;
    @ctg4clone{@ctg4clone} = ();
    my @ctg = sort(grep { !exists $ctg4clone{$_} }
                   # list of r.name
                   map { $_->[0] } @$R);
    diag sprintf('Found %d not-whole-clone contigs, out of %d contigs',
                 scalar @ctg, $tot_n_ctg);

    plan tests => 2 + 6 * @ctg;

    (cmp_ok($n_clone, '>', 10, 'clone count') && # arbitrary "did we get some?"
     cmp_ok($tot_n_ctg, '>=', $n_clone, 'clones have contigs'))
      or diagdump(n_clone => $n_clone, tot_n_ctg => $tot_n_ctg, ctg_left => scalar @ctg);


    # There are a "small" number of odd contigs (at least in pig).
    # See that the part-contig match the full, but is then unused.
    foreach my $ctg_name (@ctg) {
        my ($cl_name, $ctg_start, $ctg_end) = $ctg_name =~ m{^(.*)\.(\d+)\.(\d+)$};
      SKIP: {
            ok($cl_name, "$ctg_name: contig name parse")
              or skip 'find clone fail', 5;

            # odd contig should probably not be referenced from assembly
            my $asy_rows = $dbh->selectall_hashref(q{
 SELECT asm.name asm, asm.length asm_len,
   count(*) numseg,
   cmp.name cmp, cmp.length cmp_len
 FROM seq_region asm
   JOIN assembly a ON asm.seq_region_id = asm_seq_region_id
   JOIN seq_region cmp ON cmp.seq_region_id = cmp_seq_region_id
 WHERE asm.name = ? or cmp.name = ?
 GROUP BY 1,2 }, [1, 4], {}, $ctg_name, $ctg_name);
            excused(is => [ 'clone_dna.t', $ds->name, "$ctg_name be_unused" ],
                    scalar keys %$asy_rows, 0)
              or diagdump(asy_rows => $asy_rows);

            # get corresponding full-clone ctg
            my $cl = $slA->fetch_by_region
              (clone => $cl_name,
               undef, undef, undef, undef, 1); # no fuzzy
            ok($cl, "$ctg_name: find clone $cl_name in db")
              or skip 'find clone fail', 3;

            # info for contig-under-test and contig-for-full-clone
            my $cl_ctg_name = join '.',
              $cl->seq_region_name, $cl->start, $cl->end;
            $R = $dbh->selectall_arrayref(q{
 SELECT r.name, r.length, d.sequence
 FROM seq_region r
   JOIN dna d USING (seq_region_id)
 WHERE r.name in (?, ?) }, {}, $ctg_name, $cl_ctg_name);

            my %len =
              (dna_seq => [ map { length($_->[2]) } @$R ],
               sr_len  => [ map { $_->[1] } @$R ],
               name    => [ map { $_->[0] } @$R ],
               cl_len => $cl->length);

            if (!is(2, scalar @$R, "fetch ($ctg_name, $cl_ctg_name) direct")) {
                diagdump(got_len => \%len);
                skip 'absent', 2;
            }

            is_deeply($len{dna_seq}, $len{sr_len}, "$ctg_name lengths")
              or diagdump(len => \%len);
            # $cl_ctg_name lengths are already checked

            my %ctg = map {( $_->[0], $_->[2] )} @$R; # name => seq
            my %subseq =
              (contig_under_test => $ctg{$ctg_name},
               clone_subseq => substr($ctg{$cl_ctg_name},
                                      $ctg_start-1, $ctg_end - $ctg_start + 1));
            my %md5 = map {( $_.'_md5', md5_hex($subseq{$_}) )} keys %subseq;
            excused(is => [ 'clone_dna.t', $ds->name, "$ctg_name subseq" ],
                    values %md5)
              or diagdump(md5 => \%md5,
                          # subseq => \%subseq, # long!
                          len => \%len);
        }
    }

    return;
}



main();
