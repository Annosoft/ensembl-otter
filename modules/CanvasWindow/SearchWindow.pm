### CanvasWindow::SearchWindow

package CanvasWindow::SearchWindow;

use strict;
use warnings;
use Carp;
use base 'CanvasWindow';
use Hum::Sort 'ace_sort';

sub Client {
    my ($self, $Client) = @_;

    if ($Client) {
        $self->{'_Client'} = $Client;
    }
    return $self->{'_Client'};
}

sub DataSet {
    my ($self, $DataSet) = @_;

    if($DataSet) {
        $self->{_DataSet} = $DataSet;
    }
    return $self->{_DataSet};
}

sub SequenceSetChooser {
    my ($self, $SequenceSetChooser) = @_;

    if ($SequenceSetChooser) {
        $self->{'_SequenceSetChooser'} = $SequenceSetChooser;
    }
    return $self->{'_SequenceSetChooser'};
}

sub found_elements {
    my ($self, $new_elements) = @_;

    if($new_elements) {
        $self->{_found_elements} = $new_elements;
    }

    return $self->{_found_elements} ||= [];
}

sub search_field {
    my ($self, $value) = @_;

    my $scalar = '';
    $self->{_search_field} ||= \$scalar;

    if(defined($value)) {
        ${ $self->{_search_field} } = $value;
    }

    return $self->{_search_field};
}

sub do_search {
    my ($self) = @_;

    $self->top_window->Busy;

    foreach my $oldresult (@{$self->found_elements}) {
        $oldresult->packForget();
    }
    $self->found_elements([]);

    my $qnames = [ split(/[\s,]+/, ${$self->search_field()} ) ];

    my $result_list =
        $self->Client->find_string_match_in_clones(
            $self->DataSet->name, $qnames);
    my $result_hash = { };
    push @{$result_hash->{$_->{'qname'}}}, $_ for @{$result_list};

    for my $qname ( sort { ace_sort($a, $b); } keys %{$result_hash} ) {
        for my $res_hash (@{$result_hash->{$qname}}) {
            $self->_new_result_entry($res_hash);
        }
    }

    my $hit_hash = { };
    for (keys %{$result_hash}) {
        s/^.*://; # remove any prefix
        $hit_hash->{lc $_}++;
    }

    my @qname_fail = grep { ! $hit_hash->{lc $_} } @{$qnames};
    if (@qname_fail) {
        my $text =
            sprintf 'Nothing found for %s',
            join ', or ', map { "'$_'" } sort { ace_sort($a, $b) } @qname_fail;
        $self->_new_result_frame
            ->Label(-text => $text)
            ->pack(-side => 'left', -fill => 'x');
    }

    $self->fix_window_min_max_sizes;
    $self->top_window->Unbusy;

    return;
}

sub _new_result_entry {
    my ($self, $result) = @_;

    my $result_frame = $self->_new_result_frame;
    $self->_result_label_1($result_frame, $result);
    $self->_clones_button($result_frame, $result);
    $self->_result_label_2($result_frame, $result);

    return;
}

sub _new_result_frame {
    my ($self) = @_;

    my $result_frame = $self
        ->{_results_frame}->Frame()
        ->pack(-side => 'top', -fill => 'x');
    push @{$self->found_elements}, $result_frame;

    return $result_frame;
}

sub _result_label_1 {
    my ($self, $result_frame, $result) = @_;

    my ($qname, $qtype) =
        @{$result}{qw( qname qtype )};
    $qtype=~s/_/ /g; # underscores become spaces for readability
    my $label_text = sprintf '%s [%s] found on ', $qname, $qtype;

    $result_frame
        ->Label(-text => $label_text,)
        ->pack(-side => 'left', -fill => 'x');

    return;
}

sub _clones_button {
    my ($self, $result_frame, $result) = @_;

    my ($ssname, $clone_names) =
        @{$result}{qw( assembly components )};
    my $clone_number = scalar(@$clone_names);

    my $button_text = sprintf
        "%d clone%s on %s",
        $clone_number,
        (($clone_number>1) ? 's' : ''),
        $ssname;

    my $button_command =
        sub { $self->_clones_button_command($result); };

    $result_frame
        ->Button(-text => $button_text, -command => $button_command)
        ->pack(-side => 'left');

    return;
}

