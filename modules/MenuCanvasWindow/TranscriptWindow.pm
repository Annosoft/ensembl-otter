
### MenuCanvasWindow::TranscriptWindow

package MenuCanvasWindow::TranscriptWindow;

use strict;
use warnings;
use Carp;
use Scalar::Util 'weaken';
use Try::Tiny;
use Tk;
use Tk::Dialog;
use Tk::ROText;
use Tk::LabFrame;
use Tk::ComboBox;
use Tk::SmartOptionmenu;
use Tk::Utils::Dotter;

use Hum::Ace::Locus;
use Hum::Ace::Exon;

use Bio::EnsEMBL::Analysis;
use Bio::Vega::Author;
use Bio::Vega::Exon;
use Bio::Vega::Transcript;
use Bio::Vega::Utils::Attribute qw( add_EnsEMBL_Attributes );

use Bio::Otter::Utils::DotterLauncher;
use CanvasWindow::EvidencePaster;
use EditWindow::PfamWindow;
use Bio::Otter::Lace::Client;
use Bio::Otter::UI::TextWindow::Peptide;

use base qw( MenuCanvasWindow );

# "new" is in MenuCanvasWindow

sub initialise {
    my ($self) = @_;

    my $canvas = $self->canvas;
    my $top = $canvas->toplevel;

    $self->_draw_subseq;

    # Routines to handle the clipboard
    my $deselect_sub = sub{ $self->_deselect_all };
    $canvas->SelectionHandle(
        sub { $self->_export_highlighted_text_to_selection(@_); }
        );
    my $select_all_sub = sub{
        $self->_select_all_exon_pos;
        if ($self->list_selected) {
            $canvas->SelectionOwn( -command => $deselect_sub );
        } else {
            warn "Nothing selected";
        }
    };

    # FILE MENU
    {
        my $file_menu = $self->make_menu('File');

        # Show the peptide
        my $show_pep_command = sub{ $self->_show_peptide };
        $file_menu->add('command',
            -label          => 'Show Peptide',
            -command        => $show_pep_command,
            -accelerator    => 'Ctrl+Spacebar',
            -underline      => 5,
            );
        $top->bind('<Control-p>',       $show_pep_command);
        $top->bind('<Control-P>',       $show_pep_command);
        $top->bind('<Control-space>',   $show_pep_command);
        $canvas->Tk::bind('<space>',    $show_pep_command);

        # Trap window close
        my $window_close = $self->bind_WM_DELETE_WINDOW('window_close');
        $top->bind('<Control-w>',   $window_close);
        $top->bind('<Control-W>',   $window_close);

        if ($self->_is_mutable) {

            # Select supporting evidence for the transcript
            my $_select_evidence = sub{ $self->_select_evidence };
            $file_menu->add('command',
                -label          => 'Select evidence',
                -command        => $_select_evidence,
                -accelerator    => 'Ctrl+E',
                -underline      => 1,
                );
            $canvas->Tk::bind('<Control-e>',   $_select_evidence);
            $canvas->Tk::bind('<Control-E>',   $_select_evidence);

            # Save into db
            my $save_command = sub{ $self->_save_if_changed };
            $file_menu->add('command',
                -label          => 'Save',
                -command        => $save_command,
                -accelerator    => 'Ctrl+S',
                -underline      => 0,
                );
            $top->bind('<Control-s>',       $save_command);
            $top->bind('<Control-S>',       $save_command);
            $top->bind('<Control-Return>',  $save_command);
            $top->bind('<KP_Enter>',        $save_command);
            $canvas->Tk::bind('<Return>',   $save_command);
            $canvas->Tk::bind('<KP_Enter>', $save_command);
        }

        $file_menu->add('separator');

        # To close window
        $file_menu->add('command',
            -label          => 'Close',
            -command        => $window_close,
            -accelerator    => 'Ctrl+W',
            -underline      => 0,
            );
    }

    # EXON MENU
    {
        my $exon_menu = $self->make_menu('Exon');
        $self->{'_exon_menu'} = $exon_menu;

        # Select all positions
        $exon_menu->add('command',
            -label          => 'Select All',
            -command        => $select_all_sub,
            -accelerator    => 'Ctrl+A',
            -underline      => 7,
            );
        $canvas->Tk::bind('<Control-a>', $select_all_sub);
        $canvas->Tk::bind('<Control-A>', $select_all_sub);

        # Deselect all
        $canvas->Tk::bind('<Escape>', sub{ $self->_deselect_all });

        if ($self->_is_mutable) {

            # Flip strands
            my $reverse_command = sub { $self->_toggle_tk_strand };
            $exon_menu->add('command',
                -label          => 'Reverse',
                -command        => $reverse_command,
                -accelerator    => 'Ctrl+R',
                -underline      => 0,
                );
            $canvas->Tk::bind('<Control-r>', $reverse_command);
            $canvas->Tk::bind('<Control-R>', $reverse_command);

            # Trim CDS coords to first stop character
            my $trim_cds_sub = sub { $self->trim_cds_coord_to_first_stop };
            $exon_menu->add('command',
                -label          => 'Trim CDS',
                -command        => $trim_cds_sub,
                -accelerator    => 'Ctrl+T',
                -underline      => 0,
                );
            $canvas->Tk::bind('<Control-t>', $trim_cds_sub);
            $canvas->Tk::bind('<Control-T>', $trim_cds_sub);

            # Add editing facilities for editable SubSeqs
            $exon_menu->add('separator');

            # Sort the positions
            my $sort_command = sub{ $self->_sort_all_coordinates };
            $exon_menu->add('command',
                -label          => 'Sort',
                -command        => $sort_command,
                -accelerator    => 'Ctrl+O',
                -underline      => 0,
                );
            $top->bind('<Control-o>',   $sort_command);
            $top->bind('<Control-O>',   $sort_command);

            # Merge overlapping exon coordinates
            my $merge_overlapping_exons = sub{ $self->merge_position_pairs };
            $exon_menu->add('command',
                -label          => 'Merge',
                -command        => $merge_overlapping_exons,
                -accelerator    => 'Ctrl+M',
                -underline      => 0,
                );
            $canvas->Tk::bind('<Control-m>', $merge_overlapping_exons);
            $canvas->Tk::bind('<Control-M>', $merge_overlapping_exons);

            # Delete selected Exons
            my $delete_exons = sub{ $self->_delete_selected_exons };
            $exon_menu->add('command',
                -label          => 'Delete',
                -command        => $delete_exons,
                -accelerator    => 'Ctrl+D',
                -underline      => 0,
                );
            $canvas->Tk::bind('<Control-d>', $delete_exons);
            $canvas->Tk::bind('<Control-D>', $delete_exons);
        }
    }

    # TOOLS MENU
    {
        my $tools_menu = $self->make_menu('Tools');

        if ($self->_is_mutable) {
            # Check for annotation errors
            my $error_check = sub { $self->_check_for_errors };
            $tools_menu->add('command',
                -label          => 'Check annotation',
                -command        => $error_check,
                -accelerator    => 'Ctrl+C',
                -underline      => 0,
                );
            $top->bind('<Control-c>',   $error_check);
            $top->bind('<Control-C>',   $error_check);
        }

        # Show the subsequence in fMap
        my $_show_subseq = sub{ $self->_show_subseq };
        $tools_menu->add('command',
            -label          => 'Hunt in ZMap',
            -command        => $_show_subseq,
            -accelerator    => 'Ctrl+H',
            -underline      => 0,
            );
        $top->bind('<Control-h>',   $_show_subseq);
        $top->bind('<Control-H>',   $_show_subseq);

        # Run dotter
        my $_run_dotter = sub{ $self->_run_dotter };
        $tools_menu->add('command',
            -label          => 'Dotter',
            -command        => $_run_dotter,
            -accelerator    => 'Ctrl+.',
            -underline      => 0,
            );
        $top->bind('<Control-period>',  $_run_dotter);
        $top->bind('<Control-greater>', $_run_dotter);

        # Search Pfam
        my $search_pfam_command = sub{ $self->_search_pfam };
        $tools_menu->add('command',
            -label          => 'Search Pfam',
            -command        => $search_pfam_command,
            -accelerator    => 'Ctrl+P',
            -underline      => 7,
            );
        $top->bind('<Control-p>',       $search_pfam_command);
        $top->bind('<Control-P>',       $search_pfam_command);

        if ($self->_is_mutable) {
            # Show dialog for renaming the locus attached to this subseq
            my $_rename_locus = sub { $self->_rename_locus };
            $tools_menu->add('command',
                -label          => 'Rename locus',
                -command        => $_rename_locus,
                -accelerator    => 'Ctrl+L',
                -underline      => 0,
                );
            $top->bind('<Control-l>',  $_rename_locus);
            $top->bind('<Control-L>',  $_rename_locus);
        }
    }

    if ($self->_is_mutable) {

        my $attrib_menu = $self->make_menu('Attributes');

        my $tsct_attrib_menu = $attrib_menu->Menu(-tearoff => 0);
        $attrib_menu->add('cascade',
            -menu       => $tsct_attrib_menu,
            -label      => 'Transcript',
            -underline  => 0,
            );

        my $locus_attrib_menu = $attrib_menu->Menu(-tearoff => 0);
        $attrib_menu->add('cascade',
            -menu       => $locus_attrib_menu,
            -label      => 'Locus',
            -underline  => 0,
            );

        # Keyboard editing commands
        $canvas->Tk::bind('<Left>',      sub{ $self->_canvas_text_go_left   });
        $canvas->Tk::bind('<Right>',     sub{ $self->_canvas_text_go_right  });
        $canvas->Tk::bind('<BackSpace>', sub{ $self->_canvas_backspace      });

        # For entering digits into the text object which has keyboard focus
        $canvas->eventAdd('<<digit>>', map { "<KeyPress-$_>" } 0..9);
        $canvas->Tk::bind('<<digit>>', [sub{ $self->_canvas_insert_character(@_) }, Tk::Ev('A')]);

        # Increases the number which has keyboard focus
        $canvas->eventAdd('<<increment>>', qw{ <Up> <plus> <KP_Add> <equal> });
        $canvas->Tk::bind('<<increment>>', sub{ $self->_increment_int });

        # Decreases the number which has keyboard focus
        $canvas->eventAdd('<<decrement>>', qw{ <Down> <minus> <KP_Subtract> <underscore> });
        $canvas->Tk::bind('<<decrement>>', sub{ $self->_decrement_int });

        # Control-Left mouse for switching strand
        $canvas->Tk::bind('<Control-Button-1>', sub{
            $self->_control_left_button_handler;
            if ($self->count_selected) {
                $canvas->SelectionOwn( -command => $deselect_sub );
            }
        });

        # Middle mouse pastes in coords from clipboard
        $canvas->Tk::bind('<Button-2>', sub{
            $self->_middle_button_paste;
            if ($self->count_selected) {
                $canvas->SelectionOwn( -command => $deselect_sub );
            }
        });

        # Handle left mouse
        $canvas->Tk::bind('<Button-1>', sub{
            $self->_left_button_handler;
            $self->_focus_on_current_text;
            if ($self->count_selected) {
                $canvas->SelectionOwn( -command => $deselect_sub );
            }
        });

        my $frame = $canvas->toplevel->LabFrame(
            Name => 'transcript',
            -label => 'Transcript',
            -border => 3,
            )->pack(
                -side => 'top',
                -fill => 'x',
                );

        # Widget for changing name
        $self->_add_subseq_rename_widget($frame);

        # Widget for changing transcript type (acedb method).
        my $current_method = $self->SubSeq->GeneMethod->name;
        $self->_method_name_var(\$current_method);
        my @mutable_gene_methods = $self->SessionWindow->get_all_mutable_GeneMethods;

        my $type_frame = $frame->Frame(
            -border => 3,
            )->pack( -side => 'top' );
        $type_frame->Label(
            -padx => 6,
            -text => 'Type:',
            )->pack( -side => 'left' );
        my $menu_list = [];
        foreach my $gm (@mutable_gene_methods) {
            my $name = $gm->name;
            my $display_name = $gm->has_parent ? "    $name" : $name;
            push(@$menu_list, [$display_name, $name]);
        }
        my $type_option_menu = $type_frame->SmartOptionmenu(
            -options => $menu_list,
            -variable => \$current_method,
            -command => sub{
                    $self->_draw_translation_region;
                    $self->fix_window_min_max_sizes;
                    $top->focus;  # Need this
                },
            )->pack(-side => 'left');

        # Start not found and end not found and method widgets
        $self->_add_start_end_method_widgets($frame);

        # Transcript remark widget
        $self->_add_transcript_remark_widget($frame, $tsct_attrib_menu);
        $self->_populate_transcript_attribute_menu($tsct_attrib_menu);

        # Widget for changing locus properties
        my $locus_frame = $canvas->toplevel->LabFrame(
            Name => 'locus',
            -label => 'Locus',
            -border => 3,
            )->pack(
                -side => 'top',
                -fill => 'x',
                );
        $self->_add_locus_editing_widgets($locus_frame, $locus_attrib_menu);
        $self->_populate_locus_attribute_menu($locus_attrib_menu);
    } else {
        # SubSeq with an immutable method - won't display entry widgets for updating things

        # Only select current text - no focus
        $canvas->Tk::bind('<Button-1>', sub{
            $self->_left_button_handler;
            if ($self->count_selected) {
                $canvas->SelectionOwn( -command => $deselect_sub );
            }
        });
    }

    # For extending selection
    $canvas->Tk::bind('<Shift-Button-1>', sub{
        $self->_shift_left_button_handler;
        if ($self->count_selected) {
            $canvas->SelectionOwn( -command => $deselect_sub )
        }
    });

    $canvas->Tk::bind('<Destroy>', sub{ $self = undef });

    $self->_colour_init;
    $top->update;
    $self->fix_window_min_max_sizes;
    return;
}



