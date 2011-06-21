### MenuCanvasWindow::ZMapSeqChooser

package MenuCanvasWindow::ZMapSeqChooser;

use strict;
use warnings;
use Carp;
use ZMap::Connect;
use ZMap::XRemoteCache;
use Data::Dumper;
use XML::Simple;
use Bio::Vega::Utils::XmlEscape qw{ xml_escape };
use File::Path qw{ mkpath };
use Config::IniFiles;
use POSIX;

my $ZMAP_DEBUG = $ENV{OTTERLACE_ZMAP_DEBUG};

$Data::Dumper::Terse = 1;
$Data::Dumper::Indent = 1;

#==============================================================================#
#
# WARNING: THESE ARE INJECTED METHODS!!!!
#  I HAVE PREFIXED THEM ALL WITH zMap SO NONE SHOULD CLASH
#  BUT ALL WILL NEED CHANGING LATER (RDS)
#
#==============================================================================#

=pod

=head1 WARNING

This module is included into MenuCanvasWindow::XaceSeqChooser.  All
methods have been prefixed with "zMap" to avoid any clashes, but this
isn't a long term solution.

=cut

sub zMapInitialize {
    my ( $self ) = @_;

    $self->{_zMap_ZMAP_CONNECTOR} =
        $self->zMapZmapConnectorNew;

    $self->{_xremote_cache} =
        ZMap::XRemoteCache->new;

    my $dir = $self->zMapZmapDir;
    unless (-d $dir) {
        mkdir $dir or confess "failed to create the directory '$dir': $!\n";
    }

    my $stylesfile = $self->zMapConfigPath('styles.ini');
    $self->Assembly->MethodCollection->ZMapStyleCollection->write_to_file($stylesfile);

    $self->zMapWriteConfigFile('ZMap',     $self->zMapDotZmapContent($stylesfile));
    $self->zMapWriteConfigFile('.gtkrc',   $self->zMapDotGtkrcContent);
    $self->zMapWriteConfigFile('blixemrc', $self->zMapDotBlixemrcContent);

    return;
}

=pod

=head1 zMapLaunchZmap

This is where it all starts.  This is the method which gets called
on 'Launch ZMap' menu item in xaceseqchooser window.

=cut

=head1 _launchZMap

The guts of the code to launch and display the features in a zmap.

=cut

sub _launchZMap {
    my ($self) = @_;

    my $dataset = $self->AceDatabase->DataSet;

    my @e = (
        'zmap',
        '--conf_dir' => $self->zMapZmapDir,
        '--win_id'   => $self->zMapZmapConnector->server_window_id,
        @{$dataset->config_value_list('zmap_config', 'arguments')},
    );
    warn "Running @e";
    my $pid = fork;
    if ($pid) {
        $self->zMapPID($pid);
    }
    elsif (defined $pid) {
        exec @e;
        warn "exec '@e' failed : $!";
        close STDERR; # _exit does not flush
        POSIX::_exit(1); # avoid triggering DESTROY
    }
    else {
        my $mess = "Error: couldn't fork()\n";
        warn $mess;
        $self->message($mess);
    }

    return;
}

=head1 zMapLaunchZmap

Launches zmap, displaying the features of $self->slice_name(), killing
an existing one if it exists.

=cut

sub zMapLaunchZmap {
    my ($self) = @_;

    my $relaunch = 1;

    if (!$self->zMapKillZmap($relaunch)) {
        $self->_launchZMap();
    }

    return;
}

=head1 zMapLaunchInAZmap

Uses an existing ZMap to display the features of $self->slice_name().

=cut

sub zMapLaunchInAZmap {
    my ($self) = @_;

    # If we already have a Zmap attached, shut it down
    if (!$self->zMapKillZmap(0, 1)) {
        $self->_launchInAZMap();
    }

    return;
}

=head1 _launchInAZMap

The real part of zMapLaunchInAZmap()

=cut

sub _launchInAZMap {
    my ($self) = @_;

    my $xremote_cache = $self->xremote_cache;

    my $pid_list = $xremote_cache->get_pid_list;
    unless($pid_list) {
        warn "Failed to get a process id list from the cache. Is zmap running?";
        return;
    }

    if (@{$pid_list} < 1) {
        warn "Process id list is empty. Is zmap running?";
        return;
    }

    if (@{$pid_list} > 1) {
        warn "More than one process id in list, How to choose?";
        return;
    }

    if ($self->zMapGetXRemoteClientByName($self->slice_name)) {
        $self->message("Already launched in a ZMap");
        return;
    }

    my ($pid) = @{$pid_list};
    my $xremote = $xremote_cache->get_client_for_action_pid("new_view", $pid);
    unless ($xremote) {
        # couldn't find a client who can new_view, probably need to
        $self->zMapOpenClones;
        return;
    }

    $self->zMapPID($pid);
    my $config =
        $self->formatZmapDefaults('ZMap', sources => $self->slice_name)
        . $self->zMapAceServerDefaults();
    $self->zMapNewView($xremote, $config);

    return;
}

