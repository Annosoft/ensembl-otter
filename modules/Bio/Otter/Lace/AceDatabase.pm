
### Bio::Otter::Lace::AceDatabase

package Bio::Otter::Lace::AceDatabase;

use strict;
use warnings;
use Carp;

use Fcntl qw{ O_WRONLY O_CREAT };
use File::Basename;
use Config::IniFiles;
use Try::Tiny;
use Scalar::Util 'weaken';

use Bio::Vega::CoordSystemFactory;
use Bio::Vega::Region;
use Bio::Vega::Region::Ace;
use Bio::Vega::Region::Store;
use Bio::Vega::AceConverter;
use Bio::Vega::Transform::RegionToXML;
use Bio::Vega::Transform::XMLToRegion;

use Bio::Otter::Debug;
use Bio::Otter::Lace::AccessionTypeCache;
use Bio::Otter::Lace::Chooser::Collection;
use Bio::Otter::Lace::DB;
use Bio::Otter::Lace::Slice; # a new kind of Slice that knows how to get pipeline data
use Bio::Otter::Lace::ProcessGFF;
use Bio::Otter::Utils::Config::Ini qw( config_ini_format );

use Hum::Ace::Assembly;
use Hum::Ace::LocalServer;
use Hum::Ace::MethodCollection;
use Hum::ZMapStyleCollection;

use Hum::Conf qw{ PFETCH_SERVER_LIST };

use parent qw( Bio::Otter::Log::WithContextMixin );

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

    my $db = $self->{'_sqlite_database'} ||= Bio::Otter::Lace::DB->new(
        home        => $self->home,
        client      => $self->Client,
        log_context => $self->log_context
        );
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
        $self->DB->log_context($name);
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

sub save_lock_token {
    my ($self, $token) = @_;
    $self->DB->set_tag_value('slicelock_token', $token);
    return;
}

sub fetch_lock_token {
    my ($self) = @_;
    return $self->DB->get_tag_value('slicelock_token');
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

    my $xml_string = $self->Client->get_region_xml($self->slice);
    $self->write_file('01_before.xml', $xml_string);

    my $parser = Bio::Vega::Transform::XMLToRegion->new;

    my $cs_factory = Bio::Vega::CoordSystemFactory->new( dba => $self->DB->vega_dba );
    $parser->coord_system_factory($cs_factory);

    my $region = $parser->parse($xml_string);
    $self->write_otter_acefile($region);

    my ($raw_dna, @tiles) = $self->Client->get_assembly_dna($self->slice);
    $self->write_dna_data($raw_dna, @tiles);

    my $storer = Bio::Vega::Region::Store->new(
        vega_dba => $self->DB->vega_dba,
        coord_system_factory => $cs_factory,
        );
    $storer->store($region, $raw_dna);

    $self->write_methods_acefile;

    $self->save_region_xml($xml_string); # sets up $self->slice
    $self->DB->session_slice($self->slice->ensembl_slice);

    $self->initialize_database;

    return;
}

sub write_otter_acefile {
    my ($self, $region) = @_;

    my $ace_maker = Bio::Vega::Region::Ace->new;

    # Storing ace_text in a file
    my $ace_filename = $self->home . '/rawdata/otter.ace';
    open my $ace_fh, '>', $ace_filename or $self->logger->logdie("Can't write to '$ace_filename'");
    print $ace_fh $ace_maker->make_ace_string($region);
    close $ace_fh or $self->logger->logconfess("Error writing to '$ace_filename' : $!");
    $self->add_acefile($ace_filename);

    return;
}

sub try_to_lock_the_block {
    my ($self) = @_;

    my $client = $self->Client;
    $self->logger->logconfess("Cannot lock_region, write_access configured off")
      unless $client->write_access;

    # could usefully pass "intent" here, but there is no UI for it

    my $hash = $client->lock_region($self->slice);
    die "Locking failed but no error?" unless $hash && $hash->{locknums};
    $self->save_lock_token($hash->{locknums});
    return 1;
}

