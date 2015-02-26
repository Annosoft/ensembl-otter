
## no critic (Modules::RequireFilenameMatchesPackage)

package Hum::Ace::SubSeq; # mix-in!

use strict;
use warnings;

use Carp;

use Hum::XmlWriter;

sub zmap_featureset_name {
    my ($self) = @_;
    # we need to prepend the prefix if our Locus has one
    my $prefix = '';
    if ($self->Locus and my $pre = $self->Locus->gene_type_prefix) {
        $prefix = "$pre:";
    }
    return $prefix.$self->GeneMethod->name;
}

sub zmap_delete_xml_string {
    my ($self, $offset) = @_;

    my $xml = Hum::XmlWriter->new;
    $xml->open_tag('featureset', {name => $self->zmap_featureset_name});
    $self->zmap_xml_feature_tag($xml, $offset);
    $xml->close_all_open_tags;
    return $xml->flush;
}

sub zmap_create_xml_string {
    my ($self, $offset) = @_;

    $offset ||= 0;

    ### featureset tag will require "align" and "block" attributes
    ### if there is more than one in the ZMap. Can probably be
    ### taken from the attached clone_Sequence.
    my $xml = Hum::XmlWriter->new;
    $xml->open_tag('featureset', {name => $self->zmap_featureset_name});
    $self->zmap_xml_feature_tag($xml, $offset);

    my @exons = $self->get_all_Exons
        or confess "No exons";
    for (my $i = 0; $i < @exons; $i++) {
        my $ex = $exons[$i];
        if ($i > 0) {
            # Set intron span from end of previous exon to start of current
            my $pex = $exons[$i - 1];
            $xml->full_tag('subfeature', {
                ontology    => 'intron',
                start       => $offset + $pex->end + 1,
                end         => $offset + $ex->start - 1,
            });
        }
        $xml->full_tag('subfeature', {
            ontology    => 'exon',
            start       => $offset + $ex->start,
            end         => $offset + $ex->end,
        });
    }

    my $is_pseudo = 0;
    if (my $meth = $self->GeneMethod) {
        # We set a CDS in pseudogene transcripts so that
        # it can be inspected in zmap.
        $is_pseudo = $meth->name =~ /pseudo/i;
    }
    if ($is_pseudo or $self->translation_region_is_set) {
        my @tr = $self->translation_region;
        $xml->full_tag('subfeature', {
            ontology    => 'cds',
            start       => $offset + $tr[0],
            end         => $offset + $tr[1],
        });
    }

    $xml->close_all_open_tags;
    return $xml->flush;
}

sub zmap_xml_feature_tag {
    my ($self, $xml, $offset) = @_;

    $offset ||= 0;

    #my $style = $self->GeneMethod->style_name;

    #print "XXX: gene method name: ".$self->GeneMethod->name."\n";
    #print "XXX: gene method style name: ".$self->GeneMethod->style_name."\n";

    # Not all transcripts have a locus.
    # eg: Predicted genes (Genscan, Augustus) don't.
    my @locus_prop;
    if (my $locus = $self->Locus) {
        #if (my $pre = $locus->gene_type_prefix) {
        #    $style = "$pre:$style";
        #}
        @locus_prop = (locus => $locus->name);
    }

    my $snf = $self->start_not_found;
    $xml->open_tag('feature', {
            name            => $self->name,
            start           => $offset + $self->start_untruncated,
            end             => $offset + $self->end_untruncated,
            strand          => $self->strand == -1 ? '-' : '+',
            #style           => $style, # XXX: we shouldn't need the style as this can be established from the featureset name
            start_not_found => $snf ? $snf : 'false',
            end_not_found   => $self->end_not_found ? 'true' : 'false',
            ontology        => 'Sequence',
            @locus_prop,
    });

    return;
}

