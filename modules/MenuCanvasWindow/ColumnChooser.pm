
### MenuCanvasWindow::ColumnChooser

package MenuCanvasWindow::ColumnChooser;

use strict;
use warnings;
use Try::Tiny;
use Scalar::Util qw{ weaken };
use Bio::Otter::Lace::Chooser::Collection;
use Bio::Otter::Lace::Chooser::SearchHistory;
use MenuCanvasWindow::SessionWindow;
use Tk::Utils::CanvasXPMs;
use Tk::ScopedBusy;

use base qw{
    MenuCanvasWindow
    Bio::Otter::UI::ZMapSelectMixin
    };


sub new {
    my ($pkg, $tk) = @_;

    # Need to make both frames which appear above the canvas...
    my $menu_frame = $pkg->make_menu_widget($tk);
    my $top_frame = $tk->Frame(Name => 'top_frame')->pack(
        -side => 'top',
        -fill => 'x',
        );

    # ... before we make the canvas
    my $self = CanvasWindow->new($tk, 800, 400, 'ose');
    bless($self, $pkg);

    my $bottom_frame = $tk->Frame->pack(
        qw{ -side top -padx 4 -pady 4 }
    );

    $self->menu_bar($menu_frame);
    $self->top_frame($top_frame);
    $self->bottom_frame($bottom_frame);
    return $self;
}

sub withdraw_or_destroy {
    my ($self) = @_;

    $self->zmap_select_destroy;

    if ($self->init_flag) {
        # Destroy ourselves
        $self->AceDatabase->error_flag(0);
        $self->top_window->destroy;
    } else {
        $self->top_window->withdraw;
    }

    return;
}

sub init_flag {
    my($self, $flag) = @_;

    if (defined $flag) {
        $self->{'_init_flag'} = $flag ? 1 : 0;
    }
    return $self->{'_init_flag'};
}

sub top_frame {
    my ($self, $top_frame) = @_;

    if ($top_frame) {
        $self->{'_top_frame'} = $top_frame;
    }
    return $self->{'_top_frame'};
}

sub bottom_frame {
    my ($self, $bottom_frame) = @_;

    if ($bottom_frame) {
        $self->{'_bottom_frame'} = $bottom_frame;
    }
    return $self->{'_bottom_frame'};
}

sub balloon { # see also EditWindow.pm, which we are not one of
    my ($self) = @_;
    return $self->{_balloon} ||= $self->top_window->Balloon();
}


sub row_height {
    my ($self) = @_;

    return int 1.5 * $self->font_size;
}

