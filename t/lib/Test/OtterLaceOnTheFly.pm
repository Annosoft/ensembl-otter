# Common test code for Bio::Otter::Lace::OnTheFly* tests.

package Test::OtterLaceOnTheFly;

use strict;
use warnings;

use Cwd qw(abs_path);
use Exporter qw(import);
use File::Basename;
use Test::More;

use Bio::Otter::Lace::OnTheFly::Builder::Genomic;
use Bio::Otter::Lace::OnTheFly::Runner;
use Bio::Otter::Lace::OnTheFly::TargetSeq;
use Bio::Otter::Utils::FeatureSort qw( feature_sort );
use Hum::FastaFileIO;

our @EXPORT_OK = qw( fixed_genomic_tests fixed_transcript_tests build_target run_otf_genomic_test run_otf_test );

# .../t/lib/Test/
# need to go up two levels to get into .../t/
my $path = abs_path(dirname(__FILE__) . "/../../etc/align");

my @genomic_tests = (
    {
        name        => 'test_clone vs. test_query',
        target_path => "${path}/test_clone.fa",
        query_path  => "${path}/test_query.fa",
        query_ids   => [qw(BC018923.fwd BC018923.rev)],
    },
    {
        name        => 'test_clone vs. test_query with mark',
        target_path => "${path}/test_clone.fa",
        query_path  => "${path}/test_query.fa",
        query_ids   => [qw(BC018923.fwd BC018923.rev)],
        start       => 35000,
        end         => 141000,
    },
    {
        name        => 'AL139092 vs. BC018923',
        target_path => "${path}/AL139092.12.fasta",
        query_path  => "${path}/BC018923.fasta",
        query_ids   => [qw(ENA|BC018923|BC018923.2)],
    },
    {
        name        => 'AL139092 vs. BI831275',
        target_path => "${path}/AL139092.12.fasta",
        query_path  => "${path}/BI831275.fasta",
        query_ids   => [qw(ENA|BI831275|BI831275.1)],
    },
    {
        name        => 'AL133351 vs. BG212959.1',
        target_path => "${path}/AL133351.34.fasta",
        query_path  => "${path}/BG212959.1.fa",
        query_ids   => [qw(BG212959.1)],
    },
    {
        name        => 'AL139092 vs. protein Q96S55',
        target_path => "${path}/AL139092.12.fasta",
        query_path  => "${path}/Q96S55.fasta",
        query_ids   => [qw(sp|Q96S55|WRIP1_HUMAN)],
        type        => 'Test_Protein',
    },
    {
        name        => 'test_clone vs. protein Q96S55',
        target_path => "${path}/test_clone.fa",
        query_path  => "${path}/Q96S55.fasta",
        query_ids   => [qw(sp|Q96S55|WRIP1_HUMAN)],
        type        => 'Test_Protein',
    },
    {
        name        => 'AL133351 vs. protein Q8VHQ0.1',
        target_path => "${path}/AL133351.34.fasta",
        query_path  => "${path}/Q8VHQ0.fasta",
        query_ids   => [qw(Q8VHQ0.1)],
        type        => 'Test_Protein',
    },
    {
        name        => 'CR753817.13 vs. AW134265.1 (trim leading/trailing indels)',
        target_path => "${path}/CR753817.13.fasta",
        query_path  => "${path}/AW134265.1.fasta",
        query_ids   => [qw(AW134265.1)],
    },
    );

sub fixed_genomic_tests {
    return @genomic_tests;
}

