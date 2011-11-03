
### Bio::Otter::Lace::DataSet

package Bio::Otter::Lace::DataSet;

use strict;
use warnings;
use Carp;
use Scalar::Util 'weaken';
use URI::Escape qw( uri_escape );

use Bio::Otter::Filter;
use Bio::Otter::BAM;

sub new {
    my ( $pkg ) = @_;

    return bless {}, $pkg;
}

sub Client {
  my ( $self, $client ) = @_;
  if ($client) {
    $self->{'_Client'} = $client;
    weaken $self->{'_Client'};
  }
  $client = $self->{'_Client'};
  confess "No otter Client attached" unless $client;
  return $client;
}

sub load_client_config {
    my ( $self ) = @_;
    $self->_bam_load;
    $self->_filter_load;
    return;
}

sub name {
    my ( $self, $name ) = @_;

    if ($name) {
        $self->{'_name'} = $name;
    }
    return $self->{'_name'};
}

sub zmap_config {
    my ($self, $session) = @_;

    my $stanza = { %{ $self->config_section('zmap') } };

    my $columns_list = $self->config_value_list_merged('zmap_config', 'columns');
    $stanza->{columns} = $columns_list if @${columns_list};

    my $config = {
        'ZMap' => $stanza,
        'ZMapWindow' => $self->config_section('ZMapWindow'),
    };

    $self->_add_zmap_source_config($config, $session);
    $self->_add_zmap_bam_config($config, $session);

    return $config;
}

sub _add_zmap_source_config {
    my ($self, $config, $session) = @_;

    my $sources = $self->sources;
    my $stylesfile = $session->stylesfile;

    $config->{ZMap}{sources} =
        [ sort map { $_->name } @{$sources} ]
        if @${sources};

    my $columns      = { };
    my $styles       = { };
    my $descriptions = { };

    for my $source (@$sources) {

        $config->{$source->name} = {
            url         => $source->url($session),
            featuresets => $source->featuresets,
            delayed     => $source->delayed($session) ? 'true' : 'false',
            stylesfile  => $stylesfile,
            group       => 'always',
        };

        if ($source->zmap_column) {
            my $fsets = $columns->{$source->zmap_column} ||= [];
            push @{ $fsets }, @{$source->featuresets};
        }

        if ($source->zmap_style) {
            $styles->{$source->name} = $source->zmap_style;
        }

        if ($source->description) {
            $descriptions->{$source->name} = $source->description;
        }
    }

    $config->{'columns'}                = $columns      if keys %{$columns};
    $config->{'featureset-style'}       = $styles       if keys %{$styles};
    $config->{'featureset-description'} = $descriptions if keys %{$descriptions};

    return;
}

