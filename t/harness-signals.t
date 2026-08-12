#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use JSON;
use xaictl::Harness::Signals;

my $class = 'xaictl::Harness::Signals';
my $fixture = "$Bin/fixtures/signals.json";

open my $fh, '<', $fixture or die "fixture missing: $fixture\n";
local $/; my $raw = <$fh>;
close $fh;
my $data = decode_json($raw);
ok(ref $data eq 'HASH', 'fixture signals parse');

ok(defined $data->{contextWindowUsage}, 'fixture has contextWindowUsage');

my $out = $class->format_report(
	$data,
	session_id => 'fixture-session',
	path         => $fixture,
);
like($out, qr/xai\.signals\.context_window_usage=42\.5/, 'format includes usage percent');
like($out, qr/xai\.signals\.session_id=fixture-session/, 'format session id');

SKIP: {
	skip 'GROK_SIGNALS_LIVE not set', 2 unless $ENV{GROK_SIGNALS_LIVE};
	my $sid = $ENV{GROK_GOAL_SESSION};
	if (!$sid) {
		require xaictl::BuildLog;
		$sid = xaictl::BuildLog->read_active_session_id();
	}
	skip 'no live session id', 2 unless $sid;
	my ($live, $path) = $class->read_signals($sid);
	ok($live, 'reads live session signals when GROK_SIGNALS_LIVE=1');
	ok($path && -f $path, 'live signals path exists');
}

done_testing();