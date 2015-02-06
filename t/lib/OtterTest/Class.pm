package OtterTest::Class;

use Test::Class::Most           # autmogically becomes our parent
    is_abstract => 1,
    attributes  => our_object;

use parent 'Class::Data::Inheritable';

use lib "${ENV{ANACODE_TEAM_TOOLS}}/t/tlib";
use Test::CriticModule;

BEGIN {
    __PACKAGE__->mk_classdata('class');
    __PACKAGE__->mk_classdata('run_all');
}

{
    my %no_run_tests;

    sub import {
        my ($class, %args) = @_;
        if (delete $args{no_run_test}) {
            my $caller = caller;
            $no_run_tests{$class} = 1;
            my $obj_class = $class->_set_class;
            eval "use $obj_class";
        }
        return;
    }

    sub _test_classes {
        my $class = shift;
        my @test_classes = Test::Class::_test_classes($class);
        return @test_classes if __PACKAGE__->run_all;
        return grep { not $no_run_tests{$_} } @test_classes;
    }

    sub runtests {
        my @tests = @_;
        if (@tests == 1 && !ref($tests[0])) {
            my $base_class = shift @tests;
            @tests = _test_classes( $base_class ); # use my version
        }
        return Test::Class::runtests(@tests);
    }

    INIT {
        __PACKAGE__->runtests;
    }
}

sub is_abstract {
    my $test = shift;
    return Test::Class::Most->is_abstract($test);
}

sub _set_class {
    my $test = shift;

    my $class = $test->class;
    return $class if $class;

    ( $class = ref($test) || $test ) =~ s/^Test:://;
    $test->class($class);
    return $class;
}

sub startup : Tests(startup => 1) {
    my $test  = shift;
    return 'abstract base class' if $test->is_abstract;

    my $class = $test->_set_class;
    use_ok $class or die;

    return;
}

sub shutdown : Tests(shutdown) {
    return;
}

sub setup : Tests(setup) {
    my $test = shift;
    return if $test->is_abstract;

    my $class = $test->class;
    $test->our_object($class->new);
    return;
}

sub teardown : Tests(teardown) {
    return;
}

sub _critic : Test(1) {
    my $test = shift;
    return 'abstract base class' if $test->is_abstract;

    local $SIG{__WARN__} = sub {
        my $msg = shift;
        return if $msg =~ m/^Called UNIVERSAL::isa\(\) as a function/;
        warn $msg;
        return;
    };

    my $class = $test->class;
    critic_module_ok($class);

    return;
}

sub constructor : Test(3) {
    my $test = shift;
    return 'abstract base class' if $test->is_abstract;

    my $class = $test->class;
    can_ok $class, 'new';
    ok my  $cs = $class->new, '... and the constructor should succeed';
    isa_ok $cs,  $class,      '... and the object it returns';
    return;
}

# To be used by tests on accessors which return another object
# Runs 2 tests
sub object_accessor {
    my ($test, $accessor, $expected_class, @args) = @_;
    my $object = $test->our_object;
    can_ok $object, $accessor;
    $object = $object->$accessor(@args);
    isa_ok $object, $expected_class, '... and returned object';
    return $object;
}

sub test_attributes : Tests {
    my $test = shift;
    return 'abstract base class' if $test->is_abstract;

    my $attributes = $test->_attributes;
    return 'no attributes' unless $attributes;

    $test->num_tests((scalar keys %$attributes)*3);

    foreach my $a ( keys %$attributes ) {
        $test->_attribute($a, $attributes->{$a});
    }
    return;
}

sub _attribute {
    my ($test, $attribute, $expected) = @_;

    $test->setup;
    my $obj = $test->our_object;

    can_ok $obj, $attribute;
    ok ! defined $obj->$attribute, "...and '$attribute' should start out undefined";
    $test->set_attributes;
    is $obj->$attribute, $expected,'...and setting its value should succeed';

    $test->teardown;
    return;
}

sub set_attributes {
    my $test = shift;
    my $obj = $test->our_object;
    my $attributes = $test->_attributes;
    foreach my $a ( keys %$attributes ) {
        $obj->$a($attributes->{$a});
    }
    return;
}

sub _attributes {
    my $test = shift;

    my $_attributes = $test->{_attributes};
    return $_attributes if $_attributes;

    $_attributes = $test->build_attributes;
    return unless $_attributes;

    $_attributes = { %$_attributes }; # make a copy we can manipulate
    foreach my $a ( keys %$_attributes ) {
        my $val_or_sub = $_attributes->{$a};
        my $ref = ref $val_or_sub;
        if ($ref and $ref eq 'CODE') {
            $val_or_sub = &$val_or_sub($test);
            $_attributes->{$a} = $val_or_sub;
        }
    }

    return $test->{_attributes} = $_attributes;
}

sub build_attributes { die 'build_attributes() must be provided by child class.' }

# Caller is responsible for doing $test->teardown() once finished
sub test_object {
    my $test = shift;
    $test->_set_class;
    $test->setup;
    $test->set_attributes;
    return $test->our_object;
}

1;