sub initialize {
    my ($self) = @_;

    my $search_menu = $self->make_menu('Search');
    my $view_menu   = $self->make_menu('View');
    my $select_menu = $self->make_menu('Select');

    $self->font_size(12);
    my @button_pack = qw{ -side left -padx 4 };

    my $cllctn = $self->AceDatabase->ColumnCollection;
    my $hist = Bio::Otter::Lace::Chooser::SearchHistory->new($cllctn);
    $self->SearchHistory($hist);

    my $top = $self->top_window;
    my $top_frame = $self->top_frame;
    my @packing = qw{ -side top -fill x -expand 1 -padx 4 -pady 4 };
    my $snail_frame  = $top_frame->Frame->pack(@packing);
    my $search_frame = $top_frame->Frame->pack(@packing);

    $self->{'_snail_trail_frame'} = $snail_frame;
    $snail_frame->Label(
        -text => 'Filter trail: ',
        -padx => 4,
        -pady => 4,
        )->pack(-side => 'left');

    my $entry = $self->{'_search_Entry'} = $search_frame->Entry(
        -width        => 60,
        -textvariable => \$self->{'_entry_search_string'},
    )->pack(-side => 'left', -padx => 4);
    $self->set_search_entry($cllctn->search_string);

    my $filter = sub{ $self->do_filter };
    $search_frame->Button(-text => 'Filter', -command => $filter)->pack(@button_pack);

    my $back = sub{ $self->go_back };
    $search_frame->Button(-text => 'Back', -command => $back)->pack(@button_pack);

    $search_menu->add('command',
        -label          => 'Filter',
        -command        => $filter,
        -accelerator    => 'Return',
        );
    $search_menu->add('command',
        -label          => 'Back',
        -command        => $back,
        -accelerator    => 'Esc',
        );
    my $reset = sub{ $self->reset_search };
    $search_menu->add('command',
       -label          => 'Reset',
       -command        => $reset,
       -accelerator    => 'Ctrl+R',
       );

    my $collapse_all = sub{ $self->collapse_all };
    $view_menu->add('command',
        -label          => 'Collapse all',
        -command        => $collapse_all,
        -accelerator    => 'Ctrl+Left',
        );
    my $expand_all = sub{ $self->expand_all };
    $view_menu->add('command',
        -label          => 'Expand all',
        -command        => $expand_all,
        -accelerator    => 'Ctrl+Right',
        );

    $select_menu->add('command',
        -label      => 'Default',
        -command    => sub{ $self->change_selection('select_default') },
        );
    $select_menu->add('command',
        -label      => 'All',
        -command    => sub{ $self->change_selection('select_all') },
        );
    $select_menu->add('command',
        -label      => 'None',
        -command    => sub{ $self->change_selection('select_none') },
        );

    my $status_menu = $select_menu->Menu(-tearoff => 0);
    $select_menu->add('cascade',
                      -menu      => $status_menu,
                      -label     => 'By status',
                      -underline => 0,
        );

    $status_menu->add('command',
        -label      => 'Queued',
        -command    => sub{ $self->select_by_status('Queued') },
        );
    $status_menu->add('command',
        -label      => 'Loading',
        -command    => sub{ $self->select_by_status('Loading') },
        );
    $status_menu->add('command',
        -label      => 'Empty',
        -command    => sub{ $self->select_by_status('Empty') },
        );
    $status_menu->add('command',
        -label      => 'Error',
        -command    => sub{ $self->select_by_status('Error') },
        );

    my $bottom_frame = $self->bottom_frame;

    # The user can press the Cancel button either before the AceDatabase is made
    # (in which case we destroy ourselves) or during an edit session (in which
    # case we just withdraw the window).
    my $wod_cmd = sub { $self->withdraw_or_destroy };
    my $wod_btn = $bottom_frame->Button(
        -text => 'Cancel',
        -command => $wod_cmd,
        )->pack(@button_pack);
    $top->protocol( 'WM_DELETE_WINDOW', $wod_cmd );

    $bottom_frame->Button(
        -text => 'Select ZMap',
        -command => sub { $self->zmap_select_window },
        )->pack(@button_pack);

    my $load_cmd = sub { $self->load_filters };
    my $load_btn = $bottom_frame->Button(
        -text => 'Load',
        -command => $load_cmd,
        )->pack(@button_pack);

    $top->bind('<Return>', $filter);
    $top->bind('<Escape>', $back);
    $top->bind('<Control-r>', $reset);
    $top->bind('<Control-R>', $reset);
    $top->bind('<Control-Left>', $collapse_all);
    $top->bind('<Control-Right>', $expand_all);
    $top->bind('<Destroy>', sub{ $self = undef });

    $self->balloon->attach($wod_btn, -initwait=>0, -balloonmsg => 'Ctrl+w');
    $top->bind('<Control-w>', $wod_cmd); # cancel
    $top->bind('<Control-W>', $wod_cmd);

    $self->balloon->attach($load_btn, -initwait=>0, -balloonmsg => 'Ctrl+Return');
    $top->bind('<Control-Return>', $load_cmd);


    $self->colour_init;
    $self->calculate_text_column_sizes;
    $self->fix_window_min_max_sizes;
    $self->redraw; # calls update via set_scroll_region_and_maxsize

    # Set window to full screen height, y=0.  RT#355409
    my $w = $top->screenwidth;
    $w = 800 if $w > 800;
    my $h = $top->screenheight;

    my $x = $top->x;
    my $new_x = $top->screenwidth - $w;
    $new_x = $x if $x < $new_x;
    $x = 0 if $x < 0;
    $top->withdraw;
    $top->geometry("${w}x$h+$x+0");
    $self->deiconify_and_raise;

    return;
}

