
### EditWindow::Exonerate

package EditWindow::Exonerate;

use strict;
use warnings;

use Bio::Otter::Log::Log4perl 'logger';
use Readonly;
use Try::Tiny;

use Bio::Otter::Lace::OnTheFly::Genomic;
use Bio::Vega::Evidence::Types qw( evidence_is_sra_sample_accession seq_is_protein );
use Bio::Otter::Lace::Client;
use Hum::Pfetch;
use Hum::FastaFileIO;
use Hum::ClipboardUtils qw{ accessions_from_text };
use Hum::Sort qw{ ace_sort };
use Tk::LabFrame;
use Tk::Checkbutton;
use Tk::Radiobutton;

use base qw{
    EditWindow
    Bio::Otter::UI::OnTheFlyMixin
    };

my $BEST_N            = 1;
my $MAX_INTRON_LENGTH = 200000;
my $MAX_QUERY_LENGTH  = 10000;

my $REGION_TARGET_ALL     = 'all';
my $REGION_TARGET_MARKED  = 'marked';
my $REGION_TARGET_DEFAULT = $REGION_TARGET_MARKED;

my $MASK_TARGET_NONE    = 'none';
my $MASK_TARGET_SOFT    = 'soft';
my $MASK_TARGET_DEFAULT = $MASK_TARGET_NONE;

my $INITIAL_DIR = (getpwuid($<))[7];