sub name {
    my ($self, $name) = @_;

    if ($name) {
        $self->{'_name'} = $name;
    }
    return $self->{'_name'};
}

sub SubSeq {
    my ($self, $sub) = @_;

    if ($sub) {
        my $expected = 'Hum::Ace::SubSeq';
        try { $sub->isa($expected) } or confess "Expected a '$expected', but got '$sub'";
        $self->{'_SubSeq'} = $sub;
        $self->canvas->toplevel->configure
          (-title => $Bio::Otter::Lace::Client::PFX.'Transcript ' . $sub->name);
    }
    return $self->{'_SubSeq'};
}

sub _current_SubSeq {
    my ($self) = @_;
    if ($self->_is_mutable) {
        return $self->_new_SubSeq_from_tk;
    } else {
        return $self->SubSeq;
    }
}

sub SessionWindow { # method used by Bio::Otter::UI::TextWindow
    my ($self, $SessionWindow) = @_;

    if ($SessionWindow) {
        $self->{'_SessionWindow'} = $SessionWindow;
        weaken $self->{'_SessionWindow'};
    }
    return $self->{'_SessionWindow'};
}

sub _SW_AceDB_DataSet {
    my ($self) = @_;
    return $self->SessionWindow->AceDatabase->DataSet;
}

sub _add_subseq_exons {
    my ($self, $subseq) = @_;

    my $expected = 'Hum::Ace::SubSeq';
    unless ($subseq->isa($expected)) {
        warn "Unexpected object '$subseq', expected a '$expected'";
    }

    my $strand = $subseq->strand;

    foreach my $ex ($subseq->get_all_Exons_in_transcript_order) {
        $self->_add_exon_holder($ex->start, $ex->end, $strand);
    }

    $self->_remove_spurious_splice_sites;

    return;
}

sub _colour_init {
    my ($self) = @_;

    return $self->SessionWindow->colour_init($self->top_window);
}

{
    my $pp_field = '_position_pairs';

    sub _position_pairs {
        my ($self, @pairs) = @_;

        if (@pairs) {
            $self->{$pp_field} = [@pairs];
        }

        if (my $pp = $self->{$pp_field}) {
            return @$pp;
        } else {
            return;
        }
    }

    sub _add_position_pair {
        my ($self, @pair_and_id) = @_;

        unless (@pair_and_id == 3) {
            confess "Expecting 2 numbers and exon_id";
        }
        $self->{$pp_field} ||= [];
        push(@{$self->{$pp_field}}, [@pair_and_id]);

        return;
    }

    sub _next_position_pair_index {
        my ($self) = @_;

        if (my $pp = $self->{$pp_field}) {
            return scalar @$pp;
        } else {
            return 0;
        }
    }

    sub _trim_position_pairs {
        my ($self, $length, $strand) = @_;

        if (my $pp = $self->{$pp_field}) {
            my @del = splice(@$pp, -1 * $length, $length);
            if (@del != $length) {
                confess "only got ", scalar(@del), " elements, not '$length'";
            }
            my $canvas = $self->canvas;
            foreach my $exon_id (map { $_->[2] } @del) {
                $canvas->delete($exon_id);
            }
            $self->_decrement_exon_counter($length);
        } else {
            confess "No pairs to trim";
        }
        $self->_set_tk_strand($strand) if $strand;
        $self->_position_mobile_elements;

        return;
    }
}


sub _all_position_pair_text {
    my ($self) = @_;

    my $canvas = $self->canvas;
    my $empty  = $self->_empty_string;
    my( @pos );
    foreach my $pair ($self->_position_pairs) {
        my $start = $canvas->itemcget($pair->[0], 'text');
        my $end   = $canvas->itemcget($pair->[1], 'text');
        foreach my $p ($start, $end) {
            $p = 0 if $p eq $empty;
        }
        if ($start < $end) {
            push(@pos, [$start, $end]);
        } else {
            push(@pos, [$end, $start]);
        }
    }
    return @pos;
}

sub _set_position_pair_text {
    my ($self, $pp, $text_pair, $strand) = @_;

    $strand ||= $self->_strand_from_tk;

    my $canvas = $self->canvas;
    my @txt = @$text_pair;
    @txt = reverse @txt if $strand == -1;
    foreach my $i (0,1) {
        my $obj = $pp->[$i];
        my $pos = $txt[$i] || $self->_empty_string;
        $canvas->itemconfigure($obj, -text => $pos);
    }
    $self->_update_splice_strings($text_pair->[0]);

    return;
}

sub _set_all_position_pair_text {
    my ($self, @coord) = @_;

    my @pp_list = $self->_position_pairs;
    if (@pp_list != @coord) {
        confess "position pair number '", scalar(@pp_list),
            "' doesn't match number of coordinates '", scalar(@coord), "'";
    }
    for (my $i = 0; $i < @pp_list; $i++) {
        $self->_set_position_pair_text($pp_list[$i], $coord[$i]);
    }
    $self->_update_splice_strings('exon_start');

    return;
}

sub _sort_all_coordinates {
    my ($self) = @_;

    $self->delete_was_selected;
    $self->_sort_position_pairs;
    $self->_sort_translation_region;

    return;
}

sub _sort_position_pairs {
    my ($self) = @_;

    my %was_selected = map { $_ => 1 } $self->get_all_selected_text;
    $self->_deselect_all;

    my $empty  = $self->_empty_string;
    my $canvas = $self->canvas;
    my $strand = $self->_strand_from_tk;

    my( @sort );
    if ($strand == 1) {
        @sort = sort {$a->[0] <=> $b->[0] || $a->[1] <=> $b->[1]}
            $self->_all_position_pair_text;
    } else {
        @sort = sort {$b->[0] <=> $a->[0] || $b->[1] <=> $a->[1]}
            $self->_all_position_pair_text;
    }

    my $n = 0;
    my( @select );
    foreach my $pp ($self->_position_pairs) {
        my @num = @{$sort[$n]};
        @num = reverse @num if $strand == -1;
        foreach my $i (0,1) {
            my $pos = $num[$i] || $empty;
            my $obj = $pp->[$i];
            push(@select, $obj) if $was_selected{$pos};
            $canvas->itemconfigure($obj, -text => $pos);
        }
        $n++;
    }
    $self->highlight(@select) if @select;
    $self->_update_splice_strings('exon_start');
    $self->_remove_spurious_splice_sites;

    return;
}

sub _sort_translation_region {
    my ($self) = @_;

    my @region  = $self->_translation_region_from_tk or return;
    my $strand  = $self->_strand_from_tk;
    if ($strand == 1) {
        $self->_tk_t_start($region[0]);
        $self->_tk_t_end  ($region[1]);
    } else {
        $self->_tk_t_start($region[1]);
        $self->_tk_t_end  ($region[0]);
    }

    return;
}

sub merge_position_pairs {
    my ($self) = @_;

    $self->_deselect_all;
    $self->_sort_position_pairs;
    my @pos = $self->_all_position_pair_text;
    my $i = 0;
    my $strand = $self->_strand_from_tk;
    while (1) {
        my $this = $pos[$i];
        my $next = $pos[$i + 1] or last;
        # Merge overlapping or abutting Exons
        if (
            ($this->[0] <= $next->[1] and $this->[1] >= $next->[0])
            or ($strand == 1
                ? ($this->[1] + 1) == $next->[0]
                : $this->[0] == ($next->[1] + 1))
            )
        {
            $this->[0] = ($this->[0] < $next->[0]) ? $this->[0] : $next->[0];
            $this->[1] = ($this->[1] > $next->[1]) ? $this->[1] : $next->[1];
            splice(@pos, $i + 1, 1);
        } else {
            $i++;
        }
    }

    my @pairs  = $self->_position_pairs;
    for (my $j = 0; $j < @pos; $j++) {
        $self->_set_position_pair_text($pairs[$j], $pos[$j]);
    }
    if (my $over = @pairs - @pos) {
        $self->_trim_position_pairs($over);
        $self->fix_window_min_max_sizes;
    }

    $self->_remove_spurious_splice_sites;

    return;
}

sub _delete_selected_exons {
    my ($self) = @_;

    my $canvas = $self->canvas;
    my @selected = $self->list_selected;
    $self->_deselect_all;
    my( %del_exon );
    foreach my $obj (@selected) {
        my ($exon_id) = grep { /^exon_id/ } $canvas->gettags($obj);
        if ($exon_id) {
            $del_exon{$exon_id}++;
        }
    }

    my $strand = 0;
    my @text    = $self->_all_position_pair_text;
    my @pp_list = $self->_position_pairs;
    my $trim = 0;
    my( @keep );
    for (my $i = 0; $i < @pp_list; $i++) {
        my $exon_id = $pp_list[$i][2];
        my $count = $del_exon{$exon_id};
        if ($count and $count == 2) {
            $trim++;
        } else {
            $strand += $self->_exon_strand_from_tk($exon_id);
            push(@keep, $text[$i]);
        }
    }

    return unless $trim;

    $strand = $strand < 0 ? -1 : 1;

    $self->_trim_position_pairs($trim, $strand);
    $self->_set_all_position_pair_text(@keep);   # Also updates splice site strings
    $self->_remove_spurious_splice_sites;
    $self->delete_was_selected;

    # Put in an empty exon holder if we have deleted them all
    unless ($self->_position_pairs) {
        $self->_add_exon_holder(undef, undef, 1);
    }

    $self->fix_window_min_max_sizes;

    return;
}