sub colour_init {
    my ($self) = @_;
    my $top = $self->top_window;
    my $colour = $self->AceDatabase->colour;
    my $tpath = $top->PathName;

    $top->configure(-borderwidth => 3, -background => $colour);
    $self->bottom_frame->configure(-background => $colour);
    return;
}

sub redraw {
    my ($self) = @_;

    $self->update_snail_trail;
    $self->do_render;

    return;
}

sub do_filter {
    my ($self) = @_;

    my $new_cllctn = $self->SearchHistory->search($self->{'_entry_search_string'})
        or return;
    $self->set_search_entry($new_cllctn->search_string);
    $self->redraw;

    return;
}

sub go_back {
    my ($self) = @_;

    # Save any typing done in the search Entry
    $self->current_Collection->search_string($self->{'_entry_search_string'});

    my $sh = $self->SearchHistory;
    my $cllctn = $sh->back or return;
    $self->set_search_entry($cllctn->search_string);
    $self->redraw;

    return;
}

sub reset_search {
    my ($self) = @_;

    my $sh = $self->SearchHistory;
    $sh->reset_search;
    $self->set_search_entry('');
    my $steps = $self->snail_trail_steps;
    foreach my $s (@$steps) {
        $s->packForget;
    }
    $self->redraw;

    return;
}

sub collapse_all {
    my ($self) = @_;

    $self->current_Collection->collapse_all;
    $self->redraw;

    return;
}

sub expand_all {
    my ($self) = @_;

    $self->current_Collection->expand_all;
    $self->redraw;

    return;
}

sub change_selection {
    my ($self, $method) = @_;

    $self->current_Collection->$method();
    $self->redraw;

    return;
}

sub select_by_status {
    my ($self, $status) = @_;

    $self->current_Collection->select_by_status($status);
    $self->redraw;

    return;
}

sub set_search_entry {
    my ($self, $string) = @_;

    $self->{'_entry_search_string'} = $string;
    $self->{'_search_Entry'}->icursor('end');    

    return;
}

sub update_snail_trail {
    my ($self) = @_;

    my ($I, @trail) = $self->SearchHistory->index_and_search_string_list;
    my $trail_steps = $self->snail_trail_steps;
    for (my $i = 0; $i < @trail; $i++) {
        my $step = $trail_steps->[$i] ||= $self->{'_snail_trail_frame'}->Label(
            -relief => 'groove',
            -padx   => 10,
            -pady   => 2,
            -borderwidth => 2,
            );
        $step->pack(-side => 'left', -padx => 2);
        $step->configure(
            -text => $trail[$i],
            -font   => ['Helvetica', 12, $i == $I ? ('bold', 'underline') : ('normal')],
            );
    }

    return;
}

sub snail_trail_steps {
    my ($self) = @_;

    return $self->{'_snail_trail_steps'} ||= [];
}

sub SearchHistory {
    my ($self, $hist) = @_;

    if ($hist) {
        $self->{'_SearchHistory'} = $hist;
    }
    return $self->{'_SearchHistory'};
}

sub current_Collection {
    my ($self) = @_;

    return $self->SearchHistory->current_Collection;
}

sub current_Bracket {
    my ($self, $bkt) = @_;

    if ($bkt) {
        $self->{'_current_Bracket'} = $bkt;
    }
    return $self->{'_current_Bracket'};
}

sub name_max_x {
    my ($self, $bkt, $max_x) = @_;

    if ($bkt && $max_x) {
        $self->{'_name_max_x'}{$bkt} = $max_x;
        return;
    }
    else {
        return $self->{'_name_max_x'}{$self->current_Bracket};
    }
}

