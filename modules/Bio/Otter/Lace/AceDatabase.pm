
### Bio::Otter::Lace::AceDatabase

package Bio::Otter::Lace::AceDatabase;

use strict;
use warnings;
use Carp;

use Fcntl qw{ O_WRONLY O_CREAT };
use Config::IniFiles;
use Log::Log4perl;
use Try::Tiny;
use Scalar::Util 'weaken';

use Bio::Vega::Region;
use Bio::Vega::Transform::Otter::Ace;
use Bio::Vega::AceConverter;
use Bio::Vega::Transform::XML;

use Bio::Otter::Debug;
use Bio::Otter::Lace::AccessionTypeCache;
use Bio::Otter::Lace::DB;
use Bio::Otter::Lace::Slice; # a new kind of Slice that knows how to get pipeline data
use Bio::Otter::Lace::ProcessGFF;
use Bio::Otter::Utils::Config::Ini qw( config_ini_format );

use Hum::Ace::LocalServer;
use Hum::Ace::MethodCollection;
use Hum::ZMapStyleCollection;

use Hum::Conf qw{ PFETCH_SERVER_LIST };


Bio::Otter::Debug->add_keys(qw(
    XRemote
    Zircon
    ));

sub new {
    my ($pkg) = @_;

    return bless {}, $pkg;
}

sub Client {
    my ($self, $client) = @_;

    if ($client) {
        $self->{'_Client'} = $client;
        $self->colour( $self->next_session_colour );
    }
    return $self->{'_Client'};
}

sub AccessionTypeCache {
    my ($self) = @_;

    my $cache = $self->{'_AccessionTypeCache'};
    unless ($cache) {
        $cache = Bio::Otter::Lace::AccessionTypeCache->new;
        $cache->Client($self->Client);
        $cache->DB($self->DB);
        $self->{'_AccessionTypeCache'} = $cache;
    }
    return $cache;
}

sub DB {
    my ($self) = @_;

    my $db = $self->{'_sqlite_database'}
        ||= Bio::Otter::Lace::DB->new($self->home, $self->Client);
    return $db;
}

sub load_dataset_info {
    my ($self) = @_;
    return $self->DB->load_dataset_info($self->DataSet);
}

sub write_access {
    my ($self, $flag) = @_;

    if (defined $flag) {
        $flag = $flag ? 1 : 0;
        $self->DB->set_tag_value('write_access', $flag);
        return $flag;
    }
    else {
        return $self->DB->get_tag_value('write_access');
    }
}

sub home {
    my ($self, $home) = @_;

    if ($home) {
        $self->{'_home'} = $home;
    }
    return $self->{'_home'};
}

sub name {
    my ($self, $name) = @_;

    if ($name) {
        $self->DB->set_tag_value('name', $name);
        return $name;
    }
    else {
        return $self->DB->get_tag_value('name');
    }
}

sub unsaved_changes {
    my ($self, $flag) = @_;

    if (defined $flag) {
        $flag = $flag ? 1 : 0;
        $self->DB->set_tag_value('unsaved_changes', $flag);
        return $flag;
    }
    else {
        return $self->DB->get_tag_value('unsaved_changes');
    }
}

sub save_region_xml {
    my ($self, $xml) = @_;

    # Remove the locus and features to make data smaller
    $xml =~ s{<locus>.*</locus>}{}s;
    $xml =~ s{<feature_set>.*</feature_set>}{}s;

    $self->DB->set_tag_value('region_xml', $xml);

    return;
}

sub fetch_region_xml {
    my ($self) = @_;

    return $self->DB->get_tag_value('region_xml');
}

sub save_lock_region_xml {
    my ($self, $xml) = @_;

    $self->DB->set_tag_value('lock_region_xml', $xml);

    return;
}

sub fetch_lock_region_xml {
    my ($self) = @_;

    return $self->DB->get_tag_value('lock_region_xml');
}

sub tace {
    my ($self, $tace) = @_;

    if ($tace) {
        $self->{'_tace'} = $tace;
    }
    return $self->{'_tace'} || 'tace';
}


# It's more of a "don't delete this directory" flag.  It is cleared
# while closing the session iff saving is done or not wanted.
sub error_flag {
    my ($self, $error_flag) = @_;

    if (defined $error_flag) {
        $self->{'_error_flag'} = $error_flag;
    }
    return ($self->{'_error_flag'} ? 1 : 0);
}

sub post_exit_callback {
    my ($self, $post_exit_callback) = @_;

    if ($post_exit_callback) {
        $self->{'_post_exit_callback'} = $post_exit_callback;
    }
    return $self->{'_post_exit_callback'};
}

sub MethodCollection {
    my ($self) = @_;
    return $self->{'_MethodCollection'} ||=
        _MethodCollection($self->Client);
}

