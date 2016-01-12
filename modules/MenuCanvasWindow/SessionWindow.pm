
package MenuCanvasWindow::SessionWindow;

use strict;
use warnings;

no if $] >= 5.018, warnings => "experimental::smartmatch";
use feature 'switch';

use Carp qw(longmess);
use Scalar::Util 'weaken';

use Try::Tiny;
use File::Path (); # for make_path;
use Readonly;

require Tk::Dialog;

use Hum::Ace::SubSeq;
use Bio::Otter::ZMap::XML::SubSeq; # mix-in for Hum::Ace::SubSeq
use Hum::Ace::Locus;
use Hum::Analysis::Factory::ExonLocator;
use Hum::Sort qw{ ace_sort };
use Hum::ClipboardUtils qw{ text_is_zmap_clip };
use Hum::XmlWriter;

use EditWindow::Dotter;
use EditWindow::Exonerate;
use EditWindow::LocusName;
use MenuCanvasWindow::TranscriptWindow;
use MenuCanvasWindow::GenomicFeaturesWindow;
use Text::Wrap qw{ wrap };

use Zircon::Context::ZMQ::Tk;
use Zircon::ZMap;

use Bio::Otter::Lace::Chooser::Item::Column;
use Bio::Otter::Lace::Client;
use Bio::Otter::RequestQueuer;
use Bio::Otter::UI::AboutBoxMixIn;
use Bio::Otter::Utils::CacheByName;
use Bio::Otter::Zircon::ProcessHits;
use Bio::Otter::ZMap::XML;
use Bio::Vega::Region::Ace;
use Bio::Vega::Transform::FromHumAce;
use Bio::Vega::Transform::XMLToRegion;
use Bio::Vega::CoordSystemFactory;

use Tk::ArrayBar;
use Tk::Screens;
use Tk::ScopedBusy;
use Bio::Vega::Utils::MacProxyConfig qw{ mac_os_x_set_proxy_vars };

use base qw{
    MenuCanvasWindow
    Bio::Otter::UI::ZMapSelectMixin
    Bio::Otter::Log::WithContextMixin
    };

my $PROT_SCORE = 100;
my $DNA_SCORE  = 100;
my $DNAHSP     = 120;

sub new {
    my ($pkg, $tk) = @_;

    my $self = $pkg->SUPER::new($tk);

    $self->zmap_select_initialize;

    $self->_populate_menus;
    $self->_make_status_panel;
    $self->_make_search_panel;
    $self->_bind_events;
    $self->minimum_scroll_bbox(0,0, 380,200);
    $self->_flag_db_edits(1);

    return $self;
}

# Populated from ColumnChooser before initialise,
# avoiding method name zmap_select (which is mixed in)
sub existing_zmap_select {
    my ($self, $zmap_select) = @_;
    $self->{_zmap} = $zmap_select;
    return;
}

sub AceDatabase {
    my ($self, $AceDatabase) = @_;

    if ($AceDatabase) {
        $self->{'_AceDatabase'} = $AceDatabase;
    }
    return $self->{'_AceDatabase'};
}

sub vega_dba {
    my ($self, @args) = @_;
    ($self->{'_vega_dba'}) = @args if @args; # not used?
    my $vega_dba = $self->{'_vega_dba'};
    unless ($vega_dba) {
        $self->logger->warn('Setting vega_dba implicitly from AceDatabase->DB');
        $vega_dba = $self->{'_vega_dba'} = $self->AceDatabase->DB->vega_dba;
    }
    return $vega_dba;
}

sub SequenceNotes {
    my ($self, $sn) = @_;

    if ($sn){
        $self->{'_sequence_notes'} = $sn ;
    }
    return $self->{'_sequence_notes'} ;
}


sub RequestQueuer {
    my ($self, @args) = @_;
    ($self->{'_RequestQueuer'}) = @args if @args;
    my $RequestQueuer = $self->{'_RequestQueuer'};
    return $RequestQueuer;
}

sub initialise {
    my ($self) = @_;

    $self->_set_window_title;
    $self->_colour_init;

    unless ($self->AceDatabase->write_access) {
        $self->menu_bar()->Label(
            -text       => 'Read Only',
            -foreground => 'red',
            -padx       => 6,
            )->pack(
                    -side => 'right',
                    );
    }

    $self->Assembly;

    # Drawing the sequence list can take a long time the first time it is
    # called (QC checks not yet cached), so do it before zmap is launched.
    $self->draw_subseq_list;

    $self->AceDatabase->zmap_dir_init;
    $self->_zmap_view_new($self->{'_zmap'});
    delete $self->{'_zmap'};

    $self->RequestQueuer(Bio::Otter::RequestQueuer->new($self));
    my $proc = $self->_process_hits_proc; # launches process_hits_proc, ready for action

    return;
}

sub _from_HumAce {
    my ($self, @args) = @_;

    my $_from_HumAce = $self->{'_from_HumAce'};
    return $_from_HumAce if $_from_HumAce;

     $_from_HumAce = $self->{'_from_HumAce'} = Bio::Vega::Transform::FromHumAce->new(
         session_slice => $self->AceDatabase->DB->session_slice,
         whole_slice   => $self->AceDatabase->DB->whole_slice,
         author        => $self->AceDatabase->Client->author,
         vega_dba      => $self->vega_dba,
         log_context   => $self->log_context,
         );
    return $_from_HumAce;
}

sub session_colour {
    my ($self) = @_;
    return $self->AceDatabase->colour || '#d9d9d9';
    # The non-coloured default would be '#d9d9d9'.  Using undef causes
    # non-drawing.  For a complete no-op, don't set any borderwidth
}

sub _colour_init {
    my ($self) = @_;
    return $self->colour_init($self->top_window);
}

# called by various windows, to set their widgets to our session_colour
sub colour_init {
    my ($self, $top, @widg) = @_;
    my $colour = $self->session_colour;
    my $tpath = $top->PathName;
    $top->configure(-borderwidth => 4, -background => $colour);
    foreach my $widg (@widg) {
        $widg = $top->Widget("$tpath.$widg") unless ref($widg);
        next unless $widg; # TranscriptWindow has some PathName parts
        $widg->configure(-background => $colour);
    }
    return;
}

sub default_log_context {
    my ($self) = @_;
    my $log_context;
    my $acedb = $self->AceDatabase;
    $log_context = $acedb->log_context if $acedb;
    return $log_context || '-no-acedb-';
}

sub _set_known_GeneMethods {
    my ($self) = @_;

    my $lst = $self->{'_gene_methods_list'} = [
        $self->Assembly->MethodCollection->get_all_transcript_Methods
        ];
    my $idx = $self->{'_gene_methods'} = {};
    %$idx = map {$_->name, $_} @$lst;

    return;
}

sub get_GeneMethod {
    my ($self, $name) = @_;

    my( $meth );
    unless ($meth = $self->{'_gene_methods'}{$name}) {
        $self->logger->logconfess("No such Method '$name'");
    }
    return $meth;
}

# unused
sub get_all_GeneMethods {
    my ($self) = @_;

    return @{$self->{'_gene_methods_list'}};
}

sub get_all_mutable_GeneMethods {
    my ($self) = @_;

    return $self->Assembly->MethodCollection->get_all_mutable_GeneMethods;
}

sub get_default_mutable_GeneMethod {
    my ($self) = @_;

    my @possible = grep { $_->coding } $self->get_all_mutable_GeneMethods;
    if (my ($supp) = grep { $_->name eq 'Coding' } @possible) {
        # "Coding" is the default method, if it is there
        return $supp;
    }
    elsif (@possible)  {
        return $possible[0];
    } else {
        $self->message("Unable to get a default GeneMethod");
        return;
    }
}

sub _locus_cache {
    my ($self) = @_;
    $self->{'_locus_cache'} //= Bio::Otter::Utils::CacheByName->new;
    return $self->{'_locus_cache'};
}

sub _empty_Locus_cache {
    my ($self) = @_;
    $self->{'_locus_cache'} = undef;
    return;
}

# For external callers only - internal should use $self->_locus_cache*->get() for now
sub get_Locus_by_name {
    my ($self, $name) = @_;
    return $self->_locus_cache->get($name);
}

sub list_Locus_names {
    my ($self) = @_;
    my @names = sort {lc $a cmp lc $b} $self->_locus_cache->names;
    return @names;
}

sub _update_Locus {
    my ($self, $new_locus) = @_;

    my $locus_name = $new_locus->name;

    $self->logger->debug('_update_Locus: caching new_locus ', $self->_debug_locus($new_locus));
    $self->_locus_cache->set($new_locus);

    foreach my $sub_name ($self->_subsequence_cache->names) {
        my $sub = $self->_subsequence_cache->get($sub_name) or next;
        my $old_locus = $sub->Locus or next;

        if ($old_locus->name eq $locus_name) {
            # Replace locus in subseq with new copy
            $self->logger->debug('_update_Locus: replacing locus for ', $self->_debug_subseq($sub));
            $sub->Locus($new_locus);

            # Is there a transcript window open?
            if (my $transcript_window = $self->_get_transcript_window($sub_name)) {
                $transcript_window->update_Locus($new_locus);
            }
        }
    }

    return;
}

# FIXME - move to Locus->compare ??
sub _compare_loci {
    my ($self, $old, $new) = @_;
    return $self->_compare_fields(
        $old, $new,
        {
            strings => [ qw{
                name
                description
                gene_type_prefix
                otter_id
                } ],
                # author_name replaced on server
            booleans => [ qw{
                is_truncated
                known
                } ],
            lists => [ qw{
                list_aliases
                list_remarks
                list_annotation_remarks
                } ],
        },
        );
}

sub _compare_subseqs {
    my ($self, $old, $new) = @_;
    my $diffs = $self->_compare_fields(
        $old, $new,
        {
            strings => [ qw{
                name
                description
                otter_id
                translation_otter_id
                strand
                start_not_found
                } ],
                # author_name replaced on server
            booleans => [ qw{
                utr_start_not_found
                end_not_found
                } ],
            lists => [ qw{
                list_remarks
                list_annotation_remarks
                } ],
            specials => [ qw{
                _compare_GeneMethods
                _compare_translation_region
                _compare_exons
                _compare_evidence
                _compare_locus_dbID
                } ],
        },
        );

    return $diffs;
}

sub _compare_GeneMethods {
    my ($self, $diffs, $old, $new) = @_;
    return $self->_compare_strings($diffs, 'GeneMethod',
                                   $old->GeneMethod->name,
                                   $new->GeneMethod->name);
}

sub _compare_translation_region {
    my ($self, $diffs, $old, $new) = @_;
    my ($o_start, $o_end) = $old->translation_region;
    my ($n_start, $n_end) = $new->translation_region;
    $self->_compare_strings($diffs, 'translation_start', $o_start, $n_start);
    $self->_compare_strings($diffs, 'translation_end',   $o_end,   $n_end);
    return;
}

sub _compare_strings {
    my ($self, $diffs, $field_name, $old, $new) = @_;
    my $o = $old // '<undef>';
    my $n = $new // '<undef>';
    unless ($o eq $n) {
        $diffs->{$field_name} = [$old, $new, $o, $n];
    }
    return;
}

sub _compare_exons {
    my ($self, $diffs, $old, $new) = @_;

    my @o_exons = $old->get_all_Exons;
    my @n_exons = $new->get_all_Exons;

    if ($#o_exons != $#n_exons) {
        my $len_o = scalar @o_exons;
        my $len_n = scalar @n_exons;
        $diffs->{exons} = [\@o_exons, \@n_exons, "length:$len_o", "length:$len_n"];
        return;
    }

    my %e_diffs;
    for (my $i = 0; $i < @o_exons; $i++) {
        $self->_compare_exon(\%e_diffs, $i, $o_exons[$i], $n_exons[$i]);
    }
    if (%e_diffs) {
        my @reports = map { sprintf('%s:%s', $_, $e_diffs{$_}) } sort keys %e_diffs;
        my $report = join(';', @reports);
        $diffs->{exons} = [\@o_exons, \@n_exons, $report, "-"];
    }
    return;
}

sub _compare_evidence {
    my ($self, $diffs, $old, $new) = @_;

    my $o_evi = $old->evidence_hash;
    my $n_evi = $new->evidence_hash;

    my $o = $self->_evi_string($o_evi);
    my $n = $self->_evi_string($n_evi);
    unless ($o eq $n) {
        $diffs->{'evidence'} = [$o_evi, $n_evi, $o, $n];
    }
    return;
}

sub _compare_locus_dbID {
    my ($self, $diffs, $old, $new) = @_;
    return $self->_compare_strings($diffs, 'Locus->ensembl_dbID',
                                   $old->Locus->ensembl_dbID,
                                   $new->Locus->ensembl_dbID);
}

sub _evi_string {
    my ($self, $evi_hash) = @_;
    my @type_strings;
    foreach my $type (sort keys %$evi_hash) {
        my $ev_list = $evi_hash->{$type};
        push @type_strings, join("\n", map { "$type:$_" } sort @$ev_list);
    }
    return join("\n", @type_strings);
}

