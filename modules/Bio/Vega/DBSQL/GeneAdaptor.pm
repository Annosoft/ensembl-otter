
package Bio::Vega::DBSQL::GeneAdaptor;

use strict;
use warnings;

use Bio::Vega::Gene;
use Bio::Vega::Transcript;
use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::Vega::Utils::Comparator qw(compare);
use Bio::Vega::AnnotationBroker;
use Bio::Otter::MFetcher;

use base 'Bio::EnsEMBL::DBSQL::GeneAdaptor';


sub list_current_dbIDs {
    my ($self) = @_;

    my $sth = $self->prepare(q{ SELECT gene_id FROM gene WHERE is_current = 1 });
    $sth->execute;
    my $gene_id_list = [];
    while (my ($id) = $sth->fetchrow) {
        push(@$gene_id_list, $id);
    }
    return $gene_id_list;
}

sub fetch_by_dbID {
    my ($self, $db_id) = @_;

    if (my $gene = $self->SUPER::fetch_by_dbID($db_id)) {
        $self->reincarnate_gene($gene);
        return $gene;
    }
    else {
        return;
    }
}

sub fetch_by_stable_id {
    my ($self, $stable_id) = @_;
    my ($gene) = $self->SUPER::fetch_by_stable_id($stable_id);
    if ($gene) {
        $self->reincarnate_gene($gene);
    }
    return $gene;
}

sub fetch_by_name {
    my ($self, $genename) = @_;
    unless ($genename) {
        throw("Must enter a gene name to fetch a Gene");
    }
    my $genes = $self->fetch_by_attribute_code_value('name', $genename);
    my $gene;
    my $dbid;
    if ($genes) {
        my $stable_id;
        foreach my $g (@$genes) {
            if ($stable_id && $stable_id ne $g->stable_id) {
                ### Does this make sense? Why not return a list of genes?
                warn "more than one gene has the same name [$genename]\n";
            }
            $stable_id = $g->stable_id;
            if ($dbid) {
                if ($g->dbID > $dbid) {
                    ## Why not just keep the gene?
                    $dbid = $g->dbID;
                }
            }
            else {
                $dbid = $g->dbID;
            }
        }
    }
    if ($dbid) {
        print STDOUT "gene found\n";
        $gene = $self->fetch_by_dbID($dbid);
        $self->reincarnate_gene($gene);
    }

    return $gene;
}

sub fetch_all_current_by_name {
    my ($self, $genename) = @_;
    unless ($genename) {
        throw("Must enter a gene name to fetch Genes");
    }
    my $genes = $self->fetch_by_attribute_code_value('name', $genename);
    my $current_genes;
    if ($genes) {
        foreach my $g (@{$genes}) {
            next unless $g->is_current;
            $self->reincarnate_gene($g);
            push @{$current_genes}, $g;
        }
    }
    return $current_genes || [];
}

sub fetch_consortiumID_by_dbID {
    my ($self, $dbID) = @_;

    my $sth = $self->prepare(
        q{
     SELECT consortium_id
     FROM gene_name_update
     WHERE gene_id = ?
     }
    );

    $sth->execute($dbID);
    if (my $consortiumID = $sth->fetchrow) {

        #    warn "gene_id $dbID: $consortiumID";
        return $consortiumID;
    }
    else {

        # Consortium ID is available only when there is update from HGNC
        return 0;
    }
}

sub fetch_by_attribute_code_value {
    my ($self, $attrib_code, $attrib_value) = @_;

    my $sth = $self->prepare(
        q{
    SELECT ga.gene_id
    FROM attrib_type a
      , gene_attrib ga
    WHERE ga.attrib_type_id = a.attrib_type_id
      AND a.code = ?
      AND ga.value = ?
    }
    );
    $sth->execute($attrib_code, $attrib_value);
    my $geneids = [ map { $_->[0] } @{ $sth->fetchall_arrayref() } ];
    $sth->finish();
    if (@$geneids) {
        return $self->fetch_all_by_dbID_list($geneids);
    }
    else {
        return 0;
    }
}

sub fetch_stable_id_by_name {

    # can search either genename or transname by name or synonym,
    # support CASE INSENSITIVE search
    # returns a reference to a list of gene stable ids if successful
    # $mode is either 'gene' or 'transcript' which corresponds to genename or transname
    # search uses LIKE command
    # $current is either 1 or 0

    my ($self, $name, $mode, $current) = @_;

    unless ($name) {
        throw("Must enter a gene name to fetch a Gene");
    }

    my $mode_attrib = ($mode eq 'gene') ? 'gene_attrib' : 'transcript_attrib';

    my ($attrib_code, $attrib_value, $gsids, $join);
    my $seen;

    foreach (qw(name synonym)) {

        # warn "    Search $name by $_";
        $attrib_code  = $_;
        $attrib_value = $name;
        if ($mode eq 'gene') {
            $attrib_value =~ s/-\d+$//;
            $join = "m.gene_id = ma.gene_id";
        }
        else {
            # $attrib_value =~ /(.*)-\d+.*/;     # eg, ABO-001
            # want sth. like RP11-195F19.20, trim away eg, -001, -002-2-2
            my ($attrib_value_2) =
                $attrib_value =~ /(.*\.\d+).*/;

            # BCM:NM_032242_26281 (OTTHUMG00000136748)
            $attrib_value = $attrib_value_2 if defined $attrib_value_2;
            $join = "m.transcript_id = ma.transcript_id";
        }

        $attrib_value = lc($attrib_value);     # for case-insensitive comparison later
        my $sql = qq{
                SELECT distinct gsi.stable_id
                  , ma.value
                FROM gene_stable_id gsi
                  , $mode m
                  , attrib_type a
                  , $mode_attrib ma
                WHERE gsi.gene_id = m.gene_id
                  AND $join
                  AND ma.attrib_type_id = a.attrib_type_id
                  AND a.code = ?
                  AND ma.value LIKE ?
               };

        $sql .= " AND m.is_current = 1" if $current;

        #warn $sql;
        my $sth = $self->prepare($sql);

        $sth->execute($attrib_code, qq{$attrib_value%});

        while (my ($gsid, $value) = $sth->fetchrow) {

            # exclude eg, SET7 SETX where search is 'SET%' (ie, allow SET-2)
            # or BCM:bcm(AK057855)-2-001, bcm:bcm(ak057855)-2
            $value = lc($value);

            #warn "DB: $gsid, $value -- $attrib_value";

            if ($value eq $attrib_value or $value =~ /\Q$attrib_value\E(\.\w*)?-\d+/) {
                $seen->{$gsid}++;
                push(@$gsids, $gsid) if $seen->{$gsid} == 1;
            }
        }
        $sth->finish();
    }

    return $gsids;
}

sub reincarnate_gene {
    my ($self, $gene) = @_;

    my $this_class = 'Bio::Vega::Gene';

    if ($gene->isa($this_class)) {

        # warn "Gene is already a $this_class, possibly due to caching";
    }
    else {
        bless $gene, $this_class;

        my $author = $self->db->get_AuthorAdaptor->fetch_gene_author($gene->dbID);
        $gene->gene_author($author);

        # force loading of gene attributes
        $gene->get_all_Attributes();

        # force loading and reincarnation of transcripts
        foreach my $t (@{ $gene->get_all_Transcripts() }) {

            # force loading of transcript attributes
            $t->get_all_Attributes();
        }
    }

    return $gene;
}