sub _exon_strand_from_tk {
    my ($self, $exon_id) = @_;

    confess "exon_id not given" unless $exon_id;
    if ($self->canvas->find('withtag', "plus_strand&&$exon_id")) {
        return 1;
    } else {
        return -1;
    }
}

sub _add_coordinate_pair {
    my ($self, $start, $end) = @_;

    my $strand = 1;
    if ($start and $end and $start > $end) {
        $strand = -1;
        ($start, $end) = ($end, $start);
    }
    $self->_add_exon_holder($start, $end, $strand);

    return;
}

sub _draw_subseq {
    my ($self) = @_;

    my $sub = $self->SubSeq;
    $self->_add_subseq_exons($sub);
    $self->_draw_translation_region($sub);
    $self->_evidence_hash($sub->clone_evidence_hash);

    return;
}

sub _is_mutable {
    my ($self) = @_;

    return $self->SubSeq->is_mutable;
}

sub window_close {
    my ($self) = @_;

    my $SessionWindow = $self->SessionWindow;

    if ($self->_is_mutable && $SessionWindow->AceDatabase->write_access) {
        my ($sub, $err);
        my $ok =
            try { $sub = $self->_get_SubSeq_if_changed; return 1; }
            catch { $err = $_; return 0; };

        my $name = $self->name;

        if (! $ok) {
            $self->deiconify_and_raise;
            $self->exception_message($err, 'Error checking for changes to transcript');
            my $dialog = $self->canvas->toplevel->Dialog(
                -title          => $Bio::Otter::Lace::Client::PFX.'Abandon?',
                -bitmap         => 'question',
                -text           => "Transcript '$name' has errors.\nAbandon changes?",
                -default_button => 'No',
                -buttons        => [qw{ Yes No }],
                );
            $self->delete_window_dialog($dialog);
            my $ans = $dialog->Show;
            return if $ans eq 'No';
        }
        elsif ($sub) {
            # Ask the user if changes should be saved
            $self->deiconify_and_raise;
            my $dialog = $self->canvas->toplevel->Dialog(
                -title          => $Bio::Otter::Lace::Client::PFX.'Save changes?',
                -bitmap         => 'question',
                -text           => "Save changes to Transcript '$name' ?",
                -default_button => 'Yes',
                -buttons        => [qw{ Yes No Cancel }],
                );
            my $ans = $dialog->Show;

            if ($ans eq 'Cancel') {
                return; # Abandon window close
            }
            elsif ($ans eq 'Yes') {
                $self->_save_sub($sub) or return;
            }
        }
    }

    $self->top_window->destroy;

    return 1;
}

sub _show_subseq {
    my ($self) = @_;

    my $success = $self->SessionWindow->zmap->zoom_to_subseq($self->SubSeq);

    $self->message("ZMap: zoom to subsequence failed") unless $success;

    return;
}

sub _show_peptide {
    my ($self) = @_;

    my $peptext = $self->{'_pep_peptext'};
    unless ($peptext) {
        $peptext = $self->{'_pep_peptext'} = Bio::Otter::UI::TextWindow::Peptide->new($self);
    }

    if ($self->update_translation) {
        # Make the window visible
        my $win = $peptext->window->toplevel;
        $win->deiconify;
        $win->raise;
    }

    return;
}

sub _search_pfam {
    my ($self) = @_;

    my $sub = $self->_current_SubSeq;
    unless ($sub->GeneMethod->coding) {
        $self->message("non-coding transcript type");
        return;
    }

    return unless
      try { $sub->validate; return 1; }
        catch { $self->exception_message($_, 'Invalid transcript'); return 0; };

    # We will run the query

    my $pep = $sub->translator->translate($sub->translatable_Sequence);
    my $name = $pep->name;
    my $str = $pep->sequence_string;
    my $pfam;

    if($self->{'_pfam'}) {
        if ($self->{'_pfam'}->restore($str)) {
            # Keeping old results window
            $pfam = $self->{'_pfam'};
            return 1;
        } else {
            # Maybe keep old results URL
            my $old = $self->{'_pfam'};
            my $result_url = $old->result_url;
            my $prev_query = $old->query();
            $pfam = $self->_new_window($name);
            $pfam->result_url($result_url) if $prev_query eq $str;
        }
    } else {
        $pfam = $self->_new_window($name);
    }

    $pfam->query($str);
    $pfam->name($name);
    $self->{'_pfam'} = $pfam;
    try {
        my $session_dir = $self->SessionWindow->AceDatabase->home;
        $pfam->initialise("$session_dir/pfam");
    } catch {
        my $err = $_;
        $self->exception_message($_, "Failed to request Pfam search");
        $pfam->top->destroy;
    };

    return;
}

sub _new_window {
    my ($self, $name) = @_;
    return EditWindow::PfamWindow->init_or_reuse_Toplevel
      (-title => "Pfam $name",
       { from => $self->top_window });
}

sub update_translation {
    my ($self) = @_;

    my $peptext = $self->{'_pep_peptext'} or return;

    my $sub = $self->_current_SubSeq;
    unless ($sub->GeneMethod->coding) {
        if ($peptext) {
            $peptext->window->toplevel->withdraw;
        }
        $self->message("non-coding transcript type");
        return;
    }

    return $peptext->update_translation($sub);
}

sub _evidence_hash {
    my ($self, $_evidence_hash) = @_;

    if ($_evidence_hash) {
        $self->{'_evidence_hash'} = $_evidence_hash;
        if (my $paster = $self->{'_evi_window'}) {
            $paster->evidence_hash($_evidence_hash);
            $paster->draw_evidence;
        }
    }
    return $self->{'_evidence_hash'};
}

sub _select_evidence {
    my ($self) = @_;

    my $paster_top = $self->EvidencePaster->canvas->toplevel;
    $paster_top->deiconify;
    $paster_top->raise;
    return $paster_top;
}

sub EvidencePaster {
    my ($self) = @_;

    my $evi = $self->_evidence_hash;

    my $paster;
    if ($paster = $self->{'_evi_window'}) {
        $paster->evidence_hash($evi);
        $paster->draw_evidence;
    } else {
        my $paster_top = $self->canvas->Toplevel;
        $paster_top->transient($self->canvas->toplevel);
        $paster = $self->{'_evi_window'} = CanvasWindow::EvidencePaster->new($paster_top);
        $paster->TranscriptWindow($self);
        $paster->initialise($evi);
    }
    return $paster;
}

sub _save_OtterTranscript_evidence {
    my ($self, $transcript) = @_;

    my $info = $transcript->transcript_info;
    my $evi_hash = {};
    foreach my $evi (@{$info->get_all_Evidence}) {
        my $type = $evi->type;
        my $name = $evi->name;
        my $evi_list = $evi_hash->{$type} ||= [];
        push @$evi_list, $name;
    }
    $self->_evidence_hash($evi_hash);

    return;
}

sub adjust_tk_t_start {
    my ($self, $new) = @_;

    $self->_deselect_all;
    my $original = $self->_tk_t_start;
    $self->_tk_t_start($new);

    # Highlight the translation end if we have changed it
    $self->highlight('t_start') if $new != $original;

    return;
}

sub trim_cds_coord_to_first_stop {
    my ($self) = @_;

    unless ($self->_get_GeneMethod_from_tk->coding) {
        $self->message('non-coding transcript type');
        return;
    }

    $self->_deselect_all;
    my $sub = $self->_new_SubSeq_from_tk;
    my $strand = $sub->strand;
    my $original = $self->_tk_t_end;
    if ($strand == 1) {
        $self->_tk_t_end($sub->end);
    } else {
        $self->_tk_t_end($sub->start);
    }

    # Translate the subsequence
    $sub = $self->_new_SubSeq_from_tk;
    my $pep = $sub->translator->translate($sub->translatable_Sequence);
    my $pep_str = $pep->sequence_string;

    # Trim leading partial amino acid if present
    $pep_str =~ s/^X//;

    # Find the first stop character
    my $stop_pos = index($pep_str, '*', 0);
    if ($stop_pos == -1) {
        $self->message("No stop codon found");
        return;
    }
    $stop_pos++;

    # Convert from peptide to CDS coordinates
    my $cds_coord = $sub->start_phase - 1 + ($stop_pos * 3);
    warn sprintf "CDS coord = (%d x 3) + %d - 1 = $cds_coord\n",
        $stop_pos, $sub->start_phase, $cds_coord;

    # Get a list of exons in translation order
    my @exons = $sub->get_all_CDS_Exons;
    if ($strand == -1) {
        @exons = reverse @exons;
    }

    # Find the exon that contains the stop, and use its
    # coordinates to map back to genomic coordinates
    my $pos = 0;
    foreach my $ex (@exons) {
        my $exon_end = $pos + $ex->length;
        if ($cds_coord <= $exon_end) {
            my $exon_offset = $cds_coord - $pos;
            my( $new );
            if ($strand == 1) {
                $new = $ex->start + $exon_offset - 1;
            } else {
                $new = $ex->end + 1 - $exon_offset;
            }
            $self->_tk_t_end($new);

            # Highlight the translation end if we have changed it
            $self->highlight('t_end') if $new != $original;
            return 1;
        }
        $pos = $exon_end;
    }
    $self->message("Failed to map coordinate");

    return;
}

sub _add_locus_editing_widgets {
    my ($self, $widget, $locus_attrib_menu) = @_;

    # Get the Locus name
    my( $locus_name, $locus_description, $locus_alias );
    my $locus_is_known = 0;
    if (my $locus = $self->SubSeq->Locus) {
        $locus_name         = $locus->name;
        $locus_alias        = join(' ', $locus->list_aliases);
        $locus_description  = $locus->description;
        $locus_is_known     = $locus->known;
    }
    $locus_name        ||= '';
    $locus_description ||= '';
    $locus_alias       ||= '';
    $self->{'_locus_name_var'} = \$locus_name;
    $self->{'_locus_is_known_var'} = \$locus_is_known;

    my $symbol_known_frame = $widget->Frame->pack(-side => 'top');

    my $be = $symbol_known_frame->ComboBox(
        -listheight => 10,
        -label      => 'Symbol: ',
        -width      => 18,
        -variable   => $self->{'_locus_name_var'},
        -command    => sub{
            #warn "Locus is now '${$self->{'_locus_name_var'}}'\n";
            my $name = ${$self->{'_locus_name_var'}};
            my $locus = $self->SessionWindow->get_Locus_by_name($name);
            $self->_update_Locus_tk_fields($locus);
            },
        -exportselection    => 1,
        -background         => 'white',
        -selectbackground   => 'gold',
        -font               => $self->named_font('mono'),
        )->pack(-side => 'left');
    #$be->bind('<Leave>', sub{ warn "Variable now: ", ${$self->{'_locus_name_var'}}, "\n"; });

    $be->configure(
        -listcmd => sub{
            my @names = $self->SessionWindow->list_Locus_names;
            $be->configure(
                -choices   => [@names],
                #-listwidth => scalar @names,
                );}
        );

    $symbol_known_frame->Checkbutton(
        -text       => 'Known',
        -onvalue    => 1,
        -offvalue   => 0,
        -variable   => $self->{'_locus_is_known_var'},
        -padx       => 6,
        )->pack(-side => 'left', -padx => 6);
    #warn "Locus is known = ${$self->{'_locus_is_known_var'}}";

    # Description ("Full_name" in acedb) editing widget
    my $de_frame = $widget->Frame(
        -border => 3,
        )->pack(-anchor => 'e');

    $de_frame->Label(
        -text   => "Full name:",
        -anchor => 's',
        -padx   => 6,
        )->pack(-side => 'left');

    my $de = $de_frame->Entry(
        -width              => 38,
        -exportselection    => 1,
        -font               => $self->named_font('prop'),
        );
    $de->pack(-side => 'left');
    $de->insert(0, $locus_description);
    $self->_locus_description_Entry($de);

    my $ae = $self->_make_labelled_entry_widget($widget, 'Alias(es)', $locus_alias, 30, -side => 'top');
    $self->_locus_alias_Entry($ae);

    # Locus remark widget
    my $re = $self->_make_labelled_text_widget($widget, 'Remarks', $locus_attrib_menu, -anchor => 'se');
    $self->_locus_remark_Entry($re);
    if (my $locus = $self->SubSeq->Locus) {
        $self->_update_locus_remark_widget($locus);
    }

    # Avoid memory cycle created by ref to $self in above closure
    $be->bind('<Destroy>', sub{ $self = undef });

    return $be;
}

