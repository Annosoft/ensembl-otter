package Bio::Vega::Utils::Attributes;

use strict;
use warnings;

=head1 NAME

Bio::Vega::Utils::Attributes

=head1 DESCRIPTION

Provides shared method all_Attributes_string() to
L<Bio::Vega::Gene> and L<Bio::Vega::Transcript>, as a mixin.

=head2 B<all_Attributes_string>

Returns all of the attributes as a single string.

We drop any boolean attrib which is false, to avoid
mis-comparing 'absence of attrib' with 'attrib = 0',
which are logically identical.

=cut

my %is_boolean;
BEGIN {
    %is_boolean = map { $_ => 1 } qw(
        mRNA_start_NF
        mRNA_end_NF
        cds_start_NF
        cds_end_NF
    );
}

sub all_Attributes_string {
    my ($self) = @_;

    return join ('-',
        map {$_->code . '=' . $_->value}
        sort {$a->code cmp $b->code || $a->value cmp $b->value}
        grep {not($is_boolean{$_->code}) or $_->value}
        @{$self->get_all_Attributes});
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk
