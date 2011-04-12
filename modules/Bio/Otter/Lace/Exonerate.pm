
=pod

=head1 NAME - Bio::Otter::Lace::Exonerate

=head1 DESCRIPTION

    Similar to a Pipeline RunnableDB, but for Otter on the fly Exonerate

=cut

package Bio::Otter::Lace::Exonerate;

use strict;
use warnings;
use Carp;
use File::Basename;
use File::Path 'rmtree';

# pipeline configuration
# this must come before Bio::EnsEMBL::Analysis::Runnable::Finished::Exonerate
use Bio::Otter::Lace::Exonerate::BlastableVersion;
use Bio::Otter::Lace::Exonerate::Config::General;
use Bio::Otter::Lace::Exonerate::Config::Blast;

use Bio::Seq;
use Hum::Ace::AceText;
use Hum::Ace::Method;
use Hum::FastaFileIO;
use Bio::EnsEMBL::Analysis::Runnable::Finished::Exonerate;

sub new{
    my( $pkg ) = @_;
    return bless {}, $pkg;
}

sub initialise {
    my ($self,$fasta_file) = @_;

    unless ($fasta_file =~ m{^/}) {
        confess "fasta file '$fasta_file' is not an absolute path";
    }

    $self->database($fasta_file);
    unless (-e $fasta_file) {
        confess "Fasta file '$fasta_file' defined in config does not exist";
    }
    warn "Found exonerate database: '$fasta_file'\n";

    #$self->homol_tag(($self->query_type eq 'protein') ? 'Pep_homol' : 'DNA_homol');
    $self->homol_tag('DNA_homol');

    # Make the analysis object needed by the Runnable
    my $ana_obj = Bio::EnsEMBL::Analysis->new(
        -LOGIC_NAME    => $self->logic_name,
        -INPUT_ID_TYPE => 'CONTIG',
        -PARAMETERS    => '',
        -PROGRAM     => 'exonerate',
        -GFF_SOURCE  => 'exonerate',
        -GFF_FEATURE => 'similarity',
        -DB_FILE     => $fasta_file,
    );
    $self->analysis($ana_obj);

    return;
}

sub write_seq_file {
    my ($self) = @_;
    my $query_file   = "/tmp/query_seq.$$.fa";
    # Write out the query sequence
    my $seq = $self->query_seq();
    if(@$seq) {
        my $query_out = Hum::FastaFileIO->new("> $query_file");
        $query_out->write_sequences(@$seq);
        $query_out = undef;

        return $query_file;
    }

    return;
}

# Attribute methods


sub AceDatabase {
    my( $self, $AceDatabase ) = @_;

    if ($AceDatabase) {
        $self->{'_AceDatabase'} = $AceDatabase;
    }
    return $self->{'_AceDatabase'};
}

sub analysis {
    my( $self, $analysis ) = @_;

    if ($analysis) {
        $self->{'_analysis'} = $analysis;
    }
    return $self->{'_analysis'};
}

sub genomic_seq {
    my( $self, $genomic_seq ) = @_;

    if ($genomic_seq) {
        $self->{'_genomic_seq'} = $genomic_seq;
    }
    return $self->{'_genomic_seq'};
}

sub genomic_start {
    my ( $self, $genomic_start ) = @_;
    if ( defined $genomic_start ) {
        $self->{'_genomic_start'} = $genomic_start;
    }
    return $self->{'_genomic_start'};
}

sub genomic_end {
    my ( $self, $genomic_end ) = @_;
    if ( defined $genomic_end ) {
        $self->{'_genomic_end'} = $genomic_end;
    }
    return $self->{'_genomic_end'};
}

sub query_seq {
    my( $self, $seq ) = @_;

    if ($seq) {
        $self->{'_query_seq'} = $seq;
    }
    return $self->{'_query_seq'};
}

