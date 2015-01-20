
### Bio::Otter::Vulgar

package Bio::Otter::Vulgar;

use strict;
use warnings;

no if $] >= 5.018, warnings => "experimental::smartmatch";
use feature 'switch';

use Bio::Otter::Log::Log4perl 'logger';
use Readonly;

Readonly our @SUGAR_ORDER => qw(
    query_id
    query_start
    query_end
    query_strand
    target_id
    target_start
    target_end
    target_strand
    score
);

sub new {
    my ($pkg, @args) = @_;

    my %members;
    my $class = ref $pkg || $pkg;
    my $self = bless \%members, $class;

    my ($vulgar_string, $vulgar_comps_string);
    my %opts;

    if (scalar(@args) == 1) {
        # single arg is full vulgar string
        ($vulgar_string) = @args;
    } else {
        %opts = @args;
        $vulgar_string       = delete $opts{vulgar_string};
        $vulgar_comps_string = delete $opts{vulgar_comps_string};
    }

    my @align_comps;
    if ($vulgar_string) {
        my @vulgar_parts = split(' ', $vulgar_string);
        (@members{@SUGAR_ORDER}, @align_comps) = @vulgar_parts;
    } elsif ($vulgar_comps_string) {
        @align_comps = split(' ', $vulgar_comps_string);
    }
    $self->_align_comps(@align_comps) if @align_comps;

    # FIXME: validity checks on %members ?

    # Risks overwriting settings from vulgar_string
    @members{keys %opts} = values %opts;

    return $self;
}

sub copy {
    my ($self) = @_;
    my $new = $self->new(%$self);
    $new->_align_comps($self->_align_comps); # create new copy of array
    return $new;
}

sub query_id {
    my ($self, @args) = @_;
    ($self->{'query_id'}) = @args if @args;
    my $query_id = $self->{'query_id'};
    return $query_id;
}

sub query_start {
    my ($self, @args) = @_;
    ($self->{'query_start'}) = @args if @args;
    my $query_start = $self->{'query_start'};
    return $query_start;
}

sub query_end {
    my ($self, @args) = @_;
    ($self->{'query_end'}) = @args if @args;
    my $query_end = $self->{'query_end'};
    return $query_end;
}

sub query_strand {
    my ($self, @args) = @_;
    return $self->_strand('query_strand', @args);
}

sub query_strand_sense {
    my $self = shift;
    return $self->_strand_sense('query_strand');
}

sub query_type {
    my $self = shift;
    return $self->_type('query_strand');
}

sub query_is_protein {
    my $self = shift;
    return ($self->query_type eq 'P');
}

sub query_ensembl_coords {
    my $self = shift;
    return $self->_ensembl_coords('query');
}

sub set_query_from_ensembl {
    my ($self, @args) = @_;
    return $self->_set_coords_from_ensembl('query', @args);
}

sub target_id {
    my ($self, @args) = @_;
    ($self->{'target_id'}) = @args if @args;
    my $target_id = $self->{'target_id'};
    return $target_id;
}

sub target_start {
    my ($self, @args) = @_;
    ($self->{'target_start'}) = @args if @args;
    my $target_start = $self->{'target_start'};
    return $target_start;
}

sub target_end {
    my ($self, @args) = @_;
    ($self->{'target_end'}) = @args if @args;
    my $target_end = $self->{'target_end'};
    return $target_end;
}

sub target_strand {
    my ($self, @args) = @_;
    return $self->_strand('target_strand', @args);
}

sub target_strand_sense {
    my $self = shift;
    return $self->_strand_sense('target_strand');
}

sub target_type {
    my $self = shift;
    return $self->_type('target_strand');
}

sub target_is_protein {
    my $self = shift;
    return ($self->target_type eq 'P');
}

sub target_ensembl_coords {
    my $self = shift;
    return $self->_ensembl_coords('target');
}

sub set_target_from_ensembl {
    my ($self, @args) = @_;
    return $self->_set_coords_from_ensembl('target', @args);
}

sub apply_target_offset {
    my ($self, $offset) = @_;
    $self->target_start($self->target_start + $offset);
    $self->target_end(  $self->target_end   + $offset);
    return $self;
}

sub score {
    my ($self, @args) = @_;
    ($self->{'score'}) = @args if @args;
    my $score = $self->{'score'};
    return $score;
}

