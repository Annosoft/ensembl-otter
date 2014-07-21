# Parameters for a test region on human_test

package OtterTest::TestRegion;

use strict;
use warnings;

use Test::Builder;

use Bio::Otter::Server::Support::Local;
use Bio::Vega::Gene;
use Bio::Vega::Transform::Otter;

use Exporter qw( import );
our @EXPORT_OK = qw( check_xml extra_gene  add_extra_gene_xml region_is %test_region_params );

our %test_region_params = (   ## no critic (Variables::ProhibitPackageVars)
    dataset => 'human_test',
    name    => '6',
    type    => 'chr6-18',
    cs      => 'chromosome',
    csver   => 'Otter',
    start   => 2_558_000,
    end     => 2_648_000,
    );

sub local_server {
    my $local_server = Bio::Otter::Server::Support::Local->new;
    $local_server->set_params(%test_region_params);
    return $local_server;
}

sub check_xml {
    my ($xml, $desc) = @_;
    chomp $xml;
    my $tb = Test::Builder->new;
    $tb->is_eq($xml, local_xml_copy(), $desc);
    return;
}

sub region_is {
    my $tb = Test::Builder->new;
    $tb->diag("region_is(): NOT YET IMPLEMENTED");
    return;
}

# May have been easier to just user our parser to parse XML, *sigh*
#
sub extra_gene {
    my ($slice) = @_;
    my $bvt_otter = Bio::Vega::Transform::Otter->new; # just for utility methods

    my $analysis = $bvt_otter->get_Analysis('Otter');
    my $author   = $bvt_otter->make_Author('anacode', 'anacode');

    my $gene = Bio::Vega::Gene->new(
        -slice =>       $slice,
        -description => 'TEST COPY of chromosome 6 open reading frame 195 (via B:V:Region)',
        -analysis    => $analysis,
        );
    $gene->source('havana');
    $gene->biotype('protein_coding');
    $gene->status('KNOWN');
    $gene->gene_author($author);

    my @gene_attributes;
    push @gene_attributes, $bvt_otter->make_Attribute('name',    'ANACODE-TEST-GENE-2');
    push @gene_attributes, $bvt_otter->make_Attribute('synonym', 'TEST-GENE-2-SYN-1');
    push @gene_attributes, $bvt_otter->make_Attribute('synonym', 'TEST-GENE-2-SYN-2');
    $gene->add_Attributes(@gene_attributes);

    my $transcript = Bio::Vega::Transcript->new(
        -slice    => $slice,
        -analysis => $analysis,
        );
    $transcript->biotype('protein_coding');
    $transcript->status('KNOWN');
    $transcript->source('havana');
    $transcript->transcript_author($author);

    my @transcript_attributes;
    push @transcript_attributes, $bvt_otter->make_Attribute('name',   'ANACODE-TEST-TRANSCRIPT-2');
    push @transcript_attributes, $bvt_otter->make_Attribute('remark', 'TEST COPY 2 of novel protein (FLJ31934)');
    $transcript->add_Attributes(@transcript_attributes);

    my @exon_specs = (
        { start => 2_622_652, end => 2_622_690, strand => -1 },
        { start => 2_621_692, end => 2_621_879, strand => -1 },
        { start => 2_610_000, end => 2_612_206, strand => -1 },
        );
    my $tran_start_pos = 2_611_909 - $test_region_params{start} + 1;
    my $tran_end_pos   = 2_611_526 - $test_region_params{start} + 1;

    my @exons;
    my ($start_Exon,$start_Exon_Pos,$end_Exon,$end_Exon_Pos); # FIXME: dup with B:V:Transform::Otter
    foreach my $e_spec (@exon_specs) {
        my $exon = Bio::Vega::Exon->new(
            -start     => ($e_spec->{'start'} - $test_region_params{start} + 1),
            -end       => ($e_spec->{'end'}   - $test_region_params{start} + 1),
            -strand    => $e_spec->{'strand'},
            -slice     => $slice,
            -phase     => -1,
            -end_phase => -1,
            );
        $transcript->add_Exon($exon);
        push @exons, $exon;
        unless (defined $start_Exon_Pos) {
            $start_Exon_Pos = $bvt_otter->translation_pos($tran_start_pos, $exon);
            $start_Exon = $exon if defined $start_Exon_Pos;
        }
        unless (defined $end_Exon_Pos) {
            $end_Exon_Pos = $bvt_otter->translation_pos($tran_end_pos,$exon);
            $end_Exon = $exon if defined $end_Exon_Pos;
        }
    }

    my $translation = Bio::Vega::Translation->new();
    $translation->start_Exon($start_Exon);
    $translation->start($start_Exon_Pos);
    $translation->end_Exon($end_Exon);
    $translation->end($end_Exon_Pos);
    $transcript->translation($translation);

    my @evidence_list;
    push @evidence_list, Bio::Vega::Evidence->new( -name => 'Em:AK056496', -type => 'Genomic' );
    push @evidence_list, Bio::Vega::Evidence->new( -name => 'Sw:Q96MT4',   -type => 'Protein' );
    $transcript->evidence_list(\@evidence_list);

    $gene->add_Transcript($transcript);
    return $gene;
}

