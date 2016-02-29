#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Time::HiRes qw( gettimeofday tv_interval );
use Bio::Otter::Utils::AccessionInfo;

use Test::Otter qw( ^db_or_skipall get_BOSDatasets );


my $T_BUDGET = 45 / 5000;
# Budget of 45sec per 5k-accession fetch is based on regions I
# have seen recently.  It may need changing.

sub main {
    plan tests => 3;
    subtest compare_and_time_tt => __PACKAGE__->can('compare_and_time_tt');
    subtest time_budget_tt => __PACKAGE__->can('time_budget_tt');
    subtest acc_type_tt => __PACKAGE__->can('acc_type_tt');

    return 0;
}

sub walltime(&) { ## no critic( Subroutines::ProhibitSubroutinePrototypes )
    my ($code) = @_;
    my $t0 = [ gettimeofday() ];
    my @out = $code->();
    unshift @out, tv_interval($t0);
    return @out;
}

sub _ai_per_driver {
    my @drv = ('Bio::Otter::Utils::BulkMM', 'Bio::Otter::Utils::MM');

    # Set up the drivers to compare
    my @ai = map {
        Bio::Otter::Utils::AccessionInfo->new(driver_class => $_);
    } @drv;
    return @ai;
}

sub compare_and_time_tt {
    my @ai = _ai_per_driver();
    plan tests => 2*( 2 * @ai - 1 );
    # D timings, D-1 comparisons; for ACC.SV and again for ACC (deSV)

    my ($ds) = get_BOSDatasets('human_test');
    my $pipe_dbh = $ds->pipeline_dba->dbc->db_handle;

    my $N = 150;
    # N must be big enough that fetching overheads are not "too high"

    # Fetch the set for each driver, then re-fetch the first set.
    # Can only make timings per driver on disjoint sets, due to caching.
    foreach my $mode (qw( ACC.SV ACC_deSV )) {

        my @acc = map {        # a random set of accessions per driver
            random_accessions($pipe_dbh, $N)
        } @ai;
        deSV(\@acc) if $mode eq 'ACC_deSV';

        my (@fetch, @time, @refetch);
        for (my $i=0; $i<@ai; $i++) {
            ($time[$i], $fetch[$i]) = walltime
              { $ai[$i]->get_accession_info($acc[$i]) };

            $refetch[$i] = $i
              ? $ai[$i]->get_accession_info($acc[0]) : $fetch[0];

            # Compare.  They're hashrefs, so this is easy.
            my $drv0 = ref($ai[0]);
            my $drv  = ref($ai[$i]);
            if ($i) {
                is_deeply($refetch[0], $refetch[$i],
                          "$mode: refetch[ $drv0 ] == refetch[ $drv ]")
                  ;# or diag explain \@fetch; # may be large
            }

            # Times
            local $TODO = 'times are awry';
            my $t_ea = $time[$i] / $N;
            cmp_ok($t_ea, '<', $T_BUDGET,
                   sprintf('%s:  time[ %s ] = %.1fs/%s = %.4fs/ea = %.2fx',
                           $mode,    $drv, $time[$i],$N, $t_ea, $t_ea/$T_BUDGET));
        }
    }

    return 0;
}