# not a method, possibly belongs elsewhere
sub _MethodCollection {
    my ($client) = @_;

    my $otter_styles = $client->get_otter_styles;
    my $style_collection =
        Hum::ZMapStyleCollection->new_from_string($otter_styles);

    my $methods_ace = $client->get_methods_ace;
    my $method_collection =
        Hum::Ace::MethodCollection->new_from_string($methods_ace, $style_collection);
    $method_collection->process_for_otterlace;

    return $method_collection;
}

sub add_acefile {
    my ($self, $acefile) = @_;

    my $af = $self->{'_acefile_list'} ||= [];
    push(@$af, $acefile);
    return;
}

sub list_all_acefiles {
    my ($self) = @_;

    if (my $af = $self->{'_acefile_list'}) {
        return @$af;
    } else {
        return;
    }
}

sub empty_acefile_list {
    my ($self) = @_;

    $self->{'_acefile_list'} = undef;

    return;
}

sub init_AceDatabase {
    my ($self) = @_;

    my $xml_string = $self->http_response_content(
        'GET', 'get_region');
    $self->write_file('01_before.xml', $xml_string);

    my $parser = Bio::Vega::Transform::Otter::Ace->new;
    $parser->parse($xml_string);
    $self->write_otter_acefile($parser);
    $self->write_dna_data;
    $self->write_methods_acefile;

    $self->save_region_xml($xml_string);

    $self->initialize_database;

    return;
}

sub write_otter_acefile {
    my ($self, $parser) = @_;

    # Storing ace_text in a file
    my $ace_filename = $self->home . '/rawdata/otter.ace';
    open my $ace_fh, '>', $ace_filename or die "Can't write to '$ace_filename'";
    print $ace_fh $parser->make_ace;
    close $ace_fh or confess "Error writing to '$ace_filename' : $!";
    $self->add_acefile($ace_filename);

    return;
}

sub try_to_lock_the_block {
    my ($self) = @_;

    my $lock_xml = $self->http_response_content(
        'GET', 'lock_region', { 'hostname' => $self->Client->client_hostname });
    $self->save_lock_region_xml($lock_xml) if $lock_xml;

    return;
}

sub write_file {
    my ($self, $file_name, $content) = @_;

    my $full_file = join('/', $self->home, $file_name);
    open my $LF, '>', $full_file or die "Can't write to '$full_file'; $!";
    print $LF $content;
    close $LF or die "Error writing to '$full_file'; $!";

    return;
}

sub read_file {
    my ($self, $file_name) = @_;

    local $/ = undef;
    my $full_file = join('/', $self->home, $file_name);
    open my $RF, '<', $full_file or die "Can't read '$full_file'; $!";
    my $content = <$RF>;
    close $RF or die "Error reading '$full_file'; $!";
    return $content;
}

sub recover_slice_from_region_xml {
    my ($self) = @_;

    my $client = $self->Client or die "No Client attached";

    my $xml = $self->fetch_region_xml || $self->fetch_lock_region_xml;
    unless ($xml) {
        confess "Could not fetch XML from SQLite DB to create smart slice";
    }

    my $parser = Bio::Vega::Transform::Otter->new;
    $parser->parse($xml);
    my $chr_slice = $parser->get_ChromosomeSlice;

    my $slice = Bio::Otter::Lace::Slice->new(
        $client,
        $parser->species,
        $chr_slice->seq_region_name,
        $chr_slice->coord_system->name,
        $chr_slice->coord_system->version,
        $parser->chromosome_name,
        $chr_slice->start,
        $chr_slice->end,
        );
    $self->slice($slice);

    return;
}

sub slice {
    my ($self, $slice) = @_;

    if ($slice) {
        $self->{'_offset'} = undef;
        $self->{'_slice'} = $slice;
    }
    return $self->{'_slice'};
}

# The seq_region in the local DB is created and stored lazily when first required.
#
sub db_slice {
    my ($self) = @_;

    my $db_slice = $self->{'_db_slice'};
    return $db_slice if $db_slice;

    my $ensembl_slice = $self->slice->ensembl_slice;

    # If this is a recovered session we will already have the seq_region in the local DB
    my $slice_adaptor = $self->DB->vega_dba->get_SliceAdaptor;
    my $db_seq_region = $slice_adaptor->fetch_by_region(
        $ensembl_slice->coord_system->name,
        $ensembl_slice->seq_region_name,
        );

    unless ($db_seq_region) {

        # db_seq_region's coord_system needs to be the one already in the DB.
        my $cs_adaptor = $self->DB->vega_dba->get_CoordSystemAdaptor;
        my $cs = $cs_adaptor->fetch_by_name($ensembl_slice->coord_system->name, $ensembl_slice->coord_system->version);

        # db_seq_region must start from 1
        my $db_seq_region_parameters = {
            %$ensembl_slice,
            coord_system      => $cs,
            start             => 1,
            seq_region_length => $ensembl_slice->end,
        };
        $db_seq_region = Bio::EnsEMBL::Slice->new_fast($db_seq_region_parameters);

        $slice_adaptor->store($db_seq_region);
    }

    $db_slice = $db_seq_region->sub_Slice($ensembl_slice->start, $ensembl_slice->end);
    return $self->{'_db_slice'} = $db_slice;
}