sub zMapSendCommands {
    my ($self, @xml) = @_;

    my $xr = $self->zMapGetXRemoteClientByName($self->slice_name());
    unless ($xr) {
        warn "No current window.";
        return;
    }
    warn "Sending window '", $xr->window_id, "' this xml:\n", @xml;

    my @a = $xr->send_commands(@xml);

    for(my $i = 0; $i < @xml; $i++){
        my ($status, $xmlHash) = zMapParseResponse($a[$i]);
        if ($status =~ /^2\d\d/) { # 200s
            warn "OK\n";
        } else {
            my $error = $xmlHash->{'error'}{'message'};
            warn "ERROR: $a[$i]\n$error\n";
            $self->xremote_cache->remove_clients_to_bad_windows();
            die $error;
        }
    }

    return;
}

=head1 post_response_client_cleanup

A function to cleanup any bad windows that might exist.
Primary user of this is the zMapRelaunchZMap function.

=cut

sub post_response_client_cleanup {
    my ($zmap, $self) = @_;
    $zmap->post_respond_handler();
    $self->xremote_cache->remove_clients_to_bad_windows();
    return;
}

=head1 post_response_client_cleanup_launch_in_a_zmap

Cleanup any bad windows that might exist & call _launchInAZMap

=cut

sub post_response_client_cleanup_launch_in_a_zmap {
    my ($zmap, $self) = @_;

    post_response_client_cleanup($zmap, $self);

    $self->_launchInAZMap();

    return;
}

=head1 zMapRelaunchZMap

A  handler to  handle finalise  requests. ZMap  sends these  when it's
closing the  whole program. Depending  on whether we want  to relaunch
zmap might be launched again.

=cut

sub zMapRelaunchZMap {
    my ($self, $xml) = @_;

    if ($self->{'_relaunch_zmap'}) {
        $self->_launchZMap();
        $self->{'_relaunch_zmap'} = 0;
    }
    elsif ($self->{'_launch_in_a_zmap'}) {
        $self->zMapZmapConnector->post_respond_handler(\&post_response_client_cleanup_launch_in_a_zmap, [$self]);
        $self->{'_launch_in_a_zmap'} = 0;
    }
    else {
        $self->zMapZmapConnector->post_respond_handler(\&post_response_client_cleanup, [$self]);
    }

    return (200, "all closed");
}

=head1 zMapKillZmap

Attempts  to kill  zmap,  return true  if  it succeeded  and false  on
failure.  If relaunch = true and zMapKillZmap returns true then zmap
should relaunch, any other combination probably means no relaunch will
occur. There will still be a call to RelaunchZMap though as a finalised
request will be sent from zmap.

=cut

sub zMapKillZmap {
    my ($self, $relaunch, $in_a_zmap) = @_;

    ### We're only using the pid as marker for zmap having been started
    if (my $pid = $self->zMapPID) {
        my $rval             = 0;
        my $main_window_name = $self->main_window_name();

        warn "Looking for $main_window_name";

        if (my $xr = $self->zMapGetXRemoteClientByName($main_window_name)) {

            # check we can ping...
            if ($xr->ping()) {
                warn "Ping OK - sending 'shutdown'";
                $self->{'_relaunch_zmap'}    = $relaunch;
                $self->{'_launch_in_a_zmap'} = $in_a_zmap;

                $xr->send_commands('<zmap><request action="shutdown"/></zmap>');

                $rval = 1;    # everything has been as successful as can be
                ### Check shutdown by checking property set by ZMap?
                ### This is done in zMapRelaunchZMap...
            }
            else {

                # zmap probably died without sending us a message... seg fault...
                warn sprintf "Failed to ping %s, zmap probably crashed.", $xr->window_id();
                $rval = 0;
            }

            warn sprintf "About to delete client %s", $xr->window_id;
            $self->xremote_cache->remove_client_with_id($xr->window_id());
        }

        warn sprintf "finishing %s", "zMapKillZmap";

        return $rval;
    }

    return 0;
}

=head1 zMapPID

Stores the process id for zmap.

=cut

sub zMapPID {
    my ($self, $zmap_process_id) = @_;

    if ($zmap_process_id) {
        $self->{'_zMap_ZMAP_PROCESS_ID'} = $zmap_process_id;
    }
    return $self->{'_zMap_ZMAP_PROCESS_ID'};
}

sub zMapXRemoteClients {
    my ($self) = @_;
    return $self->{'_zMap_ZMAP_XREMOTE_CLIENTS'} ||= { };
}

=head1 zMapZmapConnector

This is the way we receive commands from zmap.

=cut

sub zMapZmapConnector {
    my ($self) = @_;
    my $zc = $self->{_zMap_ZMAP_CONNECTOR};
    return $zc;
}

sub zMapZmapConnectorNew {
    my ($self) = @_;
    my $mb = $self->menu_bar();
    my $zc = ZMap::Connect->new;
    $zc->init($mb, \&RECEIVE_FILTER, [ $self, qw() ]);
    my $id = $zc->server_window_id();
    return $zc;
}

sub zMapDotBlixemrcContent {
    my ($self) = @_;

    # extract the blixem stanza so that we can put it first
    my $blixem_config = $self->AceDatabase->blixem_config;
    my $blixem_stanza = delete $blixem_config->{blixem};

    return
        join '',
        $self->formatZmapDefaults('blixem', %{$blixem_stanza}),
        ( map {
            $self->formatZmapDefaults($_, %{$blixem_config->{$_}});
          } sort keys %{$blixem_config} );
}

