### Bio::Otter::Lace::Client

package Bio::Otter::Lace::Client;

use strict;
use warnings;
use Carp;

use File::Path qw{ remove_tree };
use Net::Domain qw{ hostname hostfqdn };
use Proc::ProcessTable;

use LWP;
use URI::Escape qw{ uri_escape };
use HTTP::Cookies::Netscape;
use Term::ReadKey qw{ ReadMode ReadLine };

use XML::Simple;

use Bio::Vega::Author;
use Bio::Vega::ContigLock;

use Bio::Otter::Lace::Defaults;
use Bio::Otter::Lace::DataSet;
use Bio::Otter::Lace::SequenceSet;
use Bio::Otter::Lace::CloneSequence;
use Bio::Otter::Lace::PipelineStatus;
use Bio::Otter::Lace::SequenceNote;
use Bio::Otter::Lace::AceDatabase;
use Bio::Otter::Lace::DB;
use Bio::Otter::LogFile;

sub new {
    my ($pkg) = @_;

    my ($script) = $0 =~ m{([^/]+)$};
    my $client_name = $script || 'otterlace';

    ## no critic(Variables::RequireLocalizedPunctuationVars)

    $ENV{'OTTERLACE_COOKIE_JAR'} ||= "$ENV{HOME}/.otter/ns_cookie_jar";

    my $new = bless {
        _client_name     => $client_name,
        _cookie_jar_file => $ENV{'OTTERLACE_COOKIE_JAR'},
    }, $pkg;

    $new->setup_pfetch_env;

    return $new;
}

sub host {
    my ($self, $host) = @_;

    warn "Set using the Config file please.\n" if $host;

    return $self->config_value('host');
}

sub port {
    my ($self, $port) = @_;

    warn "Set using the Config file please.\n" if $port;

    return $self->config_value('port');
}

sub version {
    my ($self, $version) = @_;

    warn "Set using the Config file please.\n" if $version;

    return $self->config_value('version');
}

sub write_access {
    my ($self, $write_access) = @_;

    warn "Set using the Config file please.\n" if $write_access;

    return $self->config_value('write_access') || 0;
}

sub author {
    my ($self, $author) = @_;

    warn "Set using the Config file please.\n" if $author;

    return $self->config_value('author') || (getpwuid($<))[0];
}

sub email {
    my ($self, $email) = @_;

    warn "Set using the Config file please.\n" if $email;

    return $self->config_value('email') || (getpwuid($<))[0];
}

sub client_name {
    my ($self) = @_;
    return $self->{'_client_name'};
}

sub debug {
    my ($self, $debug) = @_;

    warn "Set using the Config file please.\n" if $debug;

    my $val = $self->config_value('debug');
    return $val ? $val : 0;
}

sub password_attempts {
    my ($self, $password_attempts) = @_;

    if (defined $password_attempts) {
        $self->{'_password_attempts'} = $password_attempts;
    }
    return $self->{'_password_attempts'} || 3;
}

sub config_path_default_rel_home {
    my ($self, $key) = @_;

    my $path = $self->config_value($key) or return;

    # Make $path into absolute file path
    # It is assumed to be relative to the home directory if not
    # already absolute or beginning with "~/".
    my $home = (getpwuid($<))[7];
    $path =~ s{^~/}{$home/};
    unless ($path =~ m{^/}) {
        $path = "$home/$path";
    }

    return $path;
}


sub get_log_dir {
    my ($self) = @_;
    my $home = (getpwuid($<))[7];
    my $log_dir = "$home/.otter";
    if (mkdir($log_dir)) {
        warn "Made logging directory '$log_dir'\n"; # logging not set up, so this must use 'warn'
    }
    return $log_dir;
}

sub get_log_config_file {
    my ($self) = @_;

    my $config_file = $self->config_path_default_rel_home('log_config') or return;

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
        if($self->debug()) {
            warn "Logging output to '$log_file'\n";
        }
    }
    Bio::Otter::LogFile::make_log($log_file, $log_level, $config_file);
    return;
}

