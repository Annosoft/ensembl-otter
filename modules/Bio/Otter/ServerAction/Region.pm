package Bio::Otter::ServerAction::Region;

use strict;
use warnings;

use Readonly;
use Try::Tiny;
use Lingua::EN::Inflect qw( A NUMWORDS );

use Bio::Otter::Lace::CloneSequence;
use Bio::Vega::ContigInfo;
use Bio::Vega::SliceLockBroker;
use Bio::Vega::Region;

use base 'Bio::Otter::ServerAction';

=head1 NAME

Bio::Otter::ServerAction::Region - server requests on a region

=head1 CONSTRUCTOR

=cut

Readonly my @SLICE_REQUIRED_PARAMS => qw(
    dataset
    cs
    csver
    chr
    start
    end
);


=head2 new_with_slice

=cut

sub new_with_slice {
    my ($pkg, $server) = @_;

    my $self = $pkg->new($server);

    my $params = $server->require_arguments(@SLICE_REQUIRED_PARAMS);
    my $slice = $self->_get_requested_slice($params);
    $self->slice($slice);

    return $self;
}

sub _get_requested_slice {
    my ($self, $params) = @_;

    my $strand  = 1;

    return $self->server->otter_dba->get_SliceAdaptor->fetch_by_region(
        $params->{cs},
        $params->{chr},
        $params->{start},
        $params->{end},
        $strand,
        $params->{csver}
        );
}


=head1 METHODS

=head2 get_assembly_data

=cut

sub get_assembly_dna {
    my $self = shift;

    my $slice = $self->slice;
    my $output_string = $slice->seq . "\n";

    my $posn = 0;
    foreach my $tile (@{ $slice->project('seqlevel') }) {
        my $tile_slice = $tile->to_Slice;
        my $start = $tile->from_start;
        my $end   = $tile->from_end;

        # Is there a gap before this piece?
        if (my $gap = $start - $posn - 1) {
            # Debugging.  Show the char immediately before and after the string of "N".
            # $output_string .= substr($output_string, $posn == 0 ? 0 : $posn - 1, $posn == 0 ? $gap + 1 : $gap + 2) . "\n";
            # Change assembly gaps to dashes.
            substr($output_string, $posn, $gap, '-' x $gap);
        }
        $posn = $end;

        # To save copying large strings, we append onto the
        # end of the sequence in the output string.
        $output_string .= join("\t",
                               $tile->from_start,
                               $tile->from_end,
                               $tile_slice->seq_region_name,
                               $tile_slice->start,
                               $tile_slice->end,
                               $tile_slice->strand,
                               $tile_slice->seq_region_Slice->length,
            ) . "\n";
    }
    if (my $gap = $slice->length - $posn) {
        # If the slice ends in a gap, turn to dashes too
        substr($output_string, $posn, $gap, '-' x $gap);
    }

    return $output_string;
}


=head2 get_region

=cut

sub get_region {
    my $self = shift;

    my $odba  = $self->server->otter_dba;
    my $slice = $self->slice;

    my $region = Bio::Vega::Region->new_from_otter_db(
        otter_dba     => $odba,
        slice         => $slice,
        server_action => $self,
        );

    my $serialised_region = $self->serialise_region($region);
    return $serialised_region;
}


=head2 DE_region

Server-side generation of the "DE line" text, previously available in
the EditWindow::Clone window and generated client-side by
C<<$Assembly->generate_description_for_clone>> .

=cut

