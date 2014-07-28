package Bio::Otter::Lace::OnTheFly;

use namespace::autoclean;
use Moose::Role;

requires 'build_target_seq';
requires 'build_builder';

use Bio::Otter::Lace::OnTheFly::QueryValidator;
use Bio::Otter::Lace::OnTheFly::Runner;
use Bio::Otter::Lace::OnTheFly::TargetSeq;

has 'query_validator' => (
    is      => 'ro',
    isa     => 'Bio::Otter::Lace::OnTheFly::QueryValidator',
    handles => [qw( confirmed_seqs seq_types seqs_for_type seqs_by_name seq_by_name )],
    writer  => '_set_query_validator',
    );

has 'target_seq_obj'  => (
    is     => 'ro',
    isa    => 'Bio::Otter::Lace::OnTheFly::TargetSeq',
    handles => {
        target_fasta_file => 'fasta_file',
        target_start      => 'start',
        target_end        => 'end',
        target_seq        => 'target_seq',
        target_all_repeat => 'all_repeat',
        },
    writer => '_set_target_seq_obj',
    );

has 'softmask_target' => ( is => 'ro', isa => 'Bool' );
has 'clear_existing'  => ( is => 'ro', isa => 'Bool' );

has 'aligner_options' => (
    traits => [ 'Hash' ],
    is  => 'ro',
    isa => 'HashRef',
    default => sub { {} },
    handles => {
        _set_aligner_option => 'set',
    },
    );

has 'aligner_query_type_options' => (
    is  => 'ro',
    isa => 'HashRef',
    default => sub { { dna => {}, protein => {} } },
    );

has 'bestn'    => (
    is => 'ro',
    isa => 'Int',
    trigger => sub { my ($self, $val) = @_; $self->_set_aligner_option('--bestn', $val) },
);

has 'maxintron'    => (
    is => 'ro',
    isa => 'Int',
    trigger => sub { my ($self, $val) = @_; $self->_set_aligner_option('--maxintron', $val) },
);

has 'logic_names' => (
    is  => 'ro',
    isa => 'ArrayRef[Str]',
    required => 1,
);

sub BUILD {
    my ($self, $params) = @_;

    $self->_set_query_validator( Bio::Otter::Lace::OnTheFly::QueryValidator->new($params));
    $self->_set_target_seq_obj( $self->build_target_seq($params) );

    return;
}

sub pre_launch_setup {
    my ($self, %opts) = @_;

    if ($self->clear_existing) {

        my $slice = $opts{slice};
        my $vega_dba = $slice->adaptor->db;
        my $analysis_a = $vega_dba->get_AnalysisAdaptor;
        my $dna_saf_a  = $vega_dba->get_DnaSplicedAlignFeatureAdaptor;
        my $pro_saf_a  = $vega_dba->get_ProteinSplicedAlignFeatureAdaptor;

        foreach my $logic_name (@{$self->logic_names}) {
            if (my $analysis = $analysis_a->fetch_by_logic_name($logic_name)) {
                my $saf_a = $logic_name =~ /protein/i ? $pro_saf_a : $dna_saf_a;
                $saf_a->remove_by_analysis_id($analysis->dbID);
            }
        }
    }
    return;
}

sub builders_for_each_type {
    my $self = shift;

    my @builders;
    foreach my $type ( $self->seq_types ) {
        push @builders, $self->build_builder(
            type               => $type,
            query_seqs         => $self->seqs_for_type($type),
            target             => $self->target_seq_obj,
            softmask_target    => $self->softmask_target,
            options            => $self->aligner_options,
            query_type_options => $self->aligner_query_type_options,
            );
    }
    return @builders;
}

# Default runner is a plain one
#
sub build_runner {
    my ($self, @params) = @_;
    return Bio::Otter::Lace::OnTheFly::Runner->new(@params);
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

# EOF
