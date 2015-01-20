package Bio::Otter::Lace::OnTheFly::Runner;

use namespace::autoclean;
use Moose;

with 'MooseX::Log::Log4perl';

use Bio::Otter::Lace::OnTheFly::Utils::ExonerateFormat qw( ryo_order sugar_order );
use Bio::Otter::Lace::OnTheFly::Utils::SeqList;
use Bio::Otter::Lace::OnTheFly::Utils::Types;

use Bio::Otter::GappedAlignment;
use Bio::Otter::Utils::RequireModule qw(require_module);

use Hum::FastaFileIO;

has request    => ( is       => 'ro',
                    isa      => 'Bio::Otter::Lace::DB::OTFRequest',
                    required => 1,
                    handles  => { analysis_name => 'logic_name' },
    );

has resultset_class => ( is => 'ro', isa => 'Str', default => 'Bio::Otter::Lace::OnTheFly::ResultSet' );

has _loaded_resultset_class => ( is       => 'ro',
                                 isa      => 'Str',
                                 lazy     => 1,
                                 builder  => '_require_resultset_class',
                                 init_arg => undef,
    );

sub _require_resultset_class {     ## no critic (Subroutines::ProhibitUnusedPrivateSubroutines)
    my $self = shift;
    my $class = $self->resultset_class;
    require_module($class);
    return $class;
}

has query_seqs => ( is       => 'ro',
                    isa      => 'SeqListClass',
                    lazy     => 1,
                    builder  => '_fetch_query_seqs',
    );

sub _fetch_query_seqs {     ## no critic (Subroutines::ProhibitUnusedPrivateSubroutines)
    my ($self) = @_;

    my $fasta_file = $self->request->query_file;

    my $qf_in = Hum::FastaFileIO->new("< ${fasta_file}");
    $qf_in->sequence_class($self->is_protein ? 'Hum::Sequence::Peptide' : 'Hum::Sequence::DNA');

    my @seqs = $qf_in->read_all_sequences;
    return Bio::Otter::Lace::OnTheFly::Utils::SeqList->new( seqs => [ @seqs ] );
}

sub is_protein {
    my $self = shift;
    my $is_protein = ($self->analysis_name =~ /protein/i);
    return $is_protein;
}

sub query_type {
    my $self = shift;
    return $self->is_protein ? 'protein' : 'dna';
}

sub run {
    my $self = shift;

    my $command = $self->request->command;
    my @command_line = $self->construct_command( $command, $self->request->args );
    $self->logger->info('Running: ', join ' ', @command_line);
    open my $raw_align, '-|', @command_line or $self->logger->logconfess("failed to run $command: $!");

    return $self->parse($raw_align);
}

sub parse {
    my ($self, $fh) = @_;

    my $rs_class = $self->_loaded_resultset_class;
    my $result_set = $rs_class->new(
        analysis_name => $self->analysis_name,
        is_protein    => $self->is_protein,
        query_seqs    => $self->query_seqs,
        );

    while (my $line = <$fh>) {
        $result_set->add_raw_line($line);

        # We only parse our RYO lines
        next unless $line =~ /^RESULT:/;
        my @line_parts = split(' ',$line);
        my (%ryo_result, @vulgar_comps);
        (@ryo_result{ryo_order()}, @vulgar_comps) = @line_parts;

        my $gapped_alignment = $self->_parse_vulgar(\%ryo_result, \@vulgar_comps);

        my $target_start = $self->request->target_start;
        $gapped_alignment->apply_target_offset($target_start - 1) if $target_start > 1;

        my $q_id = $gapped_alignment->query_id;
        $self->logger->info("RESULT found for ${q_id}");

        if ($result_set->hit_by_query_id($q_id)) {
            $self->log->warn("Already have result for '$q_id'");
        }
        $result_set->add_hit_by_query_id($q_id => $gapped_alignment);
    }

    return $result_set;
}

sub _parse_vulgar {
    my ($self, $ryo_result, $vulgar_comps) = @_;

    my $vulgar_string = join(' ', @{$ryo_result}{sugar_order()}, @$vulgar_comps);

    my $ga = Bio::Otter::GappedAlignment->from_vulgar($vulgar_string);

    $ga->percent_id($ryo_result->{_perc_id});
    $ga->gene_orientation($ryo_result->{_gene_orientation});

    $ga = $ga->reverse_alignment if $ga->gene_orientation eq '-';

    return $ga;
}

# FIXME: doesn't really belong here: more general
#
sub construct_command {
    my ($self, $command, $args) = @_;
    my @command_line = ( $command );
    foreach my $key ( keys %{$args} ) {
        if (defined (my $val = $args->{$key})) {
            push @command_line, $key, $val;
        } else {
            push @command_line, $key;
        }
    }
    return @command_line;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

# EOF