sub time_budget_tt {
    my ($N, $T) = (2, 10);
    # $N tests of $T sec each.  There can be a large fraction of a
    # second of slop, so don't expect short tests to be accurate.

    plan tests => 3 * $N;

    my ($ds) = get_BOSDatasets('human_test');
    my $pipe_dbh = $ds->pipeline_dba->dbc->db_handle;

    # ask for enough to blow our local time budget $T
    my $accs = int(($T / $T_BUDGET) * 10);

    for (my $i=0; $i<$N; $i++) {
        my $acc_list = random_accessions($pipe_dbh, $accs);
        my ($t_used, $fetch) = walltime {
            my $ai = Bio::Otter::Utils::AccessionInfo->new
              (driver_class => 'Bio::Otter::Utils::BulkMM',
               t_budget => $T);
            return $ai->get_accession_info($acc_list);
        };

        my $t_used_pct = 100 * $t_used / $T;
        my $fetch_n = keys %$fetch;
        my $fetch_pct = 100 * $fetch_n / $accs;

        if ($fetch_pct > 80 && $t_used_pct < 98) {
            # Seems the fetch completed much faster than expected,
            # give it more work
            my $t_ea = $t_used_pct / $accs;
            $accs = int(($T / $t_ea) * 10);
            diag sprintf('Fetched %.1f%% of %s accessions '.
                         'in %.1f%% of t_budget => %.1fsec, '.
                         'next time ask for %s',
                         $fetch_pct, scalar @$acc_list,
                         $t_used_pct, $T,
                         $accs);
            $i --; # again!
        } else {
            # Percentage constraints are somewhat arbitrary, the
            # workload*1% limit should pass if fetches are faster than
            # 10x $T_BUDGET
            cmp_ok($t_used_pct,  '>',  85,
                   sprintf("(t_used == %.2fs) / (t_budget == %.1fs) should be >85%%",
                           $t_used, $T));
            cmp_ok($t_used_pct, '<=', 100,
                   "t_used / t_budget should be <=100%");
            cmp_ok($fetch_pct,  '>=',   1,
                   "(fetch count == $fetch_n) / (workload == $accs accs) should be >=1%");
        }
    }
    return;
}

sub acc_type_tt {
    plan tests => 3;

    my ($ds) = get_BOSDatasets('human_test');
    my $pipe_dbh = $ds->pipeline_dba->dbc->db_handle;
    my @ai = _ai_per_driver();

    my $N = 723; # non-round number, aim to leave some blank placeholders RT#439215
    my $acc_list = random_accessions($pipe_dbh, $N);
    deSV($acc_list);
    my (@fetch, @time);
    for (my $i=0; $i<@ai; $i++) {
        ($time[$i], $fetch[$i]) = walltime
          { $ai[$i]->get_accession_info_no_sequence($acc_list) };

        local $TODO = 'times are awry';
        my $t_ea = $time[$i] / $N;
        cmp_ok($t_ea, '<', $T_BUDGET,
               sprintf('get_accession_info_no_sequence: time[ %s ] = %.1fs/%s = %.4fs/ea = %.2fx',
                       ref($ai[$i]), $time[$i],$N, $t_ea, $t_ea/$T_BUDGET));
    }
    is_deeply($fetch[0], $fetch[1],
              "get_accession_info_no_sequence: fetch[ $ai[0] ] == fetch[ $ai[1] ]")
       or diag explain \@fetch; # may be large

    return 0;
}

# Return arrayref of $N accessions
sub random_accessions {
    my ($dbh, $N, $tbl) = @_;
    $tbl ||= qw(dna_align_feature protein_align_feature)[int(rand(2))];

    my @srid_range = $dbh->selectrow_array
      ("select min(seq_region_id), max(seq_region_id) from $tbl");
    $srid_range[2] = $srid_range[1] - $srid_range[0];

    # gather some until we have enough
    my %srid_used;
    my %out;
    while (keys %out < $N) {
        my $srid = int(rand($srid_range[2])) + $srid_range[0];
        next if $srid_used{$srid} ++;

        my $accs = $dbh->selectcol_arrayref
          ("SELECT hit_name FROM $tbl WHERE seq_region_id = ?", {}, $srid);

        @out{@$accs} = ();
    }

    my $n_del = (keys %out) - $N;
    # drop some at random
    while ($n_del > 0 and my ($k, $v) = each %out) {
        delete $out{$k};
        $n_del --;
    }

    return [ sort keys %out ];
}

# Strip off the .SVs (in place)
sub deSV {
    my ($acc_list) = @_;
    foreach (@$acc_list) {
        s{\.\d+$}{};
    }
    return;
}


exit main();
