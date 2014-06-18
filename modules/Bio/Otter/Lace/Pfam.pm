
=head1 NAME - Bio::Otter::Lace::Pfam

=head1 DESCRIPTION

    This module offer functionalities to use the Pfam website to run sequence searches through the RESTful services

=cut

package Bio::Otter::Lace::Pfam;
use strict;
use warnings;
use Try::Tiny;
use Log::Log4perl;
use LWP;
use LWP::UserAgent;
use HTTP::Request;
use XML::LibXML;
use XML::LibXML::XPathContext;
use Bio::Otter::Version;

my $SEARCH_URL = 'http://pfam.xfam.org/search/sequence';
my $HMM_URL    = 'http://pfam.xfam.org/family/hmm';
my $SEED_URL   = 'http://pfam.xfam.org/family/alignment/download/format';

# full path for hmmalign
my $HMMALIGN = 'hmmalign'; # see also Bio::Otter::Utils::About

sub new {
    my ($self, $tmpdir) = @_;
    $self->logger->debug("new($tmpdir)");
    unless (-d $tmpdir) {
        mkdir $tmpdir, 0755
          or die "Cannot mkdir $tmpdir: $!";
    }
    return bless { _tmpdir => $tmpdir }, $self;
}

sub _tmpdir { # under the session directory, so it will be cleared away for us
    my ($self) = @_;
    return $self->{_tmpdir};
}

sub _ua_request {
    my ($self, $description, $req) = @_;
    my $L = $self->logger;
    $L->info($description, " to ", $req->uri);
    my $ua = $self->_user_agent;
    my $res = $ua->request($req);
    $L->info("Response: ", $res->status_line, "; ", $res->content_length, " bytes");

    my $show;
    $show = 'debug' if $L->is_debug;
    $show = 'info'  unless $res->is_success;

    $L->$show(join "\n", "Request was",
              $res->request->as_string) if $show;
    $L->$show(join "\n", "Response was",
              $res->status_line,
              $res->headers_as_string,
              $res->decoded_content) if $show;

    die "$description failed ".$res->status_line unless $res->is_success;

    return $res;
}

sub logger {
    return Log::Log4perl->get_logger('otter.pfam');
}

sub _user_agent { # create and cache a user agent
    my ($self) = @_;
    return $self->{'_user_agent'} ||= do {
        my $ua = LWP::UserAgent->new;
        my $v = Bio::Otter::Version->version;
        $ua->agent("Otterlace/$v ");
        push @{ $ua->requests_redirectable }, 'POST'; # seeds and models return through a redirect
        $ua->env_proxy;
        $ua;
    };
}


# submits the sequence search and returns the XML that comes back from the
# server
sub submit_search {
    my ($self, $seq) = @_;

    # build the query parameters. Use URI to format them nicely for LWP...
    my $uri = URI->new;
    my %param = (
            seqOpts => 'both',    # search both models and merge results
            ga      => 0,         # use the gathering threshold
            seq     => $seq,      # sequence to search
            output  => 'xml'
    );
    $uri->query_form( %param );

    # set up the request
    my $req = HTTP::Request->new( POST => $SEARCH_URL );
    $req->content_type('application/x-www-form-urlencoded');
    $req->content( $uri->query );

    my $res = $self->_ua_request(submission => $req);
    my $txt = $res->decoded_content;

    if ($txt =~ m{<div class="error">(.*?)</div>}s) { # ugh
        my $err = $1;
        $err =~ s{<h2>\s*Error\s*</h2>}{};
        $err =~ s{\A\s*|\s*\Z}{}g;
        die "Pfam website error: $err\n";
    }

    return $txt;
}


