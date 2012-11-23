
### Bio::Otter::BAM

package Bio::Otter::BAM;

use strict;
use warnings;

use Carp;

use URI::Escape qw( uri_escape );

my @keys = qw( description file csver );

sub new {
    my ($pkg, $name, $config) = @_;

    for (@keys) {
        confess "missing BAM configuration parameter: $_"
            unless defined $config->{$_};
    }

    my $self = { name => $name, %{$config} };
    bless $self, $pkg;

    return $self;
}

sub name {
    my ($self) = @_;
    return $self->{name};
}

sub description {
    my ($self) = @_;
    return $self->{description};
}

sub file {
    my ($self) = @_;
    return $self->{file};
}

sub csver {
    my ($self) = @_;
    return $self->{csver};
}

sub parent_column {
    my ($self) = @_;
    return $self->{parent_column};
}

sub parent_featureset {
    my ($self) = @_;
    return $self->{parent_featureset};
}

sub coverage_plus {
    my ($self) = @_;
    return $self->{coverage_plus};
}

sub coverage_minus {
    my ($self) = @_;
    return $self->{coverage_minus};
}

# source methods

sub featuresets {
    my ($self) = @_;
    return [ $self->name ];
}

sub zmap_column { return; }
sub zmap_style  { return 'short-read'; }

sub url {
    my ($self, $session) = @_;
    my $query_string = _query_string($self->url_query($session));
    return sprintf "pipe:///%s?%s", $self->script_name, $query_string,
}

sub script_name {
    return "bam_get_align";
}

# GFF methods 

sub gff_feature_source {
    my ($self) = @_;
    return $self->name;
}

my $bam_parameters = [ qw(
    file
    csver
    gff_feature_source
    ) ];

sub bam_parameters {
    return $bam_parameters;
}

sub url_query {
    my ($self, $session) = @_;
    my $slice = $session->smart_slice;
    my $query = {
        -chr   => $slice->ssname,
        -start => $slice->start,
        -end   => $slice->end,
        ( map { ( "-$_" => $self->$_ ) } @{$bam_parameters} ),
        gff_version => 2,
    };
    return $query;
}

# NB: the following subroutines are *not* methods

sub _query_string {
    my ($query) = @_;
    my $arguments = [ ];
    for my $key (sort keys %{$query}) {
        my $value = $query->{$key};
        next unless defined $value;
        push @{$arguments}, sprintf '-%s=%s', $key, uri_escape($value);
    }
    my $query_string = join '&', @{$arguments};
    return $query_string;
}

1;

__END__

=head1 NAME - Bio::Otter::BAM

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