sub slice_name {
    my ($self) = @_;

    my $slice_name;
    unless ($slice_name = $self->{'_slice_name'}) {
        my @slice_list = $self->aceperl_db_handle->fetch(Assembly => '*');
        my @slice_names = map { $_->name } @slice_list;
        die "Error: more than 1 assembly in database: @slice_names"
            if @slice_names > 1;
        $slice_name = $self->{'_slice_name'} = $slice_names[0];
    }

    return $slice_name;
}

sub session_colourset {
    my ($self) = @_;
    my $colours = $self->Client->config_value('session_colourset')
      || '';
    my (@col, @bad, $M);
    try {
        $M = try { MainWindow->new }; # optional, to avoid hard dependency
        foreach my $col (split / /, $colours) {
            if (try { $M->configure(-background => $col); 1 } # colour is valid
                || !$M) { # assume colour is valid
                push @col, $col;
            } else {
                push @bad, $col;
            }
        }
    } finally {
        $M->destroy if $M && Tk::Exists($M);
    };
    warn "Ignored invalid [client]session_colourset values (@bad).  RGB may be given like '#fab' or '#ffaabb'" if @bad;
    push @col, qw( red green blue ) if @col < 3;
    return @col;
}

# Get as a plain string.
# Set as SCALARref, held also below (but weakened)
sub colour {
    my ($self, $set) = @_;
    $self->{'_colour'} = $set if defined $set;
    return $self->{'_colour'} ? ${ $self->{'_colour'} } : ();
}

{
    my %colour_in_use; # key = colour, value = list of weakened SCALARref
    sub next_session_colour {
        my ($self) = @_;
        my @col = $self->session_colourset;
        my %prio; # key=colour, value=priority
        @prio{@col} = reverse(1 .. scalar @col);

        # Remove no-longer-used
        while (my ($col, $use) = each %colour_in_use) {
            if (@$use) {
                # colour in use, now or recently
                my @use = grep { defined } @$use;
                for (my $i=0; $i<@use; $i++) { weaken($use[$i]) }
                $colour_in_use{$col} = \@use;
                $prio{$col} = -@use # set negative or zero priority
                  +($prio{$col} / 1000); # collision buster
            } else {
                # colour became unused last time, forget it
                delete $colour_in_use{$col};
            }
        }

        # Choose the next & remember
        my ($next) = sort { $prio{$b} <=> $prio{$a} } keys %prio;
        my $colref = \$next;
        push @{ $colour_in_use{$next} }, $colref;
        weaken($colour_in_use{$next}->[-1]);
        return $colref;
    }
}

my $gtkrc = <<'GTKRC'

style "zmap-focus-view-frame" {
  bg[NORMAL] = "gold" 
}

widget "*.zmap-focus-view" style "zmap-focus-view-frame"

style "infopanel-labels" {
  bg[NORMAL] = "white" 
}

widget "*.zmap-control-infopanel" style "infopanel-labels"

style "menu-titles" {
  fg[INSENSITIVE] = "blue" 
}

widget "*.zmap-menu-title.*" style "menu-titles"

style "default-species" {
  bg[NORMAL] = "gold" 
}
GTKRC
    ;

sub zmap_dir_init {
    my ($self) = @_;

    my $dir = $self->zmap_dir;
    unless (-d $dir) {
        mkdir $dir or confess "failed to create the directory '$dir': $!\n";
    }

    $self->MethodCollection->ZMapStyleCollection->write_to_file($self->stylesfile);

    $self->zmap_config_write('.gtkrc',   $gtkrc);
    $self->zmap_config_write('ZMap',     config_ini_format($self->zmap_config, 'ZMap'));
    $self->zmap_config_write('blixemrc', config_ini_format($self->blixem_config, 'blixem'));

    return;
}

sub zmap_config_write {
    my ($self, $file, $config) = @_;

    my $path = sprintf "%s/%s", $self->zmap_dir, $file;
    open my $fh, '>', $path
        or confess "Can't write to '$path'; $!";
    print $fh $config;
    close $fh
      or confess "Error writing to '$path'; $!";

    return;
}

sub zmap_config {
    my ($self) = @_;

    my $config = $self->ace_config;
    _config_merge($config, $self->_zmap_config);
    _config_merge($config, $self->DataSet->zmap_config($self));

    return $config;
}

