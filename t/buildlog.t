#!/usr/bin/env perl

use strict;
use warnings;
use File::Temp;
use Test::More tests => 9;

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

my $line2 = '{"ts":"2026-06-26T12:00:00Z","sid":"sess-2","msg":"shell.turn.inference_done","ctx":{"loop_index":1,"prompt_tokens":50,"completion_tokens":10,"cached_prompt_tokens":0,"reasoning_tokens":0}}';
my $tmp = File::Temp->new(UNLINK => 1);
print {$tmp} "$line\n$line2\n";
close $tmp;

my ($ordered, $sessions) = $class->scan_all_sessions(log_path => $tmp->filename);
is(scalar @{$ordered}, 2, 'two sessions');
is($sessions->{'sess-1'}{totals}{total_tokens}, 120, 'sess-1 total');
is($sessions->{'sess-2'}{totals}{total_tokens}, 60, 'sess-2 total');

done_testing();