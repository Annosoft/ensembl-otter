#!/usr/local/bin/perl

# script to take a list of HUGO names current gene labels and write
# sql required to change them.  ONLY SUITABLE FOR VEGA DATABASEs which
# only one assembly for each clone and the most recent version of each
# gene.

use strict;
use Getopt::Long;
use DBI;
use Sys::Hostname;
use cluster;

# hard wired
my $driver="mysql";
my $port=3306;
my $pass;
my $host='humsrv1';
my $user='ensro';
my $db='otter_human';
my $help;
my $phelp;
my $opt_v;
my $opt_i='';
my $opt_o='large_transcripts.lis';
my $opt_p='duplicate_exons.lis';
my $cache_file='check_genes.cache';
my $make_cache;
my $opt_c='';
my $opt_s=1000000;
my $opt_t;
my $exclude='GD:';

$Getopt::Long::ignorecase=0;

GetOptions(
	   'port:s', \$port,
	   'pass:s', \$pass,
	   'host:s', \$host,
	   'user:s', \$user,
	   'db:s', \$db,

	   'help', \$phelp,
	   'h',    \$help,
	   'v',    \$opt_v,
	   'i:s',  \$opt_i,
	   'o:s',  \$opt_o,
	   'p:s',  \$opt_p,
	   'c:s',  \$opt_c,
	   'make_cache',\$make_cache,
	   't:s',  \$opt_t,
	   'exclude:s', \$exclude,
	   );

# help
if($phelp){
  exec('perldoc', $0);
  exit 0;
}
if($help){
  print<<ENDOFTEXT;
rename_genes.pl
  -host           char      host of mysql instance ($host)
  -db             char      database ($db)
  -port           num       port ($port)
  -user           char      user ($user)
  -pass           char      passwd

  -h                        this help
  -help                     perldoc help
  -v                        verbose
  -o              file      output file ($opt_o)
  -p              file      output file ($opt_p)
  -c              char      chromosome ($opt_c)
  -make_cache               make cache file
  -exclude                  gene types prefixes to exclude ($exclude)
ENDOFTEXT
    exit 0;
}

# connect
my $dbh;
if(my $err=&_db_connect(\$dbh,$host,$db,$user,$pass)){
  print "failed to connect $err\n";
  exit 0;
}