sub write_file {
    my ($self, $file_name, $content) = @_;

    my $full_file = join('/', $self->home, $file_name);
    open my $LF, '>', $full_file or $self->logger->logdie("Can't write to '$full_file'; $!");
    print $LF $content;
    close $LF or $self->logger->logdie("Error writing to '$full_file'; $!");

    return;
}

sub read_file {
    my ($self, $file_name) = @_;

    local $/ = undef;
    my $full_file = join('/', $self->home, $file_name);
    open my $RF, '<', $full_file or $self->logger->logdie("Can't read '$full_file'; $!");
    my $content = <$RF>;
    close $RF or $self->logger->logdie("Error reading '$full_file'; $!");
    return $content;
}

sub recover_slice_from_region_xml {
    my ($self) = @_;

    my $client = $self->Client or $self->logger->logdie("No Client attached");

    my $xml = $self->fetch_region_xml;
    unless ($xml) {
        $self->logger->logconfess("Could not fetch XML from SQLite DB to create smart slice");
    }

    my $parser = Bio::Vega::Transform::XMLToRegion->new;
    $parser->coord_system_factory(Bio::Vega::CoordSystemFactory->new); # Should we get this from somewhere else?
    my $region = $parser->parse($xml);

    my $slice = Bio::Otter::Lace::Slice->new_from_region($client, $region);
    $self->slice($slice);

    $self->DB->species($region->species);
    $self->DB->session_slice($slice->ensembl_slice);

    return;
}

sub fetch_assembly {
    my ($self) = @_;

    my $ace  = $self->aceperl_db_handle;

    my $assembly = Hum::Ace::Assembly->new;
    $assembly->name($self->slice_name);
    $assembly->MethodCollection($self->MethodCollection);
    $assembly->express_data_fetch($ace);

    return $assembly;
}

sub slice {
    my ($self, $slice) = @_;

    if ($slice) {
        $self->{'_offset'} = undef;
        $self->{'_slice'} = $slice;
    }
    return $self->{'_slice'};
}