sub DE_region {
    my ($self) = @_;

    my $slice = $self->slice;

    my $GA   = $slice->adaptor->db->get_GeneAdaptor;
    my @loci = @{ $GA->fetch_all_by_Slice_untruncated($slice) };
    for (my $i = 0; $i < @loci;) {
        if ($loci[$i]->source eq 'havana') {
            $i++;
        }
        else {
            # Remove non-havana genes
            splice @loci, $i, 1;
        }
    }

    # Patterns for clone accession or clone name based gene names
    my $clone_accession = qr{^[A-Z]{1,2}\d{5,6}(\.\d{1,3})?$};
    my $clone_name      = qr{^[A-Z]{1,2}\d{1,3}-?\d{1,3}[A-Z]\d{1,3}(\.\d{1,3})?$};

    my @keywords;
    my $novel_gene_count      = 0;
    my $part_novel_gene_count = 0;
    my @DEline;

    # Loop through the loci in 5' -> 3' order
    foreach my $gene (sort {$a->start <=> $b->start} @loci) {
        my ($name_attrib) = @{ $gene->get_all_Attributes('name') };
        my $gene_name = $name_attrib ? $name_attrib->value : $gene->stable_id;

        my $desc = $gene->description
          or next;
        next if $desc =~ /artefact|artifact/i;

        my $line = '';

        # Is all of the gene in the slice?
        if ($gene->start < 1 and $gene->end > $slice->length) {
            $line = 'an internal part of ';
        }
        elsif ($gene->start < 1 and $gene->end <= $slice->length) {
            my $end = $gene->strand == 1 ? q{3'} : q{5'};
            $line = "the $end end of ";
        }
        elsif ($gene->start >= 1 and $gene->end > $slice->length) {
            my $end = $gene->strand == 1 ? q{5'} : q{3'};
            $line = "the $end end of ";
        }

        if ($desc =~ /novel\s+(protein|transcript|gene)\s+similar/i) {
            $line .= "the gene for " . A($desc);
            push @DEline, $line;
        }
        elsif (($desc =~ /(novel|putative) (protein|transcript|gene)/i)) {
            if ($desc =~ /(zgc:\d+)/) {
                $line .= "a gene for a novel protein ($1)";
                push @DEline, $line;
            }
            else {
                $line ? $part_novel_gene_count++ : $novel_gene_count++;
            }
        }
        elsif ($desc =~ /pseudogene/i) {
            if (   $gene_name !~ /$clone_accession/
                && $gene_name !~ /$clone_name/)
            {
                $line .= A($desc) . ' ' . $gene_name;
            }
            else {

                # in a pseudogene named after its clones,
                # locusname is not interesting
                $line .= A($desc);
            }
            push @DEline, $line;
        }
        elsif ($gene_name !~ /\.\d/) {
            $line .= "the $gene_name gene for $desc";
            push @DEline,   $line;
            push @keywords, $gene_name;
        }
        else {
            $line .= "a gene for " . A($desc);
            push @DEline, $line;
        }
    }

    if ($novel_gene_count) {
        if ($novel_gene_count == 1) {
            push @DEline, "a novel gene";
        }
        else {
            push @DEline, NUMWORDS($novel_gene_count) . " novel genes";
        }
    }

    if ($part_novel_gene_count) {
        if ($part_novel_gene_count == 1) {
            push @DEline, "part of a novel gene";
        }
        else {
            push @DEline, "parts of " . NUMWORDS($part_novel_gene_count) . " novel genes";
        }
    }

    my $final_line = 'Contains';
    if (@DEline == 0) {
        $final_line .= ' no genes.';
    }
    else {
        for (my $i = 0; $i < @DEline; $i++) {
            my $join = ';';
            if ($i == 0) {
                $join = '';
            }
            elsif ($i == $#DEline) {
                $join = '; and';
            }
            $final_line .= "$join $DEline[$i]";
        }
        $final_line .= '.';
    }

    return {
        keywords    => join("\n", @keywords),
        description => $final_line,
    };
}


=head2 write_region

Input: region data, author, locknums.

Output: updated region, or error.

=cut

sub write_region {
    my ($self) = @_;

    my $server = $self->server;

    my ($action, $serialised_output);
    try {
        $action = 'init';
        $server->require_method('POST');
        my $slb = $self->_slice_lock_broker(1);
        # author is checked against the locks by the broker.
        # we don't check source hostname: sessions do sometimes move around.

        $action = 'lock';
        my $current_region;
        $slb->exclusive_work # do lock, write and commit; or rollback
          (sub {
               $action = 'locked';
               $current_region = $self->_write_region_exclusive(\$action, $slb);
           });

        $action = 're-serialise';
        $serialised_output = $self->serialise_region($current_region);

    } catch {
        chomp;
        die "Writing region failed to $action \[$_]";
    };
    return $serialised_output;
}

