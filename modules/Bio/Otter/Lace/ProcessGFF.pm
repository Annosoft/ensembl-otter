
### Bio::Otter::Lace::ProcessGFF

package Bio::Otter::Lace::ProcessGFF;

use strict;
use warnings;
use Carp;
use Text::ParseWords qw{ quotewords };
use Hum::Ace::SubSeq;
use Hum::Ace::Method;
use Hum::Ace::Locus;

use Try::Tiny;

{
    ### Should add this to otter_config
    ### or parse it from the ZMap styles
    my %evidence_type = (
        vertebrate_mRNA  => 'cDNA',
        vertebrate_ncRNA => 'ncRNA',
        BLASTX           => 'Protein',
        SwissProt        => 'Protein',
        TrEMBL           => 'Protein',
        OTF_ncRNA        => 'ncRNA',
        OTF_EST          => 'EST',
        OTF_mRNA         => 'cDNA',
        OTF_Protein      => 'Protein',
        SwissProt_old    => 'Protein', # tmp RT#370164 RT#359109
        TrEMBL_old       => 'Protein',
    );

    # Some GFFs have other fields (feat_type=protein_match,
    # DB_Name=TrEMBL, Class=Protein) which should be indicative.
    sub __source2type {
        my ($source) = @_;
        return 'EST' if substr($source, 0, 4) eq 'EST_';
        return $evidence_type{$source};
    }
}

sub store_hit_data_from_gff {
    my ($accession_type_cache, $gff_file) = @_;

    $accession_type_cache->begin_work;

    my %fail;
    open my $gff_fh, '<', $gff_file or confess "Can't read GFF file '$gff_file'; $!";
    while (<$gff_fh>) {
        next if /^\s*#/;
        my ($seq_name, $source, $feat_type, $start, $end, $score, $strand, $frame, $attrib)
            = parse_gff_line($_);
        next unless $attrib->{'Name'};
        my $evi_type = __source2type($source);
        if (!$evi_type) {
            $fail{$source} ||= "Cannot convert source=$source to an evidence type\nFirst is $gff_file:$.:$_";
            next;
        }
        $accession_type_cache->save_accession_info(
            $attrib->{'Name'},
            $attrib->{'Taxon_ID'},
            $evi_type,
            $attrib->{'Description'},
            $attrib->{'DB_Name'},
            $attrib->{'Length'},
            );
    }
    close $gff_fh or confess "Error reading GFF file '$gff_file'; $!";

    $accession_type_cache->commit;

    foreach my $prob (sort values %fail) {
        warn $prob; # warn because it is only a cache save fail
    }

    return;
}


sub make_ace_transcripts_from_gff {
    my ($gff_file) = @_;

    my %tsct;
    open my $gff_fh, '<', $gff_file or confess "Can't read GFF file '$gff_file'; $!";
    make_ace_transcripts_from_gff_fh($gff_fh, \%tsct);
    close $gff_fh or confess "Can't close GFF file '$gff_file'; $!";

    my (@ok_tsct);
    while (my ($name, $sub) = each %tsct) {
        try {
            $sub->validate; # raises an error if invalid
            push(@ok_tsct, $sub);
        }
        catch {
            # special case for a common error - trim off stack trace - RT#273390
            s{^(Translation coord '\d+' does not lie within any Exon\n) at .*}{$1}s;
            warn "Skipped SubSeq '$name'.  Error:\n$_";
        };
    }
    return @ok_tsct;
}

sub make_ace_transcripts_from_gff_fh {
    my ($gff_fh, $tsct) = @_;

    my (%locus_by_name, $gene_method, $coding_gene_method);

    my ($seq_region_found,
        $seq_region_start,
        $seq_region_end,
        $seq_region_offset,
        $seq_region_length);

    $seq_region_found = 0;
    while (<$gff_fh>) {
        if (/^\s*#/) {
            if (/^\s*##sequence-region /) {
                if (($seq_region_start, $seq_region_end) =
                    /^##sequence-region \S+ (\d+) (\d+)/) {
                    $seq_region_found = 1;
                    $seq_region_offset = $seq_region_start - 1;
                    $seq_region_length = $seq_region_end - $seq_region_offset;
                }
                else {
                    confess "invalid sequence region header in GFF file"
                }
            }
            next;
        }
        confess "no sequence region header in GFF file" unless $seq_region_found;
        my ($seq_name, $source, $feat_type, $start, $end, $score, $strand, $frame, $attrib)
            = parse_gff_line($_);
        $start -= $seq_region_offset;
        $end   -= $seq_region_offset;
        my $name = $attrib->{'Name'};
        next unless $name;
        my ($sub);
        unless ($sub = $tsct->{$name}) {
            $sub = Hum::Ace::SubSeq->new;
            unless ($gene_method) {
                $gene_method = Hum::Ace::Method->new;
                $gene_method->name($source);
                $coding_gene_method = Hum::Ace::Method->new;
                $coding_gene_method->name($source);
                $coding_gene_method->coding(1);
            }
            $sub->name($name);
            $sub->GeneMethod($gene_method);
            $tsct->{$name} = $sub;
        }

        if ($feat_type eq 'Sequence') {
            $sub->strand($strand eq '-' ? -1 : 1);
            if (my $stable = $attrib->{'Stable_ID'}) {
                $sub->otter_id($stable);
            }
            if (my $loc_name = $attrib->{'Locus'}) {
                my $locus = $locus_by_name{$loc_name};
                unless ($locus) {
                    $locus = $locus_by_name{$loc_name}
                        = Hum::Ace::Locus->new;
                    $locus->name($loc_name);
                    if (my $stable = $attrib->{'Locus_Stable_ID'}) {
                        $locus->otter_id($stable);
                    }
                }
                $sub->Locus($locus);
            }
        }
        ### HACK: Should truncate to Slice on server
        elsif ($feat_type eq 'exon') {
            # Truncate exons to slice
            next if $end < 1;
            next if $start > $seq_region_length;
            $start = 1 if $start < 1;
            $end = $seq_region_length if $end > $seq_region_length;

            my $exon = $sub->new_Exon;
            $exon->start($start);
            $exon->end($end);
            if (my $stable = $attrib->{'Stable_ID'}) {
                $exon->otter_id($stable);
            }
        }
        elsif ($feat_type eq 'CDS') {            
            # Don't attempt truncated CDS
            next if $start < 1;
            next if $end > $seq_region_length;

            $sub->translation_region($start, $end);
            $sub->GeneMethod($coding_gene_method);
            if (my $stable = $attrib->{'Stable_ID'}) {
                $sub->translation_otter_id($stable);
            }
        }
    }

    return;
}

sub parse_gff_line {
    my ($line) = @_;

    chomp($line);
    my ($seq_name, $source, $feat_type, $start, $end, $score, $strand, $frame, $group)
        = split(/\t/, $line, 9);
    my $attrib = {};
    # The "1" argument to quotewords tells it to keep the quotes
    # so that we preserve the fields for the next level of parsing
    foreach my $tag_val (quotewords('\s*;\s*', 1, $group)) {
        # The "0" argument means that we now discard the quotes
        my ($tag, @values) = quotewords('\s+', 0, $tag_val);
        $attrib->{$tag} = "@values";
    }
    return ($seq_name, $source, $feat_type, $start, $end, $score, $strand, $frame, $attrib);
}

# $gff->{seqname}, $gff->{source}, $gff->{feature}, $gff->{start},
# $gff->{end},     $gff->{score},  $gff->{strand},  $gff->{frame},


1;

__END__

=head1 NAME - Bio::Otter::Lace::ProcessGFF

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

