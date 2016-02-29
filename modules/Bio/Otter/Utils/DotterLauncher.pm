
### Bio::Otter::Utils::DotterLauncher

package Bio::Otter::Utils::DotterLauncher;

use strict;
use warnings;

use Carp;
use POSIX ();
use Try::Tiny;

use Hum::FastaFileIO;

sub new {
    my( $pkg ) = @_;

    return bless {}, $pkg;
}

sub AccessionTypeCache {
    my ($self, $AccessionTypeCache) = @_;

    if ($AccessionTypeCache) {
        $self->{'_AccessionTypeCache'} = $AccessionTypeCache;
    }
    return $self->{'_AccessionTypeCache'};
}

sub query_start {
    my( $self, $query_start ) = @_;

    if ($query_start) {
        $self->{'_query_start'} = $query_start;
    }
    return $self->{'_query_start'};
}

sub query_end {
    my( $self, $query_end ) = @_;

    if ($query_end) {
        $self->{'_query_end'} = $query_end;
    }
    return $self->{'_query_end'};
}

sub query_Sequence {
    my( $self, $query_Sequence ) = @_;

    if ($query_Sequence) {
        $self->{'_query_Sequence'} = $query_Sequence;
    }
    return $self->{'_query_Sequence'};
}

sub query_type {
    my ($self, @args) = @_;
    ($self->{'query_type'}) = @args if @args;
    my $query_type = $self->{'query_type'};
    return $query_type;
}

sub subject_name {
    my( $self, $subject_name ) = @_;

    if ($subject_name) {
        $self->{'_subject_name'} = $subject_name;
    }
    return $self->{'_subject_name'};
}

sub subject_type {
    my ($self, @args) = @_;
    ($self->{'subject_type'}) = @args if @args;
    my $subject_type = $self->{'subject_type'};
    return $subject_type;
}

sub problem_report_cb {
    my ($self, @args) = @_;
    ($self->{'problem_report_cb'}) = @args if @args;
    my $problem_report_cb = $self->{'problem_report_cb'};
    return $problem_report_cb;
}

sub revcomp_subject {
    my( $self, $flag ) = @_;

    if (defined $flag) {
        $self->{'_revcomp_subject'} = $flag;
    }
    return $self->{'_revcomp_subject'} || 0;
}

{
    my $query_serial = 0;
    sub _session_info {
        my ($self, $session_window) = @_;
        my $colour = $session_window->session_colour;
        my $session_dir = $session_window->AceDatabase->home;
        my $tmpdir = "$session_dir/dotter";
        unless (-d $tmpdir) {
            mkdir $tmpdir, 0755
              or die "Cannot mkdir $tmpdir: $!";
        }
        $query_serial ++;
        return ($colour, "$tmpdir/dotter.$query_serial");
    }
}

sub fork_dotter {
    my ($self, $session_window) = @_;
    my ($colour, $prefix) = $self->_session_info($session_window);

    my $start           = $self->query_start    or confess "query_start not set";
    my $end             = $self->query_end      or confess "query_end not set";
    my $seq             = $self->query_Sequence or confess "query_Sequence not set";
    my $subject_name    = $self->subject_name   or confess "subject_name not set";

    my $query_file   = "$prefix.query";
    my $subject_file = "$prefix.subject";
    # In SeqTools 4.27, Dotter reads these files promptly on start,
    # and then doesn't look at them again.

    try {
        my $query_seq = $seq->sub_sequence($start, $end);
        $query_seq->name($seq->name);

        # Gaps between clones are emitted as dashes by acedb but dotter
        # splcies them out, which affects the coordinates, so we must
        # change them to "n"s.
        $self->change_dashes_to_n($query_seq);

        my $atc = $self->AccessionTypeCache;
        my $acc_list = $atc->accession_list_from_text($subject_name);   # Strips "Em:" etc... prefixes
        my ($actual_name);
        if (@$acc_list) {
            $atc->populate($acc_list);
            $actual_name = $acc_list->[0];
        }
        else {
            # Name didn't match accession regular expression
            # Could be, for example, a RefSeq accession.
            $atc->populate([$subject_name]);
            $actual_name = $subject_name;
        }
        $actual_name = $atc->full_acc_sv($actual_name) || $actual_name;
        if (my $info = $atc->feature_accession_info($actual_name)) {
            # Write the subject
            my $subject_seq = Hum::Sequence->new();
            $subject_seq->name($actual_name);  # Show the fully resolved name
            $subject_seq->description($info->{'description'});
            $subject_seq->sequence_string($info->{'sequence'});
            my $subject_out = Hum::FastaFileIO->new("> $subject_file");
            $subject_out->write_sequences($subject_seq);
        }
        else {
            die "Can't fetch '$subject_name'\n";
        }

        # Write out the query sequence
        my $query_out = Hum::FastaFileIO->new("> $query_file");
        $query_out->write_sequences($query_seq);
        $query_out = undef;
        1;
    }
    catch {
        warn $_;
        if ($self->problem_report_cb) {
            &{$self->problem_report_cb}($_);
        }
        0;
    } or return;

    # Run dotter. Offset ensures that annotators see the global coordinates of the whole assembly in dotter.
    my %options;
    my $offset = $start - 1;
    $options{'--horizontal-offset'} = $offset;
    $options{'--horizontal-type'} = $self->query_type   if defined $self->query_type;
    $options{'--vertical-type'}   = $self->subject_type if defined $self->subject_type;
    $options{'--session_colour'} = quotemeta($colour)   if defined $colour;
    my $dotter_opts = join(' ', map { "$_=$options{$_}" } keys %options);
    $dotter_opts .= " --reverse-horizontal -N" if $self->revcomp_subject;

    my $dotter_command =
        "dotter $dotter_opts $query_file $subject_file ; rm $query_file $subject_file ; echo 'Dotter finished'";

    if (my $pid = fork) {
        warn "$dotter_command running, pid $pid\n";
        return 1;
    }
    elsif (defined $pid) {
        { exec($dotter_command) }
        try {
            warn "Failed to exec '$dotter_command': $!";
            unlink $query_file, $subject_file
              or warn "Some input file(s) not tidied up: $!\n";
            warn "dotter launch aborted\n";
            close STDERR;
            close STDOUT;
        }; # no catch, just be sure to _exit
        POSIX::_exit(127); # avoid triggering DESTROY
    }
    else {
        confess "Can't fork: $!";
    }
    return;                     # never reached but keeps perlcritic happy
}

sub change_dashes_to_n {
    my( $self, $seq ) = @_;

    my $str = $seq->sequence_string;
    $str =~ tr/-/n/;
    return $seq->sequence_string($str);
}

1;

__END__

=head1 NAME - Bio::Otter::Utils::DotterLauncher

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

