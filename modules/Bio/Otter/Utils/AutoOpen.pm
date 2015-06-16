package Bio::Otter::Utils::AutoOpen;
use strict;
use warnings;
use Try::Tiny;
use Time::HiRes qw( gettimeofday tv_interval );

use Hum::Sort qw{ ace_sort };
use Bio::Otter::Log::Log4perl;


=head1 NAME

Bio::Otter::Utils::AutoOpen - helper to get a window opened "automatically"

=head1 DESCRIPTION

Consstructing the object starts the process, and it hooks itself onto
an after callback.  The object will forget itself when the work is
complete.  If it fails, the error will go to the MainLoop handler.

There isn't much public API, because the internals should be expected
to change with the GUI.

=head1 OPEN SYNTAX

The region opening syntax is similar to a filename path, but each
level has its own syntax variations and shortcuts.

In addition to the canonical syntax there are some shortcuts and
variations which may be easier to type.  These may need to change in
future.

=head2 By example

 --open human_dev                                 Dataset
 --open human_dev/chr12-38                        SequenceSet
 --open human_dev/chr12-38/1_000_000:2_000_000    Region, by coords
 --open human_dev/chr12-38/1_000_000+1_000_000    Region, by start + length
 --open 'human_dev/chr12-38/#5'                   Region, by clone index
 --open 'human_dev/chr12-38/#5..8'                Region, by clone indices
 --open human_dev/chr12-38/AC004803               Region, by name
 --open human_dev/chr12-38/AC004803-KC877505.1    Region, by start-end names

 --open human_dev/chr12-38/view:...               Region, read-only

 --open human_dev/chr12-38/AC004803/              As above + Load default columns

 -o D/12/v:AC004803/                              Using shortcut; read-only

=head2 Dataset

First element must name a dataset.  Shortcuts are

 h  human
 m  mouse
 z  zebrafish
 T  human_test
 D  human_dev

Other non-dataset features (Preference, LogWindow) could be linked.
Not implemented.

=head2 Chromosome

Second element should name a chromosome or subregion.

A plain number N will be taken to mean a shortcut to chrC<N>-<vv>, for
the latest version C<vv> where there is a choice.

=head2 Clone

Clone numbers are given in the form shown in the SessionWindow
C<#5..8> .

For matches by clone name, C<.SV> is optional and ignored.

For coordinates, underscores to mark digit groups are optional and
ignored.  They may be given as C<start:end> or C<start+length> .

Currently for chromosome coordinates, the range will be rounded to
clone boundaries.

The prefix C<view:> makes the session read-only, the default is as
configured in the C<~/.otter/config.ini> file.  C<v:> is a shortcut
for this.

=head2 Columns

The third C</> delimits a fourth element, which causes loading.

If the column specification is empty (trailing slash), load the
default columns for the species.

There is one other column specification C<=none> which switches
everything off for fastest load.

Suggestions for further syntax would be useful.

Beware that using this other than at the start of a session could
clear the user's column choice.


=head1 CAVEATS

This bypasses some parts of the UI to get the job done, hence those
parts are not tested by this route.

If multiple regions are opened, currently they will run in parallel.
Might be better to chain them on L</_done>.

=cut

sub new {
    my ($pkg, $SpeciesListWindow) = @_;
    my $self = { _SLW => $SpeciesListWindow };
    bless $self, $pkg;
    return $self;
}

sub hide_after {
    my ($self, @set) = @_;
    ($self->{hide_after}) = @set if @set;
    return $self->{hide_after};
}

sub _SLW {
    my ($self) = @_;
    return $self->{_SLW};
}

sub _more_work {
    my ($self) = @_;
    return @{ $self->{_work} } ? 1 : 0;
}

sub _take_work {
    my ($self) = @_;
    return shift @{ $self->{_work} };
}

sub path {
    my ($self) = @_;

    return $self->{_path};
}