sub _get_locus_known {
    my ($self) = @_;

    return ${$self->{'_locus_is_known_var'}} ? 1 : 0;
}

sub _update_Locus_tk_fields {
    my ($self, $locus) = @_;

    ${$self->{'_locus_name_var'}} = $locus->name;

    ${$self->{'_locus_is_known_var'}} = $locus->known;

    my $de = $self->_locus_description_Entry;
    $de->delete(0, 'end');
    if (my $desc = $locus->description) {
        $de->insert(0, $desc);
    }

    my $ae = $self->_locus_alias_Entry;
    $ae->delete(0, 'end');
    if (my $alias_str = join(' ', $locus->list_aliases)) {
        $ae->insert(0, $alias_str);
    }

    $self->_update_locus_remark_widget($locus);

    return;
}

# Locus renaming plan
# On save the locus fields in all other TranscriptWindows with the same Locus get updated
# (Provide a button to open all TranscriptWindows with same Locus?)
# Choosing a different Locus from the dropdown menu updates
#   the Locus edit widgets with values from the other Locus.
# Editing the name of the Locus and saving renames the locus if already
#   saved, and keeps its otter_id.


sub _get_Locus_from_tk {
    my ($self) = @_;

    my $name    = $self->_get_locus_name or return;
    my $known   = $self->_get_locus_known;
    my $desc    = $self->_get_locus_description;
    my @aliases = $self->_get_locus_aliases;

    #warn "name '$name'\ndesc '$desc'\nremark '$remark'\n";

    my $locus = Hum::Ace::Locus->new;
    $locus->name($name);
    $locus->known($known);
    if ($name =~ /^([^:]+):/) {
        $locus->gene_type_prefix($1);
    }
    $locus->description($desc) if $desc;
    $locus->set_aliases(@aliases);

    $self->_get_locus_remarks($locus);

    return $locus;
}

sub _get_locus_name {
    my ($self) = @_;

    my $name = ${$self->{'_locus_name_var'}} or return;
    if ($name =~ /\s/) {
        $self->message("Error: whitespace in Locus name '$name'");
        return;
    }
    return $name;
}

sub _rename_locus {
    my ($self) = @_;

    my $name = $self->_get_locus_name or return;
    $self->SessionWindow->rename_locus($name);

    return;
}

sub update_Locus {
    my ($self, $locus) = @_;

    $self->_update_Locus_tk_fields($locus);
    $self->SubSeq->Locus($locus);

    return;
}

my $ann_tag = 'Annotation';
my $voc_tag = 'Controlled_Vocabulary';

sub _update_transcript_remark_widget {
    my ($self, $sub) = @_;

    $self->_update_remark_Entry($self->_transcript_remark_Entry,
                               $self->_SW_AceDB_DataSet->vocab_transcript,
                               $sub);

    return;
}

sub _update_locus_remark_widget {
    my ($self, $locus) = @_;

    $self->_update_remark_Entry($self->_locus_remark_Entry,
                               $self->_SW_AceDB_DataSet->vocab_locus,
                               $locus);

    return;
}

sub _update_remark_Entry {
    my ($self, $remark_text, $vocab, $obj) = @_;

    $remark_text->delete('1.0', 'end');
    foreach my $remark ($obj->list_remarks) {
        my $style = $vocab->{$remark} ? $voc_tag : '';
        $remark_text->insert('end',
            $remark     => $style,
            "\n"        => '',
        );
    }
    foreach my $remark ($obj->list_annotation_remarks) {
        my $style = $vocab->{$remark} ? $voc_tag : $ann_tag;
        $remark_text->insert('end',
            $remark     => $style,
            "\n"        => '',
        );
    }

    return;
}

sub _add_transcript_remark_widget {
    my ($self, $widget, $tsct_attrib_menu) = @_;

    my $rt = $self->_make_labelled_text_widget($widget, 'Remarks', $tsct_attrib_menu, -anchor => 'se');
    $self->_transcript_remark_Entry($rt);
    $self->_update_transcript_remark_widget($self->SubSeq);

    return;
}

sub _add_subseq_rename_widget {
    my ($self, $widget) = @_;

    $self->_subseq_name_Entry(
        $self->_make_labelled_entry_widget($widget, 'Name', $self->SubSeq->name, 22, -side => 'top')
        );

    return;
}

sub _populate_transcript_attribute_menu {
    my ($self, $menu) = @_;

    $self->_populate_attribute_menu($menu,
                                    $self->_transcript_remark_Entry,
                                    $self->_SW_AceDB_DataSet->vocab_transcript);

    return;
}

sub _populate_locus_attribute_menu {
    my ($self, $menu) = @_;

    $self->_populate_attribute_menu($menu,
                                    $self->_locus_remark_Entry,
                                    $self->_SW_AceDB_DataSet->vocab_locus);

    return;
}

sub _populate_attribute_menu {
    my ($self, $parent_menu, $text, $attribs) = @_;

    my %sub_menus;
    foreach my $phrase (sort keys %$attribs) {
        my $value = $attribs->{$phrase};
        my $menu;
        if ($value eq 'single') {
            $menu = $parent_menu;
        } else {
            $menu = $sub_menus{$value} ||= $parent_menu->Menu(-tearoff => 0);
        }
        $menu->add('command',
            -label      => $phrase,
            -command    => sub {
                _insert_phrase($text, $phrase);
            },
        );
    }

    # Add any cascade sub-menus onto the end of this menu
    foreach my $label (sort keys %sub_menus) {
        $parent_menu->add('cascade',
            -menu       => $sub_menus{$label},
            -label      => $label,
            -underline  => 0,
            );
    }

    return;
}

sub _make_labelled_text_widget {
    my ($self, $widget, $name, $menu, @pack) = @_;

    @pack = (-side => 'left') unless @pack;

    my $std_border = 3;
    my $frame = $widget->Frame(
        -border => $std_border,
        )->pack(@pack);
    my $label_annotation_frame = $frame->Frame(
        -border => $std_border,
        )->pack(
            -side => 'left',
            -expand => 1,
            -fill => 'y',
            );

    my @label_pack = (-side => 'top', -expand => 1, -fill => 'x');
    my @label_anchor = (-padx => $std_border, -anchor => 'w');
    my $text_label = $label_annotation_frame->Label(
        -text   => "$name:",
        @label_anchor,
        )->pack(@label_pack);

    # Button for setting Visible/annotation remarks
    my @annotation_color = (-foreground => 'white', -background => 'IndianRed3');
    my $annotation_button = $label_annotation_frame->Button(
        -text   => $ann_tag,
        @label_anchor,
        @annotation_color,
        -activeforeground => 'white',
        -activebackground => 'IndianRed2',
        )->pack(@label_pack);

    my $text = $frame->Scrolled('Text',
        -scrollbars         => 'e',
        -width              => 36,
        -height             => 4,
        -exportselection    => 1,
        -background         => 'white',
        -wrap               => 'word',
        );
    $text->pack(-side => 'left', -expand => 1, -fill => 'both');
    $text->tagConfigure($ann_tag, @annotation_color);
    $text->tagLower($ann_tag, 'sel');
    $text->tagConfigure($voc_tag,
            -foreground => 'black',
            -background => 'GreenYellow',
            );
    $text->tagLower($voc_tag, 'sel');

    my $tw = $text->Subwidget('text');
    my $class = ref($tw);

    # We need to ignore any sequences which edit text when inside
    # controlled vocabulary tagged text
    foreach my $seq (qw{

        <Button-2>
        <ButtonRelease-2>

        <<Cut>>
        <<Paste>>

        <Control-Key-t>

        <Return>
        <Control-Key-o>

        <Tab>
        <Control-Key-i>

        <F2>  <F3>

    }) {
        $tw->bind($seq, [\&_ignore_in_controlled_vocab, Tk::Ev('K')]);
    }

    # Keyboard sequences which delete backwards need to take out the whole
    # line of controlled vocabulary in one go...
    foreach my $seq (qw{

        <BackSpace>
        <Control-Key-h>
        <Meta-Key-BackSpace>

    }) {
        $tw->bind($seq, [\&_backspace_delete_whole_ctrl_vocab_line, Tk::Ev('K')]);
    }

    # ... as do sequences which delete forwards.
    foreach my $seq (qw{

        <Delete>
        <Meta-Key-d>

        <Control-Key-k>
        <Control-Key-d>

    }) {
        $tw->bind($seq, [\&_forward_delete_whole_ctrl_vocab_line, Tk::Ev('K')]);
    }

    # Do not post the Text class's built in popup menu
    $tw->bind($class, '<Button-3>', '');
    $tw->bind('<Button-3>', [\&_post_ctrl_vocab_menu, $menu, Tk::Ev('X'), Tk::Ev('Y')]);

    # Remove key binding for keyboard input and replace with our own which
    # inserts characters using the same tag as the rest of the line, or
    # which ignores characters with the controlled vocabulary tag.
    $tw->bind($class, '<Key>', '');
    $tw->bind('<Key>', [\&_insert_char, Tk::Ev('A')]);


    my (@tags) = $tw->bindtags;
    # warn "tags=(@tags)\n";
    $tw->bindtags([@tags[1, 0, 2, 3]]);

    $annotation_button->configure(-command => sub {
        my ($line) = $text->index('insert') =~ /^(\d+)/;
        my $line_start = "$line.0";
        my @this_line = ("$line_start", "$line_start lineend");
        #warn "line start = $line_start";
        my $annotation_is_set = 0;
        if (grep { $_ eq $ann_tag } $text->tagNames("$line_start")) {
            $annotation_is_set = 1;
            $text->tagRemove($ann_tag, @this_line);
        }
        unless ($annotation_is_set) {
            $text->tagAdd($ann_tag, @this_line);
        }
    });

    return $tw;
}

sub _post_ctrl_vocab_menu {
    my ($text, $menu, $x, $y) = @_;

    $menu->Post($x, $y);

    return;
}

sub _insert_phrase {
    my ($text, $phrase) = @_;

    my @vocab_lines = $text->tagRanges($voc_tag);
    my $see_i;
    for (my $i = 0; $i < @vocab_lines; $i += 2) {
        my ($a, $b) = @vocab_lines[$i, $i + 1];
        my $subtext = $text->get($a, $b);
        if ($subtext eq $phrase) {
            $see_i = $a;
            last;
        }
    }
    unless ($see_i) {
        $see_i = '1.0';
        $text->insert($see_i,
            $phrase => $voc_tag,
            "\n"    => '',
            );
    }
    $text->see($see_i);

    return;
}

sub _backspace_delete_whole_ctrl_vocab_line {
    my ($text, $keysym) = @_;

    my $prev = $text->index('insert - 1 chars');

    if (_is_ctrl_vocab_char($text, $prev)) {
        $text->delete("$prev linestart", "$prev lineend");
        $text->break;
    }
    elsif ($text->compare('insert', '==', 'insert linestart')) {
        # If this or the previous line is controlled vocab, just move the cursor
        if (_is_ctrl_vocab_char($text, "$prev - 1 chars") or _is_ctrl_vocab_char($text, 'insert')) {
            $text->SetCursor('insert - 1 chars');
            $text->break;
        }
    }

    return;
}

sub _forward_delete_whole_ctrl_vocab_line {
    my ($text, $keysym) = @_;

    if (_is_ctrl_vocab_char($text, 'insert')) {
        $text->delete('insert linestart', 'insert lineend');
        $text->break;
    }
    elsif ($text->compare('insert', '==', 'insert lineend')) {
        # If this or the next line is controlled vocab, just move the cursor
        if (_is_ctrl_vocab_char($text, 'insert + 1 chars') or _is_ctrl_vocab_char($text, 'insert - 1 chars')) {
            $text->SetCursor('insert + 1 chars');
            $text->break;
        }
    }

    return;
}

sub _ignore_in_controlled_vocab {
    my ($text, $keysym) = @_;

    # Need to choose "insert" for keyboard events
    # and "current" for mouse events.
    my $posn = $keysym ? 'insert' : 'current';

    if ($text->compare($posn, '==', "$posn linestart")) {
        # Return at linestart is always OK
        return if $keysym eq 'Return';
    }

    if (_is_ctrl_vocab_char($text, $posn)) {
        $text->break;
    }

    return;
}

sub _is_ctrl_vocab_char {
    my ($text, $posn) = @_;

    return grep { $_ eq $voc_tag } $text->tagNames($posn);
}

# Inserts (printing) characters with the same style as the rest of the line
sub _insert_char {
    my ($text, $char) = @_;

    # We only want to insert printing characters in the Text box!
    # [:print:] is the POSIX class of printing characters.
    return unless $char =~ /[[:print:]]/;

    # Do not edit controlled vocabulary
    return if grep { $_ eq $voc_tag } $text->tagNames('insert linestart');

    # Expected behaviour is that any selected text will
    # be replaced by what the user types.
    $text->deleteSelected;

    # There will only ever be one or zero tags per line in out Text box.
    my ($tag) =
        $text->compare('insert linestart', '==', 'insert lineend')
        ? ( $ann_tag )
        : grep { $_ eq $ann_tag } $text->tagNames('insert linestart');

    $text->insert('insert', $char, $tag);

    return;
}

sub _make_labelled_entry_widget {
    my ($self, $widget, $name, $value, $size, @pack) = @_;

    @pack = (-side => 'left') unless @pack;

    my $frame = $widget->Frame(
        -border => 3,
        )->pack(@pack);

    $frame->Label(
        -text   => "$name:",
        -anchor => 's',
        -padx   => 6,
        )->pack(-side => 'left');

    my $entry = $frame->Entry(
        -width              => $size,
        -exportselection    => 1,
        );
    $entry->pack(-side => 'left');
    $entry->insert(0, $value) if $value;
    return $entry;
}

sub _add_start_end_method_widgets {
    my ($self, $widget) = @_;

    my $top = $widget->toplevel;
    my $frame = $widget->Frame(
        -border => 6,
        )->pack(
            -side   => 'top',
            -expand => 0,
            );

    $frame->Label(
        -text   => 'Start:',
        -padx   => 6,
        )->pack(-side => 'left');

    # Menu
    my $snf = $self->SubSeq->start_not_found;
    unless ($snf) {
        $snf = 'utr' if $self->SubSeq->utr_start_not_found;
    }
    my $om = $frame->SmartOptionmenu(
        -variable   => \$snf,
        -options    => [
                ['Found'                =>     0],
                ['CDS not found - 1'    =>     1],
                ['CDS not found - 2'    =>     2],
                ['CDS not found - 3'    =>     3],
                ['UTR incomplete'       => 'utr'],
            ],
        -takefocus  => 0, # Doesn't work ...
        -command    => sub{
            $top->focus, # ... so need this instead
            $self->update_translation,
            },
        )->pack(
            -side => 'left',
            );

    # Pad between Start and End not found widgets
    $frame->Frame(
        -width  => 10,
        )->pack(-side => 'left');

    $self->{'_start_not_found_variable'} = \$snf;

    $frame->Label(
        -text   => 'End:',
        -padx   => 6,
        )->pack(-side => 'left');

    # Menu
    my( $enf );
    $om = $frame->Optionmenu(
        -variable   => \$enf,
        -options    => [
                ['Found'        => 0],
                ['Not found'    => 1],
            ],
        -takefocus  => 0,   # Doesn't work
        -command    => sub{ $top->focus },  # Need this
        )->pack( -side => 'top' );
    $enf = $self->SubSeq->end_not_found;
    $om->menu->invoke($enf);
    #warn "enf = $enf";

    $self->{'_end_not_found_variable'} = \$enf;

    $om->bind('<Destroy>', sub{ $self = undef });

    return;
}

sub _start_not_found_from_tk {
    my ($self) = @_;
    return ${$self->{'_start_not_found_variable'}} || 0;
}

sub _end_not_found_from_tk {
    my ($self) = @_;
    return ${$self->{'_end_not_found_variable'}} || 0;
}

sub _subseq_name_Entry {
    my ($self, $entry) = @_;

    if ($entry) {
        $self->{'_subseq_name_Entry'} = $entry;
    }
    return $self->{'_subseq_name_Entry'};
}

sub _transcript_remark_Entry {
    my ($self, $_transcript_remark_Entry) = @_;

    if ($_transcript_remark_Entry) {
        $self->{'_transcript_remark_Entry'} = $_transcript_remark_Entry;
    }
    return $self->{'_transcript_remark_Entry'};
}

sub _locus_remark_Entry {
    my ($self, $_locus_remark_Entry) = @_;

    if ($_locus_remark_Entry) {
        $self->{'_locus_remark_Entry'} = $_locus_remark_Entry;
    }
    return $self->{'_locus_remark_Entry'};
}

sub _get_transcript_remarks {
    my ($self, $sub) = @_;

    confess "Missing SubSeq argument" unless $sub;

    return $self->_get_remarks_from_Entry($self->_transcript_remark_Entry, $sub);
}

sub _get_locus_remarks {
    my ($self, $locus) = @_;

    confess "Missing Locus argument" unless $locus;

    return $self->_get_remarks_from_Entry($self->_locus_remark_Entry, $locus);
}

sub _get_remarks_from_Entry {
    my ($self, $text, $obj) = @_;

    my %ann_index = $text->tagRanges($ann_tag);
    my $line = 0;
    my $rem     = [];
    my $ann_rem = [];
    foreach my $string (split /\n/, $text->get('1.0', 'end')) {
        $line++;
        # Trim trailing spaces and full-stops from remark
        $string =~ s/[\s\.]+$//;
        next if $string eq '';
        my $array = $ann_index{"$line.0"} ? $ann_rem : $rem;
        push(@$array, $string);
    }
    $obj->set_remarks(@$rem);
    $obj->set_annotation_remarks(@$ann_rem);

    return;
}

sub _locus_description_Entry {
    my ($self, $_locus_description_Entry) = @_;

    if ($_locus_description_Entry) {
        $self->{'_locus_description_Entry'} = $_locus_description_Entry;
    }
    return $self->{'_locus_description_Entry'};
}

sub _get_locus_description {
    my ($self) = @_;

    my $desc = $self->_locus_description_Entry->get;
    $desc =~ s/(^\s+|\s+$)//g;
    if ($desc) {
        return $desc;
    } else {
        return;
    }
}

sub _locus_alias_Entry {
    my ($self, $_locus_alias_Entry) = @_;

    if ($_locus_alias_Entry) {
        $self->{'_locus_alias_Entry'} = $_locus_alias_Entry;
    }
    return $self->{'_locus_alias_Entry'};
}

sub _get_locus_aliases {
    my ($self) = @_;

    my $alias_str = $self->_locus_alias_Entry->get;
    $alias_str =~ s/(^\s+|\s+$)//g;
    my @aliases = split /\s+/, $alias_str;
    if (@aliases) {
        return @aliases;
    } else {
        return;
    }
}

sub _get_subseq_name {
    my ($self) = @_;

    my $name = $self->_subseq_name_Entry->get;
    $name =~ s/\s+//g;
    return $name || 'NO-NAME';
}

# Not used
sub _set_subseq_name {
    my ($self, $new) = @_;

    my $entry = $self->_subseq_name_Entry;
    $entry->delete(0, 'end');
    $entry->insert(0, $new);

    return;
}

sub _method_name_var {
    my ($self, $var_ref) = @_;

    if ($var_ref) {
        $self->{'_method_name_var'} = $var_ref;
    }
    return $self->{'_method_name_var'};
}

sub _get_GeneMethod_from_tk {
    my ($self) = @_;

    my $meth_name = ${$self->_method_name_var};
    return $self->SessionWindow->get_GeneMethod($meth_name);
}

sub _canvas_insert_character {
    my ($self, $canvas, $char) = @_;

    my $text = $canvas->focus or return;
    $canvas->insert($text, 'insert', $char);
    $self->re_highlight($text);
    $self->_update_splice_strings($text);
    $self->_remove_spurious_splice_sites;

    return;
}

sub _increment_int {
    my ($self) = @_;

    my $canvas = $self->canvas;
    my $text = $canvas->focus or return;
    my $num = $canvas->itemcget($text, 'text');
    if ($num =~ /^\d+$/) {
        $num++;
        $canvas->itemconfigure($text, -text => $num);
        $self->re_highlight($text);
        $self->_update_splice_strings($text);
        $self->_remove_spurious_splice_sites;
    }

    return;
}

sub _decrement_int {
    my ($self) = @_;

    my $canvas = $self->canvas;
    my $text = $canvas->focus or return;
    my $num = $canvas->itemcget($text, 'text');
    if ($num =~ /^\d+$/) {
        $num--;
        $canvas->itemconfigure($text, -text => $num);
        $self->re_highlight($text);
        $self->_update_splice_strings($text);
        $self->_remove_spurious_splice_sites;
    }

    return;
}

sub _canvas_text_go_left {
    my ($self) = @_;

    my $canvas = $self->canvas;
    my $text = $canvas->focus or return;
    my $pos = $canvas->index($text, 'insert');
    $canvas->icursor($text, $pos - 1);

    return;
}

sub _canvas_text_go_right {
    my ($self) = @_;

    my $canvas = $self->canvas;
    my $text = $canvas->focus or return;
    my $pos = $canvas->index($text, 'insert');
    $canvas->icursor($text, $pos + 1);

    return;
}

sub _canvas_backspace {
    my ($self) = @_;

    my $canvas = $self->canvas;
    my $text = $canvas->focus or return;
    my $pos = $canvas->index($text, 'insert')
        or return;  # Don't delete when at beginning of string
    $canvas->dchars($text, $pos - 1);
    $self->re_highlight($text);
    $self->_update_splice_strings($text);
    $self->_remove_spurious_splice_sites;

    return;
}

