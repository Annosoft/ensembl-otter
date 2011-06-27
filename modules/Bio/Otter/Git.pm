
package Bio::Otter::Git;

use strict;
use warnings;

#  NB: This module must not have any non-standard dependencies,
#  because the installer uses this module and it runs with a very
#  minimal $PATH, $PERL5LIB etc. (due in part to ssh-ing to
#  development hosts) so it will only find modules in default
#  locations.  If you add any dependencies here then you *must* check
#  that the installer still works.
 
use File::Basename;

my $dir = dirname __FILE__;

my $commands = {
    head => q(git describe --tags HEAD),
};

our $CACHE = {
};

#  Attempt to load a cache.
unless (eval { require Bio::Otter::Git::Cache; 1; }) {
    if ($@ =~ m(\A\QCan't locate Bio/Otter/Git/Cache.pm in \E)) {
        warn "No git cache: assuming a git checkout.\n";
        my $command = q(git tag);
        system(qq(cd '$dir' && $command > /dev/null)) == 0
            or die "'$command' failed: something is wrong with your git checkout";
    }
    else {
        die "cache error: $@";
    }
}

sub dump { ## no critic (Subroutines::ProhibitBuiltinHomonyms)
    my ($pkg) = @_;
    warn sprintf "git HEAD: %s\n", $pkg->param('head');
    return;
}

my $cache_template = <<'CACHE_TEMPLATE'

package Bio::Otter::Git::Cache;

use strict;
use warnings;

$Bio::Otter::Git::CACHE = {
%s};

1;

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk
CACHE_TEMPLATE
    ;

sub _create_cache {
    my ($pkg, $module_dir) = @_;

    my $cache_contents = join '', map {
        sprintf "    %s => q(%s),\n", $_, $pkg->param($_);
    } keys %{$commands};

    require File::Path;
    my $git_dir = "${module_dir}/Bio/Otter/Git";
    File::Path::make_path($git_dir);

    my $cache_path = "${git_dir}/Cache.pm";
    open my $cache_h, '>', $cache_path
        or die "failed to open the git cache '${cache_path}': $!";
    printf $cache_h $cache_template, $cache_contents;
    close $cache_h
        or die "failed to close the git cache '${cache_path}': $!";

    return;
}

sub param {
    my ($pkg, $key) = @_;
    $CACHE->{$key} = $pkg->_param($key)
        unless exists $CACHE->{$key};
    return $CACHE->{$key};
}

sub _param {
    my ($pkg, $key) = @_;
    my $command = $commands->{$key};
    die qq(invalid git parameter key "${key}") unless $command;
    my $shell_command = sprintf q( cd '%s' && %s ), $dir, $command;
    my $value = qx( $shell_command ); ## no critic(InputOutput::ProhibitBacktickOperators)
    chomp $value;
    unless ($? == 0) {
        warn qq("$shell_command" failed);
        return;
    }
    return $value;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

