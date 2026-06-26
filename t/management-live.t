#!/usr/bin/env perl

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../../xAI-API/lib";

use GrokAPI::Config;
use xAI::API;
use Test::More;

my $conf = -f GrokAPI::Config->default_config_path()
	? GrokAPI::Config->read_config()
	: {};
my $mgmt_key = $ENV{XAI_MANAGEMENT_API_KEY}
	// GrokAPI::Config->management_key(config => $conf);
my $team_id  = $ENV{XAI_TEAM_ID};

if (!defined $mgmt_key || $mgmt_key eq '') {
	plan skip_all => 'XAI_MANAGEMENT_API_KEY or [mgmt] management_key required for live management test';
}

if (!defined $team_id || $team_id eq '') {
	my $bearer = GrokAPI::Config->bearer_token(config => $conf);
	if (defined $bearer && $bearer ne '') {
		my $api  = xAI::API->new(bearer_token => $bearer);
		my $info = $api->keyinfo();
		$team_id = $info->{team_id};
	}
}
plan skip_all => 'team_id required (XAI_TEAM_ID or inference keyinfo)' unless $team_id;

plan tests => 3;

my $mgmt = xAI::API->new_management(bearer_token => $mgmt_key);
my $bal  = $mgmt->prepaid_balance($team_id);
ok(defined $bal->{total}, 'prepaid balance returns total');
ok(defined $bal->{total}{val}, 'prepaid total has val');

my $usage = $mgmt->usage_analytics($team_id, {
	timeRange => {
		startTime => '2026-06-01 00:00:00',
		endTime   => '2026-06-30 23:59:59',
		timezone  => 'Etc/GMT',
	},
	timeUnit => 'TIME_UNIT_NONE',
	values   => [ { name => 'usd', aggregation => 'AGGREGATION_SUM' } ],
	groupBy  => [],
	filters  => [],
});
ok(ref $usage eq 'HASH', 'usage analytics returns hash');

done_testing();