sub _add_zmap_bam_config {
    my ($self, $config, $session) = @_;

    # This handles special configuration parameters that are specific
    # to BAM sources, such as those relating to sequence and coverage
    # data.  The normal configuration stanzas for BAM sources are
    # already handled by _add_zmap_source_config().

    my $stylesfile = $session->stylesfile;
    my $slice      = $session->smart_slice;

    # must be careful here because different BAM objects may have the
    # same parent_column or parent_featureset

    my $column_featureset_hash = { };
    my $featureset_featureset_hash = { };

    for my $bam ( @{$self->bam_list} ) {
        my $bam_featureset = $bam->name;

        push @{$config->{ZMap}{'seq-data'}}, $bam_featureset;

        # coverage columns and featuresets
        my $coverage_column = $bam->parent_column;
        my $coverage_featureset = $bam->parent_featureset;
        next unless $coverage_column && $coverage_featureset;
        $column_featureset_hash->{$coverage_column}{$coverage_featureset}++;

        # related columns
        my $related_column = "${coverage_featureset}_reads";
        my $related_featureset = "${related_column}_features";
        push @{$config->{ZMap}{'seq-data'}}, $related_featureset;
        $column_featureset_hash->{$related_column}{$related_featureset}++;
        $featureset_featureset_hash->{$related_featureset}{$bam_featureset}++;

        for (
            [ "${bam_featureset}_coverage_plus",  $bam->coverage_plus,   1 ],
            [ "${bam_featureset}_coverage_minus", $bam->coverage_minus, -1 ],
            ) {
            my ( $featureset, $file, $strand ) = @{$_};
            next unless $file;
            push @{$config->{ZMap}{sources}}, $featureset;
            push @{$config->{featuresets}{$coverage_featureset}}, $featureset;
            $config->{'featureset-style'}{$coverage_featureset} = 'heatmap';
            $config->{'featureset-related'}{$coverage_featureset} = $related_column;
            $config->{'featureset-style'}{$featureset} = 'heatmap';
            $config->{'featureset-related'}{$featureset} = $related_column;
            my $query = {
                chr   => $slice->ssname,
                start => $slice->start,
                end   => $slice->end,
                ( map { ( $_ => $bam->$_ ) } qw( csver chr_prefix ) ),
                file   => $file,
                strand => $strand,
                gff_feature_source => $featureset,
                gff_version => 2,
            };
            my $query_string = _query_string($query);
            my $url = sprintf "pipe:///%s?%s", 'bigwig_get', $query_string;
            $config->{$featureset} = {
                featuresets => $featureset,
                delayed     => 'true',
                group       => 'always',
                stylesfile  => $stylesfile,
                url         => $url,
            };
        }
    }

    # add the columns to the ZMap configuration
    my @columns = sort keys %{$column_featureset_hash};
    push @{$config->{ZMap}{columns}}, sort @columns;
    $config->{columns}{$_} =
        [ sort keys %{$column_featureset_hash->{$_}} ]
        for @columns;
    $config->{featuresets}{$_} =
        [ sort keys %{$featureset_featureset_hash->{$_}} ]
        for keys %{$featureset_featureset_hash};

    return;
}

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

sub blixem_config {
    my ($self) = @_;

    my $config = {
        ( map {
            $_->name => {
                description => $_->description,
                args => $self->blixem_bam_args($_),
            },
          } @{$self->bam_list} ),
    };

    return $config;
}

sub blixem_bam_args {
    my ($self, $bam) = @_;

    my $args = join ' ', map {
        $bam->$_ ? sprintf '-%s=%s', $_, uri_escape($bam->$_) : ( );
    } @{$bam->bam_parameters};

    return $args;
}

sub _bam_load {
    my ( $self ) = @_;

    my $bam_by_name = $self->{_bam_by_name} = { };
    for my $name ( @{$self->config_keys("bam")} ) {
        my $config = $self->config_section("bam.${name}");
        eval { $bam_by_name->{$name} = Bio::Otter::BAM->new($name, $config); 1; } or
            warn sprintf "BAM section for ${name}: ignored: $@";
    }

    my $config = $self->config_section('bam_list');
    my @name_list = grep { $config->{$_} } keys %{$config};
    my $bam_list = $self->{_bam_list} =
        [ grep { defined } @{$bam_by_name}{@name_list} ];

    return;
}

sub bam_by_name {
    my ($self, $name) = @_;
    return $self->{_bam_by_name}{$name};
}

sub bam_list {
    my ($self) = @_;
    return $self->{_bam_list};
}

sub _filter_load {
    my ( $self ) = @_;

    my $filter_by_name = $self->{_filter_by_name} = { };
    for my $name ( @{$self->config_keys("filter")} ) {
        my $config = $self->config_section("filter.${name}");
        eval {
            my $filter= Bio::Otter::Filter->from_config($config);
            $filter->name($name);
            $filter_by_name->{$name} = $filter;
            1;
        }
        or warn sprintf "filter section for ${name}: ignored: $@";
    }

    my $filters = $self->{_filters} = [ ];
    my $config = $self->config_section("use_filters");
    $self->_filter_add($_, $config->{$_}) for keys %{$config};

    return;
}

sub _filter_add {
    my ( $self, $name, $wanted ) = @_;
    my $filter = $self->{_filter_by_name}{$name};
    return unless $filter;
    $filter->wanted($wanted);
    push @{$self->{_filters}}, $filter;
    return;
}

sub filter_by_name {
    my ($self, $name) = @_;
    return $self->{'_filter_by_name'}{$name};
}