sub _write_region_exclusive { # runs under $slb->exclusive_work
    my ($self, $action_sref, $slb) = @_;
    my $server = $self->server;

    $$action_sref = 'convert XML to otter';
    my $xml_string = $server->require_argument('data');
    my $new_region = $self->deserialise_region($xml_string);

    $$action_sref = 'compare assemblies'; # compare XML assembly with database assembly
    my $db_region = $self->_fetch_db_region($new_region);
    my $ci_hash   = $self->_compare_region_create_ci_hash($new_region, $db_region);

    $$action_sref = 'locks check';
    $slb->assert_bumped($db_region->slice);

    $$action_sref = 'write';
    my $time_now = do {
        my ($first_lock) = $slb->locks;
        # everything that needs saving should use this timestamp:
        $first_lock->ts_activity;
    };

    my $author_obj = $slb->author;
    my $odba = $self->server->otter_dba();

    # update all contig_info and contig_info_attrib
    while (my ($contig_name, $pair) = each %$ci_hash) {
        my ($db_ctg_slice, $xml_ci_attribs) = @$pair;
        warn "Ignoring contig info-attrib for '$contig_name'\n";
    }

    ## strip_incomplete_genes for the xml genes
    my @new_genes = $new_region->genes;
    $self->_strip_incomplete_genes(\@new_genes);

    my $db_slice = $db_region->slice;

    ##fetch database genes and compare to find the new/modified/deleted genes
    warn "Fetching database genes for comparison...\n";
    my $ga =  $db_slice->adaptor->db->get_GeneAdaptor();
    my $db_genes = $ga->fetch_all_by_Slice($db_slice) || [];
    $self->_strip_incomplete_genes($db_genes);
    warn "Comparing " . scalar(@$db_genes) . " old to " . scalar(@new_genes) . " new gene(s)...\n";

    my $gene_adaptor = $odba->get_GeneAdaptor;
    warn "Attaching gene to slice \n";

    my @changed_genes;
    foreach my $gene (@new_genes) {
        # attach gene and its components to the right slice
        $gene->slice($db_slice);
        # update author in gene and transcript
        $gene->gene_author($author_obj);
        foreach my $tran (@{ $gene->get_all_Transcripts }) {
            $tran->slice($db_slice);
            $tran->transcript_author($author_obj);
        }
        foreach my $exon (@{ $gene->get_all_Exons }) {
            $exon->slice($db_slice);
        }
        # update all gene and its components in db (new/mod)
        $gene->is_current(1);

        $slb->assert_bumped($gene->slice);
        if ($gene_adaptor->store($gene, $time_now)) {
            push(@changed_genes, $gene);
        }
    }
    warn "Updated " . scalar(@changed_genes) . " genes\n";

    my %stored_genes_hash = map {$_->stable_id, $_} @new_genes;

    my $del_count = 0;
    foreach my $dbgene (@$db_genes) {
        next if $stored_genes_hash{$dbgene->stable_id};

        ##attach gene and its components to the right slice
        $dbgene->slice($db_slice);
        ##update author in gene and transcript
        $dbgene->gene_author($author_obj);
        foreach my $tran (@{ $dbgene->get_all_Transcripts }) {
            $tran->slice($db_slice);
            $tran->transcript_author($author_obj);
        }
        foreach my $exon (@{ $dbgene->get_all_Exons }) {
            $exon->slice($db_slice);
        }
        ##update all gene and its components in db (del)

        # Setting is_current to 0 will cause the store method to delete it.
        $dbgene->is_current(0);
        $slb->assert_bumped($dbgene->slice);
        $gene_adaptor->store($dbgene, $time_now);
        $del_count++;
        warn "Deleted gene " . $dbgene->stable_id . "\n";
    }
    warn "Deleted $del_count Genes\n" if ($del_count);

    my $ab = $odba->get_AnnotationBroker();

    # Because exons are shared between transcripts, genes and gene versions
    # setting which are current is not simple
    #$ab->set_exon_current_flags($db_genes, \@new_genes);

    ##update feature_sets
    ##SimpleFeatures - deletes old features(features not in xml)
    ##and stores the current featues in databse(features in xml)
    my @new_simple_features = $new_region->seq_features;
    my $sfa                 = $odba->get_SimpleFeatureAdaptor;
    my $db_simple_features  = $sfa->fetch_all_by_Slice($db_slice);

    my ($delete_sf, $save_sf) = $ab->compare_feature_sets($db_simple_features, \@new_simple_features);
    foreach my $del_feat (@$delete_sf) {
        $slb->assert_bumped($del_feat->slice);
        $sfa->remove($del_feat);
    }
    warn "Deleted " . scalar(@$delete_sf) . " SimpleFeatures\n";
    foreach my $new_feat (@$save_sf) {
        $new_feat->slice($db_slice);
        $slb->assert_bumped($new_feat->slice);
        $sfa->store($new_feat);
    }
    warn "Saved " . scalar(@$save_sf) . " SimpleFeatures\n";

    ##assembly_tags are not taken into account here, as they are not part of annotation nor versioned ,
    ##but may be required in the future
    ##fetch a new slice, and convert this new_slice to xml so that
    ##the response xml has all the above changes done in this session

    # Pass on to the xml generator the set of changed genes, and
    # all simple features
    my $current_region =  Bio::Vega::Region->new(
            otter_dba     => $odba,
            slice         => $db_slice,
            server_action => $self,
            );
    $current_region->genes(@changed_genes);
    $current_region->seq_features(@new_simple_features);
    $current_region->fetch_species;
    $current_region->fetch_CloneSequences;

    return $current_region;
}