sub cleanup_log_dir {
    my ($self, $file_root, $days) = @_;

    # Files older than this number of days are deleted.
    $days ||= 14;

    $file_root ||= 'client';

    my $log_dir = $self->get_log_dir or return;

    opendir my $LOG, $log_dir or confess "Can't open directory '$log_dir': $!";
    foreach my $file (grep { /^$file_root\./ } readdir $LOG) {
        my $full = "$log_dir/$file"; #" comment solely for eclipses buggy parsing!
        if (-M $full > $days) {
            unlink $full
                or warn "Couldn't delete file '$full' : $!";
        }
    }
    closedir $LOG or confess "Error reading directory '$log_dir' : $!";
    return;
}

my $session_root = '/var/tmp/lace';
my $session_number = 0;
my $session_dir_expire_days = 14;

sub cleanup_sessions {
    my ($self) = @_;

    foreach ( $self->all_session_dirs ) {
        next unless /\.done$/;
        if ( -M > $session_dir_expire_days ) {
            remove_tree($_)
                or warn "Error removing expired session directory '$_'";
        }
    }

    return;
}

sub session_path {
    my ($self) = @_;

    $session_number++;

    my $user = (getpwuid($<))[0];

    return
        sprintf "%s_%d.%s.%d.%d",
        $session_root, $self->version, $user, $$, $session_number;
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

    # Skip if directory is not ours
    my ($owner, $mtime) = (stat($dir))[4,9];
    return unless $< == $owner;

    return [ $dir, $pid, $mtime ];
}

sub all_session_dirs {
    my ($self) = @_;

    my $session_dir_pattern =
        sprintf "%s_%s.*", $session_root, $self->version;
    my @session_dirs = glob($session_dir_pattern);
    return @session_dirs;
}

sub new_AceDatabase {
    my ($self) = @_;

    my $adb = Bio::Otter::Lace::AceDatabase->new;
    $adb->Client($self);
    $adb->home($self->session_path);

    return $adb;
}

