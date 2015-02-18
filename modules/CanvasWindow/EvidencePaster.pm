
### CanvasWindow::EvidencePaster

package CanvasWindow::EvidencePaster;

use strict;
use warnings;
use Bio::Otter::Log::Log4perl 'logger';
use Readonly;
use Scalar::Util 'weaken';
use Hum::Sort 'ace_sort';
use Try::Tiny;
use Bio::Otter::Lace::Client;
use Bio::Otter::Lace::OnTheFly::Transcript;
use Bio::Otter::UI::TextWindow::TranscriptAlign;
use Bio::Vega::Evidence::Types qw(evidence_is_sra_sample_accession);
use Tk::ScopedBusy;

use base qw{
    CanvasWindow
    Bio::Otter::UI::OnTheFlyMixin
    };

Readonly my $EVI_TAG     => 'IsEvidence';
Readonly my $CURRENT_EVI => "current&&${EVI_TAG}";

sub initialise {
    my ($self, $evidence_hash) = @_;

    my $canvas = $self->canvas;
    my $top = $canvas->toplevel;
    $top->configure(-title => $Bio::Otter::Lace::Client::PFX.'Evidence');

    my $action_frame = $top->Frame->pack(
        -side => 'top',
        -fill => 'x',
        );
    {
        my $otf_frame = $action_frame->LabFrame(
                Name => 'otf',
                -label  => 'On The Fly Alignment',
                -border => 3,
            )
            ->pack(
                -side => 'top',
                -fill => 'x',
            );
        {
            my $otf_ts_frame = $otf_frame->LabFrame(
                    Name    => 'otf_ts',
                    -label  => 'Spliced Transcript',
                    -border => 3,
                )
                ->pack(
                    -side   => 'left',
                    -fill   => 'x',
                    -expand => 1,
                );

            my $align = sub {

                $self->align_button->configure(-state => 'disabled');

                try {
                    $self->align_to_transcript;
                }
                catch {
                    my $err = $_;
                    $self->top->messageBox(
                        -title   => $Bio::Otter::Lace::Client::PFX.'Error',
                        -icon    => 'warning',
                        -message => 'Error running align to transcript: ' . $err,
                        -type    => 'OK',
                        );
                    $self->logger->error('Error running align_to_transcript: ', $err);
                };

                $self->align_button->configure(-state => 'normal');
            };

            $top->bind('<Control-t>', $align);
            $top->bind('<Control-T>', $align);
            my $align_button = $otf_ts_frame->Button(
                    -text    => 'Align',
                    -command => $align,
                    -state   => 'disabled',
                )
                ->pack(
                    -side   => 'top',
                    -anchor => 'w'
                );
            $self->align_button($align_button);

            my $clear_otf = $otf_ts_frame->Checkbutton(
                    -variable => \$self->{_clear_existing},
                    -text     => 'Clear existing',
                    -anchor   => 'w',
                    -state    => 'disabled',
                )
                ->pack(
                    -side   => 'top',
                    -anchor => 'w'
                );
            $self->clear_otf_checkbutton($clear_otf);
        }

        {
            my $otf_gen_frame = $otf_frame->LabFrame(
                    Name    => 'otf_gen',
                    -label  => 'Genomic',
                    -border => 3,
                )
                ->pack(
                    -side   => 'right',
                    -fill   => 'both',
                    -expand => 1,
                );

            my $launch = sub { $self->SessionWindow->run_exonerate( clear_accessions => 1 ); };
            $top->bind('<Control-g>', $launch);
            $top->bind('<Control-G>', $launch);
            my $launch_button = $otf_gen_frame->Button(
                    -text    => 'Open',
                    -command => $launch,
                    -state   => 'disabled',
                )
                ->pack(
                    -side   => 'top',
                    -anchor => 'w'
                );
            $self->genomic_otf_button($launch_button);
        }
    } # $otf_frame

    {
        my $dotter_frame = $action_frame->LabFrame(
                Name    => 'dotter',
                -label  => 'Dotter',
                -border => 3,
            )
            ->pack(
                -side => 'top',
                -fill => 'x',
            );

        my $dotter = sub { $self->dotter_to_transcript; };
        $top->bind('<Control-period>',  $dotter);
        $top->bind('<Control-greater>', $dotter);
        my $dotter_button = $dotter_frame->Button(
            -text    => 'Dotter',
            -command => $dotter,
            -state   => 'disabled',
            )
            ->pack(-side => 'left');
        $self->dotter_button($dotter_button);
    }

    {
        my $button_frame = $top->Frame(
            Name => 'button_frame',
            -border => 2,
        )->pack(
            -side => 'top',
            -fill => 'x',
            );

        my $draw = sub{ $self->draw_evidence };
        $top->bind('<Control-u>', $draw);
        $top->bind('<Control-u>', $draw);
        #$button_frame->Button(
        #    -text => 'Update',
        #    -command => $draw,
        #    )->pack(-side => 'left');

        my $paste = sub{ $self->paste_type_and_name };
        $top->bind('<Control-v>', $paste);
        $top->bind('<Control-V>', $paste);
        $top->bind('<Button-2>',  $paste);
        $button_frame->Button(
            -text => 'Paste',
            -command => $paste,
            )->pack(-side => 'left');

        my $delete = sub{ $self->remove_selected_from_evidence_list };
        $top->bind('<BackSpace>', $delete);
        $top->bind('<Delete>',    $delete);
        $top->bind('<Control-x>', $delete);
        $top->bind('<Control-X>', $delete);
        $button_frame->Button(
            -text => 'Delete',
            -command => $delete,
            )->pack(-side => 'left', -padx => 4);

        my $close_window = sub{ $top->withdraw; };
        $top->bind('<Control-w>',           $close_window);
        $top->bind('<Control-W>',           $close_window);
        $top->protocol('WM_DELETE_WINDOW',  $close_window);
        $button_frame->Button(
            -text => 'Close',
            -command => $close_window,
            )->pack(-side => 'right');
    }

    my $select_all = sub{ $self->select_all };
    $top->bind('<Control-a>', $select_all);
    $top->bind('<Control-A>', $select_all);
    $canvas->SelectionHandle( sub{ $self->selected_text_to_clipboard(@_) });

    $canvas->Tk::bind('<Button-1>',         sub{ $self->left_button_handler });
    $canvas->Tk::bind('<Control-Button-1>', sub{ $self->control_left_button_handler });
    $canvas->Tk::bind('<Shift-Button-1>',   sub{ $self->shift_left_button_handler });

    $canvas->Tk::bind('<Destroy>', sub{ $self = undef });


    $self->_colour_init;
    $self->evidence_hash($evidence_hash);
    $self->draw_evidence;

    return;
}