my $n=0;
if($make_cache){

  # get assemblies of interest
  my %a;
  my $sth=$dbh->prepare("select a.contig_id, c.name, a.type, a.chr_start, a.chr_end, a.contig_start, a.contig_end, a.contig_ori from chromosome c, assembly a, sequence_set ss, vega_set vs where a.chromosome_id=c.chromosome_id and a.type=ss.assembly_type and ss.vega_set_id=vs.vega_set_id and vs.vega_type != 'N'");
  $sth->execute;
  my $n=0;
  while (my @row = $sth->fetchrow_array()){
    my $cid=shift @row;
    $a{$cid}=[@row];
    $n++;
  }
  print "$n contigs read from assembly\n";

  # get exons of current genes
  my $sth=$dbh->prepare("select gsi1.stable_id,gn.name,g.type,tsi.stable_id,ti.name,et.rank,e.exon_id,e.contig_id,e.contig_start,e.contig_end,e.sticky_rank from exon e, exon_transcript et, transcript t, current_gene_info cgi, gene_stable_id gsi1, gene_name gn, gene g, transcript_stable_id tsi, current_transcript_info cti, transcript_info ti left join gene_stable_id gsi2 on (gsi1.stable_id=gsi2.stable_id and gsi1.version<gsi2.version) where gsi2.stable_id IS NULL and cgi.gene_stable_id=gsi1.stable_id and cgi.gene_info_id=gn.gene_info_id and gsi1.gene_id=g.gene_id and g.gene_id=t.gene_id and t.transcript_id=tsi.transcript_id and tsi.stable_id=cti.transcript_stable_id and cti.transcript_info_id=ti.transcript_info_id and t.transcript_id=et.transcript_id and et.exon_id=e.exon_id and e.contig_id");
  $sth->execute;
  my $nexclude=0;
  my %excluded_gsi;
  my %reported_gsi;
  open(OUT,">$cache_file") || die "cannot open cache file $cache_file";
  while (my @row = $sth->fetchrow_array()){
    $n++;

    # transform to chr coords
    my($gsi,$gn,$gt,$tsi,$tn,$erank,$eid,$ecid,$est,$eed,$esr)=@row;
    if($a{$ecid}){

      my($cname,$atype,$acst,$aced,$ast,$aed,$ao)=@{$a{$ecid}};
      my $ecst;
      my $eced;
      if($ao==1){
	$ecst=$acst+$est-$ast;
	$eced=$acst+$eed-$ast;
      }else{
	$ecst=$aced-$est+$ast;
	$eced=$aced-$eed+$ast;
      }
      # constant direction - easier later
      if($ecst>$eced){
	my $t=$ecst;
	$ecst=$eced;
	$eced=$t;
      }
      my @row2=($gsi,$gn,$gt,$tsi,$tn,$erank,$eid,$ecst,$eced,$cname,$atype,$esr);
      print OUT join("\t",@row2)."\n";

      if($excluded_gsi{$gsi} && !$reported_gsi{$gsi}){
	print "WARN $gsi ($gn) chr=\'$cname\' ss=\'$atype\' has exon(s) off assembly:\n  ".
	    join("\n  ",@{$excluded_gsi{$gsi}})."\n";
	$reported_gsi{$gsi}=1;
      }

    }else{
      $nexclude++;
      push(@{$excluded_gsi{$gsi}},join(',',@row));
    }
    last if ($opt_t && $n>=$opt_t);
  }
  close(OUT);
  $dbh->disconnect();
  print "wrote $n records to cache file $cache_file\n";
  print "wrote $nexclude exons ignored as not in selected assembly\n";
  exit 0;
}

my %gsi;
my %gsi_sum;
my %tsi_sum;
my %atype;
my $n=0;
my $nobs=0;
my $nexclude=0;
open(IN,"$cache_file") || die "cannot open $opt_i";
while(<IN>){
  chomp;
  my($gsi,$gn,$gt,$tsi,$tn,$erank,$eid,$ecst,$eced,$cname,$atype,$esr)=split(/\t/);

  # skip obs genes
  if($gt eq 'obsolete'){
    $nobs++;
    next;
  }
  foreach my $excl (split(/,/,$exclude)){
    if($gt=~/^$excl/){
      $nexclude++;
      next;
    }
  }

  # expect transcripts to stay on same assembly
  if($tsi_sum{$tsi}){
    my($tn2,$cname2,$atype2)=@{$tsi_sum{$tsi}};
    if($cname2 ne $cname){
      print "ERR: $gsi ($gn): $tsi ($tn) on chr $cname and $cname2\n";
    }elsif($atype ne $atype2){
      print "ERR: $gsi ($gn): $tsi ($tn) on chr $atype and $atype2\n";
    }
  }else{
    $tsi_sum{$tsi}=[$tn,$cname,$atype];
  }

  push(@{$gsi{$atype}->{$gsi}},[$tsi,$erank,$eid,$ecst,$eced,$esr]);

  # these relationships should be fixed
  $atype{$atype}=$cname;
  $gsi_sum{$gsi}=[$gn,$gt];

  $n++;
}
close(IN);
print scalar(keys %gsi_sum)." genes read; $nobs obsolete skipped; $nexclude excluded\n";
print "$n name relationships read\n\n";

# get clones from assemblies of interest
my %a;
my $sth=$dbh->prepare("select a.type, cl.embl_acc, a.chr_start, a.chr_end, cl.name from clone cl, contig ct, assembly a, sequence_set ss, vega_set vs where a.contig_id=ct.contig_id and ct.clone_id=cl.clone_id and a.type=ss.assembly_type and ss.vega_set_id=vs.vega_set_id and vs.vega_type != 'N'");
$sth->execute;
my $n=0;
while (my @row = $sth->fetchrow_array()){
  my $type=shift @row;
  my $embl_acc=shift @row;
  $a{$type}->{$embl_acc}=[@row];
  $n++;
  }
