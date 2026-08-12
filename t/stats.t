#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 14;

use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../../xAI-API/lib";

use xaictl::Stats;
use xAI::API;

my $class = 'xaictl::Stats';

my $sample = {
	usage => {
		input_tokens      => 42,
		output_tokens     => 7,
		total_tokens      => 49,
		cost_in_usd_ticks => 37756000,
	},
	output => [
		{
			type    => 'message',
			role    => 'assistant',
			content => [
				{ type => 'output_text', text => 'hello' },
			],
		},
	],
};

my $usage = $class->usage_from_response($sample);
is($usage->{prompt_tokens}, 42, 'maps input_tokens to prompt_tokens');
is($usage->{completion_tokens}, 7, 'maps output_tokens to completion_tokens');
is($usage->{total_tokens}, 49, 'preserves total_tokens');
is($usage->{cost_in_usd_ticks}, 37756000, 'extracts cost_in_usd_ticks');

my $usd = $class->ticks_to_usd(37756000);
ok(abs($usd - 0.0037756) < 0.0000001, 'converts ticks to USD');

my $line = $class->format_usage($usage, 'usage');
like($line, qr/usage\.cost_in_usd_ticks=37756000/, 'format includes raw ticks');
like($line, qr/usage\.cost_usd=0\.00377560/, 'format includes USD decimal');

my $totals = $class->empty_totals();
$class->accumulate($totals, $usage);
$class->accumulate($totals, {
	prompt_tokens     => 10,
	completion_tokens => 5,
	total_tokens      => 15,
	cost_in_usd_ticks => 10000000,
});

is($totals->{prompt_tokens}, 52, 'accumulates prompt tokens');
is($totals->{completion_tokens}, 12, 'accumulates completion tokens');
is($totals->{total_tokens}, 64, 'accumulates total tokens');
is($totals->{cost_in_usd_ticks}, 47756000, 'accumulates cost ticks');
is($totals->{query_count}, 2, 'counts queries');

my $text = $class->response_text($sample);
is($text, 'hello', 'extracts responses API output text');

my $legacy = {
	choices => [
		{ message => { content => "legacy ok" } },
	],
};
is($class->response_text($legacy), 'legacy ok', 'extracts chat choices text');

done_testing();