sub TranscriptWindow {
    my ($self, $TranscriptWindow) = @_;

    if ($TranscriptWindow) {
        $self->{'_TranscriptWindow'} = $TranscriptWindow;
        weaken($self->{'_TranscriptWindow'});
    }
    return $self->{'_TranscriptWindow'};
}

sub SessionWindow { # method used by Bio::Otter::UI::TextWindow
    my ($self) = @_;
    return $self->TranscriptWindow->SessionWindow;
}

sub align_button {
    my ($self, $align_button) = @_;

    if ($align_button) {
        $self->{'_align_button'} = $align_button;
    }
    return $self->{'_align_button'};
}

sub genomic_otf_button {
    my ($self, $genomic_otf_button) = @_;

    if ($genomic_otf_button) {
        $self->{'_genomic_otf_button'} = $genomic_otf_button;
    }
    return $self->{'_genomic_otf_button'};
}

sub clear_existing {
    my ($self) = @_;
    return $self->{'_clear_existing'};
}

sub clear_otf_checkbutton {
    my ($self, $clear_otf_checkbutton) = @_;

    if ($clear_otf_checkbutton) {
        $self->{'_clear_otf_checkbutton'} = $clear_otf_checkbutton;
    }
    return $self->{'_clear_otf_checkbutton'};
}

sub dotter_button {
    my ($self, $dotter_button) = @_;

    if ($dotter_button) {
        $self->{'_dotter_button'} = $dotter_button;
    }
    return $self->{'_dotter_button'};
}

sub _colour_init {
    my ($self) = @_;

    return $self->SessionWindow->colour_init($self->top_window);
}

sub align_enable {
    my ($self, $enable) = @_;
    my $state = $enable ? 'normal' : 'disabled';
    $self->align_button->configure( -state => $state );
    $self->genomic_otf_button->configure( -state => $state );
    $self->clear_otf_checkbutton->configure( -state => $state );
    return;
}

sub dotter_enable {
    my ($self, $enable) = @_;
    my $state = $enable ? 'normal' : 'disabled';
    $self->dotter_button->configure( -state => $state );
    return;
}

sub control_buttons {
    my ($self) = @_;

    my $sel_count = scalar($self->list_selected);
    $self->align_enable($sel_count);
    $self->dotter_enable($sel_count == 1);

    return;
}

