#!/usr/bin/env perl

use strict;
use warnings;

use lib "${ENV{ANACODE_TEAM_TOOLS}}/t/tlib";
use Test::CriticModule;

use Test::More;
use Test::Otter qw( ^db_or_skipall );
use Test::Requires qw( Bio::EnsEMBL::Variation::DBSQL::DBAdaptor );
use List::Util  qw( max );
use Time::HiRes qw( gettimeofday tv_interval );

use Bio::Otter::Server::Support::Local;

my $TIMEOUT = $ENV{FIND_CLONES_TEST_TIMEOUT} || 1.25; # sec - a bit lenient

my ($safc_module, $safc_tsv_module);

BEGIN {
    $safc_module = qw( Bio::Otter::ServerAction::FindClones );
    $safc_tsv_module = qw( Bio::Otter::ServerAction::TSV::FindClones );
    use_ok($safc_module);
    use_ok($safc_tsv_module);
}

critic_module_ok($safc_module);
critic_module_ok($safc_tsv_module);

my @tests = (
    {
        dataset => 'human',
        queries => {
            OTTHUMT00000039641 =>
                "OTTHUMT00000039641\tOtter:transcript_stable_id\tAL139092.12\tchr6-38\n",

            'OTTHUMG00000014126,OTTHUMP00000015944,RP11-420G6.2' => <<"__EO_RESULT__",
OTTHUMG00000014126\tOtter:gene_stable_id\tAL139092.12\tchr6-38
OTTHUMP00000015944\tOtter:translation_stable_id\tAL139092.12\tchr6-38
RP11-420G6.2\tgene_synonym\tAL139092.12\tchr6-38
__EO_RESULT__

            'ENST00000380773,ENSG00000124535' => <<"__EO_RESULT__",
ENSG00000124535\tEnsEMBL:ensembl_havana_gene:gene_stable_id\tAL139092.12\tchr6-38
ENST00000380773\tCCDS_db:Ens_Hs_transcript:\tAL139092.12\tchr6-38
ENST00000380773\tEnsEMBL:ensembl_havana_transcript:transcript_stable_id\tAL139092.12\tchr6-38
__EO_RESULT__
                    'ACOT4' =>
"ACOT4\tgene_name\tAC005225.2\tchr14-38\n",
        },
    },
    {
        dataset => 'zebrafish',
        queries => {
            ENSDARG00000086319 => <<"__EO_RESULT__",
ENSDARG00000086319\tEnsEMBL:ensembl:gene_stable_id\tCR847984.14\tchr11_20140314
ENSDARG00000086319\tEnsEMBL:ensembl:gene_stable_id\tFQ482077.1\tchr11_20110419
ENSDARG00000086319\tEnsEMBL:ensembl:gene_stable_id\tFQ482077.1\tchr11_20140314
ENSDARG00000086319\tEnsEMBL:ensembl:gene_stable_id\tFQ482077.1,CR847984.14\tchr11_20110419
__EO_RESULT__
        },
    },
    {
        dataset => 'mouse',
        queries => {
            SPDYB => # auto-find the WU: variant
"SPDYB\tgene_name\tAC123686.11\tchr5-38
WU:SPDYB\tgene_synonym\tAC123686.11\tchr5-38",
            "*:SPDYB" => [ # prefix-wildcard finds prefixed variants, slowly
"KO:SPDYB\tgene_name\tAC123686.11\tchr5-38
WU:SPDYB\tgene_synonym\tAC123686.11\tchr5-38", max($TIMEOUT, 10) ],
        },
    },
    );

sub do_find {
    my ($module, %params) = @_;
    my $t0 = [ gettimeofday() ];

    # $server can be re-used, only for the same dataset
    my $server = Bio::Otter::Server::Support::Local->new;
    $server->set_params(%params);

    my $finder = new_ok($module => [ $server ]);
    return ($finder->find_clones, tv_interval($t0));
}

sub do_find_raw {
    my (%params) = @_;
    return do_find($safc_module, %params);
}

sub do_find_tsv {
    my (%params) = @_;
    return do_find($safc_tsv_module, %params);
}

sub tt_raw {
    subtest 'Raw query' => sub {
        my ($got, $t_took) = do_find_raw(dataset => 'human', qnames => 'OTTHUMT00000039641');
        is_deeply($got,
                  { OTTHUMT00000039641 => {
                      'chr6-38' => {
                          'Otter:transcript_stable_id' => { 'AL139092.12' => 1 },
                      }
                    }
                  },
                  'raw result');
        cmp_ok($t_took, '<=', $TIMEOUT, "raw query time");
        done_testing;
    };
    return;
}

sub tt_testlist {
    my ($test) = @_;
    note "Tests for dataset: $test->{dataset}";

    while (my ($query, $want) = each %{$test->{queries}} ) {
        my $t_allow = $TIMEOUT;
        ($want, $t_allow) = @$want if ref($want);

        subtest "Query: $query" => sub {
            my ($got, $t_took) =
              do_find_tsv(qnames  => $query, dataset => $test->{dataset});
            $got = join "\n", sort split /\n/, $got; # test stability sort
            $want =~ s{\n*\Z}{};
            is($got, $want, "query($query) result");
            cmp_ok($t_took, '<=', $t_allow, "query($query) time");
            done_testing;
        }
    }
    return ();
}

sub tt_overflow {
  SKIP: {

      if ($ENV{OTTER_SKIP_SLOW_DB_TESTS}) {
          my $msg = 'tt_overflow as OTTER_SKIP_SLOW_DB_TESTS is set';
          diag "skipping $msg";
          skip $msg, 1;
      }

      my ($got, $t_took) = do_find_tsv(dataset => 'human', qnames => 'D*'); # ~ 6k hits
      like($got, qr{\A\tToo many search results}, 'human D* hit overflow');
    }
    return ();
}

sub main {
    tt_raw();
    tt_testlist($_) foreach @tests;
    tt_overflow();

    done_testing;
    return ();
}

main();

# Local Variables:
# mode: perl
# End:

# EOF
