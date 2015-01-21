
### CanvasWindow::SequenceSetChooser

package CanvasWindow::SequenceSetChooser;

use strict;
use warnings;
use Carp;
use base 'CanvasWindow';
use CanvasWindow::SequenceNotes;
use CanvasWindow::SearchWindow;
use Bio::Otter::Lace::Client;
use Hum::Sort 'ace_sort';
use Tk::ScopedBusy;

sub new {
    my ($pkg, @args) = @_;

    my $self = $pkg->SUPER::new(@args);

    my $canvas = $self->canvas;
    $canvas->Tk::bind('<Button-1>', sub{
            $self->deselect_all;
            $self->select_sequence_set;
        });
    my $edit_command = sub{ $self->open_sequence_set; };
    $canvas->Tk::bind('<Double-Button-1>',  $edit_command);
    $canvas->Tk::bind('<Return>',           $edit_command);
    $canvas->Tk::bind('<KP_Enter>',         $edit_command);
    $canvas->Tk::bind('<Control-o>',        $edit_command);
    $canvas->Tk::bind('<Control-O>',        $edit_command);
    $canvas->Tk::bind('<Escape>', sub{ $self->deselect_all });

    my $close_window = sub{
        my $top = $self->SpeciesListWindow->canvas->toplevel;
        $top->deiconify;
        $top->raise;
        $self->canvas->toplevel->destroy;
        $self->clean_SequenceNotes();
        $self = undef;  # $self will not get DESTROY'd without this
    };
    $canvas->Tk::bind('<Control-w>',                $close_window);
    $canvas->Tk::bind('<Control-W>',                $close_window);
    $canvas->toplevel->protocol('WM_DELETE_WINDOW', $close_window);


    my $top = $canvas->toplevel;
    my $button_frame = $top->Frame->pack(-side => 'top', -fill => 'x');
    my $open = $button_frame->Button(
        -text       => 'Open',
        -command    => sub {
            unless ($self->open_sequence_set) {
                $self->message("No SequenceSet selected - click on one to select");
            }
        },
        )->pack(-side => 'left');

    my $search_command = sub { $self->search_window };

    my $search = $button_frame->Button(
        -text       => 'Search' ,
        -command    => $search_command,
    )->pack(-side =>'left') ;
    $canvas->Tk::bind('<Control-f>', $search_command);
    $canvas->Tk::bind('<Control-F>', $search_command);

    my $quit = $button_frame->Button(
        -text       => 'Close',
        -command    => $close_window,
        )->pack(-side => 'right');

    # XXX: pointer to moved UI element - remove "later"
    my $err_log = $button_frame->Label
      (-text => "Error Log is now in\nSpecies List Help menu",
       -fg => '#666')->pack(-side => 'right');

    return $self;
}

sub name {
    my ($self, $name) = @_;

    if ($name) {
        $self->{'_name'} = $name;
    }
    return $self->{'_name'};
}

sub Client {
    my ($self, $Client) = @_;

    if ($Client) {
        $self->{'_Client'} = $Client;
    }
    return $self->{'_Client'};
}

sub DataSet {
    my ($self, $DataSet) = @_;

    if ($DataSet) {
        $self->{'_DataSet'} = $DataSet;
    }
    return $self->{'_DataSet'};
}

sub SpeciesListWindow {
    my ($self, $SpeciesListWindow) = @_;

    if ($SpeciesListWindow) {
        $self->{'_SpeciesListWindow'} = $SpeciesListWindow;
    }
    return $self->{'_SpeciesListWindow'};
}

sub initialise { # alias provided for BaseWindow->in_Toplevel(... { init => ... })
    my ($self) = @_;
    return $self->draw;
}

sub draw {
    my ($self) = @_;

    my $canvas  = $self->canvas;

    my ($font_def, $size, $row_height) =
      $self->named_font(listbold => 'linespace', 'linegap');
    my $helv_def = $self->named_font('menu');

    my $ds = $self->Client->get_DataSet_by_name($self->name);

    my $ss_list  = $ds->get_all_visible_SequenceSets;

    if(@$ss_list) {

        my $all_pairs = [ map { [$_->name(), $_->name().':', $_->description(), $_ ] }
                           sort { ace_sort($a->name, $b->name) } @$ss_list ];
        # sub_pairs were included from $ss->get_subset_names, until RT#275972

        my $row_height = int $size * 1.5;
        my $x = $size;

        my $client_write_access = $self->Client->write_access;

        for (my $i = 0; $i < @$all_pairs; $i++) {
            my ($display_name, $tag, $desc, $ss) = @{$all_pairs->[$i]};
            my $row = $i + 1;
            my $y = $row_height * $row;
            my $ss_write_access = $client_write_access && $ss->write_access;
            $canvas->createText(
            $x, $y,
            -text   => $display_name,
            -font   => $font_def,
            -fill   => ($ss_write_access ? 'DarkGreen' : 'DarkRed'),
            -anchor => 'nw',
            -tags   => ["row=$row", 'SetName', 'SequenceSet=' . $tag],
            );
        }

        $x = ($canvas->bbox('SetName'))[2] + ($size * 2);
        for (my $i = 0; $i < @$all_pairs; $i++) {
            my ($display_name, $tag, $desc, $ss) = @{$all_pairs->[$i]};
            my $row = $i + 1;
            my $y = $row_height * $row;
            $canvas->createText(
            $x, $y,
            -text   => $desc,
            -font   => $helv_def,
            -anchor => 'nw',
            -tags   => ["row=$row", 'SetDescription', 'SequenceSet=' . $tag],
            );
        }

        $x = ($canvas->bbox('SetDescription'))[2] + ($size * 2);
        for (my $i = 0; $i < @$all_pairs; $i++) {
            my ($display_name, $tag, $desc, $ss) = @{$all_pairs->[$i]};
            my $row = $i + 1;
            my $y = $row_height * $row;
            my $ss_write_access = $client_write_access && $ss->write_access;
            $canvas->createText(
            $x, $y,
            -text   => ($ss_write_access ? '' : 'r-o'),
            -font   => $font_def,
            -fill   => ($ss_write_access ? 'DarkGreen' : 'DarkRed'),
            -anchor => 'nw',
            -tags   => ["row=$row", 'SetDescription', 'SequenceSet=' . $tag],
            );
        }

        $x = $size;
        my $max_x = ($canvas->bbox('SetDescription'))[2];
        for (my $i = 0; $i < @$all_pairs; $i++) {
            my ($display_name, $tag, $desc, $ss) = @{$all_pairs->[$i]};
            my $row = $i + 1;
            my $y = $row_height * $row;
            my $rec = $canvas->createRectangle(
            $x, $y, $max_x, $y + $size,
            -fill       => undef,
            -outline    => undef,
            -tags   => ["row=$row", 'SetBackground', 'SequenceSet=' . $tag],
            );
            $canvas->lower($rec, "row=$row");
        }

    } else {
        warn "Empty SequenceSet list returned, probably an error";
    }

    $self->fix_window_min_max_sizes;

    return;
}

