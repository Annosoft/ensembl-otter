#!/usr/bin/env perl

use strict;
use warnings;

use lib "${ENV{ANACODE_TEAM_TOOLS}}/t/tlib";
use Test::CriticModule;
use Test::SetupLog4perl;

use Readonly;
use Scalar::Util qw(reftype);
use Test::More;

use Hum::Ace::SubSeq;

Readonly my %ele_expected => {
    'M' => { class => 'Match',      desc => 'match',                   q => 10, t => 10 },
    'C' => { class => 'Codon',      desc => 'codon',                   q => 10, t => 10 },
    'G' => { class => 'Gap',        desc => 'gap',                     q => 10, t =>  0 },
    'N' => { class => 'NER',        desc => 'non-equivalenced region', q => 10, t => 10 },
    '5' => { class => 'SS_5P',      desc => "5' splice site",          q =>  0, t =>  2 },
    '3' => { class => 'SS_3P',      desc => "3' splice site",          q =>  0, t =>  2 },
    'I' => { class => 'Intron',     desc => 'intron',                  q =>  0, t => 10 },
    'S' => { class => 'SplitCodon', desc => 'split codon',             q => 10, t => 10 },
    'F' => { class => 'Frameshift', desc => 'frameshift',              q =>  0, t =>  1 },
};

my ($ele_module, $ga_module);
BEGIN {
    $ga_module = 'Bio::Otter::GappedAlignment';
    use_ok($ga_module);
    $ele_module = 'Bio::Otter::GappedAlignment::Element';
    use_ok($ele_module);
}

critic_module_ok($ga_module);
critic_module_ok($ele_module);
critic_module_ok($ga_module . '::ElementI');
critic_module_ok($ga_module . '::ElementTypes');

foreach my $type (keys %ele_expected) {
    my $exp = $ele_expected{$type};
    my $ele = $ele_module->new($type, $exp->{q}, $exp->{t});
    my $class = $ele_module . '::' . $exp->{class};
    isa_ok($ele, $class);
    is($ele->type, $type, "type for $type");
    is($ele->long_type, $exp->{desc}, "long_type for $type");
    critic_module_ok($class);
}

Readonly my %tiny_ts_expected => (

    vulgar   => 'Q 0 20 + T 6 21 + 56 M 5 5 G 3 0 M 5 5 G 0 1 M 4 4 G 3 0',

    q_id     => 'Q',
    q_start  => 0,
    q_end    => 20,
    q_strand => '+',
    t_id     => 'T',
    t_start  => 6,
    t_end    => 21,
    t_strand => '+',
    score    => 56,
    n_ele    => 6,
    cigar_exonerate => 'M 5 I 3 M 5 D 1 M 4 I 3',
    cigar_ensembl   => '5M3D5MI4M3D',

    intron_vulgar  => 'M 3 3 I 0 3 M 2 2 G 3 0 M 4 4 I 0 4 M 1 1 G 0 1 M 1 1 I 0 2 M 3 3 G 3 0',
    intron_n_ele   => 12,

    i_cigar_ensembl      => '3M3I2M3D4M4IMIM2I3M3D',
    );

# Common expected components for test clone results
#
my %test_clone_exp = (         # not Readonly as some components manufactured from others

    invariants => {
        t_id         => 'EMBOSS_001',
        score        => 12625,
        n_ele        => 5,
        intron_n_ele => 17,
    },

    protein_invariants => {
        vulgar   => 'Q96S55 0 665 . EMBOSS_001 152 2071 + 3047 M 285 855 F 0 1 M 52 156 G 25 0 M 19 57 F 0 1 G 1 0 M 283 849',
        q_id     => 'Q96S55',
        q_start  => 0,
        q_end    => 665,
        q_strand => '.',

        t_id         => 'EMBOSS_001',
        t_start  => 152,
        t_end    => 2071,
        t_strand => '+',

        score        => 3047,
        n_ele        => 8,

        cigar_exonerate    => 'M 855 D 1 M 156 I 25 M 57 D 1 I 1 M 849',
        cigar_ensembl      => '855MI156M75D57MI3D849M', # mine - rest follow this convention
#       cigar_ensembl      => '855MI156M25D57MID849M',  # according to exonerate - counts on I's is from query side

        intron_vulgar  => 'M 274 822 I 0 2246 M 11 33 F 0 1 M 52 156 G 25 0 M 1 3 I 0 1312 M 18 54 F 0 1 G 1 0 M 36 108 S 0 2 I 0 8901 S 1 1 M 76 228 S 0 1 I 0 3913 S 1 2 M 51 153 S 0 1 I 0 762 S 1 2 M 26 78 I 0 603 M 91 273',
        intron_n_ele => 26,

        i_cigar_ensembl => '822M2246I33MI156M75D3M1312I54MI3D108M8903I229M3914I155M763I80M603I273M',

        ensembl_feature_type => 'Bio::EnsEMBL::DnaPepAlignFeature',
    },

    ts_vulgar_comps_fwd => 'M 1007 1007 G 0 1 M 214 214 G 2 0 M 1315 1315',
    ts_vulgar_comps_rev => 'M 1315 1315 G 2 0 M 214 214 G 0 1 M 1007 1007',

    ts_cigar_exonerate_fwd => 'M 1007 D 1 M 214 I 2 M 1315',
    ts_cigar_exonerate_rev => 'M 1315 I 2 M 214 D 1 M 1007',

    intronified_vulgar_comps_fwd  => 'M 974 974 I 0 2246 M 33 33 G 0 1 M 159 159 I 0 1312 M 55 55 G 2 0 M 110 110 I 0 8901 M 230 230 I 0 3913 M 156 156 I 0 762 M 80 80 I 0 603 M 739 739',

    intronified_vulgar_comps_rev  => 'M 739 739 I 0 603 M 80 80 I 0 762 M 156 156 I 0 3913 M 230 230 I 0 8901 M 110 110 G 2 0 M 55 55 I 0 1312 M 159 159 G 0 1 M 33 33 I 0 2246 M 974 974',

    exons_fwd_region => [
        [ 120389, 121362 ],     # 974 intron 2246
        [ 123609, 123801 ],     # 193        1312
        [ 125114, 125278 ],     # 165
        [ 134180, 134409 ],     # 230
        [ 138323, 138478 ],     # 156
        [ 139241, 139320 ],     #  80
        [ 139924, 140662 ],     # 739
    ],

    fwd_region_min   => 120389,
    fwd_region_v_min => 120389 - 1,
    fwd_region_max   => 140662,

    exons_rev_region => [
        [ 35001, 35739 ],
        [ 36343, 36422 ],
        [ 37185, 37340 ],
        [ 41254, 41483 ],
        [ 50385, 50549 ],
        [ 51862, 52054 ],
        [ 54301, 55274 ],
    ],
    rev_region_min   => 35001,
    rev_region_v_min => 35001 - 1,
    rev_region_max   => 55274,

    v_fwd_query_exons_fwd => [
        [    0,  974 ],
        [  974, 1166 ],
        [ 1166, 1333 ],
        [ 1333, 1563 ],
        [ 1563, 1719 ],
        [ 1719, 1799 ],
        [ 1799, 2538 ],
    ],

    v_rev_query_exons_fwd => [
        [   15,  754 ],
        [  754,  834 ],
        [  834,  990 ],
        [  990, 1220 ],
        [ 1220, 1387 ],
        [ 1387, 1579 ],
        [ 1579, 2553 ],
    ],

    exon_vulgars_fwd => [
        'M 974 974',
        'M 33 33 G 0 1 M 159 159',
        'M 55 55 G 2 0 M 110 110',
        'M 230 230',
        'M 156 156',
        'M 80 80',
        'M 739 739',
    ],

    exon_vulgars_rev => [
        'M 739 739',
        'M 80 80',
        'M 156 156',
        'M 230 230',
        'M 110 110 G 2 0 M 55 55',
        'M 159 159 G 0 1 M 33 33',
        'M 974 974',
    ],

    v_protein_query_exons => [
        [   0, 274 ],
        [ 274, 363 ],
        [ 363, 418 ],
        [ 418, 495 ],
        [ 495, 547 ],
        [ 547, 574 ],
        [ 574, 665 ],
    ],

    protein_exon_vulgars => [
        'M 274 822',
        'M 11 33 F 0 1 M 52 156 G 25 0 M 1 3',
        'M 18 54 F 0 1 G 1 0 M 36 108 S 0 2',
        'S 1 1 M 76 228 S 0 1',
        'S 1 2 M 51 153 S 0 1',
        'S 1 2 M 26 78',
        'M 91 273',
    ],
    );