sub _select_all_exon_pos {
    my ($self) = @_;

    my $canvas = $self->canvas;
    return $self->highlight($canvas->find('withtag', 'exon_pos'));
}

sub _left_button_handler {
    my ($self) = @_;

    return if $self->delete_message;
    $self->_deselect_all;
    $self->_shift_left_button_handler;

    return;
}

sub _focus_on_current_text {
    my ($self) = @_;

    my $canvas = $self->canvas;
    my ($obj) = $canvas->find('withtag', 'current') or return;
    if (grep { /translation_region|exon_pos/ } $canvas->gettags($obj) ) {
        $canvas->focus($obj);

        # Position the icursor at the end of the text
        $canvas->icursor($obj, 'end');

        if ($canvas->itemcget($obj, 'text') eq $self->_empty_string) {
            $canvas->itemconfigure($obj,
                -text   => '',
                );
        }
        $canvas->focus($obj);
    }

    return;
}

sub _shift_left_button_handler {
    my ($self) = @_;

    my $canvas = $self->canvas;
    $canvas->focus("");

    my ($obj) = $canvas->find('withtag', 'current')  or return;
    my %tags  = map { $_ => 1 } $canvas->gettags($obj);

    if ($self->is_selected($obj)) {
        $self->remove_selected($obj);
    }
    elsif ($tags{'exon_pos'} or $tags{'translation_region'}) {
        $self->highlight($obj);
    }
    elsif ($tags{'exon_furniture'}) {
        my ($exon_id) = grep { /^exon_id/ } keys %tags;
        my( @select, @deselect );
        foreach my $ex_obj ($canvas->find('withtag', "exon_pos&&$exon_id")) {
            if ($self->is_selected($ex_obj)) {
                push(@deselect, $ex_obj);
            } else {
                push(@select,   $ex_obj);
            }
        }
        $self->remove_selected(@deselect) if @deselect;
        $self->highlight(@select)         if @select;
    }

    return;
}

sub _control_left_button_handler {
    my ($self) = @_;

    my $canvas = $self->canvas;
    my ($obj) = $canvas->find('withtag', 'current') or return;
    my %tags = map { $_ => 1 } $canvas->gettags($obj);
    if ($tags{'plus_strand'}) {
        $self->_set_tk_strand(-1);
    }
    elsif ($tags{'minus_strand'}) {
        $self->_set_tk_strand(1);
    }
    $self->_update_splice_strings($obj);
    $self->_remove_spurious_splice_sites;

    return;
}

sub _set_tk_strand {
    my ($self, $strand) = @_;

    my( $del_tag, $draw_method );
    if ($strand == 1) {
        $del_tag = 'minus_strand';
        $draw_method = '_draw_plus';
    } else {
        $del_tag = 'plus_strand';
        $draw_method = '_draw_minus';
    }

    my $canvas = $self->canvas;
    foreach my $obj ($canvas->find('withtag', $del_tag)) {
        my @tags = grep { $_ ne $del_tag } $canvas->gettags($obj);
        $canvas->delete($obj);
        my ($i) = map { /exon_id-(\d+)/ } @tags;
        #warn "Drawing strand indicator for exon $i\n";
        my( $size, $half, $pad, $text_len,
            $x1, $y1, $x2, $y2 ) = $self->_exon_holder_coords($i - 1);
        $self->$draw_method($x1 + $half, $y1, $size, @tags);
    }

    $self->_sort_all_coordinates;
    $self->_remove_spurious_splice_sites;

    return;
}

sub _toggle_tk_strand {
    my ($self) = @_;

    if ($self->_strand_from_tk == 1) {
        $self->_set_tk_strand(-1);
    } else {
        $self->_set_tk_strand(1);
    }

    return;
}

sub _empty_string {
    return '<empty>';
}

sub _deselect_all {
    my ($self) = @_;

    my $canvas = $self->canvas;

    # Avoid unselectable empty text objects
    if (my $obj = $canvas->focus) {
        if ($canvas->type($obj) eq 'text') {
            my $text_string = $canvas->itemcget($obj, 'text');
            unless ($text_string) {
                $canvas->itemconfigure($obj,
                    -text   => $self->_empty_string,
                    );
            }
        }
    }
    $canvas->focus("");

    $self->SUPER::deselect_all;

    return;
}

sub _export_highlighted_text_to_selection {
    my ($self, $offset, $max_bytes) = @_;

    my @text = $self->get_all_selected_text;
    my $clip = '';
    if (@text == 1) {
        $clip = $text[0];
    } else {
        for (my $i = 0; $i < @text; $i += 2) {
            my($start, $end) = @text[$i, $i + 1];
            $end ||= $self->_empty_string;
            $clip .= "$start  $end\n";
        }
    }

    return substr($clip, $offset, $max_bytes);
}

sub _middle_button_paste {
    my ($self) = @_;

    my $canvas = $self->canvas;

    my @ints = $self->integers_from_clipboard;
    return unless @ints;

    $self->_deselect_all;

    my $did_paste = 0;
    if (my ($obj)  = $canvas->find('withtag', 'current')) {
        $did_paste = 1;
        my %obj_tags = map {$_ => 1} $canvas->gettags($obj);
        # warn "Clicked on object with tags: ", join(', ', map "'$_'", sort keys %obj_tags);
        if ($obj_tags{'max_width_rectangle'}) {
            $did_paste = 0;
        }
        elsif ($obj_tags{'exon_pos'} or $obj_tags{'translation_region'}) {
            $canvas->itemconfigure($obj,
                -text   => $ints[0],
                );
            $self->highlight($obj);
            $self->_update_splice_strings($obj) if $obj_tags{'exon_pos'};
            #$self->_remove_spurious_splice_sites;
        }
        elsif ($obj_tags{'exon_furniture'}) {
            # Set coordinates with middle button on strand indicator
            my ($start, $end) = @ints;
            return unless $start and $end;
            if ($start > $end) {
                ($start, $end) = ($end, $start);
            }
            my ($exon_num) = map { /exon_id-(\d+)/ } keys %obj_tags;
            warn "start=$start end=$end exon=$exon_num";
            my $pp = ($self->_position_pairs)[$exon_num - 1];
            $self->_set_position_pair_text($pp, [$start, $end]);
            $self->highlight(@$pp[0,1]);
        }
    }

    unless ($did_paste) {
        my @pos = $self->_all_position_pair_text;

        # If there is only 1 <empty> pair, write to it
        my $was_empty = 0;
        if (@pos == 1 and $pos[0][0] == 0 and $pos[0][1] == 0) {
            $self->_trim_position_pairs(1);
            $was_empty = 1;
        }

        for (my $i = 0; $i < @ints; $i += 2) {
            $self->_add_coordinate_pair(@ints[$i, $i + 1]);
        }

        $self->fix_window_min_max_sizes;
    }

    $self->_remove_spurious_splice_sites;

    return;
}

sub _next_exon_holder_coords {
    my ($self) = @_;

    my $i = $self->_next_position_pair_index;
    return $self->_exon_holder_coords($i);
}

sub _exon_holder_coords {
    my ($self, $i) = @_;

    $i++;   # Move exons down 1 line to make space for splice site sequence
    my( $size, $half, $pad, $text_len, @bbox ) = $self->_coord_matrix;
    my $y_offset = $i * ($size + (2 * $pad));
    $bbox[1] += $y_offset;
    $bbox[3] += $y_offset;
    return( $size, $half, $pad, $text_len, @bbox );
}

sub _coord_matrix {
    my ($self) = @_;

    my( $m );
    unless ($m = $self->{'_coord_matrix'}) {
        my $uw      = $self->font_unit_width;
        my (undef, $size) = $self->named_font('mono', 'linespace');
        my $max_chars = 8;  # For coordinates up to 99_999_999
        my $text_len = $max_chars * $uw;
        my $half = int($size / 2);
        my $pad  = int($size / 6);

        my $x1 = $half + $size + (2 * $text_len);
        my $y1 = $half;
        $m = [
            $size, $half, $pad, $text_len,
            $x1,               $y1,
            $x1 + ($size * 2), $y1 + $size,
            ];
        $self->{'_coord_matrix'} = $m;

        # Create rectangle to pad canvas to max number width
        my $canvas = $self->canvas;
        my $max_width = 4 * ($size + $text_len);
        #warn "max_width = $max_width\n";
        $canvas->createRectangle(
            $half, $half + $size,
            $half + $max_width, $half + (2 * $size),
            -fill       => undef,
            -outline    => undef,
            -tags       => ['max_width_rectangle'],
            );
    }

    return @$m;
}

sub _update_splice_strings {
    my ($self, $tag_or_id) = @_;

    my $canvas = $self->canvas;

    my %exons_to_update;
    foreach my $obj ($canvas->find('withtag', $tag_or_id)) {
        my ($exon_id) = grep { /^exon_id/ } $canvas->gettags($obj);
        $exons_to_update{$exon_id} = 1 if $exon_id;
    }

    my @good = (
        -font => $self->named_font('mono'),
        -fill => 'YellowGreen',
        );
    my @bad  = (
        -font => $self->named_font('listbold'),
        -fill => "#ee2c2c",     # firebrick2
        );

    foreach my $exon_id (keys %exons_to_update) {

        my ($start, $end) = map { $canvas->itemcget($_, 'text') } $canvas->find('withtag', "$exon_id&&exon_pos");
        if ($start > $end) {
            ($start, $end) = ($end, $start);
        }

        my $strand = $self->_exon_strand_from_tk($exon_id);
        my ($acc_str, $don_str) = $self->_get_splice_acceptor_donor_strings($start, $end, $strand);


        my ($acceptor_txt) = $canvas->find('withtag', "$exon_id&&splice_acceptor");
        $canvas->itemconfigure($acceptor_txt,
            -text => $acc_str,
            $acc_str eq 'ag' ? @good : @bad,
        );

        my ($donor_txt) = $canvas->find('withtag', "$exon_id&&splice_donor");
        $canvas->itemconfigure($donor_txt,
            -text => substr($don_str, 1, 2),
            # OK if first two bases in intron are "gt", or are "gc"
            # preceeded by "g" at the last base of the exon.
            $don_str =~ /(.gt|ggc)/ ? @good : @bad,
        );
    }

    return;
}

sub _remove_spurious_splice_sites {
    my ($self) = @_;

    my $canvas = $self->canvas;

    my @pps = sort { $a->[0] <=> $b->[0] } $self->_position_pairs;

    return unless @pps;

    my $initial_exon_id = $pps[0]->[2];
    my $terminal_exon_id = $pps[-1]->[2];

    $self->_update_splice_strings('exon_end');

    my ($acceptor_txt) = $canvas->find('withtag', "$initial_exon_id&&splice_acceptor");
    $canvas->itemconfigure($acceptor_txt, -text => '');

    my ($donor_txt) = $canvas->find('withtag', "$terminal_exon_id&&splice_donor");
    $canvas->itemconfigure($donor_txt, -text => '');

    return;
}

sub _get_splice_acceptor_donor_strings {
    my ($self, $start, $end, $strand) = @_;

    # Fetch the splice donor and acceptor sequences before switching start/end for reverse strand
    my ($splice_acceptor_str, $splice_donor_str);
    if ($start and $end) {
        try { $splice_acceptor_str = $self->SubSeq->splice_acceptor_seq_string($start, $end, $strand) };
        try { $splice_donor_str    = $self->SubSeq->splice_donor_seq_string(   $start, $end, $strand) };
    }
    $splice_acceptor_str ||= '??';
    $splice_donor_str    ||= '???';

    return ($splice_acceptor_str, $splice_donor_str);
}