sub fetch_all_versions_by_Slice_constraint {
    my ($self, $slice, $constraint, $logic_name, $load_transcripts) = @_;

    $constraint ||= '1 = 1'; # this should not break the primitive MySQL patterns

    my $genes = $self->SUPER::fetch_all_by_Slice_constraint($slice, $constraint, $logic_name) || [];

    ## if there are 0 or 1 genes still do lazy-loading
    if (!$load_transcripts || @$genes < 2) {
        return $genes;
    }

    # preload all of the transcripts now, instead of lazy loading later
    # faster than 1 query per transcript

    # first check if transcripts are already preloaded
    # coorectly we should check all of them ..
    return $genes if (exists $genes->[0]->{'_transcript_array'});

    # get extent of region spanned by transcripts
    my ($min_start, $max_end);
    foreach my $g (@$genes) {
        if (!defined($min_start) || $g->seq_region_start() < $min_start) {
            $min_start = $g->seq_region_start();
        }
        if (!defined($max_end) || $g->seq_region_end() > $max_end) {
            $max_end = $g->seq_region_end();
        }
    }

    my $ext_slice;

    if ($min_start >= $slice->start() && $max_end <= $slice->end()) {
        $ext_slice = $slice;
    }
    else {
        my $sa = $self->db()->get_SliceAdaptor();
        $ext_slice = $sa->fetch_by_region(
            $slice->coord_system->name(),
            $slice->seq_region_name(),
            $min_start, $max_end, $slice->strand(), $slice->coord_system->version()
        );
    }

    # associate transcript identifiers with genes

    my %g_hash = map { $_->dbID => $_ } @$genes;

    my $g_id_str = '(' . join(',', keys %g_hash) . ')';

    my $sth = $self->prepare("SELECT gene_id, transcript_id " . "FROM   transcript " . "WHERE  gene_id IN $g_id_str");

    $sth->execute();

    my ($g_id, $tr_id);
    $sth->bind_columns(\$g_id, \$tr_id);

    my %tr_g_hash;

    while ($sth->fetch()) {
        $tr_g_hash{$tr_id} = $g_hash{$g_id};
    }

    $sth->finish();

    my $ta = $self->db()->get_TranscriptAdaptor();
    my $transcripts = $ta->fetch_all_by_Slice($ext_slice, 1);

    # move transcripts onto gene slice, and add them to genes
    foreach my $tr (@$transcripts) {
        if (!exists $tr_g_hash{ $tr->dbID() }) {
            next;
        }

        my $new_tr;
        if ($slice != $ext_slice) {
            $new_tr = $tr->transfer($slice) if ($slice != $ext_slice);
            if (!$new_tr) {
                throw("Unexpected. Transcript could not be transfered onto Gene slice.");
            }
        }
        else {
            $new_tr = $tr;
        }

        $tr_g_hash{ $tr->dbID() }->add_Transcript($new_tr);
    }

    return $genes;
}

sub fetch_all_by_Slice_untruncated {
    my ($self, $slice, $logic_name, $load_transcripts) = @_;
    my ($genes) = $self->fetch_all_by_Slice_constraint($slice, 'g.is_current = 1', $logic_name, $load_transcripts);

    foreach my $gene (@$genes) {
        $self->reincarnate_gene($gene);
        # Force loading of exons, to replicate behaviour of full fetch_all_by_Slice()
        foreach my $t (@{$gene->get_all_Transcripts}) {
            $t->get_all_Exons;
        }
    }
    return $genes;
}

sub fetch_all_by_Slice {
    my ($self, $slice, $logic_name, $load_transcripts) = @_;
    my $latest_genes = [];
    my ($genes) = $self->fetch_all_by_Slice_untruncated($slice, $logic_name, $load_transcripts);

    foreach my $gene (@$genes) {
        my $tsct_list = $gene->get_all_Transcripts;
        for (my $i = 0; $i < @$tsct_list;) {
            my $transcript = $tsct_list->[$i];
            my ($t_name);
            eval {
                my $t_name_att = $transcript->get_all_Attributes('name');
                if ($t_name_att->[0]) {
                    $t_name = $t_name_att->[0]->value;
                }
            };
            if ($@) {
                die sprintf("Error getting name of %s %s (%d):\n$@",
                    ref($transcript), $transcript->stable_id, $transcript->dbID);
            }
            my $exons_truncated = $transcript->truncate_to_Slice($slice);
            my $ex_list         = $transcript->get_all_Exons;
            my $message;
            my $truncated = 0;
            if (@$ex_list) {
                $i++;
                if ($exons_truncated) {
                    $message = "Transcript '$t_name' has $exons_truncated exon";
                    if ($exons_truncated > 1) {
                        $message .= 's that are not in this slice';
                    }
                    else {
                        $message .= ' that is not in this slice';
                    }
                    $truncated = 1;

                }
            }
            else {

                # This will fail if get_all_Transcripts() ceases to return a ref
                # to the actual list of Transcripts inside the Gene object
                splice(@$tsct_list, $i, 1);
                $message   = "Transcript '$t_name' has no exons within the slice";
                $truncated = 1;
            }
            if ($truncated) {
                my $remark_att = Bio::EnsEMBL::Attribute->new(
                    -CODE        => 'remark',
                    -NAME        => 'Remark',
                    -DESCRIPTION => 'Annotation Remark',
                    -VALUE       => $message
                );

                my $gene_att = $gene->get_all_Attributes;
                push @$gene_att, $remark_att;
                $gene->truncated_flag(1);
                print STDERR "Found a truncated gene\n";
            }
        }

        # Remove any genes that don't have transcripts left.
        if (@$tsct_list) {
            push @$latest_genes, $gene;
        }
    }
    return $latest_genes;
}

