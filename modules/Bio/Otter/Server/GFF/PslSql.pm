
package Bio::Otter::Server::GFF::PslSql;

use strict;
use warnings;

use List::Util qw(max min);
use Readonly;
Readonly my $INTRON_MIN => 30;

use base qw( Bio::Otter::Server::GFF );

use Bio::Vega::DnaDnaAlignFeature;
use Bio::Vega::HitDescription;

# NOT a method - but probably should be, of a PSL utility class
#
# Taken from: http://genome.ucsc.edu/FAQ/FAQblat.html#blat4
# simplified by setting isMrna = 1 (as stated in the ref)
# AND assuming we're NOT handling protein PSLs!
#
sub _psl_percent_id {
    my $psl = shift;

    my $milliBad = 0;

    my $qAliSize = $psl->{qEnd} - $psl->{qStart};
    my $tAliSize = $psl->{tEnd} - $psl->{tStart};
    my $aliSize  = min($qAliSize, $tAliSize);
    if ($aliSize <= 0) {
        return 0;
    }
    my $sizeDif = $qAliSize - $tAliSize;
    if ($sizeDif < 0) {
        $sizeDif = 0;
    }
    my $insertFactor = $psl->{qNumInsert};
    my $total = $psl->{matches} + $psl->{repMatches} + $psl->{misMatches};
    if ($total != 0) {
        $milliBad = (1000 * ($psl->{misMatches} + $insertFactor + int(3*log(1+$sizeDif)+0.5))) / $total;
    }
    return 100 - $milliBad / 10;
}

sub _psl_score {
    my $psl = shift;

    return (
          $psl->{matches}
        + ($psl->{repMatches} / 2) 
        - $psl->{misMatches}
        - $psl->{qNumInsert}
        - $psl->{tNumInsert}
        );
}

# NOT a method - but probably should be, of a PSL utility class
#
sub _psl_get_next_block {
    my ($block_lists, $q_size, $positive) = @_;

    return unless (@{$block_lists->{sizes}} and @{$block_lists->{q_starts}} and @{$block_lists->{t_starts}});

    my $length      = shift(@{$block_lists->{sizes}});
    my $raw_q_start = shift(@{$block_lists->{q_starts}});
    my $raw_t_start = shift(@{$block_lists->{t_starts}});

    my %block;

    if ($positive) {

        $block{q_start} = $raw_q_start + 1;
        $block{q_end}   = $raw_q_start + $length;

    } else { # negative

        $block{q_end}   = $q_size - $raw_q_start;
        $block{q_start} = $block{q_end} - $length + 1;

    }

    $block{t_start} = $raw_t_start + 1;
    $block{t_end}   = $raw_t_start + $length;

    $block{length}  = $length;

    $block{cigar}   = $length == 1 ? 'M' : $length . 'M';

    return \%block;
}

# NOT a method
#
sub _psl_split_gapped_feature {
    my $psl = shift;

    my @features;

    my $strand = $psl->{strand};
    my $positive = ($strand eq '+');

    my $q_size      = $psl->{qSize};
    my $block_count = $psl->{blockCount};
    my $block_sizes = $psl->{blockSizes};
    my $q_starts    = $psl->{qStarts};
    my $t_starts    = $psl->{tStarts};

    # Much of the inital processing is nicked from Bio::SearchIO::psl
    #

    # cleanup trailing commas in some output
    $block_sizes =~ s/\,$//;
    $q_starts    =~ s/\,$//;
    $t_starts    =~ s/\,$//;

    my @blocksizes = split( /,/, $block_sizes );    # block sizes
    my @qstarts = split( /,/, $q_starts ); # starting position of each block in query
    my @tstarts = split( /,/, $t_starts ); # starting position of each block in target

    my %blocks = ( sizes => \@blocksizes, q_starts => \@qstarts, t_starts => \@tstarts );

    my $prev = _psl_get_next_block(\%blocks, $q_size, $positive);

    # Start with a copy of the initial block. There may only be one, after all
    my $current = { %$prev };

    while (my $this = _psl_get_next_block(\%blocks, $q_size, $positive)) {

        my $q_intron_len;
        if ($positive) {        # account for q blocks in rev order for -ve
            $q_intron_len = $this->{q_start} - $prev->{q_end} - 1;
        } else {
            $q_intron_len = $prev->{q_start} - $this->{q_end} - 1;
        }

        my $t_intron_len = $this->{t_start} - $prev->{t_end} - 1;

        # Don't understand why we need all of these conditions
        if (    $t_intron_len < $INTRON_MIN
                and $q_intron_len < $INTRON_MIN
                and ($t_intron_len == 0 or $q_intron_len == 0 or $t_intron_len == $q_intron_len)
            ) {

            # Treat as gap - extend $current and its cigar string
            #
            $current->{t_end}   = $this->{t_end};

            $current->{q_start} = min($current->{q_start}, $this->{q_start});
            $current->{q_end}   = max($current->{q_end},   $this->{q_end});

            if ($q_intron_len > 0) {
                # extra bases in query == insertions in target (can't do) == deletions from query
                $current->{cigar} .= $q_intron_len == 1 ? 'D' : $q_intron_len . 'D';
            } elsif ($t_intron_len > 0) {
                # extra bases in target == insertions in query to make match
                $current->{cigar} .= $t_intron_len == 1 ? 'I' : $t_intron_len . 'I';
            } else {
                # BAD PSL
                warn("Bad blocks list in PSL item.\n");
            }

            $current->{cigar} .= $this->{cigar};

        } else {

            # Treat as intron - add the current feature to the list and restart
            #
            push @features, $current;
            $current = { %$this };

        }

        $prev = $this;
    }

    push @features, $current;   # make sure to get the last (or only) block

    return @features;
}

