#!/usr/bin/env perl

use strict;
use warnings;

use lib "${ENV{ANACODE_TEAM_TOOLS}}/t/tlib";
use Test::CriticModule;

use Test::More;

my @modules;
BEGIN {
    @modules = qw(
       Bio::Otter::LogFile
       Bio::Otter::Log::Appender::SafeScreen
       Bio::Otter::Log::Layout::UseSrcTimestamp
    );

    use_ok($_) foreach (@modules);
}
critic_module_ok($_) foreach (@modules);

done_testing;

1;

# Local Variables:
# mode: perl
# End:

# EOF
