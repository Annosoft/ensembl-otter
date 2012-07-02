
### Bio::Otter::Lace::AceDatabase

package Bio::Otter::Lace::AceDatabase;

use strict;
use warnings;
use Carp;

use Fcntl qw{ O_WRONLY O_CREAT };
use Config::IniFiles;
use POSIX();

use Bio::Vega::Transform::Otter::Ace;
use Bio::Vega::AceConverter;
use Bio::Vega::Transform::XML;

use Bio::Otter::Lace::AccessionTypeCache;
use Bio::Otter::Lace::DB;
use Bio::Otter::Lace::Slice; # a new kind of Slice that knows how to get pipeline data
use Bio::Otter::Lace::ProcessGFF;
use Bio::Otter::Utils::Config::Ini qw( config_ini_format );

use Hum::Ace::LocalServer;
use Hum::Ace::MethodCollection;
use Hum::ZMapStyleCollection;
use Bio::Vega::Utils::MacProxyConfig qw{ mac_os_x_set_proxy_vars };

use Hum::Conf qw{ PFETCH_SERVER_LIST };

my $ZMAP_DEBUG = $ENV{OTTERLACE_ZMAP_DEBUG};


sub new {
    my ($pkg) = @_;

    return bless {}, $pkg;
}

sub Client {
    my ($self, $client) = @_;

    if ($client) {
        $self->{'_Client'} = $client;
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
        ||= Bio::Otter::Lace::DB->new($self->home);
    return $db;
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

    my $collect = $self->{'_MethodCollection'} ||= $self->get_default_MethodCollection;
    return $collect;
}

sub get_default_MethodCollection {
    my ($self) = @_;

    my $styles_collection = Hum::ZMapStyleCollection->new_from_string($self->Client->get_otter_styles);
    my $collect = Hum::Ace::MethodCollection->new_from_string($self->Client->get_methods_ace, $styles_collection);
    $collect->process_for_otterlace;
    return $collect;
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

sub recover_smart_slice_from_region_xml {
    my ($self) = @_;

    my $client = $self->Client or die "No Client attached";

    my $xml = $self->fetch_region_xml || $self->fetch_lock_region_xml;
    unless ($xml) {
        confess "Could not fetch XML from SQLite DB to create smart slice";
    }

    my $parser = Bio::Vega::Transform::Otter->new;
    $parser->parse($xml);
    my $slice = $parser->get_ChromosomeSlice;

    my $smart_slice = Bio::Otter::Lace::Slice->new(
        $client,
        $parser->species,
        $slice->seq_region_name,
        $slice->coord_system->name,
        $slice->coord_system->version,
        $parser->chromosome_name,
        $slice->start,
        $slice->end,
        );
    $self->smart_slice($smart_slice);

    return;
}

sub smart_slice {
    my ($self, $smart_slice) = @_;

    if ($smart_slice) {
        $self->{'_offset'} = undef;
        $self->{'_smart_slice'} = $smart_slice;
    }
    return $self->{'_smart_slice'};
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

sub zmap_launch {
    my ($self, $win_id) = @_;

    if ($^O eq 'darwin') {
        # Sadly, if someone moves network after launching zmap, it
        # won't see new proxy variables.
        mac_os_x_set_proxy_vars(\%ENV);
    }

    my @e = (
        'zmap',
        '--conf_dir' => $self->zmap_dir,
        '--win_id'   => $win_id,
        @{$self->DataSet->config_value_list('zmap_config', 'arguments')},
    );

    warn "Running: @e\n";

    my $pid = fork;
    return $pid if $pid;
    confess "Error: couldn't fork()\n" unless defined $pid;
    exec @e;
    warn "exec '@e' failed : $!";
    close STDERR; # _exit does not flush
    POSIX::_exit(1); # avoid triggering DESTROY

    return;
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

    # The 'show-mainwindow' parameter is for when zmap does not start
    # due to it not having window id when doing XChangeProperty().

    my $show_mainwindow =
        $self->Client->config_value('zmap_main_window');
    my $pfetch_www = $ENV{'PFETCH_WWW'};
    my $pfetch_url = $self->Client->pfetch_url;

    my $blixemrc = sprintf '%s/blixemrc', $self->zmap_dir;

    my $config = {

        'ZMap' => {
            'show-mainwindow' => ( $show_mainwindow ? 'true' : 'false' ),
            'cookie-jar'      => $ENV{'OTTERLACE_COOKIE_JAR'},
            'pfetch-mode'     => ( $pfetch_www ? 'http' : 'pipe' ),
            'pfetch'          => ( $pfetch_www ? $pfetch_url : 'pfetch' ),
            'xremote-debug'   => $ZMAP_DEBUG ? 'true' : 'false',
            %{$self->smart_slice->zmap_config_stanza},
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

    my $ace_server = $self->ace_server;
    my $url = sprintf 'acedb://%s:%s@%s:%d'
        , $ace_server->user, $ace_server->pass, $ace_server->host, $ace_server->port;

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
        },

    };

    return $config;
}

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
            # Zmap stylesfile is used to pick up colours for transcripts
            'stylesfile'            => $self->stylesfile,
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
            'bulk-fetch'            => [$embl_fetch, $raw_fetch],
            'user-fetch'            => [$embl_fetch, $fasta_fetch, 'internal'],
        },
        
        'protein-match' => {
            'link-features-by-name' => 'true',
            'bulk-fetch'            => $raw_fetch,
            'user-fetch'            => [$embl_fetch, $fasta_fetch, 'internal'],
        },

        'psl' => {
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

    while ( my ( $name, $value ) = each %{$self->filters}) {
        my $state_hash = $value->{state};
        if ($state_hash->{done}) {
            $cfg->setval($name,'delayed','false');
        }
        if ($state_hash->{failed}) {
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
        my $slice = $self->smart_slice
            or confess "No smart_slice (Bio::Otter::Lace::Slice) attached";
        $offset = $self->{'_offset'} = $slice->start - 1;
    }
    return $offset;
}

sub save_ace_to_otter {
    my ($self) = @_;

    my $client = $self->Client or confess "No Client attached";
    my $xml = $client->save_otter_xml($self->generate_XML_from_acedb, $self->smart_slice->dsname);

    return $self->update_with_stable_ids($xml);
}

sub generate_XML_from_acedb {
    my ($self) = @_;

    # Make Ensembl objects from the acedb database
    my $feature_types =
        [ $self->MethodCollection->get_all_mutable_non_transcript_Methods ];
    my $converter = Bio::Vega::AceConverter->new;
    $converter->ace_handle($self->aceperl_db_handle);
    $converter->feature_types($feature_types);
    $converter->otter_slice($self->smart_slice);
    $converter->generate_vega_objects;

    # Pass the Ensembl objects to the XML formatter
    my $formatter = Bio::Vega::Transform::XML->new;
    $formatter->species($self->smart_slice->dsname);
    $formatter->slice(          $converter->ensembl_slice   );
    $formatter->clone_seq_list( $converter->clone_seq_list  );
    $formatter->genes(          $converter->genes           );
    $formatter->seq_features(   $converter->seq_features    );

    return $formatter->generate_OtterXML;
}

sub update_with_stable_ids {
    my ($self, $xml) = @_;

    return unless $xml;

    my $parser = Bio::Vega::Transform::Otter::Ace->new;
    $parser->parse($xml);

    return $parser->make_ace_genes_transcripts;
}

sub unlock_otter_slice {
    my ($self) = @_;

    my $smart_slice = $self->smart_slice();
    my $slice_name  = $smart_slice->name();
    my $dsname      = $smart_slice->dsname();

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
        $sgif = Hum::Ace::LocalServer->new($self->home);
        $sgif->server_executable('sgifaceserver');
        $sgif->start_server() or return 0; # this only check the fork was successful
        $sgif->ace_handle(1)  or return 0; # this checks it can connect
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
    unless (
        eval {
            open my $expand, '|-', $tar_command or die "Can't open pipe '$tar_command'; $?";
            print $expand $tar;
            close $expand or die "Error running pipe '$tar_command'; $?";
            1;
        }) {
        $self->error_flag(1);
        confess $@;
    }

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

    my $name = $self->smart_slice->name;
    my $ace = join ''
        , qq{\nSequence "$name"\n}, @feature_ace , @ctg_ace
        , qq{\nSequence : "$name"\nDNA "$name"\n\nDNA : "$name"\n$dna\n}
    ;

    return $ace;
}

sub reload_filter_state {
    my ($self) = @_;

    my $dbh = $self->DB->dbh;
    my $sth = $dbh->prepare(q{
        SELECT filter_name, wanted, failed, done FROM otter_filter
    });
    $sth->execute;

    my $filters = $self->filters;

    my @obsolete;
    while (my ($filter_name, $wanted, $failed, $done) = $sth->fetchrow) {
        my $filter = $filters->{$filter_name};
        if ($filter) {
            warn "Reloading state from file for $filter_name\n";
        } else {
            warn "Skipping obsolete coloumn '$filter_name'\n";
            push(@obsolete, $filter_name);
            next;
        }
        my $state_hash = $filters->{$filter_name}{'state'};
        $state_hash->{'wanted'} = $wanted;
        $state_hash->{'failed'} = $failed;
        $state_hash->{'done'}   = $done;
    }

    if (@obsolete) {
        $dbh->begin_work;
        my $del = $dbh->prepare(q{ DELETE FROM otter_filter WHERE filter_name = ? });
        foreach my $filter_name (@obsolete) {
            $del->execute($filter_name);
        }
        $dbh->commit;
    }

    return;
}

sub save_filter_state {
    my ($self) = @_;

    my $dbh = $self->DB->dbh;
    $dbh->begin_work;

    my $insert = $dbh->prepare(q{
        INSERT OR IGNORE INTO otter_filter (filter_name) VALUES (?)
    });
    my $update = $dbh->prepare(q{
        UPDATE otter_filter SET wanted = ?, failed = ?, done = ? WHERE filter_name = ?
    });

    while ( my ($name, $value) = each %{$self->filters} ) {
        my $state_hash = $value->{'state'};
        $insert->execute($name);
        $update->execute(
            $state_hash->{'wanted'},
            $state_hash->{'failed'},
            $state_hash->{'done'},
            $name, 
            );
    }
    $dbh->commit;

    return;
}

sub filters {
    my ($self) = @_;

    return $self->{'_filters'} ||= {
        map {
            $_->name => {
                filter => $_,
                state => {
                    wanted => $_->wanted,
                    done   => 0,
                    failed => 0,
                },
            };
        } @{$self->DataSet->filters},
    };
}

sub DataSet {
    my ($self) = @_;

    return $self->Client->get_DataSet_by_name($self->smart_slice->dsname);
}

sub process_gff_file_from_Filter {
    my ($self, $filter) = @_;

    my $filter_name = $filter->name;
    my $sth = $self->DB->dbh->prepare(q{ SELECT gff_file, process_gff FROM otter_filter WHERE filter_name = ? });
    $sth->execute($filter_name);
    my ($gff_file, $load_gff) = $sth->fetchrow;
    unless ($gff_file) {
        confess "gff_file column not set for '$filter_name' in otter_filter table in SQLite DB";
    }
    unless ($load_gff) {
        return;
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

    if ($filter->server_script eq 'get_gff_genes'
        or $filter->feature_kind eq 'PredictionExon'
        or $filter->feature_kind eq 'PredictionTranscript'
    ) {
        return Bio::Otter::Lace::ProcessGFF::make_ace_transcripts_from_gff($full_gff_file);
    }
    elsif ($filter->feature_kind =~ /AlignFeature/) {
        Bio::Otter::Lace::ProcessGFF::store_hit_data_from_gff($self->DB->dbh, $full_gff_file);
        # Unset flag so that we don't reprocess this file if we recover the session.
        my $dbh = $self->DB->dbh;
        $dbh->begin_work;
        my $no_reload = $dbh->prepare(q{ UPDATE otter_filter SET process_gff = 0 WHERE filter_name = ? });
        $no_reload->execute($filter_name);
        $dbh->commit;
        return;
    }
    else {
        confess "Don't know how to process '$filter_name' GFF file '$gff_file'\n";
    }
}

sub script_arguments {
    my ($self) = @_;

    my $arguments = {
        client => 'otterlace',
        %{$self->smart_slice->toHash},
        session_dir => $self->home,
        url_root    => $self->Client->url_root,
        cookie_jar  => $ENV{'OTTERLACE_COOKIE_JAR'},
    };

    return $arguments; 
}

sub http_response_content {
    my ($self, $command, $script, $args) = @_;

    my $query = $self->smart_slice->toHash;
    $query = { %{$query}, %{$args} } if $args;

    my $response = $self->Client->http_response_content(
        $command, $script, $query);

    return $response;
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
    if (
        eval {
            if ($self->ace_server_registered) {
                $self->ace_server->kill_server;
            }
            if ($client) {
                $self->unlock_otter_slice() if $self->write_access;
            }
            1;
        }) {
        rename($home, "${home}.done")
            or die "Error renaming the session directory; $!";
    } else {
        warn "Error in AceDatabase::DESTROY : $@";
    }

    if ($callback) {
        $callback->();
    }

    return;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