sub do_render {
    my ($self) = @_;

    $self->canvas->delete('all');

    my $cllctn = $self->current_Collection;
    $cllctn->update_all_Bracket_selection;
    my @items = $cllctn->list_visible_Items;
    for (my $i = 0; $i < @items; $i++) {
        $self->draw_Item($i, $items[$i]);
    }

    $self->set_scroll_region_and_maxsize;
    return;
}

sub draw_Item {
    my ($self, $row, $item) = @_;

    my $canvas = $self->canvas;
    my $row_height = $self->row_height;
    my $pad = int $self->font_size * 0.4;
    my $x = $row_height * $item->indent;
    my $y = $row * ($row_height + $pad);

    # Brackets have an arrow to expand or contract their contents
    if ($item->is_Bracket) {
        $self->draw_arrow($item, $x, $y);
        $self->current_Bracket($item);
    }

    # Both Brackets and Columns have a checkbutton and their name drawn
    $x += 2 * $row_height;
    my $txt_id = $canvas->createText(
        $x, $y,
        -anchor => 'nw',
        -text   => $item->name,
        -font   => $self->normal_font,
        );
    $x -= $row_height;
    # Draw text first, so we can pass $txt_id to draw_checkbutton()
    $self->draw_checkbutton($item, $x, $y, $txt_id);
    $x += $row_height;

    # Draw status indicator and description for Columns
    unless ($item->is_Bracket) {
        $x += $row_height + $self->name_max_x;
        $self->draw_status_indicator($item, $x, $y);
        $x += $row_height + $self->{'_status_max_x'};
        $canvas->createText(
            $x, $y,
            -anchor => 'nw',
            -text   => $item->Filter->description,
            -font   => $self->normal_font,
            );        
    }

    return;
}

sub normal_font {
    my ($self) = @_;

    return ['Helvetica', $self->font_size, 'normal'],
}

sub draw_status_indicator {
    my ($self, $item, $x, $y) = @_;

    my $canvas = $self->canvas;
    my ($dark, $light) = $item->status_colors;
    my $width = $self->{'_status_max_x'};
    $canvas->createRectangle(
        $x - 1, $y - 1, $x + $width + 1, $y + $self->{'_max_y'} + 1,
        -fill       => $light,
        -outline    => $dark,
        -tags       => ["STATUS_RECTANGLE $item"],
        );

    $canvas->createText(
        $x + ($width / 2), $y,
        -anchor => 'n',
        -text   => $item->status,
        -font   => $self->normal_font,
        -tags       => ["STATUS_LABEL $item"],
        );

    $item->status_callback([$self, 'update_status_indicator']);

    # # For looking at appearance of status indicators
    # my $next = sub { $self->next_status($item) };
    # $canvas->bind("STATUS_RECTANGLE $item", '<Button-1>', $next);
    # $canvas->bind("STATUS_LABEL $item",     '<Button-1>', $next);

    return;
}

# sub next_status {
#     my ($self, $item) = @_;
# 
#     my @status = Bio::Otter::Lace::Chooser::Item::Column::VALID_STATUS_LIST();
#     my $this = $item->status;
#     for (my $i = 0; $i < @status; $i++) {
#         if ($status[$i] eq $this) {
#             my $j = $i + 1;
#             if ($j == @status) {
#                 $j = 0;
#             }
#             $item->status($status[$j]);
#             $self->update_status_indicator($item);
#             last;
#         }
#     }
# }

sub update_status_indicator {
    my ($self, $item) = @_;

    my $canvas = $self->canvas;
    my ($dark, $light) = $item->status_colors;
    $canvas->itemconfigure("STATUS_RECTANGLE $item",
        -fill       => $light,
        -outline    => $dark,
        );
    $canvas->itemconfigure("STATUS_LABEL $item",
        -text   => $item->status,
        );

    return;
}

