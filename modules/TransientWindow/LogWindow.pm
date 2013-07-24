package TransientWindow::LogWindow;

use strict;
use warnings;

use IO::Handle;
use Bio::Otter::LogFile;
use Bio::Otter::Lace::Client;
use Bio::Otter::Git;
use Bio::Vega::Utils::URI qw{ open_uri uri_config_how };
use Net::Domain qw{ hostfqdn };


use base qw( TransientWindow );

my @mailto; # file global, init-once
__mailto_init();


sub show_for {
    my ($pkg, $w) = @_;

    my $mw = $w->MainWindow;
    my $tw = $mw->{'__tw_log'};

    if (!$tw) {
        my $title = $Bio::Otter::Lace::Client::PFX.'log file - '.
          $pkg->current_logfile;
        $tw = TransientWindow::LogWindow->new($mw, $title);
        $mw->{'__tw_log'} = $tw; # not yet initialised
        $tw->initialise();
        $tw->draw;
        $tw->show_me();
    } elsif (!$tw->{'_drawn'}) {
        # Window was being initialised but we recursed?
        # It will happen soon; show_output will be no-op
    } else {
        # Window found and ready, may be hidden
        $tw->show_me();
    }

    return $tw;
}

sub initialise {
    my ($self, @args) = @_;

    $self->SUPER::initialise(@args);

    my $lw        = $self->window;
    my $top_frame = $lw->Frame->pack(
        -side   => 'top',
        -fill   => 'both',
        -expand => 1
    );
    my $but_frame = $lw->Frame->pack(
        -side => 'top',
        -fill => 'x'
    );
    my $scrolled = $top_frame->Scrolled(
        'ROText',
        -font             => [ 'lucidatypewriter', 10, 'normal' ],
        -padx             => 6,
        -pady             => 6,
        -relief           => 'groove',
        -background       => 'white',
        -border           => 2,
        -selectbackground => 'gold',
        -scrollbars       => 'se',
        -wrap             => 'none',
        -width            => 100,
        -height           => 24,
      )->pack(
        -expand => 1,
        -fill   => 'both',
      );
    my $ROText = $scrolled->Subwidget('rotext');
    unless ($^O eq 'MSWin32') {
        my $y_scroll = $ROText->parent->Subwidget('yscrollbar');
        $ROText->Tk::bind(
            '<4>',
            sub {
                $y_scroll->ScrlByUnits('v', -3);
            }
        );
        $ROText->Tk::bind(
            '<5>',
            sub {
                $y_scroll->ScrlByUnits('v', +3);
            }
        );
    }
    $ROText->tagConfigure(seenmark => -background => '#d00', -foreground => '#fff');
    $self->readonly_text($ROText);

    my $email_dev = sub { $self->mail_contents(); };
    $but_frame->Button(
        -text    => 'Report bug',
        -command => $email_dev,
    )->pack(-side => 'left');

    $but_frame->Label(-text => ' for ')->pack(-side => 'left');
    my $dest = $but_frame->SmartOptionmenu
      (-options => \@mailto,
       -variable => \$self->{_mailto},
      )->pack(-side => 'left');

    $but_frame->Button(
        -text    => 'Close',
        -command => sub { $self->hide_me },
    )->pack(-side => 'right');

    $lw->Tk::bind('<Escape>', [ $self, 'hide_me' ]);
    $lw->Tk::bind('<Control-w>', [ $self, 'hide_me' ]);
    $lw->Tk::bind('<Control-W>', [ $self, 'hide_me' ]);

    $but_frame->bind('<Destroy>', sub { $self = undef; });

    return;
}

sub draw {
    my ($self) = @_;
    return if $self->{'_drawn'};

    my $file      = $self->current_logfile;
    my $tail_pipe = "tail -f -n 1000 $file";
    my $pid       = open my $fh, '-|', $tail_pipe
      or die "Can't open tail command '$tail_pipe': $!";
    $self->tail_process($pid);
    $self->logfile_handle($fh);
    my $txt = $self->readonly_text;

    # Non-blocking filehandle so we don't stall the app
    $fh->blocking(0);

    $txt->fileevent($fh, 'readable', # is unhooked by close $fh
                    [ $self, 'show_output' ]);

    $self->{'_drawn'} = 1;
    return;
}

sub tail_process {
    my ($self, $tail_process) = @_;

    if ($tail_process) {
        $self->{'_tail_process'} = $tail_process;
    }
    return $self->{'_tail_process'};
}

sub logfile_handle {
    my ($self, $logfile_handle) = @_;

    if ($logfile_handle) {
        $self->{'_logfile_handle'} = $logfile_handle;
    }
    return $self->{'_logfile_handle'};
}

sub current_logfile {
    return Bio::Otter::LogFile::current_logfile();
}

sub readonly_text {
    my ($self, $widget) = @_;

    $self->{'_rotext'} = $widget if $widget;
    return $self->{'_rotext'};
}