sub _slice_lock_broker {
    my ($self, $add_locknums) = @_;
    die unless defined $add_locknums;
    my $server = $self->server;

    my @lockp;
    if ($add_locknums) {
        my $locknums   = $server->require_argument('locknums');
        my @locknum = split ',', $locknums;
        @lockp = (-lockid => \@locknum);
    }

    my $slb = Bio::Vega::SliceLockBroker->new
      (-author => $server->make_Author_obj,
       -adaptor => $server->otter_dba,
       @lockp);

    return $slb;
}

sub _fetch_db_region {
    my ($self, $new_region) = @_;

    my $odba = $self->server->otter_dba;
    my $new_slice = $new_region->slice;

    my $db_slice = $odba->get_SliceAdaptor()->fetch_by_region(
        $new_slice->coord_system->name,
        $new_slice->seq_region_name,
        $new_slice->start,
        $new_slice->end,
        $new_slice->strand,
        $new_slice->coord_system->version,
        );

    my $db_region = Bio::Vega::Region->new;
    $db_region->slice($db_slice);

    my @db_tiles = sort { $a->from_start() <=> $b->from_start() } @{ $db_slice->project('contig') };

    my @db_clone_sequences;
    foreach my $tile ( @db_tiles ) {
        my $ctg_slice = $tile->to_Slice;

        my $cs = Bio::Otter::Lace::CloneSequence->new;
        $cs->chr_start(    $tile->from_start + $new_slice->start - 1 );
        $cs->chr_end(      $tile->from_end   + $new_slice->start - 1 );
        $cs->contig_start( $ctg_slice->start  );
        $cs->contig_end(   $ctg_slice->end    );
        $cs->contig_strand($ctg_slice->strand );

        my $ci = Bio::Vega::ContigInfo->new( -slice => $ctg_slice );
        $cs->ContigInfo($ci);

        push @db_clone_sequences, $cs;
    }
    $db_region->clone_sequences(@db_clone_sequences);

    return $db_region;
}

sub _compare_region_create_ci_hash {
    my ($self, $new_region, $db_region) = @_;

    my $db_slice = $db_region->slice;

    my @new_clone_sequences = $new_region->clone_sequences;
    my @db_clone_sequences  = $db_region->clone_sequences;

    if (@db_clone_sequences != @new_clone_sequences) {
        die "The numbers of tiles in new_region and DB_region do not match";
    }

    my %contig_info_hash;

    for (my $i = 0; $i < @db_clone_sequences; $i++) {

        my $db_asm_start = $db_clone_sequences[$i]->chr_start();
        my $db_asm_end   = $db_clone_sequences[$i]->chr_end();
        my $db_ctg_slice = $db_clone_sequences[$i]->ContigInfo->slice();

        my $new_asm_start  = $new_clone_sequences[$i]->chr_start();
        my $new_asm_end    = $new_clone_sequences[$i]->chr_end();
        my $new_ctg_slice  = $new_clone_sequences[$i]->ContigInfo->slice();
        my $new_ci_attribs = $new_clone_sequences[$i]->ContigInfo->get_all_Attributes();

        if($db_asm_start != $new_asm_start) {
            die "In tile number $i 'asm_start' is different (new_value='$new_asm_start', db_value='$db_asm_start') ";
        }

        if($db_asm_end != $new_asm_end) {
            die "In tile number $i 'asm_end' is different (new_value='$new_asm_end', db_value='$db_asm_end') ";
        }

        foreach my $method (qw{ seq_region_name start end strand }) {
            my $db_value  = $db_ctg_slice->$method();
            my $new_value = $new_ctg_slice->$method();
            if ($db_value ne $new_value) {
                die "In tile number $i '$method' is different (new_value='$new_value', db_value='$db_value') ";
            }
        }

        ## hash the [db_contig, new_ci_attribs] pairs
        # previously, for saving the attributes after the locks are obtained
        # now just warn that they are ignored
        $contig_info_hash{$new_ctg_slice->seq_region_name()} = [ $db_ctg_slice, $new_ci_attribs ];
    }

    return \%contig_info_hash;
}