$test_clone_exp{v_exons_fwd_region} = adjust_start_coords($test_clone_exp{exons_fwd_region}, -1);
$test_clone_exp{v_exons_rev_region} = adjust_start_coords($test_clone_exp{exons_rev_region}, -1);

$test_clone_exp{v_exons_fwd_region_revd} = reverse_exon_coords($test_clone_exp{v_exons_fwd_region});
$test_clone_exp{v_exons_rev_region_revd} = reverse_exon_coords($test_clone_exp{v_exons_rev_region});

$test_clone_exp{v_fwd_query_exons_rev} = reverse_exon_coords($test_clone_exp{v_fwd_query_exons_fwd});
$test_clone_exp{v_rev_query_exons_rev} = reverse_exon_coords($test_clone_exp{v_rev_query_exons_fwd});

Readonly my @split_expected => (
    {
        name     => 'Tiny fwd',
        %tiny_ts_expected,

        ts_strand => 1,
        exons     => [ [21, 24], [27, 31], [35, 40], [45, 47], [50,52] ],
        clone_contig_offset => 0,

        intron_t_start => 28,
        intron_t_end   => 52,
        intron_t_strand=> '+',

        splits => [
            'Q 0 3 + T 28 31 + 56 M 3 3',
            'Q 3 12 + T 34 40 + 56 M 2 2 G 3 0 M 4 4',
            'Q 12 14 + T 44 47 + 56 M 1 1 G 0 1 M 1 1',
            'Q 14 20 + T 49 52 + 56 M 3 3 G 3 0',
            ],

        ensembl_feature_type => 'Bio::EnsEMBL::DnaDnaAlignFeature',
        ensembl_features => [
            { start => 29, end => 31, strand => 1, hstart =>  1, hend =>  3, hstrand => 1, cigar => '3M', },
            { start => 35, end => 40, strand => 1, hstart =>  4, hend => 12, hstrand => 1, cigar => '2M3D4M', },
            { start => 45, end => 47, strand => 1, hstart => 13, hend => 14, hstrand => 1, cigar => 'MIM', },
            { start => 50, end => 52, strand => 1, hstart => 15, hend => 17, hstrand => 1, cigar => '3M', },
            ],
    },
    {
        name     => 'Tiny rev',
        %tiny_ts_expected,

        ts_strand => -1,
        exons     => [ [56, 58], [61, 63], [68, 73], [77, 81], [84, 87] ],
        clone_contig_offset => 0,

        intron_t_start => 79,
        intron_t_end   => 55,
        intron_t_strand=> '-',

        splits => [
            'Q 0 3 + T 79 76 - 56 M 3 3',
            'Q 3 12 + T 73 67 - 56 M 2 2 G 3 0 M 4 4',
            'Q 12 14 + T 63 60 - 56 M 1 1 G 0 1 M 1 1',
            'Q 14 20 + T 58 55 - 56 M 3 3 G 3 0',
            ],

        ensembl_feature_type => 'Bio::EnsEMBL::DnaDnaAlignFeature',
        ensembl_features => [
            { start => 77, end => 79, strand => -1, hstart =>  1, hend =>  3, hstrand => 1, cigar => '3M', },
            { start => 68, end => 73, strand => -1, hstart =>  4, hend => 12, hstrand => 1, cigar => '2M3D4M', },
            { start => 61, end => 63, strand => -1, hstart => 13, hend => 14, hstrand => 1, cigar => 'MIM', },
            { start => 56, end => 58, strand => -1, hstart => 15, hend => 17, hstrand => 1, cigar => '3M', },
            ],
    },
    {
        name     => 'RP11-420G6.2-002 vs BC018923.2',
        vulgar   => 'BC018923.2 0 2538 + ENST00000380771 57 2595 + 12663 M 2538 2538',

        q_id     => 'BC018923.2',
        q_start  => 0,
        q_end    => 2538,
        q_strand => '+',
        t_id     => 'ENST00000380771',
        t_start  => 57,
        t_end    => 2595,
        t_strand => '+',
        score    => 12663,
        n_ele    => 1,

        ts_strand => 1,
        exons     => [
            [ 69325, 70355 ],
            [ 72602, 72793 ],
            [ 74106, 74272 ],
            [ 83174, 83403 ],
            [ 87317, 87472 ],
            [ 88235, 88314 ],
            [ 88918, 89656 ],
            ],
        clone_contig_offset => 100,    # contig starts at bp 100 in clone; ts is rel contig

        intron_vulgar  => 'M 974 974 I 0 2246 M 192 192 I 0 1312 M 167 167 I 0 8901 M 230 230 I 0 3913 M 156 156 I 0 762 M 80 80 I 0 603 M 739 739',
        intron_t_start => 69481,
        intron_t_end   => 89756,
        intron_t_strand=> '+',
        intron_n_ele   => 13,

        splits => [
            'BC018923.2 0 974 + ENST00000380771 69481 70455 + 12663 M 974 974',
            'BC018923.2 974 1166 + ENST00000380771 72701 72893 + 12663 M 192 192',
            'BC018923.2 1166 1333 + ENST00000380771 74205 74372 + 12663 M 167 167',
            'BC018923.2 1333 1563 + ENST00000380771 83273 83503 + 12663 M 230 230',
            'BC018923.2 1563 1719 + ENST00000380771 87416 87572 + 12663 M 156 156',
            'BC018923.2 1719 1799 + ENST00000380771 88334 88414 + 12663 M 80 80',
            'BC018923.2 1799 2538 + ENST00000380771 89017 89756 + 12663 M 739 739'
            ],
    },
    {
        name     => 'RP11-420G6.1-003 vs BI831275.1',
        vulgar   => 'BI831275.1 0 746 + OTTHUMT00000039637 57 797 + 3471 M 12 12 G 0 1 M 2 2 G 0 1 M 476 476 G 1 0 M 64 64 G 1 0 M 26 26 G 1 0 M 53 53 G 1 0 M 38 38 G 1 0 M 4 4 G 1 0 M 25 25 G 1 0 M 23 23 G 1 0 M 15 15',

        q_id     => 'BI831275.1',
        q_start  => 0,
        q_end    => 746,
        q_strand => '+',
        t_id     => 'OTTHUMT00000039637',
        t_start  => 57,
        t_end    => 797,
        t_strand => '+',
        score    => 3471,
        n_ele    => 21,

        ts_strand => -1,
        exons     => [
            [ 136243, 137923 ], # OTTHUME00000175054 1681bp
            [ 139767, 139934 ], # OTTHUME00000175059  168bp
            [ 140019, 140161 ], # OTTHUME00000175058  143bp
            [ 141793, 141910 ], # OTTHUME00000175064  118bp
            [ 142460, 142597 ], # OTTHUME00000175057  138bp
            [ 144330, 144505 ], # OTTHUME00000175063  176bp
            [ 145723, 145917 ], # OTTHUME00000175061  195bp -57 = 138
            ],
        clone_contig_offset => 100,    # contig starts at bp 100 in clone; ts is rel contig

        intron_vulgar  => 'M 12 12 G 0 1 M 2 2 G 0 1 M 122 122 I 0 1217 M 176 176 I 0 1732 M 138 138 I 0 549 M 40 40 G 1 0 M 64 64 G 1 0 M 14 14 I 0 1631 M 12 12 G 1 0 M 53 53 G 1 0 M 38 38 G 1 0 M 4 4 G 1 0 M 25 25 G 1 0 M 11 11 I 0 84 M 12 12 G 1 0 M 15 15',

        intron_t_start => 145960,
        intron_t_end   => 140007,
        intron_t_strand=> '-',
        intron_n_ele   => 31,

        splits => [
            'BI831275.1 0 136 + OTTHUMT00000039637 145960 145822 - 3471 M 12 12 G 0 1 M 2 2 G 0 1 M 122 122',
            'BI831275.1 136 312 + OTTHUMT00000039637 144605 144429 - 3471 M 176 176',
            'BI831275.1 312 450 + OTTHUMT00000039637 142697 142559 - 3471 M 138 138',
            'BI831275.1 450 570 + OTTHUMT00000039637 142010 141892 - 3471 M 40 40 G 1 0 M 64 64 G 1 0 M 14 14',
            'BI831275.1 570 718 + OTTHUMT00000039637 140261 140118 - 3471 M 12 12 G 1 0 M 53 53 G 1 0 M 38 38 G 1 0 M 4 4 G 1 0 M 25 25 G 1 0 M 11 11',
            'BI831275.1 718 746 + OTTHUMT00000039637 140034 140007 - 3471 M 12 12 G 1 0 M 15 15',
            ],
    },

    # vvv Test clone cases start here vvv

    {
        name     => 'Test fwd region vs BC018923.fwd (+)',
        vulgar   => 'BC018923.fwd 0 2538 + EMBOSS_001 0 2537 + 12625 ' . $test_clone_exp{ts_vulgar_comps_fwd},

        %{$test_clone_exp{invariants}},

        cigar_exonerate => $test_clone_exp{ts_cigar_exonerate_fwd},

        q_id     => 'BC018923.fwd',
        q_start  => 0,
        q_end    => 2538,
        q_strand => '+',

        t_start  => 0,
        t_end    => 2537,
        t_strand => '+',

        ts_strand => 1,
        exons     => $test_clone_exp{exons_fwd_region},

        intron_vulgar  => $test_clone_exp{intronified_vulgar_comps_fwd},
        intron_t_start => $test_clone_exp{fwd_region_v_min},
        intron_t_end   => $test_clone_exp{fwd_region_max},
        intron_t_strand=> '+',

        split_components => [
            'BC018923.fwd', $test_clone_exp{v_fwd_query_exons_fwd}, '+', # query
            'EMBOSS_001',   $test_clone_exp{v_exons_fwd_region},    '+', # target
            12625,          $test_clone_exp{exon_vulgars_fwd},           # score, vulgar string
        ],

        # BS: BC018923.fwd 0 974 + EMBOSS_001 120388 121362 + 12625 M 974 974
        # BS: BC018923.fwd 974 1166 + EMBOSS_001 123608 123801 + 12625 M 33 33 G 0 1 M 159 159
        # BS: BC018923.fwd 1166 1333 + EMBOSS_001 125113 125278 + 12625 M 55 55 G 2 0 M 110 110
        # BS: BC018923.fwd 1333 1563 + EMBOSS_001 134179 134409 + 12625 M 230 230
        # BS: BC018923.fwd 1563 1719 + EMBOSS_001 138322 138478 + 12625 M 156 156
        # BS: BC018923.fwd 1719 1799 + EMBOSS_001 139240 139320 + 12625 M 80 80
        # BS: BC018923.fwd 1799 2538 + EMBOSS_001 139923 140662 + 12625 M 739 739
    },
    {
        name     => 'Test rev region vs BC018923.rev (+)',
        vulgar   => 'BC018923.rev 15 2553 + EMBOSS_001 2537 0 - 12625 ' . $test_clone_exp{ts_vulgar_comps_rev},

        %{$test_clone_exp{invariants}},

        cigar_exonerate => $test_clone_exp{ts_cigar_exonerate_rev},

        q_id     => 'BC018923.rev',
        q_start  => 15,
        q_end    => 2553,
        q_strand => '+',

        t_start  => 2537,
        t_end    => 0,
        t_strand => '-',

        ts_strand => -1,
        exons     => $test_clone_exp{exons_rev_region},

        intron_vulgar  => $test_clone_exp{intronified_vulgar_comps_rev},
        intron_t_start => $test_clone_exp{rev_region_v_min},
        intron_t_end   => $test_clone_exp{rev_region_max},
        intron_t_strand=> '+',

        split_components => [
            'BC018923.rev', $test_clone_exp{v_rev_query_exons_fwd}, '+', # query
            'EMBOSS_001',   $test_clone_exp{v_exons_rev_region},    '+', # target
            12625,          $test_clone_exp{exon_vulgars_rev},           # score, vulgar string
            ],

        # BS: BC018923.rev 15 754 + EMBOSS_001 35000 35739 + 12625 M 739 739
        # BS: BC018923.rev 754 834 + EMBOSS_001 36342 36422 + 12625 M 80 80
        # BS: BC018923.rev 834 990 + EMBOSS_001 37184 37340 + 12625 M 156 156
        # BS: BC018923.rev 990 1220 + EMBOSS_001 41253 41483 + 12625 M 230 230
        # BS: BC018923.rev 1220 1387 + EMBOSS_001 50384 50549 + 12625 M 110 110 G 2 0 M 55 55
        # BS: BC018923.rev 1387 1579 + EMBOSS_001 51861 52054 + 12625 M 159 159 G 0 1 M 33 33
        # BS: BC018923.rev 1579 2553 + EMBOSS_001 54300 55274 + 12625 M 974 974
    },
    {
        name     => 'Test fwd region vs BC018923.rev (+)',
        vulgar   => 'BC018923.rev 15 2553 + EMBOSS_001 2537 0 - 12625 ' . $test_clone_exp{ts_vulgar_comps_rev},

        %{$test_clone_exp{invariants}},

        cigar_exonerate => $test_clone_exp{ts_cigar_exonerate_rev},

        q_id     => 'BC018923.rev',
        q_start  => 15,
        q_end    => 2553,
        q_strand => '+',

        t_start  => 2537,
        t_end    => 0,
        t_strand => '-',

        ts_strand => 1,
        exons     => $test_clone_exp{exons_fwd_region},

        intron_vulgar  => $test_clone_exp{intronified_vulgar_comps_rev},
        intron_t_start => $test_clone_exp{fwd_region_max},
        intron_t_end   => $test_clone_exp{fwd_region_v_min},
        intron_t_strand=> '-',

        split_components => [
            'BC018923.rev', $test_clone_exp{v_rev_query_exons_fwd},   '+', # query
            'EMBOSS_001',   $test_clone_exp{v_exons_fwd_region_revd}, '-', # target
            12625,          $test_clone_exp{exon_vulgars_rev},             # score, vulgar string
            ],

        # BS: BC018923.rev 15 754 + EMBOSS_001 140662 139923 - 12625 M 739 739
        # BS: BC018923.rev 754 834 + EMBOSS_001 139320 139240 - 12625 M 80 80
        # BS: BC018923.rev 834 990 + EMBOSS_001 138478 138322 - 12625 M 156 156
        # BS: BC018923.rev 990 1220 + EMBOSS_001 134409 134179 - 12625 M 230 230
        # BS: BC018923.rev 1220 1387 + EMBOSS_001 125278 125113 - 12625 M 110 110 G 2 0 M 55 55
        # BS: BC018923.rev 1387 1579 + EMBOSS_001 123801 123608 - 12625 M 159 159 G 0 1 M 33 33
        # BS: BC018923.rev 1579 2553 + EMBOSS_001 121362 120388 - 12625 M 974 974
    },
    {
        name     => 'Test rev region vs BC018923.fwd (+)',
        vulgar   => 'BC018923.fwd 0 2538 + EMBOSS_001 0 2537 + 12625 ' . $test_clone_exp{ts_vulgar_comps_fwd},

        %{$test_clone_exp{invariants}},

        cigar_exonerate => $test_clone_exp{ts_cigar_exonerate_fwd},

        q_id     => 'BC018923.fwd',
        q_start  => 0,
        q_end    => 2538,
        q_strand => '+',

        t_start  => 0,
        t_end    => 2537,
        t_strand => '+',

        ts_strand => -1,
        exons     => $test_clone_exp{exons_rev_region},

        intron_vulgar  => $test_clone_exp{intronified_vulgar_comps_fwd},
        intron_t_start => $test_clone_exp{rev_region_max},
        intron_t_end   => $test_clone_exp{rev_region_v_min},
        intron_t_strand=> '-',

        split_components => [
            'BC018923.fwd', $test_clone_exp{v_fwd_query_exons_fwd},   '+', # query
            'EMBOSS_001',   $test_clone_exp{v_exons_rev_region_revd}, '-', # target
            12625,          $test_clone_exp{exon_vulgars_fwd},             # score, vulgar string
            ],

        # BS: BC018923.fwd 0 974 + EMBOSS_001 55274 54300 - 12625 M 974 974
        # BS: BC018923.fwd 974 1166 + EMBOSS_001 52054 51861 - 12625 M 33 33 G 0 1 M 159 159
        # BS: BC018923.fwd 1166 1333 + EMBOSS_001 50549 50384 - 12625 M 55 55 G 2 0 M 110 110
        # BS: BC018923.fwd 1333 1563 + EMBOSS_001 41483 41253 - 12625 M 230 230
        # BS: BC018923.fwd 1563 1719 + EMBOSS_001 37340 37184 - 12625 M 156 156
        # BS: BC018923.fwd 1719 1799 + EMBOSS_001 36422 36342 - 12625 M 80 80
        # BS: BC018923.fwd 1799 2538 + EMBOSS_001 35739 35000 - 12625 M 739 739
    },
    {
        name     => 'Test fwd region vs BC018923.fwd (-)',
        vulgar   => 'BC018923.fwd 2538 0 - EMBOSS_001 2537 0 - 12625 ' . $test_clone_exp{ts_vulgar_comps_rev},

        %{$test_clone_exp{invariants}},

        cigar_exonerate => $test_clone_exp{ts_cigar_exonerate_rev},

        q_id     => 'BC018923.fwd',
        q_start  => 2538,
        q_end    => 0,
        q_strand => '-',

        t_start  => 2537,
        t_end    => 0,
        t_strand => '-',

        ts_strand => 1,
        exons     => $test_clone_exp{exons_fwd_region},

        intron_vulgar  => $test_clone_exp{intronified_vulgar_comps_rev},
        intron_t_start => $test_clone_exp{fwd_region_max},
        intron_t_end   => $test_clone_exp{fwd_region_v_min},
        intron_t_strand=> '-',

        # We expect these to be the same as Test fwd region vs BC018923.rev (+) on target side,
        # but query side exons will be for BC018923.fwd

        split_components => [
            'BC018923.fwd', $test_clone_exp{v_fwd_query_exons_rev},   '-', # query
            'EMBOSS_001',   $test_clone_exp{v_exons_fwd_region_revd}, '-', # target
            12625,          $test_clone_exp{exon_vulgars_rev},             # score, vulgar string
            ],

        # BS: BC018923.fwd 2538 1799 - EMBOSS_001 140662 139923 - 12625 M 739 739
        # BS: BC018923.fwd 1799 1719 - EMBOSS_001 139320 139240 - 12625 M 80 80
        # BS: BC018923.fwd 1719 1563 - EMBOSS_001 138478 138322 - 12625 M 156 156
        # BS: BC018923.fwd 1563 1333 - EMBOSS_001 134409 134179 - 12625 M 230 230
        # BS: BC018923.fwd 1333 1166 - EMBOSS_001 125278 125113 - 12625 M 110 110 G 2 0 M 55 55
        # BS: BC018923.fwd 1166 974 - EMBOSS_001 123801 123608 - 12625 M 159 159 G 0 1 M 33 33
        # BS: BC018923.fwd 974 0 - EMBOSS_001 121362 120388 - 12625 M 974 974
    },
    {
        name     => 'Test rev region vs BC018923.rev (-)',
        vulgar   => 'BC018923.rev 2553 15 - EMBOSS_001 0 2537 + 12625 ' . $test_clone_exp{ts_vulgar_comps_fwd},

        %{$test_clone_exp{invariants}},

        cigar_exonerate => $test_clone_exp{ts_cigar_exonerate_fwd},

        q_id     => 'BC018923.rev',
        q_start  => 2553,
        q_end    => 15,
        q_strand => '-',

        t_start  => 0,
        t_end    => 2537,
        t_strand => '+',

        ts_strand => -1,
        exons     => $test_clone_exp{exons_rev_region},

        intron_vulgar  => $test_clone_exp{intronified_vulgar_comps_fwd},
        intron_t_start => $test_clone_exp{rev_region_max},
        intron_t_end   => $test_clone_exp{rev_region_v_min},
        intron_t_strand=> '-',

        # We expect these to be the same as Test rev region vs BC018923.fwd (+) on target side,
        # but query side exons will be for BC018923.rev

        split_components => [
            'BC018923.rev', $test_clone_exp{v_rev_query_exons_rev},   '-', # query
            'EMBOSS_001',   $test_clone_exp{v_exons_rev_region_revd}, '-', # target
            12625,          $test_clone_exp{exon_vulgars_fwd},             # score, vulgar string
            ],

        # BS: BC018923.rev 2553 1579 - EMBOSS_001 55274 54300 - 12625 M 974 974
        # BS: BC018923.rev 1579 1387 - EMBOSS_001 52054 51861 - 12625 M 33 33 G 0 1 M 159 159
        # BS: BC018923.rev 1387 1220 - EMBOSS_001 50549 50384 - 12625 M 55 55 G 2 0 M 110 110
        # BS: BC018923.rev 1220 990 - EMBOSS_001 41483 41253 - 12625 M 230 230
        # BS: BC018923.rev 990 834 - EMBOSS_001 37340 37184 - 12625 M 156 156
        # BS: BC018923.rev 834 754 - EMBOSS_001 36422 36342 - 12625 M 80 80
        # BS: BC018923.rev 754 15 - EMBOSS_001 35739 35000 - 12625 M 739 739
    },
    {
        name     => 'Test fwd region vs BC018923.rev (-)',
        vulgar   => 'BC018923.rev 2553 15 - EMBOSS_001 0 2537 + 12625 ' . $test_clone_exp{ts_vulgar_comps_fwd},

        %{$test_clone_exp{invariants}},

        cigar_exonerate => $test_clone_exp{ts_cigar_exonerate_fwd},

        q_id     => 'BC018923.rev',
        q_start  => 2553,
        q_end    => 15,
        q_strand => '-',

        t_start  => 0,
        t_end    => 2537,
        t_strand => '+',

        ts_strand => 1,
        exons     => $test_clone_exp{exons_fwd_region},

        intron_vulgar  => $test_clone_exp{intronified_vulgar_comps_fwd},
        intron_t_start => $test_clone_exp{fwd_region_v_min},
        intron_t_end   => $test_clone_exp{fwd_region_max},
        intron_t_strand=> '+',

        split_components => [
            'BC018923.rev', $test_clone_exp{v_rev_query_exons_rev},   '-', # query
            'EMBOSS_001',   $test_clone_exp{v_exons_fwd_region},      '+', # target
            12625,          $test_clone_exp{exon_vulgars_fwd},             # score, vulgar string
            ],

        # BS: BC018923.rev 2553 1579 - EMBOSS_001 120388 121362 + 12625 M 974 974
        # BS: BC018923.rev 1579 1387 - EMBOSS_001 123608 123801 + 12625 M 33 33 G 0 1 M 159 159
        # BS: BC018923.rev 1387 1220 - EMBOSS_001 125113 125278 + 12625 M 55 55 G 2 0 M 110 110
        # BS: BC018923.rev 1220 990 - EMBOSS_001 134179 134409 + 12625 M 230 230
        # BS: BC018923.rev 990 834 - EMBOSS_001 138322 138478 + 12625 M 156 156
        # BS: BC018923.rev 834 754 - EMBOSS_001 139240 139320 + 12625 M 80 80
        # BS: BC018923.rev 754 15 - EMBOSS_001 139923 140662 + 12625 M 739 739
    },
   {
        name     => 'Test rev region vs BC018923.fwd (-)',
        vulgar   => 'BC018923.fwd 2538 0 - EMBOSS_001 2537 0 - 12625 ' . $test_clone_exp{ts_vulgar_comps_rev},

        %{$test_clone_exp{invariants}},

        cigar_exonerate => $test_clone_exp{ts_cigar_exonerate_rev},

        q_id     => 'BC018923.fwd',
        q_start  => 2538,
        q_end    => 0,
        q_strand => '-',

        t_start  => 2537,
        t_end    => 0,
        t_strand => '-',

        ts_strand => -1,
        exons     => $test_clone_exp{exons_rev_region},

        intron_vulgar  => $test_clone_exp{intronified_vulgar_comps_rev},
        intron_t_start => $test_clone_exp{rev_region_v_min},
        intron_t_end   => $test_clone_exp{rev_region_max},
        intron_t_strand=> '+',

        split_components => [
            'BC018923.fwd', $test_clone_exp{v_fwd_query_exons_rev},   '-', # query
            'EMBOSS_001',   $test_clone_exp{v_exons_rev_region},      '+', # target
            12625,          $test_clone_exp{exon_vulgars_rev},             # score, vulgar string
            ],

        # BS: BC018923.fwd 2538 1799 - EMBOSS_001 35000 35739 + 12625 M 739 739
        # BS: BC018923.fwd 1799 1719 - EMBOSS_001 36342 36422 + 12625 M 80 80
        # BS: BC018923.fwd 1719 1563 - EMBOSS_001 37184 37340 + 12625 M 156 156
        # BS: BC018923.fwd 1563 1333 - EMBOSS_001 41253 41483 + 12625 M 230 230
        # BS: BC018923.fwd 1333 1166 - EMBOSS_001 50384 50549 + 12625 M 110 110 G 2 0 M 55 55
        # BS: BC018923.fwd 1166 974 - EMBOSS_001 51861 52054 + 12625 M 159 159 G 0 1 M 33 33
        # BS: BC018923.fwd 974 0 - EMBOSS_001 54300 55274 + 12625 M 974 974
    },

    # ^^^ end of test clone cases ^^^

    {
        name     => 'RP1-90J20.6-002 vs BG212959.1 (failed 2012-06-26 due to overlap => 0)',
        vulgar   => 'BG212959.1 928 0 - RP1-90J20.6-002 2281 3252 + 3570 M 9 9 G 0 1 M 3 3 G 0 3 M 6 6 G 0 4 M 11 11 G 0 2 M 6 6 G 0 3 M 4 4 G 0 1 M 1 1 G 0 1 M 4 4 G 0 1 M 1 1 G 0 1 M 2 2 G 0 1 M 10 10 G 0 1 M 3 3 G 0 1 M 5 5 G 0 1 M 2 2 G 0 1 M 4 4 G 0 1 M 3 3 G 0 1 M 6 6 G 0 2 M 6 6 G 0 1 M 6 6 G 0 1 M 10 10 G 0 1 M 5 5 G 0 1 M 3 3 G 0 1 M 10 10 G 0 2 M 20 20 G 0 1 M 3 3 G 0 1 M 9 9 G 0 1 M 6 6 G 0 1 M 10 10 G 0 1 M 7 7 G 1 0 M 4 4 G 0 1 M 57 57 G 0 1 M 20 20 G 0 1 M 17 17 G 0 1 M 9 9 G 0 1 M 7 7 G 0 1 M 8 8 G 1 0 M 15 15 G 0 1 M 614 614',

        # transcript length is 3265

        q_id     => 'BG212959.1',
        q_start  => 928,
        q_end    => 0,
        q_strand => '-',
        t_id     => 'RP1-90J20.6-002',
        t_start  => 2281,
        t_end    => 3252,
        t_strand => '+',
        score    => 3570,
        n_ele    => 75,

        ts_strand => -1,
        exons     => [
            [ 84023, 84563 ], # OTTHUME00000190873 len  541  ^   2725 3265
            [ 84778, 84933 ], # OTTHUME00000190862 len  156  :   2569 2724
            [ 88908, 89050 ], # OTTHUME00000190863 len  143  :   2426 2568
            [ 90456, 90573 ], # OTTHUME00000190861 len  118  :   2308 2425
            [ 91388, 91534 ], # OTTHUME00000190871 len  147  :   2161 2307
            [ 95032, 97191 ], # OTTHUME00000190870 len 2160 cuml    1 2160
            ],
        clone_contig_offset => 100,    # contig starts at bp 100 in clone; ts is rel contig

        intron_vulgar  => 'M 9 9 G 0 1 M 3 3 G 0 3 M 6 6 G 0 4 I 0 814 M 11 11 G 0 2 M 6 6 G 0 3 M 4 4 G 0 1 M 1 1 G 0 1 M 4 4 G 0 1 M 1 1 G 0 1 M 2 2 G 0 1 M 10 10 G 0 1 M 3 3 G 0 1 M 5 5 G 0 1 M 2 2 G 0 1 M 4 4 G 0 1 M 3 3 G 0 1 M 6 6 G 0 2 M 6 6 G 0 1 M 6 6 G 0 1 M 10 10 G 0 1 M 5 5 G 0 1 M 3 3 G 0 1 M 3 3 I 0 1405 M 7 7 G 0 2 M 20 20 G 0 1 M 3 3 G 0 1 M 9 9 G 0 1 M 6 6 G 0 1 M 10 10 G 0 1 M 7 7 G 1 0 M 4 4 G 0 1 M 57 57 G 0 1 M 11 11 I 0 3974 M 9 9 G 0 1 M 17 17 G 0 1 M 9 9 G 0 1 M 7 7 G 0 1 M 8 8 G 1 0 M 15 15 G 0 1 M 86 86 I 0 214 M 528 528',

        intron_t_start => 91513,
        intron_t_end   => 84135,
        intron_t_strand=> '-',
        intron_n_ele   => 75 + 4 + 1 + 1 + 1,

        splits => [
            'BG212959.1 928 910 - RP1-90J20.6-002 91513 91487 - 3570 M 9 9 G 0 1 M 3 3 G 0 3 M 6 6 G 0 4',
            'BG212959.1 910 815 - RP1-90J20.6-002 90673 90555 - 3570 M 11 11 G 0 2 M 6 6 G 0 3 M 4 4 G 0 1 M 1 1 G 0 1 M 4 4 G 0 1 M 1 1 G 0 1 M 2 2 G 0 1 M 10 10 G 0 1 M 3 3 G 0 1 M 5 5 G 0 1 M 2 2 G 0 1 M 4 4 G 0 1 M 3 3 G 0 1 M 6 6 G 0 2 M 6 6 G 0 1 M 6 6 G 0 1 M 10 10 G 0 1 M 5 5 G 0 1 M 3 3 G 0 1 M 3 3',
            'BG212959.1 815 680 - RP1-90J20.6-002 89150 89007 - 3570 M 7 7 G 0 2 M 20 20 G 0 1 M 3 3 G 0 1 M 9 9 G 0 1 M 6 6 G 0 1 M 10 10 G 0 1 M 7 7 G 1 0 M 4 4 G 0 1 M 57 57 G 0 1 M 11 11',
            'BG212959.1 680 528 - RP1-90J20.6-002 85033 84877 - 3570 M 9 9 G 0 1 M 17 17 G 0 1 M 9 9 G 0 1 M 7 7 G 0 1 M 8 8 G 1 0 M 15 15 G 0 1 M 86 86',
            'BG212959.1 528 0 - RP1-90J20.6-002 84663 84135 - 3570 M 528 528',
            ],
    },

    # Protein to DNA alignment
    {
        name     => 'Test fwd region vs Q96S55',

        %{$test_clone_exp{protein_invariants}},

        ts_strand => 1,
        exons     => $test_clone_exp{exons_fwd_region},

        intron_t_start => 120540,
        intron_t_end   => 140196,
        intron_t_strand=> '+',

        split_components => [
            'Q96S55',     $test_clone_exp{v_protein_query_exons}, '.', # query
            'EMBOSS_001', [
                              [ 120540, 121362 ],
                              [ 123608, 123801 ],
                              [ 125113, 125278 ],
                              [ 134179, 134409 ],
                              [ 138322, 138478 ],
                              [ 139240, 139320 ],
                              [ 139923, 140196 ],
                          ],                                      '+', # target
            3047, $test_clone_exp{protein_exon_vulgars},               # score, vulgar string
        ],

        # BS: Q96S55 0 274 . EMBOSS_001 120540 121362 + 3047 M 274 822
        # BS: Q96S55 274 363 . EMBOSS_001 123608 123801 + 3047 M 11 33 F 0 1 M 52 156 G 25 0 M 1 3
        # BS: Q96S55 363 418 . EMBOSS_001 125113 125278 + 3047 M 18 54 F 0 1 G 1 0 M 36 108 S 0 2
        # BS: Q96S55 418 495 . EMBOSS_001 134179 134409 + 3047 S 1 1 M 76 228 S 0 1
        # BS: Q96S55 495 547 . EMBOSS_001 138322 138478 + 3047 S 1 2 M 51 153 S 0 1
        # BS: Q96S55 547 574 . EMBOSS_001 139240 139320 + 3047 S 1 2 M 26 78
        # BS: Q96S55 574 665 . EMBOSS_001 139923 140196 + 3047 M 91 273

        ensembl_features => [
            { start => 120541, end => 121362, strand => 1, hstart =>   1, hend => 274, cigar => '822M', },
            { start => 123609, end => 123641, strand => 1, hstart => 275, hend => 285, cigar => '33M', },
            { start => 123643, end => 123801, strand => 1, hstart => 286, hend => 363, cigar => '156M75D3M', },
            { start => 125114, end => 125167, strand => 1, hstart => 364, hend => 381, cigar => '54M', },
            { start => 125169, end => 125276, strand => 1, hstart => 383, hend => 418, cigar => '108M', },
            { start => 134181, end => 134408, strand => 1, hstart => 420, hend => 495, cigar => '228M', },
            { start => 138325, end => 138477, strand => 1, hstart => 497, hend => 547, cigar => '153M', },
            { start => 139243, end => 139320, strand => 1, hstart => 549, hend => 574, cigar => '78M', },
            { start => 139924, end => 140196, strand => 1, hstart => 575, hend => 665, cigar => '273M', },
        ],
    },

    {
        name     => 'Test rev region vs Q96S55',

        %{$test_clone_exp{protein_invariants}},

        ts_strand => -1,
        exons     => $test_clone_exp{exons_rev_region},

        intron_t_start => 55122,
        intron_t_end   => 35466,
        intron_t_strand=> '-',

        split_components => [
            'Q96S55',     $test_clone_exp{v_protein_query_exons}, '.', # query
            'EMBOSS_001', [
                              [ 55122, 54300 ],
                              [ 52054, 51861 ],
                              [ 50549, 50384 ],
                              [ 41483, 41253 ],
                              [ 37340, 37184 ],
                              [ 36422, 36342 ],
                              [ 35739, 35466 ],
                          ],                                      '-', # target
            3047, $test_clone_exp{protein_exon_vulgars},               # score, vulgar string
        ],

        # BS: Q96S55 0 274 . EMBOSS_001 55122 54300 - 3047 M 274 822
        # BS: Q96S55 274 363 . EMBOSS_001 52054 51861 - 3047 M 11 33 F 0 1 M 52 156 G 25 0 M 1 3
        # BS: Q96S55 363 418 . EMBOSS_001 50549 50384 - 3047 M 18 54 F 0 1 G 1 0 M 36 108 S 0 2
        # BS: Q96S55 418 495 . EMBOSS_001 41483 41253 - 3047 S 1 1 M 76 228 S 0 1
        # BS: Q96S55 495 547 . EMBOSS_001 37340 37184 - 3047 S 1 2 M 51 153 S 0 1
        # BS: Q96S55 547 574 . EMBOSS_001 36422 36342 - 3047 S 1 2 M 26 78
        # BS: Q96S55 574 665 . EMBOSS_001 35739 35466 - 3047 M 91 273

        ensembl_feature_type => 'Bio::EnsEMBL::DnaPepAlignFeature',
        ensembl_features => [
            { start => 54301, end => 55122, strand => -1, hstart =>   1, hend => 274, cigar => '822M', },
            { start => 52022, end => 52054, strand => -1, hstart => 275, hend => 285, cigar => '33M', },
            { start => 51862, end => 52020, strand => -1, hstart => 286, hend => 363, cigar => '156M75D3M', },
            { start => 50496, end => 50549, strand => -1, hstart => 364, hend => 381, cigar => '54M', },
            { start => 50387, end => 50494, strand => -1, hstart => 383, hend => 418, cigar => '108M', },
            { start => 41255, end => 41482, strand => -1, hstart => 420, hend => 495, cigar => '228M', },
            { start => 37186, end => 37338, strand => -1, hstart => 497, hend => 547, cigar => '153M', },
            { start => 36343, end => 36420, strand => -1, hstart => 549, hend => 574, cigar => '78M', },
            { start => 35467, end => 35739, strand => -1, hstart => 575, hend => 665, cigar => '273M', },
        ],
    },

    {
        name =>   'RP11-420G6.5-001 vs. Q8CG07 (failing 2013-04-02 ref RT319413)',
        vulgar => 'Q8CG07 257 400 . chr6-18 0 429 + 713 M 143 429',

        q_id     => 'Q8CG07',
        q_start  => 257,
        q_end    => 400,
        q_strand => '.',
        t_id     => 'chr6-18',
        t_start  => 0,
        t_end    => 429,
        t_strand => '+',
        score    => 713,
        n_ele    => 1,

        ts_strand => 1,
        exons     => [
            [  70320,  70355 ], # len  36 cuml    1  36
            [  72602,  72793 ], # len 192  :     37 228
            [  74031,  74229 ], # len 199  :    229 427
            [  87419,  87472 ], # len  54  :    428 481
            [ 159081, 159130 ], # len  49  :    482 530
            ],

        intron_vulgar => 'M 12 36 I 0 2246 M 64 192 I 0 1237 M 66 198 S 0 1 I 0 13189 S 1 2',

        intron_t_start  => 70319,
        intron_t_end    => 87420,
        intron_t_strand => '+',
        intron_n_ele    => 8,

        splits => [
            'Q8CG07 257 269 . chr6-18 70319 70355 + 713 M 12 36',
            'Q8CG07 269 333 . chr6-18 72601 72793 + 713 M 64 192',
            'Q8CG07 333 399 . chr6-18 74030 74229 + 713 M 66 198 S 0 1',
            'Q8CG07 399 400 . chr6-18 87418 87420 + 713 S 1 2',
        ],

    },
    );

