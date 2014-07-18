
package MenuCanvasWindow::SessionWindow;

use strict;
use warnings;

use Carp;
use Scalar::Util 'weaken';

use Try::Tiny;
use File::Path (); # for make_path;

require Tk::Dialog;
require Tk::Balloon;

use Hum::Ace::SubSeq;
use Bio::Otter::ZMap::XML::SubSeq;
use Hum::Ace::Locus;
use Hum::Ace::Assembly;
use Hum::Analysis::Factory::ExonLocator;
use Hum::Sort qw{ ace_sort };
use Hum::ClipboardUtils qw{ text_is_zmap_clip };
use Hum::XmlWriter;

use EditWindow::Dotter;
use EditWindow::Exonerate;
use EditWindow::Clone;
use EditWindow::LocusName;
use MenuCanvasWindow::TranscriptWindow;
use MenuCanvasWindow::GenomicFeaturesWindow;
use Text::Wrap qw{ wrap };

use Zircon::Tk::Context;
use Zircon::ZMap;

use Bio::Otter::Lace::Client;
use Bio::Otter::Log::WithContext;
use Bio::Otter::RequestQueuer;
use Bio::Otter::ZMap::XML;
use Bio::Vega::Transform::Otter::Ace;

use Tk::Screens;
use Tk::ScopedBusy;
use Bio::Vega::Utils::MacProxyConfig qw{ mac_os_x_set_proxy_vars };

use base qw{
    MenuCanvasWindow
    Bio::Otter::UI::ZMapSelectMixin
    };

my $PROT_SCORE = 100;
my $DNA_SCORE  = 100;
my $DNAHSP     = 120;

sub new {
    my ($pkg, $tk) = @_;

    my $self = $pkg->SUPER::new($tk);

    $self->zmap_select_initialize;

    $self->populate_menus;
    $self->make_search_panel;
    $self->bind_events;
    $self->minimum_scroll_bbox(0,0, 380,200);
    $self->flag_db_edits(1);

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

    $self->set_window_title;
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
    $self->fetch_external_SubSeqs;
    $self->populate_clone_menu;
    # Drawing the sequence list can take a long time the first time it is
    # called (QC checks not yet cached), so do it before zmap is launched.
    $self->draw_subseq_list;

    $self->AceDatabase->zmap_dir_init;
    $self->_zmap_view_new($self->{'_zmap'});
    delete $self->{'_zmap'};

    $self->RequestQueuer(Bio::Otter::RequestQueuer->new($self));

    return;
}

sub session_colour {
    my ($self) = @_;
    return $self->AceDatabase->colour || '#d9d9d9';
    # The non-coloured default would be '#d9d9d9'.  Using undef causes
    # non-drawing.  For a complete no-op, don't set any borderwidth
}

sub _colour_init {
    my ($self) = @_;
    return $self->colour_init($self->top_window, 'search_frame', 'search_frame.filler');
}

# called by various windows, to set their widgets to our session_colour
sub colour_init {
    my ($self, $top, @widg) = @_;
    my $colour = $self->session_colour;
    my $tpath = $top->PathName;
    $top->configure(-borderwidth => 3, -background => $colour);
    foreach my $widg (@widg) {
        $widg = $top->Widget("$tpath.$widg") unless ref($widg);
        next unless $widg; # TranscriptWindow has some PathName parts
        $widg->configure(-background => $colour);
    }
    return;
}

sub logger {
    my ($self, $category) = @_;
    $category = scalar caller unless defined $category;

    my $acedb = $self->AceDatabase;
    return Bio::Otter::Log::WithContext->get_logger($category, '-no-acedb-') unless $acedb;

    return $acedb->logger($category);
}

sub clone_menu {
    my ($self, $clone_menu) = @_;

    if ($clone_menu) {
        $self->{'_clone_menu'} = $clone_menu;
    }
    return $self->{'_clone_menu'};
}

sub balloon {
    my ($self) = @_;

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
    my ($self, $name) = @_;

    my( $meth );
    unless ($meth = $self->{'_gene_methods'}{$name}) {
        $self->logger->logconfess("No such Method '$name'");
    }
    return $meth;
}

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

sub get_Locus {
    my ($self, $name) = @_;

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
    my ($self, $locus) = @_;

    my $name = $locus->name;
    $self->{'_locus_cache'}{$name} = $locus;

    return;
}

sub get_all_Loci {
    my ($self) = @_;
    my $lc = $self->{'_locus_cache'};
    return values %$lc;
}

