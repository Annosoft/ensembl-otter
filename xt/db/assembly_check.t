#! /software/bin/perl-5.12.2
use strict;
use warnings;

use Test::More;
use Test::Otter qw( ^db_or_skipall get_BOSDatasets diagdump );

=head1 DESCRIPTION

=head2 This script checks

=over 4

=item * assembly mapping segments in general

=item * the chromosome:contig:clone mappings.

=back

=head2 This script does not check

=over 4

=item * The sequence of clones.  See F<slow/clone_dna.t>    TODO

=item * Equivalence of assemblies between loutre and pipe.  TODO

=back

=head1 CAVEATS

Tests are structured as SELECTs which return no rows on success.  This
makes adding new tests simple, but has the obvious drawback that an
impossible constraint makes the test useless.  This is mitigated by
sharing SQL text where possible.

=head1 AUTHOR

mca@sanger.ac.uk

=cut


sub main {
    if (!@ARGV) {
        # species which pass
        push @ARGV,
          qw( rat gibbon opossum chimp wallaby gorilla platypus chicken
              mus_spretus dog tropicalis cat tomato marmoset medicago lemur
              sordaria tas_devil );

        # species which fail
@ARGV=();
        push @ARGV, qw( human mouse zebrafish pig );

        # restricted: nod_mouse
    }

    my @ds = get_BOSDatasets(@ARGV);
    my $maxrow = 2;

    my $FROM_ASM_A_CMP = q{  from
   seq_region asm
    join assembly a     on a.asm_seq_region_id = asm.seq_region_id
    join seq_region cmp on a.cmp_seq_region_id = cmp.seq_region_id};

    my %sql =
      ('assembly segment asm/cmp length: match && >= 0' => qq{
  select
   asm.name, asm_end-asm_start+1 asm_len,
   cmp.name, cmp_end-cmp_start+1 cmp_len, a.*
  $FROM_ASM_A_CMP
  where asm_end-asm_start+1 <> cmp_end-cmp_start+1
     or asm_end-asm_start+1 <= 0 },
       # where ori=-1 the lengths are still +ve
       # (almost always, and the rest look like a bad AGP loaded)

       (map {( "assembly.${_} side" => qq{
  select distinct asm.name, cmp.name,
   asm_start, asm_end, cmp_start, cmp_end, ori
  $FROM_ASM_A_CMP
  where (${_}_end > ${_}.length
      or ${_}_start < 1) } )} qw( asm cmp )),

       'contigs match their clone' => qq{
  select distinct asm.name, asm.length, cmp.name
  $FROM_ASM_A_CMP
    join coord_system acs  on asm.coord_system_id = acs.coord_system_id
    join coord_system ccs  on cmp.coord_system_id = ccs.coord_system_id
  where ccs.name = 'contig'
    and acs.name = 'clone'
    and (cmp.name <> concat_ws('.', asm.name, 1, asm.length)
      or acs.name <> 'clone'
      or a.asm_start <> 1 or a.cmp_start <> 1
      or a.asm_end <> asm.length
      or a.cmp_end <> asm.length
      or cmp.length <> asm.length
      or a.ori <> 1
        ) },

      );

    plan tests => @ds * keys %sql;

    foreach my $ds (@ds) {
        my $dbc = $ds->otter_dba->dbc;
        my $dbh = $dbc->db_handle;
        my $dbname = $dbc->dbname;

        foreach my $qname (sort keys %sql) {
            my $R = $dbh->selectall_arrayref("$sql{$qname} limit $maxrow");

            is(scalar @$R, 0, "$dbname: $qname")
              or diagdump(R => $R);
        }
    }

    return ();
}


main();