sub _add_exon_holder {
    my ($self, $start, $end, $strand) = @_;
    $start ||= $self->_empty_string;
    $end   ||= $self->_empty_string;

    my $arrow = ($strand == 1) ? 'last' : 'first';
    if ($strand == -1) {
        ($start, $end) = ($end, $start);
    }

    my $canvas  = $self->canvas;
    my $font    = $self->named_font('mono');
    my $exon_id = 'exon_id-'. $self->_next_exon_number;
    my( $size, $half, $pad, $text_len,
        $x1, $y1, $x2, $y2 ) = $self->_next_exon_holder_coords;
    my $arrow_size = $half - $pad;

    $canvas->createText(
        $x1 - $text_len, $y1 + $half,
        -anchor     => 'e',
        -text       => '..',
        -font       => $font,
        -tags       => [$exon_id, 'splice_acceptor'],
        );

    my $start_text = $canvas->createText(
        $x1, $y1 + $half,
        -anchor     => 'e',
        -text       => $start,
        -font       => $font,
        -tags       => [$exon_id, 'exon_pos', 'exon_start'],
        );

    if ($strand == 1) {
        $self->_draw_plus ($x1 + $half, $y1, $size, $exon_id, 'exon_furniture');
    } else {
        $self->_draw_minus($x1 + $half, $y1, $size, $exon_id, 'exon_furniture');
    }

    my $end_text = $canvas->createText(
        $x2, $y1 + $half,
        -anchor     => 'w',
        -text       => $end,
        -font       => $font,
        -tags       => [$exon_id, 'exon_pos', 'exon_end'],
        );

    $self->_add_position_pair($start_text, $end_text, $exon_id);

    $canvas->createText(
        $x2 + $text_len, $y1 + $half,
        -anchor     => 'w',
        -text       => '..',
        -font       => $font,
        -tags       => [$exon_id, 'splice_donor'],
        );


    my $bkgd = $canvas->createRectangle(
        $x1, $y1, $x2, $y2,
        -fill       => 'white',
        -outline    => undef,
        -tags       => [$exon_id, 'exon_furniture'],
        );
    $canvas->lower($bkgd, $start_text);

    $self->_update_splice_strings($exon_id);

    $self->_position_mobile_elements;

    # Return how big we were
    return $size + $pad;
}

sub _position_mobile_elements {
    my ($self) = @_;

    my $canvas = $self->canvas;
    return unless $canvas->find('withtag', 'mobile');
    my ($font, # as in _add_exon_holder
        $size) = $self->named_font('mono', 'linespace');
    my $pad  = int($size / 2);

    my $mobile_top   = ($canvas->bbox( 'mobile'))[1];
    my $fixed_bottom = ($canvas->bbox('!mobile'))[3] + $pad;

    $canvas->move('mobile', 0, $fixed_bottom - $mobile_top);

    return;
}

sub _draw_plus {
    my ($self, $x, $y, $size, @tags) = @_;

    # size is now entire line height
    $x += $size / 9;
    $y += $size / 9;
    $size *= 7/9;

    my $third = $size / 3;

    $self->canvas->createPolygon(
        $x +     $third,  $y             ,
        $x + 2 * $third,  $y             ,
        $x + 2 * $third,  $y +     $third,
        $x + $size     ,  $y +     $third,
        $x + $size     ,  $y + 2 * $third,
        $x + 2 * $third,  $y + 2 * $third,
        $x + 2 * $third,  $y + $size,
        $x +     $third,  $y + $size,
        $x +     $third,  $y + 2 * $third,
        $x             ,  $y + 2 * $third,
        $x             ,  $y +     $third,
        $x +     $third,  $y +     $third,
        -tags       => [@tags, 'plus_strand'],
        -fill       => 'grey',
        -outline    => 'DimGrey',
        -joinstyle  => 'miter',
        );

    return;
}

sub _draw_minus {
    my ($self, $x, $y, $size, @tags) = @_;

    # size is now entire line height
    $x += $size / 9;
    $y += $size / 9;
    $size *= 7/9;

    my $third = $size / 3;

    $self->canvas->createRectangle(
        $x        ,  $y +     $third,
        $x + $size,  $y + 2 * $third,
        -tags       => [@tags, 'minus_strand'],
        -fill       => 'grey',
        -outline    => 'DimGrey',
        );

    return;
}

sub _strand_from_tk {
    my ($self, $keep_quiet) = @_;

    my $canvas = $self->canvas;
    my @fwd = $canvas->find('withtag', 'plus_strand' );
    my @rev = $canvas->find('withtag', 'minus_strand');

    my $guess = 0;
    my( $strand );
    if (@fwd >= @rev) {
        $strand = 1;
        $guess = 1 if @rev;
    } else {
        $strand = -1;
        $guess = 1 if @fwd;
    }

    if ($guess) {
        my $dir = $strand == 1 ? 'forward' : 'reverse';
        $self->message("Inconsistent exon directions.  Guessing '$dir'")
            unless $keep_quiet;
    }

    return $strand;
}

{
    my $tr_tag = 'translation_region';

    sub _draw_translation_region {
        my ($self, $sub) = @_;

        # Get the translation region from the
        # canvas or the SubSequence
        my( @trans );
        if ($sub) {
            return unless $sub->translation_region_is_set;  ### Why is this needed?
            @trans = $sub->translation_region;
        } else {
            @trans = $self->_translation_region_from_tk;
            unless (@trans) {
                @trans = $self->SubSeq->translation_region;
            }
        }

        # Delete the existing translation region, "CDS" label, and any highlights or lowlights
        my $canvas = $self->canvas;
        if (my @tr_coord = $canvas->find('withtag', $tr_tag)) {
            $self->remove_selected(@tr_coord);
            foreach my $obj (@tr_coord) {
                if ($self->was_selected($obj)) {
                    $self->delete_was_selected($obj);
                }
            }
            $canvas->delete(@tr_coord, 't_cds');
        }

        # Don't draw anything if it isn't coding
        my( $meth, $strand );
        if ($sub) {
            $meth = $sub->GeneMethod;
            $strand = $sub->strand;
        } else {
            $meth = $self->_get_GeneMethod_from_tk;
            $strand = $self->_strand_from_tk;
        }
        return unless $meth->coding;

        my( $size, $half, $pad, $text_len, $x1, $y1, $x2, $y2 ) = $self->_coord_matrix;
        my $font = $self->named_font('listbold');

        if ($strand == -1) {
            @trans = reverse @trans;
        }

        $canvas->createText(
            $x1 - $text_len, $y1,
            -anchor => 'e',
            -text   => $trans[0],
            -font   => $font,
            -tags   => ['t_start', $tr_tag],
            );

        # Put the CDS label between start and end editable text
        $canvas->createText(
            $x1 + (($x2 - $x1) / 2), $y1,
            -anchor => 'center',
            -text   => 'CDS',
            -font   => $font,
            -tags   => ['t_cds'],
            );

        $canvas->createText(
            $x2 + $text_len, $y1,
            -anchor => 'w',
            -text   => $trans[1],
            -font   => $font,
            -tags   => ['t_end', $tr_tag],
            );

        return;
    }

    sub _translation_region_from_tk {
        my ($self) = @_;

        my $canvas = $self->canvas;
        my( @region );
        foreach my $obj ($canvas->find('withtag', $tr_tag)) {
            push(@region, $canvas->itemcget($obj, 'text'));
        }
        return(sort {$a <=> $b} @region);
    }
}

sub _tk_t_start {
    my ($self, $start) = @_;

    my $canvas = $self->canvas;
    my ($t_txt) = $canvas->find('withtag', 't_start')
        or confess "Can't get t_start";
    if ($start) {
        $canvas->itemconfigure($t_txt, -text => $start);
    } else {
        ($start) = $canvas->itemcget($t_txt, 'text');
    }
    return $start;
}

sub _tk_t_end {
    my ($self, $end) = @_;

    my $canvas = $self->canvas;
    my ($t_txt) = $canvas->find('withtag', 't_end')
        or confess "Can't get t_end";
    if ($end) {
        $canvas->itemconfigure($t_txt, -text => $end);
    } else {
        ($end) = $canvas->itemcget($t_txt, 'text');
    }
    return $end;
}

sub _get_SubSeq_if_changed {
    my ($self) = @_;

    my $old = $self->SubSeq;
    my $new = $self->_new_SubSeq_from_tk;

    # Preserve Otter ids in SubSeq (not attached Locus)
    $new->take_otter_ids($old);

    # Get the otter_id for the locus, or take it from
    # an existing locus if we are renaming.
    $self->_manage_locus_otter_ids($old, $new);

    # warn sprintf "Comparing old:\n%s\nTo new:\n%s",
    #     $old->ace_string, $new->ace_string;

    if ($old->ensembl_dbID and $new->ace_string eq $old->ace_string) {
        # SubSeq is saved, and there are no changes.
        return;
    }

    # warn sprintf "OLD:\n>%s<\nNEW:>%s<\n", $old->ace_string, $new->ace_string;

    my $new_name = $new->name;
    if ($new_name ne $self->name) {
        if ($self->SessionWindow->get_SubSeq($new_name)) {
            confess "Error: SubSeq '$new_name' already exists\n";
        }
    }

    $new->validate;
    $new->set_seleno_remark_from_translation;
    return $new;
}

sub _manage_locus_otter_ids {
    my ($self, $old, $new) = @_;

    my $new_locus = $new->Locus;
    my $new_locus_name = $new_locus->name;

    # Copy locus otter_id from existing Locus of same name if present
    my $SessionWindow_locus = $self->SessionWindow->get_Locus_by_name($new_locus_name);
    if ($SessionWindow_locus and my $SessionWindow_locus_otter_id = $SessionWindow_locus->otter_id) {
        $new_locus->otter_id($SessionWindow_locus_otter_id);
    }
    elsif (my $old_locus = $old->Locus) {
        # We don't have an otter_id, but did the old locus have an otter_id?
        my $old_locus_name = $old_locus->name;
        if (my $old_otter_id = $old_locus->otter_id
            and $new_locus_name ne $old_locus_name)
        {
            my $prefix_pat = qr{^(\w+:)};
            my ($old_pre) = $old_locus_name =~ /$prefix_pat/;
            my ($new_pre) = $new_locus_name =~ /$prefix_pat/;
            if ($new_pre and $new_pre ne ($old_pre || '')) {
                # warn "'$new_pre' ne '$old_pre'";
                confess "New locus with '$new_pre' prefix would steal Otter ID from locus '$old_locus_name'\n";
            }
            # Looks like a rename, so we steal the otter_id from the old locus.
            $new_locus->otter_id($old_otter_id);
            $new_locus->previous_name($old_locus_name);
            $self->message("Locus object '$new_locus_name' has now stolen Otter ID from '$old_locus_name'");
        }
    }

    return;
}