sub initialise {
    my ($self) = @_;

    my @frame_pack = (-side => 'top', -fill => 'x');
    my @frame_expand = (-side => 'top', -fill => 'both', -expand => 1);

    my $top = $self->top;

    ### Query frame
    my $query_frame = $top->LabFrame(
        Name       => 'query',
        -label     => 'Query sequences',
        -border    => 3,
    )->pack(@frame_expand);

    ## Accession entry box
    my $match_frame = $query_frame->Frame(-border => 3)->pack(@frame_pack);
    $match_frame->Label(
        -text   => 'Accessions:',
        -anchor => 's',
    )->pack(-side => 'left');
    $self->match($match_frame->Entry->pack(-side => 'left', -expand => 1, -fill => 'x'));

    my $update = sub {
        $self->accessions_from_clipboard;
    };
    $match_frame->Button(
        -text      => 'Fetch from clipboard',
        -underline => 0,
        -command   => $update,
    )->pack(-side => 'left', -padx => 4);
    $match_frame->Button(
        -text      => 'Clear',
        -underline => 0,
        -command   => sub { $self->clear_accessions },
    )->pack(-side => 'left');
    $top->bind('<Control-u>', $update);
    $top->bind('<Control-U>', $update);

    ## Fasta file entry box
    my $fname;
    my $file_frame = $query_frame->Frame(-border => 3)->pack(@frame_pack);
    $file_frame->Label(
        -text   => 'Fasta file:',
        -anchor => 's',
    )->pack(-side => 'left');

    $self->fasta_file($file_frame->Entry(-textvariable => \$fname)->pack(-side => 'left', -expand => 1, -fill => 'x', -padx => 4));

    $file_frame->Button(
        -text    => 'Browse...',
        -command => sub {
            $fname = $top->getOpenFile(
                -title      => $Bio::Otter::Lace::Client::PFX.'Choose Fasta File',
                -initialdir => $INITIAL_DIR,
                -filetypes  => [

                    # ['Fasta Files'  => [qw{ .seq .pep .dna .fasta .fa }]],
                    # ['All Files'    => '*'],

                    # Do not want to show hidden files.
                    [
                        'Fasta Files (*.seq,*.pep,*.dna,*.fasta,*.fa)' => sub {
                            my ($widget, $file, $dir) = @_;

                            # Match non-hidden files which end with one of our extensions
                            return $file =~ /^[^\.].*\.(seq|pep|dna|fasta|fa)$/;
                          }
                    ],
                    [
                        'All Files (*)' => sub {
                            my ($widget, $file, $dir) = @_;

                            # Match non-hidden files
                            return $file !~ /^\./;
                          }
                    ],
                ],

                # This option is present in our patched Tk::FBox
                # module which you can find in our Tk directory.
                -sortcmd => sub { ace_sort(@_) },
            );
            if ($fname) {
                if (my ($dir) = $fname =~ m{^(.+?)[^/]+$}) {

                    # $self->logger->warn("Setting inital dir to '$dir'");
                    $INITIAL_DIR = $dir;
                }
            }

            # Show the end of the Entry, so that when the file path is long the
            # user can see the name of the file which was chosen.
            $self->fasta_file->xviewMoveto(1);
        }
    )->pack(-side => 'left');

    ## Sequence text box
    my $txt_frame = $query_frame->Frame(-border => 3)->pack(@frame_expand);
    $txt_frame->Label(
        -text   => 'Fasta sequence:',
        -anchor => 'w',
    )->pack(@frame_pack);
    $self->fasta_txt(
        $txt_frame->Scrolled(
            "Text",

            # -background => 'white',
            -height     => 12,
            -width      => 62,
            -scrollbars => 'se',
            -font       => $self->SessionWindow->font_fixed,
          )->pack(@frame_expand)
    );

    ### Input
    my $input_frame = $top->Frame(Name => 'input')->pack(@frame_pack);

    my $input_widgets = [
        [ '_region_target', $REGION_TARGET_DEFAULT, 'Region',
          [
           [ 'All',           $REGION_TARGET_ALL    ],
           [ 'Marked region', $REGION_TARGET_MARKED ],
          ] ],
        [ '_mask_target', $MASK_TARGET_DEFAULT, 'Repeat masking',
          [
           [ 'Unmasked',    $MASK_TARGET_NONE ],
           [ 'Soft masked', $MASK_TARGET_SOFT ],
          ] ],
        ];

    for (@{$input_widgets}) {
        my ($key, $default, $name, $button_list) = @{$_};
        $self->{$key} = $default;
        my $button_list_frame =
            $input_frame->LabFrame(
                Name    => $key,
                -label  => $name,
                -border => 3,
            )->pack(-side => 'left', -expand => 1, -fill => 'x');
        my $variable = \($self->{$key});
        for (@{$button_list}) {
            my ($text, $value) = @{$_};
            $button_list_frame->Radiobutton(
                -variable => $variable,
                -text     => $text,
                -value    => $value,
                -offrelief  => 'flat',
                )->pack(-side => 'left', -expand => 1, -fill => 'x');
        }
    }

    ### Parameters
    my $param_frame = $top->LabFrame(
        Name       => 'param',
        -label     => 'Alignment parameters',
        -border    => 3,
    )->pack(@frame_pack);

    # bestn parameter
    Tk::grid(
        $param_frame->Label(
            -text   => 'Number of transcript alignments to report (0 for all):',
            -anchor => 'e',
            -padx   => 6,
        ),
        $self->bestn(
            $param_frame->Entry(
                -width   => 9,
                -justify => 'right',
            )),
        );
    $self->set_entry('bestn', $BEST_N);

    # max intron length parameter
    Tk::grid(
        $param_frame->Label(
            -text   => 'Maximum intron length:',
            -anchor => 'e',
            -padx   => 6,
        ),
        $self->max_intron_length(
            $param_frame->Entry(
                -width   => 9,
                -justify => 'right',
            )),
        );
    $self->set_entry('max_intron_length', $MAX_INTRON_LENGTH);

    my $cb_frame = $top->Frame->pack(
        -fill => 'x',
        -side => 'top',
        );
    $cb_frame->Checkbutton(
        -variable => \$self->{_clear_existing},
        -text     => 'Clear existing OTF alignments',
        -anchor   => 'w',
    )->pack(-side => 'top');

    ### Commands
    my $button_frame = $top->Frame(
        Name    => 'button',
        -border => 2,
        )->pack(@frame_pack);
    my $doing_launch = 0;       # captured by closure...
    my $launch       = sub {
        if ($doing_launch) {
            $self->logger->warn("Already launched, ignoring click.");
            return;
        }
        $doing_launch = 1;
        try {
            $self->launch_exonerate;
        }
        catch {
            my $err = $_;
            $self->top->messageBox(
                -title   => $Bio::Otter::Lace::Client::PFX.'Error',
                -icon    => 'warning',
                -message => 'Error running exonerate: ' . $err,
                -type    => 'OK',
            );
            $self->logger->error('Error running exonerate: ', $err);
        };
        $doing_launch = 0;
    };
    $button_frame->Button(
        -text      => 'Launch',
        -underline => 0,
        -command   => $launch,
    )->pack(-side => 'left');
    $top->bind('<Control-l>', $launch);
    $top->bind('<Control-L>', $launch);

    # Progress
    $button_frame->Label(
        -width        => 45,
        -height       =>  1,
        -textvariable => \$self->{_progress},
    )->pack(-side => 'left', -expand => 1, -fill => 'x', -padx => 6);

    # Manage window closes and destroys
    my $close_window = sub { $top->withdraw };
    $button_frame->Button(
        -text    => 'Close',
        -command => $close_window,
    )->pack(-side => 'right');
    $top->bind('<Control-w>', $close_window);
    $top->bind('<Control-W>', $close_window);
    $top->protocol('WM_DELETE_WINDOW', $close_window);
    $top->bind('<Destroy>', sub { $self = undef; });
    $self->set_minsize;

    $self->colour_init;

    return;
}