sub slice_name {
    my ($self) = @_;

    my $slice_name;
    unless ($slice_name = $self->{'_slice_name'}) {
        my @slice_list = $self->aceperl_db_handle->fetch(Assembly => '*');
        my @slice_names = map { $_->name } @slice_list;
        $self->logger->logdie("Error: more than 1 assembly in database: @slice_names") if @slice_names > 1;
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
    $self->logger->error("Ignored invalid [client]session_colourset values (@bad).  RGB may be given like '#fab' or '#ffaabb'") if @bad;
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
    my @colour_list;

    sub next_session_colour {
        my ($self) = @_;

        unless (@colour_list) {
            @colour_list = $self->session_colourset;
        }

        my $threshold = 1;
        my $colour_ref = undef;
        for (my $i = 0; $i < @colour_list; $i++) {
            # Rotate list of colours
            my $col = shift @colour_list;
            push @colour_list, $col;

            my $use = $colour_in_use{$col} ||= [];
            for (my $j = 0; $j < @$use; ) {
                if ($use->[$j]) {
                    # Colour still in use
                    $j++;
                }
                else {
                    # Weakend ref has gone away, so remove empty element.
                    splice(@$use, $j, 1);
                }
            }

            if (@$use < $threshold) {
                # Found a colour below use threhold
                $colour_ref = \$col;
                push(@$use, $colour_ref);
                weaken($use->[-1]);
                last;
            }
            elsif ($i == $#colour_list) {
                # Reached the end of the list; all the colours are in use!
                # Up the threhold and start again.
                $threshold++;
                $i = 0;
            }
        }

        return $colour_ref;
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
        mkdir $dir or $self->logger->logconfess("failed to create the directory '$dir': $!");
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
        or $self->logger->logconfess("Can't write to '$path'; $!");
    print $fh $config;
    close $fh
      or $self->logger->logconfess("Error writing to '$path'; $!");

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
    my @method_names = map { $_->name } @methods;

    # extract DNA source into a separate initial stanza for pre-loading
    #
    my $dna         = [ grep { $_ eq 'DNA' } @method_names ];
    my $featuresets = [ grep { $_ ne 'DNA' } @method_names ];

    my @sources = $slice_name;
    my $dna_slice_name;
    if (@$dna) {
        $dna_slice_name = sprintf '%s-DNA', $slice_name;
        unshift @sources, $dna_slice_name;

        # RT400142: we also put 'DNA' back in as the first item in the main stanza
        unshift @$featuresets, @$dna;
    }

    my $config = {

        'ZMap' => {
            sources => \@sources,
        },

        $slice_name => $self->_ace_slice_config(
            url         => $url,
            featuresets => $featuresets,
            version     => $acedb_version,
        ),

    };

    if ($dna_slice_name) {
        $config->{$dna_slice_name} = $self->_ace_slice_config(
            url         => $url,
            featuresets => $dna,
            version     => $acedb_version,
            );
    }

    return $config;
}

sub _ace_slice_config {
    my ($self, @args) = @_;
    return {
        sequence    => 'true',
        group       => 'always',
        stylesfile  => $self->stylesfile,
        @args,
    }
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

    my @pfetch_http_config = (
        'separator'     => '" "',
        'fetch-mode'    => 'http',
        'errors'        => ['no match', 'Not authorized'],
        'url'           => $self->Client->pfetch_url,
        'cookie-jar'    => $ENV{'OTTERLACE_COOKIE_JAR'},
        'port'          => 80,
        );

    if (my $proxy = $ENV{'http_proxy'}) {
        push @pfetch_http_config, 'proxy' => $proxy;
    }

    my $raw_fetch   = "pfetch-http-raw";
    my $fasta_fetch = "pfetch-http-fasta";
    my $embl_fetch  = "pfetch-http-embl";

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

        # Fetch methods
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
            or $self->logger->logconfess("No slice (Bio::Otter::Lace::Slice) attached");
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

    # write_region requires that the client describe the region, to
    # ensure it is the correct one, but then ignores ContigInfo.

    my $formatter = Bio::Vega::Transform::RegionToXML->new;
    $formatter->region($region);
    return $formatter->generate_OtterXML;
}

sub unlock_otter_slice {
    my ($self) = @_;

    my $slice = $self->slice();
    my $slice_name  = $slice->name();
    my $dsname      = $slice->dsname();

    $self->logger->info("Unlocking $dsname:$slice_name");

    my $client   = $self->Client or $self->logger->logconfess("No Client attached");

    my $token = $self->fetch_lock_token;
    if ($token =~ /^unlocked /) { # as set by this method
        $self->logger->info("  already $token, continuing");
        return 1;
    }

    my $hash = $client->unlock_region($dsname, $token);
    die "Unlock request failed without error?"
      unless $hash && ($hash->{unlocked} || $hash->{already});

    $self->write_access(0);
    $self->save_lock_token('unlocked at ' . scalar localtime);

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
        $self->logger->info("sgifaceserver on $home running, pid $pid");
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

    my $logger = $self->logger;
    my $home   = $self->home;
    my $tar    = $self->Client->get_lace_acedb_tar
        or $logger->logconfess("Client did not return tar file for local acedb database directory structure");
    mkdir($home, 0777) or $logger->logdie("Can't mkdir('$home') : $!");

    my $tar_command = "cd '$home' && tar xzf -";
    try {
        open my $expand, '|-', $tar_command or die "Can't open pipe '$tar_command'; $?";
        print $expand $tar;
        close $expand or die "Error running pipe '$tar_command'; $?";
    }
    catch {
        $self->error_flag(1);
        $logger->logconfess($_);
    };

    # rawdata used to be in tar file, but no longer because
    # it doesn't (yet) contain any files.
    my $rawdata = "$home/rawdata";
    mkdir($rawdata, 0777);
    $logger->logdie("Can't mkdir('$rawdata') : $!") unless -d $rawdata;

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
        or $self->logger->logconfess("Can't write to '$passWrm' : $!");
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

    my $logger = $self->logger;
    my $home   = $self->home;
    my $tace   = $self->tace;

    my $parse_log = "$home/init_parse.log";
    my $pipe = "'$tace' '$home' >> '$parse_log'";

    open my $pipe_fh, '|-', $pipe
        or $logger->logdie("Can't open pipe '$pipe' : $!");
    # Say "yes" to "initalize database?" question.
    print $pipe_fh "y\n" unless $self->db_initialized;
    foreach my $file ($self->list_all_acefiles) {
        print $pipe_fh "parse $file\n";
    }
    close $pipe_fh or $logger->logdie("Error initializing database exit($?)");

    open my $fh, '<', $parse_log or $logger->logdie("Can't open '$parse_log' : $!");
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
                $logger->error("Parse error detected:\n$file_log  $_");
                $errors++;
            }
        }
        elsif (/Sorry/) {
            $logger->warn("Apology detected:\n$file_log  $_");
            $errors++;
        }
        elsif ($in_parse) {
            $file_log .= "  $_";
        }
    }
    close $fh;

    $logger->confess("Error initializing database") if $errors;
    $self->empty_acefile_list;
    return 1;
}