sub zmap_transcript_info_xml {
    my ($self) = @_;

    my $xml = Hum::XmlWriter->new(7);
    # Otter stable ID and Author
    if ($self->otter_id or $self->author_name) {
        $xml->open_tag('paragraph', {type => 'tagvalue_table'});
        if (my $ott = $self->otter_id) {
            $xml->full_tag('tagvalue', {name => 'Transcript Stable ID', type => 'simple'}, $ott);
        }
        if (my $ott = $self->translation_otter_id) {
            $xml->full_tag('tagvalue', {name => 'Translation Stable ID', type => 'simple'}, $ott);
        }
        if (my $aut = $self->author_name) {
            $xml->full_tag('tagvalue', {name => 'Transcript author', type => 'simple'}, $aut);
        }
        $xml->close_tag;
    }

    # Subseq Remarks and Annotation remarks
    if ($self->list_remarks or $self->list_annotation_remarks) {
        $xml->open_tag('paragraph', {type => 'tagvalue_table'});
        foreach my $rem ($self->list_remarks) {
            $xml->full_tag('tagvalue', {name => 'Remark',            type => 'scrolled_text'}, $rem);
        }
        foreach my $rem ($self->list_annotation_remarks) {
            $xml->full_tag('tagvalue', {name => 'Annotation remark', type => 'scrolled_text'}, $rem);
        }
        $xml->close_tag;
    }

    # # Supporting evidence in tag-value list
    # if ($self->count_evidence) {
    #     $xml->open_tag('paragraph', {name => 'Evidence', type => 'tagvalue_table'});
    #     my $evi = $self->evidence_hash;
    #     foreach my $type (sort keys %$evi) {
    #         my $id_list = $evi->{$type};
    #         foreach my $name (@$id_list) {
    #             $xml->full_tag('tagvalue', {name => $type, type => 'simple'}, $name);
    #         }
    #     }
    #     $xml->close_tag;
    # }

    # Supporting evidence as a compound table
    if ($self->count_evidence) {
        $xml->open_tag('paragraph', {
            name => 'Evidence',
            type => 'compound_table',
            columns => q{'Type' 'Accession.SV'},
            column_types => q{string string},
            });
        my $evi = $self->evidence_hash;
        foreach my $type (sort keys %$evi) {
            my $id_list = $evi->{$type};
            foreach my $name (@$id_list) {
                my $str = sprintf "%s %s", $type, $name;
                $xml->full_tag('tagvalue', {type => 'compound'}, $str);
            }
        }
        $xml->close_tag;
    }
    return $xml->flush;
}

sub zmap_info_xml {
    my ($self) = @_;

    my $xml = Hum::XmlWriter->new(5);

    # We can add our info for ZMap into the "Feature" and "Annotation" subsections of the "Details" page.
    $xml->open_tag('page', {name => 'Details'});

    if (my $locus = $self->Locus) {
        # This Locus stuff might be better in Hum::Ace::Locus
        $xml->open_tag('subsection', {name => 'Locus'});

            $xml->open_tag('paragraph', {type => 'tagvalue_table'});

            # Locus Symbol, Alias and Full name
            $xml->full_tag('tagvalue', {name => 'Symbol', type => 'simple'}, $locus->name);
            foreach my $alias ($locus->list_aliases) {
                $xml->full_tag('tagvalue', {name => 'Alias', type => 'simple'}, $alias);
            }
            $xml->full_tag('tagvalue', {name => 'Full name', type => 'simple'}, $locus->description);

            # Otter stable ID and Author
            if (my $ott = $locus->otter_id) {
                $xml->full_tag('tagvalue', {name => 'Locus Stable ID', type => 'simple'}, $ott);
            }
            if (my $aut = $locus->author_name) {
                $xml->full_tag('tagvalue', {name => 'Locus author', type => 'simple'}, $aut);
            }

            # Locus Remarks and Annotation remarks
            foreach my $rem ($locus->list_remarks) {
                $xml->full_tag('tagvalue', {name => 'Remark',            type => 'scrolled_text'}, $rem);
            }
            foreach my $rem ($locus->list_annotation_remarks) {
                $xml->full_tag('tagvalue', {name => 'Annotation remark', type => 'scrolled_text'}, $rem);
            }

            $xml->close_tag;

        $xml->close_tag;
    }

    if (my $t_info_xml = $self->zmap_transcript_info_xml) {
        $xml->open_tag('subsection', {name => 'Annotation'});
        $xml->add_raw_data($t_info_xml);
        $xml->close_tag;
    }

    # Description field was added to the object for displaying DE_line info for Halfwise (Pfam) objects
    if (my $desc = $self->description) {
        $xml->open_tag('subsection', {name => 'Feature'});
        $xml->open_tag('paragraph', {type => 'tagvalue_table'});
        $xml->full_tag('tagvalue', {name => 'Description', type => 'scrolled_text'}, $desc);
        $xml->close_tag;
        $xml->close_tag;
    }

    $xml->close_tag;

    # Add our own page called "Exons"
    $xml->open_tag('page', {name => 'Exons'});
    $xml->open_tag('subsection');
    $xml->open_tag('paragraph', {
        type => 'compound_table',
        columns => q{'Start' 'End' 'Stable ID'},
        column_types => q{int int string},
        });
    my @ordered_exons = $self->get_all_Exons_in_transcript_order;
    foreach my $exon (@ordered_exons) {
        my @pos;
        if ($self->strand == 1) {
            @pos = ($exon->start, $exon->end);
        } else {
            @pos = ($exon->end, $exon->start);
        }
        my $str = sprintf "%d %d %s", @pos, $exon->otter_id || '-';
        $xml->full_tag('tagvalue', {type => 'compound'}, $str);
    }

    $xml->close_all_open_tags;
    return $xml->flush;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