sub left_button_handler {
    my ($self) = @_;

    return if $self->delete_message;
    $self->deselect_all;
    $self->control_left_button_handler;

    return;
}

sub control_left_button_handler {
    my ($self) = @_;

    my $canvas = $self->canvas;

    my ($obj)  = $canvas->find('withtag', $CURRENT_EVI)
      or return;

    if ($self->is_selected($obj)) {
        $self->remove_selected($obj);
    } else {
        $self->highlight($obj);
    }

    $self->control_buttons;

    return;
}

sub shift_left_button_handler {
    my ($self) = @_;

    my $canvas = $self->canvas;

    return unless $canvas->find('withtag', $CURRENT_EVI);

    $self->extend_highlight($EVI_TAG);

    return;
}

sub select_all {
    my ($self) = @_;

    my $canvas = $self->canvas;

    my @all      = $canvas->find('withtag', $EVI_TAG);
    my @selected = $self->list_selected;

    if (scalar(@all) == scalar(@selected)) {
        $self->deselect_all;
    } else {
        $self->highlight(@all);
    }

    return;
}

sub evidence_hash {
    my ($self, $evidence_hash) = @_;

    if ($evidence_hash) {
        $self->{'_evidence_hash'} = $evidence_hash;
    }
    return $self->{'_evidence_hash'};
}

sub remove_selected_from_evidence_list {
    my ($self) = @_;

    my $canvas = $self->canvas;
    my $evi    = $self->evidence_hash;
    foreach my $obj ($self->list_selected) {
        my ($type) = $canvas->gettags($obj);
        my ($name) = $canvas->itemcget($obj, 'text');
        my $name_list = $evi->{$type} or die "No list with key '$type' in evidence hash";
        for (my $i = 0; $i < @$name_list; $i++) {
            if ($name_list->[$i] eq $name) {
                splice(@$name_list, $i, 1);
                last;
            }
        }
    }
    $self->draw_evidence;

    return;
}

sub draw_evidence {
    my ($self) = @_;

    $self->deselect_all;

    my $evidence_hash = $self->evidence_hash;
    my $canvas = $self->canvas;
    $canvas->delete('all');

    my ($norm, $size, $row_height) =
      $self->named_font('mono', 'linespace', 'linegap');
    my $bold = $self->named_font('listbold');
    my $type_pad = $row_height / 2;
    my $x = $size;

    my $y = 0;
    foreach my $type ( @Bio::Vega::Evidence::Types::VALID ) {
        my $name_list = $evidence_hash->{$type} or next;
        next unless @$name_list;

        $canvas->createText(0, $y,
            -anchor => 'ne',
            -text   => $type,
            -font   => $bold,
            );

        foreach my $text (@$name_list) {
            $canvas->createText($x, $y,
                -anchor => 'nw',
                -text   => $text,
                -font   => $norm,
                -tags   => [$type, $EVI_TAG],
                );
            $y += $row_height;
        }

        $y += $type_pad
    }

    $self->canvas->toplevel->configure
      (-title => $Bio::Otter::Lace::Client::PFX.
       'Evidence ' . $self->TranscriptWindow->SubSeq->name);
    $self->fix_window_min_max_sizes;

    return;
}

sub paste_type_and_name {
    my ($self) = @_;

    if (my $clip = $self->get_clipboard_text) {
        $self->add_evidence_from_text($clip);
    }

    return;
}

sub add_evidence_from_text {
    my ($self, $text) = @_;

    my $busy = Tk::ScopedBusy->new($self->top_window); # Because it may involve a HTTP request

    my $cache = $self->SessionWindow->AceDatabase->AccessionTypeCache;

    my $acc_list = $cache->accession_list_from_text($text);
    $cache->populate($acc_list);
    if (my $clip_evi = $cache->evidence_type_and_name_from_accession_list($acc_list)) {
        $self->add_evidence_type_name_hash($clip_evi);
    }

    return;
}

sub add_evidence_type_name_hash {
    my ($self, $clip_evi) = @_;

    foreach my $type (keys %$clip_evi) {
        my $clip_list = $clip_evi->{$type};
        my $evi = $self->evidence_hash;
        my $list = $evi->{$type} ||= [];

        # Hmm, perhaps evidence hash should be two level hash?
        my %uniq = map { $_ => 1 } (@$list, @$clip_list);
        @$list = sort {ace_sort($a, $b)} keys %uniq;
    }
    $self->draw_evidence;
    foreach my $type (keys %$clip_evi) {
        my $clip_list = $clip_evi->{$type};
        foreach my $name (@$clip_list) {
            $self->highlight_evidence_by_type_name($type, $name);
        }
    }

    return;
}

