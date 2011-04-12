
### CanvasWindow::SequenceNotes::History

package CanvasWindow::SequenceNotes::History;

use strict;
use warnings;
use Carp;
use Data::Dumper;
use Scalar::Util 'weaken';
use base 'CanvasWindow::SequenceNotes';

### Lots of duplicated code with CanvasWindow::SequenceNotes::Status
sub clone_index {
    my ($self, $index) = @_;

    if (defined $index) {
        $self->{'_clone_index'} = $index;

        # Disable Prev and Next buttons at ends of range
        my $cs_list     = $self->get_CloneSequence_list();
        my $prev_button = $self->prev_button();
        my $next_button = $self->next_button();
        if ($index == 0) {

            # First clone
            $prev_button->configure(-state => 'disabled');
            $next_button->configure(-state => 'normal');
        }
        elsif ($index + 1 >= scalar(@$cs_list)) {

            # Last clone
            $prev_button->configure(-state => 'normal');
            $next_button->configure(-state => 'disabled');
        }
        else {

            # Internal clone
            $prev_button->configure(-state => 'normal');
            $next_button->configure(-state => 'normal');
        }
    }
    return $self->{'_clone_index'};
}

sub SequenceNotes {
    my( $self, $SequenceNotes ) = @_;
    
    if ($SequenceNotes) {
        $self->{'_SequenceNotes'} = $SequenceNotes;
        weaken($self->{'_SequenceNotes'});
    }
    return $self->{'_SequenceNotes'};
}


sub next_button {
    my ($self, $next) = @_;
    if ($next) {
        $self->{'_next_button'} = $next;
    }
    return $self->{'_next_button'};
}

sub prev_button {
    my ($self, $prev) = @_;
    if ($prev) {
        $self->{'_prev_button'} = $prev;
    }
    return $self->{'_prev_button'};
}

sub entry_text_ref {
    my ($self, $entry_ref) = @_;
    if ($entry_ref) {
        $self->{'_entry_ref'} = $entry_ref;
    }
    return $self->{'_entry_ref'};
}

sub current_clone {
    my ($self, $clone) = @_;

    my $cs_list = $self->get_CloneSequence_list();
    my $i       = $self->clone_index;
    my $cs      = @$cs_list[$i];

    my $title = sprintf "otter: Note History of %d %s  (%s)", $i + 1,
      $cs->accession . '.' . $cs->sv, $cs->clone_name;
    $self->canvas->toplevel->title($title);
    return $cs;
}

sub draw {
    my ($self) = @_;
    my $current_clone = $self->current_clone();
    $self->SUPER::draw();
    if ($current_clone->get_lock_status) {
        my $canvas = $self->canvas();
        my $size   = $self->font_size();
        my $list   = $self->get_rows_list();
        my $row_t  = 'row=' . (@$list + 1);
        my $font   = [ 'Helvetica', $size, 'normal' ];
        my $locker = $current_clone->get_lock_as_CloneLock()->author->name;
        my $host   = $current_clone->get_lock_as_CloneLock()->hostname;

        my $c_name = $current_clone->clone_name;

        my @bbox      = $canvas->bbox('all');
        my $max_vis_y = $bbox[3] + $size;
        $canvas->createText(
            $size, $max_vis_y,
            -anchor => 'nw',
            -font   => $font,
            -tags   => ['lock_status'],
            -fill   => 'red',
            -text   =>
              qq(Clone '$c_name' is locked by user '$locker' on host '$host')
        );
        $self->fix_window_min_max_sizes();
    }
    return;
}