sub update_from_SessionWindow {
    my ($self) = @_;
    $self->accessions_from_clipboard;
    my $top = $self->top;
    $top->deiconify;
    $top->raise;
    return;
}

sub query_Sequence {
    my ($self, $query_Sequence) = @_;
    if ($query_Sequence) {
        $self->{'_query_Sequence'} = $query_Sequence;
    }
    return $self->{'_query_Sequence'};
}

sub accessions_from_clipboard {
    my ($self) = @_;

    my $text = $self->get_clipboard_text or return;

    # Add clipboard text to existing entry text so that annotator
    # can easily build up a list of accessions to search
    if (my $entry_txt = $self->get_entry('match')) {
        $text = join(' ', $entry_txt, $text);
    }

    # accessions_from_text extracts all the accessions from its
    # text argument and removes duplicates from the list

    # Temporary fix to eliminate SRA accessions from dotter / OTF vs transcript.
    my @acc = grep { not evidence_is_sra_sample_accession($_) } accessions_from_text($text);

    if (@acc) {
        $self->set_entry('match', join ' ', @acc);

        # Show the end of the Entry so that the annotator sees
        # the latest accessions added.
        $self->match->xviewMoveto(1);
    }

    return;
}

sub set_entry {
    my ($self, $method, $txt) = @_;
    my $entry = $self->$method();

    my $reset = 0;
    if ($entry->cget('-state') eq 'readonly') {
        $entry->configure(-state => 'normal');
        $reset = 1;
    }

    $entry->delete(0, 'end');
    $entry->insert(0, $txt);

    $entry->configure(-state => 'readonly') if $reset;

    return;
}

sub get_entry {
    my ($self, $method) = @_;

    if (my $txt = $self->$method()->get) {
        if ($txt =~ /\S/) {
            return $txt;
        }
    }
    return;
}

sub clear_accessions {
    my ($self) = @_;
    $self->set_entry('match', '');
    $self->fasta_txt->delete('1.0', 'end');
    return;
}

sub fasta_txt {
    my ($self, $txt) = @_;
    if ($txt) {
        $self->{'_fasta_txt'} = $txt;
    }
    return $self->{'_fasta_txt'};
}

sub fasta_file {
    my ($self, $file) = @_;
    if ($file) {
        $self->{'_fasta_file'} = $file;
    }
    return $self->{'_fasta_file'};
}

sub bestn {
    my ($self, $bestn) = @_;
    if ($bestn) {
        $self->{'_bestn'} = $bestn;
    }
    return $self->{'_bestn'};
}

sub max_intron_length {
    my ($self, $max_intron_length) = @_;
    if ($max_intron_length) {
        $self->{'_max_intron_length'} = $max_intron_length;
    }
    return $self->{'_max_intron_length'};
}

sub match {
    my ($self, $match) = @_;
    if ($match) {
        $self->{'_match'} = $match;
    }
    return $self->{'_match'};
}

sub SessionWindow {
    my ($self, $SessionWindow) = @_;
    if ($SessionWindow) {
        $self->{'_SessionWindow'} = $SessionWindow;
    }
    return $self->{'_SessionWindow'};
}