# Coverage matrix: . = tiny, * = real or test
#
#          | q / t strands
# ---------+-----+-----+-----+-----
# ts_strand| +/+ | +/- | -/+ | -/-
# ---------+-----+-----+-----+-----
#        + | .** | *   | *   | *
# ---------+-----+-----+-----+-----
#        - | .** | *   | **  | *
# ---------+-----+-----+-----+-----


foreach my $test (@split_expected) {
    note("Split tests for '", $test->{name}, "'");

    my $ga = $ga_module->from_vulgar($test->{vulgar});
    isa_ok($ga, 'Bio::Otter::GappedAlignment');

    is($ga->query_id,      $test->{q_id},     'query_id');
    is($ga->query_start,   $test->{q_start},  'query_start');
    is($ga->query_end,     $test->{q_end},    'query_end');
    is($ga->query_strand,  $test->{q_strand}, 'query_strand');
    is($ga->target_id,     $test->{t_id},     'target_id');
    is($ga->target_start,  $test->{t_start},  'target_start');
    is($ga->target_end,    $test->{t_end},    'target_end');
    is($ga->target_strand, $test->{t_strand}, 'target_strand');
    is($ga->score,         $test->{score},    'score');
    is($ga->n_elements,    $test->{n_ele},    'n_elements');
    is($ga->vulgar_string, $test->{vulgar},   'vulgar_string');

    is(scalar($ga->exon_gapped_alignments), 1, 'exon_gapped_alignments for ungapped');

    is($ga->exonerate_cigar_string, $test->{cigar_exonerate}, 'cigar_exonerate') if $test->{cigar_exonerate};
    is($ga->ensembl_cigar_string,   $test->{cigar_ensembl},   'cigar_ensembl')   if $test->{cigar_ensembl};

    my $ts = Hum::Ace::SubSeq->new();
    $ts->strand($test->{ts_strand});
    my $offset = $test->{clone_contig_offset} || 0;
    foreach my $exon (@{$test->{exons}}) {
        my $e = Hum::Ace::Exon->new();
        $e->start($exon->[0] + $offset);
        $e->end(  $exon->[1] + $offset);
        $ts->add_Exon($e);
    }

    my $intron_ga = $ga->intronify_by_transcript_exons($ts);
    isa_ok($intron_ga, 'Bio::Otter::GappedAlignment');
    note("Intronified vulgar: ", $intron_ga->vulgar_string);
    is ($intron_ga->vulgar_comps_string, $test->{intron_vulgar}, 'intronify');
    is($intron_ga->query_id,      $test->{q_id},     'query_id');
    is($intron_ga->query_start,   $test->{q_start},  'query_start');
    is($intron_ga->query_end,     $test->{q_end},    'query_end');
    is($intron_ga->query_strand,  $test->{q_strand}, 'query_strand');
    is($intron_ga->target_id,     $test->{t_id},     'target_id');
    is($intron_ga->target_start,  $test->{intron_t_start}, 'target_start');
    is($intron_ga->target_end,    $test->{intron_t_end},   'target_end');
    is($intron_ga->target_strand, $test->{intron_t_strand},'target_strand');
    is($intron_ga->score,         $test->{score},          'score');
    is($intron_ga->n_elements,    $test->{intron_n_ele},   'n_elements');

    is($intron_ga->ensembl_cigar_string, $test->{i_cigar_ensembl}, 'i_ensembl_cigar') if $test->{i_cigar_ensembl};

    my @split = $intron_ga->exon_gapped_alignments;
    my $n_splits = scalar(@split);

    my @e_splits;
    if ($test->{split_components}) {
        @e_splits = build_splits($test->{split_components});
    } else {
        @e_splits = @{$test->{splits}};
    }
    is($n_splits, scalar(@e_splits), 'n_splits');

    unless ($test->{skip_split_tests}) {
        foreach my $n ( 0 .. ($n_splits - 1) ) {
            isa_ok($split[$n], 'Bio::Otter::GappedAlignment');
            is ($split[$n]->vulgar_string, $e_splits[$n], "split $n");
        }
    }

    if ($test->{ensembl_features}) {
        my @ensembl_features = $intron_ga->ensembl_features;

        my $n_features = scalar(@ensembl_features);
        my @exp_features = @{$test->{ensembl_features}};

        is ($n_features, scalar(@exp_features), 'n ensembl_features');

        foreach my $n ( 0 .. ($n_features - 1) ) {
            isa_ok($ensembl_features[$n], $test->{ensembl_feature_type}, "feature $n: isa");
            is ($ensembl_features[$n]->start,        $exp_features[$n]->{start},  "feature $n: start");
            is ($ensembl_features[$n]->end,          $exp_features[$n]->{end},    "feature $n: end");
            is ($ensembl_features[$n]->strand,       $exp_features[$n]->{strand}, "feature $n: strand");
            is ($ensembl_features[$n]->hstart,       $exp_features[$n]->{hstart}, "feature $n: hstart");
            is ($ensembl_features[$n]->hend,         $exp_features[$n]->{hend},   "feature $n: hend");
            is ($ensembl_features[$n]->hstrand,      $exp_features[$n]->{hstrand},"feature $n: hstrand")
                if $exp_features[$n]->{hstrand};
            is ($ensembl_features[$n]->cigar_string, $exp_features[$n]->{cigar},  "feature $n: cigar_string");
        }
    }
}

done_testing;

sub adjust_start_coords {
    my ($coords, $offset) = @_;
    return [ map { [ $_->[0] + $offset, $_->[1] ] } @$coords ];
}

# Components are either scalars which are identical for each split,
# or arrayrefs where one item should be taken in order for each split.
#
sub build_splits {
    my $components = shift;

    # Get number of splits and check for consistency
    my $n;
    foreach (@$components) {
        if (reftype($_) and reftype($_) eq 'ARRAY') {
            my $this_n = scalar(@$_);
            if ($n) {
                die "Split component sizes do not match, prev $n, this $this_n." unless $n == $this_n;
            } else {
                $n = scalar(@$_);
            }
        }
    };

    my @splits;
    foreach my $i ( 0..($n-1) ) {
        push @splits, join ' ', map {
            (reftype($_) and reftype($_) eq 'ARRAY') ? flatten(' ', $_->[$i]) : $_;
        } @$components;
        note('BS: ', $splits[$i]);
    }

    return @splits;
}

sub flatten {
    # Some per-split components are start/end arrays themselves, and need to be flattened
    my ($glue, $item) = @_;
    my $result = (reftype($item) and reftype($item) eq 'ARRAY') ? join($glue, @$item) : $item;
    return $result;
}

sub reverse_exon_coords {
    my $coords = shift;
    return [ reverse map { [ reverse @$_ ] } @$coords ];
}

1;

# Local Variables:
# mode: perl
# End:

# EOF