sub query_type {
    my( $self, $query_type ) = @_;

    if ($query_type) {
        my $type = lc($query_type);
        $type =~ s/\s//g;
        unless( $type eq 'dna' || $type eq 'protein' ){
            confess "not the right query type: $type";
        }
        $self->{'_query_type'} = $type;
    }

    return $self->{'_query_type'} || 'dna';
}

sub acedb_homol_tag {
    my( $self, $tag ) = @_;

    if ($tag) {
        $self->{'_acedb_homol_tag'} = $tag;
    }

    return $self->{'_acedb_homol_tag'};
}

sub database {
    my( $self, $database ) = @_;

    if ($database) {
        $self->{'_database'} = $database;
    }
    return $self->{'_database'};
}

sub score {
    my ( $self, $score ) = @_;
    if ($score) {
        $self->{'_score'} = $score;
    }
    return $self->{'_score'};
}

sub bestn {
    my ( $self, $bestn) = @_;
    if ($bestn) {
        $self->{'_bestn'} = $bestn;
    }
    return $self->{'_bestn'};
}

sub max_intron_length {
    my ( $self, $max_intron_length) = @_;
    if ($max_intron_length) {
        $self->{'_max_intron_length'} = $max_intron_length;
    }
    return $self->{'_max_intron_length'};
}

sub dnahsp {
    my ( $self, $dnahsp ) = @_;
    if ($dnahsp) {
        $self->{'_dnahsp'} = $dnahsp;
    }
    return $self->{'_dnahsp'};
}


sub db_basename {
    my ($self) = @_;

    return basename($self->database);
}

sub db_dirname{
    my ($self) = @_;

    return dirname($self->database);
}

sub homol_tag {
    my( $self, $homol_tag ) = @_;

    if ($homol_tag) {
        $self->{'_homol_tag'} = $homol_tag;
    }
    return $self->{'_homol_tag'} || 'DNA_homol';
}

sub method_tag {
    my( $self, $method_tag ) = @_;

    if ($method_tag) {
        $self->{'_method_tag'} = $method_tag;
    }
    if (my $tag = $self->{'_method_tag'}) {
        return $tag;
    } elsif ($self->db_basename =~ /(.{1,40})$/) {
        return $1;
    } else {
        return;
    }
}

sub method_color {
    my( $self, $method_color ) = @_;

    if ($method_color) {
        $self->{'_method_color'} = $method_color;
    }
    return $self->{'_method_color'} || 'GREEN';
}

sub logic_name {
    my( $self, $logic_name ) = @_;

    if ($logic_name) {
        $self->{'_logic_name'} = $logic_name;
    }
    return $self->{'_logic_name'} || $self->db_basename;
}


sub sequence_fetcher {
    my( $self, $sequence_fetcher ) = @_;

    if ($sequence_fetcher) {
        $self->{'_sequence_fetcher'} = $sequence_fetcher;
    }
    return $self->{'_sequence_fetcher'};
}

sub ace_Method {
    my ($self) = @_;

    my $method = $self->{'_ace_method'} = Hum::Ace::Method->new;
    $method->name(  $self->method_tag   );

    return $method;
}


sub run {
    my( $self ) = @_;

    my $ace = '';
    my $name = $self->genomic_seq->name;
    my ($masked, $smasked, $unmasked) = $self->get_masked_unmasked_seq;

    # only run exonerate with the specified subsequence of the genomic sequence
    my $start = $self->genomic_start;
    my $end = $self->genomic_end;
    $_->seq($_->subseq($start, $end)) foreach $masked, $smasked, $unmasked;

    unless ($masked->seq =~ /[acgtACGT]{5}/) {
        warn "The genomic sequence is entirely repeat\n";
        return $ace;
    }

    my $features = $self->run_exonerate($masked, $smasked, $unmasked);
    $self->append_polyA_tail($features) unless $self->query_type eq 'protein' ;

    $ace .= $self->format_ace_output($name, $features);

    return $ace;
}