print "$n contigs read from assembly\n";

my $nsticky=0;
my $nexon=0;
my %dup_exon;
my $nmc=0;
my $nl=0;
my $flag_v;
open(OUT,">$opt_o") || die "cannot open $opt_o";
open(OUT2,">$opt_p") || die "cannot open $opt_p";
foreach my $atype (keys %gsi){
  my $cname=$atype{$atype};
  print "Checking \'$atype\' (chr \'$cname\')\n";
  foreach my $gsi (keys %{$gsi{$atype}}){

    # debug:
    if($gsi eq 'OTTHUMG00000015202' && $opt_v){
      $flag_v=1;
    }else{
      $flag_v=0;
    }
    
    my($gn,$gt)=@{$gsi_sum{$gsi}};
    my %t2e;
    my %e2t;
    my %e;
    my %eids;
    my %eidso;
    my %elink;
    # look for overlapping exons and group exons into transcripts
    foreach my $rt (@{$gsi{$atype}->{$gsi}}){
      my($tsi,$erank,$eid,$ecst,$eced,$esr)=@{$rt};
      if($e{$eid}){
	# either stored as sticky rank2 or this is sticky rank2
	if($eids{$eid} || $esr>1){

	  my($st,$ed)=@{$e{$eid}};

	  # save originals
	  my $esro=1;
	  if($eids{$eid}){
	    $esro=$eids{$eid};
	  }
	  $eidso{$eid}->{$esro}=[$st,$ed] unless $eidso{$eid}->{$esro};
	  $eidso{$eid}->{$esr}=[$ecst,$eced] unless $eidso{$eid}->{$esr};
	  $eids{$eid}=1;

	  # skip if identical match to old original
	  my $match;
	  foreach my $esr2 (keys %{$eidso{$eid}}){
	    my($st2,$ed2)=@{$eidso{$eid}->{$esr2}};
	    if($st2==$ecst && $ed2==$eced){
	      $match=1;
	    }
	  }
	  if($match){
	    # if identical, check for sticky
	  }elsif($ed+1==$ecst){
	    $eids{"$eid.$esr"}=[$ecst,$eced];
	    $ed=$eced;
	    $e{$eid}=[$st,$ed];
	    $nsticky++;
	  }elsif($eced+1==$st){
	    $st=$ecst;
	    $e{$eid}=[$st,$ed];
	    $nsticky++;
	  }else{
	    print "ERR: duplicate exon id $eid, but no sticky alignment\n";
	  }
	}
      }else{
	my $flag;
	foreach my $eid2 (keys %e){
	  my($st,$ed)=@{$e{$eid2}};
	  if($st==$ecst && $ed==$eced){
	    # duplicate exons
	    if($dup_exon{$eid}==$eid2 || $dup_exon{$eid2}==$eid){
	    }else{
	      $dup_exon{$eid}=$eid2;
	      print OUT2 "$eid\t$eid2\t$st\t$ed\n";
	    }
	    $flag=1;
	    $eid=$eid2;
	  }else{
	    my $mxst=$st;
	    $mxst=$ecst if $ecst>$mxst;
	    my $mied=$ed;
	    $mied=$eced if $eced<$mied;
	    if($mxst<=$mied){
	      if(1){
		push(@{$elink{$eid}},$eid2);
	      }else{
	      # overlapping exons
		my $mist=$st;
		$mist=$ecst if $ecst<$mist;
		my $mxed=$ed;
		$mxed=$eced if $eced>$mxed;
		$e{$eid2}=[$mist,$mxed];
		$eid=$eid2;
		$flag=1;
	      }
	    }
	  }
	}
	if(!$flag){
	  $e{$eid}=[$ecst,$eced];
	  $eids{$eid}=$esr if $esr>1;
	  $nexon++;
	}
      }
      push(@{$t2e{$tsi}},$eid);
      push(@{$e2t{$eid}},$tsi);
    }
    # get size of transcripts and warn of large ones
    my %tse;
    foreach my $tsi (keys %t2e){
      my $mist=1000000000000;
      my $mxed=-1000000000000;
      foreach my $eid (@{$t2e{$tsi}}){
	my($st,$ed)=@{$e{$eid}};
	$mist=$st if $st<$mist;
	$mxed=$ed if $ed>$mxed;
      }
      $tse{$tsi}=[$mist,$mxed];
      my $tsize=$mxed-$mist;
      if($tsize>$opt_s){
	my($tn)=@{$tsi_sum{$tsi}};
	print OUT "WARN $tsize is size of $tsi ($tn), $gsi ($gn,$gt)\n";
	$nl++;
      }
    }
    my $cl=new cluster();
    # link exons by transcripts
    foreach my $tsi (keys %t2e){
      if(scalar(@{$t2e{$tsi}})>1){
	$cl->link([@{$t2e{$tsi}}]);
	print "D: $tsi ".join(',',@{$t2e{$tsi}})."\n" if $flag_v;
      }
    }
    # link exons by overlap
    foreach my $eid (keys %elink){
      $cl->link([$eid,@{$elink{$eid}}]);
      print "D: $eid ".join(',',@{$elink{$eid}})."\n" if $flag_v;
    }
    if($cl->cluster_count>1){
      print "$gsi ($gt,$gn) has multiple clusters\n";

      # analysis by overlap of exons
      foreach my $cid ($cl->cluster_ids){
	my %tcl;
	foreach my $eid ($cl->cluster_members($cid)){
	  foreach my $tsi (@{$e2t{$eid}}){
	    $tcl{$tsi}++;
	  }
	}
	print "Cluster $cid: ".join(',',(keys %tcl))."\n";
      }

      # analysis by overlap of transcripts
      my $last_ed;
      foreach my $tsi (sort {$tse{$a}->[0]<=>$tse{$b}->[0]} keys %tse){
	my($st,$ed)=@{$tse{$tsi}};
	my($tn)=@{$tsi_sum{$tsi}};
	if($last_ed && $last_ed<$st){
	  my $gap=$st-$last_ed;
	  print "  **GAP of $gap bases\n";
	  my $nc=0;
	  my $out='';
	  foreach my $embl_acc (keys %{$a{$atype}}){
	    my($st2,$ed2,$name)=@{$a{$atype}->{$embl_acc}};
	    if($st2>=$last_ed && $st2<=$st){
	      $nc++;
	      $out.="    Boundary of $embl_acc ($name)\n";
	    }
	    if($ed2>=$last_ed && $ed2<=$st){
	      $nc++;
	      $out.="    Boundary of $embl_acc ($name)\n";
	    }
	  }
	  if($nc<=2){
	    print $out;
	  }
	}
	print "  $tsi ($tn): $st-$ed\n";
	$last_ed=$ed;
      }
      $nmc++;
    }
  }
}
print scalar(keys %dup_exon)." duplicate exons\n";
print "$nmc genes with non overlapping transcripts\n";
print "found $nexon exons; $nsticky sticky exons\n";
print "$nl large transcripts\n";
close(OUT);
close(OUT2);

exit 0;

# connect to db with error handling
sub _db_connect{
  my($rdbh,$host,$database,$user,$pass)=@_;
  my $dsn = "DBI:$driver:database=$database;host=$host;port=$port";
  
  # try to connect to database
  eval{
    $$rdbh = DBI->connect($dsn, $user, $pass,
			  { RaiseError => 1, PrintError => 0 });
  };
  if($@){
    print "$database not on $host\n$@\n" if $opt_v;
    return -2;
  }
}

__END__


=pod

=head1 rename_genes.pl

=head1 DESCRIPTION

=head1 EXAMPLES

=head1 FLAGS

=over 4

=item -h

Displays short help

=item -help

Displays this help message

=back

=head1 VERSION HISTORY

=over 4

=item 17-MAR-2004

B<th> released first version

=back

=head1 BUGS

=head1 AUTHOR

B<Tim Hubbard> Email th@sanger.ac.uk

=cut