sub Bio::EnsEMBL::Slice::get_all_features_via_psl_sql {
    my ($slice, $server, $sth, $chr_name) = @_;

    my $chr_start = $slice->start();
    my $chr_end   = $slice->end();

    $sth->execute($chr_name, $chr_start, $chr_end);

    my @feature_coll;

    my $rows = 0;

    while (my $psl_row = $sth->fetchrow_hashref) {

        ++$rows;
        my @features   = _psl_split_gapped_feature($psl_row);
        my $score      = _psl_score($psl_row);
        my $percent_id = _psl_percent_id($psl_row);

        my $hit_desc = Bio::Vega::HitDescription->new(
            -HIT_NAME   => $psl_row->{qName},
            -HIT_LENGTH => $psl_row->{qSize},
            );

        foreach my $f (@features) {

            # Skip components which extend beyond segment.
            # (We could truncate align features if we could
            # correctly cut cigar strings etc...)
            next if $f->{t_start} < $chr_start;
            next if $f->{t_end}   > $chr_end;

            my $daf = Bio::Vega::DnaDnaAlignFeature->new_fast({});
            $daf->{'_hit_description'} = $hit_desc;

            $daf->slice(   $slice );

            $daf->start( $f->{t_start} - $chr_start + 1 );
            $daf->end(   $f->{t_end}   - $chr_start + 1 );
            $daf->strand( $psl_row->{strand} =~ /^-/ ? -1 : 1 );

            $daf->hstart(   $f->{q_start} );
            $daf->hend(     $f->{q_end}    );
            $daf->hstrand(  1                 );
            $daf->hseqname( $psl_row->{qName} );

            my $cigar = $f->{cigar};
            if ( $psl_row->{strand} =~ /^-/ ) {
                $cigar = join('', reverse($cigar =~ /(\d*[A-Za-z])/g));
            }
            $daf->cigar_string( $cigar            );

            $daf->score(        $score            );
            $daf->percent_id(   $percent_id       );

            $daf->display_id(   $psl_row->{qName} );

            push @feature_coll, $daf;

        }

    }

    warn "got ", scalar(@feature_coll), " features from $rows rows\n";

    return \@feature_coll;
}

sub get_requested_features {
    my ($self) = @_;

    my $chr_name      = $self->param('name');  ## Since in our new schema name is substituted for type,
    ## we need it clean for outer sources

    my $db_dsn   = $self->require_argument('db_dsn');
    my $db_user  = $self->require_argument('db_user');
    my $db_pass  = $self->param('db_pass');

    my $db_table = $self->require_argument('db_table');
    ($db_table) = $db_table =~ m/(\w+)/; # avoid sql injection

    my $chr_prefix = $self->param('chr_prefix');
    $chr_name = "${chr_prefix}${chr_name}" if defined $chr_prefix;

    my $connecting = sprintf("connecting to '%s' %s %s, table %s\n",
        $db_dsn,
        $db_user ? "as '${db_user}'" : "[no user]",
        $db_pass ? "with pw"         : "[no pw]",
        $db_table);

    my $dbh = DBI->connect($db_dsn, $db_user, $db_pass, {RaiseError => 1})
        or die "Error $connecting";
    my $sth = $dbh->prepare(qq{
    SELECT
        matches,
        misMatches,
        repMatches,
        nCount,
        qNumInsert,
        qBaseInsert,
        tNumInsert,
        tBaseInsert,
        strand,
        qName,
        qSize,
        qStart,
        qEnd,
        tName,
        tSize,
        tStart,
        tEnd,
        blockCount,
        blockSizes,
        qStarts,
        tStarts
    FROM
        ${db_table}
    WHERE
            tName   = ?
        AND tEnd   >= ?
        AND tStart <= ?
    ORDER BY
        tStart ASC
    });

    my $map = $self->make_map;
    my $features = $self->fetch_mapped_features_das(
        'get_all_features_via_psl_sql',
        [$self, $sth, $chr_name],
        $map);

    return $features;
}

1;

__END__

=head1 AUTHOR

Michael Gray B<email> mg13@sanger.ac.uk

