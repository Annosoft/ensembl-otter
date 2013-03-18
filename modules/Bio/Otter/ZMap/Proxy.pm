
package Bio::Otter::ZMap::Proxy;

use strict;
use warnings;

sub new {
    my ($pkg, $zmap) = @_;
    my $new = { 'zmap' => $zmap };
    bless $new, $pkg;
    return $new;
}

sub DESTROY {
    my ($self) = @_;
    $self->{'zmap'}->destroy;
    return;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk
