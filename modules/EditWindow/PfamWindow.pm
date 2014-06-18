
package EditWindow::PfamWindow;

use strict;
use warnings;
use Carp;
use POSIX ();
use URI;
use Try::Tiny;
use Log::Log4perl;

use Tk::ProgressBar;
use Bio::Otter::Lace::Pfam;
use Bio::Vega::Utils::URI qw{ open_uri };
use Hum::Sort qw{ ace_sort };

use base 'EditWindow';

my $POLL_ATTEMPTS = 30;

sub new {
    my ($pkg, @args) = @_;
    my $self = $pkg->SUPER::new(@args);

    return $self;
}

sub progress {
    my ($self, $p) = @_;
    if ($p) {
        $self->{_progress} = $p;
        my $top = $self->top;
        $top->toplevel->update if Tk::Exists($top);
    }
    return $self->{_progress};
}

sub pfam {
    my ($self, $pfam) = @_;
    $self->{_pfam} = $pfam if $pfam;
    return $self->{_pfam};
}

sub query {
    my ($self, $s) = @_;
    if ($s) {
        $self->{_seq} = $s;
    }
    return $self->{_seq};
}

sub name {
    my ($self, $n) = @_;
    if ($n) {
        $self->{_name} = $n;
    }
    return $self->{_name};
}

sub status {
    my ($self, $s) = @_;
    if ($s) {
        $self->{_status} = $s;
        $self->logger->info("status: $s");
        my $top = $self->top;
        $top->toplevel->update if Tk::Exists($top);
    }
    return $self->{_status};
}

sub result_url {
    my ($self, $u) = @_;
    if ($u) {
        $self->{_url} = $u;
    }
    return $self->{_url};
}

sub widg {
    my ($self, $name) = @_;
    return $self->{_widg}->{$name} or die "No widg($name)";
}

sub initialize {
    my ($self, $tmpdir) = @_;

    my $pfam = Bio::Otter::Lace::Pfam->new($tmpdir);
    $self->pfam($pfam);

    my $top = $self->top;

    my $button_frame = $top->Frame->pack(-side => 'bottom', -fill => 'x');

    my $progress_bar = $top->ProgressBar(
        -width    => 20,
        -from     => 0,
        -to       => 100,
        -blocks   => 1,
        -variable => \$self->{_progress}
    )->pack(-fill => 'x', -expand => 1);

    $top->Label(
        -width        => 45,
        -height       => 1,
        -textvariable => \$self->{_status}
    )->pack(-side => 'top', -fill => 'x');

    my $cancel_command = [ $self, 'cancel' ];
    $top->bind('<Control-q>', $cancel_command);
    $top->bind('<Control-Q>', $cancel_command);
    $top->protocol('WM_DELETE_WINDOW', $cancel_command);
    my $cancel_button = $button_frame->Button(
        -text    => 'Cancel',
        -command => $cancel_command,
    )->pack(-side => 'left');

    my $close_button = $button_frame->Button(
        -text    => 'Close',
        -command => [ $self, 'withdraw' ],
    )->pack(-side => 'right');

    my $view_button = $button_frame->Button(
        -text    => 'View on Pfam website',
        -command => sub { $self->open_url },
    )->pack(-side => 'left', -fill => 'x');

    $self->{_widg} = { progress => $progress_bar, view => $view_button,
                       cancel => $cancel_button, close => $close_button };

    $view_button->configure(-state => $self->result_url ? 'normal' : 'disabled');
    $close_button->configure(-state => 'disabled');

    $self->begin_search;

    return;
}


sub begin_search {
    my ($self) = @_;
    my $top = $self->top;
    my $pfam = $self->pfam;

    if ($self->result_url) {
        # created with an existing result - nothing to do
        $self->status("showing previous result");
        $top->afterIdle([ $self, 'await_result', 1 ]);
    }
    else {
        my $xml = $pfam->submit_search($self->query);
        my $result_url = $pfam->check_submission($xml);
        $self->result_url($result_url);
        $self->widg('view')->configure(-state => 'normal');
        $self->status("searching pfam...");

        # For pfam.sanger.ac.uk intent seems to have been to wait a
        # while before polling.  pfam.xfam.org is now much faster, so
        # wait faster.
        my $n_div = 30;
        my $t_unit = 3000 / $n_div; # millisec, for progress 0..$n_div
        for (my $n=0; $n<$n_div; $n++) {
            $top->after($n * $t_unit, [ $self, 'progress', $n ]);
        }
        $top->after($n_div * $t_unit, [ $self, 'await_result', 0 ]);
    }

    # events are queued,
    return;
}