my @transcript_tests = (
    {
        name        => 'test_ts vs. test_query, fwd exons',
        target_path => "${path}/test_ts.fa",
        query_path  => "${path}/BC018923.fwd.fa",
        query_ids   => [qw(BC018923.fwd)],
        ts_spec     => "${path}/exons.fwd.txt",
        ts_strand   => 1,
        vulgar      => {
            'BC018923.fwd' => 'BC018923.fwd 0 2538 + EMBOSS_001 120388 140662 + 12574 M 974 974 5 0 2 I 0 2242 3 0 2 M 33 33 G 0 1 M 159 159 5 0 2 I 0 1308 3 0 2 M 55 55 G 2 0 M 110 110 5 0 2 I 0 8897 3 0 2 M 230 230 5 0 2 I 0 3909 3 0 2 M 156 156 5 0 2 I 0 758 3 0 2 M 80 80 5 0 2 I 0 599 3 0 2 M 739 739',
        },
    },
    {
        name        => 'test_ts vs. test_query, rev exons',
        target_path => "${path}/test_ts.fa",
        query_path  => "${path}/BC018923.fwd.fa",
        query_ids   => [qw(BC018923.fwd)],
        ts_spec     => "${path}/exons.rev.txt",
        ts_strand   => -1,
        vulgar      => {
            'BC018923.fwd' => 'BC018923.fwd 0 2538 + EMBOSS_001 55274 35000 - 12574 M 974 974 5 0 2 I 0 2242 3 0 2 M 33 33 G 0 1 M 159 159 5 0 2 I 0 1308 3 0 2 M 55 55 G 2 0 M 110 110 5 0 2 I 0 8897 3 0 2 M 230 230 5 0 2 I 0 3909 3 0 2 M 156 156 5 0 2 I 0 758 3 0 2 M 80 80 5 0 2 I 0 599 3 0 2 M 739 739',
        },
    },
    {
        name        => 'test_ts vs. protein Q96S55, fwd exons',
        target_path => "${path}/test_ts_b.fa",
        query_path  => "${path}/Q96S55.fasta",
        query_ids   => [qw(sp|Q96S55|WRIP1_HUMAN)],
        ts_spec     => "${path}/exons_b.fwd.txt",
        ts_strand   => 1,
        vulgar      => {
            'sp|Q96S55|WRIP1_HUMAN' => 'sp|Q96S55|WRIP1_HUMAN 0 665 . EMBOSS_001 120540 140196 + 3329 M 274 822 5 0 2 I 0 2242 3 0 2 M 11 33 F 0 1 M 53 159 5 0 2 I 0 1233 3 0 2 M 43 129 F 0 1 G 1 0 M 36 108 S 0 2 5 0 2 I 0 8897 3 0 2 S 1 1 M 76 228 S 0 1 5 0 2 I 0 3909 3 0 2 S 1 2 M 51 153 S 0 1 5 0 2 I 0 758 3 0 2 S 1 2 M 26 78 5 0 2 I 0 599 3 0 2 M 91 273',
        },
        type        => 'Test_Protein',
    },
    {
        name        => 'test_ts vs. protein Q96S55, rev exons',
        target_path => "${path}/test_ts_b.fa",
        query_path  => "${path}/Q96S55.fasta",
        query_ids   => [qw(sp|Q96S55|WRIP1_HUMAN)],
        ts_spec     => "${path}/exons_b.rev.txt",
        ts_strand   => -1,
        vulgar      => {
            'sp|Q96S55|WRIP1_HUMAN' => 'sp|Q96S55|WRIP1_HUMAN 0 665 . EMBOSS_001 55122 35466 - 3329 M 274 822 5 0 2 I 0 2242 3 0 2 M 11 33 F 0 1 M 53 159 5 0 2 I 0 1233 3 0 2 M 43 129 F 0 1 G 1 0 M 36 108 S 0 2 5 0 2 I 0 8897 3 0 2 S 1 1 M 76 228 S 0 1 5 0 2 I 0 3909 3 0 2 S 1 2 M 51 153 S 0 1 5 0 2 I 0 758 3 0 2 S 1 2 M 26 78 5 0 2 I 0 599 3 0 2 M 91 273',
        },
        type        => 'Test_Protein',
    },
    );

sub fixed_transcript_tests {
    return @transcript_tests;
}

sub build_target {
    my $test = shift;

    $test->{target_seq} ||= Hum::FastaFileIO->new_DNA_IO($test->{target_path})->read_one_sequence;

    my @target_seq_args = ( full_seq => $test->{target_seq} );
    push @target_seq_args, start => $test->{start} if $test->{start};
    push @target_seq_args, end   => $test->{end}   if $test->{end};

    my $target = new_ok('Bio::Otter::Lace::OnTheFly::TargetSeq' => \@target_seq_args);
    return $target;
}

sub run_otf_genomic_test {
    my ($test, $target) = @_;
    $test->{builder_class} = 'Bio::Otter::Lace::OnTheFly::Builder::Genomic';
    return run_otf_test($test, $target);
}

sub run_otf_test {
    my ($test, $target, $extra_builder_args) = @_;

    note 'Test: ', $test->{name};

    $test->{runner_class} ||= 'Bio::Otter::Lace::OnTheFly::Runner';

    if ($test->{query_path}) {
        $test->{query_seqs} = [ Hum::FastaFileIO->new_DNA_IO($test->{query_path})->read_all_sequences ];
    }

    $extra_builder_args ||= {};
    my $builder = new_ok( $test->{builder_class} => [{
        type       => $test->{type},
        query_seqs => $test->{query_seqs},
        target     => $target,
        %$extra_builder_args,
                                                                             }]);
    my $request = $builder->prepare_run;
    isa_ok($request, 'Bio::Otter::Lace::DB::OTFRequest');

    my $runner = new_ok( $test->{runner_class} => [
                             request         => $request,
                             resultset_class => 'Bio::Otter::Lace::OnTheFly::ResultSet::Test',
                             %{ $test->{runner_args} || {} },
                                                                  ]);
    my $result_set = $runner->run;
    isa_ok($result_set, 'Bio::Otter::Lace::OnTheFly::ResultSet');

    my @qids = sort $result_set->hit_query_ids;
    if ($test->{strict_hit_list}) {
        is(scalar(@qids), scalar(@{$test->{query_ids}}), 'n(query_ids)');
        is_deeply(\@qids, $test->{query_ids}, 'query_ids');
    }

    my @gapped_alignments =  map { @{$result_set->hit_by_query_id($_)} } @qids;
    my @new_features;
    foreach my $ga ( @gapped_alignments ) {
        push @new_features, $ga->ensembl_features;
        note $ga->query_id, ': QS ', $ga->query_strand, ', TS ', $ga->target_strand, ', GO ', $ga->gene_orientation;
    }
    @new_features = feature_sort @new_features;
    note("n(new_features): ", scalar(@new_features));

    unlink $request->query_file;
    unlink $request->target_file;

    return $result_set, @new_features;
}

1;