sub _strand {
    my ($self, $key, @args) = @_;
    if (@args) {
        my ($value) = @args;
        unless ($value =~ /^[+-.]$/) {
            if ($value == 1) {
                $value = '+';
            } elsif ($value == -1) {
                $value = '-';
            } else {
                $self->logger->logcroak("strand '$value' not valid");
            }
        }
        $self->{$key} = $value;
    }
    return $self->{$key};
}

sub _strand_sense { ## no critic (Subroutines::RequireFinalReturn)
    my ($self, $accessor) = @_;
    my $strand = $self->$accessor;
    return if not defined $strand;

    for ($strand) {
        when ($_ eq '+') { return  1; }
        when ($_ eq '-') { return -1; }
        when ($_ eq '.') { return  1; }
        default {
            $self->logger->logcroak("$accessor not '+', '-' or '.'");
        }
    }
}

sub _type {
    my ($self, $accessor) = @_;
    my $strand = $self->$accessor;
    return if not defined $strand;

    if ($strand eq '+' or $strand eq '-') {
        return 'N';
    } elsif ($strand eq '.') {
        return 'P';
    } else {
        $self->logger->logcroak("$accessor not '+', '-' or '.'");
    }
    return;                     # redundant but keeps perlcritic happy
}

sub _ensembl_coords {
    my ($self, $which) = @_;

    my ($start_acc, $end_acc, $ss_acc) = map { $which . $_ } qw( _start _end _strand_sense );
    my @coords = sort { $a <=> $b } ($self->$start_acc, $self->$end_acc);
    my $strand = $self->$ss_acc;

    return $coords[0]+1, $coords[1], $strand;
}

# Strand can be '.' to signal protein
sub _set_coords_from_ensembl {
    my ($self, $which, $start, $end, $strand) = @_;

    my ($start_acc, $end_acc, $strand_acc) = map { $which . $_ } qw( _start _end _strand );

    my @coords;
    if (defined $start and defined $end) {
        @coords = sort { $a <=> $b } ($start, $end);
        $coords[0] -= 1;
    }

    my $is_protein;
    $is_protein = 1 if $strand eq '.';

    if ($is_protein or $strand == 1) {
        $self->$start_acc($coords[0]);
        $self->$end_acc(  $coords[1]);
    } elsif ($strand == -1) {
        $self->$start_acc($coords[1]);
        $self->$end_acc(  $coords[0]);
    } else {
        $self->logger->logcroak("$strand_acc not 1, -1 or '.'");
    }
    $self->$strand_acc($strand);

    return $self->$start_acc, $self->$end_acc, $self->$strand_acc;
}

sub _align_comps {
    my ($self, @args) = @_;
    ($self->{'_align_comps'}) = [ @args ] if @args;
    my $_align_comps = $self->{'_align_comps'};
    return @$_align_comps;
}

sub n_elements {
    my ($self) = @_;
    return int(scalar($self->_align_comps)/3);
}

sub parse_align_comps {
    my ($self, $callback) = @_;

    my $okay = 1;

    my @align_comps = $self->_align_comps;
    while (@align_comps) {
        my ($type, $q_len, $t_len) = splice(@align_comps, 0, 3); # shift off 1st three
        unless ($type and defined $q_len and defined $t_len) {
            $self->logger->logcroak('Ran out of vulgar align_comps in mid-triplet');
        }
        $okay &&= $callback->($type, $q_len, $t_len);
    }

    return $okay;
}

sub string {
    my $self = shift;

    my $align_comps_string = $self->align_comps_string;
    return unless $align_comps_string;

    my $sugar_string = $self->sugar_string;
    return "$sugar_string $align_comps_string";
}

# FIXME: should warn when setting defaults?
sub sugar_string {
    my $self = shift;
    return sprintf(
        '%s %d %d %s %s %d %d %s %d',
        $self->query_id      || sprintf('Q_notset_0x%x', $self),
        $self->query_start   || 0,
        $self->query_end     || 0,
        $self->query_strand  || '+',
        $self->target_id     || sprintf('T_notset_0x%x', $self),
        $self->target_start  || 0,
        $self->target_end    || 0,
        $self->target_strand || '+',
        $self->score         || 0,
        );
}

sub align_comps_string {
    my $self = shift;

    my @align_comps = $self->_align_comps;
    return unless @align_comps;

    return join(' ', @align_comps);
}


1;

__END__

=head1 NAME - Bio::Otter::Vulgar

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

