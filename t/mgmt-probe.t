#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 7;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use xaictl::Management::Probe;

my $class = 'xaictl::Management::Probe';
my $cat   = $class->endpoint_catalog();

ok(ref $cat->{readonly} eq 'ARRAY' && @{$cat->{readonly}} >= 8, 'readonly catalog');
ok(ref $cat->{write_capable} eq 'ARRAY' && @{$cat->{write_capable}} >= 4, 'write catalog');

is(
	$class->expand_path('auth/teams/{teamId}/models', 'aaaa-bbbb'),
	'auth/teams/aaaa-bbbb/models',
	'expand_path',
);

my $mock_api = bless {}, 'MockMgmtAPI';
{
	no warnings 'redefine';
	*MockMgmtAPI::mgmt_request = sub {
		my ($self, $method, $path) = @_;
		return { ok => 1, status => 200, data => { apiKeys => [{}, {}] } }
			if $path =~ /api-keys/;
		return { ok => 0, status => 403, error => 'denied' }
			if $path =~ /audit/;
		return { ok => 1, status => 200, data => { total => { val => '-100' } } };
	};
}

my $results = $class->probe_readonly(
	api     => $mock_api,
	team_id => '1d67d1a7-61bb-420a-a20d-6b18c314b98e',
);

my ($ok, $deny) = (0, 0);
for my $r (@{$results}) {
	$ok++   if $r->{ok};
	$deny++ if !$r->{ok} && ($r->{status} // 0) == 403;
}
ok($ok > 0, 'mock probe has successes');
ok($deny > 0, 'mock probe records denials');

my $report = $class->format_report($results, team_id => 'team-1');
like($report, qr/xai\.mgmt\.probe\.team_id=team-1/, 'format_report team');
like($report, qr/xai\.mgmt\.probe\.write_capable\.count=/, 'format_report write section');

done_testing();