# parses the submission XML and returns the URL for retrieving results and the
# estimated job runtime
sub check_submission {
    my ($self, $xml) = @_;

    # parse the XML that came back from the server when we submitted the search
    my $parser = XML::LibXML->new();
    my $dom;
    try { $dom = $parser->parse_string($xml); }
    catch { $self->logger->warn("couldn't parse XML response for submission: $_") };
    return unless $dom;

    # the root element is "jobs"
    my $root = $dom->documentElement();

    # set up to use XPaths
    my $xc = XML::LibXML::XPathContext->new($root);
    $xc->registerNs( 'p', 'http://pfam.xfam.org/' );

    # we're only running a single Pfam-A search, so there will be only one "job"
    # tag, so we know that these XPaths will each give us only a single node
    my $result_url     = $xc->findvalue('/p:jobs/p:job/p:result_url');
#    my $estimated_time = $xc->findvalue('/p:jobs/p:job/p:estimated_time'); # no longer present
    die "Cannot recover result_url from XML\n$xml" unless $result_url;
    $result_url     =~ s/\s//g;

    return $result_url;
}

# polls the result URL as often as necessary (up to a hard limit) and returns
# the results XML
sub poll_results {
    my ($self, $result_url) = @_;

    # this is the request that we'll submit repeatedly
    my $req = HTTP::Request->new( GET => $result_url );

    my $res = $self->_ua_request(poll => $req);
    # at first,  202 (Accepted) with "PEND" or "RUN",
    # then later 200 (OK) with XML

    return $res->decoded_content;
}

# parses the results XML and return a hash containing the hits and locations
sub parse_results {
    my ($self, $results_xml) = @_;
    $self->logger->info("parsing XML search results");

    my $parser = XML::LibXML->new();
    my $dom;
    try { $dom = $parser->parse_string($results_xml); }
    catch { $self->logger->warn("couldn't parse XML response for results: $_") };
    return unless $dom;

    # set up the XPath stuff for this document
    my $root = $dom->documentElement();
    my $xc   = XML::LibXML::XPathContext->new($root);
    $xc->registerNs( 'p', 'http://pfam.xfam.org/' );

    # get all of the matches, that is the list of Pfam-A families that are found
    # on the sequence
    my @matches =
      $xc->findnodes(
'/p:pfam/p:results/p:matches/p:protein/p:database/p:match[@type="Pfam-A"]' );
    print 'found ' . scalar @matches . " hit(s)\n";
    my $results = {};
    foreach my $match_node (@matches) {
        print STDOUT (
            'looking for locations for Pfam-A '
            . $match_node->getAttribute('class') . ' '
            . $match_node->getAttribute('id') . ' ('
            . $match_node->getAttribute('accession')
            . ')' );
        my @locations =
          $xc->findnodes( 'p:location[@significant=1]', $match_node );
        print '  found '
          . scalar @locations
          . ' location(s) for '
          . $match_node->getAttribute('accession') . "\n";

        next unless @locations;

        foreach my $location_node (@locations) {
            my $location = {
                start => $location_node->getAttribute('start'),
                end   => $location_node->getAttribute('end')
            };
            push @{ $results->{ $match_node->getAttribute('accession') }->{locations} }, $location;
        }

        $results->{ $match_node->getAttribute('accession') }->{id} = $match_node->getAttribute('id');
        $results->{ $match_node->getAttribute('accession') }->{class} = $match_node->getAttribute('class');
    }
    print "done parsing search results\n";
    return $results;
}

#-------------------------------------------------------------------------------
# retrieves the HMM and seed alignment for each hit and drops them into the
# results hash

sub retrieve_pfam_hmm {
  my ($self, $domains) = @_;

  my %data;
  foreach my $domain (@$domains) {

    #----------------------------------------
    # get the HMM

    print STDOUT "$domain: retrieve HMM model\n";

    # set up the request
    my $req = HTTP::Request->new( POST => $HMM_URL );
    $req->content_type( 'application/x-www-form-urlencoded' );

    # add the query parameters onto the URL
    my $uri = URI->new;
    $uri->query_form( mode => 'ls',
                      entry => $domain );
    $req->content( $uri->query );

    try {
        my $res = $self->_ua_request("Domain $domain hmm", $req);
        $data{$domain} = $res->decoded_content;
    } catch {
        $self->logger->warn("$domain: HMM model retrieval failed: $_");
    };
  } # end of "foreach domain"

  return \%data;

}