sub _zmap_config {
    my ($self) = @_;

    my $pfetch_www = $ENV{'PFETCH_WWW'};
    my $pfetch_url = $self->Client->pfetch_url;

    my $blixemrc = sprintf '%s/blixemrc', $self->zmap_dir;
    my $xremote_debug = Bio::Otter::Debug->debug('XRemote');

    my $config = {

        'ZMap' => {
            'cookie-jar'      => $ENV{'OTTERLACE_COOKIE_JAR'},
            'pfetch-mode'     => ( $pfetch_www ? 'http' : 'pipe' ),
            'pfetch'          => ( $pfetch_www ? $pfetch_url : 'pfetch' ),
            'xremote-debug'   => $xremote_debug ? 'true' : 'false',
            'stylesfile'      => $self->stylesfile,
            ($self->colour ? ('session-colour'  => $self->colour) : ()),
            %{$self->slice->zmap_config_stanza},
        },

        'glyphs' => {
            'dn-tri' => '<0,4; -4,0; 4,0; 0,4>',
            'up-tri' => '<0,-4; -4,0; 4,0; 0,-4>',

            # NB: 5 and 3 in "tri" glyphs below refer to 5' and
            # 3' ends of genomic sequence, not match!

            'fwd5-tri' => '<0,-2; -3,-9; 3,-9; 0,-2>',
            'fwd3-tri' => '<0,9; -3,2; 3,2; 0,9>',

            'rev5-tri' => '<0,-9; -3,-2; 3,-2; 0,-9>',
            'rev3-tri' => '<0,2; -3,9; 3,9; 0,2>',

            'dn-hook' => '<0,0; 15,0; 15,10>',
            'up-hook' => '<0,0; 15,0; 15,-10>',
        },

        'blixem' => {
            'config-file' => $blixemrc,
            %{ $self->DataSet->config_section('blixem') },
        },

    };

    return $config;
}

sub ace_config {
    my ($self) = @_;

    my $slice_name = $self->slice_name;
    my $gff_version = 2;
    my $acedb_version = $self->DataSet->acedb_version;

    my $ace_server = $self->ace_server;
    my $url = sprintf 'acedb://%s:%s@%s:%d?gff_version=%d'
        , $ace_server->user, $ace_server->pass, $ace_server->host, $ace_server->port
        , $gff_version;

    my @methods = $self->MethodCollection->get_all_top_level_Methods;
    my $featuresets = [ map { $_->name } @methods ];

    my $config = {

        'ZMap' => {
            sources => [ $slice_name ],
        },

        $slice_name => {
            url         => $url,
            writeback   => 'false',
            sequence    => 'true',
            group       => 'always',
            featuresets => $featuresets,
            stylesfile  => $self->stylesfile,
            version     => $acedb_version,
        },

    };

    return $config;
}

my $sqlite_fetch_query = "
SELECT  oai.accession_sv     AS  'Name'
     ,  oai.sequence         AS  'Sequence'
     ,  oai.description      AS  'Description'
     ,  osi.scientific_name  AS  'Organism'
FROM             otter_accession_info  oai
LEFT OUTER JOIN  otter_species_info    osi  USING  ( taxon_id )
WHERE  oai.accession_sv  IN  ( '%m' )
";
$sqlite_fetch_query =~ s/[[:space:]]+/ /g; # collapse into one line for the blixem config file

