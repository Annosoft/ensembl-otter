package Test::Bio::Vega::Transcript;

use Test::Class::Most
    parent     => 'OtterTest::Class';

use Test::Bio::Vega::Author no_run_test => 1;

use OtterTest::TestRegion qw( transcript_info_lookup );

sub build_attributes {
    my $test = shift;
    return {
        stable_id      => 'OTTTEST000456',
        description    => 'Test transcript',
        start          => 3_456_123,
        end            => 3_567_321,
        strand         => -1,
        analysis       => sub { return bless {}, 'Bio::EnsEMBL::Analysis' },
        transcript_author => sub { return Test::Bio::Vega::Author->new->test_object },
        # source         => 'ensembl-test',
    };
}

sub source : Test(3) {
    my $test = shift;
    my $ts = $test->our_object;
    can_ok $ts, 'source';
    is $ts->source, 'ensembl', '... and default is correct';
    $ts->source('test');
    is $ts->source, 'test',   '... and setting its value succeeds';
    return;
}

sub evidence_list : Test(4) {
    my $test = shift;
    my $ts = $test->our_object;
    can_ok $ts, 'evidence_list';
    my $initial_el = $ts->evidence_list;
    isa_ok $initial_el, 'ARRAY', '... and return value';
    is scalar(@$initial_el), 0, '... and it starts empty';
    my @evi = ( bless {}, 'Bio::Vega::Evidence' ) x 3;
    $ts->evidence_list( [ @evi ] );
    cmp_deeply $ts->evidence_list, \@evi, '... and setting it succeeds';
    return;
}

sub matches_parsed_xml {
    my ($test, $parsed_xml, $description) = @_;
    my $ts = $test->our_object;
    my $ts_info = transcript_info_lookup($parsed_xml->{stable_id});
    note "stable_id '$parsed_xml->{stable_id}'";
    $test->attributes_are($ts,
                          {
                              stable_id   => $parsed_xml->{stable_id},
                              biotype     => $ts_info->{biotype},
                              status      => $ts_info->{status},
                          },
                          "$description (attributes)");

    # FIXME - dup with Gene
    subtest "$description (name)" => sub {
        my $na = $ts->get_all_Attributes('name');
        ok $na && scalar(@$na),                  'has name attribute';
        is $na->[0]->value, $parsed_xml->{name}, 'name matches';
    };

    # FIXME - dup with Gene
    my $t_author = Test::Bio::Vega::Author->new(our_object => $ts->transcript_author);
    $t_author->matches_parsed_xml($parsed_xml, "$description (author)");

    my $exons     = $ts->get_all_Exons;
    my $xml_exons = $parsed_xml->{exon_set}->{exon};

    my $n_exons = scalar @$exons;
    is $n_exons,  scalar @$xml_exons, 'n(Exons)';
    # FIXME - Test them!

    my $evidence = $ts->evidence_list;
    my $xml_evi  = $parsed_xml->{evidence_set}->{evidence};

    my $n_evi = scalar @$evidence;
    is $n_evi,  scalar @$xml_evi, 'n(Evidence)';
    # FIXME - Test them!

    my $translation = $ts->translation;
    if (my $translation_sid = $parsed_xml->{translation_stable_id}) {
        isa_ok $translation, 'Bio::Vega::Translation', '... translation';
        is $translation->stable_id, $translation_sid, '    ... stable_id';
        my @expected = @{$parsed_xml}{qw( translation_start translation_end )};
        @expected = reverse @expected if $ts->strand < 0;
        is $test->_add_offset($translation->genomic_start), $expected[0], '    ... start';
        is $test->_add_offset($translation->genomic_end),   $expected[1], '    ... end';
        is $translation->transcript, $ts, '    ... transcript';
    } else {
        is $translation, undef, 'no translation';
    }
    return;
}

sub _add_offset {
    my ($test, $coord) = @_;
    my $start = $test->our_object->slice->start;
    return $start + $coord - 1;
}

1;