{
    my $extra_gene = <<'__EO_GENE_XML__';
     <locus>
       <description>TEST COPY of chromosome 6 open reading frame 195</description>
       <name>ANACODE-TEST-GENE</name>
       <type>Known_CDS</type>
       <known>1</known>
       <truncated>0</truncated>
       <synonym>TEST-GENE-SYN-1</synonym>
       <synonym>TEST-GENE-SYN-2</synonym>
       <author>anacode</author>
       <author_email>anacode</author_email>
       <transcript>
         <author>anacode</author>
         <author_email>anacode</author_email>
         <remark>TEST COPY of novel protein (FLJ31934)</remark>
         <transcript_class>Known_CDS</transcript_class>
         <name>ANACODE-TEST-TRANSCRIPT-001</name>
         <translation_start>2591909</translation_start>
         <translation_end>2591526</translation_end>
         <evidence_set>
           <evidence>
             <name>Em:AK056496</name>
             <type>Genomic</type>
           </evidence>
           <evidence>
             <name>Sw:Q96MT4</name>
             <type>Protein</type>
           </evidence>
         </evidence_set>
         <exon_set>
           <exon>
             <start>2602652</start>
             <end>2602690</end>
             <strand>-1</strand>
             <phase>-1</phase>
             <end_phase>-1</end_phase>
           </exon>
           <exon>
             <start>2601692</start>
             <end>2601879</end>
             <strand>-1</strand>
             <phase>-1</phase>
             <end_phase>-1</end_phase>
           </exon>
           <exon>
             <start>2590000</start>
             <end>2592206</end>
             <strand>-1</strand>
             <phase>-1</phase>
             <end_phase>-1</end_phase>
           </exon>
         </exon_set>
       </transcript>
     </locus>
__EO_GENE_XML__

    sub add_extra_gene_xml {
        my $xml = shift;
        $xml =~ s|(     </locus>\n)(   </sequence_set>)|$1$extra_gene$2|m;
        return $xml;
    }
}