sub parse_path {
    my ($self, $path) = @_;

    $self->{_path} = $path;
    my $work = $self->{_work} = [];

    my $t0 = $self->{t0} = [ gettimeofday() ];

    my ($ds, $asm_name, $pos, $load) = split '/', $path, 4;
    # take a 5th part to zoom / hunt?
    die "Open shortcut syntax: --open dataset[:seq_region]\n" unless $ds;

    $ds = $self->_expand_dataset_short_name($ds);
    my $want_write = 0;
    my $region;
    if ($pos) {
        ($want_write, $pos) = $self->_want_write_access($pos);
        $region = $self->_parse_start_end($pos);
    }

    if ($region) {
        my $slice = Bio::Otter::Lace::Slice->new;
        $slice->dsname($ds);
        $slice->ssname($asm_name);
        $slice->start($region->{'start'});
        $slice->end($region->{'end'});
        push @$work, ['open_slice', $slice, $want_write];
    }
    else {
        push @$work, [ open_dataset_by_name => $ds ];

        if ($asm_name) {
            push @$work, [ open_sequenceset_by_name => $asm_name ];
        }

        if ($pos) {
            unless ($want_write) {
                push @$work, [ 'open_region_readonly' ];
            }
            push @$work, $self->_init_pos($pos);
        }

        if (defined $load) {
            die "$self($path): Load Columns syntax is not yet defined"
              unless $load =~ /^(|=none)$/;
            push @$work, [ load_columns => $load ], [ 'load_columns_hide' ];
        }
    }

    $self->logger->info(sprintf("Queued %s at \$^T+%.2fs",
                                $path, tv_interval([$^T,0], $t0)));
    return $self->_hook;
}

sub _expand_dataset_short_name {
    my ($self, $name) = @_;

    my %expand = qw{ h human  m mouse  z zebrafish  T human_test  D human_dev };
    if ($expand{$name}) {
        $name = $expand{$name};
    }
    return $name;
}

