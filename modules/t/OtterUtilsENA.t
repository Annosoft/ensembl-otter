#!/usr/bin/env perl

use strict;
use warnings;

use lib "${ENV{ANACODE_TEAM_TOOLS}}/t/tlib";
use Test::CriticModule;

use Test::More;

my $module;
BEGIN {
    $module = 'Bio::Otter::Utils::ENA';
    use_ok($module);
}

critic_module_ok($module);

my $ena = $module->new;
isa_ok($ena, $module);

my @valid_accs = qw(ERS000123 SRS000012 DRS000234);
my @invalid_accs = qw(ERA000012 XYZ123456 AA020997); # one submission, one nonsense, one non-SRA

my $results = $ena->get_sample_accessions(@valid_accs, @invalid_accs);
is(ref($results), 'HASH', 'results hash');

foreach my $valid ( @valid_accs ) {
    my $sample = $results->{$valid};
    ok($sample, "$valid: have result");
}

foreach my $invalid ( @invalid_accs ) {
    my $sample = $results->{$invalid};
    ok(not($sample), "$invalid: no result");
}

my $at_results = $ena->get_sample_accession_types(@valid_accs, @invalid_accs);
is(ref($at_results), 'HASH', 'at_results hash');

foreach my $valid ( @valid_accs ) {
    my $at = $at_results->{$valid};
    ok($at, "$valid: have at_result");
    ok($at->[4], "$valid: has taxon_id");
    note("\ttaxon_id:\t", $at->[4]);
    note("\ttitle:\t\t", $at->[5]);
}

foreach my $invalid ( @invalid_accs ) {
    my $at = $at_results->{$invalid};
    ok(not($at), "$invalid: no at_result");
}

# Singleton
my $acc = $valid_accs[1];
my $s_results = $ena->get_sample_accessions($acc);
is(ref($s_results), 'HASH', 's_results hash');
ok($s_results->{$acc}, 'result is for singleton acc');

# Empty
my $e_results = $ena->get_sample_accessions();
is(ref($e_results), 'HASH', 'e_results hash');
ok(not(%$e_results), 'result is empty');

done_testing;

1;

# Local Variables:
# mode: perl
# End:

# EOF
