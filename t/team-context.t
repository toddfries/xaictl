#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 5;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use GrokAPI::TeamContext;

my $class = 'GrokAPI::TeamContext';

is($class->team_id_for_mgmt(explicit => 'team-explicit'), 'team-explicit', 'explicit -T');

is(
	$class->team_id_for_mgmt(
		bearer     => 'tok',
		keyinfo_cb => sub { { team_id => 'from-keyinfo' } },
	),
	'from-keyinfo',
	'bearer keyinfo lookup',
);

is(
	$class->team_id_for_mgmt(
		explicit   => 'mgmt-only-team',
		bearer     => undef,
		keyinfo_cb => sub { die "should not call keyinfo" },
	),
	'mgmt-only-team',
	'mgmt-key-only with explicit -T',
);

eval { $class->team_id_for_mgmt() };
like($@, qr/team_id required/, 'error when both absent');

eval {
	$class->team_id_for_mgmt(
		bearer     => 'tok',
		keyinfo_cb => sub { {} },
	);
};
like($@, qr/did not return team_id/, 'error when keyinfo missing team_id');

done_testing();