sub db_initialized {
    my ($self) = @_;

    my $init_file = join('/', $self->home, 'database/ACEDB.wrm');
    return -e $init_file;
}

sub write_dna_data {
    my ($self, $dna, @tiles) = @_;

    my $ace_filename = $self->home . '/rawdata/dna.ace';
    $self->add_acefile($ace_filename);
    open my $ace_fh, '>', $ace_filename
        or $self->logger->logconfess("Can't write to '$ace_filename' : $!");
    print $ace_fh $self->dna_ace_data($dna, @tiles);
    close $ace_fh;

    return;
}

sub dna_ace_data {
    my ($self, $dna, @tiles) = @_;

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

# returns true if column updated in DB
#
sub select_column_by_name {
    my ($self, $column_name) = @_;

    my $cllctn   = $self->ColumnCollection;
    my $col_aptr = $self->DB->ColumnAdaptor;

    my $column = $cllctn->get_Column_by_name($column_name);
    if ($column and not $column->selected) {
        $column->selected(1);
        $col_aptr->store_Column_state($column);
        return 1;
    }
    return;
}

sub ColumnCollection {
    my ($self) = @_;

    my $cc = $self->{'_ColumnCollection'};
    unless ($cc) {
        my $ds = $self->DataSet;
        $ds->load_client_config;
        $cc = $self->{'_ColumnCollection'} =
            Bio::Otter::Lace::Chooser::Collection->new_from_Filter_list(
                @{ $ds->filters },
                (map { $self->_bam_filter_list($_) } @{ $ds->bam_list }),
            );
    }
    return $cc;
}

my @coverage_param_list = (
    [ 'coverage_plus',  '+ve coverage' ],
    [ 'coverage_minus', '-ve coverage' ],
    );

sub _bam_filter_list {
    my ($self, $bam) = @_;
    my @filter_list = _bam_is_filter($bam) ? ( $bam ) : ( );
    for (@coverage_param_list) {
        try {
            my $coverage_filter = _bam_coverage_filter($bam, @{$_});
            push @filter_list, $coverage_filter if $coverage_filter;
        }
        catch { $self->logger->logwarn("error creating BAM coverage filter: $_"); };
    }
    return @filter_list;
}

sub _bam_is_filter {
    my ($bam) = @_;
    my $bam_is_filter =
        ! ( $bam->coverage_plus || $bam->coverage_minus );
    return $bam_is_filter;
}

sub _bam_coverage_filter {
    my ($bam, $method, $comment) = @_;

    $bam->$method or return;
    my $name = sprintf '%s_%s', $bam->name, $method;
    my $description = sprintf '%s (%s)', $bam->description, $comment;

    # the real ZMap config is handled elsewhere - here we just need
    # enough to make the column chooser work
    my $config = {
        'description'    => $description,
        'featuresets'    => $name,
        'classification' => (join ' > ', $bam->classification),
    };
    my $filter = Bio::Otter::Source::Filter->from_config($config);
    $filter->name($name);
    $filter->resource_bin($bam->resource_bin);
    $filter->wanted(      $bam->wanted);

    return $filter;
}

sub DataSet {
    my ($self) = @_;

    return $self->Client->get_DataSet_by_name($self->slice->dsname);
}

sub process_transcript_Columns {
    my ($self, @columns) = @_;

    $self->logger->debug("process_transcript_Columns: {", join(',', map { $_->name } @columns), "}");

    my $results = [ ];
    my $failed  = [ ];

    foreach my $col (@columns) {
        try {
            push @$results, $self->_process_transcript_Column($col);
        }
        catch {
            $self->logger->error($_);
            push @$failed, $col;
        };
    }

    my $result = {
        '-results' => $results,
        '-failed'  => $failed,
    };

    return $result;
}

sub _process_transcript_Column {
    my ($self, $column) = @_;

    my $logger = $self->logger;

    my @transcripts = ( );
    my $close_error;
    my $gff_processor = $self->_new_ProcessGFF_for_column($column);

    try {
        @transcripts = $gff_processor->make_ace_transcripts_from_gff($self->slice->start, $self->slice->end);
    }
    catch {
        $logger->logdie(sprintf "%s: %s: $_", $column->Filter->name, $column->gff_file);
    }
    finally {
        # want to &confess here but that would hide any errors from
        # the try block so we save the error for later
        $gff_processor->close
            or $close_error = "Error closing via ProcessGFF";
    };

    $logger->logconfess($close_error) if $close_error;

    return @transcripts;
}

sub _new_ProcessGFF_for_column {
    my ($self, $column) = @_;

    my $gff_file    = $column->gff_file;
    my $filter_name = $column->Filter->name;

    unless ($gff_file) {
        $self->logger->logconfess("gff_file column not set for '$filter_name' in otter_filter table in SQLite DB");
    }
    my $gff_path = sprintf '%s/%s', $self->home, $gff_file;

    return Bio::Otter::Lace::ProcessGFF->new(
        gff_path    => $gff_path,
        column_name => $filter_name,
        log_context => $self->log_context,
        );
}

sub core_script_arguments {
    my ($self) = @_;

    my $arguments = {
        client      => 'otterlace',
        session_dir => $self->home,
        url_root    => $self->Client->url_root,
        cookie_jar  => $ENV{'OTTERLACE_COOKIE_JAR'},
    };

    return $arguments;
}

sub script_arguments {
    my ($self) = @_;

    my $arguments = {
        %{$self->core_script_arguments},
        %{$self->_query_hash},
        gff_version => $self->DataSet->gff_version,
    };

    return $arguments;
}

sub _query_hash {
    my ($self, @args) = @_;

    my $hash = { $self->Client->slice_query($self->slice), @args };

    return $hash;
}


sub DESTROY {
    my ($self) = @_;

    my $logger = $self->logger;
    # $logger->debug("Debug - leaving database intact"); return;

    my $home = $self->home;
    my $callback = $self->post_exit_callback;
    $logger->info("DESTROY has been called for AceDatabase.pm with home $home");
    if ($self->error_flag) {
        $logger->info("Not cleaning up '$home' because error flag is set");
        return;
    }
    my $client = $self->Client;
    return if try {
        if ($self->ace_server_registered) {
            # $self->ace_server->kill_server; # this may hang...
            $self->kill_ace_server;           # ...so do this instead
        }
        if ($client) {
            $self->unlock_otter_slice() if $self->write_access;
        }
        0;
    } catch {
        $logger->error("Error in AceDatabase::DESTROY : $_");
        $self->error_flag(1); # don't delete
        1;
    };

    my $writable = try { $self->write_access } catch { "unknown: $_" };
    if ($writable eq '0') {
        # clean, mark it done
        rename($home, "${home}.done") # DUP: $client->_move_to_done
          or $logger->logdie("Error renaming the session directory; $!");
    } else {
        $logger->info("Cleanup '$home' failed, write_access=$writable");
    }

    if ($callback) {
        $callback->();
    }

    return; # not the only return
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

# Required by Bio::Otter::Log::WithContextMixin
sub log_context {
    my ($self) = @_;
    return $self->name if $self->{_sqlite_database};
    return basename($self->home) if $self->home;
    return '-AceDB unnamed-';
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