sub select_sequence_set {
    my ($self) = @_;

    return if $self->delete_message;
    my $canvas = $self->canvas;
    if (my ($current) = $canvas->find('withtag', 'current')) {
        my( $ss_tag );
        foreach my $tag ($canvas->gettags($current)) {
            if ($tag =~ /^SequenceSet=/) {
                $ss_tag = $tag;
                last;
            }
        }
        if ($ss_tag) {
            $self->highlight($ss_tag);
        }
    } else {
        $self->deselect_all;
    }

    return;
}

sub add_SequenceNotes{
    my ($self, $sn) = @_;
    if ($sn){
        $self->{'_sequence_notes'}->{"$sn"} = $sn;
    }
    return $self->{'_sequence_notes'}->{"$sn"};
}

sub find_cached_SequenceNotes_by_name{
    my ($self, $ss_name) = @_;

    my $seqNotes = $self->{'_sequence_notes'} || {};
    foreach my $hash_id(keys %$seqNotes){
        next unless $seqNotes->{$hash_id};
        my $sn = $seqNotes->{$hash_id};
        my $sn_name = $sn->name();
        next unless $ss_name eq $sn_name;

        return $sn;
    }
    return 0;
}

sub clean_SequenceNotes{
    my ($self) = @_;
    my $seqNotes = $self->{'_sequence_notes'} || {};

    foreach my $hash_id(keys %$seqNotes){
#        warn $hash_id ;
        $seqNotes->{"$hash_id"} = undef;
        delete $seqNotes->{"$hash_id"};
    }
    return 0;
}

sub open_sequence_set {
    my ($self) = @_;

    my ($obj) = $self->list_selected;
    my $canvas = $self->canvas;
    foreach my $tag ($canvas->gettags($obj)) {
        if ($tag =~ /^SequenceSet=([^:]+):([^:]*)/) {
            my ($ss_name, $subset_name) = ($1, $2);

            my $ss = $self->DataSet->get_SequenceSet_by_name($ss_name);

            $self->open_sequence_set_by_ssname_subset($ss_name, $subset_name);
            return 1;
        }
    }
    return;
}

sub open_sequence_set_by_ssname_subset {
    my ($self, $ss_name, $subset_name) = @_;

    my $busy = Tk::ScopedBusy->new($self->canvas->toplevel);
    my $sn = $self->find_cached_SequenceNotes_by_name($ss_name);

    if($sn) {
        $sn->top_window()->deiconify();
        $sn->top_window()->raise();
    } else {
        my $top = $self->top_window()->Toplevel
          (-title => $Bio::Otter::Lace::Client::PFX."Assembly $ss_name");
        my $ss = $self->DataSet->get_SequenceSet_by_name($ss_name);

        $sn = CanvasWindow::SequenceNotes->new($top, 820, 100);
        $sn->name($ss_name);
        $sn->Client($self->Client);
        $sn->SequenceSet($ss);
        $sn->SequenceSetChooser($self);
        $sn->initialise;
        $self->add_SequenceNotes($sn);
    }

    if( $subset_name ) {
        # we assume that whoever calls this has set the subset previously
        #
        # If the SequenceNotes was destroyed & recreated, old subset
        # names will be invalid; code routes for this deleted in
        # RT#275972 but state storage still supports it.
        $sn->draw_subset($subset_name);
    } elsif(! $sn->canvas->find('withtag', 'all')) {
        $sn->draw_all();
    }

    return $sn;
}

# brings up a window for searching for loci / clones
sub search_window{
    my ($self) = @_;

    my $search_window = $self->{'_search_window'};

    unless (defined ($search_window) ){
        my $actual_window = $self->top_window()->Toplevel
          (-title => $Bio::Otter::Lace::Client::PFX.
           'Find Loci, Stable IDs or Clones ('.($self->name).')');
        $self->{'_search_window'} = $search_window = CanvasWindow::SearchWindow->new($actual_window, 500, 60);
        $search_window->Client($self->Client());
        $search_window->DataSet($self->DataSet());
        $search_window->SequenceSetChooser($self);
    }
    $search_window->show_me;
    return $search_window;
}

sub DESTROY {
    my ($self) = @_;

    my ($type) = ref($self) =~ /([^:]+)$/;
    my $name = $self->name;
    warn "Destroying $type $name\n";

    return;
}

1;

__END__

=head1 NAME - CanvasWindow::SequenceSetChooser

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