sub _repeat_masker {
    my ($self, $apply_mask_sub) = @_;

    my $ace_database = $self->SessionWindow->AceDatabase;
    my $offset = $ace_database->offset;

    my $dataset = $ace_database->DataSet;
    foreach my $filter_name (qw( trf RepeatMasker )) {
        my $filter = $dataset->filter_by_name($filter_name);
        $self->logger->logconfess("no filter named '${filter_name}'") unless $filter;
        $filter->call_with_session_data_handle(
            $ace_database,
            sub {
                my ($data_h) = @_;
                $self->logger->info('In _repeat_masker filter callback');
                while (<$data_h>) {
                    chomp;
                    next if /^\#\#/; # skip GFF headers

                    # feature parameters
                    my ( $start, $end ) = (split /\t/)[3,4];
                    $start -= $offset;
                    $end   -= $offset;

                    # sanity checks
                    $self->logger->logconfess("missing feature start in '$_'") unless defined $start;
                    $self->logger->logconfess("non-numeric feature start: $start")
                        unless $start =~ /^[[:digit:]]+$/;
                    $self->logger->logconfess("missing feature end in '$_'") unless defined $end;
                    $self->logger->logconfess("non-numeric feature end: $end")
                        unless $end =~ /^[[:digit:]]+$/;

                    if ($start > $end) {
                        ($start, $end) = ($end, $start);
                    }

                    # mask against this feature
                    $apply_mask_sub->($start, $end);
                }
                return;
            });
    }
    return;
}

sub launch_exonerate {
    my ($self) = @_;

    my $SessionWindow = $self->SessionWindow;
    $SessionWindow->AceDatabase->Client->reauthorize_if_cookie_will_expire_soon;

    my $bestn     = $self->get_entry('bestn') || 0;
    my $maxintron = $self->get_entry('max_intron_length') || 0;

    my $top = $self->top;
    my $atc = $SessionWindow->AceDatabase->AccessionTypeCache;
    my $latest_acc_sv_sub = sub { return $atc->latest_acc_sv_for_stem(@_) };

    $self->progress('Building OTF session');
    my $otf = Bio::Otter::Lace::OnTheFly::Genomic->new(

        seqs       => $self->entered_seqs($latest_acc_sv_sub),
        accessions => $self->entered_accessions,

        full_seq        => $SessionWindow->Assembly->Sequence,
        repeat_masker   => sub { my $apply_mask_sub = shift; $self->_repeat_masker($apply_mask_sub); },

        softmask_target => ($self->{_mask_target} eq $MASK_TARGET_SOFT),
        bestn           => $bestn,
        maxintron       => $maxintron,

        clear_existing  => $self->{_clear_existing},

        lowercase_poly_a_t_tails => 1, # to avoid spurious exons

        problem_report_cb => sub { $self->problem_box($top, 'Accessions Supplied', @_) },
        long_query_cb     => sub { $self->long_query_confirm($top, @_)  },
        progress_cb       => sub { $self->progress(@_) },

        accession_type_cache => $atc,

        logic_names          => $SessionWindow->OTF_Genomic_columns,
        );

    # get marked region (if requested)
    if ($self->{_region_target} eq $REGION_TARGET_MARKED) {
        $self->progress('Getting marked region');
        my ($mark_start, $mark_end) = $SessionWindow->get_mark_in_slice_coords;
        if ($mark_start && $mark_end) {
            $self->logger->warn("Setting exonerate genomic start & end to marked region: $mark_start - $mark_end");
            $otf->target_start($mark_start);
            $otf->target_end(  $mark_end);
        }
    }

    if ($otf->target_all_repeat) {
        $top->messageBox(
            -title   => $Bio::Otter::Lace::Client::PFX.'All Repeat',
            -icon    => 'warning',
            -message => 'The genomic sequence is entirely repeat',
            -type    => 'OK',
        );
        return;
    }

    $self->progress('Validating sequences');
    my $seq_list = $otf->confirmed_seqs();
    my $seqs = $seq_list->seqs;

    $self->logger->warn("Found ", scalar(@$seqs), " sequences");

    unless (@$seqs) {
        $self->progress('No query sequence(s)');
        $top->messageBox(
            -title   => $Bio::Otter::Lace::Client::PFX.'No Sequence',
            -icon    => 'warning',
            -message => 'Did not get any query sequence data',
            -type    => 'OK',
        );
        return;
    }

    if ($self->{'_clear_existing'}) {
        $self->progress('Deleting existing results from ZMap');
        $SessionWindow->delete_featuresets(@{$otf->logic_names});
    }

    $self->progress('Passing OTF requests to ZMap');
    my $key = "$otf";
    $SessionWindow->register_exonerate_callback($key, $self, \&Bio::Otter::UI::OnTheFlyMixin::exonerate_callback);
    $otf->prep_and_store_request_for_each_type($SessionWindow, $key);

    $self->progress('Done');
    $top->withdraw;

    return 1;
}