sub retrieve_pfam_seed {
  my ($self, $domains) = @_;

  my %data;
  foreach my $domain (@$domains) {

    #----------------------------------------
    # get the HMM

    print STDOUT "$domain: retrieve seed alignments\n";

    # set up the request
    my $req = HTTP::Request->new( POST => $SEED_URL );
    $req->content_type( 'application/x-www-form-urlencoded' );

    # add the query parameters onto the URL
    my $uri = URI->new;
    $uri->query_form( alnType  => 'seed',
                      download => 1,
                      entry    => $domain );
    $req->content( $uri->query );

    try {
        my $res = $self->_ua_request("Domain $domain seed", $req);

        $data{$domain} = $res->content;
        # (need to strip out secondary structure and consensus lines,
        # otherwise hmmalign seg faults...)
        $data{$domain} =~ s/^\#=G[CR].*?\n//mg;

    } catch {
        $self->logger->warn("$domain: seed alignment retrieval failed: $_");
    };
  } # end of "foreach domain"

  return \%data;
}

sub get_seq_snippets {
    my ($self, $seq_name, $seq_string, $hit_locations) = @_;

    my $s;

    foreach my $location ( @$hit_locations ) {

            my $subseq = substr( $seq_string,
                           $location->{start} - 1,
                           $location->{end} - $location->{start} + 1 );

            $s .= ">${seq_name}_$location->{start}-$location->{end}\n$subseq\n";
    }

    return $s;
}


#-------------------------------------------------------------------------------
# builds a sequence file containing the sequence snippets that match Pfam
# hits and aligns them to the seed alignment using hmmalign. Writes the
# the resulting alignments to the working directory

sub align_to_seed {
    my ($self, $seq, $domain, $hmm, $seed) = @_;

    my $have_no = (!defined $seed ? "seed" :
                   (!defined $hmm ? "hmm" : ""));
    if ($have_no) {
        # Failure probably carried from retrieve_pfam_seed or
        # retrieve_pfam_hmm
        my $err = "have no $have_no, cannot run hmmalign";
        $self->logger->warn("$domain: $err");
        return (fail => $err);
    }

    # the sequence that we'll be aligning
    my $seq_file = $self->write_file($domain,"seq", $seq);

    # the seed alignment
    my $seed_file = $self->write_file($domain, "seed", $seed);

    # the HMM
    my $hmm_file = $self->write_file($domain, "ls", $hmm);

    # the hmmalign output
    my $output_filename = $self->create_filename($domain,"aln");

    # build the hmmalign command
    my @cmd = ($HMMALIGN,
               '--mapali' => $seed_file,
               '-o' => $output_filename,
               $hmm_file, $seq_file);

    $self->logger->debug("$domain: aligning with (@cmd)");

    my $ret = system @cmd;
    if ($ret) {
        my $err = "hmmalign '@cmd' failed [$ret]";
        $self->logger->warn("$domain: $err");
        return (fail => $err);
    } else {
        # delete tmp files
        unlink $seed_file, $hmm_file, $seq_file;
        return (ok => $output_filename);
    }
}

sub create_filename{
  my ($self, $stem, $ext) = @_;
  my $dir = $self->_tmpdir;
  $stem = '' if(!$stem);
  $ext = '' if(!$ext);
  my $num = int(rand(100000));
  my $file = $dir."/".$stem.".".$$.".".$num.".".$ext;
  while(-e $file){
    $num = int(rand(100000));
    $file = $dir."/".$stem.".".$$.".".$num.".".$ext;
  }
  return $file;
}

sub write_file {
    my ($self, $stem, $ext, $content) = @_;
    my $fn = $self->create_filename($stem, $ext);
    open my $fh, '>', $fn
      or die "Error creating $ext at $fn: $!";
    print {$fh} $content
      or die "Error writing to $fn: $!";
    close $fh
      or die "Error closing $fn: $!";
    return $fn;
}


1;
__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