{
    my $on_checkbutton_xpm;
    my $off_checkbutton_xpm;

    sub draw_checkbutton {
        my ($self, $item, $x, $y, $txt_id) = @_;

        my $canvas = $self->canvas;
        $on_checkbutton_xpm  ||= Tk::Utils::CanvasXPMs::on_checkbutton_xpm($canvas);
        $off_checkbutton_xpm ||= Tk::Utils::CanvasXPMs::off_checkbutton_xpm($canvas);

        my $is_selected = $item->selected;
        my ($img, $other_img);
        if ($is_selected) {
            $img       = $on_checkbutton_xpm;
            $other_img = $off_checkbutton_xpm;
        }
        else {
            $img       = $off_checkbutton_xpm;
            $other_img = $on_checkbutton_xpm;
        }
        my $img_id = $canvas->createImage(
            $x, $y,
            -anchor => 'nw',
            -image  => $img,
            );
        foreach my $id ($img_id, $txt_id) {
            $canvas->bind($id, '<Button-1>', sub {
                # Update image immediately to provide feedback on slow connections
                $canvas->itemconfigure($img_id, -image => $other_img);
                $canvas->update;
                $item->selected(! $is_selected);
                # update_item_select_state() redraws whole canvas
                $self->update_item_select_state($item);
                });
        }

        return;
    }
}

sub update_item_select_state {
    my ($self, $item) = @_;

    my $cllctn = $self->current_Collection;
    if ($item->is_Bracket) {
        $cllctn->select_Bracket($item);
    }
    $self->do_render;

    return;
}

{
    my $arrow_right_xpm;
    my $arrow_right_active_xpm;

    my $arrow_down_xpm;
    my $arrow_down_active_xpm;

    sub draw_arrow {
        my ($self, $item, $x, $y) = @_;

        my $canvas = $self->canvas;
        my $is_collapsed = $self->current_Collection->is_collapsed($item);
        my ($img, $active_img);
        if ($is_collapsed) {
            $img        = $arrow_right_xpm        ||= Tk::Utils::CanvasXPMs::arrow_right_xpm($canvas);
            $active_img = $arrow_right_active_xpm ||= Tk::Utils::CanvasXPMs::arrow_right_active_xpm($canvas);            
        }
        else {
            $img        = $arrow_down_xpm        ||= Tk::Utils::CanvasXPMs::arrow_down_xpm($canvas);
            $active_img = $arrow_down_active_xpm ||= Tk::Utils::CanvasXPMs::arrow_down_active_xpm($canvas);
        }
        my $img_id = $canvas->createImage(
            $x, $y,
            -anchor => 'nw',
            -image  => $img,
            -activeimage => $active_img,
            );
        $canvas->bind($img_id, '<Button-1>', sub {
            $self->current_Collection->is_collapsed($item, ! $is_collapsed);
            $self->do_render;
            });

        return;
    }

}

