
### Bio::Otter::Mapping

package Bio::Otter::Mapping;

use XML::Simple;

use strict;
use warnings;

use Carp;

sub _equiv_new { ## no critic (Subroutines::RequireArgUnpacking)
    require Bio::Otter::Mapping::Equiv;
    return Bio::Otter::Mapping::Equiv->new(@_);
}

sub _map_new { ## no critic (Subroutines::RequireArgUnpacking)
    require Bio::Otter::Mapping::Map;
    return Bio::Otter::Mapping::Map->new(@_);
}

sub new_from_xml {
    my ($pkg, $xml) = @_;

    local $XML::Simple::PREFERRED_PARSER = 'XML::Parser';
    # configure expat for speed, also used in Bio::Vega::Transform

    my $data =
        XMLin($xml,
              ForceArray => [ qw( map maplet ) ],
              KeyAttr => {
              },
        );
    my $type = $data->{type};
    die "missing mapping type" unless $type;

    return
        ( ! $type ) ? die "missing mapping type" :
        ( $type eq 'none'  ) ? die "there is no mapping" :
        ( $type eq 'equiv' ) ? _equiv_new( 
            -chr => $data->{equiv_chr},
        ) :
        ( $type eq 'map' ) ? _map_new(
            -map => $data->{map}
        ) :
            die "invalid mapping type '${type}'";

}

1;

__END__

=head1 NAME - Bio::Otter::Mapping

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