sub lock {
    my ($self, @args) = @_;

    confess "lock takes no arguments" if @args;

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

sub get_DataSet_by_name {
    my ($self, $name) = @_;

    foreach my $ds ($self->get_all_DataSets) {
        if ($ds->name eq $name) {
            return $ds;
        }
    }
    confess "No such DataSet '$name'";
}

sub password_prompt{
    my ($self, $callback) = @_;

    if ($callback) {
        $self->{'_password_prompt_callback'} = $callback;
    }
    $callback = $self->{'_password_prompt_callback'} ||=
        sub {
            my ($self) = @_;

            unless (-t STDIN) { ## no critic(InputOutput::ProhibitInteractiveTest)
                warn "Cannot prompt for password - not attached to terminal\n";
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
          $message =~ s{\n*\z}{\n};
          warn $message;
      };
    return $callback;
}

sub reauthorize_if_cookie_will_expire_soon {
    my ($self) = @_;

    # Soon is if cookie expires less than half an hour from now
    my $soon = time + (30 * 60);
    if ($self->cookie_expiry_time < $soon) {
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

sub authorize {
    my ($self) = @_;

    my $user = $self->author;
    my $password = $self->password_prompt()->($self)
      or die "No password given";

    # need to url-encode these
    $user     = uri_escape($user);      # possibly not worth it...
    $password = uri_escape($password);  # definitely worth it!

    my $req = HTTP::Request->new;
    $req->method('POST');
    $req->uri("https://enigma.sanger.ac.uk/LOGIN");
    $req->content_type('application/x-www-form-urlencoded');
    $req->content("credential_0=$user&credential_1=$password&destination=/");

    my $response = $self->request($req);
    if ($response->is_success) {
        # Cookie will have been given to UserAgent
        warn sprintf "Authorized OK: %s\n",
            $response->status_line;
        $self->save_CookieJar;
        return 1;
    } else {
        my $content = $response->decoded_content;
        my $msg = sprintf "Authorize failed: %s (%s)\n",
            $response->status_line, $content;
        if ($content =~ m{<title>Sanger Single Sign-on login}) {
            # Some common special cases
            if ($content =~ m{<P>(Invalid account details\. Please try again)</P>}i) {
                $msg = "Login failed: $1";
            } elsif ($content =~
                     m{The account <b>(.*)</b> has been temporarily locked}) {
                $msg = "Login failed and account $1 is now temporarily locked.";
                $msg .= "\nPlease wait $1 and try again, or contact Anacode for support"
                  if $content =~ m{Please try again in ((\d+ hours?)?,? \d+ minutes?)};
            } # else probably an entire HTML page
        }
        $self->password_problem()->($self, $msg);
        return 0;
    }
}

# ---- HTTP protocol related routines:

sub request {
    my ($self, $req) = @_;
    return $self->get_UserAgent->request($req);
}

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

    return $ua;
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
        if ($mode != 0600) { ## no critic(ValuesAndExpressions::ProhibitLeadingZeros)
            chmod(0600, $jar) or confess "chmod(0600, '$jar') failed; $!";
        }
    } else {
        # Create file with mode 600
        my $save_mask = umask;
        umask(066);
        open my $fh, '>', $jar
            or confess "Can't create '$jar'; $!";
        close $fh
            or confess "Can't close '$jar'; $!";
        umask($save_mask);
    }

    $self->get_CookieJar->save
        or confess "Failed to save cookie";

    return;
}

sub cookie_expiry_time {
    my ($self) = @_;

    my $jar = $self->get_CookieJar;
    my $expiry_time = 0;
    $jar->scan(sub{
        my ($key, $expiry) = @_[1,8];

        if ($key eq 'WTSISignOn') {
            $expiry_time = $expiry;
        }
        return;
    });

    # warn "Cookie expiry time is ", scalar localtime($expiry_time), "\n";

    return $expiry_time;
}

sub url_root {
    my ($self) = @_;

    my $host    = $self->host    or confess "host not set";
    my $port    = $self->port    or confess "port not set";
    my $version = $self->version or confess "version not set";
    $port =~ s/\D//g; # port only wants to be a number! no spaces etc
    return "http://$host:$port/cgi-bin/otter/$version";
}

sub pfetch_url {
    my ($self) = @_;

    return $self->url_root . '/pfetch';
}

sub setup_pfetch_env {
    my ($self) = @_;

    ## no critic(Variables::RequireLocalizedPunctuationVars)

    # Need to use pfetch via HTTP proxy if we are outside Sanger
    my $hostname = hostfqdn();
    if ($hostname =~ /\.sanger\.ac\.uk$/) {
        delete($ENV{'PFETCH_WWW'});
    } else {
        $ENV{'PFETCH_WWW'} = $self->pfetch_url;
    }

    return;
}

# Returns the content string from the http response object
# with the <otter> tags removed.
sub otter_response_content {
    my ($self, $method, $scriptname, $params) = @_;

    my $response = $self->general_http_dialog($method, $scriptname, $params);

    my $xml = $response->content();

    if (my ($content) = $xml =~ m{<otter[^\>]*\>\s*(.*)</otter>}s) {
        if ($self->debug) {
            warn $self->response_info($scriptname, $params, length($content));
        }
        return $content;
    } else {
        confess "No <otter> tags in response content: [$xml]";
    }
}

# Returns the full content string from the http response object
sub http_response_content {
    my ($self, $method, $scriptname, $params) = @_;

    my $response = $self->general_http_dialog($method, $scriptname, $params);

    my $xml = $response->content();
    #warn $xml;

    if ($self->debug) {
        warn $self->response_info($scriptname, $params, length($xml));
    }
    return $xml;
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

    # Set debug to 2 or more to turn on debugging on server side
    $params->{'log'} = 1 if $self->debug > 1;
    $params->{'client'} = $self->client_name;

    my $password_attempts = $self->password_attempts;
    my $response;

    REQUEST: while (1) {
        $response = $self->do_http_request($method, $scriptname, $params);
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
            die "Authorization failed";
        } else {
            print STDERR "\nGot error $code\n";
            print STDERR __truncdent_for_log($response->decoded_content, 10240, '| ');
            die sprintf "%d (%s)", $response->code, $response->decoded_content;
        }
    }

    if ($response->content =~ /The Sanger Institute Web service you requested is temporarily unavailable/) {
        die "Problem with the web server\n";
    }

    return $response;
}

sub __truncdent_for_log {
    my ($txt, $maxlen, $dent) = @_;
    my $len = length($txt);
    substr($txt, $maxlen, $len, "[...truncated from $len bytes]\n") if $len > $maxlen;
    $txt =~ s/^/| /g;
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

        if($self->debug()) {
            warn "GET  $get\n";
        }
    }
    elsif ($method eq 'POST') {
        $request->uri($url);
        $request->content($paramstring);

        if($self->debug()) {
            warn "POST  $url\n";
        }
        #warn "paramstring: $paramstring";
    }
    else {
        confess "method '$method' is not supported";
    }

    return $self->request($request);
}