# Extend the last or first align feature to incorporate
# the query sequence PolyA/T tail if any

sub append_polyA_tail {
    my( $self, $features ) = @_;
    my %by_hit_name;
    my $debug = 0;

    # Group the DnaDnaAlignFeatures by hit_name
    map { $by_hit_name{$_->hseqname} ||= [] ; push @{$by_hit_name{$_->hseqname}}, $_ } @$features;

  HITNAME: for my $hit_name (keys %by_hit_name) {
      my ($sub_seq,$alt_exon,$match,$cigar,$pattern);
      my $hit_features = $by_hit_name{$hit_name};
      my $hit_strand = $hit_features->[0]->hstrand;
      print STDOUT "PolyA/T tail Search for $hit_name...\n";
      print STDOUT "Processing $hit_name with ".scalar(@$hit_features)." Features\n" if $debug;
      # fetch the hit sequence
      my $fetcher = $self->sequence_fetcher;
      my $seq = $fetcher->{$hit_name};
      # Get the AlignFeature that needs to be extended
      # last exon if hit in forward strand, first if in reverse

      @$hit_features = sort {
          $hit_strand == -1 ?
              $a->hstart <=> $b->hstart || $b->hend <=> $a->hend :
              $b->hend <=> $a->hend || $a->hstart <=> $b->hstart;
      } @$hit_features;
      $alt_exon = shift @$hit_features;
      print STDOUT ($hit_strand == -1 ? "Reverse" : "Forward").
          " strand: start ".$alt_exon->hstart." end ".$alt_exon->hend." length ".$seq->sequence_length."\n" if $debug;
      if($hit_strand == -1) {
          next HITNAME unless $alt_exon->hstart > 1;
          $sub_seq = $seq->sub_sequence(1,($alt_exon->hstart-1));
          print STDOUT "subseq <1-".($alt_exon->hstart-1)."> is\n$sub_seq\n" if $debug;
          $pattern = '^(.*T{3,})$';  # <AGAGTTTTTTTTTTTTTTTTTTTTTT>ALT_EXON_START
      }
      else {
          next HITNAME unless $alt_exon->hend < $seq->sequence_length;
          $sub_seq = $seq->sub_sequence(($alt_exon->hend+1),$seq->sequence_length);
          print STDOUT "subseq <".($alt_exon->hend+1)."-".$seq->sequence_length."> is\n$sub_seq\n" if $debug;
          $pattern = '^(A{3,}.*)$';  # ALT_EXON_END<AAAAAAAAAAAAAAAAAAAAAAAACGAG>
      }

      if($sub_seq =~ /$pattern/i ) {
          $match = length $1;
          $cigar = $alt_exon->cigar_string;
          print STDOUT "Found $match bp long polyA/T tail\n";

          # change the feature cigar string
          if(not $cigar =~ s/(\d*)M$/($1+$match)."M"/e ) {
              $cigar = $cigar."${match}M";
          }
          print STDOUT "old cigar $cigar new $cigar\n" if $debug;
          $alt_exon->cigar_string($cigar);

          # change the feature coordinates
          if($hit_strand == -1) {
              $alt_exon->hstart($alt_exon->hstart-$match);
          }
          else {
              $alt_exon->hend($alt_exon->hend+$match);
          }

          if($alt_exon->strand == 1) {
              $alt_exon->end($alt_exon->end+$match);
          }
          else {
              $alt_exon->start($alt_exon->start-$match);
          }

      }
      else {
          next HITNAME;
      }
  }

    return;
}

