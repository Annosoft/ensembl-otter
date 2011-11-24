
package MenuCanvasWindow::XaceSeqChooser;

use strict;
use warnings;

use Carp;
use Scalar::Util 'weaken';

require Tk::Dialog;
require Tk::Balloon;

use Hum::Ace::SubSeq;
use Hum::Ace::Locus;
use Hum::Ace::XaceRemote;
use Hum::Ace::Assembly;
use Hum::Analysis::Factory::ExonLocator;
use Hum::Sort qw{ ace_sort };
use Hum::ClipboardUtils qw{ text_is_zmap_clip };
use EditWindow::Dotter;
use EditWindow::Exonerate;
use EditWindow::Clone;
use EditWindow::LocusName;
use MenuCanvasWindow::ExonCanvas;
use MenuCanvasWindow::GenomicFeatures;
use Text::Wrap qw{ wrap };

use Bio::Otter::Lace::Exonerate;
use Bio::Otter::ZMap::XML;
use Bio::Vega::Evidence::Types qw{ new_evidence_type_valid };

use base qw{
MenuCanvasWindow
MenuCanvasWindow::ZMapSeqChooser
};

my $PROT_SCORE = 100;
my $DNA_SCORE  = 100;
my $DNAHSP     = 120;

sub new {
    my( $pkg, $tk ) = @_;

    my $self = $pkg->SUPER::new($tk);
    
    $self->populate_menus;
    $self->make_search_panel;
    $self->bind_events;
    $self->minimum_scroll_bbox(0,0, 380,200);
    $self->flag_db_edits(1);

    return $self;
}

sub AceDatabase {
    my( $self, $AceDatabase ) = @_;

    if ($AceDatabase) {
        $self->{'_AceDatabase'} = $AceDatabase;
    }
    return $self->{'_AceDatabase'};
}

sub drop_AceDatabase {
    my( $self ) = @_;

    $self->{'_AceDatabase'} = undef;

    return;
}

sub SequenceNotes {
    my ($self, $sn) = @_;

    if ($sn){
        $self->{'_sequence_notes'} = $sn ;
    }
    return $self->{'_sequence_notes'} ;
}

sub initialize {
    my( $self ) = @_;

    $self->set_window_title;

    # take GeneMethods from methods.ace file
    $self->set_known_GeneMethods();

    unless ($self->AceDatabase->write_access) {
        $self->menu_bar()->Label(
            -text       => 'Read Only',
            -foreground => 'red',
            -padx       => 6,
            )->pack(
                    -side => 'right',
                    );
    }

    $self->fetch_external_SubSeqs;
    $self->draw_subseq_list;
    $self->populate_clone_menu;
    $self->zMapInitialize;
    $self->zMapLaunchZmap;
    $self->top_window->raise;

    return;
}

sub menu_bar {
    my( $self, $bf ) = @_;

    if ($bf) {
        $self->{'_menu_bar'} = $bf;
    }
    return $self->{'_menu_bar'};
}

sub clone_menu {
    my( $self, $clone_menu ) = @_;

    if ($clone_menu) {
        $self->{'_clone_menu'} = $clone_menu;
    }
    return $self->{'_clone_menu'};
}

sub balloon {
    my( $self ) = @_;
    
    $self->{'_balloon'} ||= $self->top_window->Balloon(
        -state  => 'balloon',
        );
    return $self->{'_balloon'};
}

sub set_known_GeneMethods {
    my ($self) = @_;

    my $lst = $self->{'_gene_methods_list'} = [
        $self->Assembly->MethodCollection->get_all_transcript_Methods
        ];
    my $idx = $self->{'_gene_methods'} = {};
    %$idx = map {$_->name, $_} @$lst;

    return;
}

sub get_GeneMethod {
    my( $self, $name ) = @_;

    my( $meth );
    unless ($meth = $self->{'_gene_methods'}{$name}) {
        confess "No such Method '$name'";
    }
    return $meth;
}

sub get_all_GeneMethods {
    my( $self ) = @_;

    return @{$self->{'_gene_methods_list'}};
}

sub get_all_mutable_GeneMethods {
    my( $self ) = @_;

    return $self->Assembly->MethodCollection->get_all_mutable_GeneMethods;
}

