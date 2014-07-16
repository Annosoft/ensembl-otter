### Bio::Otter::Lace::Client

package Bio::Otter::Lace::Client;

use strict;
use warnings;
use Carp;

use Try::Tiny;

use Net::Domain qw{ hostname hostfqdn };
use Proc::ProcessTable;

use List::MoreUtils qw( uniq );
use Log::Log4perl::Level;
use LWP;
use URI::Escape qw{ uri_escape };
use HTTP::Cookies::Netscape;
use Term::ReadKey qw{ ReadMode ReadLine };

use XML::Simple;
use JSON;

use Bio::Vega::Author;
use Bio::Vega::ContigLock;

use Bio::Otter::Git; # for feature branch detection
use Bio::Otter::Debug;
use Bio::Otter::Version;
use Bio::Otter::Lace::Defaults;
use Bio::Otter::Lace::DataSet;
use Bio::Otter::Lace::SequenceSet;
use Bio::Otter::Lace::CloneSequence;
use Bio::Otter::Lace::PipelineStatus;
use Bio::Otter::Lace::SequenceNote;
use Bio::Otter::Lace::AceDatabase;
use Bio::Otter::Lace::DB;
use Bio::Otter::LogFile;
use Bio::Otter::Auth::SSO;
use Bio::Otter::Utils::AccessionInfo::Serialise qw( accession_info_column_order );

use 5.009001; # for stacked -f -r which returns false under 5.8.8

# we add "1" and "2" as keys for backwards compatibility with "debug=1" and "debug=2"
Bio::Otter::Debug->add_keys(qw(
    Client 1
    Server 2
    ));

# Window title prefix.
#
# Is a global for ease of interpolation.  Don't expect existing
# windows to update when it changes.
our $PFX = 'otter: ';

sub _pkginit {
    my ($pkg) = @_;
    # needs do_getopt to have happened
    my $short = $pkg->config_value('short_window_title_prefix');
    $PFX = 'o: ' if $short && $short > 0;
    # opt-out by negative values - B:O:L:D does not merge false values
    return 1;
}


{
    my $singleton;
    sub the {
        my ($pkg) = @_;
        return $singleton ||= $pkg->new;
    }
}

sub new {
    my ($pkg) = @_;

    # don't proceed without do_getopt
    Bio::Otter::Lace::Defaults->Client_needs_ready;

    __PACKAGE__->_pkginit;

    my ($script) = $0 =~ m{([^/]+)$};
    my $client_name = $script || 'otterlace';

    $ENV{'OTTERLACE_COOKIE_JAR'} ||= __user_home()."/.otter/ns_cookie_jar";

    my $new = bless {
        _client_name     => $client_name,
        _cookie_jar_file => $ENV{'OTTERLACE_COOKIE_JAR'},
    }, $pkg;

    my $debug = $new->config_value('debug');
    my $debug_show = defined $debug ? "'$debug'" : '<undefined>';
    warn "Debug from config: $debug_show\n";
    Bio::Otter::Debug->set($debug) if defined $debug;
    # nb. no loggers yet, because this object configures them

    return $new;
}

sub __user_home {
    my $home = (getpwuid($<))[7];
    return $home;
}

sub write_access {
    my ($self, $write_access) = @_;

    $self->logger->error('Set using the Config file please.') if $write_access;

    return $self->config_value('write_access') || 0;
}

sub author {
    my ($self, $author) = @_;

    $self->logger->error('Set using the Config file please.') if $author;

    return $self->config_value('author') || (getpwuid($<))[0];
}

sub email {
    my ($self, $email) = @_;

    $self->logger->error('Set using the Config file please.') if $email;

    return $self->config_value('email') || (getpwuid($<))[0];
}

sub client_name {
    my ($self) = @_;
    return $self->{'_client_name'};
}

sub debug_client {
    my ($self) = @_;
    # backwards compatibility with "debug=1" and "debug=2"
    my $debug_client = 0
        || Bio::Otter::Debug->debug('Client')
        || Bio::Otter::Debug->debug('1')
        || Bio::Otter::Debug->debug('2')
        ;
    return $debug_client;
}

sub debug_server {
    my ($self) = @_;
    # backwards compatibility with "debug=2"
    my $debug_server = 0
        || Bio::Otter::Debug->debug('Server')
        || Bio::Otter::Debug->debug('2')
        ;
    return $debug_server;
}

sub no_user_config {
    my $cfg = Bio::Otter::Lace::Defaults::user_config_filename();
    return !-f $cfg;
}

sub password_attempts {
    my ($self, $password_attempts) = @_;

    if (defined $password_attempts) {
        $self->{'_password_attempts'} = $password_attempts;
    }
    return $self->{'_password_attempts'} || 3;
}

sub config_path_default_rel_dot_otter {
    my ($self, $key) = @_;

    my $path = $self->config_value($key) or return;

    # Make $path into absolute file path
    # It is assumed to be relative to the ~/.otter directory
    # if not already absolute or beginning with "~/".
    my $home = __user_home();
    $path =~ s{^~/}{$home/};
    unless ($path =~ m{^/}) {
        $path = "$home/.otter/$path";
    }

    return $path;
}


sub get_log_dir {
    my ($self) = @_;
    my $home = __user_home();
    my $log_dir = "$home/.otter";
    if (mkdir($log_dir)) {
        warn "Made logging directory '$log_dir'\n"; # logging not set up, so this must use 'warn'
        return;
    }
    return $log_dir;
}

sub get_log_config_file {
    my ($self) = @_;

    my $config_file = $self->config_path_default_rel_dot_otter('log_config') or return;

    unless ( -f -r $config_file ) {
        warn "log_config file '$config_file' not readable, will use defaults";
        return;
    }
    return $config_file;
}

sub make_log_file {
    my ($self, $file_root) = @_;

    $file_root ||= 'client';

    my $log_dir = $self->get_log_dir or return;
    my( $log_file );
    my $i = 'a';
    do {
        $log_file = "$log_dir/$file_root.$$-$i.log";
        $i++;
    } while (-e $log_file);

    my $log_level = $self->config_value('log_level');
    my $config_file = $self->get_log_config_file;
    # logging not set up, so must use 'warn'
    if ($config_file) {
        warn "Using log config file '$config_file'\n";
    } else {
        if($self->debug_client) {
            warn "Logging output to '$log_file'\n";
        }
    }
    Bio::Otter::LogFile::make_log($log_file, $log_level, $config_file);
    $self->client_logger->level($DEBUG) if $self->debug_client;
    return;
}

sub cleanup {
    my ($self, $delayed) = @_;
    require Bio::Otter::Utils::Cleanup;
    my $cleaner = Bio::Otter::Utils::Cleanup->new($self);
    return $delayed ? $cleaner->fork_and_clean($delayed) : $cleaner->clean;
}

{
    my $session_number = 0;
    sub _new_session_path {
        my ($self) = @_;

        my $user = (getpwuid($<))[0];

        ++$session_number;
        return sprintf("%s.%s.%d.%d",
                       $self->_session_root, $user, $$, $session_number);
    }
}

sub _session_root {
    my ($called, $version) = @_;
    $version ||= Bio::Otter::Version->version;
    return '/var/tmp/lace_'.$version;
}

sub all_sessions {
    my ($self) = @_;

    my @sessions = map {
        $self->_session_from_dir($_);
    } $self->all_session_dirs;

    return @sessions;
}

sub _session_from_dir {
    my ($self, $dir) = @_;

    # this ignores completed sessions, as they have been renamed to
    # end in ".done"

    my ($pid) = $dir =~ m{lace[^/]+\.(\d+)\.\d+$};
    return unless $pid;

    my $mtime = (stat($dir))[9];
    return [ $dir, $pid, $mtime ];
}

sub all_session_dirs {
    my ($self, $version_glob) = @_;

    my $session_dir_pattern = $self->_session_root($version_glob) . ".*";
    my @session_dirs = glob($session_dir_pattern);

    # Skip if directory is not ours
    my $uid = $<;
    @session_dirs = grep { (stat($_))[4] == $uid } @session_dirs;

    return @session_dirs;
}

# Only creates the object.
# Does not create the directory, that's done by $adb->make_database_directory.
#
sub new_AceDatabase {
    my ($self) = @_;

    my $adb = Bio::Otter::Lace::AceDatabase->new;
    $adb->Client($self);
    $adb->home($self->_new_session_path);

    return $adb;
}

sub lock {
    my ($self, @args) = @_;

    $self->logger->logconfess("lock takes no arguments") if @args;

    return $self->write_access ? 'true' : 'false';
}

sub client_hostname {
    my ($self, $client_hostname) = @_;

    if ($client_hostname) {
        $self->{'_client_hostname'} = $client_hostname;
    }
    elsif (not $client_hostname = $self->{'_client_hostname'}) {
        $client_hostname = $self->{'_client_hostname'} = hostname();
    }
    return $client_hostname;
}

#
# now used by scripts only;
# please switch everywhere to using SequenceSet::region_coordinates()
#
sub chr_start_end_from_contig {
    my ($self, $ctg) = @_;

    my $chr_name  = $ctg->[0]->chromosome;
    my $start     = $ctg->[0]->chr_start;
    my $end       = $ctg->[-1]->chr_end;
    return($chr_name, $start, $end);
}

# "perlcritic --stern" refuses to learn that $logger->logconfess is fatal
sub get_DataSet_by_name { ## no critic (Subroutines::RequireFinalReturn)
    my ($self, $name) = @_;

    foreach my $ds ($self->get_all_DataSets) {
        if ($ds->name eq $name) {
            return $ds;
        }
    }
    $self->logger->logconfess("No such DataSet '$name'");
}

sub password_prompt{
    my ($self, $callback) = @_;

    if ($callback) {
        $self->{'_password_prompt_callback'} = $callback;
    }
    $callback = $self->{'_password_prompt_callback'} ||=
        sub {
            my ($self) = @_;

            unless (-t STDIN) { ## no critic (InputOutput::ProhibitInteractiveTest)
                $self->logger->error("Cannot prompt for password - not attached to terminal");
                return;
            }

            my $user = $self->author;
            print STDERR "Please enter your password ($user): ";
            ReadMode('noecho');
            my $password = ReadLine(0);
            print STDERR "\n";
            chomp $password;
            ReadMode('normal');
            return $password;
        };
    return $callback;
}

sub password_problem{
    my ($self, $callback) = @_;

    if ($callback) {
        $self->{'_password_problem_callback'} = $callback;
    }
    $callback = $self->{'_password_problem_callback'} ||=
      sub {
          my ($self, $message) = @_;
          $message =~ s{\n*\z}{};
          $self->logger->warn($message);
      };
    return $callback;
}

sub reauthorize_if_cookie_will_expire_soon {
    my ($self) = @_;

    # Soon is if cookie expires less than half an hour from now
    my $soon = time + (30 * 60);
    my $expiry = $self->cookie_expiry_time;
    if ($expiry < $soon) {
        $self->logger->warn(
            sprintf("reauthorize_if_cookie_will_expire_soon: expiry expected at %s", scalar localtime($expiry)));
        my $password_attempts = $self->password_attempts;
        while ($password_attempts) {
            return 1 if $self->authorize;
            $password_attempts--;
        }
        return 0;
    }
    else {
        return 1;
    }
}

# Generates errors when rejecting config changes
sub config_set {
    my ($self, $section, $param, $value) = @_;

    # Be conservative.  Most code still assumes the config is static
    # after initialisation.
    my $target = qq{[$section]$param};
    $self->logger->logdie("Runtime setting of preference $target is not yet implemented")
      unless grep { $_ eq $target }
        qw{ [client]author [client]write_access };

    Bio::Otter::Lace::Defaults::set_and_save($section, $param, $value);
    # Save was successful - update client state

    if ($target eq '[client]author') {
        try {
            $self->ensure_authorised;
        } catch {
            $self->logger->warn("After config_set $target, auth failed: $_");
            # we now have no valid authorisation
        };
    } # else no update needed

    # app is built on the assumption that these don't change, which we
    # will initially avoid by only showing prefs when auth fails
    $self->logger->warn("XXX: $target=$value changed; need to invalidate several windows");

    return ();
}