sub list_Locus_names {
    my ($self) = @_;
    my @names = sort {lc $a cmp lc $b} map { $_->name } $self->get_all_Loci;
    return @names;
}

sub empty_Locus_cache {
    my ($self) = @_;

    $self->{'_locus_cache'} = undef;

    return;
}

sub update_Locus {
    my ($self, $new_locus) = @_;

    my $locus_name = $new_locus->name;

    $self->set_Locus($new_locus);

    foreach my $sub_name ($self->list_all_SubSeq_names) {
        my $sub = $self->get_SubSeq($sub_name) or next;
        my $old_locus = $sub->Locus or next;

        if ($old_locus->name eq $locus_name) {
            # Replace locus in subseq with new copy
            $sub->Locus($new_locus);

            # Is there a transcript window open?
            if (my $transcript_window = $self->get_transcript_window($sub_name)) {
                $transcript_window->update_Locus($new_locus);
            }
        }
    }

    return;
}

sub do_rename_locus {
    my ($self, $old_name, $new_name) = @_;

    my %done; # we update in three places - keep track
    return try {
        my @delete_xml;
        my $offset = $self->AceDatabase->offset;
        foreach my $sub ($self->fetch_SubSeqs_by_locus_name($old_name)) {
            push @delete_xml, $sub->zmap_delete_xml_string($offset);
        }

        my $locus_cache = $self->{'_locus_cache'}
            or confess "Did not get locus cache";

        if ($locus_cache->{$new_name}) {
            $self->message("Cannot rename to '$new_name'; Locus already exists");
            return 0;
        }

        my $locus = delete $locus_cache->{$old_name};
        if (!$locus) {
            $self->message("Cannot find locus called '$old_name'");
            return 0;
        }

        $locus->name($new_name);
        $self->set_Locus($locus);
        $done{'int'} = 1;

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

        # Now we need to update ZMap with the new locus names
        my @create_xml;
        foreach my $sub ($self->fetch_SubSeqs_by_locus_name($new_name)) {
            push @create_xml, $sub->zmap_create_xml_string($offset);
        }

        $self->save_ace($ace);
        $done{'ace'} = 1;

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
        if ($done{'ace'}) {
            # haven't told ZMap, reload it from Ace
            $msg = "Renamed OK but sync failed, please restart ZMap";
        } elsif ($done{'int'}) {
            # haven't told Ace, so Otterlace state is wrong
            $msg = "Rename failed, please restart Otterlace";
        } else {
            $msg = "Could not rename";
        }
        $self->exception_message($err, "$msg\nwhile renaming locus '$old_name' to '$new_name'");
        return -1;
    }
}