# ---- specific HTTP-requests:

sub status_refresh_for_DataSet_SequenceSet{
    my ($self, $ds, $ss) = @_;

    # return unless Bio::Otter::Lace::Defaults::fetch_pipeline_switch();

    my $response = $self->otter_response_content(
        'GET',
        'get_analyses_status',
        {
            'dataset'  => $ds->name(),
            'type'     => $ss->name(),
        },
    );

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
            warn "had to assign an empty subhash to contig '$contig_name'";
        }

        while(my ($ana_name, $values) = each %$status_subhash) {
            $status->add_analysis($ana_name, $values);
        }

        $cs->pipelineStatus($status);
    }

    return;
}

sub find_string_match_in_clones {
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

    my @results_list = ();

    for my $line (split(/\n/,$response)) {
        my ($qname, $qtype, $component_names, $assembly) = split(/\t/, $line);
        my $components = $component_names ? [ split(/,/, $component_names) ] : [];
        push @results_list, {
            qname      => $qname,
            qtype      => $qtype,
            components => $components,
            assembly   => $assembly,
        };
    }

    return \@results_list;
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

    my $meta_hash = {};
    for my $line (split(/\n/,$response)) {
        my($meta_key, $meta_value) = split(/\t/,$line);
        push @{$meta_hash->{$meta_key}}, $meta_value; # as there can be multiple values for one key
    }

    return $meta_hash;
}