sub _strip_incomplete_genes {
    my ($self, $gene_list) = @_;

    for (my $i = 0 ; $i < @$gene_list ;) {
        my $gene = $gene_list->[$i];
        if ($gene->truncated_flag) {
            my $gene_name = $gene->get_all_Attributes('name')->[0]->value;
            warn "Splicing out incomplete gene '$gene_name'\n";
            splice(@$gene_list, $i, 1);
            next;
        } else {
            $i++;
        }
    }
    return;
}


=head2 lock_region

Input: region, author, hostname, client.

Output (JSON): error or { locknums => $txt }.

=cut

sub lock_region {
    my ($self) = @_;

    my $server = $self->server;
    $server->content_type('application/json');

    my $client = $server->param('client') || $server->cgi->user_agent;
    substr($client, 35) = '...' ## no critic (BuiltinFunctions::ProhibitLvalueSubstr)
      if length($client) > 38; # keep -intent short

    my $cl_host = $server->best_client_hostname;

    my ($lock_token, $action);
    try {
        $action = 'init';
        $server->require_method('POST');
        my $slb = $self->_slice_lock_broker(0);
        $slb->client_hostname($cl_host);

        $action = 'pre-lock';
        $slb->lock_create_for_Slice
          (-slice => $self->slice,
           -intent => "lock_region for $client");

        $action = 'locking';
        $slb->exclusive_work(sub {}); # do lock and commit, or rollback

        $action = 'output';
        my @dbID = map { $_->dbID } $slb->locks;
        $lock_token = { locknums => join ',', @dbID };
    } catch {
        chomp;
        die "Locking slice failed during $action \[$_]";
    };

    return $lock_token;
}


=head2 unlock_region

Input: locknums.

Output: error, or { unlocked => $locknums1, already => $locknums2 }

When the C<locknums> contains multiple locks, they must be compatible
within the SliceLockBroker together i.e. have the same author and
host.

=cut

sub unlock_region {
    my ($self) = @_;
    my $server = $self->server;
    $server->content_type('application/json');

    my (%out, $action);
    try {
        $action = 'init';
        $server->require_method('POST');
        my $slb_all = $self->_slice_lock_broker(1);

        $action = 'checking locks';
        my @already = grep { ! $_->is_held } $slb_all->locks;
        my @locked  = grep {   $_->is_held } $slb_all->locks;

        $action = 'to unlock slice';
        if (@locked) {
            my $slb_locked = $self->_slice_lock_broker(0);
            $slb_locked->locks(@locked);
            my $unlock_fail = $slb_locked->exclusive_work(sub {}, 1);
            die $unlock_fail if $unlock_fail;
        }

        $action = 'output';
        $out{unlocked} = join ',', map { $_->dbID } @locked if @locked;
        $out{already} = join ',', map { $_->dbID } @already if @already;
        die "Nothing happened" unless keys %out;

    } catch {
        chomp;
        die "Failed $action \[$_]";
    };

    return \%out;
}

### Null serialisation & deserialisation methods

sub serialise_region {
    my ($self, $region) = @_;
    return $region;
}

sub deserialise_region {
    my ($self, $region) = @_;
    return $region;
}

### Accessors

sub server {
    return shift->{_server};
}

sub slice {
    my ($self, @args) = @_;
    ($self->{_slice}) = @args if @args;
    return $self->{_slice};
}

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

=cut

1;