sub _clones_button_command {
    my ($self, $result) = @_;

    my ($qname, $ssname, $clone_names) =
        @{$result}{qw( qname assembly components )};
    my $ss = $self->DataSet->get_SequenceSet_by_name($ssname);
    my $subset_tag = "${ssname}:Found:${qname}";

    $ss->set_subset($subset_tag, $clone_names);
    $self->SequenceSetChooser->open_sequence_set_by_ssname_subset($ssname, $subset_tag);

    return;
}

sub _result_label_2 {
    my ($self, $result_frame, $result) = @_;

    my $label_text = $self->_clone_names_label($result);
    $result_frame
        ->Label(-text => $label_text)
        ->pack(-side => 'left', -fill => 'x');

    return;
}

sub _clone_names_label {
    my ($self, $result) = @_;

    my $clone_names = $result->{components};
    my $clone_number = scalar(@$clone_names);
    my $center_index = int(($clone_number-1)/2);

    my %show_clone_index = (
        0               => 1,               # always show the first one
        ($center_index==2) ? (1 => 1) : (), # show the second one if there is only one in the gap
        $center_index   => 1,               # always show the middle one
        ($clone_number==5) ? (3 => 1) : (), # show the fourth one if there is only one in the gap
        $clone_number-1 => 1,               # always show the last one
        );

    my @clone_names_to_show = ();
    my $skipped_number = 0;
    foreach my $i (0..scalar(@$clone_names)-1) {
        if($show_clone_index{$i}) {
            if($skipped_number) {
                push @clone_names_to_show, '...';
                $skipped_number = 0;
            }
            my $clone_name = $clone_names->[$i];
            push @clone_names_to_show, $clone_name;
        } else {
            $skipped_number++;
        }
    }

    return sprintf ' [ %s ] ', join ', ', @clone_names_to_show;
}

sub new {
    my ($pkg, @args) = @_;

    my $self = $pkg->SUPER::new(@args);

    $self->{_results_frame} = $self->canvas->Frame();
    $self->canvas->createWindow( 5, 5,
        -window => $self->{_results_frame},
        -anchor => 'nw',
        -tags => 'metaframe',
    );
    $self->canvas->configure(-background => $self->{_results_frame}->cget('-background') );

        # the 'help' message pretends to be one of the search results:
    my $help_frame = $self->{_results_frame}->Frame(
    )->pack(-side => 'top', -fill => 'x');

    push @{$self->found_elements}, $help_frame;

    $help_frame->Label(
        -text => "Search for:\n\n"
                ."* Locus names or synonyms,\n"
                ."* international or EMBL clone names,\n"
                ."* Otter Gene/Transcript/Translation/Exon OTT... stable_IDs,\n"
                ."* EnsEMBL Gene/Transcript/Translation/Exon ENS... stable_IDs,\n"
                ."* CCDS names or\n"
                ."* Pipeline hit names.\n",
        -justify => 'left',
    )->pack(-side => 'top', -fill => 'both');

        # controls are all grouped below:
    my $control_frame = $self->canvas()->toplevel()->Frame->pack(-side => 'top', -fill => 'x');

    my $clear_button = $control_frame->Button(
        -text       => 'Clear',
        -command    => sub { $self->search_field('') },
    )->pack(-side => 'left');

    my $search_entry = $control_frame->Entry(
        -textvariable => $self->search_field(),
        -width => 36,
    )->pack(-side => 'left', -fill => 'x', -expand => 1);

    my $close_button = $control_frame->Button(
        -text       => 'Close',
        -command    => sub { $self->hide_me() },
    )->pack(-side => 'right');

    my $search_button = $control_frame->Button(
        -text    => 'Search',
        -command => sub { $self->do_search(); },
    )->pack(-side => 'right');

        # functional bindings:
    my $window = $self->canvas()->toplevel();
    $search_entry->bind('<Return>', sub { $self->do_search(); } );
    $window->protocol('WM_DELETE_WINDOW', sub { $self->hide_me(); } );

        # anti-disfunctional bindings:
    $search_button->bind('<Destroy>', sub { $self = undef });
    $search_entry->bind('<Destroy>', sub { $self = undef });
    $close_button->bind('<Destroy>', sub { $self = undef });
    $window->bind('<Destroy>', sub { $self = undef });

    $self->fix_window_min_max_sizes;

    return $self;
}

sub show_me {
    my ($self) = @_;

    my $window = $self->canvas()->toplevel();

    $window->deiconify();
    $window->raise();
    $window->focus();

    return;
}

sub hide_me {
    my ($self) = @_;

    my $window = $self->canvas()->toplevel();

    $window->withdraw();

    return;
}

1;

__END__

=head1 NAME - CanvasWindow::SearchWindow

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