sub lock_refresh_for_DataSet_SequenceSet {
    my ($self, $ds, $ss) = @_;

    my $response = $self->otter_response_content(
        'GET',
        'get_locks',
        {
            'dataset'  => $ds->name(),
            'type'     => $ss->name(),
        },
    );

    my %lock_hash = ();
    my %author_hash = ();

    for my $line (split(/\n/,$response)) {
        my ($intl_name, $embl_name, $ctg_name, $hostname, $timestamp, $aut_name, $aut_email)
            = split(/\t/, $line);

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
        || die "no selected_SequenceSet attached to DataSet";

    my $response = $self->otter_response_content(
        'GET',
        'get_sequence_notes',
        {
            'type'     => $ss->name(),
            'dataset'  => $ds->name(),
        },
    );

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

    my $content = $self->http_response_content(
        'GET',
        'get_otter_config',
        {},
    );

    Bio::Otter::Lace::Defaults::save_server_otter_config($content);

    return;
}

sub get_otter_styles {
    my ($self) = @_;

    # We cache the whole otter_styles file in memory
    unless ($self->{'_otter_styles'}) {
        $self->{'_otter_styles'} = $self->http_response_content('GET', 'get_otter_styles', {});
    }
    return $self->{'_otter_styles'};
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

    # We cache the whole lace_acedb tar.gz file in memory
    unless ($self->{'_lace_acedb_tar'}) {
        $self->{'_lace_acedb_tar'} = $self->http_response_content( 'GET', 'get_lace_acedb_tar', {});
    }
    return $self->{'_lace_acedb_tar'};
}

sub get_methods_ace {
    my ($self) = @_;

    # We cache the whole methods.ace file in memory
    unless ($self->{'_methods_ace'}) {
        $self->{'_methods_ace'} = $self->http_response_content('GET', 'get_methods_ace', {});
    }
    return $self->{'_methods_ace'};
}

sub get_accession_types {
    my ($self, @accessions) = @_;

    my $response = $self->http_response_content(
        'POST',
        'get_accession_types',
        {accessions => join ',', @accessions},
        );
    return $response;
}

sub save_otter_xml {
    my ($self, $xml, $dsname) = @_;

    confess "Don't have write access" unless $self->write_access;

    my $ds = $self->get_DataSet_by_name($dsname);

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

    my $ds = $self->get_DataSet_by_name($dsname);

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

# configuration

sub config_value {
    my ($self, $key) = @_;

    return Bio::Otter::Lace::Defaults::config_value('client', $key);
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
    my @otterlace_procs = grep {$_->cmndline =~ /otterlace/} @{$proc_table->table};
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
                die "Session with uninitialised or corrupted SQLite DB renamed to '$done'";
            }
        } else {
            eval {
                # Attempt to release locks of uninitialised sessions
                my $adb = $self->recover_session($lace_dir);
                $adb->error_flag(0);    # It is uninitialised, so we want it to be removed
                $lace_dir = $adb->home;
                if ($adb->write_access) {
                    $adb->unlock_otter_slice;
                    warn "\nRemoved lock from uninitialised database in '$lace_dir'\n";
                }
                1;
            } or warn "error while recoving session '$lace_dir': $@";
            if (-d $lace_dir) {
                # Belt and braces - if the session was unrecoverable we want it to be deleted.
                my $done = $self->move_to_done($lace_dir);
                die "\nNo such file: '$lace_dir/database/ACEDB.wrm'\nDatabase moved to '$done'\n";
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
    rename($lace_dir, $done) or die "Error renaming '$lace_dir' to '$done'; $!";
    return $done;
}

sub get_name {
    my ($self, $home_dir) = @_;

    my $db = Bio::Otter::Lace::DB->new($home_dir);
    return $db->get_tag_value('name');
}

sub recover_session {
    my ($self, $dir) = @_;

    $self->kill_old_sgifaceserver($dir);

    my $adb = $self->new_AceDatabase;
    $adb->error_flag(1);
    my $home = $adb->home;
    rename($dir, $home) or die "Cannot move '$dir' to '$home'; $!";

    unless ($adb->db_initialized) {
        warn $@ unless eval { $adb->recover_smart_slice_from_region_xml; 1; };
        return $adb;
    }

    # All the info we need about the genomic region
    # in the lace database is saved in the region XML
    # dot file.
    $adb->recover_smart_slice_from_region_xml;
    $adb->DataSet->load_client_config;
    $adb->reload_filter_state;

    return $adb;
}

sub kill_old_sgifaceserver {
    my ($self, $dir) = @_;

    # Kill any sgifaceservers from crashed otterlace
    my $proc_list = Proc::ProcessTable->new;
    foreach my $proc (@{$proc_list->table}) {
        my ($cmnd, @args) = split /\s+/, $proc->cmndline;
        next unless $cmnd eq 'sgifaceserver';
        next unless $args[0] eq $dir;
        warn sprintf "Killing old sgifaceserver '%s'\n", $proc->cmndline;
        kill 9, $proc->pid;
    }

    return;
}

############## Session recovery methods end here ############################

1;

__END__

=head1 NAME - Bio::Otter::Lace::Client

=head1 DESCRIPTION

A B<Client> object Communicates with an otter
HTTP server on a particular host and port.  It
has methods to fetch annotated gene information
in otter XML, lock and unlock clones, and save
"ace" formatted annotation back.  It also returns
lists of B<DataSet> objects provided by the
server.

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

