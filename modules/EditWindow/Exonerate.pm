
### EditWindow::Exonerate

package EditWindow::Exonerate;

use strict;
use warnings;

use Log::Log4perl;

use Bio::Otter::Lace::OnTheFly::Genomic;
use Bio::Vega::Evidence::Types qw(evidence_is_sra_sample_accession);
use Bio::Otter::Lace::Client;
use Hum::Pfetch;
use Hum::FastaFileIO;
use Hum::ClipboardUtils qw{ accessions_from_text };
use Hum::Sort qw{ ace_sort };
use Tk::LabFrame;
use Tk::Checkbutton;
use Tk::Radiobutton;
use Tk::Utils::OnTheFly;

use base 'EditWindow';

my $BEST_N            = 1;
my $MAX_INTRON_LENGTH = 200000;
my $MAX_QUERY_LENGTH  = 10000;
my $MASK_TARGET       = 'soft';

my $INITIAL_DIR = (getpwuid($<))[7];

sub initialise {
    my ($self) = @_;

    my @frame_pack = (-side => 'top', -fill => 'x');
    my @frame_expand = (-side => 'top', -fill => 'both', -expand => 1);

    my $top = $self->top;

    ### Query frame
    my $query_frame = $top->LabFrame(
        -label     => 'Query sequences',
        -border    => 3,
    )->pack(@frame_expand);

    ## Accession entry box
    my $match_frame = $query_frame->Frame(-border => 3)->pack(@frame_pack);
    $match_frame->Label(
        -text   => 'Accessions:',
        -anchor => 's',
        -padx   => 6,
    )->pack(-side => 'left');
    $self->match($match_frame->Entry->pack(-side => 'left', -expand => 1, -fill => 'x'));
    $match_frame->Frame(-width => 6,)->pack(-side => 'left');

    my $update = sub {
        $self->accessions_from_clipboard;
    };
    $match_frame->Button(
        -text      => 'Fetch from clipboard',
        -underline => 0,
        -command   => $update,
    )->pack(-side => 'left');
    $match_frame->Button(
        -text      => 'Clear',
        -underline => 0,
        -command   => sub {
            $self->set_entry('match', '');
            $self->fasta_txt->delete('1.0', 'end');
        },
    )->pack(-side => 'left');
    $top->bind('<Control-u>', $update);
    $top->bind('<Control-U>', $update);

    ## Fasta file entry box
    my $fname;
    my $file_frame = $query_frame->Frame(-border => 3)->pack(@frame_pack);
    $file_frame->Label(
        -text   => 'Fasta file:',
        -anchor => 's',
        -padx   => 6,
    )->pack(-side => 'left');

    $self->fasta_file($file_frame->Entry(-textvariable => \$fname)->pack(-side => 'left', -expand => 1, -fill => 'x'));

    # Pad between entries
    $file_frame->Frame(-width => 6,)->pack(-side => 'left');

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
        -padx   => 6,
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
    my $input_frame = $top->Frame->pack(@frame_pack);

    my $input_widgets = [
        [ '_use_marked_region', 1, 'Region',
          [ [ 'All', 0 ], [ 'Marked region', 1 ] ] ],
        [ '_mask_target', $MASK_TARGET, 'Repeat masking',
          [ [ 'Unmasked', 'none' ], [ 'Soft masked', 'soft' ] ] ],
        ];

    for (@{$input_widgets}) {
        my ($key, $default, $name, $button_list) = @{$_};
        $self->{$key} = $default;
        my $button_list_frame =
            $input_frame->LabFrame(
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
                )->pack(-side => 'left', -expand => 1, -fill => 'x');
        }
    }

    ### Parameters
    my $param_frame = $top->LabFrame(
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

    $top->Checkbutton(
        -variable => \$self->{_clear_existing},
        -text     => 'Clear existing OTF alignments',
        -anchor   => 'w',
    )->pack(-side => 'top');

    ### Commands
    my $button_frame = $top->Frame->pack(@frame_pack);
    my $doing_launch = 0;       # captured by closure...
    my $launch       = sub {
        if ($doing_launch) {
            $self->logger->warn("Already launched, ignoring click.");
            return;
        }
        $doing_launch = 1;
        my $okay = $self->launch_exonerate;
        $top->withdraw if $okay;
        $doing_launch = 0;
    };
    $button_frame->Button(
        -text      => 'Launch',
        -underline => 0,
        -command   => $launch,
    )->pack(-side => 'left');
    $top->bind('<Control-l>', $launch);
    $top->bind('<Control-L>', $launch);

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
    foreach my $filter_name qw( trf RepeatMasker ) {
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

    my $bestn     = $self->get_entry('bestn') || 0;
    my $maxintron = $self->get_entry('max_intron_length') || 0;

    my $otf = Bio::Otter::Lace::OnTheFly::Genomic->new(

        seqs       => $self->entered_seqs,
        accessions => $self->entered_accessions,

        full_seq        => $SessionWindow->Assembly->Sequence,
        repeat_masker   => sub { my $apply_mask_sub = shift; $self->_repeat_masker($apply_mask_sub); },

        softmask_target => ($self->{_mask_target} eq 'soft'),
        bestn           => $bestn,
        maxintron       => $maxintron,

        lowercase_poly_a_t_tails => 1, # to avoid spurious exons

        problem_report_cb => sub { $self->top->Tk::Utils::OnTheFly::problem_box('Accessions Supplied', @_) },
        long_query_cb     => sub { $self->top->Tk::Utils::OnTheFly::long_query_confirm(@_)  },

        accession_type_cache => $SessionWindow->AceDatabase->AccessionTypeCache,
        );

    # get marked region (if requested)
    if ($self->{_use_marked_region}) {
        my ($mark_start, $mark_end) = $SessionWindow->get_mark_in_slice_coords;
        if ($mark_start && $mark_end) {
            $self->logger->warn("Setting exonerate genomic start & end to marked region: $mark_start - $mark_end");
            $otf->target_start($mark_start);
            $otf->target_end(  $mark_end);
        }
    }

    if ($otf->target_all_repeat) {
        $self->top->messageBox(
            -title   => $Bio::Otter::Lace::Client::PFX.'All Repeat',
            -icon    => 'warning',
            -message => 'The genomic sequence is entirely repeat',
            -type    => 'OK',
        );
        return;
    }

    my $seqs = $otf->confirmed_seqs();

    $self->logger->warn("Found ", scalar(@$seqs), " sequences");

    unless (@$seqs) {
        $self->top->messageBox(
            -title   => $Bio::Otter::Lace::Client::PFX.'No Sequence',
            -icon    => 'warning',
            -message => 'Did not get any sequence data',
            -type    => 'OK',
        );
        return;
    }

    $self->top->Busy;

    # OTF should not influence unsaved changes state of the session
    $SessionWindow->flag_db_edits(0);

    if ($self->{'_clear_existing'}) {
        $SessionWindow->delete_featuresets(qw{
Unknown_DNA
Unknown_Protein
OTF_EST
OTF_ncRNA
OTF_mRNA
OTF_Protein });
    }

    my $db_edited = $SessionWindow->launch_exonerate($otf);

    $self->top->Unbusy;

    $SessionWindow->flag_db_edits(1);

    if ($db_edited) {
        my @misses = $otf->names_not_hit;
        if (@misses) {
            $self->top->messageBox(
                -title   => $Bio::Otter::Lace::Client::PFX.'Missing Matches',
                -icon    => 'warning',
                -message => join("\n",
                                 'Exonerate did not find matches for:',
                                 sort @misses,
                                ),
                -type    => 'OK',
                );
        }
        return 1;
    }
    else {
        $self->top->messageBox(
            -title   => $Bio::Otter::Lace::Client::PFX.'No Matches',
            -icon    => 'warning',
            -message => 'Exonerate did not find any matches on genomic sequence',
            -type    => 'OK',
        );
        return 0;
    }
}

my $seq_tag = 1;

# get seqs from fasta file and text box
#
sub entered_seqs {
    my ($self) = @_;
    my @seqs;

    if (my $string = $self->fasta_txt->get('1.0', 'end')) {
        if ($string =~ /\S/ and $string !~ />/) {
            $self->logger->warn("creating new seq tag num: $seq_tag");
            $string = ">OTF_seq_$seq_tag\n" . $string;
            $seq_tag++;
        }
        push @seqs, Hum::FastaFileIO->new(\$string)->read_all_sequences;
    }
    if (my $file_name = $self->get_entry('fasta_file')) {
        # Trim trailing or leading whitespace from file name
        $file_name =~ s/^\s+|\s+$//g;
        push @seqs, Hum::FastaFileIO->new($file_name)->read_all_sequences;
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

sub logger {
    return Log::Log4perl->get_logger;
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