sub fetch_by_stable_id_version {
    my ($self, $stable_id, $version) = @_;
    unless ($stable_id || $version) {
        throw("Must enter a gene stable id:$stable_id and version:$version to fetch a Gene");
    }
    my $constraint =
"g.stable_id = '$stable_id' AND g.version = '$version' ORDER BY g.modified_date DESC, g.gene_id DESC LIMIT 1";
    my ($gene) = @{ $self->generic_fetch($constraint) };
    if ($gene) {
        $self->reincarnate_gene($gene);
    }
    return $gene;
}

sub fetch_longest_transcript_by_stable_id {

    # returns longest transcript obj of the current gene
    # only 1 is returned if >1
    my ($self, $gene_stable_id) = @_;

    my $gene = $self->fetch_by_stable_id($gene_stable_id);

    my $trans_len;
    foreach my $t (@{ $gene->get_all_Transcripts }) {
        push(@{ $trans_len->{ $t->length } }, $t);
    }

    return $trans_len->{ (sort { $a <=> $b } keys %$trans_len)[-1] }->[0];
}

sub fetch_by_transcript_stable_id_constraint {

    # Ensembl has fetch_by_transcript_stable_id
    # but is restricted to is_current == 1

    # here, is_current is not restricted to 1
    # use this for tracking gene history
    # returns a reference to a list of vega gene objects

    my ($self, $trans_stable_id) = @_;

    my $sth = $self->prepare(
        qq(
        SELECT  tr.gene_id
        FROM    transcript tr, transcript_stable_id tsi
        WHERE   tsi.stable_id = ?
        AND     tr.transcript_id = tsi.transcript_id
    )
    );

    $sth->execute($trans_stable_id);

    my ($genes, $seen_genes);

    # check if a transcript is attached to multiple gene stable_ids
    # should not be the case, but happens in gene history

    while (my $geneid = $sth->fetchrow) {
        throw("No gene id found: invalid gene stable id") unless $geneid;

        my $gene = $self->fetch_by_dbID($geneid);
        my $gsid = $gene->stable_id;
        $seen_genes->{$gsid}++;
        push(@$genes, $gene) if $seen_genes->{$gsid} == 1;
    }

    if (keys %$seen_genes > 1) {
        my @gsids = keys %$seen_genes;
        printf STDERR "$trans_stable_id (history) belongs to > 1 gene_stable_ids: @gsids\n";
    }

    return $genes;
}

sub get_current_Gene_by_slice {
    my ($self, $gene) = @_;
    unless ($gene) {
        throw("no gene passed on to fetch old gene");
    }
    my $gene_slice     = $gene->slice;
    my $gene_stable_id = $gene->stable_id;
    my @out =
      grep { $_->stable_id eq $gene_stable_id }
      @{ $self->fetch_all_by_Slice_constraint($gene_slice, 'g.is_current = 1 ') };
    if ($#out > 1) {
        die "there are more than one gene retrived\n";
    }
    my $db_gene = $out[0];
    if ($db_gene) {
        $self->reincarnate_gene($db_gene);
    }
    return $db_gene;
}

# Fetch and reincarnate the last version of the gene with the same stable_id (whether current or not).
sub fetch_latest_by_stable_id {
    my ($self, $stable_id) = @_;

    my $constraint =
      "g.stable_id = '$stable_id' ORDER BY g.is_current DESC, g.modified_date DESC, g.gene_id DESC LIMIT 1";
    my ($gene) = @{ $self->generic_fetch($constraint) };
    if ($gene) {
        $self->reincarnate_gene($gene);
    }
    return $gene;
}