sub authorize {
    my ($self) = @_;

    my $user = $self->author;
    my $password = $self->password_prompt()->($self)
      or $self->logger->logdie("No password given");

    my ($status, $failed, $detail) =
      Bio::Otter::Auth::SSO->login($self->get_UserAgent, $user, $password);

    if (!$failed) {
        # Cookie will have been given to UserAgent
        $self->logger->info(sprintf("Authenticated as %s: %s\n", $self->author, $status));
        $self->save_CookieJar;
        return 1;
    } else {
        $self->logger->warn(sprintf("Authentication as %s failed: %s (((%s)))\n", $self->author, $status, $detail));
        $self->password_problem()->($self, $failed);
        return 0;
    }
}

# ---- HTTP protocol related routines:

sub get_UserAgent {
    my ($self) = @_;

    return $self->{'_lwp_useragent'} ||= $self->create_UserAgent;
}

sub create_UserAgent {
    my ($self) = @_;

    my $ua = LWP::UserAgent->new(timeout => 9000);
    $ua->env_proxy;
    $ua->protocols_allowed([qw{ http https }]);
    $ua->agent('otterlace/50.0 ');
    push @{ $ua->requests_redirectable }, 'POST';
    $ua->cookie_jar($self->get_CookieJar);

    my $json_impl = JSON->backend;
    $self->client_logger->warn("Slow JSON decoder '$json_impl' in use?")
      unless $json_impl->is_xs;

    return $ua;
}

# Call it early, but after loggers are ready
sub env_config {
    my ($self) = @_;
    $self->ua_tell_hostinfo;
    $self->setup_pfetch_env;
    return;
}

sub ua_tell_hostinfo {
    my ($self) = @_;
    my $ua = $self->get_UserAgent;
    my %info;
    @info{qw{ http https }} = map { defined $_ ? $_ : 'none' }
      $ua->proxy([qw[ http https ]]);
    if ($info{http} eq $info{https}) {
        $info{'http[s]'} = delete $info{http};
        delete $info{https};
    }
    my @nopr = @{ $ua->{no_proxy} }; # there is no get accessor
    $info{no_proxy} = join ',', uniq(@nopr) if @nopr;
    $info{set_in_ENV} = join ',',
      map { m{^(.).*_(.).*$} ? "$1$2" : $_ }
        grep { defined $ENV{$_} }
          map {( $_, uc($_) )}
            qw( http_proxy https_proxy no_proxy );

    $self->client_logger->info('Hostname: ', hostfqdn());
    $self->client_logger->info('Proxy:', map {" $_=$info{$_}"} sort keys %info);
    return;
}

sub get_CookieJar {
    my ($self) = @_;
    return $self->{'_cookie_jar'} ||= $self->create_CookieJar;
}

sub create_CookieJar {
    my ($self) = @_;

    my $jar = $self->{'_cookie_jar_file'};
    return HTTP::Cookies::Netscape->new(file => $jar);
}

sub save_CookieJar {
    my ($self) = @_;

    my $jar = $self->{'_cookie_jar_file'};
    if (-e $jar) {
        # Fix mode if not already mode 600
        my $mode = (stat(_))[2];
        my $mode_required = oct(600);
        if ($mode != $mode_required) {
            chmod($mode_required, $jar)
                or $self->logger->logconfess(sprintf "chmod(0%o, '$jar') failed; $!", $mode_required);
        }
    } else {
        # Create file with mode 600
        my $save_mask = umask;
        umask(066);
        open my $fh, '>', $jar
            or $self->logger->logconfess("Can't create '$jar'; $!");
        close $fh
            or $self->logger->logconfess("Can't close '$jar'; $!");
        umask($save_mask);
    }

    $self->get_CookieJar->save
        or $self->logger->logconfess("Failed to save cookie");

    return;
}

sub cookie_expiry_time {
    my ($self) = @_;

    my $jar = $self->get_CookieJar;
    my $expiry_time = 0;
    $jar->scan(sub{
        my ($key, $expiry) = @_[1,8];

        if ($key eq 'WTSISignOn') { # nb. Bio::Otter::Auth::SSO
            $expiry_time = $expiry;
        }
        return;
    });

    # $self->logger->debug("Cookie expiry time is ", scalar localtime($expiry_time));

    return $expiry_time;
}

sub url_root {
    my ($self) = @_;
    return $self->{'url_root'} ||=
        $self->_url_root;
}

sub _url_root {
    my ($self) = @_;

    my $feat = Bio::Otter::Git->param('feature');
    my $url = sprintf '%s/%s%s'
        , $self->config_value('url')
        , Bio::Otter::Version->version
        , ($feat ? "_$feat" : '')
        ;

    return $url;
}

sub url_root_is_default {
    my ($self) = @_;

    my $default = Bio::Otter::Lace::Defaults::default_config_value
      (qw( client url ));
    my $cfgd = $self->config_value('url');
    my $feat = Bio::Otter::Git->param('feature');

    return $cfgd eq $default && !$feat;
}

sub pfetch_url {
    my ($self) = @_;

    return $self->url_root . '/pfetch';
}

