#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 8;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use xaictl::TeamContext;

my $class = 'xaictl::TeamContext';
my $VALID = '1d67d1a7-61bb-420a-a20d-6b18c314b98e';

ok($class->is_valid_team_id($VALID), 'valid UUID');
ok(!$class->is_valid_team_id('fake-team-id'), 'invalid UUID rejected');
ok(!$class->is_valid_team_id(''), 'empty rejected');

is($class->team_id_for_mgmt(explicit => $VALID), $VALID, 'explicit -T with UUID');

is(
	$class->team_id_for_mgmt(
		bearer     => 'tok',
		keyinfo_cb => sub { { team_id => $VALID } },
	),
	$VALID,
	'bearer keyinfo lookup',
);

is(
	$class->team_id_for_mgmt(
		explicit   => $VALID,
		bearer     => undef,
		keyinfo_cb => sub { die "should not call keyinfo" },
	),
	$VALID,
	'mgmt-only with explicit -T',
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