sub blixem_config {
    my ($self) = @_;

    my @pfetch_common_config = (
        'separator'     => '" "',
        );

    my @pfetch_socket_config = (
        @pfetch_common_config,
        'fetch-mode'    => 'socket',
        'errors'        => ['no match'],
        'node'          => $PFETCH_SERVER_LIST->[0][0],
        'port'          => $PFETCH_SERVER_LIST->[0][1],
        'command'       => 'pfetch',
        );

    my @pfetch_http_config = (
        @pfetch_common_config,
        'fetch-mode'    => 'http',
        'errors'        => ['no match', 'Not authorized'],
        'url'           => $self->Client->pfetch_url,
        'cookie-jar'    => $ENV{'OTTERLACE_COOKIE_JAR'},
        'port'          => 80,
        );

    my $connect = $ENV{'PFETCH_WWW'} ? 'http' : 'socket';
    # my $connect = 'http';
    my $raw_fetch   = "pfetch-$connect-raw";
    my $fasta_fetch = "pfetch-$connect-fasta";
    my $embl_fetch  = "pfetch-$connect-embl";

    my $config = {

        'blixem'  => {
            'link-features-by-name' => 'false',
            'bulk-fetch'            => 'none',
            'user-fetch'            => 'internal',
            # ZMap stylesfile is used to pick up colours for transcripts
            'stylesfile'            => $self->stylesfile,
            ($self->colour ? ('session-colour'  => $self->colour) : ()),
        },


        # Data types

        'none' => {
            'fetch-mode'    => 'none',
        },

        'internal' => {
            'fetch-mode'    => 'internal',
        },

        'variation-fetch'   => {
            'fetch-mode'    => 'www',
            'url'           => 'http://www.ensembl.org/Homo_sapiens/Variation/Summary',
            'request'       => 'v=%m',
        },

        'dna-match' => {
            'link-features-by-name' => 'true',
            'bulk-fetch'            => 'sqlite-fetch',
            'user-fetch'            => [$embl_fetch, $fasta_fetch, 'internal'],
            'optional-fetch'        => $embl_fetch,
        },

        'dna-match-pfetch' => {
            'link-features-by-name' => 'true',
            'bulk-fetch'            => [$embl_fetch, $raw_fetch],
            'user-fetch'            => [$embl_fetch, $fasta_fetch, 'internal'],
        },

        'protein-match' => {
            'link-features-by-name' => 'true',
            'bulk-fetch'            => 'sqlite-fetch',
            'user-fetch'            => [$embl_fetch, $fasta_fetch, 'internal'],
            'optional-fetch'        => $embl_fetch,
        },

        'protein-match-pfetch' => {
            'link-features-by-name' => 'true',
            'bulk-fetch'            => $raw_fetch,
            'user-fetch'            => [$embl_fetch, $fasta_fetch, 'internal'],
        },

        'linked-local' => {
            'link-features-by-name' => 'true',
            'bulk-fetch'            => 'none',
            'user-fetch'            => 'internal',
        },

        'ensembl-variation' => {
            'link-features-by-name' => 'false',
            'bulk-fetch'            => 'none',
            'user-fetch'            => 'variation-fetch',
        },

        # Hard coded links for OTF data types - no longer required
        'source-data-types' => {
        },

        # Fetch methods

        'pfetch-socket-embl'  => {
            @pfetch_socket_config,
            'args'      => '--client=%p_%h_%u -C -F %m',
            'output'    => 'embl',
        },

        'pfetch-socket-fasta'   => {
            @pfetch_socket_config,
            'args'      => '--client=%p_%h_%u -C %m',
            'output'    => 'fasta',
        },

        'pfetch-socket-raw'     => {
            @pfetch_socket_config,
            'args'      => '--client=%p_%h_%u -q -C %m',
            'output'    => 'raw',
        },

        'pfetch-http-embl'      => {
            @pfetch_http_config,
            'request'   => 'request=-F %m',
            'output'     => 'embl',
        },

        'pfetch-http-fasta'     => {
            @pfetch_http_config,
            'request'   => 'request=%m',
            'output'    => 'fasta',
        },

        'pfetch-http-raw'     => {
            @pfetch_http_config,
            'request'   => 'request=-q %m',
            'output'    => 'raw',
        },

        'sqlite-fetch' => {
            'fetch-mode' => 'sqlite',
            'location'   => $self->DB->file,
            'query'      => $sqlite_fetch_query,
            'output'     => 'list',
        },

    };

    # Merge in dataset specific blixem config (BAM sources)
    _config_merge($config, $self->DataSet->blixem_config);

    return $config;
}

sub _config_merge {
    my ($config, $config_other) = @_;
    for my $name (keys %{$config_other}) {
        my $stanza = $config->{$name} ||= { };
        my $stanza_other = $config_other->{$name};
        for my $key (keys %{$stanza_other}) {
            $stanza->{$key} =
                _value_merge($stanza->{$key},$stanza_other->{$key});
        }
    }
    return;
}

# We merge two values as follows: if either value is undefined we
# ignore it and return the other, if either value is a reference then
# we concatenate them into a list, otherwise we ignore the first value
# and return the second.

sub _value_merge {
    my ($v0, $v1) = @_;
    return $v0 unless defined $v1;
    return $v1 unless defined $v0;
    return [ @{$v0}, @{$v1} ] if ref $v0 && ref $v1;
    return [ @{$v0},   $v1  ] if ref $v0;
    return [   $v0 , @{$v1} ] if ref $v1;
    return $v1;
}

sub zmap_config_update {
    my ($self) = @_;

    my $cfg_path = sprintf "%s/ZMap", $self->zmap_dir;
    my $cfg = $self->{_zmap_cfg} ||=
        Config::IniFiles->new( -file => $cfg_path );

    foreach my $column ($self->ColumnCollection->list_Columns) {
        my $name = $column->name;
        if ($column->status eq 'Visible') {
            $cfg->setval($name,'delayed','false');
        }
        else {
            $cfg->setval($name,'delayed','true');
        }
    }

    $cfg->RewriteConfig;

    return;
}

sub stylesfile {
    my ($self) = @_;
    return sprintf '%s/styles.ini', $self->zmap_dir;
}

sub zmap_dir {
    my ($self) = @_;
    return sprintf '%s/ZMap', $self->home;
}

sub offset {
    my ($self) = @_;

    my $offset = $self->{'_offset'};
    unless (defined $offset) {
        my $slice = $self->slice
            or confess "No slice (Bio::Otter::Lace::Slice) attached";
        $offset = $self->{'_offset'} = $slice->start - 1;
    }
    return $offset;
}

sub generate_XML_from_acedb {
    my ($self) = @_;

    # Make Ensembl objects from the acedb database
    my $feature_types =
        [ $self->MethodCollection->get_all_mutable_non_transcript_Methods ];
    my $converter = Bio::Vega::AceConverter->new;
    $converter->ace_handle($self->aceperl_db_handle);
    $converter->feature_types($feature_types);
    $converter->otter_slice($self->slice);
    $converter->generate_vega_objects;

    # Pass the Ensembl objects to the XML formatter
    my $region = Bio::Vega::Region->new;
    $region->species($self->slice->dsname);
    $region->slice(           $converter->ensembl_slice           );
    $region->clone_sequences( @{$converter->clone_seq_list || []} );
    $region->genes(           @{$converter->genes          || []} );
    $region->seq_features(    @{$converter->seq_features   || []} );

    my $formatter = Bio::Vega::Transform::XML->new;
    $formatter->region($region);
    return $formatter->generate_OtterXML;
}

sub unlock_otter_slice {
    my ($self) = @_;

    my $slice = $self->slice();
    my $slice_name  = $slice->name();
    my $dsname      = $slice->dsname();

    warn "Unlocking $dsname:$slice_name\n";

    my $client   = $self->Client or confess "No Client attached";

    my $xml_text = $self->fetch_lock_region_xml;

    if ($client->unlock_otter_xml($xml_text, $dsname)) {
        $self->write_access(0);
        $self->save_lock_region_xml('unlocked at ' . scalar localtime);
    }
    return 1;
}

sub ace_server {
    my ($self) = @_;

    my $sgif;
    unless ($sgif = $self->{'_ace_server'}) {
        my $home = $self->home;
        $sgif = Hum::Ace::LocalServer->new($home);
        $sgif->server_executable('sgifaceserver');

        $sgif->timeout_string('0:30:100:0');
        # client_timeout:server_timeout:max_req_sizeKB:auto_save_interval

        $sgif->start_server() or return 0; # this only check the fork was successful
        my $pid = $sgif->server_pid;
        $sgif->ace_handle(1)  or return 0; # this checks it can connect
        warn "sgifaceserver on $home running, pid $pid\n";
        $self->{'_ace_server'} = $sgif;
    }
    return $sgif;
}

sub ace_server_registered {
    my ($self) = @_;

    return $self->{'_ace_server'};
}

sub aceperl_db_handle {
    my ($self) = @_;

    return $self->ace_server->ace_handle;
}

sub make_database_directory {
    my ($self) = @_;

    my $home = $self->home;
    my $tar  = $self->Client->get_lace_acedb_tar
        or confess "Client did not return tar file for local acedb database directory structure";
    mkdir($home, 0777) or die "Can't mkdir('$home') : $!\n";

    my $tar_command = "cd '$home' && tar xzf -";
    try {
        open my $expand, '|-', $tar_command or die "Can't open pipe '$tar_command'; $?";
        print $expand $tar;
        close $expand or die "Error running pipe '$tar_command'; $?";
    }
    catch {
        $self->error_flag(1);
        confess $_;
    };

    # rawdata used to be in tar file, but no longer because
    # it doesn't (yet) contain any files.
    my $rawdata = "$home/rawdata";
    mkdir($rawdata, 0777);
    die "Can't mkdir('$rawdata') : $!\n" unless -d $rawdata;

    $self->make_passwd_wrm;

    return;
}

sub write_methods_acefile {
    my ($self) = @_;

    my $methods_file = $self->home . '/rawdata/methods.ace';
    my $collect = $self->MethodCollection;
    $collect->write_to_file($methods_file);
    $self->add_acefile($methods_file);

    return;
}

sub make_passwd_wrm {
    my ($self) = @_;

    my $passWrm = $self->home . '/wspec/passwd.wrm';
    my ($prog) = $0 =~ m{([^/]+)$};
    my $real_name      = ( getpwuid($<) )[0];
    my $effective_name = ( getpwuid($>) )[0];

    my $fh;
    sysopen($fh, $passWrm, O_CREAT | O_WRONLY, 0644)
        or confess "Can't write to '$passWrm' : $!";
    print $fh "// PASSWD.wrm generated by $prog\n\n";

    # acedb looks at the real user ID, but some
    # versions of the code seem to behave differently
    if ( $real_name ne $effective_name ) {
        print $fh "root\n\n$real_name\n\n$effective_name\n\n";
    }
    else {
        print $fh "root\n\n$real_name\n\n";
    }

    close $fh;    # Must close to ensure buffer is flushed into file

    return;
}

sub initialize_database {
    my ($self) = @_;

    my $home = $self->home;
    my $tace = $self->tace;

    my $parse_log = "$home/init_parse.log";
    my $pipe = "'$tace' '$home' >> '$parse_log'";

    open my $pipe_fh, '|-', $pipe
        or die "Can't open pipe '$pipe' : $!";
    # Say "yes" to "initalize database?" question.
    print $pipe_fh "y\n" unless $self->db_initialized;
    foreach my $file ($self->list_all_acefiles) {
        print $pipe_fh "parse $file\n";
    }
    close $pipe_fh or die "Error initializing database exit($?)\n";

    open my $fh, '<', $parse_log or die "Can't open '$parse_log' : $!";
    my $file_log = '';
    my $in_parse = 0;
    my $errors = 0;
    while (<$fh>) {
        if (/parsing/i) {
            $file_log = "  $_";
            $in_parse = 1;
        }

        if (/(\d+) (errors|parse failed)/i) {
            if ($1) {
                warn "\nParse error detected:\n$file_log  $_\n";
                $errors++;
            }
        }
        elsif (/Sorry/) {
            warn "Apology detected:\n$file_log  $_\n";
            $errors++;
        }
        elsif ($in_parse) {
            $file_log .= "  $_";
        }
    }
    close $fh;

    confess "Error initializing database\n" if $errors;
    $self->empty_acefile_list;
    return 1;
}


sub db_initialized {
    my ($self) = @_;

    my $init_file = join('/', $self->home, 'database/ACEDB.wrm');
    return -e $init_file;
}

sub write_dna_data {
    my ($self) = @_;

    my $ace_filename = $self->home . '/rawdata/dna.ace';
    $self->add_acefile($ace_filename);
    open my $ace_fh, '>', $ace_filename
        or confess "Can't write to '$ace_filename' : $!";
    print $ace_fh $self->dna_ace_data;
    close $ace_fh;

    return;
}

sub dna_ace_data {
    my ($self) = @_;

    my ($dna, @tiles) = split /\n/
        , $self->http_response_content('GET', 'get_assembly_dna');

    $dna = lc $dna;
    $dna =~ s/(.{60})/$1\n/g;

    my @feature_ace;
    my %seen_ctg = ( );
    my @ctg_ace = ( );

    for (@tiles) {

        my ($start, $end,
            $ctg_name, $ctg_start,
            $ctg_end, $ctg_strand, $ctg_length,
            ) = split /\t/;
        ($start, $end) = ($end, $start) if $ctg_strand == -1;

        my $strand_ace =
            $ctg_strand == -1 ? 'minus' : 'plus';
        my $feature_ace =
            sprintf qq{Feature "Genomic_canonical" %d %d %f "%s-%d-%d-%s"\n},
            $start, $end, 1.000, $ctg_name, $ctg_start, $ctg_end, $strand_ace;
        push @feature_ace, $feature_ace;

        unless ( $seen_ctg{$ctg_name} ) {
            $seen_ctg{$ctg_name} = 1;
            my $ctg_ace =
                sprintf qq{\nSequence "%s"\nLength %d\n}, $ctg_name, $ctg_length;
            push @ctg_ace, $ctg_ace;
        }

    }

    my $name = $self->slice->name;
    my $ace = join ''
        , qq{\nSequence "$name"\n}, @feature_ace , @ctg_ace
        , qq{\nSequence : "$name"\nDNA "$name"\n\nDNA : "$name"\n$dna\n}
    ;

    return $ace;
}

sub reload_filter_state {
    my ($self) = @_;

    my $col_aptr = $self->DB->ColumnAdaptor;
    $col_aptr->fetch_ColumnCollection_state($self->ColumnCollection);

    return;
}

sub save_filter_state {
    my ($self) = @_;

    my $col_aptr = $self->DB->ColumnAdaptor;
    $col_aptr->store_ColumnCollection_state($self->ColumnCollection);

    return;
}

sub ColumnCollection {
    my ($self) = @_;

    return $self->{'_ColumnCollection'} ||=
      Bio::Otter::Lace::Source::Collection->new_from_Filter_list(
          @{ $self->DataSet->filters },
          (grep { _bam_is_filter($_) } @{ $self->DataSet->bam_list }));
}

sub _bam_is_filter {
    my ($bam) = @_;
    my $bam_is_filter =
        ! ( $bam->coverage_plus || $bam->coverage_minus );
    return $bam_is_filter;
}

sub DataSet {
    my ($self) = @_;

    return $self->Client->get_DataSet_by_name($self->slice->dsname);
}

sub process_Columns {
    my ($self, @columns) = @_;

    $self->logger->debug("process_Columns: '", join(',', map { $_->name } @columns), "'\n");
    my $transcripts = [ ];
    my $failed      = [ ];
    foreach my $col (@columns) {
        (    $col->Filter->content_type
          && $col->process_gff )
            or next;
        try {
            my @filter_transcripts = $self->_process_Column($col);
            push @$transcripts, @filter_transcripts;
        }
        catch { warn $_; push @$failed, $col; };        
    }

    my $result = {
        '-transcripts' => $transcripts,
        '-failed'      => $failed,
    };

    return $result;
}