sub get_default_mutable_GeneMethod {
    my( $self ) = @_;

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

sub get_Locus {
    my( $self, $name ) = @_;

    my( $locus );
    if (ref($name)) {
        $locus = $name;
        $name = $locus->name;
    }

    if (my $cached = $self->{'_locus_cache'}{$name}) {
        return $cached;
    } else {
        unless ($locus) {
            $locus = Hum::Ace::Locus->new;
            $locus->name($name);
        }
        $self->{'_locus_cache'}{$name} = $locus;
        return $locus;
    }
}

sub set_Locus {
    my( $self, $locus ) = @_;

    my $name = $locus->name;
    $self->{'_locus_cache'}{$name} = $locus;

    return;
}

sub get_all_Loci {
    my( $self ) = @_;
    my $lc = $self->{'_locus_cache'};
    return values %$lc;
}

sub list_Locus_names {
    my( $self ) = @_;
    my @names = sort {lc $a cmp lc $b} map { $_->name } $self->get_all_Loci;
    return @names;
}

sub empty_Locus_cache {
    my( $self ) = @_;

    $self->{'_locus_cache'} = undef;

    return;
}

sub update_Locus {
    my( $self, $new_locus ) = @_;

    $self->set_Locus($new_locus);

    my $locus_name = $new_locus->name;

    foreach my $sub_name ($self->list_all_SubSeq_names) {
        my $sub = $self->get_SubSeq($sub_name) or next;
        my $old_locus = $sub->Locus or next;

        if ($old_locus->name eq $locus_name) {
            # Replace locus in subseq with new copy
            $sub->Locus($new_locus);

            # Is there an edit window open?
            if (my $ec = $self->get_subseq_edit_window($sub_name)) {
                $ec->update_Locus($new_locus);
            }
        }
    }

    return;
}

sub do_rename_locus {
    my( $self, $old_name, $new_name ) = @_;

    eval {
        my @xml;
        my $offset = $self->AceDatabase->offset;
        foreach my $sub ($self->fetch_SubSeqs_by_locus_name($old_name)) {
            push @xml, $sub->zmap_delete_xml_string($offset);
        }

        my $locus_cache = $self->{'_locus_cache'}
            or confess "Did not get locus cache";

        if ($locus_cache->{$new_name}) {
            $self->message("Cannot rename to '$new_name'; Locus already exists");
            return;
        }

        my $locus = delete $locus_cache->{$old_name}
            or confess "No locus called '$old_name'";
        $locus->name($new_name);
        $self->set_Locus($locus);

        my $ace = qq{\n-R Locus "$old_name" "$new_name"\n};

        # Need to deal with gene type prefix, in case the rename
        # involves a prefix being added, removed or changed.
        if (my ($pre) = $new_name =~ /^([^:]+):/) {
            $locus->gene_type_prefix($pre);
            $ace .= qq{\nLocus "$new_name"\nType_prefix "$pre"\n};
        } else {
            $locus->gene_type_prefix('');
            $ace .= qq{\nLocus "$new_name"\n-D Type_prefix\n};
        }
    
        # Now we need to update Zmap with the new locus names
        foreach my $sub ($self->fetch_SubSeqs_by_locus_name($new_name)) {
            push @xml, $sub->zmap_create_xml_string($offset);
        }
        $self->zMapSendCommands(@xml);    

        $self->save_ace($ace);
    };

    if ($@) {
        $self->exception_message("Error renaming locus '$old_name' to '$new_name'; ". $@);
    }

    return;
}

sub fetch_SubSeqs_by_locus_name {
   my( $self, $locus_name ) = @_;

   my @list;
   foreach my $name ($self->list_all_SubSeq_names) {
       my $sub = $self->get_SubSeq($name) or next;
       my $locus = $sub->Locus or next;
       if ($locus->name eq $locus_name) {
           push(@list, $sub);
       }
   }
   return @list;
}


#------------------------------------------------------------------------------------------

sub make_menu {
    my( $self, $name, $pos, @rest ) = @_;

    $pos ||= 0;

    my $menu_frame = $self->menu_bar
        or confess "No menu_bar";
    my $button = $menu_frame->Menubutton(
        -text       => $name,
        -underline  => $pos,
        #-padx       => 8,
        #-pady       => 6,
        );
    $button->pack(
        -side       => 'left',
        );
    my $menu = $button->Menu(
        -tearoff    => 0,
        @rest,
    );
    $button->configure(
        -menu       => $menu,
    );

    return $menu;
}

sub populate_menus {
    my( $self ) = @_;

    my $menu_frame = $self->menu_bar
        or confess "No menu_bar";
    my $top = $menu_frame->toplevel;

    # File menu
    my $file = $self->make_menu('File');

    # Save annotations to otter
    my $save_command = sub {
        unless ($self->close_all_edit_windows) {
            $self->message('Not saving because some editing windows are still open');
            return;
        }
        $self->save_data;
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
    my $resync_command = sub { $self->resync_with_db };
    $file->add('command',
        -label          => 'Resync',
        -hidemargin     => 1,
        -command        => $resync_command,
        -accelerator    => 'Ctrl+R',
        -underline      => 0,
        );
    $top->bind('<Control-r>', $resync_command);
    $top->bind('<Control-R>', $resync_command);

    # Close window
    my $exit_command = sub {
        $self->exit_save_data or return;
        $self->LoadColumns->top->destroy;
        };
    $file->add('command',
        -label          => 'Close',
        -command        => $exit_command,
        -accelerator    => 'Ctrl+W',
        -underline      => 0,
        );
    $top->bind('<Control-w>', $exit_command);
    $top->bind('<Control-W>', $exit_command);
    $top->protocol('WM_DELETE_WINDOW', $exit_command);

    # Subseq menu
    my $subseq = $self->make_menu('SubSeq', 1);

    # Edit subsequence
    my $edit_command = sub{
        $self->edit_subsequences;
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
        $self->close_all_subseq_edit_windows;
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
        $self->copy_selected_subseqs;
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
        eval {
            $self->paste_selected_subseqs;
        };
        if ($@) {
            $self->exception_message($@);
        }
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
        $self->edit_new_subsequence;
        };
    $subseq->add('command',
        -label          => 'New',
        -command        => $new_command,
        -accelerator    => 'Ctrl+N',
        -underline      => 0,
        );
    $top->bind('<Control-n>', $new_command);
    $top->bind('<Control-N>', $new_command);

    # Make an variant of the current selected sequence
    my $variant_command = sub{
        $self->make_variant_subsequence;
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
        $self->delete_subsequences;
        };
    $subseq->add('command',
        -label          => 'Delete',
        -command        => $delete_command,
        -accelerator    => 'Ctrl+D',
        -underline      => 0,
        );
    $top->bind('<Control-d>', $delete_command);
    $top->bind('<Control-D>', $delete_command);

    my $clone_menu = $self->make_menu("Clone");
    $self->clone_menu($clone_menu);

    my $tools_menu = $self->make_menu("Tools");

    # Launch Zmap
    my $zmap_launch_command = sub { $self->zMapLaunchZmap };
    $tools_menu->add('command',
               -label          => 'Launch ZMap',
               -command        => $zmap_launch_command,
               -accelerator    => 'Ctrl+Z',
               -underline      => 7,
               );
    $top->bind('<Control-z>', $zmap_launch_command);
    $top->bind('<Control-Z>', $zmap_launch_command);

    $zmap_launch_command = sub { $self->zMapLaunchInAZmap };
    $tools_menu->add('command',
               -label          => 'Launch In A ZMap',
               -command        => $zmap_launch_command,
               -underline      => 7,
               );

    # Genomic Features editing window
    my $gf_command = sub { $self->launch_GenomicFeatures };
    $tools_menu->add('command' ,
        -label          => 'Genomic Features',
        -command        => $gf_command,
        -accelerator    => 'Ctrl+G',
        -underline      => 0,
    );
    $top->bind('<Control-g>', $gf_command);
    $top->bind('<Control-G>', $gf_command);

    ## Spawn dotter Ctrl .
    my $run_dotter_command = sub { $self->run_dotter };
    $tools_menu->add('command',
        -label          => 'Dotter Zmap hit',
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
               -command        => sub {$self->show_lcd_dialog()},
    );

    $subseq->bind('<Destroy>', sub{
        $self = undef;
    });

    return;
}

sub LoadColumns {
    my( $self, $lc ) = @_;
    
    $self->{'_LoadColumns'} = $lc if $lc;
    
    return $self->{'_LoadColumns'};
}

sub show_lcd_dialog {
    my ($self) = @_;

    my $lc = $self->LoadColumns;
    my $top = $lc->top;
    # we need to force a redraw
    $lc->reset_progress;
    $lc->show_filters;
    $top->deiconify;
    $top->raise;

    return;
}

sub populate_clone_menu {
    my ($self) = @_;

    my $clone_menu = $self->clone_menu;
    foreach my $clone ($self->Assembly->get_all_Clones) {
        $clone_menu->add('command',
            # NB: $clone->name ne $clone->clone_name
            -label          => $clone->clone_name,
            # Not an accelerator - just for formatting!
            -accelerator    => $clone->accession_version,
            -command        => sub{ $self->edit_Clone_by_name($clone->name) },
            );
    }

    $clone_menu->bind('<Destroy>', sub{
        $self = undef;
    });

    return;
}

sub bind_events {
    my( $self ) = @_;

    my $canvas = $self->canvas;

    $canvas->Tk::bind('<Button-1>', [
        sub{ $self->left_button_handler(@_); },
        Tk::Ev('x'), Tk::Ev('y') ]);
    $canvas->Tk::bind('<Shift-Button-1>', [
        sub{ $self->shift_left_button_handler(@_); },
        Tk::Ev('x'), Tk::Ev('y') ]);
    $canvas->Tk::bind('<Double-Button-1>', [
        sub{
            $self->left_button_handler(@_);
            $self->edit_double_clicked;
            },
        Tk::Ev('x'), Tk::Ev('y') ]);

    $canvas->Tk::bind('<Escape>',   sub{ $self->deselect_all        });
    $canvas->Tk::bind('<Return>',   sub{ $self->edit_double_clicked });
    $canvas->Tk::bind('<KP_Enter>', sub{ $self->edit_double_clicked });

    # Clipboard
    $canvas->SelectionHandle( sub{ $self->selected_text_to_clipboard(@_) });

    # Object won't get DESTROY'd without:
    $canvas->Tk::bind('<Destroy>', sub{
        $self = undef;
        });

    return;
}

sub highlight {
    my( $self, @args ) = @_;

    $self->SUPER::highlight(@args);

    my $canvas = $self->canvas;
    $canvas->SelectionOwn(
        -command    => sub{ $self->deselect_all; },
    );
    weaken $self;

    return;
}

sub GenomicFeatures {
    my ($self, $gfs) = @_;

    if(defined($gfs)){
        $self->{'_gfs'} = $gfs;
        weaken($self->{'_gfs'});
    }
    return $self->{'_gfs'};
}

sub launch_GenomicFeatures {
    my( $self ) = @_;
    eval {
        if(my $gfs = $self->GenomicFeatures()) {

            my $gfw = $gfs->top_window();
            $gfw->deiconify;
            $gfw->raise;
        } else {
            my $gfw = $self->canvas->Toplevel;

            $gfs = MenuCanvasWindow::GenomicFeatures->new($gfw);
            $self->GenomicFeatures($gfs);
            $gfs->XaceSeqChooser($self);
            $gfs->initialize;
        }
    };
    if ($@) {
        my $msg = "Error creating GenomicFeatures window: $@";
        warn $msg;
        $self->exception_message($msg);
    }

    return;
}

sub close_GenomicFeatures {
    my( $self ) = @_;

    if(my $gfs = $self->GenomicFeatures()) {
        $gfs->try2save_and_quit();
    }

    return;
}

{
    my( @holding_pen );

    sub copy_selected_subseqs {
        my( $self ) = @_;

        # Empty holding pen
        @holding_pen = ();

        my @select = $self->list_selected_subseq_names;
        unless (@select) {
            $self->message('Nothing selected');
            return;
        }
        foreach my $name (@select) {
            my $sub = $self->get_SubSeq($name)->clone;
            $sub->is_archival(0);
            push(@holding_pen, $sub);
        }

        return;
    }

    sub paste_selected_subseqs {
        my( $self ) = @_;

        unless (@holding_pen) {
            $self->message('No SubSequences on clipboard');
            return;
        }

        my $assembly = $self->Assembly;

        # The ExonLocator finds exons in a genomic sequence
        my $finder = Hum::Analysis::Factory::ExonLocator->new;
        $finder->genomic_Sequence($assembly->Sequence);

        my( @msg, @new_subseq, $i );
        foreach my $sub (@holding_pen) {
            my $name = $sub->name;
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

            if (@new_exons) {
                my $new = $sub->clone;
                my( $temp_name );
                do {
                    $temp_name = sprintf "TEMP-%03d", ++$i;
                } while ($self->get_SubSeq($temp_name));
                #my $temp_name = sprintf "TEMP-%03d", ++$i;
                $new->name($temp_name);
                $new->strand($strand);
                $new->replace_all_Exons(@new_exons);
                $new->clone_Sequence($assembly->Sequence);
                $assembly->add_SubSeq($new);
                if ($sub->translation_region_is_set) {
                    eval {
                        $new->set_translation_region_from_cds_coords($sub->cds_coords);
                    };
                    if ($@) {
                        push(@msg, "Failed to set translation region - check translation of '$temp_name'");
                        $new->translation_region($new->start, $new->end);
                    }
                }
                $new->Locus($self->get_Locus($sub->Locus->name));
                ### set locus gene_type_prefix() here ?
                $self->add_SubSeq($new);
                push(@new_subseq, $new);
                print STDERR $new->ace_string;
            } else {
                $self->message("Got zero exons from realigning '$name'");
            }
        }
        $self->draw_subseq_list;
        $self->highlight_by_name(map { $_->name } @new_subseq);
        $self->message(@msg) if @msg;
        foreach my $new (@new_subseq) {
            $self->make_exoncanvas_edit_window($new);
        }

        return;
    }
}

sub exit_save_data {
    my( $self ) = @_;

    my $adb = $self->AceDatabase;
    unless ($adb->write_access) {
        $adb->error_flag(0);
        $self->close_GenomicFeatures;   ### Why is this special?
        return 1;
    }

    $self->close_all_edit_windows or return;

    if (my @loci = $self->Assembly->get_all_annotation_in_progress_Loci) {

        # Format the text for the dialog
        my $loci_str = join('', map {sprintf "\t%s\n", $_->name} @loci);
        my $loci_phrase = @loci > 1 ? 'loci are'    : 'locus is';
        my $flag_phrase = @loci > 1 ? 'these flags' : 'this flag';
        my $what_phrase = @loci > 1 ? 'their'       : 'its';
        my $txt = "The following $loci_phrase flagged with 'annotation in progress':\n$loci_str"
            . "Is $what_phrase annotation now complete? Answering 'Yes' will remove $flag_phrase and save to otter";

        my $dialog = $self->top_window()->Dialog(
            -title          => 'otter: Annotation complete?',
            -bitmap         => 'question',
            -text           => $txt,
            -default_button => 'No',
            -buttons        => [qw{ Yes No Cancel }],
            );
        my $ans = $dialog->Show;
        if ($ans eq 'Cancel') {
            return;
        }
        elsif ($ans eq 'Yes') {
            my $ace = '';
            foreach my $locus (@loci) {
                $locus->unset_annotation_in_progress;
                $ace .= $locus->ace_string;
                $self->update_Locus($locus);
            }

            eval {
                $self->save_ace($ace);
            };
            if (my $err = $@) {
                warn "Aborting lace session exit:\n$err";
                return;
            }

            if ($self->save_data) {
                $adb->error_flag(0);
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
            -title          => 'otter: Save?',
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
            $self->save_data or return;
        }
    }

    # Unsetting the error_flag means that AceDatabase
    # will remove its directory during DESTROY.
    $adb->error_flag(0);

    return 1;
}

sub close_all_edit_windows {
    my( $self ) = @_;

    $self->close_all_subseq_edit_windows or return;
    $self->close_all_clone_edit_windows or return;
    $self->close_GenomicFeatures;
    return 1;
}

sub save_data {
    my ($self) = @_;

    my $adb = $self->AceDatabase;

    unless ($adb->write_access) {
        warn "Read only session - not saving\n";
        return 1;   # Can't save - but is OK
    }
    my $top = $self->top_window();

    $top->Busy;

    eval{
        my $ace_data = $adb->save_ace_to_otter;
        $adb->unsaved_changes(0);
        $self->flag_db_edits(0);    # or the save_ace() will set unsaved_changes back to "1"
        $self->save_ace($ace_data);
        $self->flag_db_edits(1);
        $self->resync_with_db;
        $self->update_window_title_unsaved_flag(0);
    };
    my $err = $@;

    $top->Unbusy;

    if ($err) {
        $self->exception_message($err, 'Error saving to otter');
        return 0;
    } else {
        return 1;
    }
}

sub edit_double_clicked {
    my( $self ) = @_;

    return unless $self->list_selected;

    my $canvas = $self->canvas;
    $canvas->Busy;
    $self->edit_subsequences;
    $canvas->Unbusy;

    return;
}

sub left_button_handler {
    my( $self, $canvas, $x, $y ) = @_;

    return if $self->delete_message;

    $self->deselect_all;
    if (my ($obj) = $canvas->find('withtag', 'current')) {
        $self->highlight($obj);
    }

    return;
}

sub shift_left_button_handler {
    my( $self, $canvas, $x, $y ) = @_;

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

sub make_search_panel {
    my ($self) = @_;

    my $top = $self->top_window();
    my $search_frame = $top->Frame();
    $search_frame->pack(-side => 'top');

    my $search_box = $search_frame->Entry(
        -width => 22,
        );
    $search_box->pack(-side => 'left');

    $search_frame->Frame(-width => 6)->pack(-side => 'left');

    # Is hunting in CanvasWindow?
    my $hunter = sub{
        $top->Busy;
        $self->hunt_for_Entry_text($search_box);
        $top->Unbusy;
    };
    my $button = $search_frame->Button(
         -text      => 'Find',
         -command   => $hunter,
         -underline => 0,
         )->pack(-side => 'left');

    my $clear_command = sub {
        $search_box->delete(0, 'end');
        };
    my $clear = $search_frame->Button(
        -text      => 'Clear',
        -command   => $clear_command,
        -underline => 2,
        )->pack(-side => 'left');
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


sub hunt_for_Entry_text {
    my ($self, $entry) = @_;

    # Searches for the text given in the supplied Entry in
    # the acedb string representation of all the subsequences.

    my $canvas = $self->canvas;
    my( $query_str, $regex );
    eval{
        $query_str = $entry->get();
        $query_str =~ s{([^\w\*\?\\])}{\\$1}g;
        $query_str =~ s{\*}{.*}g;
        $query_str =~ s{\?}{.}g;
        $regex =  qr/($query_str)/i;
    };
    return unless $query_str;
    # warn $query_str;
    # warn $regex;
    $canvas->delete('msg');
    $self->deselect_all();

    my @matching_sub_names;
    my @ace_fail_names;
    foreach my $name ($self->list_all_SubSeq_names) {
        my $sub = $self->get_SubSeq($name) or next;
        my $str = eval { $sub->ace_string };
        if ($@) {
            # Data outside our control may break Hum::Ace::SubSeq  RT:188195, 189606
            my $err = $@;
            warn "hunt_for_Entry_text on $name: $err";
            push @ace_fail_names, $name;
            # It could be a real error, not just some broken data.
            # We'll mention that if there are no results.
            next;
        }
        if (my ($hit) = $str =~ /$regex/) {
            push(@matching_sub_names, $name);
        }
    }

    if (@ace_fail_names && !@matching_sub_names) {
        # We see only errors.  Highlight them.
        $self->message("hunt_for_Entry_text: NO RESULTS, but did encounter errors while searching.  Highlighting those instead.");
        @matching_sub_names = @ace_fail_names;
    } elsif (@ace_fail_names) {
        # Mixture of errors and hits.  Highlight the hits.
        $self->message("hunt_for_Entry_text: I also saw some errors while searching.  Search for 'wibble' to highlight those.");
    }

    if (@matching_sub_names) {
        $self->highlight_by_name(@matching_sub_names);
    } else {
        $self->message("Can't find '$query_str'");
    }

    return;
}


sub ace_path {
    my( $self ) = @_;

    return $self->AceDatabase->home;
}

sub save_ace {
    my( $self, @args ) = @_;

    my $adb = $self->AceDatabase;

    my $val;
    eval { $val = $adb->ace_server->save_ace(@args) };
    if (my $err = $@) {
        $self->exception_message($err, "Error saving to acedb");
        confess "Error saving to acedb: $err";
    }
    else {
        if ($self->flag_db_edits) {
            $self->AceDatabase->unsaved_changes(1);
            $self->update_window_title_unsaved_flag(1);            
        }
        return $val;
    }
}

sub flag_db_edits {
    my ($self, $flag) = @_;
    
    if (defined $flag) {
        $self->{'_flag_db_edits'} = $flag ? 1 : 0;
    }
    return $self->{'_flag_db_edits'};
}

sub resync_with_db {
    my( $self ) = @_;


    unless ($self->close_all_edit_windows) {
        $self->message("All editor windows must be closed before a ReSync");
        return;
    }

    $self->canvas->Busy(
        -recurse => 0,
        );

    $self->empty_Assembly_cache;
    $self->empty_SubSeq_cache;
    $self->empty_Locus_cache;
    
    # Refetch transcripts from GFF cache
    $self->fetch_external_SubSeqs;

    # Redisplay
    $self->draw_subseq_list;

    $self->canvas->Unbusy;

    return;
}

sub max_seq_list_length {
    return 1000;
}

sub slice_name {
    my( $self ) = @_;
    return $self->{_slice_name} ||=
        $self->AceDatabase->slice_name;
}

sub edit_subsequences {
    my( $self, @sub_names ) = @_;

    my $retval = 1;
    
    @sub_names = $self->list_selected_subseq_names
        unless @sub_names;
    foreach my $sub_name (@sub_names) {
        # Just show the edit window if present
        next if $self->raise_subseq_edit_window($sub_name);

        # Get a copy of the subseq
        if (my $sub = $self->get_SubSeq($sub_name)) {
            my $edit = $sub->clone;
            $edit->otter_id($sub->otter_id);
            $edit->translation_otter_id($sub->translation_otter_id);
            $edit->is_archival($sub->is_archival);
            $edit->locus_level_errors($sub->locus_level_errors);

            $self->make_exoncanvas_edit_window($edit);
        } else {
            warn "Failed to get_SubSeq($sub_name)";
            $retval = 0;
        }
    }
    
    return $retval;
}

sub default_locus_prefix {
    my ( $self ) = @_;
    return $self->{_default_locus_prefix} ||=
        $self->_default_locus_prefix;
}

sub _default_locus_prefix {
    my ( $self ) = @_;
    my $client = $self->AceDatabase->Client;
    return $client->config_value('gene_type_prefix') || '';
}

sub edit_new_subsequence {
    my( $self ) = @_;

    my @sub_names = $self->list_selected_subseq_names;
    my $clip      = $self->get_clipboard_text || '';

    my( @subseq );
    foreach my $sn (@sub_names) {
        my $sub = $self->get_SubSeq($sn);
        push(@subseq, $sub);
    }

    my ($new);
    if (@subseq) {
        $new = Hum::Ace::SubSeq->new_from_subseq_list(@subseq);
    }
    else {
        # warn "CLIPBOARD: $clip\n";
        $new = Hum::Ace::SubSeq->new_from_clipboard_text($clip);
        unless ($new) {
            $self->message("Need a highlighted transcript or a coordinate on the clipboard to make SubSeq");
            return;
        }
        $new->clone_Sequence($self->Assembly->Sequence);
    }

    my ($region_name, $max) = $self->region_name_and_next_locus_number($new);

    my $prefix = $self->default_locus_prefix;
    my $loc_name = $prefix ? "$prefix:$region_name.$max" : "$region_name.$max";
    my $locus = $self->get_Locus($loc_name);
    $locus->gene_type_prefix($prefix);

    my $seq_name = "$loc_name-001";

    # Check we don't already have a sequence of this name
    if ($self->get_SubSeq($seq_name)) {
        # Should be impossible, I hope!
        $self->message("Tried to make new SubSequence name but already have SubSeq named '$seq_name'");
        return;
    }

    $new->name($seq_name);
    $new->Locus($locus);
    my $gm = $self->get_default_mutable_GeneMethod or confess "No default mutable GeneMethod";
    $new->GeneMethod($gm);
    # Need to initialise translation region for coding transcripts
    if ($gm->coding) {
        $new->translation_region($new->translation_region);
    }

    $self->add_SubSeq_and_paste_evidence($new, $clip);

    return;
}

sub region_name_and_next_locus_number {
    my ($self, $new) = @_;

    my $most_3prime = $new->strand == 1 ? $new->end : $new->start;

    my $assembly = $self->Assembly;
    # Check that our coordinate is not off the end of the assembly
    if ($most_3prime and ($most_3prime < 0 or $most_3prime > $assembly->Sequence->sequence_length)) {
        $most_3prime = undef;
    }
    my $region_name = $most_3prime
        ? $assembly->clone_name_overlapping($most_3prime)
        : $assembly->name;
    warn "Looking for clone overlapping '$most_3prime' found '$region_name'\n";

    # Trim sequence version from accession if clone_name ends .SV
    $region_name =~ s/\.\d+$//;

    # Now get the maximum locus number for this root
    my $regex = qr{^(?:[^:]+:)?$region_name\.(\d+)}; # qr is a Perl 5.6 feature
    my $max = 0;
    foreach my $sub ($assembly->get_all_SubSeqs) {
        my ($n) = $sub->name =~ /$regex/;
        if ($n and $n > $max) {
            $max = $n;
        }
    }
    $max++;

    return ($region_name, $max);
}

sub make_variant_subsequence {
    my( $self ) = @_;

    my $clip      = $self->get_clipboard_text || '';
    my @sub_names = $self->list_selected_subseq_names;
    unless (@sub_names) {
        @sub_names = $self->list_was_selected_subseq_names;
    }

    # warn "Got subseq names: (@sub_names)";
    unless (@sub_names) {
        $self->message("No subsequence selected");
        return;
    }
    elsif (@sub_names > 1) {
        $self->message("Can't make a variant from more than one selected sequence");
        return;
    }
    my $name = $sub_names[0];
    my $sub = $self->get_SubSeq($name);
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
            if ($n and $n > $max) {
                $max = $n;
            }
        }

        $var_name = sprintf "%s-%03d", $root, $max + 1;

        # Check we don't already have the variant we are trying to create
        if ($self->get_SubSeq($var_name)) {
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

    # Make the variant
    my $var = $sub->clone;
    $var->name($var_name);
    $var->empty_evidence_hash;
    $var->empty_remarks;
    $var->empty_annotation_remarks;
    my $locus = $var->Locus;

    if (text_is_zmap_clip($clip)) {
        my $clip_sub = Hum::Ace::SubSeq->new_from_clipboard_text($clip);
        $var->replace_all_Exons($clip_sub->get_all_Exons);
    }

    $self->add_SubSeq_and_paste_evidence($var, $clip);

    return;
}

sub add_SubSeq_and_paste_evidence {
    my ($self, $sub, $clip) = @_;

    $self->Assembly->add_SubSeq($sub);

    $self->add_SubSeq($sub);
    $self->draw_subseq_list;
    $self->highlight_by_name($sub->name);

    my $ec = $self->make_exoncanvas_edit_window($sub);
    $ec->merge_position_pairs;  # Useful if multiple overlapping evidence selected
    $ec->EvidencePaster->add_evidence_from_text($clip);

    return;
}

sub add_external_SubSeqs {
    my ($self, @ext_subs) = @_;

    # Subsequences from Zmap gff which are not in acedb database
    my $asm = $self->Assembly;
    my $dna = $asm->Sequence;
    foreach my $sub (@ext_subs) {
        if (my $ext = $self->get_SubSeq($sub->name)) {
            if ($ext->GeneMethod->name eq $sub->GeneMethod->name) {
                # Looks zmap has been restarted, which has
                # triggered a reload of this data.
                next;
            }
            else {
                confess sprintf "External transcript '%s' from '%s' has same name as transcript from '%s'\n",
                    $sub->name, $sub->GeneMethod->name, $ext->GeneMethod->name;
            }
        }
        $sub->clone_Sequence($dna);
        $asm->add_SubSeq($sub);
        $self->add_SubSeq($sub);
    }

    return;
}

sub fetch_external_SubSeqs {
    my ($self) = @_;
    
    my $sth = $self->AceDatabase->DB->dbh->prepare(
        q{ SELECT filter_name FROM otter_filter WHERE done = 1 AND process_gff = 1 }
        );
    $sth->execute;
    my $filter_hash = $self->AceDatabase->filters;
    while (my ($filter_name) = $sth->fetchrow) {
        my $filter = $filter_hash->{$filter_name}{'filter'};
        my @tsct = $self->AceDatabase->process_gff_file_from_Filter($filter);
        if (@tsct) {
            $self->add_external_SubSeqs(@tsct);
        }
    }

    return;
}

sub delete_subsequences {
    my( $self ) = @_;

    # Make a list of editable SubSeqs from those selected,
    # which we are therefore allowed to delete.
    my @sub_names = $self->list_selected_subseq_names;
    my( @to_die );
    foreach my $sub_name (@sub_names) {
        my $sub = $self->get_SubSeq($sub_name);
        if ($sub->GeneMethod->mutable) {
            push(@to_die, $sub);
        }
    }
    return unless @to_die;

    # Check that none of the sequences to be deleted are being edited
    my $in_edit = 0;
    foreach my $sub (@to_die) {
        $in_edit += $self->raise_subseq_edit_window($sub->name);
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
        -title          => 'otter: Delete Transcripts?',
        -bitmap         => 'question',
        -text           => $question,
        -default_button => 'Yes',
        -buttons        => [qw{ Yes No }],
        );
    my $ans = $dialog->Show;

    return if $ans eq 'No';

    # Make ace delete command for subsequences
    my $offset = $self->AceDatabase->offset;
    my $ace = '';
    my @xml;
    foreach my $sub (@to_die) {
        # Only attempt to delete sequences which have been saved
        if ($sub->is_archival) {
            my $sub_name   = $sub->name;
            my $clone_name = $sub->clone_Sequence->name;
            $ace .= qq{\n\-D Sequence "$sub_name"\n}
                . qq{\nSequence "$clone_name"\n}
                . qq{-D Subsequence "$sub_name"\n};
            push @xml, $sub->zmap_delete_xml_string($offset);
        }
    }

    # Delete from acedb database and Zmap
    $self->save_ace($ace);
    $self->zMapSendCommands(@xml);

    # Remove from our objects
    foreach my $sub (@to_die) {
        $self->delete_SubSeq($sub);
    }

    $self->draw_subseq_list;

    return;
}

sub make_exoncanvas_edit_window {
    my( $self, $sub ) = @_;

    my $sub_name = $sub->name;
    my $canvas = $self->canvas;

    # Make a new window
    my $top = $canvas->Toplevel;

    # Make new MenuCanvasWindow::ExonCanvas object and initialize
    my $ec = MenuCanvasWindow::ExonCanvas->new($top, 345, 50);
    $ec->name($sub_name);
    $ec->XaceSeqChooser($self);
    $ec->SubSeq($sub);
    $ec->initialize;

    $self->save_subseq_edit_window($sub_name, $ec);

    return $ec;
}

sub raise_subseq_edit_window {
    my( $self, $name ) = @_;

    confess "no name given" unless $name;

    if (my $ec = $self->get_subseq_edit_window($name)) {
        my $top = $ec->canvas->toplevel;
        $top->deiconify;
        $top->raise;
        return 1;
    } else {
        return 0;
    }
}

sub get_subseq_edit_window {
    my( $self, $name ) = @_;

    return $self->{'_subseq_edit_window'}{$name};
}

sub list_all_subseq_edit_window_names {
    my( $self ) = @_;

    return keys %{$self->{'_subseq_edit_window'}};
}

sub save_subseq_edit_window {
    my( $self, $name, $ec ) = @_;

    $self->{'_subseq_edit_window'}{$name} = $ec;
    weaken($self->{'_subseq_edit_window'}{$name});

    return;
}

sub delete_subseq_edit_window {
    my( $self, $name ) = @_;

    delete($self->{'_subseq_edit_window'}{$name});

    return;
}

sub rename_subseq_edit_window {
    my( $self, $old_name, $new_name ) = @_;

    my $win = $self->get_subseq_edit_window($old_name)
        or return;
    $self->delete_subseq_edit_window($old_name);
    $self->save_subseq_edit_window($new_name, $win);

    return;
}

sub close_all_subseq_edit_windows {
    my( $self ) = @_;

    foreach my $name ($self->list_all_subseq_edit_window_names) {
        my $ec = $self->get_subseq_edit_window($name) or next;
        $ec->window_close or return 0;
    }

    return 1;
}

sub draw_subseq_list {
    my( $self ) = @_;

    my $canvas = $self->canvas;

    my $slist = [];
    my $counter = 1;
    foreach my $clust ($self->get_all_Subseq_clusters) {
        push(@$slist, "") if @$slist;
        push(@$slist, @$clust);
    }

    $self->draw_sequence_list($slist);
    $self->fix_window_min_max_sizes;

    return;
}

sub get_all_Subseq_clusters {
    my( $self ) = @_;

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
            and $this->start <= $y
            and $this->end   >= $x)
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

sub save_Clone {
    my ($self, $clone) = @_;

    my $ace = $clone->ace_string;
    $self->save_ace($ace);
    $self->Assembly->replace_Clone($clone);

    return;
}

sub edit_Clone {
    my ($self, $clone) = @_;

    my $name = $clone->name;

    # show Clone EditWindow
    my $cew;
    unless ($cew = $self->{'_clone_edit_window'}{$name}) {
        $cew = EditWindow::Clone->new($self->top_window->Toplevel(
            -title => sprintf("otter: Clone %s", $clone->clone_name),
            ));
        $cew->XaceSeqChooser($self);
        $cew->Clone($clone);
        $cew->initialise;
        $self->{'_clone_edit_window'}{$name} = $cew;
        weaken($self->{'_clone_edit_window'}{$name});
    }
    my $top = $cew->top;
    $top->deiconify;
    $top->raise;

    return;
}

sub edit_Clone_by_name {
    my ($self, $name) = @_;

    my $clone = $self->Assembly->get_Clone($name);
    $self->edit_Clone($clone);

    return;
}

sub edit_Clone_by_accession_version {
    my ($self, $accession_version) = @_;

    my $clone = $self->Assembly->get_Clone_by_accession_version($accession_version);
    $self->edit_Clone($clone);

    return;
}

sub close_all_clone_edit_windows {
    my ($self) = @_;

    if (my $cew_hash = $self->{'_clone_edit_window'}) {
        foreach my $win (values %$cew_hash) {
            next unless $win;   # Already closed
            $win->close_window or return;
        }
    }

    return 1;
}

sub Assembly {
    my( $self ) = @_;

    my $canvas = $self->canvas;
    my $slice_name = $self->slice_name;
    my $ace  = $self->AceDatabase->aceperl_db_handle;

    unless ($self->{'_assembly'}) {
        my $before = time();
        $canvas->Busy(
            -recurse => 0,
            );

        my( $assembly );
        eval {
            $assembly = Hum::Ace::Assembly->new;
            $assembly->name($slice_name);
            $assembly->MethodCollection($self->AceDatabase->MethodCollection);
            $assembly->express_data_fetch($ace);
        };
        if ($@) {
            $self->exception_message($@, "Can't fetch Assembly '$slice_name'");
            return;
        }

        foreach my $sub ($assembly->get_all_SubSeqs) {
            $self->add_SubSeq($sub);

            # Ignore loci from non-editable SubSeqs
            next unless $sub->is_mutable;
            if (my $s_loc = $sub->Locus) {
                my $locus = $self->get_Locus($s_loc);
                $sub->Locus($locus);
            }
        }

        $self->{'_assembly'} = $assembly;
        $self->set_known_GeneMethods;

        my $after  = time();
        $canvas->Unbusy;
        printf
            "Express fetch for '%s' took %d second(s)\n",
            $self->slice_name, $after - $before;
    }
    return $self->{'_assembly'};
}

sub save_Assembly {
    my( $self, $new ) = @_;

    my @xml = Bio::Otter::ZMap::XML::update_SimpleFeatures_xml(
        $self->Assembly, $new, $self->AceDatabase->offset);
    $self->zMapSendCommands(@xml);
    my $ace = $new->ace_string;
    $self->save_ace($ace);
    $self->Assembly->set_SimpleFeature_list($new->get_all_SimpleFeatures);

    return;
}

sub empty_Assembly_cache {
    my( $self ) = @_;

    $self->{'_assembly'} = undef;

    return;
}

sub delete_featuresets {
    my( $self, @types ) = @_;

    my $name = $self->Assembly->Sequence->name;
    my $ace = sprintf qq{\nSequence : "%s"\n}, $name;

    foreach my $type ( @types ) {
        $ace .= qq{-D Homol ${type}_homol\n};

        # we delete types seperately because zmap errors out without
        # deleting anything if any featureset does not currently exist
        # in the zmap window

        $self->zMapDeleteFeaturesets($type);
    }

    $self->save_ace($ace);

    return;
}

sub replace_SubSeq {
    my( $self, $new, $old ) = @_;

    my $new_name = $new->name;
    my $old_name = $old->name || $new_name;

    my $rename_needed = $old->is_archival && $new_name ne $old_name;
    my $ace = $rename_needed
        ? $new->ace_string($old_name)
        : $new->ace_string;
    $self->save_ace($ace);

    my $offset = $self->AceDatabase->offset;
    $self->zMapSendCommands(
        ( $old->is_archival ? $old->zmap_delete_xml_string($offset) : () ),
        $new->zmap_create_xml_string($offset),
        );

    $self->Assembly->replace_SubSeq($new, $old_name);
    if ($new_name ne $old_name) {
        $self->{'_subsequence_cache'}{$old_name} = undef;
        $self->rename_subseq_edit_window($old_name, $new_name);
    }
    $self->{'_subsequence_cache'}{$new_name} = $new;

    my $locus = $new->Locus;
    if (my $prev_name = $locus->drop_previous_name) {
        warn "Unsetting otter_id for locus '$prev_name'\n";
        $self->get_Locus($prev_name)->drop_otter_id;
    }
    $self->set_Locus($locus);

    ### Update all subseq edit windows
    $self->draw_subseq_list;

    return;
}

sub add_SubSeq {
    my( $self, $sub ) = @_;

    my $name = $sub->name;
    if ($self->{'_subsequence_cache'}{$name}) {
        confess "already have SubSeq '$name'";
    } else {
        $self->{'_subsequence_cache'}{$name} = $sub;
    }

    return;
}

sub delete_SubSeq {
    my( $self, $sub ) = @_;

    my $name = $sub->name;
    $self->Assembly->delete_SubSeq($name);

    if ($self->{'_subsequence_cache'}{$name}) {
        $self->{'_subsequence_cache'}{$name} = undef;
        return 1;
    } else {
        return 0;
    }
}

sub get_SubSeq {
    my( $self, $name ) = @_;

    confess "no name given" unless $name;
    return $self->{'_subsequence_cache'}{$name};
}

sub list_all_SubSeq_names {
    my ($self) = @_;

    if (my $sub_hash = $self->{'_subsequence_cache'}) {
        return keys %$sub_hash;
    } else {
        return;
    }
}

sub empty_SubSeq_cache {
    my( $self ) = @_;

    $self->{'_subsequence_cache'} = undef;

    return;
}

sub row_count {
    my( $self, $slist ) = @_;

    # Work out number of rows to keep chooser
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

sub update_SubSeq_locus_level_errors {
    my ($self) = @_;
    
    $self->Assembly->set_SubSeq_locus_level_errors;
    foreach my $sub_name ($self->list_all_subseq_edit_window_names) {
        my $ec = $self->get_subseq_edit_window($sub_name) or next;
        my $sub = $self->get_SubSeq($sub_name) or next;
        $ec->SubSeq->locus_level_errors($sub->locus_level_errors);
    }

    return;
}

sub launch_exonerate {
    my( $self, $seqs, $params ) = @_;

    # lower case query polyA/T tails to avoid spurious exons
    for my $seq (@$seqs) {
        my $s = $seq->uppercase;
        $s =~ s/(^T{6,}|A{6,}$)/lc($1)/ge;
        $seq->sequence_string($s);
    }

    # save seqs in hash
    my $name_seq = { };
    for my $seq (@$seqs) {
        $name_seq->{ $seq->name } = $seq;
    }

    my %seqs_by_type = ();

    for my $seq (@$seqs) {
        if ($seq->type && new_evidence_type_valid($seq->type))
        {
            push @{ $seqs_by_type{ $seq->type } }, $seq;
        }
        elsif ($seq->sequence_string =~ /^[AGCTNagctn\s]*$/) {
            push @{ $seqs_by_type{'Unknown_DNA'} }, $seq;
        }
        else {
            push @{ $seqs_by_type{'Unknown_Protein'} }, $seq;
        }
    }

    # get marked region (if requested)
    my ($genomic_start, $genomic_end) =
        (1, $self->Assembly->Sequence->sequence_length);
    if ($params->{-use_marked_region}) {
        my ($mark_start, $mark_end) = $self->zMapGetMark;
        if ($mark_start && $mark_end) {
            warn "Setting exonerate genomic start & end to marked region: $mark_start - $mark_end\n";
            ($genomic_start, $genomic_end) = ($mark_start, $mark_end);
        }
    }

    my $db_edited = 0;
    my @method_names;
    my $ace_text = '';
    my $best_n   = $params->{-best_n};
    my $max_intron_length = $params->{-max_intron_length};
    my $mask_target = $params->{-mask_target};

    for my $type (keys %seqs_by_type) {

        print STDERR "Running exonerate for sequence(s) of type: $type\n";

        my $score    = $type =~ /Protein/  ? $PROT_SCORE : $DNA_SCORE;
        my $ana_name = $type =~ /^Unknown/ ? $type       :
            $type eq 'cDNA' ? "OTF_mRNA" : "OTF_$type";
        my $dnahsp   = $DNAHSP;

        my $exonerate = Bio::Otter::Lace::Exonerate->new;
        $exonerate->AceDatabase($self->AceDatabase);
        $exonerate->genomic_seq($self->Assembly->Sequence);
        $exonerate->genomic_start($genomic_start);
        $exonerate->genomic_end($genomic_end);
        $exonerate->query_seq($seqs_by_type{$type});
        $exonerate->sequence_fetcher($name_seq);
        $exonerate->acedb_homol_tag($ana_name . '_homol');
        $exonerate->query_type($type =~ /Protein/ ? 'protein' : 'dna');
        $exonerate->score($score);
        $exonerate->dnahsp($dnahsp);
        $exonerate->bestn($best_n);
        $exonerate->mask_target($mask_target);
        $exonerate->max_intron_length($max_intron_length);
        $exonerate->method_tag($ana_name);
        $exonerate->logic_name($ana_name);

        my $seq_file = $exonerate->write_seq_file();

        if ($seq_file) {
            $exonerate->initialise($seq_file);
            my $ace_output = $exonerate->run;

            # delete query file
            unlink $seq_file;

            if ($ace_output) {
                $db_edited = 1;
            }
            else {
                next;
            }

            # add hit sequences into ace text
            my $names = $exonerate->delete_all_hit_names;

            # only add the sequence to acedb if they are not pfetchable (i.e. they are unknown)
            if ($type =~ /^Unknown/) {
                foreach my $hit_name (@$names) {
                    my $seq = $name_seq->{$hit_name};

                    if ($exonerate->query_type eq 'protein') {
                        $ace_output .= $self->ace_PEPTIDE($hit_name, $seq);
                    }
                    else {
                        $ace_output .= $self->ace_DNA($hit_name, $seq);
                    }
                }
            }

            # Need to add new method to collection if we don't have it already
            my $coll      = $exonerate->AceDatabase->MethodCollection;
            my $coll_zmap = $self->Assembly->MethodCollection;
            my $method    = $exonerate->ace_Method;
            push @method_names, $method->name;
            unless ($coll->get_Method_by_name($method->name)
                || $coll_zmap->get_Method_by_name($method->name))
            {
                $coll->add_Method($method);
                $coll_zmap->add_Method($method);
                $self->save_ace($coll->ace_string());
            }
            $ace_text .= $ace_output;
        }
    }

    $self->save_ace($ace_text);

    $self->zMapLoadFeatures(@method_names) if $db_edited;

    return $db_edited;
}

sub ace_DNA {
    my ($self, $name, $seq) = @_;

    my $ace = qq{\nSequence "$name"\n\nDNA "$name"\n};

    my $dna_string = $seq->sequence_string;

    while ($dna_string =~ /(.{1,60})/g) {
        $ace .= $1 . "\n";
    }

    return $ace;
}

sub ace_PEPTIDE {
    my ($self, $name, $seq) = @_;

    my $ace = qq{\nProtein "$name"\n\nPEPTIDE "$name"\n};

    my $prot_string = $seq->sequence_string;
    while ($prot_string =~ /(.{1,60})/g) {
        $ace .= $1 . "\n";
    }
    return $ace;
}

sub draw_sequence_list {
    my( $self, $slist ) = @_;

    $self->update_SubSeq_locus_level_errors;

    my $canvas = $self->canvas;
    my $size = $self->font_size;
    my $pad  = int($size / 6);
    my $half = int($size / 2);

    my $rows = $self->row_count($slist);

    # Delete everything apart from messages
    $canvas->delete('!msg');

    my $x = 0;
    my $y = 0;
    my $err_hash = {};
    my $locus_type_pattern;
    if (my $pre = $self->default_locus_prefix) {
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
                eval{ $error = $sub->pre_otter_save_error };
                $error = $@ ? $@ : $error;
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
                -font       => $style eq 'bold' ? $self->font_fixed_bold : $self->font_fixed,
                -tags       => ['subseq', 'searchable'],
                -fill       => $color,
                );
            if ($error) {
                $error =~ s/\n$//;
                $Text::Wrap::columns = 60; ## no critic(Variables::ProhibitPackageVars)
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
        # $balloon->detatch($canvas);
        $self->balloon->attach($canvas,
            -balloonposition => 'mouse',
            -msg => $err_hash,
            );
    }

    # Raise messages above everything else
    eval{
        $canvas->raise('msg', 'subseq');
    };

    return;
}

sub highlight_by_name {
    my( $self, @names ) = @_;

    $self->highlight($self->subseq_names_to_canvas_obj(@names));

    return;
}

sub highlight_by_name_without_owning_clipboard {
    my ($self, @names) = @_;

    if (my @obj_list = $self->subseq_names_to_canvas_obj(@names)) {
        $self->CanvasWindow::highlight(@obj_list);
    }

    return;
}

sub subseq_names_to_canvas_obj {
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

sub canvas_obj_to_subseq_names {
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
    my( $self ) = @_;

    return $self->canvas_obj_to_subseq_names($self->list_selected);
}

sub list_was_selected_subseq_names {
    my( $self ) = @_;

    return $self->canvas_obj_to_subseq_names($self->list_was_selected);
}

sub rename_locus {
    my ($self, $locus_name) = @_;

    warn "Renaming locus";

    unless ($self->close_all_subseq_edit_windows) {
        $self->message('Must close all clone editing windows before renaming locus');
        return;
    }

    if (my $ren_window = $self->{'_locus_rename_window'}) {
        $ren_window->top->destroy;
    }
    my $parent = $self->top_window;
    my $top = $parent->Toplevel(-title => 'otter: Rename Locus');
    $top->transient($parent);
    my $lr = EditWindow::LocusName->new($top);
    $lr->XaceSeqChooser($self);
    $lr->locus_name_arg($locus_name);
    $lr->initialise;
    $self->{'_locus_rename_window'} = $lr;
    weaken($self->{'_locus_rename_window'});

    return 1;
}

sub run_dotter {
    my( $self ) = @_;

    my $dw = $self->{'_dotter_window'};
    unless ($dw) {
        my $parent = $self->top_window();
        my $top = $parent->Toplevel(-title => 'otter: Run Dotter');
        $top->transient($parent);
        $dw = EditWindow::Dotter->new($top);
        $dw->initialise;
        $dw->XaceSeqChooser($self);
        $self->{'_dotter_window'} = $dw;
    }
    $dw->update_from_XaceSeqChooser($self);

    return 1;
}

sub run_exonerate {
    my( $self ) = @_;

    my $ew = $self->{'_exonerate_window'};
    unless ($ew) {
        my $parent = $self->top_window();
        my $top = $parent->Toplevel(
            -title => 'otter: On The Fly (OTF) Alignment'
            );
        $top->transient($parent);
        $ew = EditWindow::Exonerate->new($top);
        $ew->XaceSeqChooser($self);
        $ew->initialise();
        $self->{'_exonerate_window'} = $ew;
        weaken($self->{'_exonerate_window'});
    }
    $ew->update_from_XaceSeqChooser;

    return 1;
}

sub set_window_title {
    my ($self) = @_;
    
    my $name = $self->AceDatabase->name;
    my $unsaved_str = $self->AceDatabase->unsaved_changes ? '* ' : '';
    my $title = "${unsaved_str}otter: Session $name";
    $self->top_window->title($title);

    return;
}

sub update_window_title_unsaved_flag {
    my ($self, $flag) = @_;
    
    my $top = $self->top_window;
    my $title = $top->title;
    $title =~ s/^\* //;
    my $unsaved_str = $flag ? '* ' : '';
    $top->title("${unsaved_str}$title");

    return;
}

sub DESTROY {
    my( $self ) = @_;

    warn "Destroying XaceSeqChooser for ", $self->ace_path, "\n";

    $self->zMapKillZmap;
    $self->drop_AceDatabase;

    return;
}

1;

__END__

=head1 NAME - MenuCanvasWindow::XaceSeqChooser

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