sub filters {
    my ($self) = @_;
    return $self->{_filters};
}

sub sources {
    my ($self) = @_;
    return $self->{_sources} ||= [
        @{$self->filters},
        @{$self->bam_list},
        ];
}

sub config_section {
    my ($self, $section) = @_;
    return $self->Client->config_section($self->config_name, $section);
}

sub config_keys {
    my ($self, $key) = @_;
    return $self->Client->config_keys($self->config_name, $key);
}

sub config_value_list {
    my ($self, @keys) = @_;
    return $self->Client->config_value_list($self->config_name, @keys);
}

sub config_value_list_merged {
    my ($self, @keys) = @_;
    return $self->Client->config_value_list_merged($self->config_name, @keys);
}

sub config_name {
    my ($self) = @_;
    my $name = $self->ALIAS || $self->name;
    return $name;
}

sub meta_hash {
    my ($self) = @_;
    # Get all of meta table in one call
    return $self->{'_meta_hash'} ||=
        $self->Client->get_meta($self->name);
}

sub get_meta_value {
    my ($self, $key) = @_;

    my $values = $self->meta_hash->{$key};

    confess "No entry in meta table under key '$key'" if ! @{$values};
    confess "Multiple entries in meta table under key '$key'" if @{$values} > 1;

    return $values->[0];
}

sub vocab_locus {
    my ($self) = @_;
    return $self->{'_vocab_locus'} ||=
        $self->config_section('controlled_vocabulary_locus');
}

sub vocab_transcript {
    my ($self) = @_;
    return $self->{'_vocab_transcript'} ||=
        $self->config_section('controlled_vocabulary_transcript');
}

sub taxon {
    my ($self) = @_;

    unless ($self->{'_taxon_id'}) {
        $self->{'_taxon_id'} = $self->get_meta_value('species.taxonomy_id');
    }
    return $self->{'_taxon_id'};
}

sub species {
    my ($self) = @_;

    unless ($self->{'_species'}) {
        $self->{'_species'} = $self->get_meta_value('species.common_name');
    }
    return $self->{'_species'};
}

sub stable_id_prefix {
    my ($self) = @_;

    unless ($self->{'_stable_id_prefix'}) {
        my $pri = $self->get_meta_value('prefix.primary');
        my $spe = $self->get_meta_value('prefix.species');
        confess
"Need entries for both 'prefix.primary' and 'prefix.species' in otter meta table"
          unless $pri and $spe;
        $self->{'_stable_id_prefix'} = "$pri$spe";
    }
    return $self->{'_stable_id_prefix'};
}

sub sequence_sets_cached {
  my ( $self, $ss ) = @_;
  if ($ss) {
    $self->{'_sequence_sets'} = $ss;
  }
  return $self->{'_sequence_sets'};
}

sub get_all_visible_SequenceSets {
  my ( $self) = @_;
  my $ss_list= $self->get_all_SequenceSets();
  my $visible = [];
  foreach my $ss (@$ss_list) {
     unless($ss->is_hidden) {
        push @$visible, $ss;
     }
  }
  return $visible;
}

sub get_all_SequenceSets {
  my ($self)=@_;
  my $seq_sets =$self->sequence_sets_cached;
  return $seq_sets if (defined($seq_sets) && scalar(@$seq_sets));

  my $client = $self->Client;
  $seq_sets = $client->get_all_SequenceSets_for_DataSet($self);
  $self->sequence_sets_cached($seq_sets);

  return $seq_sets;
}

sub get_SequenceSet_by_name {
    my ( $self, $name ) = @_;
    confess "missing name argument" unless $name;
    my $ss_list = $self->get_all_SequenceSets;
    foreach my $ss (@$ss_list) {
        if ($name eq $ss->name) {
            return $ss;
        }
    }
    confess "No SequenceSet called '$name'";
}

sub selected_SequenceSet {
    my ( $self, $selected_SequenceSet ) = @_;
    if ($selected_SequenceSet) {
        $self->{'_selected_SequenceSet'} = $selected_SequenceSet;
    }
    return $self->{'_selected_SequenceSet'};
}