sub _new_SubSeq_from_tk {
    my ($self) = @_;

    my $new = $self->SubSeq->clone;
    $new->unset_Locus;
    $new->unset_translation_region;
    $new->translation_region     ( $self->_translation_region_from_tk  );
    $new->name                   ( $self->_get_subseq_name             );
    $new->replace_all_Exons      ( $self->_Exons_from_canvas           );
    $new->GeneMethod             ( $self->_get_GeneMethod_from_tk      );
    $new->strand                 ( $self->_strand_from_tk              );
    $new->end_not_found          ( $self->_end_not_found_from_tk       );
    $new->evidence_hash          ( $self->_evidence_hash               );
    $new->Locus                  ( $self->_get_Locus_from_tk           );
    $self->_get_transcript_remarks($new);

    my $snf = $self->_start_not_found_from_tk;
    if ($snf eq 'utr') {
        $new->utr_start_not_found(1);
        $new->start_not_found(0);
    } else {
        $new->utr_start_not_found(0);
        $new->start_not_found($snf);
    }

    # warn "Start not found ", $self->_start_not_found_from_tk, "\n",
    #      "  End not found ", $self->_end_not_found_from_tk,   "\n";
    return $new;
}

# WARNING: work in progress - do not rely on anything other than the basics without checking!
#
sub ensEMBL_Transcript_from_tk {
    my ($self) = @_;

    my $strand = $self->_strand_from_tk;

    my $ts = Bio::Vega::Transcript->new;
    $ts->strand($strand);
    add_EnsEMBL_Attributes($ts, 'name' => $self->_get_subseq_name);

    foreach my $pp ($self->_all_position_pair_text) {
        my $exon = Bio::Vega::Exon->new;
        $exon->start($pp->[0]);
        $exon->end(  $pp->[1]);
        $exon->strand($strand);
        $exon->phase(-1);       # FIXME: do better than this?
        $exon->end_phase(-1);   # FIXME: --"--

        $ts->add_Exon($exon);
    }

    return $ts;
}

sub store_Transcript {
    my ($self, $transcript) = @_;

    my $db_slice   = $self->SessionWindow->AceDatabase->DB->session_slice;
    my $vega_dba   = $db_slice->adaptor->db; # FIXME: probably fragile in face of multiple species
    my $ts_adaptor = $vega_dba->get_TranscriptAdaptor;

    if ($transcript->is_stored($vega_dba)) {
        $ts_adaptor->update($transcript);
    } else {
        # For now, we blindly store a new copy each time, to ensure up-to-dateness

        $transcript->analysis(         $self->_otter_analysis) unless $transcript->analysis;
        $transcript->transcript_author($self->_author_object ) unless $transcript->transcript_author;

        $transcript->slice($db_slice) unless $transcript->slice;
        foreach my $exon (@{$transcript->get_all_Exons}) {
            $exon->slice($db_slice) unless $exon->slice;
        }

        $ts_adaptor->store($transcript);
    }

    return $transcript->dbID;
}

# FIXME: this belongs elsewhere, in due course.
{
    my $_author_object;

    sub _author_object {
        my ($self) = @_;
        return $_author_object if $_author_object;

        my $user = getpwuid($<);
        return $_author_object = Bio::Vega::Author->new(-name => $user);
    }
}

# FIXME: this belongs elsewhere, in due course.
{
    my $_otter_analysis;

    sub _otter_analysis {
        my ($self) = @_;
        return $_otter_analysis if $_otter_analysis;

        return $_otter_analysis = Bio::EnsEMBL::Analysis->new(-logic_name => 'Otter');
    }
}

sub _save_if_changed {
    my ($self) = @_;

    my $sub = try {
        $self->_get_SubSeq_if_changed;
    }
    catch {
        # Make sure the annotators see the messages!
        $self->exception_message($_, 'Error checking for changes to transcript');
        return;
    };

    if ($sub) {
        return $self->_save_sub($sub);
    }
    else {
        return;
    }
}

sub _save_sub {
    my ($self, $sub) = @_;

    my $top = $self->top_window;
    $top->Busy;
    return try {
        $self->_do_save_subseq_work($sub);
    }
    catch {
        $self->exception_message($_, 'Error saving transcipt');
        return 0;
    }
    finally {
        $top->Unbusy;
    }
}

sub _do_save_subseq_work {
    my ($self, $sub) = @_;

    confess "Missing SubSeq argument" unless $sub;

    my $old      = $self->SubSeq;
    my $old_name = $old->name;
    my $new_name = $sub->name;

    # Allow the "annotation in progress" remark to be deleted. If the old
    # locus had it, but the new one does not, then it was deliberately
    # deleted, so don't set it again.
    unless ($old->Locus->annotation_in_progress && !$sub->Locus->annotation_in_progress) {
        $sub->Locus->set_annotation_in_progress;
    }

    my $clone_name = $sub->clone_Sequence->name;
    if ($clone_name eq $new_name) {
        die("Can't have SubSequence with same name as clone!\n");
    }

    my $SessionWindow = $self->SessionWindow;

    # replace_SubSeq() saves to persistent storage and zmap
    if ($SessionWindow->replace_SubSeq($sub, $old)) {

        # more updating of internal state - if we're OK to do that

        $self->SubSeq($sub);
        $self->_update_transcript_remark_widget($sub);
        $self->name($new_name);
        $self->_evidence_hash($sub->clone_evidence_hash);

        ### Update all subseq edit windows (needs a sane Ace server)
        $SessionWindow->draw_subseq_list;
    }

    return 1;
}

sub _Exons_from_canvas {
    my ($self) = @_;

    my $done_message = 0;
    my( @exons );
    foreach my $pp ($self->_all_position_pair_text) {
        confess "Error: Empty coordinate" if grep { $_ == 0 } @$pp;
        my $ex = Hum::Ace::Exon->new;
        $ex->start($pp->[0]);
        $ex->end  ($pp->[1]);
        push(@exons, $ex);
    }

    for (my $i = 0; $i < @exons; $i++) {
        my $this = $exons[$i];
        my $next = $exons[$i + 1] or last;
        if ($this->start <= $next->end and $this->end >= $next->start) {
            $self->message("Error: overlapping coordinates");
            return;
        }
    }

    return @exons;
}

sub _check_for_errors {
    my ($self) = @_;

    my $sub = $self->_new_SubSeq_from_tk;
    $sub->locus_level_errors($self->SubSeq->locus_level_errors);
    if (my $err = $sub->pre_otter_save_error) {
        $err =~ s/\n$//;
        $self->message($err);
    } else {
        $self->message('Transcript OK');
    }

    return;
}

sub check_get_mRNA_Sequence {
    my ($self) = @_;

    my( $cdna );
    try {
        my $sub = $self->_current_SubSeq;
        $sub->validate;
        $cdna = $sub->mRNA_Sequence;
    } catch {
        $self->exception_message($_, 'Error fetching mRNA sequence');
        return;
    };
    return $cdna;
}

sub _run_dotter {
    my ($self) = @_;

    my( $hit_name );
    if (my $txt = $self->get_clipboard_text) {
        # Match fMap "blue box"
        ($hit_name) = $txt =~ /^(?:<?(?:Protein|Sequence)[:>]?)?\"?([^\"\s]+)\"?/;
    }
    unless ($hit_name) {
        $self->message('Cannot see a hit name on the clipboard');
        return;
    }

    return $self->launch_dotter($hit_name);
}

sub launch_dotter {
    my ($self, $hit_name) = @_;

    my $cdna = $self->check_get_mRNA_Sequence;
    return unless $cdna;

    my $dotter = Bio::Otter::Utils::DotterLauncher->new;
    $dotter->AccessionTypeCache($self->SessionWindow->AceDatabase->AccessionTypeCache);

    my $top = $self->canvas->toplevel;
    $dotter->problem_report_cb( sub { $top->Tk::Utils::Dotter::problem_box(@_) } );

    $dotter->query_Sequence($cdna);
    $dotter->query_start(1);
    $dotter->query_end($cdna->sequence_length);
    $dotter->query_type('d');
    $dotter->subject_name($hit_name);

    return $dotter->fork_dotter($self->SessionWindow);
}

sub _max_exon_number {
    my ($self) = @_;

    return $self->{'_max_exon_number'} || 0;
}

sub _next_exon_number {
    my ($self) = @_;

    $self->{'_max_exon_number'}++;
    return $self->{'_max_exon_number'};
}

sub _decrement_exon_counter {
    my ($self, $count) = @_;

    confess "No count given" unless defined $count;
    $self->{'_max_exon_number'} -= $count;

    return;
}

sub DESTROY {
    my ($self) = @_;

    my $name = $self->name;
    warn "Destroying TranscriptWindow: '$name'\n";

    return;
}

sub icon_pixmap {

    return <<'END_OF_PIXMAP';
/* XPM */
static char * exoncanvas_xpm[] = {
/* width height ncolors cpp [x_hot y_hot] */
"48 48 5 1 0 0",
/* colors */
"  s none m none c none",
". s iconColor2 m white c white",
"o s iconColor3 m black c red",
"O s iconColor1 m black c black",
"X s bottomShadowColor m black c #636363636363",
/* pixels */
"   .....................XX                      ",
"   ...o.............o...XX                      ",
"   ...o.............o...XX                      ",
"   ...o.............o...XX                      ",
"   ...o.............o...XX                      ",
"   ...o.............o...XX                      ",
"   ...ooooooooooooooo...XX                      ",
"   ...........oo........XX                      ",
"   .............o.......XX                      ",
"   ..............o......XX                      ",
"   ...............oo....XX                      ",
"   .................o...XX            O         ",
"   ...............oo....XX           O.O        ",
"   ..............o......XX          O...O       ",
"   .............o.......XX         O.....O      ",
"   ...........oo........XX        O.......O     ",
"   ...ooooooooooooooo...XX       O.........O    ",
"   ...o.............o...XX       OOOOO.OOOOO    ",
"   ...o.............o...XX          XO.OXXX     ",
"   ...o.............o...XX         XXO.OXXXX    ",
"   ...o.............o...XX        XXXO.OXXXXX   ",
"   ...o.............o...XX        XXXO.OXXXXX   ",
"   ...o.............o...XX           O.OX       ",
"   ...o.............o...XX           O.OX       ",
"   ...o.............OOOOOOOOOOOOOOOOOO.OX       ",
"   ...ooooooooooooooo..................OX       ",
"   ...ooooooooooooooOOOOOOOOOOOOOOOOOO.OX       ",
"   ...ooooooooooooooo..XXX           O.OX       ",
"   ...ooooooooooooooo...XXXXXXXXXXXXXO.OX       ",
"   ...ooooooooooooooo...XXXXXXXXXXXXXO.OX       ",
"   ...ooooooooooooooo...XXXXXXXXXXXXXO.OX       ",
"   ...ooooooooooooooo...XX           O.OX       ",
"   ...ooooooooooooooo...XX           O.OX       ",
"   ...ooooooooooooooo...XX       OOOOO.OOOOO    ",
"   ...ooooooooooooooo...XX       O.........O    ",
"   ...ooooooooooooooo...XX        O.......O     ",
"   ...ooooooooooooooo...XX         O.....O      ",
"   ...ooooooooooooooo...XX        XXO...OXXXX   ",
"   ...ooooooooooooooo...XX        XXXO.OXXXXX   ",
"   ...ooooooooooooooo...XX         XXXOXXXXX    ",
"   ...ooooooooooooooo...XX          XXXXXXX     ",
"   ...ooooooooooooooo...XX           XXXXX      ",
"   ...........o.........XX            XXX       ",
"   ...........o.........XX             X        ",
"   ............o........XX                      ",
"   ............o........XX                      ",
"    XXXXXXXXXXXXXXXXXXXXXX                      ",
"    XXXXXXXXXXXXXXXXXXXXXX                      "};
END_OF_PIXMAP

}

1;

__END__

=head1 NAME - MenuCanvasWindow::TranscriptWindow

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