sub _process_Column {
    my ($self, $column) = @_;

    my $filter = $column->Filter;
    my $filter_name = $filter->name;
    my $gff_file = $column->gff_file;
    unless ($gff_file) {
        confess "gff_file column not set for '$filter_name' in otter_filter table in SQLite DB";
    }

    my $full_gff_file = $self->home . "/$gff_file";

    # feature_kind values from otter_config:
    # DitagFeature
    # DnaDnaAlignFeature
    # DnaPepAlignFeature
    # ExonSupportingFeature
    # MarkerFeature
    # PredictionExon
    # PredictionTranscript
    # RepeatFeature
    # SimpleFeature
    # VariationFeature

    my @transcripts = ( );
    my $close_error;
    open my $gff_fh, '<', $full_gff_file or confess "Can't read GFF file '$full_gff_file'; $!";

    try {
        @transcripts = $self->_process_fh($column, $gff_fh);
    }
    catch { die sprintf "%s: %s: $_", $filter_name, $full_gff_file; }
    finally {
        # want to &confess here but that would hide any errors from
        # the try block so we save the error for later
        close $gff_fh
            or $close_error = "Error closing GFF file '$full_gff_file'; $!";
    };

    confess $close_error if $close_error;

    return @transcripts;
}

sub _process_fh {
    my ($self, $column, $gff_fh) = @_;

    my $filter = $column->Filter;

    if ($filter->content_type eq 'transcript') {
        return Bio::Otter::Lace::ProcessGFF::make_ace_transcripts_from_gff(
            $gff_fh, $self->slice->start, $self->slice->end);
    }
    elsif ($filter->content_type eq 'alignment_feature') {
        Bio::Otter::Lace::ProcessGFF::store_hit_data_from_gff($self->AccessionTypeCache, $gff_fh);
        # Unset flag so that we don't reprocess this file if we recover the session.
        $column->process_gff(0);
        $self->DB->ColumnAdaptor->store_Column_state($column);
        return;
    }
    else {
        confess "Don't know how to process GFF file\n";
    }
}

sub script_arguments {
    my ($self) = @_;

    my $arguments = {
        client => 'otterlace',
        %{$self->query_hash},
        gff_version => $self->DataSet->gff_version,
        session_dir => $self->home,
        url_root    => $self->Client->url_root,
        cookie_jar  => $ENV{'OTTERLACE_COOKIE_JAR'},
    };

    return $arguments; 
}

sub http_response_content {
    my ($self, $command, $script, $args) = @_;

    my $query = $self->query_hash;
    $query = { %{$query}, %{$args} } if $args;

    my $response = $self->Client->http_response_content(
        $command, $script, $query);

    return $response;
}

sub query_hash {
    my ($self) = @_;

    my $slice = $self->slice;

    my $hash = {
            'dataset' => $slice->dsname(),
            'chr'     => $slice->ssname(),

            'cs'      => $slice->csname(),
            'csver'   => $slice->csver(),
            'name'    => $slice->seqname(),
            'start'   => $slice->start(),
            'end'     => $slice->end(),
    };

    return $hash;
}


sub DESTROY {
    my ($self) = @_;

    #warn "Debug - leaving database intact"; return;

    my $home = $self->home;
    my $callback = $self->post_exit_callback;
    warn "DESTROY has been called for AceDatabase.pm with home $home\n";
    if ($self->error_flag) {
        warn "Not cleaning up '$home' because error flag is set\n";
        return;
    }
    my $client = $self->Client;
    try {
        if ($self->ace_server_registered) {
            # $self->ace_server->kill_server; # this may hang...
            $self->kill_ace_server;           # ...so do this instead
        }
        if ($client) {
            $self->unlock_otter_slice() if $self->write_access;
        }
    }
    catch { warn "Error in AceDatabase::DESTROY : $_"; };

    rename($home, "${home}.done")
        or die "Error renaming the session directory; $!";

    if ($callback) {
        $callback->();
    }

    return;
}

#  This is basically $self->ace_server->kill_server except that it
#  does not call waitpid to wait for the Ace server process to exit.
#  This is necessary to prevent lockups when closing Otter sessions.

sub kill_ace_server {
    my( $self ) = @_;
    my $ace_server = $self->ace_server;
    my $ace_handle = $ace_server->ace_handle;
    $ace_handle->raw_query('shutdown') if $ace_handle;
    $ace_server->disconnect_client;
    $ace_server->forget_port;
    $ace_server->server_pid(undef);
    return;
}

sub logger {
    return Log::Log4perl->get_logger;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