sub fetch_all_CloneSequences_for_selected_SequenceSet {
    my ( $self ) = @_;

    my $ss = $self->selected_SequenceSet
        or confess "No SequenceSet is selected";
    return $self->fetch_all_CloneSequences_for_SequenceSet($ss);
}

sub fetch_all_CloneSequences_for_SequenceSet {
    my ( $self, $ss ) = @_;
    confess "Missing SequenceSet argument" unless $ss;
    my $client = $self->Client;
    my $cs_list=$client->get_all_CloneSequences_for_DataSet_SequenceSet($self, $ss);
    return $cs_list;
}

sub fetch_notes_locks_status_for_SequenceSet {
    my ( $self, $ss ) = @_;
    confess "Missing SequenceSet argument" unless $ss;
    my $client = $self->Client;

    $client->fetch_all_SequenceNotes_for_DataSet_SequenceSet($self, $ss);
    $client->lock_refresh_for_DataSet_SequenceSet($self, $ss);
    $client->status_refresh_for_DataSet_SequenceSet($self, $ss);

    return;
}

#
# DB connection handling
#-------------------------------------------------------------------------------
#
sub get_cached_DBAdaptor {
    my ( $self ) = @_;

    unless($self->{'_dba_cache'}){
        $self->{'_dba_cache'} = $self->make_Vega_DBAdaptor;
        $self->_attach_DNA_DBAdaptor($self->{'_dba_cache'});
    }
    #warn "OTTER DBADAPTOR = '$dba'";
    return $self->{'_dba_cache'};
}

sub make_EnsEMBL_DBAdaptor {
    my ( $self ) = @_;

    require Bio::EnsEMBL::DBSQL::DBAdaptor;
    return $self->_make_DBAdaptor_with_class('Bio::EnsEMBL::DBSQL::DBAdaptor');
}

sub make_Vega_DBAdaptor {
    my ( $self ) = @_;

    require Bio::Vega::DBSQL::DBAdaptor;
    return $self->_make_DBAdaptor_with_class('Bio::Vega::DBSQL::DBAdaptor');
}

sub _make_DBAdaptor_with_class {
    my ( $self, $class ) = @_;

    my (@args) = (
        # Extra arguments to stop Bio::EnsEMBL::Registry issuing warnings
        -GROUP      => "otter:$class",
        -SPECIES    => $self->name,
        );

    foreach my $prop ($self->list_all_db_properties) {
        if (my $val = $self->$prop()) {
            push(@args, "-$prop", $val);
        }
    }

    return $class->new(@args);
}
sub _attach_DNA_DBAdaptor{
    my ( $self, $dba ) = @_;

    return unless $dba;

    my (@ott_args, @dna_args);
    foreach my $this ($self->list_all_db_properties) {
        if (my ($prop) = $this =~ /^DNA_(\w+)/) {
            if (my $val = $self->$this()) {
                push(@dna_args, "-$prop", $val);
                push(@ott_args, "-$prop", $self->$prop());
            }
        }
    }

    if(("@dna_args" eq "@ott_args") && @dna_args){
        #warn "They are the same the DBAdaptor will just return itself\n";
    }elsif(@dna_args){
        #warn "dna_args: @dna_args\n";
        my $dnadb = Bio::EnsEMBL::DBSQL::DBAdaptor->new(
            @dna_args,
            # Extra arguments to stop Bio::EnsEMBL::Registry issuing warnings
            -GROUP      => 'dnadb',
            -SPECIES    => $self->name,
            );
        $dba->dnadb($dnadb);
    }else{
        warn "No DNA_* options found. *** CHECK species.dat ***\n";
    }

    return;
}

sub list_all_db_properties {
    return qw{
        HOST
        USER
        DNA_PASS
        PASS
        DBNAME
        TYPE
        DNA_PORT
        DNA_HOST
        DNA_USER
        DNA_DBNAME
        PORT
        ALIAS
        };
}

sub HOST {
    my ( $self, $HOST ) = @_;

    if(defined($HOST)) {
        $self->{'_HOST'} = $HOST;
    }
    return $self->{'_HOST'};
}

sub USER {
    my ( $self, $USER ) = @_;

    if(defined($USER)) {
        $self->{'_USER'} = $USER;
    }
    return $self->{'_USER'};
}

sub DNA_PASS {
    my ( $self, $DNA_PASS ) = @_;

    if(defined($DNA_PASS)) {
        $self->{'_DNA_PASS'} = $DNA_PASS;
    }
    return $self->{'_DNA_PASS'};
}

sub PASS {
    my ( $self, $PASS ) = @_;

    if(defined($PASS)) {
        $self->{'_PASS'} = $PASS;
    }
    return $self->{'_PASS'};
}

sub DBNAME {
    my ( $self, $DBNAME ) = @_;

    if(defined($DBNAME)) {
        $self->{'_DBNAME'} = $DBNAME;
    }
    return $self->{'_DBNAME'};
}

sub TYPE {
    my ( $self, $TYPE ) = @_;

    if(defined($TYPE)) {
        $self->{'_TYPE'} = $TYPE;
    }
    return $self->{'_TYPE'};
}

sub DNA_PORT {
    my ( $self, $DNA_PORT ) = @_;

    if(defined($DNA_PORT)) {
        $self->{'_DNA_PORT'} = $DNA_PORT;
    }
    return $self->{'_DNA_PORT'};
}

sub DNA_HOST {
    my ( $self, $DNA_HOST ) = @_;

    if(defined($DNA_HOST)) {
        $self->{'_DNA_HOST'} = $DNA_HOST;
    }
    return $self->{'_DNA_HOST'};
}

sub DNA_USER {
    my ( $self, $DNA_USER ) = @_;

    if(defined($DNA_USER)) {
        $self->{'_DNA_USER'} = $DNA_USER;
    }
    return $self->{'_DNA_USER'};
}
sub DNA_DBNAME {
    my ( $self, $DNA_DBNAME ) = @_;

    if(defined($DNA_DBNAME)) {
        $self->{'_DNA_DBNAME'} = $DNA_DBNAME;
    }
    return $self->{'_DNA_DBNAME'};
}
sub PORT {
    my ( $self, $PORT ) = @_;

    if(defined($PORT)) {
        $self->{'_PORT'} = $PORT;
    }
    return $self->{'_PORT'};
}

sub ALIAS {
    my ( $self, $ALIAS ) = @_;

    if(defined($ALIAS)) {
        $self->{'_ALIAS'} = $ALIAS;
    }
    return $self->{'_ALIAS'};
}

1;

__END__

=head1 NAME - Bio::Otter::Lace::DataSet

=head1 DESCRIPTION

The B<Bio::Otter::Lace> objects are designed for
use with the annotators' B<otterlace> interface,
where simple data objects for use behind the
graphical interface of the long-running client
are needed.  The standard Ensembl DBAdaptor
scheme was not used so that the database handle
can be dropped.  (Because of the DBAdaptor system
design, the database connection is usually only
dropped when all the data objects go out of
scope.)

There are also objects to represent the extra
tables found in the B<lace.sql> file in the otter
distribution (such as sequence sets and notes).

=head2 DataSet

The B<DataSet> object represents an entry in the
B<species.dat> file, which is, usually, a species
served by the otter server.

The DataSet object has an Ensembl B<DBAdaptor> -
it is the only object in the Lace system that
does.  It contains methods for saving data
to the extra tables defined in B<lace.sql>, and
which are represented by the other Lace data
objects.

Each DataSet contains one or more
B<SequenceSet>s.

=head2 SequenceSet

A SequenceSet is any list of clones that
annotators are working on, most often a
contiguous region of a genome.  Each SequenceSet
has a list of B<CloneSequence> objects.

=head2 CloneSequence

A CloneSequence is a container for some of the
data found in the Ensembl B<Clone> and B<Contig>
objects and in the B<assembly> table.  It has
zero or more B<SequenceNotes>, and, if there are
any, one of them is designated the current (most
recent) SeqeuenceNote.

=head2 SequenceNote

This is a remark added by an annotator to the
annotation interface to aid tracking the progress
of annotation.

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

