
### Bio::Vega::Transform

package Bio::Vega::Transform;

use strict;
use warnings;
use Carp;
use XML::Parser;
use Data::Dumper;   # For debugging

# This misses the "$VAR1 = " bit out from the Dumper() output
$Data::Dumper::Terse = 1;

# Using inside-out object design for speed.

my (
    %tag_stack,
    %current_object,
    %current_string,
    %object_builders,
    %object_data,
    %is_multiple,
    );

sub DESTROY {
    my ($self) = @_;

    # printf STDERR "Destroying '%s'\n", ref($self);

    delete $tag_stack{$self};
    delete $current_object{$self};
    delete $current_string{$self};
    delete $object_builders{$self};
    if (my $data = delete $object_data{$self}) {
        warn "Unused data after parse: ", Dumper($data);
    }
    delete $is_multiple{$self};

    return;
}

sub new {
    my ($pkg) = @_;

    my $scalar;
    my $self = bless \$scalar, $pkg;
    $self->initialize;
    $tag_stack{$self} = [];

    return $self;
}

sub parse {
    my ($self, $fh, $encoding) = @_;

    $self->_do_parse($fh, $encoding, 'parse');

    return;
}

sub parsefile {
    my ($self, $filename, $encoding) = @_;

    $self->_do_parse($filename, $encoding, 'parsefile');

    return;
}

# If we need a value from the parent tag which has not yet
# been closed whilst we're building an object.
sub parent_data {
    my ($self) = @_;
    
    my $context = $tag_stack{$self}[0];
    # warn "Returning data under '$context', stored data: ", Dumper($object_data{$self});
    return $object_data{$self}{$context};
}

sub _do_parse {
    my ($self, $file, $encoding, $method) = @_;
    
    my @opt;
    if ($encoding) {
        if ($encoding eq 'latin1') {
            @opt = (ProtocolEncoding => 'ISO-8859-1');
        } else {
            confess "Unknown encoding '$encoding'";
        }
    }
    
    my $parser = $self->new_Parser;
    $parser->$method($file, @opt);

    return;
}

sub new_Parser {
    my ($self) = @_;

    my $parser = XML::Parser->new(
        ErrorContext => 3,
        Handlers => {
            Start => sub { $self->handle_start(@_); },
            End   => sub { $self->handle_end(@_);   },
            Char  => sub { $self->handle_char(@_);  },
        },
    );
    return $parser;
}

sub object_builders {
    my ($self, $value) = @_;

    if ($value) {
        $object_builders{$self} = $value;
    }
    return $object_builders{$self};
}

sub set_multi_value_tags {
    my ($self, $value) = @_;

    if ($value) {
        foreach my $row (@$value) {
            my ($context, @ele) = @$row;
            foreach my $element (@ele) {
                $is_multiple{$self}{$context}{$element} = 1;
            }
        }
    }
    return $is_multiple{$self};
}

sub handle_start {
    my ($self, $expat, $element, @args) = @_;

    if ($object_builders{$self}{$element}) {
        # This makes $element the "current context"
        unshift @{$tag_stack{$self}}, $element;
        # @args are attribute key, value pairs
        for (my $i = 0; $i < @args; $i += 2) {
            $object_data{$self}{$element}{$args[$i]} = $args[$i + 1];
        }
    }
    elsif (@args) {
        # There are attribtes in a non object-creating tag.
        $expat->xpcroak(
            "This parser cannot handle attributes in '$element' tags:\n"
            . Dumper({@args})
            );
    }

    return;
}

sub handle_char {
    my ($self, $expat, $txt) = @_;
    # The character handler may be called multiple times
    # by Expat on a single string. We therefore need
    # to append to the existing string.
    $current_string{$self} .= $txt;
    return;
}

sub handle_end {
    my ($self, $expat, $element) = @_;

    if (my $builder = $object_builders{$self}{$element}) {
        # It is the end of a tag that we use to make an object.
        # We now have all the data needed, and pass it to the
        # builder method.
        my $context = shift @{$tag_stack{$self}};
        my $data    = delete $object_data{$self}{$context};
        # warn "\nCalling $builder at end of $context with: ", Dumper($data);
        $self->$builder($data);
    }
    elsif (defined( my $str = delete $current_string{$self} )) {
        # It is a tag that encloses non-markup text (its value).
        # We save it under its tag (the key) in the current context.
        my $context = $tag_stack{$self}[0];
        $str =~ s/(^\s+|\s+$)//g;
        # warn "Setting '$element' in '$context' to '$str'\n";
        if ($is_multiple{$self}{$context}{$element}) {
            # Tag can occur multiple times, so we save it in an array.
            my $list = $object_data{$self}{$context}{$element} ||= [];
            push(@$list, $str);
        } else {
            # Tag should only occur once, so check that it does not already have a value.
            if (defined( my $value = $object_data{$self}{$context}{$element} )) {
                # xpcroak method on Expat object gives
                # some context in the XML.
                $expat->xpcroak("Setting '$element' in '$context' to '$str' but already set to '$value'");
            } else {
                $object_data{$self}{$context}{$element} = $str;
            }
        }
    }

    return;
}

1;

__END__

=head1 NAME - Bio::Vega::Transform

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