sub initialise {
    my ($self) = @_;

    # Use a slightly smaller font so that more info fits on the screen
    $self->font_size(12);

    my $ss = $self->SequenceSet
      or confess "No SequenceSet or SequenceNotes attached";

    my $write = $ss->write_access;

    my $canvas = $self->canvas;
    my $top    = $canvas->toplevel;

    my $button_frame = $top->Frame;
    $button_frame->pack(-side => 'top',);

    my ($comment, $comment_label, $set_note);

    if ($write) {
        $comment_label = $button_frame->Label(
            -text => 'Note text:',    #
        );
        $comment_label->pack(-side => 'left',);
        my $text = '';
        $self->entry_text_ref(\$text);
        $comment = $button_frame->Entry(
            -width        => 40,
            -font         => [ 'Helvetica', $self->font_size, 'normal' ],
            -textvariable => $self->entry_text_ref,
        );
        $comment->pack(-side => 'left',);

        # Remove Control-H binding from Entry
        $comment->bind(ref($comment), '<Control-h>', '');
        $comment->bind(ref($comment), '<Control-H>', '');

        $comment->bind('<Return>', sub { $self->update_db_comment });
        my $update_comment = sub {
            $self->update_db_comment;
        };
        $set_note =
          $self->make_button($button_frame, 'Set note', $update_comment, 0);
        $top->bind('<Control-s>', $update_comment);
        $top->bind('<Control-S>', $update_comment);

        $self->bind_item_selection($canvas, $comment);
    }

    my $next_clone = sub {
        my $cs_list = $self->get_CloneSequence_list();
        my $cur_idx = $self->clone_index();
        $self->clone_index(++$cur_idx) unless $cur_idx + 1 >= scalar(@$cs_list);
        $self->draw();
    };
    my $prev_clone = sub {
        my $cs_list = $self->get_CloneSequence_list();
        my $cur_idx = $self->clone_index();
        $self->clone_index(--$cur_idx) if $cur_idx;
        $self->draw();
    };

    my $prev = $self->make_button($button_frame, 'Prev. Clone', $prev_clone, 0);
    my $next = $self->make_button($button_frame, 'Next Clone',  $next_clone, 0);
    $top->bind('<Control-p>', $prev_clone);
    $top->bind('<Control-P>', $prev_clone);
    $top->bind('<Control-n>', $next_clone);
    $top->bind('<Control-N>', $next_clone);

    $self->prev_button($prev);
    $self->next_button($next);

    $self->make_button($button_frame, 'Close', sub { $top->withdraw }, 0);

    # It all gets cleared up twice with it.
    # And I think normal behaviour without it.
    $self->bind_close_window($top);

    $canvas->Tk::bind('<Destroy>', sub { $self = undef });
    return $self;
}

sub get_rows_list {
    my ($self)    = @_;
    my $clone     = $self->current_clone;
    my $note_list = $clone->get_all_SequenceNotes;
    return $note_list;
}

sub empty_canvas_message {
    my ($self) = @_;
    my $clone = $self->current_clone;
    return "No History for sequence "
      . $clone->contig_name . "  "
      . $clone->clone_name;
}

#already have this method in SequenceNotes.pm, but perl doesnt seem to like inheritance with anonymous subroutines
sub _column_write_text {
    my ($canvas, @args) = @_;
    $canvas->createText(@args);
    return;
}

sub column_methods {
    my ($self) = @_;
    my $helv = [ 'helvetica', $self->font_size, 'normal' ];
    my $norm = $self->font_fixed;
    my $bold = $self->font_fixed_bold;
    unless (ref($self->{'_column_methods'}) eq 'ARRAY') {
        my $calling_method = \&_column_write_text;
        my $methods        = [
            [
                $calling_method,
                sub {
                    my $sn   = shift;
                    my $time = $sn->timestamp;
                    my ($year, $month, $mday) = (localtime($time))[ 5, 4, 3 ];
                    my $txt = sprintf "%04d-%02d-%02d", 1900 + $year,
                      1 + $month, $mday;
                    return {
                        -text => $txt,
                        -font => $norm,
                        -tags => ['searchable']
                    };
                  }
            ],
            [
                $calling_method,
                sub {

                    # Use closure for font definition
                    my $note   = shift;
                    my $author = $note->author;
                    return {
                        -text => "$author",
                        -font => $bold,
                        -tags => ['searchable']
                    };
                  }
            ],
            [
                $calling_method,
                sub {

                    # Use closure for font definition
                    my $note = shift;
                    return {
                        -text => $note->text,
                        -font => $helv,
                        -tags => ['searchable']
                    };
                  }
            ]
        ];
        $self->{'_column_methods'} = $methods;
    }
    return $self->{'_column_methods'};
}