sub run_exonerate {
    my ($self, $masked, $smasked, $unmasked) = @_;

    my $analysis = $self->analysis();
    my $score = $self->score() || ( $self->query_type() eq 'protein' ? 150 : 2000 );
    my $dnahsp = $self->dnahsp || 120 ;
    my $bestn = $self->bestn || 0;
    my $max_intron_length = $self->max_intron_length || 200000;
    
    my $exo_options = "--softmasktarget yes -M 500 --bestn $bestn --maxintron $max_intron_length --score $score";
    
    $exo_options .=
        $self->query_type() eq 'protein' ?
        " -m p2g" :
        " -m e2g --softmaskquery yes --dnahspthreshold $dnahsp --geneseed 300" ;

    my $runnable = Bio::EnsEMBL::Analysis::Runnable::Finished::Exonerate->new(
        -analysis    => $self->analysis(),
        -target      => $smasked,
        -query_db    => $self->database(),
        -query_type  => $self->query_type() || 'dna',
        -exo_options => $exo_options,
        -program     => $self->analysis->program
        );
    $runnable->run();

    return $runnable->output;
}

sub add_hit_name {
    my( $self, $name ) = @_;

    $self->{'_hit_names'}{$name} = 1;

    return;
}

sub delete_all_hit_names {
    my ($self) = @_;

    my $hit_names = [ sort keys %{$self->{'_hit_names'}} ];
    $self->{'_hit_names'} = undef;
    return $hit_names;
}

sub format_ace_output {
    my ($self, $contig_name, $fp_list) = @_;

    unless (@$fp_list) {
        warn "No hits found on '$contig_name'\n";
        return '';
    }

    my $is_protein = $self->query_type eq 'protein';
    my $homol_tag   = $self->homol_tag;
    my $method_tag  = $self->method_tag;

    my $offset = $self->genomic_start - 1;

    my %name_fp_list;
    foreach my $fp (@$fp_list) {
        my $hname = $fp->hseqname;
        my $list = $name_fp_list{$hname} ||= [];
        push @$list, $fp;
        $fp->start($fp->start + $offset);
        $fp->end($fp->end + $offset);
    }

    my $ace = '';
    foreach my $hname (sort keys %name_fp_list) {
        # Save hit name. This is used to get the DNA sequence for
        # each hit from the fasta file using the OBDA index.
        $self->add_hit_name($hname);

        my $prefix = $is_protein ? 'Protein' : 'Sequence';

        $ace       .= qq{\nSequence : "$contig_name"\n};
        my $hit_ace = qq{\n$prefix : "$hname"\n};

        foreach my $fp (@{ $name_fp_list{$hname} }) {

            # In acedb strand is encoded by start being greater
            # than end if the feature is on the negative strand.
            my $strand  = $fp->strand;
            my $start   = $fp->start;
            my $end     = $fp->end;
            my $hstart  = $fp->hstart;
            my $hend    = $fp->hend;
            my $hstrand = $fp->hstrand;

            if ($hstrand ==-1){
                $fp->hstrand(1);
                $strand *= -1;
            }

            if ($strand == -1){
                ($start, $end) = ($end, $start);
            }

            my $hit_homol_tag = 'DNA_homol';

            # Show coords in hit back to genomic sequence. (The annotators like this.)
            $hit_ace .=
                sprintf qq{Homol %s "%s" "%s" %.3f %d %d %d %d\n},
                $hit_homol_tag, $contig_name, $method_tag, $fp->percent_id,
                $hstart, $hend, $start, $end;
            #print STDOUT sprintf qq{Homol %s "%s" "%s" %.3f %d %d %d %d\n},
            #$homol_tag, $contig_name, $method_tag, $fp->percent_id,
            #$fp->hstart, $fp->hend, $start, $end;

            # The first part of the line is all we need if there are no
            # gaps in the alignment between genomic sequence and hit.
            my $query_line =
                sprintf qq{Homol %s "%s" "%s" %.3f %d %d %d %d},
                $self->acedb_homol_tag, $hname, $method_tag, $fp->percent_id,
                $start, $end, $hstart, $hend;

            my @ugfs = $fp->ungapped_features;
            if (@ugfs > 1) {
                # Gapped alignments need two or more Align blocks to describe
                # them. The information at the start of the line is needed for
                # each block so that they all end up under the same tag once
                # they are parsed into acedb.
                foreach my $ugf (@ugfs){
                    my $ref_coord   = $strand  == -1 ? $ugf->end  : $ugf->start;
                    my $match_coord = $hstrand == -1 ? $ugf->hend : $ugf->hstart;
                    my $length      = ($ugf->hend - $ugf->hstart) + 1;
                    $ace .=
                        $query_line
                        . ($is_protein ? " AlignDNAPep" : " Align")
                        . " $ref_coord $match_coord $length\n";
                }
            } else {
                $ace .= $query_line . "\n";
            }
        }

        $ace .= $hit_ace;
    }

    return $ace;
}