sub load_filters {
    my ($self, %options) = @_;

    my $is_recover = $options{is_recover};

    my $top = $self->top_window;
    my $busy = Tk::ScopedBusy->new($top, -recurse => 1);

    my $cllctn = $self->SearchHistory->root_Collection;

    # So that next session will use current selected filters:
    $cllctn->save_Columns_selected_flag_to_Filter_wanted;
    $self->AceDatabase->save_filter_state;

    my @statuses =  qw( Selected );
    push @statuses, qw( Queued Loading Visible ) if $is_recover;

    my @to_fetch = $cllctn->list_Columns_with_status(@statuses);
    my @to_fetch_names;
    foreach my $col (@to_fetch) {
        $col->status('Queued');
        push @to_fetch_names, $col->Filter->name;
    }

    if ($self->init_flag) {
        # now initialise the database
        try { $self->AceDatabase->init_AceDatabase; return 1; }
        catch {
            $self->SequenceNotes->exception_message($_, "Error initialising database");
            $self->AceDatabase->error_flag(0);
            undef $busy; # i.e. Unbusy
            $self->zmap_select_destroy;
            $top->destroy;
            return 0;
        }
        or return;
        $self->init_flag(0);
    }

    if ($self->SessionWindow) {
        unless (@to_fetch) {
            $top->messageBox(
                -title      => $Bio::Otter::Lace::Client::PFX.'Nothing to fetch',
                -icon       => 'warning',
                -message    => 'All selected columns have already been loaded',
                -type       => 'OK',
                );
        }
    } else {
        # we need to set up and show a SessionWindow
        my $zmap = $self->zmap_select;
        my $zircon_context = $self->SpeciesListWindow->zircon_context;
        my $SessionWindow =
            MenuCanvasWindow::SessionWindow->new(
                $self->top_window->Toplevel,
                '-zmap'           => $zmap,
                '-zircon_context' => $zircon_context,
            );

        $self->SessionWindow($SessionWindow);
        $SessionWindow->AceDatabase($self->AceDatabase);
        $SessionWindow->SequenceNotes($self->SequenceNotes);
        $SessionWindow->ColumnChooser($self);
        $SessionWindow->initialize;
    }

    if (@to_fetch) {
        $self->AceDatabase->Client->reauthorize_if_cookie_will_expire_soon;
        my $rq = $self->SessionWindow->RequestQueuer;
        $rq->flush_current_requests; # in case of Zircon message loss
        $rq->request_features(@to_fetch_names);
    }

    undef $busy; # i.e. Unbusy
    # $top->withdraw;
    $self->zmap_select_destroy;

    return;
}

sub calculate_text_column_sizes {
    my ($self) = @_;

    my $font = $self->normal_font;
    my $cllctn = $self->current_Collection;

    my @status = Bio::Otter::Lace::Chooser::Item::Column::VALID_STATUS_LIST();
    my ($status_max_x, $max_y) = $self->max_x_y_of_text_array($font, @status);
    $self->{'_status_max_x'} = 4 + $status_max_x;
    $self->{'_max_y'} = $max_y;

    foreach my $bkt ($cllctn->list_Brackets) {
        my $next_level = $bkt->indent + 1;
        my @names = map { $_->name }
            grep { $_->indent == $next_level } $cllctn->get_Bracket_contents($bkt);
        my ($name_max_x) = $self->max_x_y_of_text_array($font, @names);
        $self->name_max_x($bkt, $name_max_x);
    }

    return;
}

sub update_statuses_by_name {
    my ($self, $status, @names) = @_;
    my $cllctn = $self->SearchHistory->root_Collection;

    foreach my $name (@names) {
        my $item = $cllctn->get_Column_by_name($name);
        $item->status($status) if $item;
    }
    return;
}


sub SessionWindow {
    my ($self, $SessionWindow) = @_;

    if ($SessionWindow) {
        $self->{'_SessionWindow'} = $SessionWindow;
        weaken($self->{'_SessionWindow'});
    }

    return $self->{'_SessionWindow'} ;
}

sub AceDatabase {
    my ($self, $db) = @_;
    $self->{'_AceDatabase'} = $db if $db;
    return $self->{'_AceDatabase'} ;
}

sub SequenceNotes {
    my ($self, $sn) = @_;
    $self->{'_SequenceNotes'} = $sn if $sn;
    return $self->{'_SequenceNotes'} ;
}

sub SpeciesListWindow {
    my ($self, $SpeciesListWindow) = @_;
    $self->{'_SpeciesListWindow'} = $SpeciesListWindow if $SpeciesListWindow;
    return $self->{'_SpeciesListWindow'} ;
}

sub DESTROY {
    my ($self) = @_;

    $self->zmap_select_destroy;

    warn "Destroying ColumnChooser\n";
    if (my $sn = $self->SequenceNotes) {
        $self->AceDatabase->post_exit_callback(sub{
            $sn->refresh_lock_columns;
        });
    }

    return;
}


1;

__END__

=head1 NAME - MenuCanvasWindow::ColumnChooser

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

