#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 6;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use GrokAPI::BuildLog;

my $class = 'GrokAPI::BuildLog';

my $line = '{"ts":"2026-06-26T11:00:00Z","sid":"sess-1","msg":"shell.turn.inference_done","ctx":{"loop_index":1,"prompt_tokens":100,"completion_tokens":20,"cached_prompt_tokens":50,"reasoning_tokens":5}}';

my $rec = $class->parse_inference_line($line);
ok($rec, 'parses inference line');
is($rec->{session_id}, 'sess-1', 'session id');
is($rec->{ctx}{prompt_tokens}, 100, 'prompt tokens');

my $totals = $class->empty_totals();
$class->accumulate_turn($totals, $rec->{ctx});
$class->accumulate_turn($totals, {
	prompt_tokens => 200, completion_tokens => 30,
	cached_prompt_tokens => 10, reasoning_tokens => 0,
});

is($totals->{turn_count}, 2, 'turn count');
is($totals->{total_tokens}, 350, 'total tokens');
like($class->format_totals($totals), qr/build_session_total:.*total_tokens=350/, 'format');

done_testing();