sub await_result {
    my ($self, $attempt_number) = @_;
    my $top = $self->top;
    my $pfam = $self->pfam;
    return if !Tk::Exists($top); # cancelled

    $self->progress(30 + $attempt_number);
    my $n_left = $POLL_ATTEMPTS - $attempt_number - 1;
    my $wait = 1500 * ($attempt_number+1) ** 2; # millisec
    $self->logger->debug("await_result($attempt_number) - $n_left left, next check after ", $wait/1000);
    my $res = $pfam->poll_results($self->result_url);

    if ($res && $res =~ /<pfam/m) {
        return $self->have_result($res);

    } elsif ($attempt_number < $POLL_ATTEMPTS) {
        $self->status("searching pfam (status $res)");
        return $top->after($wait, [ $self, 'await_result', $attempt_number + 1 ]);

    } else {
        # Gave up waiting
        $self->status("No result, please open pfam manually");
        return;
    }
}

sub have_result {
    my ($self, $res) = @_;
    my $top = $self->top;
    my $pfam = $self->pfam;
    return if !Tk::Exists($top); # cancelled

    my $alignments = {};
    my $err = {};

    $self->status("parsing pfam result");
    $top->toplevel->update;

    my $matches = $pfam->parse_results($res);
    $self->progress(70);

    my @domains = keys %$matches;
    if (@domains) {
        my $progress_per_domain = 30 / scalar(@domains);
        foreach my $domain (sort @domains) {
            my $sub_seq = $pfam->get_seq_snippets($self->name, $self->query, $matches->{$domain}->{locations});
            $self->status("$domain: get the seed aligments");
            my $s    = $pfam->retrieve_pfam_seed([$domain]);
            my $seed = $s->{$domain};

            $self->status("$domain: get the hmm");
            my $h   = $pfam->retrieve_pfam_hmm([$domain]);
            my $hmm = $h->{$domain};

            $self->status("$domain: aligning");
            my ($status, $output) =
              $pfam->align_to_seed($sub_seq, $domain, $hmm, $seed);
            if ($status eq 'ok') {
                $alignments->{$domain} = $output; # filename
            } else {
                $alignments->{$domain} = undef; # filename
                $err->{$domain} = $output; # error message
            }
            $self->progress($progress_per_domain + $self->progress);
        }
    }

    $self->status("Significant Pfam-A Matches :");
    $self->progress(100);

    $top->Frame->pack(-side => 'top', -fill => 'both');
    my $result_frame_widget = $top->Frame->pack(-side => 'top', -fill => 'both');

    # display result
    if (keys %$alignments) {

        $result_frame_widget->Label(
            -text  => 'Pfam',
            -width => 10,
        )->grid(-column => 0, -row => 0, -sticky => 'ew');

        $result_frame_widget->Label(
            -text  => 'ID & Class',
            -width => 20,
          )->grid(
            -row    => 0,
            -column => 1,
            -sticky => 'ew',
          );

        $result_frame_widget->Label(
            -text  => 'Locations',
            -width => 10,
          )->grid(
            -row    => 0,
            -column => 2,
            -sticky => 'ew',
          );

        $result_frame_widget->Label(
            -text  => 'Alignments',
            -width => 10,
          )->grid(
            -row    => 0,
            -column => 3,
          );
    }

    my $row = 1;

    foreach my $domain (sort { ace_sort($a, $b) } keys %$alignments) {
        my $locations = "";
        my $m         = scalar @{ $matches->{$domain}->{locations} };
        my ($locs_h, $locs_w) = (0, 0);
        for my $location (sort { $a->{start} <=> $b->{start} } @{ $matches->{$domain}->{locations} }) {
            my $loc = $location->{start} . "->" . $location->{end};
            $locations .= "$loc\n";
            $locs_w = length($loc) if length($loc) > $locs_w;
            $locs_h ++;
        }

        $result_frame_widget->Entry(
            -highlightthickness => 0,
            -justify            => 'center',
            -state              => 'readonly',
            -text               => $domain,
            -width              => 10,
          )->grid(
            -row    => $row,
            -column => 0,
            -sticky => 'new',
          );

        $result_frame_widget->Entry(
            -highlightthickness => 0,
            -justify            => 'center',
            -state              => 'readonly',
            -width              => 20,
            -text               => $matches->{$domain}->{id} . " " . $matches->{$domain}->{class},
          )->grid(
            -row    => $row,
            -column => 1,
            -sticky => 'nsew',
          );

        my $loc_widget = $result_frame_widget->ROText(
            -highlightthickness => 0,
            -height => $locs_h,
            -width => $locs_w + 2,
          )->grid(
            -row    => $row,
            -column => 2,
            -sticky => 'ew',
          );
        $loc_widget->Contents($locations);

        my $alignment = $alignments->{$domain}; # undef = failed
        my $launch = $result_frame_widget->Button(
            -anchor             => 's',
            -borderwidth        => 1,
            -highlightthickness => 2,
            -justify            => 'left',
            -padx               => '0m',
            -pady               => '0m',
            -text               => 'in Belvu',
            -width              => 9,
            -state => defined $alignment ? 'normal' : 'disabled',
            -command            => [ $self, '_launch_belvu', $alignment ],
          )->grid(
            -row    => $row,
            -column => 3,
          );
        $self->balloon->attach($launch, -balloonmsg => $err->{$domain})
          if $err->{$domain};

        $result_frame_widget->gridColumnconfigure($_, -weight => 1)
          foreach (0,1,2);

        $row++;
    }

    $self->open_url();
    return $self->mark_completed;
}