# YUK - this ain't great! Maybe we should query the production server via HTTP.
#
sub local_xml_copy {
    my $xml = <<'__EO_XML__';
 <otter>
   <species>human_test</species>
   <sequence_set>
     <assembly_type>chr6-18</assembly_type>
     <sequence_fragment>
       <id>AL359852.20.1.120512</id>
       <chromosome>6</chromosome>
       <accession>AL359852</accession>
       <version>20</version>
       <clone_name>RP11-299J5</clone_name>
       <assembly_start>2558000</assembly_start>
       <assembly_end>2588535</assembly_end>
       <fragment_ori>1</fragment_ori>
       <fragment_offset>89977</fragment_offset>
       <clone_length>120512</clone_length>
       <remark>Annotation_remark- annotated</remark>
     </sequence_fragment>
     <sequence_fragment>
       <id>AL138876.23.1.107888</id>
       <chromosome>6</chromosome>
       <accession>AL138876</accession>
       <version>23</version>
       <clone_name>RP11-145H9</clone_name>
       <assembly_start>2588536</assembly_start>
       <assembly_end>2648000</assembly_end>
       <fragment_ori>1</fragment_ori>
       <fragment_offset>101</fragment_offset>
       <clone_length>107888</clone_length>
       <remark>EMBL_dump_info.DE_line- Contains part of a gene for a novel protein similar to myosin light chain kinase and two novel genes.</remark>
       <remark>Annotation_remark- annotated</remark>
       <keyword>myosin</keyword>
       <keyword>kinase</keyword>
     </sequence_fragment>
     <locus>
       <stable_id>OTTHUMG00000175882</stable_id>
       <description>TEC</description>
       <name>RP11-299J5.1</name>
       <type>TEC</type>
       <known>0</known>
       <truncated>0</truncated>
       <author>cas</author>
       <author_email>cas</author_email>
       <transcript>
         <stable_id>OTTHUMT00000431233</stable_id>
         <author>cas</author>
         <author_email>cas</author_email>
         <transcript_class>TEC</transcript_class>
         <name>RP11-299J5.1-001</name>
         <evidence_set>
           <evidence>
             <name>Em:AK057938.1</name>
             <type>cDNA</type>
           </evidence>
         </evidence_set>
         <exon_set>
           <exon>
             <stable_id>OTTHUME00002169081</stable_id>
             <start>2562181</start>
             <end>2564377</end>
             <strand>1</strand>
             <phase>-1</phase>
             <end_phase>-1</end_phase>
           </exon>
         </exon_set>
       </transcript>
     </locus>
     <locus>
       <stable_id>OTTHUMG00000014122</stable_id>
       <description>chromosome 6 open reading frame 195</description>
       <name>C6orf195</name>
       <type>Known_CDS</type>
       <known>1</known>
       <truncated>0</truncated>
       <synonym>bA145H9.2</synonym>
       <synonym>RP11-145H9.2</synonym>
       <author>gs6</author>
       <author_email>gs6</author_email>
       <transcript>
         <stable_id>OTTHUMT00000039633</stable_id>
         <author>gs6</author>
         <author_email>gs6</author_email>
         <remark>novel protein (FLJ31934)</remark>
         <transcript_class>Known_CDS</transcript_class>
         <name>RP11-145H9.2-001</name>
         <translation_start>2624056</translation_start>
         <translation_end>2623673</translation_end>
         <translation_stable_id>OTTHUMP00000015942</translation_stable_id>
         <evidence_set>
           <evidence>
             <name>Em:AK056496</name>
             <type>Genomic</type>
           </evidence>
           <evidence>
             <name>Sw:Q96MT4</name>
             <type>Protein</type>
           </evidence>
         </evidence_set>
         <exon_set>
           <exon>
             <stable_id>OTTHUME00000175047</stable_id>
             <start>2634799</start>
             <end>2634837</end>
             <strand>-1</strand>
             <phase>-1</phase>
             <end_phase>-1</end_phase>
           </exon>
           <exon>
             <stable_id>OTTHUME00000175046</stable_id>
             <start>2633839</start>
             <end>2634026</end>
             <strand>-1</strand>
             <phase>-1</phase>
             <end_phase>-1</end_phase>
           </exon>
           <exon>
             <stable_id>OTTHUME00000175048</stable_id>
             <start>2622147</start>
             <end>2624353</end>
             <strand>-1</strand>
             <phase>-1</phase>
             <end_phase>-1</end_phase>
           </exon>
         </exon_set>
       </transcript>
     </locus>
     <locus>
       <stable_id>OTTHUMG00000014123</stable_id>
       <description>novel transcript</description>
       <name>RP11-145H9.3</name>
       <type>Transcript</type>
       <known>0</known>
       <truncated>0</truncated>
       <synonym>bA145H9.3</synonym>
       <author>gs6</author>
       <author_email>gs6</author_email>
       <transcript>
         <stable_id>OTTHUMT00000039634</stable_id>
         <author>gs6</author>
         <author_email>gs6</author_email>
         <remark>novel transcript</remark>
         <transcript_class>lincRNA</transcript_class>
         <name>RP11-145H9.3-001</name>
         <evidence_set>
           <evidence>
             <name>Em:BM553903</name>
             <type>EST</type>
           </evidence>
         </evidence_set>
         <exon_set>
           <exon>
             <stable_id>OTTHUME00000175050</stable_id>
             <start>2637170</start>
             <end>2637689</end>
             <strand>1</strand>
             <phase>-1</phase>
             <end_phase>-1</end_phase>
           </exon>
           <exon>
             <stable_id>OTTHUME00000175049</stable_id>
             <start>2639922</start>
             <end>2640235</end>
             <strand>1</strand>
             <phase>-1</phase>
             <end_phase>-1</end_phase>
           </exon>
         </exon_set>
       </transcript>
     </locus>
   </sequence_set>
 </otter>
__EO_XML__
    chomp $xml;
    return $xml;
}

1;