sub setup_pfetch_env {
    my ($self) = @_;

    # Need to use pfetch via HTTP proxy if we are outside Sanger
    my $hostname = hostfqdn();
    my $old_PW = defined $ENV{'PFETCH_WWW'} ? "'$ENV{'PFETCH_WWW'}'" : "undef";
    if ($hostname =~ /\.sanger\.ac\.uk$/) {
        delete($ENV{'PFETCH_WWW'});
    } else {
        $ENV{'PFETCH_WWW'} = $self->pfetch_url;
    }

    # Belvu's fetch is manually switched (as of 4.26-62-g75547)
    $ENV{'BELVU_FETCH_WWW'} = $self->pfetch_url.'?request=%s'; # RT#405174

    # Report the result to log.  RT#379752
    # Hardwired blixem config can affect some pfetches.
    my $new_PW = defined $ENV{'PFETCH_WWW'} ? "'$ENV{'PFETCH_WWW'}'" : "undef";
    my $blix_cfg = __user_home()."/.blixemrc";
    my $blix_cfg_exist = -f $blix_cfg ? "exists" : "not present";
    $self->client_logger->info("setup_pfetch_env: PFETCH_WWW was $old_PW, now $new_PW; $blix_cfg $blix_cfg_exist");

    return;
}

# Returns the content string from the http response object
# with the <otter> tags or JSON encoding removed.
# "perlcritic --stern" refuses to learn that $logger->logconfess is fatal
sub otter_response_content { ## no critic (Subroutines::RequireFinalReturn)
    my ($self, $method, $scriptname, $params) = @_;

    my $response = $self->general_http_dialog($method, $scriptname, $params);

    return $self->_json_content($response)
      if $response->content_type =~ m{^application/json($|;)}; # charset ignored

    my $xml = $response->decoded_content();

    if (my ($content) = $xml =~ m{<otter[^\>]*\>\s*(.*)</otter>}s) {
        my $cl = $self->client_logger;
        $cl->debug($self->response_info($scriptname, $params, length($content).' (unwrapped)')) if $cl->is_debug;
        return $content;
    } else {
        $self->logger->logconfess("No <otter> tags in response content: [$xml]");
    }
}

sub _json_content {
    my ($self, $response) = @_;
    return JSON->new->decode($response->decoded_content);
}

# Returns the full content string from the http response object
sub http_response_content {
    my ($self, $method, $scriptname, $params) = @_;

    my $response = $self->general_http_dialog($method, $scriptname, $params);

    my $txt = $response->decoded_content();
    # $self->logger->debug($txt);

    my $cl = $self->client_logger;
    $cl->debug($self->response_info($scriptname, $params, length($txt))) if $cl->is_debug;
    return $txt;
}

sub response_info {
    my ($self, $scriptname, $params, $length) = @_;

    my $ana = $params->{'analysis'}
      ? ":$params->{analysis}"
      : '';
    return "$scriptname$ana - client received $length bytes from server\n";
}

sub general_http_dialog {
    my ($self, $method, $scriptname, $params) = @_;

    $params->{'log'} = 1 if $self->debug_server;
    $params->{'client'} = $self->client_name;
    my $clogger = $self->client_logger;

    my $password_attempts = $self->password_attempts;
    my ($response, $content);

    REQUEST: while (1) {
        $response = $self->do_http_request($method, $scriptname, $params);
        $content = $response->decoded_content;
        if ($response->is_success) {
            last REQUEST;
        }
        my $code = $response->code;
        if ($code == 401 || $code == 403) {
            # 401 = unauthorized
            # 403 = forbidden
            # we should see 401 but the server still incorrectly returns 403
            while ($password_attempts) {
                $password_attempts--;
                # Try the request again if we manage to authorize
                if ($self->authorize) {
                    next REQUEST;
                }
            }
            $clogger->logdie("Authorization failed");
        } elsif ($code == 410) {
            # 410 = Gone.  Not coming back; probably concise.  RT#234724
            # Actually, maybe not so concise.  RT#382740 returns "410 Gone" plus large HTML.
            $clogger->warn(__truncdent_for_log($content, 10240, '* '));
            $clogger->logdie(sprintf("Otter Server v%s is gone, please download an up-to-date Otterlace.",
                                     Bio::Otter::Version->version));
        } else {
            # Some error.  Content-length: protection is not yet applied,
            # just hope the error is informative.
            my $json_error = try {
                ($response->content_type =~ m{^application/json($|;)}) &&
                  JSON->new->decode($content); # charset ignored
            };
            if ($json_error && defined(my $error = $json_error->{error})) {
                # clear JSON-encoded error
                $clogger->info($content) if keys %$json_error > 1;
                $clogger->logdie("Server returned error $code: $error");
            } else {
                $clogger->info(join "\n", $response->status_line, $response->headers_as_string,
                               __truncdent_for_log($content, 10240));

                my $err;
                if ($content =~ m{<title>500 Internal Server Error</title>.*The server encountered an internal error or\s+misconfiguration and was unable to complete\s+your request}s) {
                    # standard Apache, uninformative
                    $err = 'details are in server error_log';
                } elsif ($content =~m{\A<\?xml.*\?>\n\s*<otter>\s*<response>\s*ERROR: (.*?)\s+</response>\s*</otter>\s*\z}s) {
                    # otter_wrap_response error
                    $err = $1;
                    $err =~ s{[.\n]*\z}{,}; # "... at /www/.../foo line 30,"
                } else {
                    # else some raw and probably large failure, hide it
                    $err = 'error text not recognised, details in Otterlace log';
                }
                $clogger->logdie(sprintf "Error %d: %s", $response->code, $err);
            }
        }
    }

    if ($content =~ /The Sanger Institute Web service you requested is temporarily unavailable/) {
        $clogger->logdie("Problem with the web server");
    }

    # for RT#401537 HTTP response truncation
    $clogger->debug(join "\n", $response->status_line, $response->headers_as_string)
      if $clogger->is_debug;

    # Check (possibly gzipped) lengths.  LWP truncates any excess
    # bytes, but does nothing if there are too few.
    my $got_len = length(${ $response->content_ref });
    my $exp_len = $response->content_length; # from headers
    $clogger->logdie
      ("Content length mismatch (before content-decode, if any).\n  Got $got_len bytes, headers promised $exp_len")
      if defined $exp_len # it was not provided, until recently
        && $exp_len != $got_len;

    return $response;
}