sub balloon {
    my ($self) = @_;
    return $self->{_balloon} ||= $self->top->Balloon;
}

sub mark_completed {
    my ($self) = @_;
    my $top = $self->top;
    $self->logger->info('Completed ', $self->name);

    $self->widg('progress')->packForget;
    $self->widg('close')->configure(-state => 'normal');
    $self->widg('cancel')->configure(-state => 'disabled');

    my $close_command = [ $self, 'withdraw' ];
    # Change these from 'cancel' to 'close'
    $top->bind('<Control-q>', $close_command);
    $top->bind('<Control-Q>', $close_command);
    $top->protocol('WM_DELETE_WINDOW', $close_command);

    # need to call configure to resize the window.
    # the values in width and height are not important
    $self->top->toplevel->configure(-width => 1, -height => 1);

    return;
}

sub cancel {
    my ($self) = @_;
    my $top = $self->top;
    if (Tk::Exists($top)) {
        $self->logger->info('Cancel (destroy)');
        $top->destroy;
    }
    return;
}

sub withdraw {
    my ($self) = @_;
    my $top = $self->top;
    if (Tk::Exists($top)) {
        $top->withdraw;
        $self->logger->info('Closed (withdraw)');
    }
    return;
}

sub restore { # owning TranscriptWindow wants us back
    my ($self, $new_query) = @_;
    my $top = $self->top;
    my $old_query = $self->query;
    if (Tk::Exists($top) && $old_query eq $new_query) {
        $self->logger->info("Restored for $old_query");
        $top->deiconify;
        $top->raise;
        $top->focus;
        return 1;
    } else {
        $self->logger->info("Restored, query was $old_query now $new_query");
        $top->destroy if Tk::Exists($top);
        return 0;
    }
}

sub fill_progressBar {
    my ($self, $value) = @_;

    for (my $percent = $self->progress; $percent <= $value; $percent++) {
        $self->progress($percent);
        $self->top->toplevel->update;
        $self->top->toplevel->after(20);
    }

    return;
}

sub _launch_belvu {
    my ($self, $alignment) = @_;
    if (my $pid = fork) {
        # parent
        $self->logger->info("launch belvu on $alignment, pid $pid");
        return 1;
    } elsif (defined $pid) {
        $ENV{BELVU_FETCH} = 'pfetch'; # will be on PATH, won't work outside firewall
        my @command = ("belvu", $alignment);
        # DUP: Bio::Otter::ZMap::_launchZMap()
        { exec(@command) };
        warn "Failed to exec '@command': $!";
        close STDERR; # _exit does not flush
        close STDOUT;
        POSIX::_exit(127); # avoid triggering DESTROY
    } else {
        $self->logger->warn("fork for belvu failed: $!");
    }
}

sub open_url {
    my ($self) = @_;

    my $url = $self->result_url;
    $url =~ s/resultset/results/;

    # Remove query parameters
    my $uri = URI->new($url);
    $uri->query_form({});
    $url = $uri->as_string;

    $self->logger->info("Pfam search result for ", $self->name, "\n$url");
    open_uri($url);
    return;
}

sub logger {
    return Log::Log4perl->get_logger('otter.pfam'); # shared with Bio::Otter::Lace::Pfam
}

sub DESTROY {
    my ($self) = @_;
    $self = undef;    # $self gets nicely DESTROY'd with this
    return;
}

1;
__END__

=head1 NAME - EditWindow::PfamWindow

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

