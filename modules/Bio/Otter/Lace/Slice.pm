package Bio::Otter::Lace::Slice;

use strict;
use warnings;

use Bio::EnsEMBL::Slice;
use Bio::EnsEMBL::CoordSystem;

sub new {
    my( $pkg,
        $Client, # object
        $dsname, # e.g. 'human'
        $ssname, # e.g. 'chr20-03'

        $csname, # e.g. 'chromosome'
        $csver,  # e.g. 'Otter'
        $seqname,# e.g. '20'
        $start,  # in the given coordinate system
        $end,    # in the given coordinate system
    ) = @_;

    # chromosome:Otter:chr6-17:2666323:2834369:1


    my $self = {
        '_Client'   => $Client,
        '_dsname'   => $dsname,
        '_ssname'   => $ssname,

        '_csname'   => $csname,
        '_csver'    => $csver  || '',
        '_seqname'  => $seqname,
        '_start'    => $start,
        '_end'      => $end,
    }; 

    return bless $self, $pkg;
}

sub Client {
    my( $self, $dummy ) = @_;

    die "You shouldn't need to change Client" if defined($dummy);

    return $self->{_Client};
}

sub dsname {
    my( $self, $dummy ) = @_;

    die "You shouldn't need to change dsname" if defined($dummy);

    return $self->{_dsname};
}

sub ssname {
    my( $self, $dummy ) = @_;

    die "You shouldn't need to change ssname" if defined($dummy);

    return $self->{_ssname};
}


sub csname {
    my( $self, $dummy ) = @_;

    die "You shouldn't need to change csname" if defined($dummy);

    return $self->{_csname};
}

sub csver {
    my( $self, $dummy ) = @_;

    die "You shouldn't need to change csver" if defined($dummy);

    return $self->{_csver};
}

sub seqname {
    my( $self, $dummy ) = @_;

    die "You shouldn't need to change seqname" if defined($dummy);

    return $self->{_seqname};
}

sub start {
    my( $self, $dummy ) = @_;

    die "You shouldn't need to change start" if defined($dummy);

    return $self->{_start};
}

sub end {
    my( $self, $dummy ) = @_;

    die "You shouldn't need to change end" if defined($dummy);

    return $self->{_end};
}

sub length { ## no critic(Subroutines::ProhibitBuiltinHomonyms)
    my ( $self ) = @_;

    return $self->end() - $self->start() + 1;
}

sub name {
    my( $self ) = @_;

    return sprintf "%s_%d-%d",
        $self->ssname,
        $self->start,
        $self->end;
}


sub toHash {
    my ($self) = @_;

    my $hash = {
            'dataset' => $self->dsname(),
            'type'    => $self->ssname(),

            'cs'      => $self->csname(),
            'csver'   => $self->csver(),
            'name'    => $self->seqname(),
            'start'   => $self->start(),
            'end'     => $self->end(),
    };

    return $hash;
}

sub create_detached_slice {
    my ($self) = @_;

    my $slice = Bio::EnsEMBL::Slice->new(
        -seq_region_name    => $self->ssname,
        -start              => $self->start,
        -end                => $self->end,
        -coord_system   => Bio::EnsEMBL::CoordSystem->new(
            -name           => $self->csname,
            -version        => $self->csver,
            -rank           => 2,
            -sequence_level => 0,
            -default        => 1,
        ),
    );
    return $slice;
}

sub DataSet {
    my ($self) = @_;

    return $self->Client->get_DataSet_by_name($self->dsname);
}

# ----------------------------------------------------------------------------------


sub get_assembly_dna {
    my ($self) = @_;
    
    my $response = $self->Client()->otter_response_content(
        'GET',
        'get_assembly_dna',
        {
            %{$self->toHash},
        },
    );
    
    my ($seq, @tiles) = split /\n/, $response;
    for (my $i = 0; $i < @tiles; $i++) {
        my ($start, $end, $ctg_name, $ctg_start, $ctg_end, $ctg_strand, $ctg_length) = split /\t/, $tiles[$i];
        $tiles[$i] = {
            start       => $start,
            end         => $end,
            ctg_name    => $ctg_name,
            ctg_start   => $ctg_start,
            ctg_end     => $ctg_end,
            ctg_strand  => $ctg_strand,
            ctg_length  => $ctg_length,
        };
    }
    return (lc $seq, @tiles);
}

sub get_region_xml {
    my ($self) = @_;

    my $client = $self->Client();

    if($client->debug()) {
        warn sprintf("Fetching data from chr %s %s-%s\n", $self->seqname(), $self->start(), $self->end() );
    }

    my $xml = $client->http_response_content( # should be unified with 'otter_response_content'
        'GET',
        'get_region',
        {
            %{$self->toHash},
            'trunc'     => $client->fetch_truncated_genes,
        },
    );

    return $xml;
}

sub lock_region_xml {
    my ($self) = @_;

    my $client = $self->Client();

    return $client->http_response_content(
        'GET',
        'lock_region',
        {
            %{$self->toHash},
            'hostname' => $client->client_hostname(),
        }
    );
}

sub dna_ace_data {
    my ($self) = @_;

    my $name = $self->name;

    my ($dna_str, @t_path) = $self->get_assembly_dna;

    my $ace_output = qq{\nSequence "$name"\n};

    foreach my $tile (@t_path) {
        my $start   = $tile->{'start'};
        my $end     = $tile->{'end'};
        my $strand  = $tile->{'ctg_strand'};
        if ($strand == -1) {
            ($start, $end) = ($end, $start);
        }
        $ace_output .= sprintf qq{Feature "Genomic_canonical" %d %d %f "%s-%d-%d-%s"\n},
            $start,
            $end,
            1.000,
            $tile->{'ctg_name'},
            $tile->{'ctg_start'},
            $tile->{'ctg_end'},
            $tile->{'ctg_strand'} == -1 ? 'minus' : 'plus';
    }
    
    my %seen_ctg;
    foreach my $tile (@t_path) {
        my $ctg_name = $tile->{'ctg_name'};
        next if $seen_ctg{$ctg_name};
        $seen_ctg{$ctg_name} = 1;
        $ace_output .= sprintf qq{\nSequence "%s"\nLength %d\n},
            $tile->{'ctg_name'},
            $tile->{'ctg_length'};
    }
    
    $ace_output .= qq{\nSequence : "$name"\n}
                 # . qq{Genomic_canonical\n}
                 # . qq{Method Genomic_canonical\n}
                 . qq{DNA "$name"\n}
                 . qq{\nDNA : "$name"\n};

    while ($dna_str =~ /(.{1,60})/g) {
        $ace_output .= "$1\n";
    }
    
    return $ace_output;
}

1;

__END__


=head1 NAME - Bio::Otter::Lace::Slice

=head1 AUTHOR

Leo Gordon B<email> lg4@sanger.ac.uk