sub __truncdent_for_log {
    my ($txt, $maxlen, $dent) = @_;
    my $len = length($txt);
    substr($txt, $maxlen, $len, "[...truncated from $len bytes]\n") if $len > $maxlen;
    $txt =~ s/^/$dent/mg if defined $dent;
    $txt =~ s/\n*\z/\n/;
    return $txt;
}


sub escaped_param_string {
    my ($self, $params) = @_;

    return join '&', map { $_ . '=' . uri_escape($params->{$_}) } (keys %$params);
}

sub do_http_request {
    my ($self, $method, $scriptname, $params) = @_;

    my $url = $self->url_root.'/'.$scriptname;
    my $paramstring = $self->escaped_param_string($params);

    my $request = HTTP::Request->new;
    $request->method($method);

    if ($method eq 'GET') {
        my $get = $url . ($paramstring ? "?$paramstring" : '');
        $request->uri($get);

        $self->client_logger->debug("GET  $get");
    }
    elsif ($method eq 'POST') {
        $request->uri($url);
        $request->content($paramstring);

        $self->client_logger->debug("POST  $url");
        # $self->client_logger->debug("paramstring: $paramstring");
    }
    else {
        $self->logger->logconfess("method '$method' is not supported");
    }

    return $self->get_UserAgent->request($request);
}

# ---- specific HTTP-requests:

sub status_refresh_for_DataSet_SequenceSet{
    my ($self, $ds, $ss) = @_;

    my $response =
        $self->_DataSet_SequenceSet_response_content(
            $ds, $ss, 'GET', 'get_analyses_status');

    my %status_hash = ();
    for my $line (split(/\n/,$response)) {
        my ($c, $a, @rest) = split(/\t/, $line);
        $status_hash{$c}{$a} = \@rest;
    }

    # create a dummy hash with names only:
    my $names_subhash = {};
    if(my ($any_subhash) = (values %status_hash)[0] ) {
        while(my ($ana_name, $values) = each %$any_subhash) {
            $names_subhash->{$ana_name} = [];
        }
    }

    foreach my $cs (@{$ss->CloneSequence_list}) {
        $cs->drop_pipelineStatus;

        my $status = Bio::Otter::Lace::PipelineStatus->new;
        my $contig_name = $cs->contig_name();

        my $status_subhash = $status_hash{$contig_name} || $names_subhash;

        if($status_subhash == $names_subhash) {
            $self->logger->warn("had to assign an empty subhash to contig '$contig_name'");
        }

        while(my ($ana_name, $values) = each %$status_subhash) {
            $status->add_analysis($ana_name, $values);
        }

        $cs->pipelineStatus($status);
    }

    return;
}

sub find_clones {
    my ($self, $dsname, $qnames_list) = @_;

    my $qnames_string = join(',', @$qnames_list);

    my $response = $self->http_response_content(
        'GET',
        'find_clones',
        {
            'dataset'  => $dsname,
            'qnames'   => $qnames_string,
        },
    );

    my $result_list = [ map { _find_clone_result($_); } split /\n/, $response ];

    return $result_list;
}

sub _find_clone_result {
    my ($line) = @_;
    my ($qname, $qtype, $component_names, $assembly) = split /\t/, $line;
    if ($qname eq '') {
        return { text => $line };
    } else {
        my $components = $component_names ? [ split /,/, $component_names ] : [];
        return {
                qname      => $qname,
                qtype      => $qtype,
                components => $components,
                assembly   => $assembly,
               };
    }
}

sub get_meta {
    my ($self, $dsname) = @_;

    my $response = $self->otter_response_content(
        'GET',
        'get_meta',
        {
            'dataset'  => $dsname,
        },
    );

    return $self->_build_meta_hash($response);
}

# Factored out for use in OtterTest::Client
#
sub _build_meta_hash {
    my ($self, $response) = @_;

    my $meta_hash = {};
    for my $line (split(/\n/,$response)) {
        my($meta_key, $meta_value, $species_id) = split(/\t/,$line);
        $species_id = undef if $species_id eq '';
        $meta_hash->{$meta_key}->{species_id} = $species_id;
        push @{$meta_hash->{$meta_key}->{values}}, $meta_value; # as there can be multiple values for one key
    }
    return $meta_hash;
}

sub get_db_info {
    my ($self, $dsname) = @_;

    my $response = $self->otter_response_content(
        'GET',
        'get_db_info',
        {
            'dataset'  => $dsname,
        },
    );

    return $self->_build_db_info_hash($response);
}

# Factored out for use in OtterTest::Client
#
sub _build_db_info_hash {
    my ($self, $response) = @_;

    my $db_info_hash = {};
    for my $line (split(/\n/,$response)) {
        my($key, @values) = split(/\t/,$line);
        $db_info_hash->{$key} = [ @values ];
    }

    return $db_info_hash;
}

sub lock_refresh_for_DataSet_SequenceSet {
    my ($self, $ds, $ss) = @_;

   my $response =
       $self->_DataSet_SequenceSet_response_content(
           $ds, $ss, 'GET', 'get_locks');

    my %lock_hash = ();
    my %author_hash = ();

    foreach my $clone_lock (@{ $response->{CloneLock} || [] }) {
        my ($ctg_name, $hostname, $timestamp, $aut_name, $aut_email)
          = @{$clone_lock}{qw{ ctg_name hostname timestamp author_name author_email }};

        $author_hash{$aut_name} ||= Bio::Vega::Author->new(
            -name  => $aut_name,
            -email => $aut_email,
        );

        $lock_hash{$ctg_name} ||= Bio::Vega::ContigLock->new(
            -author    => $author_hash{$aut_name},
            -hostname  => $hostname,
            -timestamp => $timestamp,
        );
    }

    foreach my $cs (@{$ss->CloneSequence_list()}) {
        if (my $lock = $lock_hash{$cs->contig_name}) {
            $cs->set_lock_status($lock);
        } else {
            $cs->set_lock_status(undef);
        }
    }

    return;
}

sub fetch_all_SequenceNotes_for_DataSet_SequenceSet {
    my ($self, $ds, $ss) = @_;

    $ss ||= $ds->selected_SequenceSet
        || $self->logger->logdie("no selected_SequenceSet attached to DataSet");

    my $response =
        $self->_DataSet_SequenceSet_response_content(
            $ds, $ss, 'GET', 'get_sequence_notes');

    my %ctgname2notes = ();

        # we allow the notes to come in any order, so simply fill the hash:

    for my $line (split(/\n/,$response)) {
        my ($ctg_name, $aut_name, $is_current, $datetime, $timestamp, $note_text)
            = split(/\t/, $line, 6);

        my $new_note = Bio::Otter::Lace::SequenceNote->new;
        $new_note->text($note_text);
        $new_note->timestamp($timestamp);
        $new_note->is_current($is_current eq 'Y' ? 1 : 0);
        $new_note->author($aut_name);

        my $note_listp = $ctgname2notes{$ctg_name} ||= [];
        push(@$note_listp, $new_note);
    }

        # now, once everything has been loaded, let's fill in the structures:

    foreach my $cs (@{$ss->CloneSequence_list()}) {
        my $hashkey = $cs->contig_name();

        $cs->truncate_SequenceNotes();
        if (my $notes = $ctgname2notes{$hashkey}) {
            foreach my $note (sort {$a->timestamp <=> $b->timestamp} @$notes) {
                # logic in current_SequenceNote doesn't work
                # unless sorting is done first

                $cs->add_SequenceNote($note);
                if ($note->is_current) {
                    $cs->current_SequenceNote($note);
                }
            }
        }
    }

    return;
}

sub change_sequence_note {
    my ($self, @args) = @_;

    $self->_sequence_note_action('change', @args);

    return;
}

sub push_sequence_note {
    my ($self, @args) = @_;

    $self->_sequence_note_action('push', @args);

    return;
}

sub _sequence_note_action {
    my ($self, $action, $dsname, $contig_name, $seq_note) = @_;

    my $ds = $self->get_DataSet_by_name($dsname);

    my $response = $self->http_response_content(
        'GET',
        'set_sequence_note',
        {
            'dataset'   => $dsname,
            'action'    => $action,
            'contig'    => $contig_name,
            'timestamp' => $seq_note->timestamp(),
            'text'      => $seq_note->text(),
        },
    );

    # I guess we simply have to ignore the response
    return;
}

sub get_all_DataSets {
    my ($self) = @_;

    my $ds = $self->{'_datasets'};
    if (! $ds) {

        my $datasets_xml =
            $self->http_response_content(
                'GET', 'get_datasets', {});

        local $XML::Simple::PREFERRED_PARSER = 'XML::Parser';
        # configure expat for speed, also used in Bio::Vega::Transform

        my $datasets_hash =
            XMLin($datasets_xml,
                  ForceArray => [ qw(
                      dataset
                      ) ],
                  KeyAttr => {
                      dataset => 'name',
                  },
            )->{datasets}{dataset};

        my @datasets = map {
            $self->_make_DataSet($_, $datasets_hash->{$_});
        } keys %{$datasets_hash};

        $ds = $self->{'_datasets'} =
            [ sort {$a->name cmp $b->name} @datasets ];
    }

    return @$ds;
}

sub _make_DataSet {
    my ($self, $name, $params) = @_;

    my $dataset = Bio::Otter::Lace::DataSet->new;
    $dataset->name($name);
    while (my ($key, $value) = each %{$params}) {
        my $method = uc $key;
        $dataset->$method($value) if $dataset->can($method);
    }
    $dataset->Client($self);

    return $dataset;
}

sub get_server_otter_config {
    my ($self) = @_;

    $self->ensure_authorised;
    my $content = $self->_get_config_file('otter_config');
    Bio::Otter::Lace::Defaults::save_server_otter_config($content);

    return;
}

sub ensure_authorised {
    my ($self) = @_;

    # Is user associated with the cookiejar the one configured?
    # Done here because it's the first action of Otterlace.
    my $who_am_i = $self->do_authentication;
    if ($who_am_i ne $self->author) {
        my $a = $self->author;
        $self->logger->warn("Clearing existing cookie for author='$who_am_i'.  Configuration is for author='$a'");
        $self->get_CookieJar->clear;
        $who_am_i = $self->do_authentication;
    }

    # This shows authentication AND authorization
    $self->logger->info("Authorised as $who_am_i");
    return ();
}


sub _get_config_file {
    my ($self, $key) = @_;
    return $self->http_response_content(
        'GET',
        'get_config',
        { 'key' => $key },
        );
}

sub _get_cache_config_file {
    my ($self, $key) = @_;

    # We cache the whole file in memory
    unless ($self->{$key}) {
        $self->{$key} = $self->_get_config_file($key);
    }
    return $self->{$key};
}

sub get_otter_styles {
    my ($self) = @_;
    return $self->_get_cache_config_file('otter_styles');
}

sub get_otter_schema {
    my ($self) = @_;
    return $self->_get_cache_config_file('otter_schema');
}

sub get_loutre_schema {
    my ($self) = @_;
    return $self->_get_cache_config_file('loutre_schema');
}

sub get_server_ensembl_version {
    my ($self) = @_;
    return $self->_get_cache_config_file('ensembl_version');
}

# same as Bio::Otter::Server::Config->designations (fresh every time)
sub get_designations {
    my ($self) = @_;
    my $hashref = $self->otter_response_content(GET => 'get_config', { key => 'designations' });
    return $hashref;
}

# Return (designation_of_this_major, latest_this_major, live_major_minor)
sub designate_this {
    my ($self) = @_;
    my $desig = $self->get_designations;
    my $major = Bio::Otter::Version->version;
    my $feat = Bio::Otter::Git->param('feature');

    my $major_re = ($feat
                    ? qr{^$major(\.\d+)?_$feat$}
                    : qr{^$major(\.|$)});

    my ($key) =
      # There would have been multiple hits for v75, but now we have
      # feature branches.  Sort just in case.
      sort grep { $desig->{$_} =~ $major_re } keys %$desig;

    my $live = $desig->{live};
    my $exact_key = $key;

    if (!defined $key) {
        my @v = sort values %$desig;
        $self->logger->warn("No match for $major_re against designations.txt values (@v)");
        $exact_key = 'live';
    }

    my $exact = $desig->{$exact_key};
    return ($key, $exact, $live);
}

