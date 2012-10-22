package Bio::Otter::Lace::OnTheFly::FastaFile;

## Moose provides these, but webpublish doesn't know that!
##
use strict;
use warnings;
##

use namespace::autoclean;
use Moose::Role;                # THIS IS A ROLE, not a class

requires 'fasta_sequences';
requires 'fasta_description';

use File::Temp;
use Hum::FastaFileIO;

has 'fasta_file'   => ( is => 'ro', isa => 'File::Temp',
                        lazy => 1, builder => '_build_fasta_file', init_arg => undef );

sub _build_fasta_file {         ## no critic (Subroutines::ProhibitUnusedPrivateSubroutines)
    my $self = shift;

    my $template = sprintf("otf_%s_%d_XXXXX", $self->fasta_description, $$);
    my $file = File::Temp->new(
        TEMPLATE => $template,
        TMPDIR   => 1,
        SUFFIX   => '.fa',
        UNLINK   => 1,
        );

    my $ts_out  = Hum::FastaFileIO->new("> $file");
    $ts_out->write_sequences( $self->fasta_sequences );
    $ts_out = undef;            # flush

    return $file;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

# EOF