sub _parse_start_end {
    my ($self, $pos) = @_;

    if (my ($start, $op, $end) = $pos =~ m{^(\d[0-9_]*)(:|\+)(\d[0-9_]*)$}) {
        foreach ($start, $end) { s/_//g }
        if ($op eq '+') {
            $end = $start + $end - 1;
        }
        return { start => $start, end => $end };
    }
    else {
        return;
    }
}

sub _want_write_access {
    my ($self, $pos) = @_;

    my $want_write = $pos =~ s/^v(iew)?:// ? 0 : 1;
    return ($want_write, $pos);
}

sub _init_pos {
    my ($self, $pos) = @_;

    if (my $region = $self->_parse_start_end($pos)) {
        return [ open_region_by_coords => $region->{'start'}, $region->{'end'} ];
    }

    if ($pos =~ m{^#(\d+)$}) {
        return [ open_region_by_index => $1, $1 ];
    }

    if ($pos =~ m{^#(\d+)\.\.(\d+)$}) {
        return [ open_region_by_index => $1, $2 ];
    }

    return [ open_region_by_names => split '-', $pos, 2 ];
}


sub logger {
    return Bio::Otter::Log::Log4perl->get_logger('AutoOpen');
}

sub _hook {
    my ($self) = @_;
    if ($self->_more_work) {
        my $mw = $self->_SLW->top_window;
        $mw->afterIdle([ $self, 'do_open' ]);
    } else {
        $self->_done;
    }
    return;
}

sub _done {
    my ($self) = @_;

    # we leave the mainwindow visible until we're done opening
    # my $mw = $self->_SLW->top_window;
    # $mw->iconify if $self->hide_after;

    $self->logger->info(sprintf("Finished %s in %.2fs",
                                $self->path, tv_interval($self->{t0})));
    return;
}

sub do_open {
    my ($self) = @_;

    try {
        my $next = $self->_take_work;
        my ($method, @arg) = @$next;
        die "Don't know how to ($method, @arg) yet" unless $self->can($method);
        $self->logger->debug("$method(@arg)");
        $self->$method(@arg);
    } catch {
        my $name = try { $self->path } catch { "$self" };
        die "While trying to AutoOpen '$name', $_";
    };

    return $self->_hook;
}

sub open_slice {
    my ($self, $slice, $write_access) = @_;

    if ($write_access) {
        $self->_SLW->open_Slice($slice);
    }
    else {
        $self->_SLW->open_Slice_read_only($slice);
    }
}

sub open_dataset_by_name {
    my ($self, $ds) = @_;

    my $ssc = $self->_SLW->open_dataset_by_name($ds);
    $self->{ssc} = $ssc; # a CanvasWindow::SequenceSetChooser
    # $ssc->top_window->iconify if $self->_more_work;
    return;
}

sub open_sequenceset_by_name {
    my ($self, $seq_region) = @_;
    my $ssc = $self->{ssc}
      or die "Cannot open_sequenceset_by_name without a CanvasWindow::SequenceSetChooser";

    if (my ($N) = $seq_region =~ /^([A-Z0-9]+)$/) {
        # want a shortcut to chr$N-$vv for largest $vv
        my $re = qr{^chr$N-\d+$};
        my $ds = $ssc->DataSet;
        my $ss_list  = $ds->get_all_visible_SequenceSets;
        my @match = sort { ace_sort($b, $a) } grep { $_->name =~ $re } @$ss_list;
        my ($take) = $match[0];
        die sprintf('Wanted %s => %s but found no match', $seq_region, $re)
          unless $take;
        $self->logger->info
          (sprintf('For %s, took %s to be %s (options were %s)',
                   $self->path, $seq_region, $take->name,
                   join ', ', map { $_->name } @match))
            if @match > 1;
        $seq_region = $take->name;
    }

    my $sn = $ssc->open_sequence_set_by_ssname_subset($seq_region, undef);
    $self->{sn} = $sn; # a CanvasWindow::SequenceNotes
    $sn->set_write_ifposs;
    # $sn->top_window->iconify if $self->_more_work;
    return;
}

sub open_region_readonly {
    my ($self, $start, $end) = @_;
    my $sn = $self->{sn}
      or die "Cannot open_region_readonly without CanvasWindow::SequenceNotes";
    $sn->set_read_only;     ### Means all further regions on chr will be read-only too!
    return;
}

sub open_region_by_coords {
    my ($self, $start, $end) = @_;
    my $sn = $self->{sn}
      or die "Cannot open_region_by_coords without CanvasWindow::SequenceNotes";
    my $cc = $sn->run_lace_on_slice($start, $end);
    $self->{cc} = $cc; # a MenuCanvasWindow::ColumnChooser
    return;
}

sub open_region_by_index {
    my ($self, $first, $last) = @_;
    my $sn = $self->{sn}
      or die "Cannot open_region_by_index without CanvasWindow::SequenceNotes";
    my $cs_list = $sn->get_CloneSequence_list; # ensures it is fetched
    my $ss = $sn->SequenceSet;
    my $max = @$cs_list; # indices are 1-based
    my $name = $sn->name; # or $ss->name?
    die "Invalid clone index range #$first..$last (incl.) on $name, valid is 1..$max\n"
      if $first < 1 || $first > $last || $first > $max || $last > $max;

    my @selected = @{$cs_list}[$first-1 .. $last-1];
    $ss->selected_CloneSequences(\@selected);
    return $self->_open_region_selected($sn);
}

sub open_region_by_names {
    my ($self, $start, $end) = @_;
    my $sn = $self->{sn}
      or die "Cannot open_region_by_hunt without CanvasWindow::SequenceNotes";
    my $ss = $sn->SequenceSet;

    foreach ($start, $end) { s/\.\d+$// }
    # this API matches ACC without .SV

    $ss->select_CloneSequences_by_start_end_accessions($start, $end);
    # can fail to find

    return $self->_open_region_selected($sn);
}

sub _open_region_selected {
    my ($self, $sn) = @_;
    my $cc = $sn->open_SequenceSet($self->path);
    $self->{cc} = $cc; # a MenuCanvasWindow::ColumnChooser
    return;
}


sub load_columns {
    my ($self, $load) = @_;
    my $cc = $self->{cc}
      or die "Cannot load_columns without MenuCanvasWindow::ColumnChooser";
    if ($load eq '=none') {
        $cc->change_selection('select_none');
    } else {
        $cc->change_selection('select_default');
    }
    $cc->load_filters;
    $self->{sw} = $cc->SessionWindow;
    return;
}

sub load_columns_hide {
    my ($self) = @_;
    my $cc = $self->{cc};
    my $cctw = $cc && $cc->top_window;
    $cctw->withdraw if $cctw && Tk::Exists($cctw);
    return;
}

sub DESTROY {
    my ($self) = @_;

    printf STDERR "Destroying AutoOpen '%s'\n", $self->path;
}

1;
