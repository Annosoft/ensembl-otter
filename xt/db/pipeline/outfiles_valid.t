#! /software/bin/perl-5.12.2
use strict;
use warnings;

use Test::More;
use Test::Otter qw( ^db_or_skipall ^farm_or_skipall get_BOSDatasets diagdump );

=head1 DESCRIPTION

This script checks the C<pipe_$foo.job.std{out,err}_file> fields to
ensure

=over 4

=item * they point to somewhere that exists

=item * it is group writable

=item * it is owned by a group of which you are a member

=item * stdout and stderr go to files of matching name

=back

This test must therefore be run somewhere with access to the relevant
filesytem(s).  How inconvenient.


=head1 AUTHOR

mca@sanger.ac.uk

=cut


sub main {
    setup('0775 02775');

    @ARGV = 'ALL' if !@ARGV;
    my @ds = get_BOSDatasets(@ARGV);

    plan tests => @ds * 2;

    foreach my $ds (@ds) {
        my $dbc = $ds->pipeline_dba->dbc;
        my $dbh = $dbc->db_handle;
        my $dbname = $dbc->dbname;

        my $R = $dbh->selectall_arrayref
          (q{ select job_id, stdout_file, stderr_file from job });

        my @sfx_mismatch; # list of job_id
        my %dir; # key = files' directory, value = count of job_id
        while (my $row = shift @$R) {
            my ($id, @fn) = @$row;

            # see that (out,err) = map { "$dir/$foo.$_" } qw(out err)
            my (@leaf, @dir);
            for my $i (0,1) {
                ($dir[$i], $leaf[$i]) = $fn[$i] =~
                  m{^(.*?)/+([^/]+)$} or
                    die "Cannot digest fn[$i]=$fn[$i] (job_id=$id)";
            }
            foreach (@leaf) { s{\.(err|out)$}{} }
            push @sfx_mismatch, $id unless
              $leaf[0] eq $leaf[1] && $dir[0] eq $dir[1];

            # collect directories
            $dir{$dir[0]} ++;
        }

        my %dir_fail; # key = dirname, value = problem
        foreach my $dir (keys %dir) {
            my $err = checkdir($dir);
            $dir_fail{$dir} = $err if $err;
        }
        my %fail_count; # key = problem, value = { dir => count }
        while (my ($dir, $prob) = each %dir_fail) {
            $fail_count{$prob}{$dir} = $dir{$dir};
        }

        is(0, scalar keys %dir_fail, "$dbname: std{out,err}_file directories OK")
          or diagdump(dbname => $dbname, 'fail__dir__count' => \%fail_count);

        is(0, scalar @sfx_mismatch, "$dbname: stdout_file,stderr_file all same down to suffix")
          or diagdump(dbname => $dbname, job_id => \@sfx_mismatch);
    }

    return ();
}


{
    my %my_group; # key = egid, value = undef
    my $valid_mode; # join ' ', @octal_modes
    my %valid_mode; # key = decimal mode, value = undef

    sub setup {
        ($valid_mode) = @_;
        @my_group{  split / /, $) } = ();

        die "invalid valid_mode=$valid_mode"
          if grep { not /^0\d+/ } split / /, $valid_mode;
        my @mode_dec = map { oct($_) } split / /, $valid_mode;
        @valid_mode{@mode_dec} = ();
        return ();
    }

    sub checkdir {
        my ($dir) = @_;
        my @s = stat $dir;

        return 'not absolute'
          unless $dir =~ m{^/};
        return absent_dir($dir)
          unless -d _;
        return "not in your groups $)"
          unless exists $my_group{ $s[5] };

        my $mode = $s[2] & oct(7777);
        return sprintf("mode 0%o not in validity list %s", $mode, $valid_mode)
          unless exists $valid_mode{$mode};

        return '';
    }
}

sub absent_dir {
    my ($dir) = @_;
    my @p = $dir =~ m{(/+[^/]+)}g
      or die "Cannot break up $dir";
    for my $i (0 .. $#p) {
        my $part = join '', @p[0 .. $i];
        return "not a directory: $part" unless -d $part;
    }
    die "I thought $dir was absent, it isn't";
}

main();
