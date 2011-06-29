
### MenuCanvasWindow::ExonCanvas

package MenuCanvasWindow::ExonCanvas;

use strict;
use warnings;
use Carp;
use Scalar::Util 'weaken';
use Tk;
use Tk::Dialog;
use Tk::ROText;
use Tk::LabFrame;
use Tk::ComboBox;
use Tk::SmartOptionmenu;
use Hum::Ace::SubSeq;
use Hum::Ace::DotterLauncher;
use CanvasWindow::EvidencePaster;
use EditWindow::PfamWindow;
use Hum::Ace;

use base qw( MenuCanvasWindow );

my $highlight_hydrophobic = 0;

# "new" is in MenuCanvasWindow

sub initialize {
    my( $self ) = @_;

    my $canvas = $self->canvas;
    my $top = $canvas->toplevel;

    $self->draw_subseq;

    # Routines to handle the clipboard
    my $deselect_sub = sub{ $self->deselect_all };
    $canvas->SelectionHandle(
        sub { $self->export_highlighted_text_to_selection(@_); }
        );
    my $select_all_sub = sub{
        $self->select_all_exon_pos;
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
        my $show_pep_command = sub{ $self->show_peptide };
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

        # Save changes on window close
        my $window_close = sub {
            $self->window_close or return;
            };

        # Trap window close
        $top->protocol('WM_DELETE_WINDOW', $window_close);
        $top->bind('<Control-w>',   $window_close);
        $top->bind('<Control-W>',   $window_close);

        if ($self->is_mutable) {

            # Select supporting evidence for the transcript
            my $select_evidence = sub{ $self->select_evidence };
            $file_menu->add('command',
                -label          => 'Select evidence',
                -command        => $select_evidence,
                -accelerator    => 'Ctrl+E',
                -underline      => 1,
                );
            $canvas->Tk::bind('<Control-e>',   $select_evidence);
            $canvas->Tk::bind('<Control-E>',   $select_evidence);

            # Save into db via sgifaceserver
            my $save_command = sub{ $self->save_if_changed };
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
        $canvas->Tk::bind('<Escape>', sub{ $self->deselect_all });

        if ($self->is_mutable) {

            # Flip strands
            my $reverse_command = sub { $self->toggle_tk_strand };
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
            my $sort_command = sub{ $self->sort_all_coordinates };
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
            my $delete_exons = sub{ $self->delete_selected_exons };
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

        if ($self->is_mutable) {
            # Check for annotation errors
            my $error_check = sub { $self->check_for_errors };
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
        my $show_subseq = sub{ $self->show_subseq };
        $tools_menu->add('command',
            -label          => 'Hunt in Zmap',
            -command        => $show_subseq,
            -accelerator    => 'Ctrl+H',
            -underline      => 0,
            );
        $top->bind('<Control-h>',   $show_subseq);
        $top->bind('<Control-H>',   $show_subseq);

        # Run dotter
        my $run_dotter = sub{ $self->run_dotter };
        $tools_menu->add('command',
            -label          => 'Dotter',
            -command        => $run_dotter,
            -accelerator    => 'Ctrl+.',
            -underline      => 0,
            );
        $top->bind('<Control-period>',  $run_dotter);
        $top->bind('<Control-greater>', $run_dotter);

        # Search Pfam
        my $search_pfam_command = sub{ $self->search_pfam };
        $tools_menu->add('command',
            -label          => 'Search Pfam',
            -command        => $search_pfam_command,
            -accelerator    => 'Ctrl+P',
            -underline      => 7,
            );
        $top->bind('<Control-p>',       $search_pfam_command);
        $top->bind('<Control-P>',       $search_pfam_command);

        if ($self->is_mutable) {
            # Show dialog for renaming the locus attached to this subseq
            my $rename_locus = sub { $self->rename_locus };
            $tools_menu->add('command',
                -label          => 'Rename locus',
                -command        => $rename_locus,
                -accelerator    => 'Ctrl+L',
                -underline      => 0,
                );
            $top->bind('<Control-l>',  $rename_locus);
            $top->bind('<Control-L>',  $rename_locus);
        }
    }

    if ($self->is_mutable) {
        
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
        $canvas->Tk::bind('<Left>',      sub{ $self->canvas_text_go_left   });
        $canvas->Tk::bind('<Right>',     sub{ $self->canvas_text_go_right  });
        $canvas->Tk::bind('<BackSpace>', sub{ $self->canvas_backspace      });

        # For entering digits into the text object which has keyboard focus
        $canvas->eventAdd('<<digit>>', map { "<KeyPress-$_>" } 0..9);
        $canvas->Tk::bind('<<digit>>', [sub{ $self->canvas_insert_character(@_) }, Tk::Ev('A')]);

        # Increases the number which has keyboard focus
        $canvas->eventAdd('<<increment>>', qw{ <Up> <plus> <KP_Add> <equal> });
        $canvas->Tk::bind('<<increment>>', sub{ $self->increment_int });

        # Decreases the number which has keyboard focus
        $canvas->eventAdd('<<decrement>>', qw{ <Down> <minus> <KP_Subtract> <underscore> });
        $canvas->Tk::bind('<<decrement>>', sub{ $self->decrement_int });

        # Control-Left mouse for switching strand
        $canvas->Tk::bind('<Control-Button-1>', sub{
            $self->control_left_button_handler;
            if ($self->count_selected) {
                $canvas->SelectionOwn( -command => $deselect_sub );
            }
        });

        # Middle mouse pastes in coords from clipboard
        $canvas->Tk::bind('<Button-2>', sub{
            $self->middle_button_paste;
            if ($self->count_selected) {
                $canvas->SelectionOwn( -command => $deselect_sub );
            }
        });

        # Handle left mouse
        $canvas->Tk::bind('<Button-1>', sub{
            $self->left_button_handler;
            $self->focus_on_current_text;
            if ($self->count_selected) {
                $canvas->SelectionOwn( -command => $deselect_sub );
            }
        });

        my $frame = $canvas->toplevel->LabFrame(
            -label => 'Transcript',
            -border => 3,
            )->pack(
                -side => 'top',
                -fill => 'x',
                );

        # Widget for changing name
        $self->add_subseq_rename_widget($frame);

        # Widget for changing transcript type (acedb method).
        my $current_method = $self->SubSeq->GeneMethod->name;
        $self->method_name_var(\$current_method);
        my @mutable_gene_methods = $self->XaceSeqChooser->get_all_mutable_GeneMethods;

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
                    $self->draw_translation_region;
                    $self->fix_window_min_max_sizes;
                    $top->focus;  # Need this
                },
            )->pack(-side => 'left');

        # Start not found and end not found and method widgets
        $self->add_start_end_method_widgets($frame);

        # Transcript remark widget
        $self->add_transcript_remark_widget($frame, $tsct_attrib_menu);
        $self->populate_transcript_attribute_menu($tsct_attrib_menu);

        # Widget for changing locus properties
        my $locus_frame = $canvas->toplevel->LabFrame(
            -label => 'Locus',
            -border => 3,
            )->pack(
                -side => 'top',
                -fill => 'x',
                );
        $self->add_locus_editing_widgets($locus_frame, $locus_attrib_menu);
        $self->populate_locus_attribute_menu($locus_attrib_menu);
    } else {
        # SubSeq with an immutable method - won't display entry widgets for updating things

        # Only select current text - no focus
        $canvas->Tk::bind('<Button-1>', sub{
            $self->left_button_handler;
            if ($self->count_selected) {
                $canvas->SelectionOwn( -command => $deselect_sub );
            }
        });
    }

    # For extending selection
    $canvas->Tk::bind('<Shift-Button-1>', sub{
        $self->shift_left_button_handler;
        if ($self->count_selected) {
            $canvas->SelectionOwn( -command => $deselect_sub )
        }
    });

    $canvas->Tk::bind('<Destroy>', sub{ $self = undef });

    $top->update;
    $self->fix_window_min_max_sizes;
    return;
}



sub name {
    my( $self, $name ) = @_;

    if ($name) {
        $self->{'_name'} = $name;
    }
    return $self->{'_name'};
}

sub SubSeq {
    my( $self, $sub ) = @_;

    if ($sub) {
        my $expected = 'Hum::Ace::SubSeq';
        unless (eval { $sub->isa($expected) }) {
            confess "Expected a '$expected', but got '$sub'";
        }
        $self->{'_SubSeq'} = $sub;
        $self->canvas->toplevel->configure(-title => 'otter: Transcript ' . $sub->name);
    }
    return $self->{'_SubSeq'};
}

sub XaceSeqChooser {
    my( $self, $chooser ) = @_;

    if ($chooser) {
        $self->{'_XaceSeqChooser'} = $chooser;
        weaken $self->{'_XaceSeqChooser'};
    }
    return $self->{'_XaceSeqChooser'};
}

sub DataSet {
    my( $self ) = @_;
    return $self->XaceSeqChooser->AceDatabase->DataSet;
}

sub add_subseq_exons {
    my( $self, $subseq ) = @_;

    my $expected = 'Hum::Ace::SubSeq';
    unless ($subseq->isa($expected)) {
        warn "Unexpected object '$subseq', expected a '$expected'";
    }

    my $strand = $subseq->strand;
    
    foreach my $ex ($subseq->get_all_Exons_in_transcript_order) {
        $self->add_exon_holder($ex->start, $ex->end, $strand);
    }
    
    $self->remove_spurious_splice_sites;

    return;
}

{
    my $pp_field = '_position_pairs';

    sub position_pairs {
        my( $self, @pairs ) = @_;

        if (@pairs) {
            $self->{$pp_field} = [@pairs];
        }

        if (my $pp = $self->{$pp_field}) {
            return @$pp;
        } else {
            return;
        }
    }

    sub add_position_pair {
        my( $self, @pair_and_id ) = @_;

        unless (@pair_and_id == 3) {
            confess "Expecting 2 numbers and exon_id";
        }
        $self->{$pp_field} ||= [];
        push(@{$self->{$pp_field}}, [@pair_and_id]);

        return;
    }

    sub next_position_pair_index {
        my( $self ) = @_;

        if (my $pp = $self->{$pp_field}) {
            return scalar @$pp;
        } else {
            return 0;
        }
    }

    sub trim_position_pairs {
        my( $self, $length, $strand ) = @_;

        if (my $pp = $self->{$pp_field}) {
            my @del = splice(@$pp, -1 * $length, $length);
            if (@del != $length) {
                confess "only got ", scalar(@del), " elements, not '$length'";
            }
            my $canvas = $self->canvas;
            foreach my $exon_id (map { $_->[2] } @del) {
                $canvas->delete($exon_id);
            }
            $self->decrement_exon_counter($length);
        } else {
            confess "No pairs to trim";
        }
        $self->set_tk_strand($strand) if $strand;
        $self->position_mobile_elements;

        return;
    }
}


sub all_position_pair_text {
    my( $self ) = @_;

    my $canvas = $self->canvas;
    my $empty  = $self->empty_string;
    my( @pos );
    foreach my $pair ($self->position_pairs) {
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

sub set_position_pair_text {
    my( $self, $pp, $text_pair, $strand ) = @_;

    $strand ||= $self->strand_from_tk;

    my $canvas = $self->canvas;
    my @txt = @$text_pair;
    @txt = reverse @txt if $strand == -1;
    foreach my $i (0,1) {
        my $obj = $pp->[$i];
        my $pos = $txt[$i] || $self->empty_string;
        $canvas->itemconfigure($obj, -text => $pos);
    }
    $self->update_splice_strings($text_pair->[0]);

    return;
}

sub set_all_position_pair_text {
    my( $self, @coord ) = @_;

    my @pp_list = $self->position_pairs;
    if (@pp_list != @coord) {
        confess "position pair number '", scalar(@pp_list),
            "' doesn't match number of coordinates '", scalar(@coord), "'";
    }
    for (my $i = 0; $i < @pp_list; $i++) {
        $self->set_position_pair_text($pp_list[$i], $coord[$i]);
    }
    $self->update_splice_strings('exon_start');

    return;
}

sub sort_all_coordinates {
    my( $self ) = @_;

    $self->delete_was_selected;
    $self->sort_position_pairs;
    $self->sort_translation_region;

    return;
}

sub sort_position_pairs {
    my( $self ) = @_;

    my %was_selected = map { $_ => 1 } $self->get_all_selected_text;
    $self->deselect_all;

    my $empty  = $self->empty_string;
    my $canvas = $self->canvas;
    my $strand = $self->strand_from_tk;

    my( @sort );
    if ($strand == 1) {
        @sort = sort {$a->[0] <=> $b->[0] || $a->[1] <=> $b->[1]}
            $self->all_position_pair_text;
    } else {
        @sort = sort {$b->[0] <=> $a->[0] || $b->[1] <=> $a->[1]}
            $self->all_position_pair_text;
    }

    my $n = 0;
    my( @select );
    foreach my $pp ($self->position_pairs) {
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
    $self->update_splice_strings('exon_start');
    $self->remove_spurious_splice_sites;

    return;
}

sub sort_translation_region {
    my( $self ) = @_;

    my @region  = $self->translation_region_from_tk or return;
    my $strand  = $self->strand_from_tk;
    if ($strand == 1) {
        $self->tk_t_start($region[0]);
        $self->tk_t_end  ($region[1]);
    } else {
        $self->tk_t_start($region[1]);
        $self->tk_t_end  ($region[0]);
    }

    return;
}

sub merge_position_pairs {
    my( $self ) = @_;

    $self->deselect_all;
    $self->sort_position_pairs;
    my @pos = $self->all_position_pair_text;
    my $i = 0;
    my $strand = $self->strand_from_tk;
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

    my @pairs  = $self->position_pairs;
    for (my $i = 0; $i < @pos; $i++) {
        $self->set_position_pair_text($pairs[$i], $pos[$i]);
    }
    if (my $over = @pairs - @pos) {
        $self->trim_position_pairs($over);
        $self->fix_window_min_max_sizes;
    }
    
    $self->remove_spurious_splice_sites;

    return;
}

sub delete_selected_exons {
    my( $self ) = @_;

    my $canvas = $self->canvas;
    my @selected = $self->list_selected;
    $self->deselect_all;
    my( %del_exon );
    foreach my $obj (@selected) {
        my ($exon_id) = grep { /^exon_id/ } $canvas->gettags($obj);
        if ($exon_id) {
            $del_exon{$exon_id}++;
        }
    }

    my $strand = 0;
    my @text    = $self->all_position_pair_text;
    my @pp_list = $self->position_pairs;
    my $trim = 0;
    my( @keep );
    for (my $i = 0; $i < @pp_list; $i++) {
        my $exon_id = $pp_list[$i][2];
        my $count = $del_exon{$exon_id};
        if ($count and $count == 2) {
            $trim++;
        } else {
            $strand += $self->exon_strand_from_tk($exon_id);
            push(@keep, $text[$i]);
        }
    }

    return unless $trim;

    $strand = $strand < 0 ? -1 : 1;

    $self->trim_position_pairs($trim, $strand);
    $self->set_all_position_pair_text(@keep);   # Also updates splice site strings
    $self->remove_spurious_splice_sites;
    $self->delete_was_selected;

    # Put in an empty exon holder if we have deleted them all
    unless ($self->position_pairs) {
        $self->add_exon_holder(undef, undef, 1);
    }
        
    $self->fix_window_min_max_sizes;

    return;
}

sub exon_strand_from_tk {
    my( $self, $exon_id ) = @_;

    confess "exon_id not given" unless $exon_id;
    if ($self->canvas->find('withtag', "plus_strand&&$exon_id")) {
        return 1;
    } else {
        return -1;
    }
}

sub add_coordinate_pair {
    my( $self, $start, $end ) = @_;

    my $strand = 1;
    if ($start and $end and $start > $end) {
        $strand = -1;
        ($start, $end) = ($end, $start);
    }
    $self->add_exon_holder($start, $end, $strand);

    return;
}

sub draw_subseq {
    my( $self ) = @_;

    my $sub = $self->SubSeq;
    $self->add_subseq_exons($sub);
    $self->draw_translation_region($sub);
    $self->evidence_hash($sub->clone_evidence_hash);

    return;
}

sub is_mutable {
    my( $self ) = @_;

    return $self->SubSeq->is_mutable;
}

sub window_close {
    my( $self ) = @_;

    my $xc = $self->XaceSeqChooser;

    if ($self->is_mutable && $xc->AceDatabase->write_access) {
        my( $sub );
        eval{
            $sub = $self->get_SubSeq_if_changed;
        };

        my $name = $self->name;

        if ($@) {
            $self->exception_message($@);
            my $dialog = $self->canvas->toplevel->Dialog(
                -title          => 'otter: Abandon?',
                -bitmap         => 'question',
                -text           => "Transcript '$name' has errors.\nAbandon changes?",
                -default_button => 'No',
                -buttons        => [qw{ Yes No }],
                );
            my $ans = $dialog->Show;
            return if $ans eq 'No';
        }
        elsif ($sub) {

            # Ask the user if changes should be saved
            my $dialog = $self->canvas->toplevel->Dialog(
                -title          => 'otter: Save changes?',
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
                $self->xace_save($sub) or return;
            }
        }
    }
    #$self->delete_chooser_window_ref;
    $self->top_window->destroy;

    return 1;
}

sub show_subseq {
    my( $self ) = @_;

    my $success = $self->XaceSeqChooser->zMapZoomToSubSeq($self->SubSeq);
    
    $self->message("ZMap: zoom to subsequence failed") unless $success;

    return;
}

sub show_peptide {
    my( $self ) = @_;

    unless ($self->{'_pep_peptext'}) {
        my $master = $self->canvas->toplevel;
        my $top = $master->Toplevel;
        $top->transient($master);


        my $peptext = $self->{'_pep_peptext'} = $top->Scrolled(
            'ROText',
            -scrollbars         => 'e',
            -font           => $self->font_fixed,
            #-justify        => 'left',
            -padx                   => 6,
            -pady                   => 6,
            -relief                 => 'groove',
            -background             => 'white',
            -border                 => 2,
            -selectbackground       => 'gold',
            #-exportselection => 1,
            )->pack(
                -expand => 1,
                -fill   => 'both',
                );

        # Red for stop codons
        $peptext->tagConfigure('redstop',
            -background => '#ef0000',
            -foreground => 'white',
            );

        # Blue for "X", the unknown amino acid
        $peptext->tagConfigure('blueunk',
            -background => '#0000ef',
            -foreground => 'white',
            );

        # Light grey background for hydrophobic amino acids
        $peptext->tagConfigure('greyphobic',
            -background => '#cccccc',
            -foreground => 'black',
            );

        # Gold for methionine codons
        $peptext->tagConfigure('goldmeth',
            -background => '#ffd700',
            -foreground => 'black',
        );
        $peptext->tagBind('goldmeth', '<Button-1>',
            sub{ $self->trim_cds_coord_to_current_methionine; }
            );
        $peptext->tagBind('goldmeth', '<Enter>',
            sub{ $peptext->configure(-cursor => 'arrow'); }
            );
        $peptext->tagBind('goldmeth', '<Leave>',
            sub{ $peptext->configure(-cursor => 'xterm'); }
            );
        $peptext->tagBind('goldmeth' , '<Button-3>' ,
            sub{ $self->check_kozak}
            );

        # Green for selenocysteines
        $peptext->tagConfigure('greenseleno',
            -background => '#32cd32',
            -foreground => 'white',
        );

        # Frame for buttons
        my $frame = $top->Frame(
            -border => 6,
            )->pack(
                -side   => 'bottom',
                -fill   => 'x',
                );

        my $trim_command = sub{
            $self->trim_cds_coord_to_first_stop;
            $self->show_peptide;
            };
        $frame->Button(
            -text       => 'Trim',
            -underline  => 0,
            -command    => $trim_command ,
            )->pack(-side => 'left');
        $top->bind('<Control-t>',   $trim_command);
        $top->bind('<Control-T>',   $trim_command);
        $top->bind('<Return>',      $trim_command);
        $top->bind('<KP_Enter>',    $trim_command);

        $self->{'_highlight_hydrophobic'} = $highlight_hydrophobic;
        my $toggle_hydrophobic = sub {
            # Save preferred state for next translation window
            $highlight_hydrophobic = $self->{'_highlight_hydrophobic'};
            $self->update_translation;
        };
        my $hydrophobic = $frame->Checkbutton(
            -command    => $toggle_hydrophobic,
            -variable   => \$self->{'_highlight_hydrophobic'},
            -text       => 'Highlight hydrophobic',
            -padx       => 6,
            )->pack(-side => 'left', -padx => 6);

        # Close only unmaps it from the display
        my $close_command = sub{ $top->withdraw };

        my $exit = $frame->Button(
            -text => 'Close',
            -command => $close_command ,
            )->pack(-side => 'right');
        $top->bind(    '<Control-w>',      $close_command);
        $top->bind(    '<Control-W>',      $close_command);
        $top->bind(    '<Escape>',         $close_command);


        # Closing with window manager only unmaps window
        $top->protocol('WM_DELETE_WINDOW', $close_command);

        $peptext->bind('<Destroy>', sub{ $self = undef });
    }

    if ($self->update_translation) {
        # Make the window visible
        my $win = $self->{'_pep_peptext'}->toplevel;
        $win->deiconify;
        $win->raise;
    }

    return;
}

sub search_pfam {
    my( $self ) = @_;

    my $sub = $self->is_mutable ? $self->new_SubSeq_from_tk : $self->SubSeq;
    unless ($sub->GeneMethod->coding) {
        $self->message("non-coding transcript type");
        return;
    }

    eval{ $sub->validate; };
    if ($@) {
        $self->exception_message($@, 'Invalid transcript');
    } else {
        my $pep = $sub->translator->translate($sub->translatable_Sequence);
        my $name = $pep->name;
        my $str = $pep->sequence_string;
        my $pfam;

        if($self->{'_pfam'} && Tk::Exists($self->{'_pfam'}->top)) {
            $pfam = $self->{'_pfam'};
            if($pfam->query() ne $str) {
                $pfam->top->destroy;
                $pfam = EditWindow::PfamWindow->new($self->canvas->Toplevel(-title => "otter: Pfam $name"));
            } else {
                $pfam->top->deiconify;
                $pfam->top->raise;
                $pfam->top->focus;

                return 1;
            }
        } elsif($self->{'_pfam'} && !Tk::Exists($self->{'_pfam'}->top)) {
            $pfam = $self->{'_pfam'};
            my $result_url = $pfam->result_url;
            my $prev_query = $pfam->query();
            $pfam = EditWindow::PfamWindow->new($self->canvas->Toplevel(-title => "otter: Pfam $name"));
            $pfam->result_url($result_url) unless $prev_query ne $str;
        } else {
            $pfam = EditWindow::PfamWindow->new($self->canvas->Toplevel(-title => "otter: Pfam $name"));
        }

        $pfam->query($str);
        $pfam->name($name);
        $self->{'_pfam'} = $pfam;
        $pfam->initialize();
    }

    return;
}

sub update_translation {
    my( $self ) = @_;

    my $peptext = $self->{'_pep_peptext'} or return;

    my $sub = $self->is_mutable ? $self->new_SubSeq_from_tk : $self->SubSeq;
    unless ($sub->GeneMethod->coding) {
        if ($peptext) {
            $peptext->toplevel->withdraw;
        }
        $self->message("non-coding transcript type");
        return;
    }

    # Empty the text widget
    $peptext->delete('1.0', 'end');

    eval{ $sub->validate; };
    if ($@) {
        $self->exception_message($@, 'Invalid transcript');
        $peptext->insert('end', "TRANSLATION ERROR");
    } else {
        # Put the new translation into the Text widget

        my $pep = $sub->translator->translate($sub->translatable_Sequence);
        $peptext->insert('end', sprintf(">%s\n", $pep->name));

        my $line_length = 60;
        my $str = $pep->sequence_string;
        my $map = $sub->codon_start_map;
        my %style = qw{
            *   redstop
            X   blueunk
            M   goldmeth
            U   greenseleno
            };
        if ($self->{'_highlight_hydrophobic'}) {
            %style = (%style, qw{
                A   greyphobic
                C   greyphobic
                G   greyphobic
                I   greyphobic
                L   greyphobic
                F   greyphobic
                P   greyphobic
                W   greyphobic
                V   greyphobic
                });
        }
        my $pep_genomic = $self->{'_peptext_index_to_genomic_position'} = {};
        
        # If we are showing an "X" amino acid at the start due to a partial
        # codon we need to take 1 off the index into the codon_start_map
        my $offset = $str =~ /^X/ ? 1 : 0;
        
        for (my $i = 0; $i < length($str); $i++) {
            my $char = substr($str, $i, 1);
            my $tag = $style{$char};
            $peptext->insert('end', $char, $tag);

            if ($char eq 'M') {
                my $index = $peptext->index('insert - 1 chars');
                #printf STDERR "$index  $map->[$i]\n";
                $pep_genomic->{$index} = $map->[$i - $offset];
            }

            unless (($i + 1) % $line_length) {
                $peptext->insert('end', "\n");
            }
        }
    }


    # Size widget to fit
    my ($lines) = $peptext->index('end') =~ /(\d+)\./;
    $lines--;
    if ($lines > 40) {
        $peptext->configure(
            -width  => 60,
            -height => 40,
            );
    } else {
        # This has slightly odd behaviour if the ROText starts off
        # big to accomodate a large translation, and is then made
        # smaller.  Does not seem to shrink below a certain minimum
        # height.
        $peptext->configure(
            -width  => 60,
            -height => $lines,
            );
    }

    # Set the window title
    $peptext->toplevel->configure( -title => sprintf("otter: Translation %s", $sub->name) );

    return 1;
}

sub evidence_hash {
    my( $self, $evidence_hash ) = @_;

    if ($evidence_hash) {
        $self->{'_evidence_hash'} = $evidence_hash;
        if (my $paster = $self->{'_evi_window'}) {
            $paster->evidence_hash($evidence_hash);
            $paster->draw_evidence;
        }
    }
    return $self->{'_evidence_hash'};
}

sub select_evidence {
    my( $self ) = @_;

    my $paster_top = $self->EvidencePaster->canvas->toplevel;
    $paster_top->deiconify;
    $paster_top->raise;
    return $paster_top;
}

sub EvidencePaster {
    my ($self) = @_;

    my $evi = $self->evidence_hash;

    my $paster;
    if ($paster = $self->{'_evi_window'}) {
        $paster->evidence_hash($evi);
        $paster->draw_evidence;
    } else {
        my $paster_top = $self->canvas->Toplevel;
        $paster_top->transient($self->canvas->toplevel);
        $paster = $self->{'_evi_window'} = CanvasWindow::EvidencePaster->new($paster_top);
        $paster->ExonCanvas($self);
        $paster->initialise($evi);
    }
    return $paster;
}

sub save_OtterTranscript_evidence {
    my( $self, $transcript ) = @_;

    my $info = $transcript->transcript_info;
    my $evi_hash = {};
    foreach my $evi (@{$info->get_all_Evidence}) {
        my $type = $evi->type;
        my $name = $evi->name;
        my $evi_list = $evi_hash->{$type} ||= [];
        push @$evi_list, $name;
    }
    $self->evidence_hash($evi_hash);

    return;
}

sub check_kozak{
    my ($self ) = @_ ;

    my $kozak_window = $self->{'_kozak_window'} ;
    # create a new window if none available
    unless (defined $kozak_window){
        my $master = $self->canvas->toplevel;
        $kozak_window = $master->Toplevel(-title => 'otter: Kozak Checker');
        $kozak_window->transient($master);

        my $font = $self->font_fixed;

        $kozak_window->Label(
                -font           => $font,
                -text           => "5'\n3'" ,
                -padx                   => 6,
                -pady                   => 6,
                )->pack(-side   => 'left');

        my $kozak_txt = $kozak_window->ROText(
                -font           => $font,
                #-justify        => 'left',
                -padx                   => 6,
                -pady                   => 6,
                -relief                 => 'groove',
                -background             => 'white',
                -border                 => 2,
                -selectbackground       => 'gold',
                #-exportselection => 1,

                -width                  => 10 ,
                -height                 => 2 ,
                )->pack(-side   => 'left' ,
                        -expand => 1      ,
                        -fill   => 'both' ,
                        );


        $kozak_window->Label(
                -font           => $font,
                -text           => "3'\n5'" ,
                -padx                   => 6,
                -pady                   => 6,
                )->pack(-side   => 'left');

        my $close_kozak = sub { $kozak_window->withdraw } ;
        $kozak_window->bind('<Destroy>', sub{ $self = undef });
        my $kozak_butt = $kozak_window->Button( -text       => 'close' ,
                                            -command    => $close_kozak ,
                                            )->pack(-side => 'left')  ;
        $self->{'_kozak_txt'} = $kozak_txt ;
        $self->{'_kozak_window'} = $kozak_window;

    }

    my $kozak_txt = $self->{'_kozak_txt'} ;

    ### get index of selected methionine
    my $peptext = $self->{'_pep_peptext'} or return;
    my $pep_index = $peptext->index('current');
    my $seq_index = $self->{'_peptext_index_to_genomic_position'}{$pep_index} or return;

    my $subseq = $self->SubSeq ;
    my $clone_seq = $subseq->clone_Sequence();
    my $sequence_string = $clone_seq->sequence_string;
    my $strand = $subseq->strand;

    my $k_start ;

    if ($strand == 1){
        $k_start = ($seq_index  - 7 ) ;
    }else{
        $k_start = ($seq_index  - 4 ) ;
    }

    my $kozak ;
    if ( $k_start >= 0 ){
        $kozak = substr($sequence_string ,  $k_start  , 10 ) ;
    }
    else{
        # if subseq  goes off start , this will pad it with '*'s to make it 10 chars long
        $kozak =  "*" x ( $k_start * -1) . substr($sequence_string ,  0  , 10 + $k_start ) ;
    }

    my $rev_kozak = $kozak ;
    $rev_kozak =~ tr{acgtrymkswhbvdnACGTRYMKSWHBVDN}
                    {tgcayrkmswdvbhnTGCAYRKMSWDVBHN};
    $kozak  =~ s/t/u/g  ;
    $rev_kozak =~ s/t/u/g  ;


    $kozak_window->resizable( 1 , 1)  ;
    $kozak_txt->delete( '1.0' , 'end')  ;
    $kozak_window->resizable(0 , 0)  ;

    # higlight parts of sequence that match
    # green for matches codons
    $kozak_txt->tagConfigure('match',
            -background => '#AAFF66',
            );

    # from an email from [cas]
    # shows how the template matches various recognised Kozak consensi.
    ############################  perfect, strong, adequate, chr22 version
    my @template_kozak = ('(a|g)',   # G
                          'c',       # C
                          'c',       # C
                          'a',       # A    A   G   G  Y     G
                          'c',       # C    n   n   n  n     n
                          'c',       # C    n   n   n  n     n
                          'a',       # A    A   A   A  A     A
                          'u',       # T    T   T   T  T     T
                          'g',       # G    G   G   G  G     G
                          'g');      # G    n   G   Y  G     A

    ## for some reason (tk bug?) tk would not display tags added to the second line when using the index system - hence two loops rather than one
    for( my $i = 0 ;  $i <= ( length($kozak) - 1) ; $i++ ){
        my $pos_char = substr( $kozak , $i , 1) ;
        my $template = $template_kozak[$i] ;
        if ($pos_char  =~ /$template/ && $strand == 1){
            $kozak_txt->insert('end' , "$pos_char" , 'match');
        }else{
            $kozak_txt->insert('end' , "$pos_char" );
        }
    }

    for (my $i = 0 ;  $i <= ( length($rev_kozak) - 1) ; $i++ ){
        my $template = $template_kozak[9 - $i] ;
        my $neg_char = substr( $rev_kozak ,  $i   , 1) ;
        if ($neg_char  =~ /$template/  && $strand == -1){
            $kozak_txt->insert('end' , "$neg_char" , "match");
        }else{
            $kozak_txt->insert('end' , "$neg_char");
        }
    }

    $kozak_window->deiconify;
    $kozak_window->raise ;

    return;
}

sub trim_cds_coord_to_current_methionine {
    my( $self ) = @_;

    my $peptext = $self->{'_pep_peptext'} or return;
    my $index = $peptext->index('current');
    my $new = $self->{'_peptext_index_to_genomic_position'}{$index} or return;

    $self->deselect_all;
    my $original = $self->tk_t_start;
    $self->tk_t_start($new);

    # Highlight the translation end if we have changed it
    $self->highlight('t_start') if $new != $original;

    return;
}

sub trim_cds_coord_to_first_stop {
    my( $self ) = @_;

    unless ($self->get_GeneMethod_from_tk->coding) {
        $self->message('non-coding transcript type');
        return;
    }

    $self->deselect_all;
    my $sub = $self->new_SubSeq_from_tk;
    my $strand = $sub->strand;
    my $original = $self->tk_t_end;
    if ($strand == 1) {
        $self->tk_t_end($sub->end);
    } else {
        $self->tk_t_end($sub->start);
    }

    # Translate the subsequence
    $sub = $self->new_SubSeq_from_tk;
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
    printf STDERR "CDS coord = (%d x 3) + %d - 1 = $cds_coord\n",
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
            $self->tk_t_end($new);

            # Highlight the translation end if we have changed it
            $self->highlight('t_end') if $new != $original;
            return 1;
        }
        $pos = $exon_end;
    }
    $self->message("Failed to map coordinate");

    return;
}

sub add_locus_editing_widgets {
    my( $self, $widget, $locus_attrib_menu ) = @_;

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
            my $locus = $self->XaceSeqChooser->get_Locus($name);
            $self->update_Locus_tk_fields($locus);
            },
        -exportselection    => 1,
        -background         => 'white',
        -selectbackground   => 'gold',
        -font               => $self->font_fixed,
        )->pack(-side => 'left');
    #$be->bind('<Leave>', sub{ print STDERR "Variable now: ", ${$self->{'_locus_name_var'}}, "\n"; });

    $be->configure(
        -listcmd => sub{
            my @names = $self->XaceSeqChooser->list_Locus_names;
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
        -font               => $de_frame->optionGet('font', 'CanvasWindow'),
        );
    $de->pack(-side => 'left');
    $de->insert(0, $locus_description);
    $self->locus_description_Entry($de);

    my $ae = $self->make_labelled_entry_widget($widget, 'Alias(es)', $locus_alias, 30, -side => 'top');
    $self->locus_alias_Entry($ae);

    # Locus remark widget
    my $re = $self->make_labelled_text_widget($widget, 'Remarks', $locus_attrib_menu, -anchor => 'se');
    $self->locus_remark_Entry($re);
    if (my $locus = $self->SubSeq->Locus) {
        $self->update_locus_remark_widget($locus);
    }

    # Avoid memory cycle created by ref to $self in above closure
    $be->bind('<Destroy>', sub{ $self = undef });

    return $be;
}

sub get_locus_known {
    my( $self ) = @_;

    return ${$self->{'_locus_is_known_var'}} ? 1 : 0;
}

sub update_Locus_tk_fields {
    my( $self, $locus ) = @_;

    ${$self->{'_locus_name_var'}} = $locus->name;

    ${$self->{'_locus_is_known_var'}} = $locus->known;

    my $de = $self->locus_description_Entry;
    $de->delete(0, 'end');
    if (my $desc = $locus->description) {
        $de->insert(0, $desc);
    }

    my $ae = $self->locus_alias_Entry;
    $ae->delete(0, 'end');
    if (my $alias_str = join(' ', $locus->list_aliases)) {
        $ae->insert(0, $alias_str);
    }

    $self->update_locus_remark_widget($locus);

    return;
}

# Locus renaming plan
# On save the locus fields in all other ExonCanvases with the same Locus get updated
# (Provide a button to open all ExonCanvases with same Locus?)
# Choosing a different Locus from the dropdown menu updates
#   the Locus edit widgets with values from the other Locus.
# Editing the name of the Locus and saving renames the locus if already
#   saved, and keeps its otter_id.


sub get_Locus_from_tk {
    my( $self ) = @_;

    my $name    = $self->get_locus_name or return;
    my $known   = $self->get_locus_known;
    my $desc    = $self->get_locus_description;
    my @aliases = $self->get_locus_aliases;

    #warn "name '$name'\ndesc '$desc'\nremark '$remark'\n";

    my $locus = Hum::Ace::Locus->new;
    $locus->name($name);
    $locus->known($known);
    if ($name =~ /^([^:]+):/) {
        $locus->gene_type_prefix($1);
    }
    $locus->description($desc) if $desc;
    $locus->set_aliases(@aliases);

    $self->get_locus_remarks($locus);

    return $locus;
}

sub get_locus_name {
    my ($self) = @_;

    my $name = ${$self->{'_locus_name_var'}} or return;
    if ($name =~ /\s/) {
        $self->message("Error: whitespace in Locus name '$name'");
        return;
    }
    return $name;
}

sub rename_locus {
    my ($self) = @_;

    my $name = $self->get_locus_name or return;
    $self->XaceSeqChooser->rename_locus($name);

    return;
}

sub update_Locus {
    my( $self, $locus ) = @_;

    $self->update_Locus_tk_fields($locus);
    $self->SubSeq->Locus($locus);

    return;
}

my $ann_tag = 'Annotation';
my $voc_tag = 'Controlled_Vocabulary';

sub update_transcript_remark_widget {
    my( $self, $sub ) = @_;

    $self->update_remark_Entry($self->transcript_remark_Entry,
                               $self->DataSet->vocab_transcript,
                               $sub);

    return;
}

sub update_locus_remark_widget {
    my( $self, $locus ) = @_;

    $self->update_remark_Entry($self->locus_remark_Entry,
                               $self->DataSet->vocab_locus,
                               $locus);

    return;
}

sub update_remark_Entry {
    my( $self, $remark_text, $vocab, $obj ) = @_;

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

sub add_transcript_remark_widget {
    my( $self, $widget, $tsct_attrib_menu ) = @_;

    my $rt = $self->make_labelled_text_widget($widget, 'Remarks', $tsct_attrib_menu, -anchor => 'se');
    $self->transcript_remark_Entry($rt);
    $self->update_transcript_remark_widget($self->SubSeq);

    return;
}

sub add_subseq_rename_widget {
    my( $self, $widget ) = @_;

    $self->subseq_name_Entry(
        $self->make_labelled_entry_widget($widget, 'Name', $self->SubSeq->name, 22, -side => 'top')
        );

    return;
}

sub populate_transcript_attribute_menu {
    my ($self, $menu) = @_;
    
    $self->populate_attribute_menu($menu,
                                   $self->transcript_remark_Entry,
                                   $self->DataSet->vocab_transcript);

    return;
}

sub populate_locus_attribute_menu {
    my ($self, $menu) = @_;
    
    $self->populate_attribute_menu($menu,
                                   $self->locus_remark_Entry,
                                   $self->DataSet->vocab_locus);

    return;
}

sub populate_attribute_menu {
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
                insert_phrase($text, $phrase);
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

sub make_labelled_text_widget {
    my( $self, $widget, $name, $menu, @pack ) = @_;

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
        $tw->bind($seq, [\&ignore_in_controlled_vocab, Tk::Ev('K')]);
    }

    # Keyboard sequences which delete backwards need to take out the whole
    # line of controlled vocabulary in one go...
    foreach my $seq (qw{

        <BackSpace>
        <Control-Key-h>
        <Meta-Key-BackSpace>

    }) {
        $tw->bind($seq, [\&backspace_delete_whole_ctrl_vocab_line, Tk::Ev('K')]);
    }

    # ... as do sequences which delete forwards.
    foreach my $seq (qw{

        <Delete>
        <Meta-Key-d>

        <Control-Key-k>
        <Control-Key-d>

    }) {
        $tw->bind($seq, [\&forward_delete_whole_ctrl_vocab_line, Tk::Ev('K')]);
    }

    # Do not post the Text class's built in popup menu
    $tw->bind($class, '<Button-3>', '');
    $tw->bind('<Button-3>', [\&post_ctrl_vocab_menu, $menu, Tk::Ev('X'), Tk::Ev('Y')]);

    # Remove key binding for keyboard input and replace with our own which
    # inserts characters using the same tag as the rest of the line, or
    # which ignores characters with the controlled vocabulary tag.
    $tw->bind($class, '<Key>', '');
    $tw->bind('<Key>', [\&insert_char, Tk::Ev('A')]);


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

sub post_ctrl_vocab_menu {
    my ($text, $menu, $x, $y) = @_;

    $menu->Post($x, $y);

    return;
}

sub insert_phrase {
    my ($text, $phrase) = @_;

    my @vocab_lines = $text->tagRanges($voc_tag);
    my $see_i;
    for (my $i = 0; $i < @vocab_lines; $i += 2) {
        my ($a, $b) = @vocab_lines[$i, $i + 1];
        my $text = $text->get($a, $b);
        if ($text eq $phrase) {
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

sub backspace_delete_whole_ctrl_vocab_line {
    my ($text, $keysym) = @_;

    my $prev = $text->index('insert - 1 chars');

    if (is_ctrl_vocab_char($text, $prev)) {
        $text->delete("$prev linestart", "$prev lineend");
        $text->break;
    }
    elsif ($text->compare('insert', '==', 'insert linestart')) {
        # If this or the previous line is controlled vocab, just move the cursor
        if (is_ctrl_vocab_char($text, "$prev - 1 chars") or is_ctrl_vocab_char($text, 'insert')) {
            $text->SetCursor('insert - 1 chars');
            $text->break;
        }
    }

    return;
}

sub forward_delete_whole_ctrl_vocab_line {
    my ($text, $keysym) = @_;

    if (is_ctrl_vocab_char($text, 'insert')) {
        $text->delete('insert linestart', 'insert lineend');
        $text->break;
    }
    elsif ($text->compare('insert', '==', 'insert lineend')) {
        # If this or the next line is controlled vocab, just move the cursor
        if (is_ctrl_vocab_char($text, 'insert + 1 chars') or is_ctrl_vocab_char($text, 'insert - 1 chars')) {
            $text->SetCursor('insert + 1 chars');
            $text->break;
        }
    }

    return;
}

sub ignore_in_controlled_vocab {
    my ($text, $keysym) = @_;

    # Need to choose "insert" for keyboard events
    # and "current" for mouse events.
    my $posn = $keysym ? 'insert' : 'current';

    if ($text->compare($posn, '==', "$posn linestart")) {
        # Return at linestart is always OK
        return if $keysym eq 'Return';
    }

    if (is_ctrl_vocab_char($text, $posn)) {
        $text->break;
    }

    return;
}

sub is_ctrl_vocab_char {
    my ($text, $posn) = @_;

    return grep { $_ eq $voc_tag } $text->tagNames($posn);
}

# Inserts (printing) characters with the same style as the rest of the line
sub insert_char {
    my( $text, $char ) = @_;

    # We only want to insert printing characters in the Text box!
    # [:print:] is the POSIX class of printing characters.
    return unless $char =~ /[[:print:]]/;

    # Do not edit controlled vocabulary
    return if grep { $_ eq $voc_tag } $text->tagNames('insert linestart');

    # Expected behaviour is that any selected text will
    # be replaced by what the user types.
    $text->deleteSelected;

    # There will only ever be one or zero tags per line in out Text box.
    my ($tag) = grep { $_ eq $ann_tag } $text->tagNames('insert linestart');

    $text->insert('insert', $char, $tag);

    return;
}

sub make_labelled_entry_widget {
    my( $self, $widget, $name, $value, $size, @pack ) = @_;

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

sub add_start_end_method_widgets {
    my( $self, $widget ) = @_;

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

sub start_not_found_from_tk {
    my( $self ) = @_;
    return ${$self->{'_start_not_found_variable'}} || 0;
}

sub end_not_found_from_tk {
    my( $self ) = @_;
    return ${$self->{'_end_not_found_variable'}} || 0;
}

sub subseq_name_Entry {
    my( $self, $entry ) = @_;

    if ($entry) {
        $self->{'_subseq_name_entry'} = $entry;
    }
    return $self->{'_subseq_name_entry'};
}

sub transcript_remark_Entry {
    my( $self, $transcript_remark_Entry ) = @_;

    if ($transcript_remark_Entry) {
        $self->{'_transcript_remark_Entry'} = $transcript_remark_Entry;
    }
    return $self->{'_transcript_remark_Entry'};
}

sub locus_remark_Entry {
    my( $self, $locus_remark_Entry ) = @_;

    if ($locus_remark_Entry) {
        $self->{'_locus_remark_Entry'} = $locus_remark_Entry;
    }
    return $self->{'_locus_remark_Entry'};
}

sub get_transcript_remarks {
    my( $self, $sub ) = @_;

    confess "Missing SubSeq argument" unless $sub;

    return $self->get_remarks_from_Entry($self->transcript_remark_Entry, $sub);
}

sub get_locus_remarks {
    my( $self, $locus ) = @_;

    confess "Missing Locus argument" unless $locus;

    return $self->get_remarks_from_Entry($self->locus_remark_Entry, $locus);
}

sub get_remarks_from_Entry {
    my( $self, $text, $obj ) = @_;

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

sub locus_description_Entry {
    my( $self, $locus_description_Entry ) = @_;

    if ($locus_description_Entry) {
        $self->{'_locus_description_Entry'} = $locus_description_Entry;
    }
    return $self->{'_locus_description_Entry'};
}

sub get_locus_description {
    my( $self ) = @_;

    my $desc = $self->locus_description_Entry->get;
    $desc =~ s/(^\s+|\s+$)//g;
    if ($desc) {
        return $desc;
    } else {
        return;
    }
}

sub locus_alias_Entry {
    my( $self, $locus_alias_Entry ) = @_;

    if ($locus_alias_Entry) {
        $self->{'_locus_alias_Entry'} = $locus_alias_Entry;
    }
    return $self->{'_locus_alias_Entry'};
}

sub get_locus_aliases {
    my( $self ) = @_;

    my $alias_str = $self->locus_alias_Entry->get;
    $alias_str =~ s/(^\s+|\s+$)//g;
    my @aliases = split /\s+/, $alias_str;
    if (@aliases) {
        return @aliases;
    } else {
        return;
    }
}

sub get_subseq_name {
    my( $self ) = @_;

    my $name = $self->subseq_name_Entry->get;
    $name =~ s/\s+//g;
    return $name || 'NO-NAME';
}

sub set_subseq_name {
    my( $self, $new ) = @_;

    my $entry = $self->subseq_name_Entry;
    $entry->delete(0, 'end');
    $entry->insert(0, $new);

    return;
}

sub method_name_var {
    my( $self, $var_ref ) = @_;

    if ($var_ref) {
        $self->{'_method_name_var'} = $var_ref;
    }
    return $self->{'_method_name_var'};
}

sub get_GeneMethod_from_tk {
    my( $self ) = @_;

    my $meth_name = ${$self->method_name_var};
    return $self->XaceSeqChooser->get_GeneMethod($meth_name);
}

sub canvas_insert_character {
    my( $self, $canvas, $char ) = @_;

    my $text = $canvas->focus or return;
    $canvas->insert($text, 'insert', $char);
    $self->re_highlight($text);
    $self->update_splice_strings($text);
    $self->remove_spurious_splice_sites;

    return;
}

sub increment_int {
    my( $self ) = @_;

    my $canvas = $self->canvas;
    my $text = $canvas->focus or return;
    my $num = $canvas->itemcget($text, 'text');
    if ($num =~ /^\d+$/) {
        $num++;
        $canvas->itemconfigure($text, -text => $num);
        $self->re_highlight($text);
        $self->update_splice_strings($text);
        $self->remove_spurious_splice_sites;
    }

    return;
}

sub decrement_int {
    my( $self ) = @_;

    my $canvas = $self->canvas;
    my $text = $canvas->focus or return;
    my $num = $canvas->itemcget($text, 'text');
    if ($num =~ /^\d+$/) {
        $num--;
        $canvas->itemconfigure($text, -text => $num);
        $self->re_highlight($text);
        $self->update_splice_strings($text);
        $self->remove_spurious_splice_sites;
    }

    return;
}

sub canvas_text_go_left {
    my( $self ) = @_;

    my $canvas = $self->canvas;
    my $text = $canvas->focus or return;
    my $pos = $canvas->index($text, 'insert');
    $canvas->icursor($text, $pos - 1);

    return;
}

sub canvas_text_go_right {
    my( $self ) = @_;

    my $canvas = $self->canvas;
    my $text = $canvas->focus or return;
    my $pos = $canvas->index($text, 'insert');
    $canvas->icursor($text, $pos + 1);

    return;
}

sub canvas_backspace {
    my( $self ) = @_;

    my $canvas = $self->canvas;
    my $text = $canvas->focus or return;
    my $pos = $canvas->index($text, 'insert')
        or return;  # Don't delete when at beginning of string
    $canvas->dchars($text, $pos - 1);
    $self->re_highlight($text);
    $self->update_splice_strings($text);
    $self->remove_spurious_splice_sites;

    return;
}

sub select_all_exon_pos {
    my( $self ) = @_ ;

    my $canvas = $self->canvas;
    return $self->highlight($canvas->find('withtag', 'exon_pos'));
}

sub delete_chooser_window_ref {
    my( $self ) = @_;

    my $name = $self->name;
    my $xc = $self->XaceSeqChooser;
    $xc->delete_subseq_edit_window($name);

    return;
}

sub left_button_handler {
    my( $self ) = @_;

    return if $self->delete_message;
    $self->deselect_all;
    $self->shift_left_button_handler;

    return;
}

sub focus_on_current_text {
    my( $self ) = @_;

    my $canvas = $self->canvas;
    my ($obj) = $canvas->find('withtag', 'current') or return;
    if (grep { /translation_region|exon_pos/ } $canvas->gettags($obj) ) {
        $canvas->focus($obj);

        # Position the icursor at the end of the text
        $canvas->icursor($obj, 'end');

        if ($canvas->itemcget($obj, 'text') eq $self->empty_string) {
            $canvas->itemconfigure($obj,
                -text   => '',
                );
        }
        $canvas->focus($obj);
    }

    return;
}

sub shift_left_button_handler {
    my( $self ) = @_;

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

sub control_left_button_handler {
    my( $self ) = @_;

    my $canvas = $self->canvas;
    my ($obj) = $canvas->find('withtag', 'current') or return;
    my %tags = map { $_ => 1 } $canvas->gettags($obj);
    if ($tags{'plus_strand'}) {
        $self->set_tk_strand(-1);
    }
    elsif ($tags{'minus_strand'}) {
        $self->set_tk_strand(1);
    }
    $self->update_splice_strings($obj);
    $self->remove_spurious_splice_sites;

    return;
}

sub set_tk_strand {
    my( $self, $strand ) = @_;

    my( $del_tag, $draw_method );
    if ($strand == 1) {
        $del_tag = 'minus_strand';
        $draw_method = 'draw_plus';
    } else {
        $del_tag = 'plus_strand';
        $draw_method = 'draw_minus';
    }

    my $canvas = $self->canvas;
    foreach my $obj ($canvas->find('withtag', $del_tag)) {
        my @tags = grep { $_ ne $del_tag } $canvas->gettags($obj);
        $canvas->delete($obj);
        my ($i) = map { /exon_id-(\d+)/ } @tags;
        #warn "Drawing strand indicator for exon $i\n";
        my( $size, $half, $pad, $text_len,
            $x1, $y1, $x2, $y2 ) = $self->exon_holder_coords($i - 1);
        $self->$draw_method($x1 + $half, $y1, $size, @tags);
    }

    $self->sort_all_coordinates;
    $self->remove_spurious_splice_sites;

    return;
}

sub toggle_tk_strand {
    my( $self ) = @_;

    if ($self->strand_from_tk == 1) {
        $self->set_tk_strand(-1);
    } else {
        $self->set_tk_strand(1);
    }

    return;
}

sub empty_string {
    return '<empty>';
}

sub deselect_all {
    my( $self ) = @_;

    my $canvas = $self->canvas;

    # Avoid unselectable empty text objects
    if (my $obj = $canvas->focus) {
        if ($canvas->type($obj) eq 'text') {
            my $text_string = $canvas->itemcget($obj, 'text');
            unless ($text_string) {
                $canvas->itemconfigure($obj,
                    -text   => $self->empty_string,
                    );
            }
        }
    }
    $canvas->focus("");

    $self->SUPER::deselect_all;

    return;
}

sub export_highlighted_text_to_selection {
    my( $self, $offset, $max_bytes ) = @_;

    my @text = $self->get_all_selected_text;
    my $clip = '';
    if (@text == 1) {
        $clip = $text[0];
    } else {
        for (my $i = 0; $i < @text; $i += 2) {
            my($start, $end) = @text[$i, $i + 1];
            $end ||= $self->empty_string;
            $clip .= "$start  $end\n";
        }
    }

    return substr($clip, $offset, $max_bytes);
}

sub export_ace_subseq_to_selection {
    my( $self, $offset, $max_bytes ) = @_;

    my $sub = $self->new_SubSeq_from_tk;

    return substr($sub->ace_string, $offset, $max_bytes);
}

sub middle_button_paste {
    my( $self ) = @_;

    my $canvas = $self->canvas;

    my @ints = $self->integers_from_clipboard;
    return unless @ints;

    $self->deselect_all;
    
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
            $self->update_splice_strings($obj) if $obj_tags{'exon_pos'};
            #$self->remove_spurious_splice_sites;
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
            my $pp = ($self->position_pairs)[$exon_num - 1];
            $self->set_position_pair_text($pp, [$start, $end]);
            $self->highlight(@$pp[0,1]);
        }
    }
    
    unless ($did_paste) {
        my @pos = $self->all_position_pair_text;

        # If there is only 1 <empty> pair, write to it
        my $was_empty = 0;
        if (@pos == 1 and $pos[0][0] == 0 and $pos[0][1] == 0) {
            $self->trim_position_pairs(1);
            $was_empty = 1;
        }

        for (my $i = 0; $i < @ints; $i += 2) {
            $self->add_coordinate_pair(@ints[$i, $i + 1]);
        }

        $self->fix_window_min_max_sizes;
    }
    
    $self->remove_spurious_splice_sites;

    return;
}

sub next_exon_holder_coords {
    my( $self ) = @_;

    my $i = $self->next_position_pair_index;
    return $self->exon_holder_coords($i);
}

sub exon_holder_coords {
    my( $self, $i ) = @_;

    $i++;   # Move exons down 1 line to make space for splice site sequence
    my( $size, $half, $pad, $text_len, @bbox ) = $self->_coord_matrix;
    my $y_offset = $i * ($size + (2 * $pad));
    $bbox[1] += $y_offset;
    $bbox[3] += $y_offset;
    return( $size, $half, $pad, $text_len, @bbox );
}

sub _coord_matrix {
    my( $self ) = @_;

    my( $m );
    unless ($m = $self->{'_coord_matrix'}) {
        my $uw      = $self->font_unit_width;
        my $size    = $self->font_size;
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

sub update_splice_strings {
    my ($self, $tag_or_id) = @_;

    my $canvas = $self->canvas;

    my %exons_to_update;
    foreach my $obj ($canvas->find('withtag', $tag_or_id)) {
        my ($exon_id) = grep { /^exon_id/ } $canvas->gettags($obj);
        $exons_to_update{$exon_id} = 1 if $exon_id;
    }
    
    my @good = (
        -font => $self->font_fixed,
        -fill => 'YellowGreen',
        );
    my @bad  = (
        -font => $self->font_fixed_bold,
        -fill => "#ee2c2c",     # firebrick2
        );
        
    foreach my $exon_id (keys %exons_to_update) {
        
        my ($start, $end) = map { $canvas->itemcget($_, 'text') } $canvas->find('withtag', "$exon_id&&exon_pos");
        if ($start > $end) {
            ($start, $end) = ($end, $start);
        }
        
        my $strand = $self->exon_strand_from_tk($exon_id);
        my ($acc_str, $don_str) = $self->get_splice_acceptor_donor_strings($start, $end, $strand);
        
       
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

sub remove_spurious_splice_sites {
    my ($self) = @_;
    
    my $canvas = $self->canvas;
    
    my @pps = sort { $a->[0] <=> $b->[0] } $self->position_pairs;
    
    return unless @pps;
    
    my $initial_exon_id = $pps[0]->[2];
    my $terminal_exon_id = $pps[-1]->[2];
    
    $self->update_splice_strings('exon_end');
    
    my ($acceptor_txt) = $canvas->find('withtag', "$initial_exon_id&&splice_acceptor");
    $canvas->itemconfigure($acceptor_txt, -text => '');
    
    my ($donor_txt) = $canvas->find('withtag', "$terminal_exon_id&&splice_donor");
    $canvas->itemconfigure($donor_txt, -text => '');

    return;
}

sub get_splice_acceptor_donor_strings {
    my ($self, $start, $end, $strand) = @_;
    
    # Fetch the splice donor and acceptor sequences before switching start/end for reverse strand
    my ($splice_acceptor_str, $splice_donor_str);
    if ($start and $end) {
        eval { $splice_acceptor_str = $self->SubSeq->splice_acceptor_seq_string($start, $end, $strand) };
        # warn $@ if $@;
        eval { $splice_donor_str    = $self->SubSeq->splice_donor_seq_string(   $start, $end, $strand) };
        # warn $@ if $@;
    }
    $splice_acceptor_str ||= '??';
    $splice_donor_str    ||= '???';

    return ($splice_acceptor_str, $splice_donor_str);
}

sub add_exon_holder {
    my( $self, $start, $end, $strand) = @_;
    $start ||= $self->empty_string;
    $end   ||= $self->empty_string;

    my $arrow = ($strand == 1) ? 'last' : 'first';
    if ($strand == -1) {
        ($start, $end) = ($end, $start);
    }

    my $canvas  = $self->canvas;
    my $font    = $self->font_fixed;
    my $exon_id = 'exon_id-'. $self->next_exon_number;
    my( $size, $half, $pad, $text_len,
        $x1, $y1, $x2, $y2 ) = $self->next_exon_holder_coords;
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
        $self->draw_plus ($x1 + $half, $y1, $size, $exon_id, 'exon_furniture');
    } else {
        $self->draw_minus($x1 + $half, $y1, $size, $exon_id, 'exon_furniture');
    }

    my $end_text = $canvas->createText(
        $x2, $y1 + $half,
        -anchor     => 'w',
        -text       => $end,
        -font       => $font,
        -tags       => [$exon_id, 'exon_pos', 'exon_end'],
        );

    $self->add_position_pair($start_text, $end_text, $exon_id);

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

    $self->update_splice_strings($exon_id);

    $self->position_mobile_elements;

    # Return how big we were
    return $size + $pad;
}

sub position_mobile_elements {
    my( $self ) = @_;

    my $canvas = $self->canvas;
    return unless $canvas->find('withtag', 'mobile');
    my $size = $self->font_size;
    my $pad  = int($size / 2);

    my $mobile_top   = ($canvas->bbox( 'mobile'))[1];
    my $fixed_bottom = ($canvas->bbox('!mobile'))[3] + $pad;

    $canvas->move('mobile', 0, $fixed_bottom - $mobile_top);

    return;
}

sub draw_plus {
    my( $self, $x, $y, $size, @tags ) = @_;

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

sub draw_minus {
    my( $self, $x, $y, $size, @tags ) = @_;

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

sub strand_from_tk {
    my( $self, $keep_quiet ) = @_;

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

    sub draw_translation_region {
        my( $self, $sub ) = @_;

        # Get the translation region from the
        # canvas or the SubSequence
        my( @trans );
        if ($sub) {
            return unless $sub->translation_region_is_set;  ### Why is this needed?
            @trans = $sub->translation_region;
        } else {
            @trans = $self->translation_region_from_tk;
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
            $meth = $self->get_GeneMethod_from_tk;
            $strand = $self->strand_from_tk;
        }
        return unless $meth->coding;

        my( $size, $half, $pad, $text_len, $x1, $y1, $x2, $y2 ) = $self->_coord_matrix;
        my $font = $self->font_fixed_bold;

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

    sub translation_region_from_tk {
        my( $self ) = @_;

        my $canvas = $self->canvas;
        my( @region );
        foreach my $obj ($canvas->find('withtag', $tr_tag)) {
            push(@region, $canvas->itemcget($obj, 'text'));
        }
        return(sort {$a <=> $b} @region);
    }
}

sub tk_t_start {
    my( $self, $start ) = @_;

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

sub tk_t_end {
    my( $self, $end ) = @_;

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

sub get_SubSeq_if_changed {
    my( $self ) = @_;

    my $old = $self->SubSeq;
    my $new = $self->new_SubSeq_from_tk;

    # Preserve Otter ids in SubSeq (not attached Locus)
    $new->take_otter_ids($old);

    # Get the otter_id for the locus, or take it from
    # an existing locus if we are renaming.
    $self->manage_locus_otter_ids($old, $new);

    # printf STDERR "Comparing old:\n%s\nTo new:\n%s",
    #     $old->ace_string, $new->ace_string;

    if ($old->is_archival and $new->ace_string eq $old->ace_string) {
        # SubSeq is saved, and there are no changes.
        return;
    }

    # printf STDERR "OLD:\n>%s<\nNEW:>%s<\n", $old->ace_string, $new->ace_string;

    my $new_name = $new->name;
    if ($new_name ne $self->name) {
        if ($self->XaceSeqChooser->get_SubSeq($new_name)) {
            confess "Error: SubSeq '$new_name' already exists\n";
        }
    }

    $new->validate;
    $new->set_seleno_remark_from_translation;
    return $new;
}

sub manage_locus_otter_ids {
    my( $self, $old, $new ) = @_;

    my $new_locus = $new->Locus;
    my $new_locus_name = $new_locus->name;

    # Copy locus otter_id from existing Locus of same name if present
    my $xc_locus = $self->XaceSeqChooser->get_Locus($new_locus_name);
    if (my $xc_locus_otter_id = $xc_locus->otter_id) {
        $new_locus->otter_id($xc_locus_otter_id);
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

sub new_SubSeq_from_tk {
    my( $self ) = @_;

    my $new = $self->SubSeq->clone;
    $new->unset_Locus;
    $new->unset_translation_region;
    $new->translation_region     ( $self->translation_region_from_tk  );
    $new->name                   ( $self->get_subseq_name             );
    $new->replace_all_Exons      ( $self->Exons_from_canvas           );
    $new->GeneMethod             ( $self->get_GeneMethod_from_tk      );
    $new->strand                 ( $self->strand_from_tk              );
    $new->end_not_found          ( $self->end_not_found_from_tk       );
    $new->evidence_hash          ( $self->evidence_hash               );
    $new->Locus                  ( $self->get_Locus_from_tk           );
    $self->get_transcript_remarks($new);

    my $snf = $self->start_not_found_from_tk;
    if ($snf eq 'utr') {
        $new->utr_start_not_found(1);
        $new->start_not_found(0);
    } else {
        $new->utr_start_not_found(0);
        $new->start_not_found($snf);
    }
    
    # warn "Start not found ", $self->start_not_found_from_tk, "\n",
    #      "  End not found ", $self->end_not_found_from_tk,   "\n";
    return $new;
}

sub save_if_changed {
    my( $self ) = @_;

    eval {
        if (my $sub = $self->get_SubSeq_if_changed) {
            $self->xace_save($sub);
        }
    };

    # Make sure the annotators see the messages!
    if ($@) {
        $self->exception_message($@, 'Error saving transcript');
    }

    return;
}

sub xace_save {
    my( $self, $sub ) = @_;

    confess "Missing SubSeq argument" unless $sub;

    my $top = $self->top_window;
    $top->grab;     # Stop user closing window before save is finished

    my $old = $self->SubSeq;
    my $old_name = $old->name;
    my $new_name = $sub->name;

    my $clone_name = $sub->clone_Sequence->name;
    if ($clone_name eq $new_name) {
        $self->message("Can't have SubSequence with same name as clone!");
        $top->grabRelease;
        return;
    }
    my $xc = $self->XaceSeqChooser;

    $xc->replace_SubSeq($sub, $old);
    $self->SubSeq($sub);
    $self->update_transcript_remark_widget($sub);
    $self->name($new_name);
    $self->evidence_hash($sub->clone_evidence_hash);

    # update_Locus in this object will be called
    # from update_Locus in the XaceSeqChooser
    $xc->update_Locus($sub->Locus);

    $sub->is_archival(1);
    
    $top->grabRelease;
    
    return 1;
}

sub Exons_from_canvas {
    my( $self ) = @_;

    my $done_message = 0;
    my( @exons );
    foreach my $pp ($self->all_position_pair_text) {
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

sub check_for_errors {
    my ($self) = @_;

    my $sub = $self->new_SubSeq_from_tk;
    $sub->locus_level_errors($self->SubSeq->locus_level_errors);
    if (my $err = $sub->pre_otter_save_error) {
        $err =~ s/\n$//;
        $self->message($err);
    } else {
        $self->message('Transcript OK');
    }

    return;
}

sub run_dotter {
    my( $self ) = @_;

    my( $hit_name );
    if (my $txt = $self->get_clipboard_text) {
        # Match fMap "blue box"
        ($hit_name) = $txt =~ /^(?:<?(?:Protein|Sequence)[:>]?)?\"?([^\"\s]+)\"?/;
    }
    unless ($hit_name) {
        $self->message('Cannot see a hit name on the clipboard');
        return;
    }

    my( $cdna );
    eval {
        my( $sub );
        if ($self->is_mutable) {
            $sub = $self->new_SubSeq_from_tk;
        } else {
            $sub = $self->SubSeq;
        }
        $sub->validate;
        $cdna = $sub->mRNA_Sequence;
    };
    if ($@) {
        $self->exception_message($@, 'Error fetching mRNA sequence');
        return;
    }

    my $dotter = Hum::Ace::DotterLauncher->new;
    $dotter->query_Sequence($cdna);
    $dotter->query_start(1);
    $dotter->query_end($cdna->sequence_length);
    $dotter->subject_name($hit_name);

    return $dotter->fork_dotter;
}

sub max_exon_number {
    my( $self ) = @_;

    return $self->{'_max_exon_number'} || 0;
}

sub next_exon_number {
    my( $self ) = @_;

    $self->{'_max_exon_number'}++;
    return $self->{'_max_exon_number'};
}

sub decrement_exon_counter {
    my( $self, $count ) = @_;

    confess "No count given" unless defined $count;
    $self->{'_max_exon_number'} -= $count;

    return;
}

sub DESTROY {
    my( $self ) = @_;

    my $name = $self->name;
    warn "Destroying ExonCanvas: '$name'\n";

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

=head1 NAME - MenuCanvasWindow::ExonCanvas

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