=head2 store

 Title   : store
 Usage   : store a gene from the otter_lace client, where genes and its components are attached to a gene_slice or
         : store a gene directly from a script where the gene is attached to the whole chromosome slice.
         :
 Function: Every gene is compared with the database gene on itself and all its components and versions allocated accordingly.
         : Version is incremented only if there is a change otherwise not. Re-using of exons between version of gene and between
         : transcripts of the same gene.
         : stores a deleted gene
         : stores a changed gene
         : stores a restored gene
         : stores a new gene
         : does not store if gene is unchanged.
 Example :
 Returns : 1 if succeeded
 Args    :
         : $gene to be stored (mandatory)
         :
         : $time_now is the time to be considered the current time.

=cut

sub store {
    my ($self, $gene, $time_now) = @_;

    $time_now ||= time;

    $gene->prune_Exons;

    unless ($gene) {
        throw("Must enter a Gene object to the store method");
    }
    unless ($gene->isa("Bio::Vega::Gene")) {
        throw("Object must be a Bio::Vega::Gene object. Currently [$gene]");
    }
    unless ($gene->gene_author) {
        throw("Bio::Vega::Gene must have a gene_author object set");
    }

    my $slice = $gene->slice;
    unless ($slice) {
        throw "gene does not have a slice attached to it, cannot store gene\n";
    }
    unless ($slice->coord_system) {
        throw("Coord System not set in gene slice \n");
    }
    unless ($gene->slice->adaptor) {
        my $sa = $self->db->get_SliceAdaptor();
        $gene->slice->adaptor($sa);
    }

    ### What's the point of an AnnotationBroker object at this level?
    my $broker = $self->db->get_AnnotationBroker();

    ## assign stable_ids for all new components at once:
    $broker->fetch_new_stable_ids_or_prefetch_latest_db_components($gene);

    my $gene_state;

    # first step: compare the components to their previous versions PLUS some side-effects
    # (set timestamps and versions, but do not update anything in the database)
    my ($any_changes, $seq_changes) = $broker->transcripts_diff($gene, $time_now);

    my $log_pattern = "%s %s.%d\n-------------------------------------------\n\n";

    if (my $db_gene = $gene->last_db_version()) {

        # the gene is not NEW,
        # so we either CHANGE, RESTORE (possibly changed), DELETE (possibly changed) or leave UNCHANGED

        # second step: since there was a previous version, it may have changed:
        $any_changes ||= compare($db_gene, $gene);

        $gene_state =
            $gene->is_current()
          ? $db_gene->is_current()
              ? $any_changes
                  ? 'CHANGED'
                  : 'UNCHANGED'
              : 'RESTORED'
          : 'DELETED';

        if ($gene_state eq 'UNCHANGED') {    # just leave as soon as possible
            printf STDERR $log_pattern, $gene_state, $db_gene->stable_id, $db_gene->version;
            return 0;
        }

        ###
        ##
        # Start of code where order is critical.
        # (sometimes we get the same gene object under $gene and $db_gene,
        #  but we want the code to behave in the same way as when they are different objects)
        ##
        ###

        # Add synonym if old gene name is not a current gene synonym
        # Commented out since it causes problems.  Synonyms are only added by nomenclature scripts.
        # $broker->compare_synonyms_add($db_gene, $gene);

        # mark the existing gene non-current:
        $db_gene->is_current(0);
        $self->update($db_gene);

        # transcripts cannot be shared between different versions of genes, so make them non-current, too:
        my $ta = $self->db->get_TranscriptAdaptor();
        foreach my $db_gene_tran (@{ $db_gene->get_all_Transcripts() }) {
            $db_gene_tran->is_current(0);
            $ta->update($db_gene_tran);
        }

        # # exons CAN be shared between different versions of genes, so update the non-currency of the deleted ones
        # # (assuming that exons are never shared between genes with different stable_ids. IS THAT TRUE ACTUALLY?)
        # my $ea      = $self->db->get_ExonAdaptor();
        # my %old_set = map { $_->stable_id => $_ } @{ $db_gene->get_all_Exons() };
        # my %new_set = map { $_->stable_id => $_ } @{    $gene->get_all_Exons() };
        # while (my ($stable_id, $db_gene_exon) = each %old_set) {
        #     unless ($new_set{$stable_id}) {
        #         $db_gene_exon->is_current(0);
        #         $ea->update($db_gene_exon);
        #     }
        # }
        # 
        # # also, update the non-currency of the changed exons (marked by AnnotationBroker) :
        # while (my ($stable_id, $gene_exon) = each %new_set) {
        #     my $db_exon = $gene_exon->last_db_version();
        #     if ($db_exon && !$db_exon->is_current()) {
        #         $ea->update($db_exon);
        #     }
        # }

        # If the gene is still associated with the last fetchable version,
        # (for example, if it is being DELETED or RESTORED)
        # it has to be dissociated from the DB to get a new set of dbIDs:
        if ($gene->dbID() && ($gene->dbID() == $db_gene->dbID())) {

            # if($gene->dbID()) {   # Dropped second condition to get repair_ko_gene_ott_ids script to work
            $gene->dissociate();
        }

        # If a gene is marked is non-current, we assume it was intended for deletion.
        # We also assume unsetting is_current() is the only thing needed to declare such intention.
        # So let's mark all of its' components for deletion as well:
        if ($gene_state eq 'DELETED') {
            $gene->biotype('obsolete');
            foreach my $del_tran (@{ $gene->get_all_Transcripts() }) {
                $del_tran->is_current(0);
                foreach my $del_exon (@{ $del_tran->get_all_Exons }) {
                    $del_exon->is_current(0);
                }
            }
        }
        else {

            # Otherwise make sure we haven't spoilt the original gene's is_current flags
            # if it was the same object as the db_gene:
            #
            foreach my $tran (@{ $gene->get_all_Transcripts() }) {
                $tran->is_current(1);
                foreach my $exon (@{ $tran->get_all_Exons }) {
                    $exon->is_current(1);
                }
            }
        }

        ###
        ##
        # End of code where order is critical
        ##
        ###

        $gene->version($db_gene->version() + $seq_changes);
        # CHANGED||RESTORED||DELETED will affect the author, so get a new version
        $gene->created_date($db_gene->created_date());

    }
    else {     # NEW or NEW_DELETED (happens during loading/migration) gene,
               # but may have inherited 'old' components (as a result of a split)

        $gene_state = 'NEW';

        $gene->version(1);
        $gene->created_date($time_now);

        my $current_flag = $gene->is_current();
        foreach my $obj (@{ $gene->get_all_Transcripts() }, @{ $gene->get_all_Exons }) {
            $obj->is_current($current_flag);
        }
    }
    $gene->modified_date($time_now);

    # Actually save the gene to the database
    $self->store_only($gene);

    printf STDERR $log_pattern, $gene_state, $gene->stable_id, $gene->version;
    return 1;
}

