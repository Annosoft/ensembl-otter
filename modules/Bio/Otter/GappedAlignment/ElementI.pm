
### Bio::Otter::GappedAlignment::ElementI

package Bio::Otter::GappedAlignment::ElementI;

use strict;
use warnings;

use List::Util qw(max);
use Log::Log4perl;
use Readonly;

use Bio::Otter::GappedAlignment::ElementTypes;

sub new {
    my ($class, $query_length, $target_length) = @_;

    my $pkg = ref($class) || $class;
    my $self = bless {}, $pkg;

    $self->query_length($query_length);
    $self->target_length($target_length);

    $self->validate;

    return $self;
}

sub make_copy {
    my $self = shift;
    return $self->new($self->query_length, $self->target_length);
}

sub divide {
    my ($self, $t_split_len, $protein_query) = @_;

    my $q_split_len = $t_split_len;
    my $t_split_rem;

    if ($protein_query) {
        $q_split_len = int($t_split_len / 3);
        $t_split_rem = $t_split_len % 3;

        $self->logger->debug("t_split_rem: $t_split_rem, q_split_len: $q_split_len");

        if ($t_split_rem) {
            $t_split_len -= $t_split_rem;
        }
    }

    my $q_rem = $self->query_length  - $q_split_len;
    my $t_rem = $self->target_length - $t_split_len;

    if ($t_rem <= 0 and $q_rem <= 0) {
        $self->logger->logcroak(sprintf("Cannot split %s by %d", $self->string, $t_split_len));
    }

    $self->logger->warn("q_rem: $q_rem, t_rem: $t_rem") if $q_rem < 0 or $t_rem < 0;
    $q_rem = 0 if $q_rem < 0;
    $t_rem = 0 if $t_rem < 0;

    my $q_split = $self->query_length  - $q_rem;
    my $t_split = $self->target_length - $t_rem;

    my (@left, @right);

    push @left, $self->new($q_split, $t_split);

    if ($t_split_rem) {

        if ($self->is_match) {
            push @left,  Bio::Otter::GappedAlignment::Element::SplitCodon->new(0, $t_split_rem);
            push @right, Bio::Otter::GappedAlignment::Element::SplitCodon->new(1, 3 - $t_split_rem);
        } else {
            $self->logger->logcluck("Non-match 'split codon' - not expected??");
        }

        $q_rem -= 1;
        $t_rem -= 3;

        $self->logger->warn("split codon; q_rem: $q_rem, t_rem: $t_rem") if $q_rem < 0 or $t_rem < 0;
        $q_rem = 0 if $q_rem < 0;
        $t_rem = 0 if $t_rem < 0;
    }

    push @right, $self->new($q_rem, $t_rem) if ($q_rem or $t_rem);

    return (\@left, \@right);
}

sub query_length {
    my ($self, $query_length) = @_;
    if (defined $query_length) {
        $self->{'_query_length'} = $query_length;
    }
    return $self->{'_query_length'};
}

sub target_length {
    my ($self, $target_length) = @_;
    if (defined $target_length) {
        $self->{'_target_length'} = $target_length;
    }
    return $self->{'_target_length'};
}

sub validate {
    return 1;
}

sub string {
    my $self = shift;
    return sprintf('%s %d %d', $self->type, $self->query_length, $self->target_length);
}

sub cigar_type {
    my $self = shift;
    # Pure virtual
    my $type = ucfirst $self->long_type;
    $self->logger->logcroak("cigar_type must be provided by child class '$type'");
    return;                     # not that we ever get here.
}

sub cigar_length {
    my $self = shift;
    return max($self->query_length, $self->target_length);
}

# Overridden as necessary
#
sub ensembl_cigar_type {
    my $self = shift;
    return $self->cigar_type;
}

sub ensembl_cigar_string {
    my $self = shift;
    my $len  = $self->cigar_length;
    my $type = $self->cigar_type;
    return $len > 1 ? $len . $type : $type;
}

sub is_intronic {
    my $self = shift;
    return $self->type =~ /^[35I]$/;
}

sub is_match {
    return;
}

sub logger {
    my $self = shift;
    return Log::Log4perl->get_logger(ref($self));
}

1;

__END__

=head1 NAME - Bio::Otter::GappedAlignment::ElementI

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

# EOF
