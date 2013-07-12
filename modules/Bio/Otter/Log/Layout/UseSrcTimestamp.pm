package Bio::Otter::Log::Layout::UseSrcTimestamp;

use warnings;
use strict;

use Carp;
use Log::Log4perl;              # cyclical dependencies in syntax check if we don't use this first :-(

use parent qw(Log::Log4perl::Layout::PatternLayout);

sub new {
    my ($class, $options) = @_;

    $options //= {};
    my $debug = $options->{Debug};
    delete $options->{Debug};

    my $self = $class->SUPER::new($options);
    $self->{Debug} = $debug->{value} if $debug;

    return $self;
}

sub render {
    my ($self, $message, $category, $priority, $caller_level) = @_;

    # Strip spurious trailing newlines from the message
    $message =~ s/\n+$//;

    $caller_level //= 0;

    my $placeholder = '__U_S_T_MSG__';
    my $wrapping = $self->SUPER::render($placeholder, $category, $priority, $caller_level+1);

    # ZMap log timestamps are of form MM/dd/yyyy  HH:mm:ss.SSSSSS
    my $zmap_ts_r = qr'
        ^
        (?<Z_pre>.*)
        (?<Z_yyyy>\d{4}) / (?<Z_MM>\d{2}) / (?<Z_dd>\d{2})    # date components
        \s+
        (?<Z_time>\d{2} : \d{2} : \d{2}) , (?<Z_subsec>\d+)  # time components
        \s+
        (?<Z_post>.*)
        $
      'sx;

    if ($message =~ $zmap_ts_r) {

        my %z_comps = map { $_ => $-{$_}[0] } keys %-; # flatten %-

        # It'd be good to get this from the config, but for now...
        # Otter log timestamps are based on ISO8601 with perhaps differing sub-second precision
        # yyyy-MM-dd HH:mm:ss.SSS[...]
        my $l4p_ts_r = qr'
            (\d{4} - \d{2} - \d{2} \s+ \d{2} : \d{2} : \d{2}) , (\d+)
          'x;
        my ($l4p_ts, $l4p_subsec);
        unless (($l4p_ts, $l4p_subsec) = $wrapping =~ $l4p_ts_r) {
            croak "Cannot find ISO8601-like timestamp in Log4perl conversion";
        }
        my $old_ts = "$l4p_ts,$l4p_subsec"; # reassemble the bits!

        my $precision = length $l4p_subsec;
        my $z_subsec = substr $z_comps{Z_subsec}, 0, $precision;
        my $new_ts = sprintf "%s-%s-%s %s,%s", @z_comps{qw( Z_yyyy Z_MM Z_dd Z_time )}, $z_subsec;

        $wrapping =~ s/${old_ts}/${new_ts}/;

        my $debug;
        if ($self->{Debug}) {
            my $zmap_ts = sprintf "%s/%s/%s %s,%s", @z_comps{qw( Z_yyyy Z_MM Z_dd Z_time Z_subsec )};

            $debug   = sprintf "\n[%s ~> %s]", $old_ts, $zmap_ts;
        } else {
            $debug = ' [zmap_ts]';
        }

        my $content = $z_comps{Z_pre} ? join(' ', $z_comps{Z_pre}, $z_comps{Z_post}) : $z_comps{Z_post};
        $message = $content . $debug;
    }

    my $result;
    ($result = $wrapping) =~ s/$placeholder/$message/;

    # Multi-line padding
    my $raw_prefix = $wrapping;
    chomp $raw_prefix;
    $raw_prefix =~ s/$placeholder//;
    my $prefix_len = length($raw_prefix) - 2; # ASSUMPTION: prefix ends with ': '
    my $padding = ' ' x $prefix_len . '| ';
    $result =~ s/\n(?!$)/\n$padding/g; # pad newlines which are not at the end of the result

    return $result;
}

1;

__END__

=head1 NAME

Bio::Otter::Log::Layout::UseSrcTimestamp - replace Log4perl timestamp with log message's timestamp, if present

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

=cut

# EOF