sub zMapDotZmapContent{
    my ($self, $stylesfile) = @_;
    
    return
        $self->zMapZMapDefaults
      . $self->zMapWindowDefaults
      . $self->zMapBlixemDefaults
      . $self->zMapAceServerDefaults($stylesfile)
      . $self->zMapGffFilterDefaults($stylesfile)
      . $self->zMapGlyphDefaults
      ;
}

sub zMapGlyphDefaults {
    my ($self) = @_;
    
    return $self->formatZmapDefaults(
        'glyphs',
        'up-tri'    => '<0,-4; -4,0; 4,0; 0,-4>',
        'dn-tri'    => '<0,4; -4,0; 4,0; 0,4>',
        'up-hook'   => '<0,0; 15,0; 15,-10>',
        'dn-hook'   => '<0,0; 15,0; 15,10>',
    );
}

sub zMapAceServerDefaults {
    my ($self, $stylesfile) = @_;

    my $server = $self->AceDatabase->ace_server;

    my $protocol = 'acedb';

    my $url = sprintf q{%s://%s:%s@%s:%d}, $protocol, $server->user, $server->pass, $server->host, $server->port;

    my $collection = $self->Assembly->MethodCollection;
    my $featuresets = join ' ; ', map { $_->name } $collection->get_all_top_level_Methods;

    return $self->formatZmapDefaults(
        $self->slice_name,
        url       => $url,
        writeback => 'false',
        sequence  => 'true',

        # Can specify a stylesfile instead of featuresets

        featuresets     => $featuresets,
        stylesfile      => $stylesfile,
    );
}

sub zMapGffFilterDefaults {
    
    my ($self, $stylesfile) = @_;

    my $text;
    my %filter_columns;
    my %filter_styles;
    my %filter_descs;

    for (values %{$self->AceDatabase->filters}) {

        my $filter = $_->{filter};
        my $state_hash = $_->{state};

        $text .= $self->formatZmapDefaults(
            $filter->name,
            url             => $filter->source_url($self->AceDatabase),
            featuresets     => join(' ; ', @{$filter->featuresets}),
            delayed         =>
            ( $state_hash->{wanted} && ! $state_hash->{failed} )
            ? 'false' : 'true',
            stylesfile      => $stylesfile,
            group           => 'always',
        );
        
        if ($filter->zmap_column) {
            my $fsets = $filter_columns{$filter->zmap_column} ||= [];
            push @{ $fsets }, @{$filter->featuresets};
        }
        
        if ($filter->zmap_style) {
            $filter_styles{$filter->name} = $filter->zmap_style;
        }
        
        if ($filter->description) {
            $filter_descs{$filter->name} = $filter->description;
        }
    }
    
    if (keys %filter_columns) {
        
        # also add a columns stanza to group featuresets into columns
        
        $text .= $self->formatZmapDefaults(
            'columns',
            map { $_ => join ' ; ', @{ $filter_columns{$_} } } keys %filter_columns,
        );
    }
    
    if (keys %filter_styles) {
        
        # and a featureset-styles stanza to specify the style for each featureset
        
        $text .= $self->formatZmapDefaults(
            'featureset-style',
            map { $_ => $filter_styles{$_} } keys %filter_styles,
        );
    }
    
    if (keys %filter_descs && 0) {
        
        # and a filter description stanza
        
        $text .= $self->formatZmapDefaults(
            'featureset-description',
            map { $_ => $filter_descs{$_} } keys %filter_descs,
        );
    }
    
    return $text;
}

sub zMapZMapDefaults {
    my ($self) = @_;

    # extract the ZMap stanza so that we can put it first
    my $zmap_config = $self->AceDatabase->zmap_config;
    my $zmap_stanza = delete $zmap_config->{ZMap};

    return
        join '',
        $self->formatZmapDefaults('ZMap', %{$zmap_stanza}),
        ( map {
            $self->formatZmapDefaults($_, %{$zmap_config->{$_}});
          } sort keys %{$zmap_config} );
}

sub zMapBlixemDefaults {
    my ($self) = @_;

    return $self->formatZmapDefaults(
        'blixem',
        'config-file' => $self->zMapConfigPath('blixemrc'),
        %{ $self->AceDatabase->DataSet->config_section('blixem') },
    );
}

sub zMapWindowDefaults {
    my ($self) = @_;

    return $self->formatZmapDefaults(
        'ZMapWindow',
        %{ $self->AceDatabase->DataSet->config_section('ZMapWindow') },
    );
}

sub formatZmapDefaults {
    my ($self, $key, %defaults) = @_;

    my $def_str = "\n[$key]\n";
    for my $setting ( sort keys %defaults ) {
        my $value = $defaults{$setting};
        $value = join ' ; ', @{$value} if ref $value;
        $def_str .= qq{$setting = $value\n};
    }
    $def_str .= "\n";

    return $def_str;
}

sub formatGtkrcStyleDef {
    my ($self, $style_class, %defaults) = @_;

    my $style_string = qq(\nstyle "$style_class" {\n);

    while (my ($style_element, $value) = each %defaults) {
        $style_string .= qq(  $style_element = "$value" \n);
    }

    $style_string .= qq(}\n);

    return $style_string;
}

sub formatGtkrcWidgetDef {
    my ($self, $widget_path, $style_class) = @_;

    my $widget_string = qq(\nwidget "$widget_path" style "$style_class"\n);

    return $widget_string;
}

sub formatGtkrcWidget {
    my ($self, $widget_path, $style_class, %style_def) = @_;

    my $full_def = $self->formatGtkrcStyleDef($style_class, %style_def);
    $full_def .= $self->formatGtkrcWidgetDef($widget_path, $style_class);

    return $full_def;
}

sub zMapDotGtkrcContent {
    my ($self) = @_;

    # to create a coloured border for the focused view.
    my $full_content = $self->formatGtkrcWidget(
        "*.zmap-focus-view",
        "zmap-focus-view-frame",
        qw{
          bg[NORMAL]      gold
          }
    );

    # to make the info labels stand out and look like input boxes...
    $full_content .= $self->formatGtkrcWidget(
        "*.zmap-control-infopanel",
        "infopanel-labels",
        qw{
          bg[NORMAL]      white
          }
    );

    # to make the context menu titles blue
    $full_content .= $self->formatGtkrcWidget(
        "*.zmap-menu-title.*",
        "menu-titles",
        qw{
          fg[INSENSITIVE] blue
          }
    );

    # to create a coloured border for the view with an unknown species. (Not sure this works properly...)
    $full_content .= $self->formatGtkrcStyleDef(
        "default-species",
        qw{
          bg[NORMAL]    gold
          }
    );

    # foreach (species){ self->formatGtkrcStyleDef("species", ... ) }

    return $full_content;
}

sub zMapWriteConfigFile {
    my ($self, $file, $config) = @_;

    my $path = $self->zMapConfigPath($file);
    open my $fh, '>', $path
        or confess "Can't write to '$path'; $!";
    print $fh $config;
    close $fh
      or confess "Error writing to '$path'; $!";

    return;
}

sub zMapConfigPath {
    my ($self, $file) = @_;

    my $dir  = $self->zMapZmapDir;
    my $path = "${dir}/${file}";

    return $path;
}

sub zMapZmapDir {
    my ($self) = @_;
    return $self->{'_zMap_ZMAP_DIR'} ||=
        ($self->ace_path . '/ZMap');
}

#===========================================================

sub xremote_cache {
    my ($self) = @_;

    my $cache = $self->{'_xremote_cache'};

    return $cache;
}

sub main_window_name {
    my ($self, $name) = @_;

    $name = 'ZMap port #' . $self->AceDatabase->ace_server->port();

    return $name;
}

=head1 zMapRegisterClient

A handler to handle register_client requests.

=cut

sub zMapRegisterClient {
    my ($self, $xml) = @_;

    my $zc = $self->zMapZmapConnector;

    unless ($xml->{'request'}->{'client'}->{'xwid'}
        && $xml->{'request'}->{'client'}->{'request_atom'}
        && $xml->{'request'}->{'client'}->{'response_atom'})
    {
        warn "mismatched request for register_client:\n",
          "id, request and response required\n",
          "Got '${xml}'\n";
        return (403, $zc->basic_error("Bad Request!"));
    }

    $self->zMapProcessNewClientXML($xml, $self->main_window_name());

    $zc->post_respond_handler(\&open_clones, [$self]);

    my $response_xml = $zc->client_registered_response;

    return (200, $response_xml);
}

=head1 zMapEdit

A handler to handle edit requests.  Returns a basic response.

=cut

sub zMapEdit {
    my ($self, $xml_hash) = @_;

    my $response;
    my $zc = $self->zMapZmapConnector;
    if ($xml_hash->{'request'}->{'action'} eq 'edit') {

        my $feat_hash = $xml_hash->{'request'}->{'align'}->{'block'}->{'featureset'}{'feature'}
          or return return (200, $zc->handled_response(0));

        # Are there any transcripts in the list of features?
        my @subseq_names;
      NAME: foreach my $name (keys %$feat_hash) {
            my $feat = $feat_hash->{$name};
            if (my $style = $feat->{'style'}) {
                if (lc($style) eq 'genomic_canonical') {
                    confess "invalid name for a genomic_canonical feature: ${name}"
                        unless my ( $accession_version ) = $name =~ / ^
    (.*) \. [[:digit:]]+ \. [[:digit:]]+
    - [[:digit:]]+ # start
    - [[:digit:]]+ # end
    - [[:alpha:]]+ # strand
    $ /x;
                    $self->edit_Clone_by_accession_version($accession_version);
                    return (200, $zc->handled_response(1));
                }
            }
            my $subs = $feat->{'subfeature'}
              or next;
            unless (ref $subs eq 'ARRAY') {
                confess "Unexpected feature format for ${name}";
            }
            foreach my $s (@$subs) {

                # Only transcripts have exons
                if ($s->{'ontology'} eq 'exon') {
                    push(@subseq_names, $name);
                    next NAME;
                }
            }
        }

        if (@subseq_names) {
            my $success = $self->edit_subsequences(@subseq_names);
            return (200, $zc->handled_response($success));
        }
        else {
            return (200, $zc->handled_response(0));
        }
    }
    else {
        confess "Not an 'edit' action";
    }

}

=head1 zMapHighlight

A  handler  to  handle  single_select  and  multiple_select  requests.
returns a basic response.

=cut

sub zMapHighlight {
    my ($self, $xml_hash) = @_;

    my $zc = $self->zMapZmapConnector;

    my $features_hash = $xml_hash->{'request'}{'align'}{'block'}{'featureset'}{'feature'} || {};

    # Needs to do something interesting to find the object to highlight.
    if ($xml_hash->{'request'}->{'action'} eq 'single_select') {
        $self->deselect_all();
        foreach my $name (keys(%$features_hash)) {
            $self->highlight_by_name_without_owning_clipboard($name);
        }
    }
    elsif ($xml_hash->{'request'}->{'action'} eq 'multiple_select') {
        foreach my $name (keys(%$features_hash)) {
            $self->highlight_by_name_without_owning_clipboard($name);
        }
    }
    else { confess "Not a 'select' action\n"; }

    return (200, $zc->handled_response(1));
}

=head1 zMapTagValues

A  handler  to handle  feature_details  request.   returns a  notebook
response.

=cut

sub zMapTagValues {
    my ($self, $xml_hash) = @_;

    my $pages = "";
    if ($xml_hash->{'request'}->{'action'} eq 'feature_details') {
        my $feature_hash = $xml_hash->{'request'}{'align'}{'block'}{'featureset'}{'feature'} || {};

        # There is only ever 1 feature in the XML from Zmap
        my ($name) = keys %$feature_hash;

        unless ($name) {
            warn "No feature in featureset of XML";
        }
        elsif (my $subseq = $self->get_SubSeq($name)) {
            $pages .= $subseq->zmap_info_xml;
        }
        elsif (! $feature_hash->{$name}{'subfeature'}) {
            # It is not a transcript if it doesn't have subfeatures
            $pages .= $self->zmap_feature_details_xml($name);
            $pages .= $self->zmap_feature_evidence_xml($name);
        }
    }

    my $xml = Hum::XmlWriter->new;
    $xml->open_tag('response', { handled => $pages ? 'true' : 'false' });
    if ($pages) {
        $xml->open_tag('notebook');
        $xml->open_tag('chapter');
        $xml->add_raw_data($pages);
    }
    $xml->close_all_open_tags;

    return (200, $xml->flush);
}

my $zmap_feature_details_tags = [
    [ taxon_id => {
        name => 'Taxon ID',
        type => 'simple',
      }, ],
    [ description => {
        name => 'Description',
        type => 'scrolled_text',
      }, ],
    ];

my $zmap_feature_details_xml_sql = <<'SQL'
SELECT source_db, taxon_id, description FROM accession_info WHERE accession_sv = ?
SQL
    ;

sub zmap_feature_details_xml {
    my ($self, $feat_name) = @_;

    my $row = $self->AceDatabase->DB->dbh->selectrow_arrayref(
        $zmap_feature_details_xml_sql, {}, $feat_name);
    return '' unless $row;
    my ($source_db, $taxon_id, $desc) = @{$row};

    # Put this on the "Details" page which already exists.
    my $xml = Hum::XmlWriter->new(5);
    $xml->open_tag('page',       { name => 'Details' });
    $xml->open_tag('subsection', { name => 'Feature' });
    $xml->open_tag('paragraph',  { type => 'tagvalue_table' });
    $xml->full_tag('tagvalue', { name => 'Source database', type => 'simple' }, $source_db);
    $xml->full_tag('tagvalue', { name => 'Taxon ID',        type => 'simple' }, $taxon_id);
    $xml->full_tag('tagvalue', { name => 'Description', type => 'scrolled_text' }, $desc);
    $xml->close_all_open_tags;

    return $xml->flush;
}

sub zmap_feature_evidence_xml {
    my ($self, $feat_name) = @_;

    my $feat_name_is_prefixed =
        $feat_name =~ /\A[[:alnum:]]{2}:/;

    my $subseq_list = [];
    foreach my $name ($self->list_all_SubSeq_names) {
        if (my $subseq = $self->get_SubSeq($name)) {
            push(@$subseq_list, $subseq);
        }
    }
    my $used_subseq_names = [];
  SUBSEQ: foreach my $subseq (@$subseq_list) {

        #warn "Looking at: ", $subseq->name;
        my $evi_hash = $subseq->evidence_hash();

        # evidence_hash looks like this
        # evidence = {
        #   type    => [ qw(evidence names) ],
        #   EST     => [ qw(Em:BC01234.1 Em:CR01234.2) ],
        #   cDNA    => [ qw(Em:AB01221.3) ],
        #   ncRNA   => [ qw(Em:AF480562.1) ],
        #   Protein => [ qw(Sw:Q99IVF1) ]
        # }

        foreach my $evi_type (keys %$evi_hash) {
            my $evi_array = $evi_hash->{$evi_type};
            foreach my $evi_name (@$evi_array) {
                $evi_name =~ s/\A[[:alnum:]]{2}://
                    if ! $feat_name_is_prefixed;
                if ($feat_name eq $evi_name) {
                    push(@$used_subseq_names, $subseq->name);
                    next SUBSEQ;
                }
            }
        }
    }
    if (@$used_subseq_names) {
        my $xml = Hum::XmlWriter->new(5);
        $xml->open_tag('page',       { name => 'Details' });
        $xml->open_tag('subsection', { name => 'Feature' });
        $xml->open_tag('paragraph',  { name => 'Evidence', type => 'homogenous' });
        foreach my $name (@$used_subseq_names) {
            $xml->full_tag('tagvalue', { name => 'for transcript', type => 'simple' }, $name);
        }
        $xml->close_all_open_tags;
        return $xml->flush;
    }
    else {
        return '';
    }
}

sub zMapRemoveView {
    my ($self, $xml) = @_;

    # I guess all we need to do here is remove the associated xid from the cache...

    my ($client_tag, $xid);

    my $zc = $self->zMapZmapConnector;

    if ($client_tag = $xml->{'request'}->{'client'}) {
        $xid = $client_tag->{'xwid'};
    }

    if ($xid) {
        warn sprintf "... going to remove %s", $xid;
        $self->xremote_cache->remove_client_with_id($xid);
    }

    return (200, $zc->handled_response(1));
}

sub zMapFeaturesLoaded {
    my ($self, $xml) = @_;
    
    my @featuresets = split(/;/, $xml->{'request'}{'featureset'}{'names'});
    
    my $status = $xml->{'request'}{'status'}{'value'};
    my $msg    = $xml->{'request'}{'status'}{'message'};
    
    my $filter_hash = $self->AceDatabase->filters;
    my $state_changed = 0;

    # We used to get featureset names back from zmap in lower case so that we
    # had to do a case insensitive search through the filter names for a
    # match. Starting with Zmap 0.1.114 (or maybe earlier) we get them in
    # their original case. But then I discovered that replies from
    # load_features requests come back in lower case, so I put case
    # insensitivity code back.  Can remove when zmap fixed (RT #211672).

    my %case_insensitive_filter_hash;
    while (my ($name, $entry) = each %$filter_hash) {
        $case_insensitive_filter_hash{   $name} = $entry;
        $case_insensitive_filter_hash{lc $name} = $entry;
    }
    
    foreach my $set_name (@featuresets) {
        # NB: careful not to auto-vivify entries in $filter_hash !
        # if (my $filter_entry = $filter_hash->{$set_name}) {
        if (my $filter_entry = $case_insensitive_filter_hash{$set_name}) {
            my $state_hash = $filter_entry->{'state'};
            if ($status == 0 && ! $state_hash->{'failed'}) {
                $state_changed = 1;
                $state_hash->{'failed'} = 1;
                $state_hash->{'fail_msg'} = $msg; ### Could store in SQLite db
            }
            elsif ($status == 1 && ! $state_hash->{'done'}) {
                $state_changed = 1;
                $state_hash->{'done'} = 1;
                $state_hash->{'failed'} = 0; # reset failed flag if filter succeeds
                my $filter = $filter_entry->{'filter'};
                if ($filter->process_gff_file) {
                    my @tsct = $self->AceDatabase->process_gff_file_from_Filter($filter);
                    if (@tsct) {
                        $self->add_external_SubSeqs(@tsct);
                        $self->draw_subseq_list;
                    }
                }
            }
        }
        # else {
        #     # We see a warning for each acedb featureset
        #     warn "Ignoring featurset '$set_name'";
        # }
    }
    
    if ($state_changed) {
        # save the state of each gff filter to disk so we can recover the session
        $self->AceDatabase->save_filter_state;
        
        # and update the delayed flags in the zmap config file
        $self->zMapUpdateConfigFile;
    }
    
    return (200, $self->zMapZmapConnector->handled_response(1));
}

sub zMapUpdateConfigFile {
    my ($self) = @_;
    
    my $cfg = $self->{_zmap_cfg} ||= Config::IniFiles->new( -file => $self->zMapConfigPath('ZMap'));

    while ( my ( $name, $value ) = each %{$self->AceDatabase->filters}) {
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

sub zMapIgnoreRequest {
    my ($self) = @_;
    
    return(200, $self->zMapZmapConnector->handled_response(0));
}

sub RECEIVE_FILTER {
    my ($connect, $reqXML, $obj) = @_;

    # The table of actions and functions...
    my $lookup = {
        register_client => 'zMapRegisterClient',
        edit            => 'zMapEdit',
        single_select   => 'zMapHighlight',
        multiple_select => 'zMapHighlight',
        finalised       => 'zMapRelaunchZMap',
        feature_details => 'zMapTagValues',
        view_closed     => 'zMapRemoveView',
        features_loaded => 'zMapFeaturesLoaded',
    };

    # @list could be dynamically created...
    my @list = keys(%$lookup);

    unless ($reqXML->{'request'}) {

        #for my $k (keys %$reqXML) {
        #    $reqXML->{'request'}->{$k} = $reqXML->{$k};
        #    delete $reqXML->{$k};
        #}

        warn "INVALID REQUEST: no <request> block\n";
    }

    my $action = $reqXML->{'request'}->{'action'};

    warn "PARSED REQUEST: " . Dumper($reqXML) . "\n" if $ZMAP_DEBUG;

    warn "In RECEIVE_FILTER for action=$action\n" if $ZMAP_DEBUG;

    warn sprintf "\n_zmap_request_callback:XML\n>>>\n%s\n<<<\n", $reqXML if $ZMAP_DEBUG;

    # The default response code and message.
    my ($status, $response) = (404, $obj->zMapZmapConnector->basic_error("Unknown Command"));

    # find the method to call...
    foreach my $valid (@list) {
        if (
            $action eq $valid
            && ($valid = $lookup->{$valid})    # N.B. THIS SHOULD BE ASSIGNMENT NOT EQUALITY
            && $obj->can($valid)
          )
        {

            # call the method to get the status and response
            #warn "Calling $obj->$valid($reqXML)";
            ($status, $response) = $obj->$valid($reqXML);
            last;                              # no need to go any further...
        }
    }

    warn "Response:\n$response" if $ZMAP_DEBUG;

    warn sprintf
        "\n_zmap_request_callback\nstatus:%d\nresponse\n>>>\n%s\n<<<\n"
        , $status, $response
        if $ZMAP_DEBUG;

    return ($status, $response);
}

=head1 zMapGetXRemoteClientByName

The XRemoteCache caches objects based on their window ids. This module
needs some  way to get  the object cached  for a particular  window id
based on a name. e.g. the window that's displaying the features.

=cut

sub zMapGetXRemoteClientByName {
    my ($self, $key) = @_;

    my $client = $self->zMapXRemoteClients->{$key};

    return $client;
}

sub zMapGetXRemoteClientByAction {
    my ($self, $action) = @_;

    my $cache = $self->xremote_cache;
    my $pid = $self->zMapPID();
    my $client = $cache->get_own_client_for_action_pid($action, $pid);

    return $client;
}

# This is not a method on self, but a standalone function taking a
# ZMap::Connect and a MenuCanvasWindow::XaceSeqChooser.

sub open_clones {
    my ($zmap, $self) = @_;
    $zmap->post_respond_handler();    # clear the handler...
    $self->zMapOpenClones;
    return;
}

sub zMapOpenClones {
    my ($self) = @_;
    my $xremote = $self->zMapGetXRemoteClientByName($self->main_window_name());
    return unless $self->zMapDoRequest($xremote, "new_zmap", qq!<zmap><request action="new_zmap"/></zmap>!);
    $xremote = $self->zMapGetXRemoteClientByName("ZMap");
    $self->zMapRegisterClientRequest($xremote);
    $self->zMapNewView($xremote);
    return;
}

sub zMapRegisterClientRequest {
    my ($self, $xremote) = @_;

    my $zmap = $self->zMapZmapConnector;
    $self->zMapDoRequest($xremote, "register_client", $zmap->connect_request());

    return;
}

sub zMapGetMark {

    my ($self) = @_;

    if (my $client = $self->zMapGetXRemoteClientByAction('get_mark')) {

        my $xml = qq(<zmap><request action="get_mark" /></zmap>);

        my ($response) = $client->send_commands($xml);

        my ($status, $hash) = zMapParseResponse($response);

        if ($status =~ /^2/ && $hash->{response}->{mark}->{exists} eq "true") {

            my $start = abs($hash->{response}->{mark}->{start});
            my $end   = abs($hash->{response}->{mark}->{end});

            if ($end < $start) {
                ($start, $end) = ($end, $start);
            }

            return ($start, $end);
        }
    }
    else {
        warn "Failed to get client for 'get_mark'";
    }

    return;
}

sub zMapLoadFeatures {
    my ($self, @featuresets) = @_;

    if (my $client = $self->zMapGetXRemoteClientByAction('load_features')) {

        my $xml = Hum::XmlWriter->new;
        $xml->open_tag('zmap');
        $xml->open_tag('request',
                       {
                           action => 'load_features',
                           # load => 'mark', # not used at the moment
                       });
        $xml->open_tag('align');
        $xml->open_tag('block');
        foreach my $fs_name (@featuresets) {
            $xml->open_tag('featureset', { name => $fs_name });
            $xml->close_tag;
        }
        $xml->close_all_open_tags;

        my ($response) = $client->send_commands($xml->flush);

        my ($status, $hash) = zMapParseResponse($response);

        unless ($status =~ /^2/) {
            warn "Problem loading featuresets";
        }
    }
    else {
        warn "Failed to get client for 'load_features'";
    }

    return;
}

sub zMapDeleteFeaturesets {
    my ($self, @featuresets) = @_;

    if (my $client = $self->zMapGetXRemoteClientByAction('delete_feature')) {

        my $xml = Hum::XmlWriter->new;
        $xml->open_tag('zmap');
        $xml->open_tag('request', { action => 'delete_feature' });
        $xml->open_tag('align');
        $xml->open_tag('block');

        for my $featureset (@featuresets) {
            $xml->open_tag('featureset', { name => $featureset });
            $xml->close_tag;
        }
        $xml->close_all_open_tags;

        my ($response) = $client->send_commands($xml->flush);

        my ($status, $hash) = zMapParseResponse($response);

        unless ($status =~ /^2/) {
            unless ($hash->{error}->{message} =~ /Unknown FeatureSet/) {

                # XXX: temporarily ignore this error message, as we want to be able to call
                # delete_feature on featuresets that aren't currently in the zmap window
                warn "Problem deleting featuresets: " . $hash->{error}->{message};
            }
        }
    }
    else {
        warn "Failed to get client for 'delete_feature'";
    }
    
    return;
}

sub zMapZoomToSubSeq {

    my ($self, $subseq) = @_;

    if (my $client = $self->zMapGetXRemoteClientByAction('zoom_to')) {
        my $xml = Hum::XmlWriter->new;
        $xml->open_tag('zmap');
        $xml->open_tag('request', { action => 'zoom_to' });
        $xml->open_tag('align');
        $xml->open_tag('block');
        $xml->open_tag('featureset', { name => $subseq->GeneMethod->name });
        $subseq->zmap_xml_feature_tag($xml, $self->AceDatabase->offset);
        $xml->close_all_open_tags;

        my $command = $xml->flush;
        my ($response) = $client->send_commands($command);
        my ($status, $hash) = zMapParseResponse($response);
        if ($status =~ /^2/ && $hash->{response} =~ /executed/) {
            return 1;
        }
    }
    else {
        warn "Failed to get client for 'zoom_to'";
    }

    return 0;
}

my $zmap_new_view_xml_format = <<'FORMAT'
<zmap>
 <request action="new_view">
  <segment sequence="%s" start="%d" end="%d">
%s
  </segment>
 </request>
</zmap>
FORMAT
    ;

sub _zmap_new_view_xml {
    my ($self, $config) = @_;

    my $slice = $self->AceDatabase->smart_slice;

    my $segment = $slice->ssname;
    my $start   = $slice->start;
    my $end     = $slice->end;

    my @fields = ( $segment, $start, $end, $config );
    my @xml_escaped_fields = map { xml_escape($_) } @fields;
    my $xml = sprintf $zmap_new_view_xml_format, @xml_escaped_fields;

    return $xml;
}

sub zMapNewView {
    my ($self, $xremote, $config) = @_;

    $config = "" unless defined $config;

    my $new_view_xml = $self->_zmap_new_view_xml($config);
    unless ($self->zMapDoRequest($xremote, "new_view", $new_view_xml)) {
        warn "Failed to create a new view";
        return;
    }

    my $xremote_new = $self->zMapGetXRemoteClientByName($self->slice_name);
    unless ($xremote_new) {
        warn "Failed to find the new xremote client";
        return;
    }
    $self->zMapRegisterClientRequest($xremote_new);

    return;
}

=head1 zMapDoRequest

return true for success

=cut

sub zMapDoRequest {
    my ($self, $xremote, $action, $command) = @_;

    warn sprintf "\nzMapDoRequest:command\n>>>\n%s\n<<<\n", $command if $ZMAP_DEBUG;
    my ($response) = $xremote->send_commands($command);
    warn sprintf "\nzMapDoRequest:response\n>>>\n%s\n<<<\n", $response if $ZMAP_DEBUG;

    my ($status, $xmlHash) = zMapParseResponse($response);
    if ($status =~ /^2\d\d/) {    # 200s
        if ($action eq 'new_zmap') {
            $self->zMapProcessNewClientXML($xmlHash, "ZMap");
        }
        elsif ($action eq 'new_view') {
            $self->zMapProcessNewClientXML($xmlHash, $self->slice_name());
        }
        elsif ($action eq 'list_windows') {
            $self->zMapProcessNewClientXML($xmlHash, "ZMapWindow");
        }
        return 1;
    }
    else {
        $self->xremote_cache->remove_clients_to_bad_windows if $status == 412;
        return 0;
    }
}

sub zMapProcessNewClientXML {
    my ($self, $xml, $lookup_key) = @_;

    my $cache = $self->xremote_cache;

    my ($client_tag, $id);

    if (exists($xml->{'response'})) {
        $client_tag = $xml->{'response'}->{'client'};
    }
    else {
        $client_tag = $xml->{'request'}->{'client'};
    }

    if ($client_tag) {
        my $client_array = [];
        my $add_counter  = 0;
        my $counter      = 0;
        my $full_key     = $lookup_key;

        if (ref($client_tag) eq 'ARRAY') {
            $client_array = $client_tag;
            $add_counter  = 1;
        }
        else {
            $client_array = [$client_tag];
        }

        foreach my $client (@{$client_array}) {
            $full_key = "$lookup_key.$counter" if ($add_counter);
            if ($id = $client->{'xwid'}) {

                # get actions array from xml.
                my @actions = qw();
                my $subtag  = q!action!;
                if (ref($client->{$subtag}) eq 'ARRAY') {
                    push(@actions, @{ $client->{$subtag} });
                }
                elsif (defined($client->{$subtag}) && !ref($client->{$subtag})) {
                    push(@actions, $client->{$subtag});
                }
                else {
                    warn "Odd for a client to not have actions.";
                }
                my $xr =
                    $cache->create_client_with_pid_id_actions($self->zMapPID(), $id, @actions);
                $self->zMapXRemoteClients->{$full_key} = $xr;
            }
            $counter++;
        }
    }
    else {
        warn "malformed register client xml [no window id]";
    }

    return;
}

sub zMapParseResponse {
    my ($response) = @_;
    my $delimit  = X11::XRemote::delimiter();
    my ($status, $xml) = split(/$delimit/, $response, 2);
    my $hash   = XMLin($xml);
    return ($status, $hash);
}

1;

__END__


=pod

=head1 NAME - MenuCanvasWindow::ZmapSeqChooser

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk


=cut