sub bind_item_selection {
    my ($self, $canvas, $comment_entry) = @_;

    $canvas->configure(-selectbackground => 'gold');
    $canvas->CanvasBind(
        '<Button-1>',
        sub {
            return if $self->delete_message;
            $self->deselect_all_selected_not_current();
            $self->toggle_current;
            $self->get_message;
            if (defined $comment_entry) {
                $comment_entry->focus;
                my $length = length($comment_entry->get);

                #$comment_entry->selectionRange(0 , $length );
                $comment_entry->icursor($length);
            }

        }
    );
    $canvas->CanvasBind('<Destroy>', sub { $self = undef });
    $comment_entry->bind('<Destroy>', sub { $self = undef });

    return;
}

sub toggle_selection {
    my ($self, $obj) = @_;

    my $canvas = $self->canvas;
    my $is_selected = grep { $_ eq 'selected' } $canvas->gettags($obj);
    my ($new_colour);
    if ($is_selected) {
        $new_colour = '#ccccff';
        $canvas->dtag($obj, 'selected');
    }
    else {
        $new_colour = '#ffcccc';
        $canvas->addtag('selected', 'withtag', $obj);
    }
    $canvas->itemconfigure($obj, -fill => $new_colour,);

    return;
}

sub get_row_id {
    my ($self) = @_;
    my $row_tag = $self->get_current_row_tag or return;
    my ($index) = $row_tag =~ /row=(\d+)/;
    return $index;
}

sub get_message {
    my ($self)  = @_;
    my ($index) = $self->get_row_id;
    my $text    = $self->indexed_note_text($index);
    ${ $self->entry_text_ref() } = $text;
    return;
}

sub indexed_note_text {
    my ($self, $index, $text) = @_;
    return '' unless defined $index;
    $text = $self->current_clone->get_all_SequenceNotes->[$index]->text;
    return $text;
}

sub update_db_comment {
    my ($self) = @_;

    #gets the string from the varibale reference stored
    my $new_string = ${ $self->entry_text_ref } || '-';
    
    my $dataset    = $self->SequenceSetChooser->DataSet;
    unless ($dataset) {
        warn
"no Dataset object for this history window.\nIt is not possible to update the comment.";
        return;
    }
    unless ($self->selected_CloneSequence_indices) {
        $self->message('you need to select a note to update');
        $self->top_window->Unbusy;
        return;
    }

    my ($index, @extra_indices) = @{ $self->selected_CloneSequence_indices };
    if (@extra_indices > 0) {

        # should only be possible to select 1 index on this canvas
        confess
"ok we have these rows selected @extra_indices \nsomething wrong there! should only be able to select 1";
    }

    $self->top_window->Busy;
    my $clone_sequence   = $self->current_clone;
    my $current_seq_note = $clone_sequence->get_all_SequenceNotes->[$index];

    my $cl = $self->Client();

    # check that author is valid to update note
    my $note_author  = $current_seq_note->author;
    my $current_user = $cl->author;
    if ($note_author eq $current_user) {

        ###confirm that the user wants to update the entry
        my $confirm = $self->canvas->toplevel->messageBox(
            -title   => 'otter: Update Sequence Note',
            -message =>
              "Please Confirm that you wish to update this note in the database",
            -type => 'OKCancel'
        );
        return if ($confirm eq 'Cancel');

        $current_seq_note->text($new_string);    #change text

        $cl->change_sequence_note(
            $dataset->name(),
            $clone_sequence->contig_name(),
            $current_seq_note,
        );

        $self->SequenceNotes->draw;
        $self->draw;
    }
    else {
        $self->top_window->messageBox(
            -title   => 'otter: Sorry',
            -message =>
"Only the original author, $note_author, can update these comments\nYou are currently logged on as $current_user",
            -type => 'OK'
        );
    }
    $self->top_window->Unbusy;

    return;
}

sub DESTROY {
    my ($self) = @_;
    my $idx = $self->clone_index();
    warn "Destroying CanvasWindow::SequenceNotes::History with idx $idx\n";
    return;
}

1;

__END__

=head1 NAME - CanvasWindow::SequenceNotes::History

=head1 AUTHOR

Colin Kingswood <email> ck2@sanger.ac.uk