sub list_GenomeSequence_names {
    my ($self) = @_;

    my $ace_dbh = $self->AceDatabase->aceperl_db_handle;
    return map { $_->name } $ace_dbh->fetch(Genome_Sequence => '*');
}

sub get_masked_unmasked_seq {
    my ($self) = @_;

    my $name = $self->genomic_seq->name;
    my $dna_str = $self->genomic_seq->sequence_string;
    $dna_str =~ s/-/N/g;
    my $sm_dna_str = uc $dna_str;

    warn "Got DNA string ", length($dna_str), " long";

    my $unmasked = Bio::Seq->new(
        -id         => $name,
        -seq        => $dna_str,
        -alphabet   => 'dna',
        );

    my $gff_http_script =
        $self->AceDatabase->script_dir
        . '/' .
        $self->AceDatabase->gff_http_script_name;
    my $dataset = $self->AceDatabase->smart_slice->DataSet;

    # mask the sequences with repeat features
    my $offset = $self->AceDatabase->offset;
    foreach my $filter_name qw( trf RepeatMasker ) {
        my $filter = $dataset->filter_by_name($filter_name);
        confess "no filter named '${filter_name}'" unless $filter;
        my @gff_http_command =
            ( $gff_http_script,
              @{$self->AceDatabase->gff_http_script_arguments($filter)} );
        open my $gff_http_h, '-|', @gff_http_command
            or confess "failed to run $gff_http_script: $!";
        while (<$gff_http_h>) {
            chomp;
            next if /^\#\#/; # skip GFF headers

            # feature parameters
            my ( $start, $end ) = (split /\t/)[3,4];
            $start -= $offset;
            $end   -= $offset;

            # sanity checks
            confess "missing feature start in '$_'" unless defined $start;
            confess "non-numeric feature start: $start"
                unless $start =~ /^[[:digit:]]+$/;
            confess "missing feature end in '$_'" unless defined $end;
            confess "non-numeric feature end: $end"
                unless $end =~ /^[[:digit:]]+$/;

            if ($start > $end) {
                ($start, $end) = ($end, $start);
            }

            # mask against this feature
            my $length = $end - $start + 1;
            substr($dna_str, $start - 1, $length, 'n' x $length);
            substr($sm_dna_str, $start - 1, $length,
                   lc substr($sm_dna_str, $start - 1, $length));
        }
        close $gff_http_h
            or confess $!
            ? "error closing $gff_http_script: $!"
            : "$gff_http_script failed: status = $?";
    }

    my $masked = Bio::Seq->new(
        -id         => $name,
        -seq        => $dna_str,
        -alphabet   => 'dna',
        );
    my $softmasked = Bio::Seq->new(
        -id         => $name,
        -seq        => $sm_dna_str,
        -alphabet   => 'dna',
        );

    return ($masked,$softmasked,$unmasked);
}

sub lib_path{
    my ($self, $path) = @_;
    if($path){
        $self->{'_lib_path'} = $path;
        $ENV{'LD_LIBRARY_PATH'} .= ":$path";
    }
    return $self->{'_lib_path'};
}

1;

__END__

=head1 AUTHOR

Anacode B<email> anacode@sanger.ac.uk