sub do_authentication {
    my ($self) = @_;

    my $user = $self->http_response_content(
        'GET',
        'authenticate_me',
        {},
    );
    return $user
}

sub get_all_SequenceSets_for_DataSet {
  my ($self, $ds) = @_;
  return [] unless $ds;

  my $dataset_name = $ds->name;

  my $sequencesets_xml =
      $self->http_response_content(
          'GET', 'get_sequencesets', {
              'dataset' => $dataset_name,
          });

  local $XML::Simple::PREFERRED_PARSER = 'XML::Parser';
  # configure expat for speed, also used in Bio::Vega::Transform

  my $sequencesets_hash =
      XMLin($sequencesets_xml,
            ForceArray => [ qw(
                dataset
                sequenceset
                subregion
                ) ],
            KeyAttr => {
                dataset     => 'name',
                sequenceset => 'name',
                subregion   => 'name',
            },
      )->{dataset}{$dataset_name}{sequencesets}{sequenceset};

  my $sequencesets = [
      map {
          $self->_make_SequenceSet(
              $_, $dataset_name, $sequencesets_hash->{$_});
      } keys %{$sequencesets_hash} ];

  return $sequencesets;
}

sub _make_SequenceSet {
    my ($self, $name, $dataset_name, $params) = @_;

    my $sequenceset = Bio::Otter::Lace::SequenceSet->new;
    $sequenceset->name($name);
    $sequenceset->dataset_name($dataset_name);

    while (my ($key, $value) = each %{$params}) {
        if ($key eq 'subregion') {
            while (my ($sr_name, $sr_params) = each %{$value}) {
                next if $sr_params->{hidden};
                $sequenceset->set_subset(
                    $sr_name, [split(/,/, $sr_params->{content})]);
            }
        }
        elsif ($sequenceset->can($key)) {
            $sequenceset->$key($value);
        }
    }

    return $sequenceset;
}

sub get_all_CloneSequences_for_DataSet_SequenceSet {
  my ($self, $ds, $ss) = @_;
  return [] unless $ss ;
  my $csl = $ss->CloneSequence_list;
  return $csl if (defined $csl && scalar @$csl);

  my $dataset_name     = $ds->name;
  my $sequenceset_name = $ss->name;

  my $clonesequences_xml = $self->http_response_content(
        'GET',
        'get_clonesequences',
        {
            'dataset'     => $dataset_name,
            'sequenceset' => $sequenceset_name,
        }
    );

  local $XML::Simple::PREFERRED_PARSER = 'XML::Parser';
  # configure expat for speed, also used in Bio::Vega::Transform

  my $clonesequences_array =
      XMLin($clonesequences_xml,
            ForceArray => [ qw(
                dataset
                sequenceset
                clonesequence
                ) ],
            KeyAttr => {
                dataset       => 'name',
                sequenceset   => 'name',
            },
      )->{dataset}{$dataset_name}{sequenceset}{$sequenceset_name}{clonesequences}{clonesequence};

  my $clonesequences = [
      map {
          $self->_make_CloneSequence(
              $dataset_name, $sequenceset_name, $_);
      } @{$clonesequences_array} ];
  $ss->CloneSequence_list($clonesequences);

  return $clonesequences;
}

sub _make_CloneSequence {
    my ($self, $dataset_name, $sequenceset_name, $params) = @_;

    my $clonesequence = Bio::Otter::Lace::CloneSequence->new;

    while (my ($key, $value) = each %{$params}) {
        if ($key eq 'chr') {
            $clonesequence->chromosome($value->{name});
        }
        elsif ($key eq 'lock') {

            my ($author_name, $author_email, $host_name, $lock_id) =
                @{$value}{qw( author_name email host_name lock_id )};

            my $author = Bio::Vega::Author->new(
                -name  => $author_name,
                -email => $author_email,
                );

            my $clone_lock = Bio::Vega::ContigLock->new(
                -author   => $author,
                -hostname => $host_name,
                -dbID     => $lock_id,
                );

            $clonesequence->set_lock_status($clone_lock);
        }
        elsif ($clonesequence->can($key)) {
            $clonesequence->$key($value);
        }
    }

    return $clonesequence;
}

sub get_lace_acedb_tar {
    my ($self) = @_;
    return $self->_get_cache_config_file('lace_acedb_tar');
}

sub get_methods_ace {
    my ($self) = @_;
    return $self->_get_cache_config_file('methods_ace');
}

sub get_accession_types {
    my ($self, @accessions) = @_;

    my $response = $self->http_response_content(
        'POST',
        'get_accession_types',
        {accessions => join ',', @accessions},
        );

    return unless $response;

    my %results;
    foreach my $line (split /\n/, $response) {
        my @row = split /\t/, $line;
        my %entry;
        @entry{accession_info_column_order()} = @row;
        my $name = $entry{name};
        $self->logger->warn("Duplicate result for '$name'") if $results{$name};
        $results{$name} = \%entry;
    }

    return \%results;
}

sub get_taxonomy_info {
    my ($self, @ids) = @_;

    my $response = $self->http_response_content(
        'POST',
        'get_taxonomy_info',
        {id => join ',', @ids},
        );
    return $response;
}

sub save_otter_xml {
    my ($self, $xml, $dsname) = @_;

    $self->logger->logconfess("Don't have write access") unless $self->write_access;

    my $content = $self->http_response_content(
        'POST',
        'write_region',
        {
            'dataset'  => $dsname,
            'data'     => $xml,
        }
    );

    return $content;
}