sub fetch_SubSeqs_by_locus_name {
   my ($self, $locus_name) = @_;

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

sub populate_menus {
    my ($self) = @_;

    my $top = $self->top_window;

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

    # Debug options: get (current!) session directory name
    my $debug_menu = $file->Menu(-tearoff => 0);
    $file->add('cascade', -menu => $debug_menu,
               -label => 'Debug', -underline => 0);
    $debug_menu->add('command',
                     -label => 'Copy directory name to selection',
                     -underline => 5,
                     -command => sub { $self->_clipboard_setup(0) });
    $debug_menu->add('command',
                     -label => 'Copy host:directory to selection',
                     -underline => 5,
                     -command => sub { $self->_clipboard_setup(1) });

    # Close window
    my $exit_command = sub {
        $self->exit_save_data or return;
        $self->ColumnChooser->top_window->destroy;
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
        $self->edit_selected_subsequences;
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
        $self->close_all_transcript_windows;
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
        try { $self->paste_selected_subseqs; }
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

    # Make a variant of the current selected sequence
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

    # Genomic Features editing window
    my $gf_command = sub { $self->launch_GenomicFeaturesWindow };
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
               -command        => sub {$self->show_column_chooser()},
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
    my $show_subseq = [ $self, 'show_subseq' ];
    $tools_menu->add
      ('command',
       -label          => 'Hunt in ZMap',
       -command        => $show_subseq,
       -accelerator    => 'Ctrl+H',
       -underline      => 0,
      );
    $top->bind('<Control-h>',   $show_subseq);
    $top->bind('<Control-H>',   $show_subseq);

    $subseq->bind('<Destroy>', sub{
        $self = undef;
    });

    return;
}

sub ColumnChooser {
    my ($self, $lc) = @_;

    $self->{'_ColumnChooser'} = $lc if $lc;

    return $self->{'_ColumnChooser'};
}

sub show_column_chooser {
    my ($self) = @_;

    my $cc = $self->ColumnChooser;
    my $top = $cc->top_window;
    $top->deiconify;
    $top->raise;

    return;
}

sub show_subseq {
    my ($self) = @_;

    my @subseq = $self->list_selected_subseq_objs;
    if (1 == @subseq) {
        my $success = $self->zmap->zoom_to_subseq($subseq[0]);
        $self->message("ZMap: zoom to subsequence failed") unless $success;
    } else {
        $self->message("Zoom to subsequence requires a selection of one item");
    }

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
    my ($self) = @_;

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
    my ($self, @args) = @_;

    $self->SUPER::highlight(@args);

    my $canvas = $self->canvas;
    $canvas->SelectionOwn(
        -command    => sub{ $self->deselect_all; },
    );
    weaken $self;

    return;
}

sub GenomicFeaturesWindow {
    my ($self) = @_;
    return $self->{'_gfs'}; # set in launch_GenomicFeaturesWindow
}

sub launch_GenomicFeaturesWindow {
    my ($self) = @_;
    try {
        my $gfs = MenuCanvasWindow::GenomicFeaturesWindow->in_Toplevel
          (# -title is set during initialise
           { reuse_ref => \$self->{'_gfs'},
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

sub close_GenomicFeaturesWindow {
    my ($self) = @_;

    if(my $gfs = $self->GenomicFeaturesWindow()) {
        $gfs->try2save_and_quit();
    }

    return;
}

{
    my( @holding_pen );

    sub copy_selected_subseqs {
        my ($self) = @_;

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
                for (my $i=0; !defined $temp_name || $self->get_SubSeq($temp_name); $i++) {
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
                $self->add_SubSeq($new);
                push(@new_subseq, $new);
                print STDERR "Internal paste result:\n", $new->ace_string;
            } else {
                $self->message("Got zero exons from realigning '$name'");
            }
        }
        $self->draw_subseq_list;
        $self->highlight_by_name(map { $_->name } @new_subseq);
        $self->message(@msg) if @msg;
        foreach my $new (@new_subseq) {
            $self->make_transcript_window($new);
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
    return $self->get_Locus($dup_locus);
}


sub exit_save_data {
    my ($self) = @_;

    my $adb = $self->AceDatabase;
    my $dir = $self->ace_path;
    unless ($adb->write_access) {
        $adb->error_flag(0);
        $self->close_GenomicFeaturesWindow;   ### Why is this special?
        my $changed = $self->AceDatabase->unsaved_changes;
        $changed = 'not set' unless defined $changed;
        $self->logger->info("Closing $dir (no write access, changed = $changed)");
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
            -title          => $Bio::Otter::Lace::Client::PFX.'Annotation complete?',
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

            try { $self->save_ace($ace); return 1; }
            catch  { $self->logger->error("Aborting lace session exit:\n$_"); return 0; }
            or return;

            if ($self->save_data) {
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
            $self->save_data or return;
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

sub close_all_edit_windows {
    my ($self) = @_;

    $self->close_all_transcript_windows or return;
    $self->close_all_clone_edit_windows or return;
    $self->close_GenomicFeaturesWindow;
    return 1;
}

sub save_data {
    my ($self) = @_;

    my $adb = $self->AceDatabase;

    unless ($adb->write_access) {
        $self->logger->info("Read only session - not saving");
        return 1;   # Can't save - but is OK
    }
    my $top = $self->top_window();

    $top->Busy;

    return try {
        my $xml = $adb->Client->save_otter_xml(
            $adb->generate_XML_from_acedb, $adb->DataSet->name);
        die "save_otter_xml returned no XML" unless $xml;
        my $parser = Bio::Vega::Transform::Otter::Ace->new;
        $parser->parse($xml);
        my $ace_data = $parser->make_ace_genes_transcripts;
        $adb->unsaved_changes(0);
        $self->flag_db_edits(0);    # or the save_ace() will set unsaved_changes back to "1"
        $self->save_ace($ace_data);
        $self->flag_db_edits(1);
        $self->resync_with_db;
        $self->set_window_title;
        return 1;
    }
    catch { $self->exception_message($_, 'Error saving to otter'); return 0; }
    finally { $top->Unbusy; };
}

sub edit_double_clicked {
    my ($self) = @_;

    return unless $self->list_selected;

    $self->edit_selected_subsequences;

    return;
}

sub left_button_handler {
    my ($self, $canvas, $x, $y) = @_;

    return if $self->delete_message;

    $self->deselect_all;
    if (my ($obj) = $canvas->find('withtag', 'current')) {
        $self->highlight($obj);
    }

    return;
}

sub shift_left_button_handler {
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

sub make_search_panel {
    my ($self) = @_;

    my $top = $self->top_window();
    my $search_frame = $top->Frame(Name => 'search_frame');

    $search_frame->pack(-side => 'top');

    my $search_box = $search_frame->Entry(
        -width => 22,
        );
    $search_box->pack(-side => 'left');

    $search_frame->Frame(Name => 'filler', -width => 6)->pack(-side => 'left');

    # Is hunting in CanvasWindow?
    my $hunter = sub{
        my $busy = Tk::ScopedBusy->new($top);
        $self->_do_search($search_box);
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
    foreach my $name ($self->list_all_SubSeq_names) {
        my $sub = $self->get_SubSeq($name) or next;
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
        $self->highlight_by_name(@matching_sub_names);
        # also report any errors
        if (@ace_fail_names) {
            $self->message("Search: I also saw some errors while searching.  Search for 'wibble' to highlight those.");
        }
    }
    elsif (@ace_fail_names) {
        # highlight the errors
        $self->highlight_by_name(@ace_fail_names);
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

sub ace_path {
    my ($self) = @_;

    return $self->AceDatabase->home;
}

sub save_ace {
    my ($self, @args) = @_;

    my $adb = $self->AceDatabase;

    my $val;
    try { $val = $adb->ace_server->save_ace(@args); }
    catch {
        $self->exception_message($_, "Error saving to acedb");
        $self->logger->logconfess("Error saving to acedb: $_");
    };

    if ($self->flag_db_edits) {
        $self->AceDatabase->unsaved_changes(1);
        $self->set_window_title;
    }

    return $val;
}

sub flag_db_edits {
    my ($self, $flag) = @_;

    if (defined $flag) {
        $self->{'_flag_db_edits'} = $flag ? 1 : 0;
    }
    return $self->{'_flag_db_edits'};
}

sub resync_with_db {
    my ($self) = @_;


    unless ($self->close_all_edit_windows) {
        $self->message("All editor windows must be closed before a ReSync");
        return;
    }

    my $busy = Tk::ScopedBusy->new($self->canvas, -recurse => 0);

    $self->empty_Assembly_cache;
    $self->empty_SubSeq_cache;
    $self->empty_Locus_cache;

    # Refetch transcripts
    $self->Assembly;
    $self->fetch_external_SubSeqs;

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


sub max_seq_list_length {
    return 1000;
}

sub slice_name {
    my ($self) = @_;
    return $self->{_slice_name} ||=
        $self->AceDatabase->slice_name;
}

sub edit_selected_subsequences {
    my ($self) = @_;
    $self->edit_subsequences($self->list_selected_subseq_names);
    return;
}

sub edit_subsequences {
    my ($self, @sub_names) = @_;

    my $busy = Tk::ScopedBusy->new($self->canvas);
    my $retval = 1;

    foreach my $sub_name (@sub_names) {
        # Just show the edit window if present
        next if $self->raise_transcript_window($sub_name);

        # Get a copy of the subseq
        if (my $sub = $self->get_SubSeq($sub_name)) {
            my $edit = $sub->clone;
            $edit->otter_id($sub->otter_id);
            $edit->translation_otter_id($sub->translation_otter_id);
            $edit->is_archival($sub->is_archival);
            $edit->locus_level_errors($sub->locus_level_errors);

            $self->make_transcript_window($edit);
        } else {
            $self->logger->warn("Failed to get_SubSeq($sub_name)");
            $retval = 0;
        }
    }

    return $retval;
}

sub default_locus_prefix {
    my ($self) = @_;
    return $self->{_default_locus_prefix} ||=
        $self->_default_locus_prefix;
}

sub _default_locus_prefix {
    my ($self) = @_;
    my $client = $self->AceDatabase->Client;
    return $client->config_value('gene_type_prefix') || '';
}

sub edit_new_subsequence {
    my ($self) = @_;

    my @subseq = $self->list_selected_subseq_objs;
    my $clip      = $self->get_clipboard_text || '';

    my ($new);
    if (@subseq) {
        $new = Hum::Ace::SubSeq->new_from_subseq_list(@subseq);
    }
    else {
        # $self->logger->warn("CLIPBOARD: $clip");
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
    my $gm = $self->get_default_mutable_GeneMethod or $self->logger->logconfess("No default mutable GeneMethod");
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

sub make_variant_subsequence {
    my ($self) = @_;

    my $clip      = $self->get_clipboard_text || '';
    my @sub_names = $self->list_selected_subseq_names;
    unless (@sub_names) {
        @sub_names = $self->list_was_selected_subseq_names;
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
            if ($n && $n > $max) {
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

    my $transcript_window = $self->make_transcript_window($sub);
    $transcript_window->merge_position_pairs;  # Useful if multiple overlapping evidence selected
    $transcript_window->EvidencePaster->add_evidence_from_text($clip);

    return;
}

sub add_external_SubSeqs {
    my ($self, @ext_subs) = @_;

    # Subsequences from ZMap gff which are not in acedb database
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
                $self->logger->logconfess(
                    sprintf("External transcript '%s' from '%s' has same name as transcript from '%s'\n",
                            $sub->name, $sub->GeneMethod->name, $ext->GeneMethod->name));
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

    my $AceDatabase = $self->AceDatabase;

    my $process_result =
        $AceDatabase->process_Columns(
            grep { $_->status eq 'Visible' }
            $AceDatabase->ColumnCollection->list_Columns
        );

    $self->update_from_process_result($process_result);
    return;
}

sub update_from_process_result {
    my ($self, $process_result) = @_;
    my ($transcripts, $failed) =
        @{$process_result}{qw( -transcripts -failed )};
    if (@$transcripts) {
        $self->add_external_SubSeqs(@{$transcripts});
        $self->draw_subseq_list;        
    }
    if (@{$failed}) {
        my $message = sprintf
            'Failed to load any transcripts or alignment features from column(s): %s'
            , join ', ', sort map { $_->name } @{$failed};
        $self->message($message);
    }
    return;
}

sub delete_subsequences {
    my ($self) = @_;

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
        $in_edit += $self->raise_transcript_window($sub->name);
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

    # delete from acedb
    try { $self->save_ace($ace); return 1; }
    catch {
        $self->exception_message($_, 'Aborted delete, failed to save to Ace');
        return 0;
    }
    or return;

    # Remove from our objects
    foreach my $sub (@to_die) {
        $self->delete_SubSeq($sub);
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

sub make_transcript_window {
    my ($self, $sub) = @_;

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

    $self->save_transcript_window($sub_name, $transcript_window);

    return $transcript_window;
}

sub raise_transcript_window {
    my ($self, $name) = @_;

    $self->logger->logconfess("no name given") unless $name;

    if (my $transcript_window = $self->get_transcript_window($name)) {
        my $top = $transcript_window->canvas->toplevel;
        $top->deiconify;
        $top->raise;
        return 1;
    } else {
        return 0;
    }
}

sub get_transcript_window {
    my ($self, $name) = @_;

    return $self->{'_transcript_window'}{$name};
}

sub list_all_transcript_window_names {
    my ($self) = @_;

    return keys %{$self->{'_transcript_window'}};
}

sub save_transcript_window {
    my ($self, $name, $transcript_window) = @_;

    $self->{'_transcript_window'}{$name} = $transcript_window;
    weaken($self->{'_transcript_window'}{$name});

    return;
}

sub delete_transcript_window {
    my ($self, $name) = @_;

    delete($self->{'_transcript_window'}{$name});

    return;
}

sub rename_transcript_window {
    my ($self, $old_name, $new_name) = @_;

    my $transcript_window = $self->get_transcript_window($old_name)
        or return;
    $self->delete_transcript_window($old_name);
    $self->save_transcript_window($new_name, $transcript_window);

    return;
}

sub close_all_transcript_windows {
    my ($self) = @_;

    foreach my $name ($self->list_all_transcript_window_names) {
        my $transcript_window = $self->get_transcript_window($name) or next;
        $transcript_window->window_close or return 0;
    }

    return 1;
}

sub draw_subseq_list {
    my ($self) = @_;

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
    my $cew = EditWindow::Clone->in_Toplevel
      (-title => "Clone ".$clone->clone_name,
       { from => $self->top_window,
         reuse_ref => \$self->{'_clone_edit_window'}{$name},
         init => { SessionWindow => $self,
                   Clone => $clone },
         raise => 1 });

    return;
}

sub edit_Clone_by_name {
    my ($self, $name) = @_;

    my $clone = $self->Assembly->get_Clone($name);
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
    my ($self) = @_;

    my $canvas = $self->canvas;
    my $slice_name = $self->slice_name;
    my $ace  = $self->AceDatabase->aceperl_db_handle;

    unless ($self->{'_assembly'}) {
        my $before = time();
        my $busy = Tk::ScopedBusy->new($canvas, -recurse => 0);

        my( $assembly );
        try {
            $assembly = Hum::Ace::Assembly->new;
            $assembly->name($slice_name);
            $assembly->MethodCollection($self->AceDatabase->MethodCollection);
            $assembly->express_data_fetch($ace);
            return 1;
        }
        catch {
            $self->exception_message($_, "Can't fetch Assembly '$slice_name'");
            return 0;
        }
        or return;

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
        printf
            "Express fetch for '%s' took %d second(s)\n",
            $self->slice_name, $after - $before;
    }
    return $self->{'_assembly'};
}


# "perlcritic --stern" refuses to learn that $logger->logdie is fatal
sub save_Assembly { ## no critic (Subroutines::RequireFinalReturn)
    my ($self, $new) = @_;

    my ($delete_xml, $create_xml) = Bio::Otter::ZMap::XML::update_SimpleFeatures_xml(
        $self->Assembly, $new, $self->AceDatabase->offset);
    my $ace = $new->ace_string;

    my $done_ace = 0;
    my $err = undef;
    my $done_zmap = try {
        $self->save_ace($ace);
        $done_ace = 1;
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
    };

    # Set internal state only if we saved to Ace OK
    if ($done_ace) {
        $self->Assembly->set_SimpleFeature_list($new->get_all_SimpleFeatures);
    }

    if ($done_zmap) {
        # all OK
        return;
    } else {
        my $msg;
        if ($done_ace) {
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

sub empty_Assembly_cache {
    my ($self) = @_;

    $self->{'_assembly'} = undef;

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

    my $new_name = $new->name;
    my $old_name = $old->name || $new_name;

    my $rename_needed = $old->is_archival && $new_name ne $old_name;
    my $ace =
        $rename_needed
      ? $new->ace_string($old_name)
      : $new->ace_string;

    my ($done_ace, $done_zmap, $err);
    my $offset = $self->AceDatabase->offset;
    try {
        $self->save_ace($ace);
        $done_ace = 1;
        if ($old->is_archival) {
            $self->zmap->send_command_and_xml('delete_feature', $old->zmap_delete_xml_string($offset));
        }
        $self->zmap->send_command_and_xml('create_feature', $new->zmap_create_xml_string($offset));
        $done_zmap = 1;
    }
    catch { $err = $_; };

    if ($done_ace) {

        # update internal state
        $self->Assembly->replace_SubSeq($new, $old_name);

        if ($new_name ne $old_name) {
            $self->{'_subsequence_cache'}{$old_name} = undef;
            $self->rename_transcript_window($old_name, $new_name);
        }
        $self->{'_subsequence_cache'}{$new_name} = $new;

        my $locus = $new->Locus;
        if (my $prev_name = $locus->drop_previous_name) {
            $self->logger->info("Unsetting otter_id for locus '$prev_name'");
            $self->get_Locus($prev_name)->drop_otter_id;
        }
        $self->set_Locus($locus);
    }

    if ($done_zmap) {
        # all OK
        return 1;
    }
    else {
        my $msg;
        if ($done_ace) {
            $msg = "Saved OK, but please restart ZMap";
        }
        else {
            $msg = "Aborted save, failed to save to Ace";
        }
        $self->exception_message($err, $msg);
        return $done_ace;
    }
}

sub add_SubSeq {
    my ($self, $sub) = @_;

    my $name = $sub->name;
    if ($self->{'_subsequence_cache'}{$name}) {
        $self->logger->logconfess("already have SubSeq '$name'");
    } else {
        $self->{'_subsequence_cache'}{$name} = $sub;
    }

    return;
}

sub delete_SubSeq {
    my ($self, $sub) = @_;

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
    my ($self, $name) = @_;

    $self->logger->logconfess("no name given") unless $name;
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
    my ($self) = @_;

    $self->{'_subsequence_cache'} = undef;

    return;
}

sub row_count {
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

sub update_SubSeq_locus_level_errors {
    my ($self) = @_;

    $self->Assembly->set_SubSeq_locus_level_errors;
    foreach my $sub_name ($self->list_all_transcript_window_names) {
        my $transcript_window = $self->get_transcript_window($sub_name) or next;
        my $sub = $self->get_SubSeq($sub_name) or next;
        $transcript_window->SubSeq->locus_level_errors($sub->locus_level_errors);
    }

    return;
}

sub launch_exonerate {
    my ($self, $otf) = @_;

    # Clear columns if requested
    my $db_slice = $self->AceDatabase->db_slice;
    $otf->pre_launch_setup(slice => $db_slice);

    # Setup for GFF column control below
    my $cllctn = $self->AceDatabase->ColumnCollection;
    my $col_aptr = $self->AceDatabase->DB->ColumnAdaptor;

    my $request_adaptor = $self->AceDatabase->DB->OTFRequestAdaptor;

    my @method_names;

    for my $builder ( $otf->builders_for_each_type ) {

        my $type = $builder->type;

        $self->logger->info("Running exonerate for sequence(s) of type: $type");

        # Set up a request for the filter script
        my $request = $builder->prepare_run;
        $request_adaptor->store($request);

        my $analysis_name = $builder->analysis_name;
        push @method_names, $builder->analysis_name;

        # Ensure new-style columns are selected if used
        my $column = $cllctn->get_Column_by_name($analysis_name);
        if ($column and not $column->selected) {
            $column->selected(1);
            $col_aptr->store_Column_state($column);
        }

    }

    $self->RequestQueuer->request_features(@method_names) if @method_names;

    return;
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
    my ($self, $slist) = @_;

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
                -font       => $style eq 'bold' ? $self->font_fixed_bold : $self->font_fixed,
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

sub highlight_by_name {
    my ($self, @names) = @_;

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
    my ($self) = @_;

    return $self->canvas_obj_to_subseq_names($self->list_selected);
}

sub list_selected_subseq_objs {
    my ($self) = @_;
    return map { $self->get_SubSeq($_) } $self->list_selected_subseq_names;
}

sub list_was_selected_subseq_names {
    my ($self) = @_;

    return $self->canvas_obj_to_subseq_names($self->list_was_selected);
}

sub rename_locus {
    my ($self, $locus_name) = @_;

    $self->logger->info("Renaming locus '$locus_name'");

    unless ($self->close_all_transcript_windows) {
        $self->message('Must close all clone editing windows before renaming locus');
        return;
    }

    if (my $ren_window = $self->{'_locus_rename_window'}) {
        $ren_window->top->destroy;
    }

    my $lr = EditWindow::LocusName->in_Toplevel
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

sub run_dotter {
    my ($self) = @_;

    my $dw = EditWindow::Dotter->in_Toplevel
      (-title => 'Run Dotter',
       { reuse_ref => \$self->{'_dotter_window'},
         transient => 1,
         init => { SessionWindow => $self },
         from => $self->top_window });

    $dw->update_from_SessionWindow($self);

    return 1;
}

sub run_exonerate {
    my ($self) = @_;

    my $ew = EditWindow::Exonerate->in_Toplevel
      (-title => 'On The Fly (OTF) Alignment',
       { reuse_ref => \$self->{'_exonerate_window'},
         transient => 1,
         init => { SessionWindow => $self },
         from => $self->top_window });

    $ew->update_from_SessionWindow;

    return 1;
}

sub exonerate_done_callback {
    my ($self, @feature_sets) = @_;

    $self->logger->debug('exonerate_done_callback: [', join(',', @feature_sets), ']');

    my $request_adaptor = $self->AceDatabase->DB->OTFRequestAdaptor;
    my (@requests, @requests_with_feedback);
    foreach my $set (@feature_sets) {
        my $request = $request_adaptor->fetch_by_logic_name_status($set, 'completed');
        next unless $request;
        push @requests, $request;
        push @requests_with_feedback, $request if ($request->n_hits == 0 or $request->missed_hits);
    }

    if (@requests_with_feedback) {
        my $ew = $self->{'_exonerate_window'};
        if ($ew) {
            foreach my $request (@requests_with_feedback) {
                $ew->display_request_feedback($request);
            }
        } else {
            $self->logger->error('OTF results but no exonerate window');
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
    my @mark = $self->zmap->get_mark;
    my $offset = $self->AceDatabase->offset;
    $_ -= $offset for @mark;
    return @mark;
}

sub set_window_title {
    my ($self) = @_;

    my $name = $self->AceDatabase->name;
    my $unsaved_str = $self->AceDatabase->unsaved_changes ? '*' : '';
    $self->top_window->title
      (sprintf('%s%sSession %s',
               $unsaved_str, $Bio::Otter::Lace::Client::PFX, $name));

    return;
}

sub zmap_view_arg_hash {
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

    my $config_dir = $self->zmap_configs_dir;
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

    return $config_dir;
}

sub zmap_configs_dir {
    my ($called) = @_;
    my $user = getpwuid($<);
    return "/var/tmp/otter_${user}/ZMap";
}

### BEGIN: ZMap control interface

sub zircon_context {
    my ($self, @arg) = @_;
    ($self->{'_zircon_context'}) = @arg if @arg;
    my $zircon_context =
        $self->{'_zircon_context'} ||=
        Zircon::Tk::Context->new(
            '-widget' => $self->menu_bar);
    return $zircon_context;
}

sub zmap_new {
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
            '-app_id'     => $self->zircon_app_id,
            '-context'    => $self->zircon_context,
            '-arg_list'   => $arg_list,
            '-timeout_ms'      => $client->config_section_value(Peer => 'timeout-ms'),
            '-timeout_retries' => $client->config_section_value(Peer => 'timeout-retries'),
            '-rolechange_wait' => $client->config_section_value(Peer => 'rolechange-wait'), # XXX: temporary, awaiting RT#324544
        );
    return $zmap;
}

sub zircon_app_id {
    my ($self) = @_;
    my $widget_id = $self->top_window->id;
    my $zircon_app_id = "Otterlace_${widget_id}";
    return $zircon_app_id;
}

sub _zmap_view_new {
    my ($self, $zmap) = @_;
    $zmap ||= $self->zmap_new;
    delete $self->{'_zmap_view'};
    $self->{'_zmap_view'} =
        $zmap->new_view(
            %{$self->zmap_view_arg_hash},
            '-handler' => $self,
        );
    $self->deiconify_and_raise;
    return;
}

sub _zmap_relaunch {
    my ($self) = @_;

    # NB: (from jh13 via IRC 26/02/2014)
    # Unreferencing the old view object causes it to be destroyed,
    # which removes the last reference to the ZMap object, causing it
    # to be destroyed, which sends a shutdown to the ZMap process.

    $self->_zmap_view_new($self->zmap_select);
    $self->ColumnChooser->load_filters(is_recover => 1);
    return;
}

sub zircon_zmap_view_features_loaded {
    my ($self, $status, $message, $feature_count, @featuresets) = @_;

    my $cllctn = $self->AceDatabase->ColumnCollection;
    my $col_aptr = $self->AceDatabase->DB->ColumnAdaptor;
    my $state_changed = 0;

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
                (! $status)    ? 'Error'   :
                $feature_count ? 'Visible' :
                1              ? 'Empty'   :
                $self->logger->logdie('this code should be unreachable');

            if ($column->status ne $column_status) {
                $state_changed = 1;
                $column->status($column_status);
                push @columns_to_process, $column
                    if $status && $feature_count;
            }

            $column->status_detail($message);
            $col_aptr->store_Column_state($column);

            push @otf_loaded, $set_name if $column->internal_type_is('on_the_fly');
        }
        # else {
        #     # We see a warning for each acedb featureset
        #     $self->logger->warn("Ignoring featureset '$set_name'");
        # }
    }

    my $process_result =
        $self->AceDatabase->process_Columns(@columns_to_process);
    $self->update_from_process_result($process_result);

    $self->exonerate_done_callback(@otf_loaded) if @otf_loaded;

    # FIXME 26/02/2014: assuming that commenting this out doesn't cause other problems,
    # it should be removed along with AceDatabase->zmap_config_update().

    # if ($state_changed) {
    #     # and update the delayed flags in the zmap config file
    #     $self->AceDatabase->zmap_config_update;
    # }

    # This will get called by Tk event loop when idle
    $self->top_window->afterIdle(sub{ return $self->RequestQueuer->features_loaded_callback(@featuresets); });

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
        my $clone = $self->Assembly->get_Clone_by_accession_version($accession_version);
        $self->edit_Clone($clone);
        return 1;
    }
    else {
        $sub_list or return 0;
        ref $sub_list eq 'ARRAY'
            or $self->logger->logconfess("Unexpected feature format for ${name}");
        for my $s (@$sub_list) {
            if ($s->{'ontology'} eq 'exon') {
                return $self->edit_subsequences($name);
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
    my $subseq = $self->get_SubSeq($name);
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
    foreach my $name ($self->list_all_SubSeq_names) {
        if (my $subseq = $self->get_SubSeq($name)) {
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
    $self->highlight_by_name_without_owning_clipboard($_)
        for @{$name_list};
    return;
}

sub zircon_zmap_view_multiple_select {
    my ($self, $name_list) = @_;
    $self->highlight_by_name_without_owning_clipboard($_)
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

    $self->logger->info("Destroying SessionWindow for ", $self->ace_path);

    $self->zmap_select_destroy;

    delete $self->{'_zmap_view'};
    delete $self->{'_AceDatabase'};

    return;
}

1;

__END__

=head1 NAME - MenuCanvasWindow::SessionWindow

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