sub store_only {
    my ($self, $gene) = @_;

    # Here we assume that the parent method will update all is_current() fields,
    # trusting the values that we have just set.
    $self->SUPER::store($gene);

    ## Now store the gene author
    # (transcripts' authors and evidence has already been stored by TranscriptAdaptor::store )
    my $author_adaptor = $self->db->get_AuthorAdaptor;
    my $gene_author    = $gene->gene_author;
    $author_adaptor->store($gene_author);
    $author_adaptor->store_gene_author($gene->dbID, $gene_author->dbID);

    return;
}

sub db_gene_update_is_current { # change is_current for an existing gene and its components.
                                # NB DB only, DOES NOT UPDATE any in-memory transcript or exon objects
    my ($self, $db_gene, $is_current) = @_;

    $db_gene->is_current($is_current);
    $self->update($db_gene);

    my $ta = $self->db->get_TranscriptAdaptor();
    foreach my $db_gene_tran (@{ $db_gene->get_all_Transcripts() }) {
        $db_gene_tran->is_current($is_current);
        $ta->update($db_gene_tran);
    }
    
    my $ea = $self->db->get_ExonAdaptor();
    foreach my $db_gene_exon (@{ $db_gene->get_all_Exons() }) {
        $db_gene_exon->is_current($is_current);
        $ea->update($db_gene_exon);
    }
    
    return 1;
}

