package Tk::ManualOrder;

# A mega-widget that inherits from Tk::Frame.
#
# Accepts a list of toString()'able objects,
# displays them in a vertical list
# and allows the user to re-order the objects or remove some of them.
#
# The interface for getting/setting the list is done via configure/cget mechanism.
#
# lg4

use Tk;

use base ('Evi::DestroyReporter', 'Tk::LabFrame');

Construct Tk::Widget 'ManualOrder';

sub Populate {
	my ($self,$args) = @_;

	$self->SUPER::Populate($args);

	$self->ConfigSpecs(
		-activelist => ['METHOD', 'activelist', 'Activelist', []],
	);

}

sub activelist { # the METHOD's name should match the option name minus dash
	my ($self, $newactive_lp) = @_;

	if(defined($newactive_lp)) {
		if($self->{_activelist}) {
			$self->_get_rid_of(); # of all widgets, basically
		}
		$self->{_activelist} = $newactive_lp;
		for my $idx (0..@$newactive_lp-1) {
			$self->_grid_object_at($newactive_lp->[$idx],$idx);
		}
	}
	return $self->{_activelist};
}

sub append_object {
	my ($self, $object) = @_;

	my $activelist = $self->{_activelist};

	$self->_grid_object_at($object, scalar(@$activelist));
	push @$activelist, $object;
}

# --------------------the rest is the implementation------------------

sub _get_rid_of {
	my ($self, @rest) = @_;

	for my $wid ($self->gridSlaves(@rest)) {
		$wid->gridForget();
	}
}

sub _grid_object_at {
	my ($self, $object, $idx) = @_;

	if($idx) {
		$self->Button(
			-text => 'Swap',
			-command => [ \&_swap_idx1_idx2, $self, $idx, $idx-1 ],
		)->grid(-row => 2*$idx-1, -rowspan => 2, -column => 0);
	}

	$self->Label(
		-text => $object->toString(),
	)->grid(-row => 2*$idx, -rowspan => 2, -column => 1);

	$self->Button(
		-text => 'Remove',
		-command => [ \&_remove_by_idx, $self, $idx ],
	)->grid(-row => 2*$idx, -rowspan => 2, -column => 2);
}

sub _swap_idx1_idx2 { # just re-create them from scratch
	my ($self, $idx1, $idx2) = @_;

	my $activelist = $self->{_activelist};

	$self->_get_rid_of(-row => 2*$idx1);
	$self->_get_rid_of(-row => 2*$idx2);

	my $temp = $self->{_activelist}[$idx1];
	$activelist->[$idx1] = $activelist->[$idx2];
	$activelist->[$idx2] = $temp;

	$self->_grid_object_at($activelist->[$idx1],$idx1);
	$self->_grid_object_at($activelist->[$idx2],$idx2);
}

sub _remove_by_idx {
	my ($self, $idx) = @_;

	my $activelist = $self->{_activelist};

	for my $idx2 ($idx+1..@$activelist-1) {
		$self->_swap_idx1_idx2($idx2-1,$idx2);
	}
	
	pop @$activelist;
	$self->_get_rid_of(-row => 2*scalar(@$activelist));
}

1;