sub unlock_otter_xml {
    my ($self, $xml, $dsname) = @_;

    $self->general_http_dialog(
        'POST',
        'unlock_region',
        {
            'dataset'  => $dsname,
            'data'     => $xml,
        }
    );
    return 1;
}

sub _DataSet_SequenceSet_response_content {
    my ($self, $ds, $ss, $method, $script) = @_;

    my $query = {
        'dataset'  => $ds->name,
        'chr'      => $ss->name,
    };

    my $content =
        $self->otter_response_content($method, $script, $query);

    return $content;
}

# configuration

sub config_value {
    my ($self, $key) = @_;

    return $self->config_section_value(client => $key);
}

sub config_section_value {
    my ($self, $section, $key) = @_;
    return Bio::Otter::Lace::Defaults::config_value($section, $key);
}

sub config_value_list {
    my ($self, @keys) = @_;
    return Bio::Otter::Lace::Defaults::config_value_list(@keys);
}

sub config_value_list_merged {
    my ($self, @keys) = @_;
    return Bio::Otter::Lace::Defaults::config_value_list_merged(@keys);
}

sub config_section {
    my ($self, @keys) = @_;
    return Bio::Otter::Lace::Defaults::config_section(@keys);
}

sub config_keys {
    my ($self, @keys) = @_;
    return Bio::Otter::Lace::Defaults::config_keys(@keys);
}

############## Session recovery methods ###################################

sub sessions_needing_recovery {
    my ($self) = @_;

    my $proc_table = Proc::ProcessTable->new;
    my @otterlace_procs =
      grep { defined $_->cmndline && $_->cmndline =~ /otterlace/ }
        @{$proc_table->table};
    my %existing_pid = map {$_->pid, 1} @otterlace_procs;

    my $to_recover = [];

    foreach ( $self->all_sessions ) {
        my ( $lace_dir, $pid, $mtime ) = @{$_};
        next if $existing_pid{$pid};

        my $ace_wrm = "$lace_dir/database/ACEDB.wrm";
        if (-e $ace_wrm) {
            if (my $name = $self->get_name($lace_dir)) {
                push(@$to_recover, [$lace_dir, $mtime, $name]);
            }
            else {
                my $done = $self->move_to_done($lace_dir);
                $self->logger->logdie("Session with uninitialised or corrupted SQLite DB renamed to '$done'");
            }
        } else {
            try {
                # Attempt to release locks of uninitialised sessions
                my $adb = $self->recover_session($lace_dir);
                $adb->error_flag(0);    # It is uninitialised, so we want it to be removed
                $lace_dir = $adb->home;
                if ($adb->write_access) {
                    $adb->unlock_otter_slice;
                    $self->logger->warn("Removed lock from uninitialised database in '$lace_dir'");
                }
            }
            catch { $self->logger->error("error while recoving session '$lace_dir': $_"); };
            if (-d $lace_dir) {
                # Belt and braces - if the session was unrecoverable we want it to be deleted.
                my $done = $self->move_to_done($lace_dir);
                $self->logger->logdie("No such file: '$lace_dir/database/ACEDB.wrm'\nDatabase moved to '$done'");
            }
        }
    }

    # Sort by modification date, ascending
    $to_recover = [sort {$a->[1] <=> $b->[1]} @$to_recover];

    return $to_recover;
}

sub move_to_done {
    my ($self, $lace_dir) = @_;

    my $done = "$lace_dir.done";
    rename($lace_dir, $done) or $self->logger->logdie("Error renaming '$lace_dir' to '$done'; $!");
    return $done;
}

sub get_name {
    my ($self, $home_dir) = @_;

    my $db = Bio::Otter::Lace::DB->new($home_dir, $self);
    return $db->get_tag_value('name');
}

sub recover_session {
    my ($self, $dir) = @_;

    $self->kill_old_sgifaceserver($dir);

    my $adb = $self->new_AceDatabase;
    $adb->error_flag(1);
    my $home = $adb->home;
    rename($dir, $home) or $self->logger->logdie("Cannot move '$dir' to '$home'; $!");

    unless ($adb->db_initialized) {
        try { $adb->recover_slice_from_region_xml; }
        catch { $self->logger->warn($_); };
        return $adb;
    }

    # All the info we need about the genomic region
    # in the lace database is saved in the region XML
    # dot file.
    $adb->recover_slice_from_region_xml;
    $adb->DataSet->load_client_config;
    $adb->reload_filter_state;

    return $adb;
}

sub kill_old_sgifaceserver {
    my ($self, $dir) = @_;

    # Kill any sgifaceservers from crashed otterlace
    my $proc_list = Proc::ProcessTable->new;
    foreach my $proc (@{$proc_list->table}) {
        next unless defined $proc->cmndline;
        my ($cmnd, @args) = split /\s+/, $proc->cmndline;
        next unless $cmnd eq 'sgifaceserver';
        next unless $args[0] eq $dir;
        $self->logger->info(sprintf "Killing old sgifaceserver '%s', pid %s", $proc->cmndline, $proc->pid);
        kill 9, $proc->pid;
    }

    return;
}

############## Session recovery methods end here ############################

sub logger {
    return Log::Log4perl->get_logger;
}

# This is under the control of $self->debug_client() and should match the corresponding
# log4perl.logger.client in Bio::Otter::LogFile::make_log().
#
sub client_logger {
    return Log::Log4perl->get_logger('otter.client');
}

1;

__END__

=head1 NAME - Bio::Otter::Lace::Client

=head1 DESCRIPTION

A B<Client> object Communicates with an otter
HTTP server on a particular url.  It
has methods to fetch annotated gene information
in otter XML, lock and unlock clones, and save
"ace" formatted annotation back.  It also returns
lists of B<DataSet> objects provided by the
server.


=head1 CLASS METHODS

=head2 the()

Return a singleton instance, instantiating it if necessary.

Objects which are tied (by an instance variable / property) to a
particular client instance should avoid using this.

=head2 new()

An ordinary constructor, making instances as requested.


=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