sub hide_db_gene {                # set an existing gene and its components to hidden (is_current = 0)
                                  # NB DB only, DOES NOT UPDATE any in-memory transcript or exon objects
    my ($self, $db_gene) = @_;
    return $self->db_gene_update_is_current($db_gene, 0);
}

sub unhide_db_gene {              # set an existing gene and its components to visible (is_current = 1)
                                  # NB DB only, DOES NOT UPDATE any in-memory transcript or exon objects
    my ($self, $db_gene) = @_;
    return $self->db_gene_update_is_current($db_gene, 1);
}

sub set_obsolete {    # set an existing gene to obsolete (non-current)
                      # code copied from the above store method
    my ($self, $gene) = @_;
    my $time_now = time;
    my $broker   = $self->db->get_AnnotationBroker();
    $broker->fetch_new_stable_ids_or_prefetch_latest_db_components($gene);

    if (my $db_gene = $gene->last_db_version()) {
        $self->hide_db_gene($db_gene);
        if ($gene->dbID() && ($gene->dbID() == $db_gene->dbID())) {
            $gene->dissociate();
        }
        $gene->is_current(0);
        $gene->biotype('obsolete');
        foreach my $del_tran (@{ $gene->get_all_Transcripts() }) {
            $del_tran->is_current(0);
        }
        foreach my $del_exon (@{ $gene->get_all_Exons }) {
            $del_exon->is_current(0);
        }
        $gene->version($db_gene->version());
        $gene->created_date($db_gene->created_date());

        $gene->modified_date($time_now);

        # Actually save the gene to the database
        $self->store_only($gene);

    }
    else {
        throw("Gene must be in the database\n");
    }

    return 1;
}

sub remove {
    my ($self, $gene) = @_;

    # Author
    if (my $author = $gene->gene_author) {
        $self->db->get_AuthorAdaptor->remove_gene_author($gene->dbID, $author->dbID);
    }

    $self->SUPER::remove($gene);

    return;
}

sub resurrect {    # make a particular gene current (without touching the previously current one)
    my ($self, $gene) = @_;

    my $ta = $self->db->get_TranscriptAdaptor;
    my $ea = $self->db->get_ExonAdaptor;

    $gene->is_current(1);
    $self->update($gene);
    foreach my $transcript (@{ $gene->get_all_Transcripts() }) {
        $transcript->is_current(1);
        $ta->update($transcript);
    }
    foreach my $exon (@{ $gene->get_all_Exons }) {
        $exon->is_current(1);
        $ea->update($exon);
    }

    return;
}

sub hibernate { # make a particular gene non-current (take care of shared exons)
    my ($self, $gene) = @_;

    my $ta = $self->db->get_TranscriptAdaptor;
    my $ea = $self->db->get_ExonAdaptor;

    $gene->is_current(0);
    $self->update($gene);
    foreach my $transcript (@{ $gene->get_all_Transcripts() }) {
        $transcript->is_current(0);
        $ta->update($transcript);
    }

    my $broker   = $self->db->get_AnnotationBroker();
    $broker->set_exon_current_flags([$gene]);

    return;
}

sub fetch_all_genes_on_reference_slice {

    #fka fetch_all_genes_on_ncbi_slice()
    # returns a list reference to loutre genes
    # converted to the coords of the specified assembly version
    # eg NCBI36 or GRCh37

    my ($self, $ncbi_chr, $otter_chr, $loutre_slice, $assembly) = @_;

    #  ncbi_chr, eg '22';        (num or x, y)
    #  otter_chr, eg, 'chr22-07' (sset name)

    my $mfetcher = Bio::Otter::MFetcher->new();

    $mfetcher->otter_dba($self->db);

    my $start = $loutre_slice->start;
    my $end   = $loutre_slice->end;

    my $transformed_genes = $mfetcher->fetch_and_export(
        'get_all_Genes', [ 'otter', undef, 1 ], 'chromosome', $ncbi_chr,
        $otter_chr, $start, $end, 'Otter',
        $assembly
    );

    #warn "Got ", scalar @$transformed_genes, " genes\n";
    #my $ncbi_slice = $transformed_genes->[0]->loutre_slice;

    return $transformed_genes;
}

1;

__END__

=head1 NAME - Bio::Vega::DBSQL::GeneAdaptor

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