sub show_output {
    my ($self) = @_;

    my $fh  = $self->logfile_handle;
    my $txt = $self->readonly_text;

    # Guard against being called too early
    return unless $self->{'_drawn'};

    # Guard against recursion; but we still must not call 'update'
    return if $self->{_show_output__threaded};
    local $self->{_show_output__threaded} = 1;

    # Guard against global destruction or window <Destroy>ed
    unless (Tk::Exists($txt) && $fh) {
        $self->logfile_handle(undef);
        if ($fh) {
            close $fh; # ignore tail process exit status
            warn "LogWindow: no GUI to write in, closed the pipe";
        }
        if (Tk::Exists($txt)) {
            $txt->insert('end', 'Appending stopped because pipe was closed');
        }
        return;
    };

    # Read log file
    my $nread;
    my $add = '';
    do {
        $nread = read($fh, $add, 1024, length($add));
        # This should be non-blocking, but when called in the context
        # of Tk::Error it is apparently a blocking call despite
        # frobbing $fh->blocking .  Therefore we don't loop.

        # if (!defined $nread) {
        #   ignore error, probably 11=='Resource temporarily unavailable'
        # }
    }
    # Would like to slurp all input, else we will be called again next
    # event, but this is only possible when non-blocking works.
      ;# while ($nread && !$no_jump);

    # Logfile can contain binary junk from Otterlace or child
    # processes.  We can't prevent it & Tk::ROText cannot accept it.
    # => Quote here
    $add =~ s{\\x([0-9a-fA-F][0-9a-fA-F])}{\\5Cx$1}g; # Literal \x00 to \x5Cx00
    $add =~ s{([^ -~\n])}{sprintf('\\x%02X', ord($1))}eg; # quote non-ASCII

    my (undef, $oldY) = @{ $txt->yview };
    my $jump = $oldY > 0.999999;

    my @tagged = $txt->tagRanges('seenmark');
    $jump = 0 if @tagged;

    $txt->insert('end', $add);
    $txt->yview('end') if $jump;

    return;
}

sub get_log_contents {
    my ($self, $refresh) = @_;

    my $txt = $self->readonly_text;

    # Limit size of report - some email clients truncate long mailto URLs
    return $txt->get('end - 250 lines', 'end');
}

sub __mailto_init {
    my $domain    = '@sanger.ac.uk';
    @mailto =
      ([ 'The Otterlace application, pipeline and data' =>  "anacode$domain" ],
       [ 'The ZMap application'                         =>     "zmap$domain" ],
       [ 'Blixem, Dotter and Belvu applications'        => "seqtools$domain" ],
       [ 'All bugs found during testing'                => "annotest$domain" ]);

    # We may get clues that tickets should go to annotest or developer.
    # May only work for internal Linux.  RT#267390 may bring improvement.
    my $clue = $ENV{OTTERLACE_RAN_AS} || '';
    $clue =~ s{otterlace}{otter}g;

    @mailto[0,3] = @mailto[3,0]
      if $clue =~ m{\botter_test|test_otter\b|zircon};

    my $me = getpwuid($<);
    unshift @mailto, [ 'Myself' => "$me$domain" ]
      if $clue =~ m{\botter_dev|dev_otter\b};

    return ();
}

sub _mailto {
    my ($self) = @_;
    return $self->{_mailto}; # set by SmartOptionmenu $dest
}

sub mail_contents {
    my ($self) = @_;

    my $to      = $self->_mailto();
    my $file    = hostfqdn() . ":" . $self->current_logfile;
    my $subj    = "otterlace error: <PLEASE REPLACE WITH SHORT DESCRIPTION>";
    my $mess    = $self->get_log_contents();
    my $info   =
        "Program version: " . Bio::Otter::Git->param('head') . "\n"
        . "Program script name: $0\n"
        . "Log file: $file\n";
    $info .= "Program ran as: $ENV{OTTERLACE_RAN_AS}\n"
      if $ENV{OTTERLACE_RAN_AS};

    open_uri("mailto:$to", {
        subject => $subj,
        body    => "\n<ADD FURTHER INFORMATION ABOUT PROBLEM HERE>\n\n--------\n$info--------\n$mess",
    }) or do {
        $self->message_highlight("Could not open your email client");
        # nb. this works OK for GUI mail clients, but those that run
        # in a terminal don't return an error to us!
        warn "Error opening email client to send email to '$to'";
        warn uri_config_how();
    };

    return;
}

sub message_highlight {
    my ($self, $msg) = @_;

    my $txt = $self->readonly_text;
    chomp $msg;
    $txt->yview('end');
    $txt->insert('end - 1 char linestart', "$msg\n", 'seenmark');
    warn "(LogWindow mark inserted to highlight entry: $msg)\n";

    return ();
}

sub DESTROY {
    my ($self) = @_;

    warn "Destroying logfile monitor for '", $self->current_logfile, "'\n";

    if (my $pid = $self->tail_process) {
        kill 'TERM', $pid if defined $pid;
    }
    if (my $fh = $self->logfile_handle) {
        close($fh) if defined $fh;
    }

    return;
}

1;

__END__