sub progress {
    my ($self, @args) = @_;
    if (@args) {
        ($self->{_progress}) = @args;
        my $top = $self->top;
        $top->toplevel->update if Tk::Exists($top);
    }
    return $self->{_progress};
}

sub display_request_feedback {
    my ($self, $request) = @_;
    $self->report_missed_hits($self->SessionWindow, $request, 'genomic');
    return;
}

Readonly my $SEQ_TAG_STEM => 'OTF_seq_';

# get seqs from fasta file and text box
#
sub entered_seqs {
    my ($self, $latest_acc_sv_sub) = @_;
    my @seqs;

    if (my $string = $self->fasta_txt->get('1.0', 'end')) {
        if ($string =~ /\S/ and $string !~ />/) {
            my $seq_tag = &$latest_acc_sv_sub($SEQ_TAG_STEM);
            my $n;
            if ($seq_tag) {
                ($n) = $seq_tag =~ /${SEQ_TAG_STEM}(\d+)$/;
                ++$n;
            } else {
                $n = 1;
            }
            $seq_tag = "${SEQ_TAG_STEM}$n";
            $self->logger->warn("creating new seq tag: $seq_tag");
            $string = ">$seq_tag\n" . $string;
        }
        $string = $self->_tidy_pasted_sequence($string);
        push @seqs, Hum::FastaFileIO->new(\$string)->read_all_sequences;
    }
    if (my $file_name = $self->get_entry('fasta_file')) {
        # Trim trailing or leading whitespace from file name
        $file_name =~ s/^\s+|\s+$//g;
        push @seqs, Hum::FastaFileIO->new($file_name)->read_all_sequences;
    }
    # Make sure entered seqs are distinct from seqs fetched by accession.
    # (We could try to lookup and compare, as a future feature.)
    foreach my $seq (@seqs) {
        my $name = $seq->name;
        unless ($name =~ /^otf[_:]/i) {
            $seq->name('OTF:' . $name);
        }
        $seq->type(seq_is_protein($seq->sequence_string) ? 'OTF_AdHoc_Protein' : 'OTF_AdHoc_DNA');
    }
    return \@seqs;
}

# get seqs from accession numbers supplied by the user
#
sub entered_accessions {
    my ($self) = @_;

    my @supplied_accs;
    if (my $txt = $self->get_entry('match')) {
        $txt =~ s/^\s+//;
        $txt =~ s/\s+$//;
        @supplied_accs = split(/[,;\|\s]+/, $txt);
    }
    return \@supplied_accs;
}

sub _tidy_pasted_sequence {
    my ($self, $seq) = @_;
    open my $fh, '<', \$seq or $self->logger->logdie('open stringref failed');
    my @stripped;
    while (my $line = <$fh>) {
        chomp $line;
        unless ($line =~ /^>/) {
            $line =~ s{       # strip leading line numbers:
                          ^   #   start of line
                          \s* #   optional leading whitespace
                          \d+ #   line number
                          \s+ #   at least some whitespace
                      }{}x;
            $line =~ s/\s+//g; # strip whitespace
        }
        push @stripped, $line if $line;
    }
    push @stripped, '';         # ensure trailing newline
    return join("\n", @stripped);
}

sub DESTROY {
    my ($self) = @_;

    warn "Freeing exonerateWindow '$self'\n";

    return;
}

1;

__END__

=head1 NAME - EditWindow::Exonerate

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