sub _compare_exon {
    my ($self, $diffs, $index, $old, $new) = @_;
    my $result = $self->_compare_fields(
        $old, $new,
        {
            strings => [ qw{
                    start
                    end
                    phase
                    otter_id
                }],
        }
        );
    return unless $result;

    my @explain;
    foreach my $f (sort keys %$result) {
        my ($of, $nf, $o, $n) = @{$result->{$f}};
        push @explain, "$f:$o=>$n";
    }
    $diffs->{$index} = join(',', @explain);
    return;
}

sub _compare_fields {
    my ($self, $old, $new, $spec) = @_;

    my %diffs;

    # Could use ace_strings but results are finer-grained this way.

    foreach my $field (@{$spec->{strings} // []})
    {
        $self->_compare_strings(\%diffs, $field, $old->$field, $new->$field);
    }

    foreach my $field (@{$spec->{booleans} // []})
    {
        my $of = $old->$field;
        my $nf = $new->$field;
        my $o = $of ? 'true' : 'false';
        my $n = $nf ? 'true' : 'false';
        unless ($o eq $n) {
            $diffs{$field} = [$of, $nf, $o, $n];
        }
    }

    foreach my $field (@{$spec->{lists} // []})
    {
        my @of = $old->$field;
        my @nf = $new->$field;
        my $o = join(',', @of);
        my $n = join(',', @nf);
        unless ($o eq $n) {
            $diffs{$field} = [\@of, \@nf, $o, $n];
        }
    }

    foreach my $comp_sub (@{$spec->{specials} // []})
    {
        $self->$comp_sub(\%diffs, $old, $new);
    }

    return unless keys %diffs;
    return \%diffs;
}

sub _log_diffs {
    my ($self, $diffs, $name) = @_;
    my $diff_str = '';
    while (my ($k, $v) = each(%$diffs)) {
        my ($of, $nf, $o, $n) = @$v;
        $diff_str .= sprintf("\n\t%s:\t%s\t=> %s", $k, $o, $n);
    }
    $self->logger->debug(sprintf("Diffs for '%s':%s", $name, $diff_str));
    return;
}

# FIXME - move to Locus->new_from_otter_Locus, if still here once we're done ??
sub _copy_locus {
    my ($self, $locus) = @_;
    my $copy = $locus->new_from_Locus($locus);
    foreach my $method (qw{
        otter_id
        known
        previous_name
        })
    {
        $copy->$method($locus->$method);
    }
    $copy->set_annotation_remarks($locus->list_annotation_remarks);
    return $copy;
}

sub do_rename_locus {
    my ($self, $old_name, $new_name) = @_;

    my %done; # we update in three places - keep track
    return try {
        my @delete_xml;
        my $offset = $self->AceDatabase->offset;
        foreach my $subseq ($self->_fetch_SubSeqs_by_locus_name($old_name)) {
            push @delete_xml, $subseq->zmap_delete_xml_string($offset);
        }

        if ($self->_locus_cache->get($new_name)) {
            $self->message("Cannot rename to '$new_name'; Locus already exists");
            return 0;
        }

        my $old_locus = $self->_locus_cache->delete($old_name);
        unless ($old_locus) {
            die "Cannot find locus called '$old_name' in sqlite cache";
        }
        my $new_locus = $self->_copy_locus($old_locus);
        $new_locus->name($new_name);
        $self->_locus_cache->set($new_locus);
        foreach my $subseq ($self->_fetch_SubSeqs_by_locus_name($old_name)) {
            $subseq->Locus($new_locus);
        }
        $done{'int'} = 1;

        # Need to deal with gene type prefix, in case the rename
        # involves a prefix being added, removed or changed.
        if (my ($pre) = $new_name =~ /^([^:]+):/) {
            $new_locus->gene_type_prefix($pre);
        } else {
            $new_locus->gene_type_prefix('');
        }

        # Now we need to update ZMap with the new locus names
        my @create_xml;
        foreach my $subseq ($self->_fetch_SubSeqs_by_locus_name($new_name)) {
            push @create_xml, $subseq->zmap_create_xml_string($offset);
        }

        my $vega_dba = $self->vega_dba;
        try {
            $vega_dba->begin_work;
            $self->_from_HumAce->update_Gene($new_locus, $old_locus);
            $vega_dba->commit;
            $done{'sqlite'} = 1;
            $self->_mark_unsaved;
        }
        catch {
            my $err = $_;
            $vega_dba->rollback;
            $vega_dba->clear_caches;
            die "Saving to SQLite: $err";
        };

        my $zmap = $self->zmap;
        foreach my $del (@delete_xml) {
            $zmap->send_command_and_xml('delete_feature', $del);
        }
        foreach my $cre (@create_xml) {
            $zmap->send_command_and_xml('create_feature', $cre);
        }
        $done{'zmap'} = 1;

        return 1;
    }
    catch {
        # breakage, probably a partial update.
        # explain, return true to close the window.
        my $err = $_;
        my $msg;
        $err ||= 'unknown error';
        if ($done{'sqlite'}) {
            # haven't told ZMap, reload it from Ace
            $msg = "Renamed OK but sync failed, please restart ZMap";
        } elsif ($done{'ace'}) {
            # bailed out on sqlite
            $msg = "Renamed in Ace but failed in SQLite";
        } elsif ($done{'int'}) {
            # haven't told Ace, so Otter state is wrong
            $msg = "Rename failed, please restart Otter";
        } else {
            $msg = "Could not rename";
        }
        $self->exception_message($err, "$msg\nwhile renaming locus '$old_name' to '$new_name'");
        return -1;
    }
}

sub _fetch_SubSeqs_by_locus_name {
   my ($self, $locus_name) = @_;

   my @list;
   foreach my $name ($self->_subsequence_cache->names) {
       my $sub = $self->_subsequence_cache->get($name) or next;
       my $locus = $sub->Locus or next;
       if ($locus->name eq $locus_name) {
           push(@list, $sub);
       }
   }
   return @list;
}


#------------------------------------------------------------------------------------------

sub _populate_menus {
    my ($self) = @_;

    my $top = $self->top_window;

    # File menu
    my $file = $self->make_menu('File');

    # Save annotations to otter
    my $save_command = sub {
        unless ($self->_close_all_edit_windows) {
            $self->message('Not saving because some editing windows are still open');
            return;
        }
        $self->_save_data;
        };
    $file->add('command',
        -label          => 'Save',
        -command        => $save_command,
        -accelerator    => 'Ctrl+S',
        -underline      => 0,
        );
    $top->bind('<Control-s>', $save_command);
    $top->bind('<Control-S>', $save_command);

    # Resync with database
    my $resync_command = sub { $self->_resync_with_db };
    $file->add('command',
        -label          => 'Resync',
        -hidemargin     => 1,
        -command        => $resync_command,
        -accelerator    => 'Ctrl+R',
        -underline      => 0,
        );
    $top->bind('<Control-r>', $resync_command);
    $top->bind('<Control-R>', $resync_command);

    # Debug options: get (current!) session directory name
    my $debug_menu = $file->Menu(-tearoff => 0);
    $file->add('cascade', -menu => $debug_menu,
               -label => 'Debug', -underline => 0);
    $debug_menu->add('command',
                     -label => 'About session',
                     -underline => 1,
                     -command => sub { $self->_show_about_session });
    $debug_menu->add('command',
                     -label => 'Copy directory name to selection',
                     -underline => 5,
                     -command => sub { $self->_clipboard_setup(0) });
    $debug_menu->add('command',
                     -label => 'Copy host:directory to selection',
                     -underline => 5,
                     -command => sub { $self->_clipboard_setup(1) });

    # Close window
    my $exit_command = $self->bind_WM_DELETE_WINDOW('_delete_window');
    $file->add('command',
        -label          => 'Close',
        -command        => $exit_command,
        -accelerator    => 'Ctrl+W',
        -underline      => 0,
        );
    $top->bind('<Control-w>', $exit_command);
    $top->bind('<Control-W>', $exit_command);

    # Subseq menu
    my $subseq = $self->make_menu('SubSeq', 1);

    # Edit subsequence
    my $edit_command = sub{
        $self->_edit_selected_subsequences;
        };
    $subseq->add('command',
        -label          => 'Edit',
        -command        => $edit_command,
        -accelerator    => 'Ctrl+E',
        -underline      => 0,
        );
    $top->bind('<Control-e>', $edit_command);
    $top->bind('<Control-E>', $edit_command);

    # Close all open subseq windows
    my $close_subseq_command = sub{
        $self->_close_all_transcript_windows;
        };
    $subseq->add('command',
        -label          => 'Close all',
        -command        => $close_subseq_command,
        -accelerator    => 'F4',
        -underline      => 0,
        );
    $top->bind('<F4>', $close_subseq_command);
    $top->bind('<F4>', $close_subseq_command);

    # Copy selected subseqs to holding pen
    my $copy_subseq = sub{
        $self->_copy_selected_subseqs;
        };
    $subseq->add('command',
        -label          => 'Copy',
        -command        => $copy_subseq,
        -accelerator    => 'Ctrl+C',
        -underline      => 0,
        );
    $top->bind('<Control-c>', $copy_subseq);
    $top->bind('<Control-C>', $copy_subseq);

    # Paste selected subseqs, realigning them to the genomic sequence
    my $paste_subseq = sub{
        try { $self->_paste_selected_subseqs; }
        catch { $self->exception_message($_); };
    };
    $subseq->add('command',
        -label          => 'Paste',
        -command        => $paste_subseq,
        -accelerator    => 'Ctrl+V',
        -underline      => 0,
        );
    $top->bind('<Control-v>', $paste_subseq);
    $top->bind('<Control-V>', $paste_subseq);

    #  --- Separator ---
    $subseq->add('separator');

    # New subsequence
    my $new_command = sub{
        $self->_edit_new_subsequence;
        };
    $subseq->add('command',
        -label          => 'New',
        -command        => $new_command,
        -accelerator    => 'Ctrl+N',
        -underline      => 0,
        );
    $top->bind('<Control-n>', $new_command);
    $top->bind('<Control-N>', $new_command);

    # Make a variant of the current selected sequence
    my $variant_command = sub{
        $self->_make_variant_subsequence;
        };
    $subseq->add('command',
        -label          => 'Variant',
        -command        => $variant_command,
        -accelerator    => 'Ctrl+I',
        -underline      => 2,
        );
    $top->bind('<Control-i>', $variant_command);
    $top->bind('<Control-I>', $variant_command);

    # Delete subsequence
    my $delete_command = sub {
        $self->_delete_subsequences;
        };
    $subseq->add('command',
        -label          => 'Delete',
        -command        => $delete_command,
        -accelerator    => 'Ctrl+D',
        -underline      => 0,
        );
    $top->bind('<Control-d>', $delete_command);
    $top->bind('<Control-D>', $delete_command);

    my $tools_menu = $self->make_menu("Tools");

    # Genomic Features editing window
    my $gf_command = sub { $self->_launch_GenomicFeaturesWindow };
    $tools_menu->add('command' ,
        -label          => 'Genomic Features',
        -command        => $gf_command,
        -accelerator    => 'Ctrl+G',
        -underline      => 0,
    );
    $top->bind('<Control-g>', $gf_command);
    $top->bind('<Control-G>', $gf_command);

    ## Spawn dotter Ctrl .
    my $run_dotter_command = sub { $self->_run_dotter };
    $tools_menu->add('command',
        -label          => 'Dotter ZMap hit',
        -command        => $run_dotter_command,
        -accelerator    => 'Ctrl+.',
        -underline      => 0,
        );
    $top->bind('<Control-period>',  $run_dotter_command);
    $top->bind('<Control-greater>', $run_dotter_command);

    ## Spawn exonerate Ctrl .
    my $run_exon_command = sub { $self->run_exonerate };
    $tools_menu->add('command',
        -label          => 'On The Fly (OTF) Alignment',
        -command        => $run_exon_command,
        -accelerator    => 'Ctrl+X',
        -underline      => 0,
        );
    $top->bind('<Control-x>', $run_exon_command);
    $top->bind('<Control-X>', $run_exon_command);

    # Show dialog for renaming the locus attached to this subseq
    my $rename_locus = sub { $self->rename_locus };
    $tools_menu->add('command',
        -label          => 'Rename locus',
        -command        => $rename_locus,
        -accelerator    => 'Ctrl+Shift+L',
        -underline      => 1,
        );
    $top->bind('<Control-Shift-L>', $rename_locus);


    # Show dialog for renaming the locus attached to this subseq
    my $re_authorize = sub { $self->AceDatabase->Client->do_authentication; };
    $tools_menu->add('command',
        -label          => 'Re-authorize',
        -command        => $re_authorize,
        -accelerator    => 'Ctrl+Shift+A',
        -underline      => 3,
        );
    $top->bind('<Control-Shift-A>', $re_authorize);

    $tools_menu->add('command',
               -label          => 'Load column data',
               -command        => sub {$self->_show_column_chooser()},
    );

    # launch in ZMap
    my $relaunch_zmap = sub { return $self->_zmap_relaunch };
    $tools_menu->add
      ('command',
       -label          => 'Relaunch ZMap',
       -command        => $relaunch_zmap,
       -accelerator    => 'Ctrl+L',
       -underline      => 2,
      );
     $top->bind('<Control-l>', $relaunch_zmap);

    # select ZMap
    $tools_menu->add
      ('command',
       -label          => 'Select ZMap',
       -command        => sub { $self->zmap_select_window },
       -underline      => 0,
      );

    # Show selected subsequence in ZMap
    my $_show_subseq = [ $self, '_show_subseq' ];
    $tools_menu->add
      ('command',
       -label          => 'Hunt in ZMap',
       -command        => $_show_subseq,
       -accelerator    => 'Ctrl+H',
       -underline      => 0,
      );
    $top->bind('<Control-h>',   $_show_subseq);
    $top->bind('<Control-H>',   $_show_subseq);

    $subseq->bind('<Destroy>', sub{
        $self = undef;
    });

    return;
}

sub _delete_window {
    my ($self) = @_;
    $self->_exit_save_data or return;
    $self->_delete_zmap_view;
    $self->_shutdown_process_hits_proc;
    $self->ColumnChooser->top_window->destroy;
    return 1;
}

sub ColumnChooser {
    my ($self, $lc) = @_;

    $self->{'_ColumnChooser'} = $lc if $lc;

    return $self->{'_ColumnChooser'};
}

sub _show_column_chooser {
    my ($self) = @_;

    my $cc = $self->ColumnChooser;
    my $top = $cc->top_window;
    $top->deiconify;
    $top->raise;

    return;
}

sub _show_subseq {
    my ($self) = @_;

    my @subseq = $self->_list_selected_subseq_objs;
    if (1 == @subseq) {
        my $success = $self->zmap->zoom_to_subseq($subseq[0]);
        $self->message("ZMap: zoom to subsequence failed") unless $success;
    } else {
        $self->message("Zoom to subsequence requires a selection of one item");
    }

    return;
}

sub _bind_events {
    my ($self) = @_;

    my $canvas = $self->canvas;

    $canvas->Tk::bind('<Button-1>', [
        sub{ $self->_left_button_handler(@_); },
        Tk::Ev('x'), Tk::Ev('y') ]);
    $canvas->Tk::bind('<Shift-Button-1>', [
        sub{ $self->_shift_left_button_handler(@_); },
        Tk::Ev('x'), Tk::Ev('y') ]);
    $canvas->Tk::bind('<Double-Button-1>', [
        sub{
            $self->_left_button_handler(@_);
            $self->_edit_double_clicked;
            },
        Tk::Ev('x'), Tk::Ev('y') ]);

    $canvas->Tk::bind('<Escape>',   sub{ $self->deselect_all        });
    $canvas->Tk::bind('<Return>',   sub{ $self->_edit_double_clicked });
    $canvas->Tk::bind('<KP_Enter>', sub{ $self->_edit_double_clicked });

    # Clipboard
    $canvas->SelectionHandle( sub{ $self->selected_text_to_clipboard(@_) });

    # Object won't get DESTROY'd without:
    $canvas->Tk::bind('<Destroy>', sub{
        $self = undef;
        });

    return;
}

sub highlight {
    my ($self, @args) = @_;

    $self->SUPER::highlight(@args);

    my $canvas = $self->canvas;
    $canvas->SelectionOwn(
        -command    => sub{ $self->deselect_all; },
    );
    weaken $self;

    return;
}

sub _GenomicFeaturesWindow {
    my ($self) = @_;
    return $self->{'_GenomicFeaturesWindow'}; # set in _launch_GenomicFeaturesWindow
}

sub _launch_GenomicFeaturesWindow {
    my ($self) = @_;
    try {
        my $gfs = MenuCanvasWindow::GenomicFeaturesWindow->init_or_reuse_Toplevel
          (# -title is set during initialise
           { reuse_ref => \$self->{'_GenomicFeaturesWindow'},
             raise => 1,
             init => { SessionWindow => $self },
             from => $self->canvas });
    }
    catch {
        my $msg = 'Error creating Genomic Features window';
        $self->exception_message($_, $msg);
    };

    return;
}

sub _close_GenomicFeaturesWindow {
    my ($self) = @_;

    if(my $gfs = $self->_GenomicFeaturesWindow()) {
        $gfs->try2save_and_quit();
    }

    return;
}

{
    my( @holding_pen );

    sub _copy_selected_subseqs {
        my ($self) = @_;

        # Empty holding pen
        @holding_pen = ();

        my @select = $self->list_selected_subseq_names;
        unless (@select) {
            $self->message('Nothing selected');
            return;
        }
        foreach my $name (@select) {
            my $sub = $self->_subsequence_cache->get($name)->clone;
            push(@holding_pen, $sub);
        }

        return;
    }

    sub _paste_selected_subseqs {
        my ($self) = @_;

        unless (@holding_pen) {
            $self->message('No SubSequences on clipboard');
            return;
        }

        my $assembly = $self->Assembly;

        # The ExonLocator finds exons in a genomic sequence
        my $finder = Hum::Analysis::Factory::ExonLocator->new;
        $finder->genomic_Sequence($assembly->Sequence);

        my (@msg, @new_subseq);
        foreach my $sub (@holding_pen) {
            my $name = $sub->name;
            my ($new_exons, $strand) = @{_new_exons_strand($finder, $sub)};
            if (@{$new_exons}) {
                my $new = $sub->clone;
                my $temp_name;
                for (my $i=0; !defined $temp_name || $self->_subsequence_cache->get($temp_name); $i++) {
                    $temp_name = $sub->name;
                    $temp_name .= "_$i" if $i; # invalid-dup suffix when needed
                }
                $new->name($temp_name);
                $new->strand($strand);
                $new->replace_all_Exons(@{$new_exons});
                $new->clone_Sequence($assembly->Sequence);
                $assembly->add_SubSeq($new);
                if ($sub->translation_region_is_set) {
                    try {
                        $new->set_translation_region_from_cds_coords($sub->cds_coords);
                    }
                    catch {
                        push(@msg, "Failed to set translation region - check translation of '$temp_name'");
                        $new->translation_region($new->start, $new->end);
                    };
                }
                my $paste_locus = $self->_paste_locus($sub->Locus);
                $new->Locus($paste_locus);
                $self->_add_SubSeq($new);
                push(@new_subseq, $new);
                $self->logger->info("Internal paste result:\n", $new->ace_string);
            } else {
                $self->message("Got zero exons from realigning '$name'");
            }
        }

        $self->draw_subseq_list;
        $self->_highlight_by_name(map { $_->name } @new_subseq);
        $self->message(@msg) if @msg;
        foreach my $new (@new_subseq) {
            $self->_make_transcript_window($new);
        }

        return;
    }
}

sub _new_exons_strand {
    # not a method
    my ($finder, $sub) = @_;
    my $exon_seq = $sub->exon_Sequence_array;
    my $fs = $finder->find_best_Feature_set($exon_seq);
    my @exons = $sub->get_all_Exons;
    my( $strand, @new_exons );
    for (my $i = 0; $i < @exons; $i++) {
        my $feat = $fs->[$i] or next;
        my $ex = Hum::Ace::Exon->new;
        $ex->start($feat->seq_start);
        $ex->end($feat->seq_end);
        $strand ||= $feat->seq_strand;
        push(@new_exons, $ex);
    }
    return [ \@new_exons, $strand ];
}

sub _paste_locus {
    my ($self, $source_locus) = @_;
    # similar to (Hum::Ace::Locus)->new_from_Locus
    my $dup_locus = Hum::Ace::Locus->new;
    $dup_locus->set_aliases( $source_locus->list_aliases );
    $dup_locus->set_remarks( $source_locus->list_remarks );
    $dup_locus->set_annotation_remarks( $source_locus->list_annotation_remarks );
    # we don't copy otter_id (this is copy-paste, not cut-paste) or
    # author_name (will be replaced)
    foreach my $method (qw( name description gene_type_prefix known )) {
        $dup_locus->$method( $source_locus->$method );
    }
    $dup_locus->set_annotation_in_progress;
    # return either the locus we already have with the same name, or
    # put $dup_locus in the cache and use that
    return $self->_locus_cache->get_or_this($dup_locus);
}


sub _exit_save_data {
    my ($self) = @_;

    my $adb = $self->AceDatabase;
    my $dir = $self->_session_path;
    unless ($adb->write_access) {
        $adb->error_flag(0);
        $self->_close_GenomicFeaturesWindow;   ### Why is this special?
        my $changed = $self->AceDatabase->unsaved_changes;
        $changed = 'not set' unless defined $changed;
        $self->logger->info("Closing $dir (no write access, changed = $changed)");
        return 1;
    }

    $self->_close_all_edit_windows or return;

    if (my @loci = $self->Assembly->get_all_annotation_in_progress_Loci) {

        # Format the text for the dialog
        my $loci_str = join('', map {sprintf "\t%s\n", $_->name} @loci);
        my $loci_phrase = @loci > 1 ? 'loci are'    : 'locus is';
        my $flag_phrase = @loci > 1 ? 'these flags' : 'this flag';
        my $what_phrase = @loci > 1 ? 'their'       : 'its';
        my $txt = "The following $loci_phrase flagged with 'annotation in progress':\n$loci_str"
            . "Is $what_phrase annotation now complete? Answering 'Yes' will remove $flag_phrase and save to otter";

        my $dialog = $self->top_window()->Dialog(
            -title          => $Bio::Otter::Lace::Client::PFX.'Annotation complete?',
            -bitmap         => 'question',
            -text           => $txt,
            -default_button => 'No',
            -buttons        => [qw{ Yes No Cancel }],
            );
        $self->delete_window_dialog($dialog);
        my $ans = $dialog->Show;
        if ($ans eq 'Cancel') {
            return;
        }
        elsif ($ans eq 'Yes') {
            foreach my $locus (@loci) {
                $locus->unset_annotation_in_progress;
                $self->_update_Locus($locus);
            }

            my $vega_dba = $self->vega_dba;
            try {
                $vega_dba->begin_work;
                foreach my $locus (@loci) {
                    $self->_from_HumAce->update_Gene($locus, $locus);
                }
                $vega_dba->commit;
                $self->_mark_unsaved;
                return 1;
            }
            catch {
                $self->logger->error("Aborting session exit (SQLite):\n$_"); return 0;
            }
            or return;

            if ($self->_save_data) {
                $adb->error_flag(0);
                $self->logger->info("Closing $dir (saved data, annotation is complete)");
                return 1;
            }
            else {
                return;
            }
        }
    }

    if ($self->AceDatabase->unsaved_changes) {
        # Ask the user if any changes should be saved
        my $dialog = $self->top_window()->Dialog(
            -title          => $Bio::Otter::Lace::Client::PFX.'Save?',
            -bitmap         => 'question',
            -text           => "Save any changes to otter server?",
            -default_button => 'Yes',
            -buttons        => [qw{ Yes No Cancel }],
            );
        my $ans = $dialog->Show;

        if ($ans eq 'Cancel') {
            return;
        }
        elsif ($ans eq 'Yes') {
            # Return false if there is a problem saving
            $self->_save_data or return;
            $self->logger->info("Closing $dir (saved data)");
        } else {
            $self->logger->info("Closing $dir (Save = $ans)");
        }
    } else {
        $self->logger->info("Closing $dir (nothing to save)");
    }

    # Unsetting the error_flag means that AceDatabase
    # will remove its directory during DESTROY.
    $adb->error_flag(0);

    return 1;
}

sub _close_all_edit_windows {
    my ($self) = @_;

    $self->_close_all_transcript_windows or return;
    $self->_close_GenomicFeaturesWindow;
    return 1;
}

sub _save_data {
    my ($self) = @_;

    my $adb = $self->AceDatabase;

    unless ($adb->write_access) {
        $self->message("Read only session - not saving");
        return 1;   # Can't save - but is OK
    }
    my $top = $self->top_window();

    $top->Busy;

    my $xml_out = $adb->generate_XML_from_sqlite;
    $adb->write_file('Out.xml', $xml_out);

    return try {
        my $xml = $adb->Client->save_otter_xml
          ($xml_out,
           $adb->DataSet->name,
           $adb->fetch_lock_token);
        die "save_otter_xml returned no XML" unless $xml;

        my $parser = Bio::Vega::Transform::XMLToRegion->new;
        $parser->analysis_from_transcript_class(1);
        $parser->coord_system_factory(Bio::Vega::CoordSystemFactory->new);
        my $region = $parser->parse($xml);

        $adb->unsaved_changes(0);
        $self->_flag_db_edits(0);    # or the save will set unsaved_changes back to "1"
        $self->_save_region_updates($region);
        $self->_flag_db_edits(1);
        $self->_resync_with_db;

        $self->_set_window_title;
        return 1;
    }
    catch { $self->exception_message($_, 'Error saving to otter'); return 0; }
    finally { $top->Unbusy; };
}

sub _save_region_updates {
    my ($self, $new_region) = @_;

    my $ace_maker = Bio::Vega::Region::Ace->new;
    my $new_assembly = $ace_maker->make_assembly(
        $new_region,
        {
            name             => $self->slice_name,
            MethodCollection => $self->AceDatabase->MethodCollection, # FIXME: Where will this come from?
        }
        );

    foreach my $new_subseq ($new_assembly->get_all_SubSeqs) {
        next unless $new_subseq->is_mutable;

        my $name = $new_subseq->name;
        my $old_subseq = $self->_subsequence_cache->get($name);
        $old_subseq or die "Cannot find existing subseq for $name";

        $self->_replace_SubSeq_sqlite($new_subseq, $old_subseq);
    }

    # Nothing new should come back for sequence features

    return;
}

sub _edit_double_clicked {
    my ($self) = @_;

    return unless $self->list_selected;

    $self->_edit_selected_subsequences;

    return;
}

sub _left_button_handler {
    my ($self, $canvas, $x, $y) = @_;

    return if $self->delete_message;

    $self->deselect_all;
    if (my ($obj) = $canvas->find('withtag', 'current')) {
        $self->highlight($obj);
    }

    return;
}

sub _shift_left_button_handler {
    my ($self, $canvas, $x, $y) = @_;

    return if $self->delete_message;

    if (my ($obj) = $canvas->find('withtag', 'current')) {
        if ($self->is_selected($obj)) {
            $self->remove_selected($obj);
        } else {
            $self->highlight($obj);
        }
    }

    return;
}

Readonly my @display_statuses =>
    qw( Selected Queued Loading Processing HitsQueued HitsProcess Visible Hidden Empty Error );

sub _make_status_panel {
    my ($self) = @_;

    my $status_colors = Bio::Otter::Lace::Chooser::Item::Column->STATUS_COLORS_HASHREF();
    my @colors = map { $status_colors->{$_}->[1] } @display_statuses;

    my $top = $self->top_window();
    my $status_frame = $top->Frame(Name => 'status_frame', -borderwidth => 2);
    my @status_text = @display_statuses;
    $self->{_status_text} = \@status_text;

    $status_frame->pack(
        -side => 'top',
        -fill => 'x',
        );

    my $status_bar = $status_frame->ArrayBar(
        -width => 20,
        -colors => \@colors,
        -labels =>  $self->{_status_text},
        -balloon => $self->balloon,
        );
    $status_bar->pack(
        -side => 'top',
        -fill => 'x',
        );

    $status_bar->value((0) x @display_statuses);

    $self->_status_bar($status_bar);
    return;
}

sub update_status_bar {
    my ($self) = @_;
    my $cllctn = $self->AceDatabase->ColumnCollection;
    my $counts = $cllctn->count_Columns_by_status;
    my @values = @$counts{@display_statuses};
    @{ $self->{_status_text} } = map {my $v = $$counts{$_} // 0; "$_ ($v)"} @display_statuses;
    $self->_status_bar->value(@values);
    return;
}

sub _status_bar {
    my ($self, @args) = @_;
    ($self->{'_status_bar'}) = @args if @args;
    my $_status_bar = $self->{'_status_bar'};
    return $_status_bar;
}

sub _make_search_panel {
    my ($self) = @_;

    my $top = $self->top_window();
    my $frame = $top->Frame(
        -borderwidth    => 2,
        )->pack(-side => 'top', -fill => 'x');
    my $search_frame = $frame->Frame->pack(-side => 'top');

    my @button_pack = qw{ -side left -padx 2 };

    my $search_box = $search_frame->Entry(
        -width => 22,
        );
    $search_box->pack(@button_pack);

    # Is hunting in CanvasWindow?
    my $hunter = sub{
        my $busy = Tk::ScopedBusy->new($top);
        $self->_do_search($search_box);
    };
    my $button = $search_frame->Button(
         -text      => 'Find',
         -command   => $hunter,
         -underline => 0,
         )->pack(@button_pack);

    my $clear_command = sub {
        $search_box->delete(0, 'end');
        };
    my $clear = $search_frame->Button(
        -text      => 'Clear',
        -command   => $clear_command,
        -underline => 2,
        )->pack(@button_pack);
    $top->bind('<Control-e>',   $clear_command);
    $top->bind('<Control-E>',   $clear_command);

    $search_box->bind('<Return>',   $hunter);
    $search_box->bind('<KP_Enter>', $hunter);
    $top->bind('<Control-f>',       $hunter);
    $top->bind('<Control-F>',       $hunter);

    $button->bind('<Destroy>', sub{
        $self = undef;
        });

    return;
}


sub _do_search {
    my ($self, $search_box) = @_;

    # Searches for the text given in the supplied Entry in
    # the acedb string representation of all the subsequences.

    my $query_str = $search_box->get;
    my $regex = _search_regex($query_str);
    return unless $regex;

    $self->canvas->delete('msg');
    $self->deselect_all();

    my @matching_sub_names;
    my @ace_fail_names;
    foreach my $name ($self->_subsequence_cache->names) {
        my $sub = $self->_subsequence_cache->get($name) or next;
        try {
            push @matching_sub_names, $name
                if $sub->ace_string =~ /$regex/;
        }
        catch {
            # Data outside our control may break Hum::Ace::SubSeq  RT:188195, 189606
            $self->logger->warn(sprintf "%s::_do_search(): $name: $_", __PACKAGE__);
            push @ace_fail_names, $name;
            # It could be a real error, not just some broken data.
            # We'll mention that if there are no results.
        };
    }

    my $query_str_stripped = $query_str; # for RT#379216
    $query_str_stripped =~ s{[\x00-\x1F\x7F-\xFF]+}{ }g; # remove non-printing
    $query_str_stripped =~ s{^\s+|\s+$}{}g; # remove leading & trailing space
    $query_str_stripped =~ s{ +}{ }g; # collapse remaining space

    if (@matching_sub_names) {
        # highlight the hits
        $self->_highlight_by_name(@matching_sub_names);
        # also report any errors
        if (@ace_fail_names) {
            $self->message("Search: I also saw some errors while searching.  Search for 'wibble' to highlight those.");
        }
    }
    elsif (@ace_fail_names) {
        # highlight the errors
        $self->_highlight_by_name(@ace_fail_names);
    }
    elsif ($query_str ne $query_str_stripped) {
        $self->message("Can't find '$query_str'\nStripped non-printing characters from\nsearch term, please try again");
        $search_box->delete(0, 'end');
        $search_box->insert(0, $query_str_stripped);
    }
    else {
        $self->message("Can't find '$query_str'");
    }

    return;
}

sub _search_regex {
    # not a method
    my ($query_str) = @_;
    $query_str =~ s{([^\w\*\?\\])}{\\$1}g;
    $query_str =~ s{\*}{.*}g;
    $query_str =~ s{\?}{.}g;
    return unless $query_str;
    my $regex;
    try { $regex = qr/($query_str)/i; }; # catch syntax errors
    return $regex;
}

sub _session_path {
    my ($self) = @_;

    return $self->AceDatabase->home;
}

sub _mark_unsaved {
    my ($self) = @_;
    if ($self->_flag_db_edits) {
        $self->AceDatabase->unsaved_changes(1);
        $self->_set_window_title;
    }
    return;
}

sub _flag_db_edits {
    my ($self, $flag) = @_;

    if (defined $flag) {
        $self->{'_flag_db_edits'} = $flag ? 1 : 0;
    }
    return $self->{'_flag_db_edits'};
}

sub _resync_with_db {
    my ($self) = @_;


    unless ($self->_close_all_edit_windows) {
        $self->message("All editor windows must be closed before a ReSync");
        return;
    }

    my $busy = Tk::ScopedBusy->new($self->canvas, -recurse => 0);

    $self->_empty_Assembly_cache;
    $self->_empty_SubSeq_cache;
    $self->_empty_Locus_cache;

    $self->AceDatabase->DB->vega_dba->clear_caches; # Is an AceDatabase function required?

    # Refetch transcripts
    $self->Assembly;

    my @visible_columns = $self->AceDatabase->ColumnCollection->list_Columns_with_status('Visible');
    $self->_process_and_update_columns(@visible_columns);
    $self->update_status_bar;

    return;
}


sub _show_about_session {
    my ($self) = @_;

    # Regenerate each time, as ZMap may have changed
    my $adb    = $self->AceDatabase;
    my $home   = $adb->home;
    my $sqlite = $adb->DB->file;

    my $zmap_session_dir    = $adb->zmap_dir;
    my $zmap_session_config = sprintf('%s/%s', $zmap_session_dir, 'ZMap');

    my $zmap_process_dir    = $self->{'_zmap_config_dir'};
    my $zmap_process_config = sprintf('%s/%s', $zmap_process_dir, 'ZMap');

    my $content = <<"__TEXT";
Session:
  directory:   $home
  SQLite:      $sqlite
  ZMap dir:    $zmap_session_dir
    config:    $zmap_session_config

ZMap process:
  directory:   $zmap_process_dir
  config:      $zmap_process_config
__TEXT

    $self->{'_about_session'} = $self->Bio::Otter::UI::AboutBoxMixIn::make_box('About session', $content, 1);
    $self->{'_about_session'}->Show;

    return;
}

sub _clipboard_setup {
    my ($self, $with_host) = @_;
    # use toplevel to hold selection, else we need an invisible widget

    $self->top_window->SelectionHandle(''); # clear old
    $self->top_window->SelectionHandle(sub { $self->_clipboard_contents($with_host, @_) });
    $self->top_window->SelectionOwn();
    return ();
}

sub _clipboard_contents {
    my ($self, $with_host, $offset, $maxlen) = @_;
    my $host = $self->AceDatabase->Client->client_hostname;
    my $txt = $self->AceDatabase->home;
    $txt = "$host:$txt" if $with_host;
    return substr($txt, $offset, $maxlen); # substr per selection handler spec
}


sub slice_name {
    my ($self) = @_;
    return $self->{_slice_name} ||=
        $self->AceDatabase->slice_name;
}

sub _edit_selected_subsequences {
    my ($self) = @_;
    $self->_edit_subsequences($self->list_selected_subseq_names);
    return;
}

sub _edit_subsequences {
    my ($self, @sub_names) = @_;

    my $busy = Tk::ScopedBusy->new($self->canvas);
    my $retval = 1;

    foreach my $sub_name (@sub_names) {
        # Just show the edit window if present
        next if $self->_raise_transcript_window($sub_name);

        # Get a copy of the subseq
        if (my $sub = $self->_subsequence_cache->get($sub_name)) {
            my $edit = $sub->clone;
            $edit->otter_id($sub->otter_id);
            $edit->translation_otter_id($sub->translation_otter_id);
            $edit->ensembl_dbID($sub->ensembl_dbID);
            $edit->locus_level_errors($sub->locus_level_errors);

            $self->_make_transcript_window($edit);
        } else {
            $self->logger->warn("Failed to _subsequence_cache->get($sub_name)");
            $retval = 0;
        }
    }

    return $retval;
}

sub _default_locus_prefix {
    my ($self) = @_;
    return $self->{_default_locus_prefix} ||=
        $self->_get_default_locus_prefix;
}

sub _get_default_locus_prefix {
    my ($self) = @_;
    my $client = $self->AceDatabase->Client;
    return $client->config_value('gene_type_prefix') || '';
}

sub _edit_new_subsequence {
    my ($self) = @_;

    my @subseq = $self->_list_selected_subseq_objs;
    my $clip      = $self->get_clipboard_text || '';

    my ($new_subseq);
    if (@subseq) {
        $new_subseq = Hum::Ace::SubSeq->new_from_subseq_list(@subseq);
    }
    else {
        # $self->logger->warn("CLIPBOARD: $clip");
        $new_subseq = Hum::Ace::SubSeq->new_from_clipboard_text($clip);
        unless ($new_subseq) {
            $self->message("Need a highlighted transcript or a coordinate on the clipboard to make SubSeq");
            return;
        }
        $new_subseq->clone_Sequence($self->Assembly->Sequence);
    }

    my ($region_name, $max) = $self->_region_name_and_next_locus_number($new_subseq);

    my $prefix = $self->_default_locus_prefix;
    my $loc_name = $prefix ? "$prefix:$region_name.$max" : "$region_name.$max";

    my $seq_name = "$loc_name-001";

    # Check we don't already have a sequence of this name
    if ($self->_subsequence_cache->get($seq_name)) {
        # Should be impossible, I hope!
        $self->message("Tried to make new SubSequence name but already have SubSeq named '$seq_name'");
        return;
    }

    my $locus_constructor = sub {
        my ($name) = @_;
        my $new_locus = Hum::Ace::Locus->new;
        $new_locus->name($name);
        return $new_locus;
    };

    my $locus = $self->_locus_cache->get_or_new($loc_name, $locus_constructor);
    $locus->gene_type_prefix($prefix);

    $new_subseq->name($seq_name);
    $new_subseq->Locus($locus);
    my $gm = $self->get_default_mutable_GeneMethod or $self->logger->logconfess("No default mutable GeneMethod");
    $new_subseq->GeneMethod($gm);
    # Need to initialise translation region for coding transcripts
    if ($gm->coding) {
        $new_subseq->translation_region($new_subseq->translation_region);
    }

    $self->Assembly->add_SubSeq($new_subseq);
    $self->_add_SubSeq($new_subseq);

    $self->_add_SubSeq_window_and_paste_evidence($new_subseq, $clip);

    return;
}

sub _region_name_and_next_locus_number {
    my ($self, $new) = @_;

    my $most_3prime = $new->strand == 1 ? $new->end : $new->start;

    my $assembly = $self->Assembly;
    # Check that our coordinate is not off the end of the assembly
    if ($most_3prime && ($most_3prime < 0 || $most_3prime > $assembly->Sequence->sequence_length)) {
        $most_3prime = undef;
    }
    my $region_name = $most_3prime
        ? $assembly->clone_name_overlapping($most_3prime)
        : $assembly->name;
    $self->logger->info("Looking for clone overlapping '$most_3prime' found '$region_name'");

    # Trim sequence version from accession if clone_name ends .SV
    $region_name =~ s/\.\d+$//;

    # Now get the maximum locus number for this root
    my $regex = qr{^(?:[^:]+:)?$region_name\.(\d+)}; # qr is a Perl 5.6 feature
    my $max = 0;
    foreach my $sub ($assembly->get_all_SubSeqs) {
        my ($n) = $sub->name =~ /$regex/;
        if ($n && $n > $max) {
            $max = $n;
        }
    }
    $max++;

    return ($region_name, $max);
}

sub _make_variant_subsequence {
    my ($self) = @_;

    my $clip      = $self->get_clipboard_text || '';
    my @sub_names = $self->list_selected_subseq_names;
    unless (@sub_names) {
        @sub_names = $self->_list_was_selected_subseq_names;
    }

    # $self->logger->info("Got subseq names: (@sub_names)");
    unless (@sub_names) {
        $self->message("No subsequence selected");
        return;
    }
    elsif (@sub_names > 1) {
        $self->message("Can't make a variant from more than one selected sequence");
        return;
    }
    my $name = $sub_names[0];
    my $assembly = $self->Assembly;

    # Work out a name for the new variant
    my $var_name = $name;
    if ($var_name =~ s/-(\d{3,})$//) {
        my $root = $var_name;

        # Now get the maximum variant number for this root
        my $regex = qr{^$root-(\d{3,})$};
        my $max = 0;
        foreach my $sub ($assembly->get_all_SubSeqs) {
            my ($n) = $sub->name =~ /$regex/;
            if ($n && $n > $max) {
                $max = $n;
            }
        }

        $var_name = sprintf "%s-%03d", $root, $max + 1;

        # Check we don't already have the variant we are trying to create
        if ($self->_subsequence_cache->get($var_name)) {
            $self->message("Tried to create variant '$var_name', but it already exists! (Should be impossible)");
            return;
        }
    } else {
        $self->message(
            "SubSequence name '$name' is not in the expected format " .
            "(ending with a dash followed by three or more digits).",
            "Perhaps you want to use the \"New\" funtion instead?",
            );
        return;
    }

    my $clip_sub;
    if (text_is_zmap_clip($clip)) {
        $clip_sub = Hum::Ace::SubSeq->new_from_clipboard_text($clip);
    }

    # Make the variants
    my $variant = $self->_make_variant($self->_subsequence_cache->get($name), $var_name, $clip_sub);
    $self->Assembly->add_SubSeq($variant);
    $self->_add_SubSeq($variant);

    $self->_add_SubSeq_window_and_paste_evidence($variant, $clip);

    return;
}

sub _make_variant {
    my ($self, $base_subseq, $var_name, $clip_subseq) = @_;

    my $var = $base_subseq->clone;
    $var->name($var_name);
    $var->empty_evidence_hash;
    $var->empty_remarks;
    $var->empty_annotation_remarks;

    if ($clip_subseq) {
        $var->replace_all_Exons($clip_subseq->get_all_Exons);
    }

    return $var;
}

sub _add_SubSeq_window_and_paste_evidence {
    my ($self, $sub, $clip) = @_;

#    $self->Assembly_x->add_SubSeq($sub);
#    $self->_add_SubSeq_x($sub);

    $self->draw_subseq_list;
    $self->_highlight_by_name($sub->name);

    my $transcript_window = $self->_make_transcript_window($sub);
    $transcript_window->merge_position_pairs;  # Useful if multiple overlapping evidence selected
    $transcript_window->EvidencePaster->add_evidence_from_text($clip);

    return;
}

# These only need go in the master db
sub _add_external_SubSeqs {
    my ($self, @ext_subs) = @_;

    # Subsequences from ZMap gff which are not in acedb database
    my $asm = $self->Assembly;
    my $dna = $asm->Sequence;
    foreach my $sub (@ext_subs) {
        if (my $ext = $self->_subsequence_cache->get($sub->name)) {
            if ($ext->GeneMethod->name eq $sub->GeneMethod->name) {
                # Looks zmap has been restarted, which has
                # triggered a reload of this data.
                next;
            }
            else {
                $self->logger->logconfess(
                    sprintf("External transcript '%s' from '%s' has same name as transcript from '%s'\n",
                            $sub->name, $sub->GeneMethod->name, $ext->GeneMethod->name));
            }
        }
        $sub->clone_Sequence($dna);
        $asm->add_SubSeq($sub);
        $self->_add_SubSeq($sub);
    }

    return;
}

# Does hits and transcripts for now - will separate later
#
sub _process_and_update_columns {
    my ($self, @columns) = @_;

    my (@alignment_cols, @transcript_cols, @other_cols);

    foreach my $col ( @columns ) {
        for (my $ct = $col->Filter->content_type) {
            $ct //= '';
            when ($ct eq 'alignment_feature' and $col->process_gff) { push @alignment_cols,  $col; }
            when ($ct eq 'transcript'                             ) { push @transcript_cols, $col; }
            default                                                 { push @other_cols,      $col; }
        }
    }

    if (@alignment_cols) {
        $self->_process_hits_proc->process_columns(@alignment_cols);
    }

    if (@transcript_cols) {

        my $transcript_result = $self->AceDatabase->process_transcript_Columns(@transcript_cols);
        my ($transcripts, $failed) = @{$transcript_result}{qw( -results -failed )};

        if ($transcripts and @$transcripts) {
            $self->_add_external_SubSeqs(@{$transcripts});
            $self->draw_subseq_list;
        }

        if ($failed and @$failed) {
            my $message = sprintf
                'Failed to load any transcripts from column(s): %s', join ', ', sort map { $_->name } @{$failed};
            $self->message($message);
        }
    }

    foreach my $col ( @transcript_cols, @other_cols ) {
        $self->_update_column_status($col, 'Visible');
    }

    return;
}

sub _processed_column {
    my ($self, $column) = @_;
    $self->logger->debug("_processed_column for '", $column->name, "'");
    # Unset flag so that we don't reprocess this file if we recover the session.
    $column->process_gff(0);
    $self->_update_column_status($column, 'Visible');
    return;
}

sub _update_column_status {
    my ($self, $column, $status) = @_;
    my $col_aptr = $self->AceDatabase->DB->ColumnAdaptor;
    $column->status($status);
    $col_aptr->store_Column_state($column);
    $self->update_status_bar;
    return;
}

sub _process_hits_proc {
    my ($self) = @_;
    my $_process_hits_proc = $self->{'_process_hits_proc'};
    unless ($_process_hits_proc) {

        my $core_script_args = $self->AceDatabase->core_script_arguments;
        my @arg_list = map { sprintf('%s=%s', $_, $core_script_args->{$_}) } keys %$core_script_args;

        my $proc = Bio::Otter::Zircon::ProcessHits->new(
            '-app_id'             => $self->_zircon_app_id,
            '-context'            => $self->_new_zircon_context('PHO'),
            '-arg_list'           => \@arg_list,
            '-session_window'     => $self,
            '-processed_callback' => \&_processed_column,
            '-update_callback'    => \&_update_column_status,
            '-log_context'        => $self->AceDatabase->log_context,
            $self->_zircon_timeouts,
            );
        $_process_hits_proc = $self->{'_process_hits_proc'} = $proc;
    }
    return $_process_hits_proc;
}

sub _shutdown_process_hits_proc {
    my ($self) = @_;
    delete $self->{'_process_hits_proc'}; # should trigger shutdown via DESTROY
    return;
}

sub _delete_subsequences {
    my ($self) = @_;

    # Make a list of editable SubSeqs from those selected,
    # which we are therefore allowed to delete.
    my @sub_names = $self->list_selected_subseq_names;

    my @to_die;

    foreach my $sub_name (@sub_names) {
        my $subseq = $self->_subsequence_cache->get($sub_name);
        if ($subseq->GeneMethod->mutable) {
            push(@to_die, $subseq);
        }
    }
    return unless @to_die;

    # Check that none of the sequences to be deleted are being edited
    my $in_edit = 0;
    foreach my $subseq (@to_die) {
        $in_edit += $self->_raise_transcript_window($subseq->name);
    }
    if ($in_edit) {
        $self->message("Must close edit windows before calling delete");
        return;
    }

    # Check that the user really wants to delete them
    my( $question );
    if (@to_die > 1) {
        $question = join('',
            "Really delete these transcripts?\n\n",
            map { "  $_\n" } map { $_->name } @to_die
            );
    } else {
        $question = "Really delete this transcript?\n\n  "
            . $to_die[0]->name ."\n";
    }
    my $dialog = $self->top_window()->Dialog(
        -title          => $Bio::Otter::Lace::Client::PFX.'Delete Transcripts?',
        -bitmap         => 'question',
        -text           => $question,
        -default_button => 'Yes',
        -buttons        => [qw{ Yes No }],
        );
    my $ans = $dialog->Show;

    return if $ans eq 'No';

    my $offset = $self->AceDatabase->offset;
    my @xml;

    # delete from sqlite
    my $vega_dba = $self->vega_dba;
    my $from_HumAce = $self->_from_HumAce;
    try {
        $vega_dba->begin_work;

        foreach my $sub_sqlite (@to_die) {
            if ($sub_sqlite->ensembl_dbID) {
                $from_HumAce->remove_Transcript($sub_sqlite);
                $self->logger->debug('Deleting transcript for: ', $self->_debug_subseq($sub_sqlite));
                # FIXME: check location of this cf. original version:
                push @xml, $sub_sqlite->zmap_delete_xml_string($offset);
            } else {
                $self->logger->warn('Do not have transcript to delete for: ', $self->_debug_subseq($sub_sqlite));
            }
        }

        $vega_dba->commit;
        $self->_mark_unsaved;
        return 1;
    }
    catch {
        $self->exception_message($_, 'Aborted delete, failed to save to SQLite');
        return 0;
    } or return;

    # Remove from our objects
    foreach my $sub_sqlite (@to_die) {
        $self->_delete_SubSeq($sub_sqlite);
    }

    $self->draw_subseq_list;

    # delete from ZMap
    try {
        foreach my $del (@xml) {
            $self->zmap->send_command_and_xml('delete_feature', $del);
        }
        return 1;
    }
    catch {
        $self->exception_message($_, 'Deleted OK, but please restart ZMap');
        return 0;
    }
    or return;

    return;
}

sub _make_transcript_window {
    my ($self, $sub) = @_;

    $self->logger->debug('Making transcript_window for: ', $self->_debug_subseq($sub));

    my $sub_name = $sub->name;
    my $canvas = $self->canvas;

    # Make a new window
    my $top = $canvas->Toplevel;

    # Make new MenuCanvasWindow::TranscriptWindow object and initialise
    my $transcript_window = MenuCanvasWindow::TranscriptWindow->new($top, 345, 50);
    $transcript_window->name($sub_name);
    $transcript_window->SessionWindow($self);
    $transcript_window->SubSeq($sub);
    $transcript_window->initialise;

    $self->_save_transcript_window($sub_name, $transcript_window);

    return $transcript_window;
}

sub _debug_subseq {
    my ($self, $subseq) = @_;
    return sprintf('%s, locus %s', $self->_debug_hum_ace($subseq), $self->_debug_hum_ace($subseq->Locus));
}

sub _debug_locus {
    my ($self, $locus) = @_;
    return $self->_debug_hum_ace($locus);
}

sub _debug_hum_ace {
    my ($self, $object) = @_;
    $object or return '<<undef>>';

    my $ref    = $object + 0;
    my $name   = $object->name // '<undef>';
    my $ens_id = $object->ensembl_dbID // '<undef>';
    return sprintf("[%x] '%s' (%s)", $ref, $name, $ens_id);
}

sub _raise_transcript_window {
    my ($self, $name) = @_;

    $self->logger->logconfess("no name given") unless $name;

    if (my $transcript_window = $self->_get_transcript_window($name)) {
        my $top = $transcript_window->canvas->toplevel;
        $top->deiconify;
        $top->raise;
        return 1;
    } else {
        return 0;
    }
}

sub _get_transcript_window {
    my ($self, $name) = @_;

    return $self->{'_transcript_window'}{$name};
}

sub _list_all_transcript_window_names {
    my ($self) = @_;

    return keys %{$self->{'_transcript_window'}};
}

sub _save_transcript_window {
    my ($self, $name, $transcript_window) = @_;

    $self->{'_transcript_window'}{$name} = $transcript_window;
    weaken($self->{'_transcript_window'}{$name});

    return;
}

sub _delete_transcript_window {
    my ($self, $name) = @_;

    delete($self->{'_transcript_window'}{$name});

    return;
}

sub _rename_transcript_window {
    my ($self, $old_name, $new_name) = @_;

    my $transcript_window = $self->_get_transcript_window($old_name)
        or return;
    $self->_delete_transcript_window($old_name);
    $self->_save_transcript_window($new_name, $transcript_window);

    return;
}

sub _close_all_transcript_windows {
    my ($self) = @_;

    foreach my $name ($self->_list_all_transcript_window_names) {
        my $transcript_window = $self->_get_transcript_window($name) or next;
        $transcript_window->window_close or return 0;
    }

    return 1;
}

sub draw_subseq_list {
    my ($self) = @_;

    my $canvas = $self->canvas;

    my $slist = [];
    my $counter = 1;
    foreach my $clust ($self->_get_all_Subseq_clusters) {
        push(@$slist, "") if @$slist;
        push(@$slist, @$clust);
    }

    $self->_draw_sequence_list($slist);
    $self->fix_window_min_max_sizes;

    return;
}

sub _get_all_Subseq_clusters {
    my ($self) = @_;

    my $assembly = $self->Assembly;
    my @subseq = sort {
           $a->start  <=> $b->start
        || $a->end    <=> $b->end
        || $a->strand <=> $b->strand
        } $assembly->get_all_SubSeqs;
    my $first = $subseq[0] or return;
    my( @clust );
    my $ci = 0;
    $clust[$ci] = [$first];
    my $x      = $first->start;
    my $y      = $first->end;
    my $strand = $first->strand;
    for (my $i = 1; $i < @subseq; $i++) {
        my $this = $subseq[$i];
        if ($this->strand == $strand
            && $this->start <= $y
            && $this->end   >= $x)
        {
            push(@{$clust[$ci]}, $this);
            $x = $this->start if $this->start < $x;
            $y = $this->end   if $this->end   > $y;
        } else {
            $ci++;
            $clust[$ci] = [$this];
            $x      = $this->start;
            $y      = $this->end;
            $strand = $this->strand;
        }
    }

    foreach my $c (@clust) {
        $c = [sort { ace_sort($a->name, $b->name) } @$c];
    }

    @clust = sort {$a->[0]->start <=> $b->[0]->start} @clust;

    return @clust;
}

sub Assembly {
    my ($self) = @_;
    my $assembly = $self->_assembly_sqlite;
    unless ($assembly) {
        $assembly = $self->_load_Assembly_sqlite;
    }
    return $assembly;
}

sub _assembly_sqlite {
    my ($self, @args) = @_;
    ($self->{'_assembly_sqlite'}) = @args if @args;
    my $_assembly_sqlite = $self->{'_assembly_sqlite'};
    return $_assembly_sqlite;
}

sub _empty_Assembly_cache {
    my ($self) = @_;

    $self->{'_assembly_sqlite'} = undef;

    return;
}

sub _load_Assembly_sqlite {
    my ($self) = @_;

    my $canvas = $self->canvas;
    my $slice_name = $self->slice_name;

    my $before = time();
    my $busy = Tk::ScopedBusy->new($canvas, -recurse => 0);

    my $assembly;

    try {
        $assembly = $self->AceDatabase->fetch_assembly;
        return 1;
    }
    catch {
        $self->exception_message($_, "Can't fetch Assembly '$slice_name' from SQLite");
        return 0;
    }
    or return;

    $self->_assembly_sqlite($assembly);

    $self->_set_SubSeqs_from_assembly;
    $self->_set_known_GeneMethods;

    my $after  = time();
    $self->logger->info(sprintf("SQLite fetch for '%s' took %d second(s)\n", $slice_name, $after - $before));

    return $assembly;
}

sub _set_SubSeqs_from_assembly {
    my ($self) = @_;

    foreach my $sub ($self->Assembly->get_all_SubSeqs) {
        $self->_add_SubSeq($sub);

        # Ignore loci from non-editable SubSeqs
        next unless $sub->is_mutable;
        if (my $s_loc = $sub->Locus) {
            my $locus = $self->_locus_cache->get_or_this($s_loc);
            $sub->Locus($locus);
            $self->logger->debug(sprintf('Setting locus %s for subseq %s',
                                         $self->_debug_hum_ace($locus), $self->_debug_hum_ace($sub)));
        }
    }

    return;
}


# "perlcritic --stern" refuses to learn that $logger->logdie is fatal
sub save_Assembly { ## no critic (Subroutines::RequireFinalReturn)
    my ($self, $new) = @_;

    my ($delete_xml, $create_xml) = Bio::Otter::ZMap::XML::update_SimpleFeatures_xml(
        $self->Assembly, $new, $self->AceDatabase->offset);

    my ($done_sqlite, $err);
    my $done_zmap = try {

        $self->_save_simplefeatures($new);
        $done_sqlite = 1;

        if ($delete_xml) {
            $self->zmap->send_command_and_xml('delete_feature', $delete_xml);
        }
        if ($create_xml) {
            $self->zmap->send_command_and_xml('create_feature', $create_xml);
        }
        return 1;
    }
    catch {
        $err = $_;
        return;
    };

    # Set internal state only if we saved OK
    if ($done_sqlite) {
        $self->Assembly->set_SimpleFeature_list($new->get_all_SimpleFeatures);
    }

    if ($done_zmap) {
        # all OK
        return;
    } else {
        my $msg;
        if ($done_sqlite) {
            $msg = "Saved OK, but please restart ZMap";
        } else {
            $msg = "Aborted save, failed to save to Ace";
        }

        # Where to put error message?
        # MenuCanvasWindow::GenomicFeaturesWindow doesn't display the
        # exception_message, it is covered by widgets
        #
        # Yellow note goes on the session window, somewhat invisible
        $self->exception_message($err, $msg);
        # Exception box goes to Bio::Otter::Error / Tk::Error
        $self->logger->logdie($msg);
    }
}

sub _save_simplefeatures {
    my ($self, $new_assembly) = @_;

    my $vega_dba = $self->vega_dba;
    my $from_HumAce = $self->_from_HumAce;

    try {
        $vega_dba->begin_work;

        foreach my $method ($new_assembly->MethodCollection->get_all_mutable_non_transcript_Methods) {
            $from_HumAce->remove_SimpleFeatures($method->name);
        }

        my @features = $new_assembly->get_all_SimpleFeatures;
        $self->logger->debug("Going to save ", scalar(@features), " features");
        foreach my $sf (@features) {
            $from_HumAce->store_SimpleFeature($sf);
        }

        $vega_dba->commit;
        $self->_mark_unsaved;
    }
    catch {
        my $err = $_;
        $vega_dba->rollback;
        $vega_dba->clear_caches;

        die "_save_simplefeatures: $err";
    };

    return;
}

# Used by OTF
#
sub delete_featuresets {
    my ($self, @types) = @_;

    foreach my $type ( @types ) {
        # we delete types seperately because zmap errors out without
        # deleting anything if any featureset does not currently exist
        # in the zmap window
        try {
            $self->zmap->delete_featuresets($type);
        }
        catch {
            $self->logger->warn($_);
        };
    }

    return;
}

sub replace_SubSeq {
    my ($self, $new, $old) = @_;

    my ($done_sqlite, $done_zmap, $err) = $self->_replace_SubSeq_sqlite($new, $old);

    if ($done_sqlite) {
        my $new_name = $new->name;
        my $old_name = $old->name || $new_name;
        $self->_rename_transcript_window($old_name, $new_name);
    }

    if ($done_zmap) {
        # all OK
        return 1;
    }
    else {
        my $msg;
        if ($done_sqlite) {
            $msg = "Saved to SQLite OK, but please restart ZMap";
        }
        else {
            $msg = "Aborted save, failed to save to SQLite";
        }
        $self->exception_message($err, $msg);
        return $done_sqlite;
    }
}

sub _replace_SubSeq_sqlite {
    my ($self, $new_subseq, $old_subseq) = @_;

    $self->logger->debug(sprintf("_replace_SubSeq_sqlite:\n new: %s\n old: %s",
                                 $self->_debug_subseq($new_subseq), $self->_debug_subseq($old_subseq)));

    my $new_subseq_name = $new_subseq->name;
    my $old_subseq_name = $old_subseq->name || $new_subseq_name;

    my $new_locus = $new_subseq->Locus;
    my $old_locus = $old_subseq->Locus;

    my $new_locus_name = $new_locus->name;
    my $old_locus_name = $old_locus->name || $new_locus_name;
    my $locus_tag  = "Locus $new_locus_name for SubSeq $new_subseq_name";

    my $prev_locus;
    if ($old_locus_name ne $new_locus_name) {
        $self->logger->debug("Changing sqlite locus, '$old_locus_name' => '$new_locus_name'");

        if (my $prev_locus_name = $new_locus->drop_previous_name) {

            $prev_locus = $self->_locus_cache->get($prev_locus_name);
            unless ($prev_locus) {
                $self->logger->logconfess("Cannot find cached sqlite locus for previous locus '$prev_locus_name'");
            }

            $self->logger->info("Unsetting otter_id for sqlite locus: ", $self->_debug_locus($prev_locus));
            $prev_locus->drop_otter_id;
        }

        $old_locus = $self->_locus_cache->get($new_locus_name);
        if ($old_locus) {
            $self->logger->debug("Found sqlite version of new subseq's locus: ", $self->_debug_locus($old_locus));
        }
    }

    my ($done_sqlite, $done_zmap, $err);

    my $vega_dba = $self->vega_dba;
    my $from_HumAce = $self->_from_HumAce;

    try {
        $vega_dba->begin_work;

        if ($prev_locus) {
            $from_HumAce->update_Gene($prev_locus, $prev_locus);
        }

        if ($old_locus and $old_locus->ensembl_dbID) {
            my $locus_diffs = $self->_compare_loci($old_locus, $new_locus);
            if ($locus_diffs) {
                $self->logger->debug("$locus_tag: diffs to original saved Locus.");
                $self->_log_diffs($locus_diffs, $locus_tag);
                $from_HumAce->update_Gene($new_locus, $old_locus);
            } else {
                $self->logger->debug("$locus_tag: no diffs so stick with the old one.");
                $new_subseq->Locus($old_locus);
            }
        } else {
            $self->logger->debug("$locus_tag: original Locus not saved, must save this one.");
            $from_HumAce->store_Gene($new_locus, $new_subseq);
        }

        if ($old_subseq->ensembl_dbID) {
            my $diffs = $self->_compare_subseqs($old_subseq, $new_subseq);
            if ($diffs) {
                $self->logger->debug("$new_subseq_name: diffs to original saved SubSeq.");
                $self->_log_diffs($diffs, "SubSeq $new_subseq_name");
                $from_HumAce->update_Transcript($new_subseq, $old_subseq, $diffs);
            } else {
                $self->logger->debug("$new_subseq_name: no diffs so nothing else to do.");
            }
        } else {
            $self->logger->debug("$new_subseq_name: original SubSeq not saved, must save this one.");
            $from_HumAce->store_Transcript($new_subseq);
        }

        $vega_dba->commit;
        $self->_mark_unsaved;
        $done_sqlite = 1;

        $done_zmap = $self->_replace_in_zmap($new_subseq, $old_subseq, $old_subseq->ensembl_dbID);
    }
    catch {
        $err = $_;
        $self->logger->error("_replace_SubSeq_sqlite: $err");
        $vega_dba->rollback;
        $vega_dba->clear_caches;
    };

    if ($done_sqlite) {

        # update internal state
        $self->Assembly->replace_SubSeq($new_subseq, $old_subseq_name);

        if ($new_subseq_name ne $old_subseq_name) {
            $self->_subsequence_cache->delete($old_subseq_name);
        }
        $self->_subsequence_cache->set($new_subseq);

        my $locus = $new_subseq->Locus;
        if (my $prev_name = $locus->drop_previous_name) {
            $self->logger->info("Unsetting otter_id for locus '$prev_name'");
            $self->_locus_cache->get($prev_name)->drop_otter_id;
        }
        $self->_update_Locus($locus);
    }

    return ($done_sqlite, $done_zmap, $err);
}

sub _replace_in_zmap {
    my ($self, $new, $old, $delete_old) = @_;
    my $offset = $self->AceDatabase->offset;

    if ($delete_old) {
        $self->zmap->send_command_and_xml('delete_feature', $old->zmap_delete_xml_string($offset));
    }
    $self->zmap->send_command_and_xml('create_feature', $new->zmap_create_xml_string($offset));
    return 1;
}

sub _subsequence_cache {
    my ($self) = @_;
    $self->{'_subsequence_cache'} //= Bio::Otter::Utils::CacheByName->new;
    return $self->{'_subsequence_cache'};
}

sub _empty_SubSeq_cache {
    my ($self) = @_;
    $self->{'_subsequence_cache'} = undef;
    return;
}

sub _add_SubSeq {
    my ($self, $subseq) = @_;
    return $self->_subsequence_cache->set(
        $subseq,
        sub {
            my $name = $subseq->name;
            $self->logger->logconfess("already have SubSeq '$name'");
        },
        );
}

sub _delete_SubSeq {
    my ($self, $sub) = @_;

    my $name = $sub->name;
    $self->Assembly->delete_SubSeq($name);

    return $self->_subsequence_cache->delete($name);
}

# For external callers only - internal should use $self->_subsequence_cache*->get() for now
sub get_SubSeq {
    my ($self, $name) = @_;

    $self->logger->logconfess("no name given") unless $name;
    return $self->_subsequence_cache->get($name);
}

sub _row_count {
    my ($self, $slist) = @_;

    # Work out number of rows to keep the session
    # window roughly square.  Also a lower and
    # an upper limit of 20 and 40 rows.
    my $total_name_length = 0;
    foreach my $sub (grep { $_ } @$slist) {
        $total_name_length += length($sub->name);
    }
    my $rows = int sqrt($total_name_length);
    if ($rows < 20) {
        $rows = 20;
    }
    elsif ($rows > 40) {
        $rows = 40;
    }

    return $rows;
}

# Only track errors via master db & assembly
sub _update_SubSeq_locus_level_errors {
    my ($self) = @_;

    $self->Assembly->set_SubSeq_locus_level_errors;
    foreach my $sub_name ($self->_list_all_transcript_window_names) {
        my $transcript_window = $self->_get_transcript_window($sub_name) or next;
        my $sub = $self->_subsequence_cache->get($sub_name) or next;
        $transcript_window->SubSeq->locus_level_errors($sub->locus_level_errors);
    }

    return;
}

sub _cached_columns_by_internal_type {
    my ($self, $internal_type, $key) = @_;

    my $_columns = $self->{$key};
    return $_columns if $_columns;

    my $collection = $self->ColumnChooser->root_Collection;
    my @columns = map { $_->Filter->name } $collection->list_Columns_with_internal_type($internal_type);
    return $self->{$key} = [ @columns ];
}

sub OTF_Genomic_columns {
    my ($self) = @_;
    return $self->_cached_columns_by_internal_type('on_the_fly_genomic', 'OTF_Genomic_columns');
}

sub OTF_Transcript_columns {
    my ($self) = @_;
    return $self->_cached_columns_by_internal_type('on_the_fly_transcript', 'OTF_Transcript_columns');
}

sub _draw_sequence_list {
    my ($self, $slist) = @_;

    $self->_update_SubSeq_locus_level_errors;

    my $canvas = $self->canvas;
    my (undef, $size) = $self->named_font('mono', 'linespace');
    my $pad  = 0; # int($size / 6); # linespace includes some padding
    my $half = int($size / 2);

    my $rows = $self->_row_count($slist);

    # Delete everything apart from messages
    $canvas->delete('!msg');

    my $x = 0;
    my $y = 0;
    my $err_hash = {};
    my $locus_type_pattern;
    if (my $pre = $self->_default_locus_prefix) {
        $locus_type_pattern = qr{^$pre:};
    } else {
        $locus_type_pattern = qr{^[^:]+$};
    }
    for (my $i = 0; $i < @$slist; $i++) {
        if (my $sub = $slist->[$i]) {
            # Have a subseq - and not a gap in the list.

            my $style = 'bold';
            my $color = 'black';
            my $error = '';

            if ($sub->GeneMethod->name =~ /_trunc$/) {
                $color = '#999999';
            }
            elsif (! $sub->is_mutable) {
                $style = 'normal';
            }
            else {
                ### Not sure this needs a try/catch - no die or confess in pre_otter_save_error()
                try { $error = $sub->pre_otter_save_error; }
                catch { $error = $_; };
                if ($error) {
                    # Don't highlight errors in transcripts from other centres
                    if ($sub->Locus->name =~ /$locus_type_pattern/) {
                        $color = "#ee2c2c";     # firebrick2
                    } else {
                        $error = undef;
                    }
                }
            }
            my $txt = $canvas->createText(
                $x, $y,
                -anchor     => 'nw',
                -text       => $sub->name,
                -font       => $self->named_font($style eq 'bold' ? 'listbold' : 'mono'),
                -tags       => ['subseq', 'searchable'],
                -fill       => $color,
                );
            if ($error) {
                $error =~ s/\n$//;
                $Text::Wrap::columns = 60; ## no critic (Variables::ProhibitPackageVars)
                my @fmt;
                foreach my $line (split /\n/, $error) {
                    push(@fmt, wrap('', '  ', $line));
                }
                $err_hash->{$txt} = join "\n", @fmt;
            }
        }

        if (($i + 1) % $rows) {
            $y += $size + $pad;
        } else {
            $y = 0;
            my $x_max = ($canvas->bbox('subseq'))[2];
            $x = $x_max + ($size * 2);
        }
    }
    if (keys %$err_hash) {
        # $balloon->detach($canvas);
        $self->balloon->attach($canvas,
            -balloonposition => 'mouse',
            -msg => $err_hash,
            );
    }

    # Raise messages above everything else
    try { $canvas->raise('msg', 'subseq'); };

    return;
}

sub _highlight_by_name {
    my ($self, @names) = @_;

    $self->highlight($self->_subseq_names_to_canvas_obj(@names));

    return;
}

sub _highlight_by_name_without_owning_clipboard {
    my ($self, @names) = @_;

    if (my @obj_list = $self->_subseq_names_to_canvas_obj(@names)) {
        $self->CanvasWindow::highlight(@obj_list);
    }

    return;
}

sub _subseq_names_to_canvas_obj {
    my ($self, @names) = @_;

    my $canvas = $self->canvas;
    my %select_name = map { $_ => 1 } @names;

    my( @to_select );
    foreach my $obj ($canvas->find('withtag', 'subseq')) {
        my $n = $canvas->itemcget($obj, 'text');
        if ($select_name{$n}) {
            push(@to_select, $obj);
        }
    }

    return @to_select;
}

sub _canvas_obj_to_subseq_names {
    my ($self, @obj_list) = @_;

    my $canvas = $self->canvas;

    my( @names );
    foreach my $obj (@obj_list) {
        if (grep { $_ eq 'subseq' } $canvas->gettags($obj)) {
            my $n = $canvas->itemcget($obj, 'text');
            push(@names, $n);
        }
    }
    return @names;
}

sub list_selected_subseq_names {
    my ($self) = @_;

    return $self->_canvas_obj_to_subseq_names($self->list_selected);
}

sub _list_selected_subseq_objs {
    my ($self) = @_;
    return map { $self->_subsequence_cache->get($_) } $self->list_selected_subseq_names;
}

sub _list_was_selected_subseq_names {
    my ($self) = @_;

    return $self->_canvas_obj_to_subseq_names($self->list_was_selected);
}

sub rename_locus {
    my ($self, $locus_name) = @_;

    $self->logger->info("Renaming locus '", $locus_name // '<unspecified>', "'");

    unless ($self->_close_all_transcript_windows) {
        $self->message('Must close all transcript editing windows before renaming locus');
        return;
    }

    if (my $ren_window = $self->{'_locus_rename_window'}) {
        $ren_window->top->destroy;
    }

    my $lr = EditWindow::LocusName->init_or_reuse_Toplevel
      (-title => 'Rename Locus',
       {
        reuse_ref => \$self->{'_locus_rename_window'},
        # actually we don't re-use it, but destroy the old one
        transient => 1,
        init => { SessionWindow => $self,
                  locus_name_arg => $locus_name },
        from => $self->top_window });

    return 1;
}

sub _run_dotter {
    my ($self) = @_;

    my $dw = EditWindow::Dotter->init_or_reuse_Toplevel
      (-title => 'Run Dotter',
       { reuse_ref => \$self->{'_dotter_window'},
         transient => 1,
         init => { SessionWindow => $self },
         from => $self->top_window });

    $dw->update_from_SessionWindow($self);

    return 1;
}

sub run_exonerate {
    my ($self, %options) = @_;

    my $ew = EditWindow::Exonerate->init_or_reuse_Toplevel
      (-title => 'On The Fly (OTF) Alignment',
       { reuse_ref => \$self->{'_exonerate_window'},
         transient => 1,
         init => { SessionWindow => $self },
         from => $self->top_window });

    if ($options{clear_accessions}) {
        $ew->clear_accessions;
    }
    $ew->update_from_SessionWindow;
    $ew->progress('');

    return 1;
}

sub _exonerate_callbacks {
    my ($self) = @_;
    return $self->{_exonerate_callbacks} ||= {};
}

sub register_exonerate_callback {
    my ($self, $key, $caller, $callback) = @_;

    weaken($caller);
    my $weakened_callback = sub {
        unless ($caller) {
            warn "exonerate_callback caller for '$key' no longer exists\n";
            return;
        }
        return $caller->$callback(@_);
    };

    $self->_exonerate_callbacks->{$key} = $weakened_callback;
    return;
}

sub remove_exonerate_callback {
    my ($self, $key) = @_;
    return delete $self->_exonerate_callbacks->{$key};
}

sub _exonerate_done_callback {
    my ($self, @feature_sets) = @_;

    $self->logger->debug('_exonerate_done_callback: [', join(',', @feature_sets), ']');

    my $request_adaptor = $self->AceDatabase->DB->OTFRequestAdaptor;
    my (@requests, @requests_with_feedback);
    foreach my $set (@feature_sets) {
        my $request = $request_adaptor->fetch_by_logic_name_status($set, 'completed');
        next unless $request;
        push @requests, $request;
        if ($request->n_hits == 0 or $request->missed_hits or $request->raw_result) {
            push @requests_with_feedback, $request;
        }
    }

    foreach my $request (@requests_with_feedback) {
        my $callback = $self->_exonerate_callbacks->{$request->caller_ref};
        if ($callback) {
            $callback->($request);
        } else {
            $self->logger->error(sprintf('OTF results but no callback registered [%d,%s,%d]',
                                         $request->id, $request->logic_name, $request->caller_ref));
        }
    }

    if (@requests) {
        foreach my $request (@requests) {
            $request->status('reported');
            $request_adaptor->update_status($request);
        }
    }
    return;
}

sub get_mark_in_slice_coords {
    my ($self) = @_;

    my $offset = $self->AceDatabase->offset;
    if (my $mark = $self->zmap->get_mark) {
        $mark->{'start'} -= $offset;
        $mark->{'end'}   -= $offset;
        return $mark;
    }
    else {
        return;
    }
}

sub _set_window_title {
    my ($self) = @_;

    my $name = $self->AceDatabase->name;
    my $unsaved_str = $self->AceDatabase->unsaved_changes ? '*' : '';
    $self->top_window->title
      (sprintf('%s%sSession %s',
               $unsaved_str, $Bio::Otter::Lace::Client::PFX, $name));

    return;
}

sub name { # used by the bind_WM_DELETE_WINDOW method
    my ($self) = @_;
    return try { $self->AceDatabase->name } catch { "(a session)" };
}


sub _zmap_view_arg_hash {
    my ($self) = @_;
    my $config_file = sprintf "%s/ZMap", $self->AceDatabase->zmap_dir;
    my $slice = $self->AceDatabase->slice;
    my $name  = $slice->ssname;
    my $start = $slice->start;
    my $end   = $slice->end;
    my $view_name = sprintf '%s:%d-%d', $name, $start, $end;
    my $hash = {
        '-name'        => $name,
        '-start'       => $start,
        '-end'         => $end,
        '-view_name'   => $view_name,
        '-config_file' => $config_file,
    };
    return $hash;
}

sub _make_config {
    my ($self, $config_dir, $config) = @_;
    my $config_file = sprintf "%s/ZMap", $config_dir;
    open my $config_file_h, '>', $config_file
        or $self->logger->logdie(sprintf "failed to open the configuration file '%s': $!", $config_file);
    print $config_file_h $config if defined $config;
    close $config_file_h
        or $self->logger->logdie(sprintf "failed to close the configuration file '%s': $!", $config_file);
    return;
}

sub _make_zmap_config_dir {
    my ($self) = @_;

    my $config_dir = $self->_zmap_configs_dir_otter;
    my $key;
    do {
        $key = sprintf "%09d", int(rand(1_000_000_000));
    } while (-d "$config_dir/$key");
    $config_dir = "$config_dir/$key";

    my $err;
    File::Path::make_path($config_dir, { error => \$err });
    $self->logger->logdie
      (join "\n  ",
       "make_path for zmap_config_dir $config_dir failed",
       map {( (%$_)[0] || '(general error)' ).': '.(%$_)[1] } @$err)
        if @$err;

    return $self->{'_zmap_config_dir'} = $config_dir;
}

sub zmap_configs_dirs {
    my ($called) = @_;
    return ( $called->_zmap_configs_dir_otter, $called->_zmap_configs_dir_lace );
}

sub _zmap_configs_dir_otter {
    my ($called) = @_;
    # we make a class method call as we might be called as a class method by cleanup
    my $vtod = Bio::Otter::Lace::Client->var_tmp_otter_dir;
    return sprintf '%s/ZMap', $vtod;
}

# UNLACE: can go in due course
sub _zmap_configs_dir_lace {
    my ($called) = @_;
    my $user = getpwuid($<);
    return "/var/tmp/otter_${user}/ZMap";
}

### BEGIN: ZMap control interface

sub _new_zircon_context {
    my ($self, $prefix) = @_;
    $prefix //= 'SW';
    my $context = Zircon::Context::ZMQ::Tk->new(
            '-widget'       => $self->menu_bar,
            '-trace_prefix' => sprintf('%s=[%s]', $prefix, $self->AceDatabase->name),
        );
    $self->logger->debug(sprintf('New context: %s', $context));
    return $context;
}

sub _zmap_new {
    my ($self) = @_;
    mac_os_x_set_proxy_vars(\%ENV) if $^O eq 'darwin';
    my $DataSet = $self->AceDatabase->DataSet;
    my $config_dir = $self->_make_zmap_config_dir;
    my $config = $DataSet->zmap_config_global;
    $self->_make_config($config_dir, $config);
    my $arg_list = [
        '--conf_dir' => $config_dir,
        @{$DataSet->zmap_arg_list},
        ];
    my $client = $self->AceDatabase->Client;
    if (my $screen = $client->config_value('zmap_screen')) { # RT#390512
        $self->logger->info("Using logical screen override (zmap_screen=$screen)");
        push @$arg_list, $screen if $screen;
    } else { # RT#387856
        push @$arg_list, Tk::Screens->nxt( $self->top_window )->gtk_arg;
    }
    my $zmap =
        Zircon::ZMap->new(
            '-app_id'     => $self->_zircon_app_id,
            '-context'    => $self->_new_zircon_context,
            '-arg_list'   => $arg_list,
            $self->_zircon_timeouts,
        );
    $self->logger->debug(sprintf('New zmap: %s', $zmap));
    return $zmap;
}

sub _zircon_timeouts {
    my ($self) = @_;

    my $client = $self->AceDatabase->Client;
    my $handshake_to   = $client->config_section_value(Peer => 'handshake-timeout-secs');
    my $delay          = $client->config_section_value(Peer => 'post-handshake-delay-msecs');
    my $to_list_config = $client->config_section_value(Peer => 'timeout-list');
    my @to_list = split(',', $to_list_config);

    return (
        '-timeout_list'               => \@to_list,
        '-handshake_timeout_secs'     => $handshake_to,
        '-post_handshake_delay_msecs' => $delay,
        );
}

sub _zircon_app_id {
    my ($self) = @_;
    my $widget_id = $self->top_window->id;
    my $_zircon_app_id = "Otter_${widget_id}";
    return $_zircon_app_id;
}

sub _zmap_view_new {
    my ($self, $zmap) = @_;
    $self->logger->debug($zmap ? sprintf('_zmap_view_new using zmap: %s', $zmap) : '_zmap_view_new will create new zmap');
    $zmap ||= $self->_zmap_new;
    $self->_delete_zmap_view;
    $self->{'_zmap_view'} =
        $zmap->new_view(
            %{$self->_zmap_view_arg_hash},
            '-handler' => $self,
        );
    $self->logger->debug(sprintf('New _zmap_view: %s', $self->{'_zmap_view'}));
    $self->deiconify_and_raise;
    return;
}

sub _zmap_relaunch {
    my ($self) = @_;

    # NB: (from jh13 via IRC 26/02/2014)
    # Unreferencing the old view object causes it to be destroyed,
    # which removes the last reference to the ZMap object, causing it
    # to be destroyed, which sends a shutdown to the ZMap process.

    $self->_delete_zmap_view;
    $self->_zmap_view_new($self->zmap_select);
    $self->ColumnChooser->load_filters(is_recover => 1);
    return;
}

# Called during shutdown by SpeciesListWindow
#
sub delete_zmap_view {
    my ($self) = @_;
    $self->_delete_zmap_view;
    return;
}

sub _delete_zmap_view {
    my ($self) = @_;
    $self->logger->debug(sprintf('Deleting _zmap_view: %s', $self->{'_zmap_view'} || '<undef>'));
    delete $self->{'_zmap_view'};
    return;
}

sub zircon_zmap_view_features_loaded {
    my ($self, $status, $message, $feature_count, @featuresets) = @_;

    my $cllctn = $self->AceDatabase->ColumnCollection;
    my $col_aptr = $self->AceDatabase->DB->ColumnAdaptor;

    $self->logger->debug("zzvfl: status '$status', message '$message', feature_count '$feature_count'");

    my @columns_to_process = ();
    my @otf_loaded;
    foreach my $set_name (@featuresets) {
        if (my $column = $cllctn->get_Column_by_name($set_name)) {
            # filter_get will have updated gff_file field in SQLite db
            # so we need to fetch it from the database:
            $col_aptr->fetch_state($column);
            $self->logger->debug(
                sprintf "zzvfl: column '%s', status, '%s',", $column->name, $column->status);

            my $column_status =
                (! $status)    ? 'Error'      :
                $feature_count ? 'Processing' :
                1              ? 'Empty'      :
                $self->logger->logdie('this code should be unreachable');

            if ($column_status eq 'Processing') {
                push @columns_to_process, $column;
            }

            $column->status($column_status);
            $column->status_detail($message);
            $col_aptr->store_Column_state($column);

            push @otf_loaded, $set_name if $column->internal_type_like(qr/^on_the_fly/);
        }
        # else {
        #     # We see a warning for each acedb featureset
        #     $self->logger->warn("Ignoring featureset '$set_name'");
        # }
    }

    # This will get called by Tk event loop when idle
    $self->top_window->afterIdle(
        sub{
            $self->_exonerate_done_callback(@otf_loaded) if @otf_loaded;
            $self->_process_and_update_columns(@columns_to_process) if @columns_to_process;
            $self->RequestQueuer->features_loaded_callback(@featuresets);
            return;
        });

    $self->update_status_bar;

    return;
}


my $name_pattern = qr! ^
    (.*) \. [[:digit:]]+ \. [[:digit:]]+
    - [[:digit:]]+ # start
    - [[:digit:]]+ # end
    - [[:alpha:]]+ # strand
    $ !x;

sub zircon_zmap_view_edit {
    my ($self, $name, $style, $sub_list) = @_;

    if ($style && lc($style) eq 'genomic_canonical') {
        my ($accession_version) = $name =~ $name_pattern
            or $self->logger->logconfess("invalid name for a genomic_canonical feature: ${name}");
        $self->logger->info("Ignored request to edit clone $accession_version");
        return 1;
    }
    else {
        $sub_list or return 0;
        ref $sub_list eq 'ARRAY'
            or $self->logger->logconfess("Unexpected feature format for ${name}");
        for my $s (@$sub_list) {
            if ($s->{'ontology'} eq 'exon') {
                return $self->_edit_subsequences($name);
            }
        }
        return 0;
    }
}

sub zircon_zmap_view_feature_details_xml {
    my ($self, $name, $feature_hash) = @_;
    my $feature_details_xml =
        $self->_feature_details_xml($name, $feature_hash);
    $feature_details_xml or return;
    my $xml = Hum::XmlWriter->new;
    $xml->open_tag('notebook');
    $xml->open_tag('chapter');
    $xml->add_raw_data($feature_details_xml);
    $xml->close_all_open_tags;
    return $xml->flush;
}

sub _feature_details_xml {
    my ($self, $name, $feature_hash) = @_;
    my $subseq = $self->_subsequence_cache->get($name);
    return $subseq->zmap_info_xml if $subseq;
    return if $feature_hash->{'subfeature'};
    my @feature_details_xml = (
        $self->_feature_accession_info_xml($name),
        $self->_feature_evidence_xml($name),
        );
    return unless @feature_details_xml;
    return join '', @feature_details_xml;
}

sub _feature_accession_info_xml {
    my ($self, $feat_name) = @_;

    my $info = $self->AceDatabase->AccessionTypeCache->feature_accession_info($feat_name);
    return unless $info;
    my ($source, $taxon_id, $desc, $common_name, $scientific_name) =
        @{$info}{qw(source taxon_id description taxon_scientific_name taxon_common_name)};
    my $taxon_name = join ', ', grep { $_ } $common_name, $scientific_name;
    my $taxon = sprintf '%s (Taxon ID = %d)', $taxon_name, $taxon_id;

    # Put this on the "Details" page which already exists.
    my $xml = Hum::XmlWriter->new(5);
    $xml->open_tag('page',       { name => 'Details' });
    $xml->open_tag('subsection', { name => 'Feature' });
    $xml->open_tag('paragraph',  { type => 'tagvalue_table' });
    $xml->full_tag('tagvalue', { name => 'Source database', type => 'simple' }, $source);
    $xml->full_tag('tagvalue', { name => 'Taxon',           type => 'simple' }, $taxon);
    $xml->full_tag('tagvalue', { name => 'Description', type => 'scrolled_text' }, $desc);
    $xml->close_all_open_tags;

    return $xml->flush;
}

sub _feature_evidence_xml {
    my ($self, $feat_name) = @_;

    my $feat_name_is_prefixed =
        $feat_name =~ /\A[[:alnum:]]{2}:/;

    my $subseq_list = [];
    foreach my $name ($self->_subsequence_cache->names) {
        if (my $subseq = $self->_subsequence_cache->get($name)) {
            push(@$subseq_list, $subseq);
        }
    }
    my $used_subseq_names = [];
  SUBSEQ: foreach my $subseq (@$subseq_list) {

        #$self->logger->debug("Looking at: ", $subseq->name);
        my $evi_hash = $subseq->evidence_hash();

        # evidence_hash looks like this
        # evidence = {
        #   type    => [ qw(evidence names) ],
        #   EST     => [ qw(Em:BC01234.1 Em:CR01234.2) ],
        #   cDNA    => [ qw(Em:AB01221.3) ],
        #   ncRNA   => [ qw(Em:AF480562.1) ],
        #   Protein => [ qw(Sw:Q99IVF1) ]
        # }

        foreach my $evi_type (keys %$evi_hash) {
            my $evi_array = $evi_hash->{$evi_type};
            foreach my $evi_name (@$evi_array) {
                $evi_name =~ s/\A[[:alnum:]]{2}://
                    if ! $feat_name_is_prefixed;
                if ($feat_name eq $evi_name) {
                    push(@$used_subseq_names, $subseq->name);
                    next SUBSEQ;
                }
            }
        }
    }

    return unless @{$used_subseq_names};

    my $xml = Hum::XmlWriter->new(5);
    $xml->open_tag('page',       { name => 'Details' });
    $xml->open_tag('subsection', { name => 'Feature' });
    $xml->open_tag('paragraph',  { name => 'Evidence', type => 'homogenous' });
    foreach my $name (@$used_subseq_names) {
        $xml->full_tag('tagvalue', { name => 'for transcript', type => 'simple' }, $name);
    }
    $xml->close_all_open_tags;

    return $xml->flush;
}

sub zircon_zmap_view_load_features_xml {
    my ($self, @featuresets) = @_;

    my $xml = Hum::XmlWriter->new;
    foreach my $fs_name (@featuresets) {
        $xml->open_tag('featureset', { name => $fs_name });
        $xml->close_tag;
    }

    return $xml->flush;
}

sub zircon_zmap_view_delete_featuresets_xml {
    my ($self, @featuresets) = @_;

    my $xml = Hum::XmlWriter->new;
    foreach my $featureset (@featuresets) {
        $xml->open_tag('featureset', { name => $featureset });
        $xml->close_tag;
    }

    return $xml->flush;
}

sub zircon_zmap_view_zoom_to_subseq_xml {
    my ($self, $subseq) = @_;

    my $xml = Hum::XmlWriter->new;
    $xml->open_tag('featureset', { name => $subseq->GeneMethod->name });
    $subseq->zmap_xml_feature_tag($xml, $self->AceDatabase->offset);
    $xml->close_all_open_tags;

    return $xml->flush;
}

sub zircon_zmap_view_single_select {
    my ($self, $name_list) = @_;
    $self->deselect_all();
    $self->_highlight_by_name_without_owning_clipboard($_)
        for @{$name_list};
    return;
}

sub zircon_zmap_view_multiple_select {
    my ($self, $name_list) = @_;
    $self->_highlight_by_name_without_owning_clipboard($_)
        for @{$name_list};
    return;
}

sub zmap {
    my ($self) = @_;
    my $zmap_view = $self->{'_zmap_view'};
    return $zmap_view;
}

### END: ZMap control interface


sub DESTROY {
    my ($self) = @_;

    $self->logger->info("Destroying SessionWindow for ", $self->_session_path);

    $self->zmap_select_destroy;

    $self->_delete_zmap_view;
    $self->_shutdown_process_hits_proc;

    delete $self->{'_AceDatabase'};

    return;
}

1;

__END__

=head1 NAME - MenuCanvasWindow::SessionWindow

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