sub highlight_evidence_by_type_name {
    my ($self, $type, $name) = @_;

    my $canvas = $self->canvas;
    foreach my $obj ($canvas->find('withtag', $type)) {
        my $text = $canvas->itemcget($obj, 'text');
        if ($text eq $name) {
            $self->highlight($obj);
            last;
        }
    }

    return;
}

sub highlight {
    my ($self, @args) = @_;

    $self->SUPER::highlight(@args);
    $self->canvas->SelectionOwn(
        -command    => sub{ $self->deselect_all },
        );
    $self->control_buttons;
    weaken $self;

    return;
}

sub deselect_all {
    my ($self) = @_;

    $self->SUPER::deselect_all;
    $self->control_buttons;

    return;
}

sub get_selected_accessions {
    my ($self) = @_;
    my $canvas = $self->canvas;

    my @accessions;
    foreach my $sel ($self->list_selected) {
        my ($type) = $canvas->gettags($sel);
        my $name   = $canvas->itemcget($sel, 'text');
        my @no_prefixes = Hum::ClipboardUtils::accessions_from_text($name);
        # Temporary fix to eliminate SRA accessions from dotter / OTF vs transcript.
        foreach my $acc ( @no_prefixes ) {
            push @accessions, $acc unless evidence_is_sra_sample_accession($acc);
        }
    }

    return @accessions;
}

sub align_to_transcript {
    my ($self) = @_;

    my @accessions = $self->get_selected_accessions;

    my $ts_win = $self->TranscriptWindow;
    my $cdna   = $ts_win->check_get_mRNA_Sequence;
    return unless $cdna;

    my $vega_transcript = $ts_win->ensEMBL_Transcript_from_tk;

    # ensure vega transcript has a DBid and slice
    $ts_win->store_Transcript($vega_transcript);

    my $top = $self->canvas->toplevel;

    my $otf = Bio::Otter::Lace::OnTheFly::Transcript->new({

        accessions => \@accessions,

        vega_transcript => $vega_transcript,

        problem_report_cb => sub { $self->problem_box($top, 'Evidence Selected', @_) },
        long_query_cb     => sub { $self->long_query_confirm($top, @_)  },

        accession_type_cache => $self->SessionWindow->AceDatabase->AccessionTypeCache,

        logic_names          => $self->SessionWindow->OTF_Transcript_columns,
        clear_existing       => $self->clear_existing,
        });

    my $logger = $self->logger;
    $logger->info("Found ", scalar( @{$otf->confirmed_seqs->seqs} ), " sequences");

    my $ts_file = $otf->target_fasta_file;
    $logger->info("Wrote transcript sequence to ${ts_file}");

    if ($self->clear_existing) {
        $self->SessionWindow->delete_featuresets(@{$otf->logic_names});
    }

    my $key = "$otf";
    $self->SessionWindow->register_exonerate_callback($key, $self, \&Bio::Otter::UI::OnTheFlyMixin::exonerate_callback);

    $otf->prep_and_store_request_for_each_type($self->SessionWindow, $key);
    return;
}

sub display_request_feedback {
    my ($self, $request) = @_;
    $self->logger->debug(sprintf('OTF result for [%d,%s]', $request->id, $request->logic_name));
    if ($request->n_hits) {
        $self->alignment_window($request->raw_result, $request->logic_name);
    }
    $self->report_missed_hits($self, $request, 'spliced transcript');
    return;
}

sub dotter_to_transcript {
    my ($self) = @_;

    my @accessions = $self->get_selected_accessions;

    return $self->TranscriptWindow->launch_dotter(@accessions);
}

sub alignment_window {
    my ($self, $raw_result, $type) = @_;

    $self->{_alignment_window} ||= {};
    my $window = $self->{_alignment_window}->{$type};

    unless ($window) {
        $window = Bio::Otter::UI::TextWindow::TranscriptAlign->new($self, $type);
    }

    $window->update_alignment($raw_result);
    return;
}

sub delete_alignment_window {
    my ($self, $type) = @_;
    $self->{_alignment_window}->{$type} = undef;
    return;
}

sub DESTROY {
    my ($self) = @_;
    warn "Destroying ", ref($self), "\n";
    return;
}

1;

__END__

=head1 NAME - CanvasWindow::EvidencePaster

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

