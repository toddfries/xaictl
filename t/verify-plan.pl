#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);
use JSON;
use File::Find;

my $root    = "$Bin/..";
my $scratch = $ENV{GROK_GOAL_SCRATCH} // '/tmp/grok-goal-a7d760d85190/implementer';
my $bin     = "$root/grok-sanity";
my $conf    = $ENV{HOME} . '/.config/cxai/grok.conf';
my $guard   = "$Bin/scope-guard.sh";
my $goal_sid = $ENV{GROK_GOAL_SESSION} // '019f038d-943e-7ff2-a7bb-999474ec5a6a';

mkdir $scratch;

sub slurp {
	my ($path) = @_;
	return '' unless -f $path;
	open my $fh, '<', $path or return '';
	local $/; return <$fh>;
}

sub write_file {
	my ($name, $text) = @_;
	open my $fh, '>', "$scratch/$name" or die "write $name: $!\n";
	print $fh $text;
	close $fh;
}

sub wipe_scratch {
	opendir my $dh, $scratch or die "cannot open $scratch: $!\n";
	for my $ent (readdir $dh) {
		next if $ent eq '.' || $ent eq '..';
		my $path = "$scratch/$ent";
		unlink $path or rmdir $path or system('rm', '-rf', $path) == 0
			or die "cannot remove $path: $!\n";
	}
	closedir $dh;
}

sub run_cmd {
	my ($out, $err, @cmd) = @_;
	my $shell = join ' ', map { quotemeta($_) } ($bin, @cmd);
	if (defined $out) {
		system("$shell > $scratch/$out 2> $scratch/$err");
	} else {
		system("$shell 2> $scratch/$err >/dev/null");
	}
	return $? >> 8;
}

sub extract_field {
	my ($text, $field) = @_;
	my ($val) = $text =~ /$field[=\s:]+\s*(\d+)/;
	return $val // 0;
}

sub extract_cost_ticks {
	my ($text) = @_;
	my ($val) = $text =~ /cost_in_usd_ticks=(\d+)/;
	return $val // 0;
}

sub structure_keys {
	my ($text) = @_;
	my @keys;
	push @keys, 'query_header'   if $text =~ /=== Query \d+/;
	push @keys, 'usage_line'     if $text =~ /usage:.*total_tokens=/;
	push @keys, 'cost_ticks'     if $text =~ /cost_in_usd_ticks=/;
	push @keys, 'cost_usd'       if $text =~ /cost_usd=\$/;
	push @keys, 'limits_note'    if $text =~ /Rate limits \/ SuperGrok/;
	return join ',', sort @keys;
}

my %manifest = (
	generated_at => scalar localtime,
	scratch      => $scratch,
	plan_file    => '/home/todd/.grok/sessions/%2Fhome%2Ftodd/019f038d-943e-7ff2-a7bb-999474ec5a6a/goal/plan.md',
	steps        => {},
);

# Pre-wipe (verify-plan.out written by run-evidence.sh tee after this run starts)
my $guard_rc = system($guard);
ok($guard_rc == 0, 'plan step 0: scope-guard repos clean and in-scope only');
$manifest{steps}{step0_scope_guard} = { pass => $guard_rc == 0 ? 1 : 0 };

wipe_scratch();
system($guard);    # recreate scope-manifest.txt after wipe

# --- Plan verification step 1 ---
ok(-x $bin, 'plan step 1a: grok-sanity executable under git/sw/grokapi');
run_cmd('help.out', 'help.err', '--help');
my $help = slurp("$scratch/help.out");
my $step1 = $help =~ /keyinfo/
	&& $help =~ /\bquery\b/
	&& ($help =~ /\bsession\b/ || $help =~ /query\/session/)
	&& $help =~ /balance/;
ok($step1, 'plan step 1b: help lists keyinfo, query/session, optional management');
$manifest{steps}{step1_help} = {
	pass   => $step1 ? 1 : 0,
	files  => ['help.out'],
	assert => 'help lists keyinfo, query/session, balance (management optional)',
};

# --- Plan verification step 2 ---
my $step2 = 0;
if (-f $conf) {
	run_cmd('keyinfo.out', 'keyinfo.err', '-c', $conf, '-s', 'creds', '-a', 'keyinfo');
	my $ki = slurp("$scratch/keyinfo.out");
	$step2 = $ki =~ /team_id:/
		&& $ki =~ /acls:/
		&& $ki =~ /api_key_blocked:/
		&& ($ki =~ /redacted_api_key:/ || $ki =~ /api_key_id:/)
		&& $ki !~ /xai-[A-Za-z0-9]{30,}/;    # no full bearer in capture
	ok($step2, 'plan step 2: keyinfo has team_id, acls, redacted key, blocked flags');
	$manifest{steps}{step2_keyinfo} = { pass => $step2 ? 1 : 0, files => ['keyinfo.out'] };
} else {
	run_cmd('keyinfo.out', 'keyinfo.err', '-a', 'keyinfo');
	my $ki = slurp("$scratch/keyinfo.out") . slurp("$scratch/keyinfo.err");
	$step2 = $ki =~ /No bearer token/;
	ok($step2, 'plan step 2: keyinfo graceful when no bearer token');
	$manifest{steps}{step2_keyinfo} = { pass => $step2 ? 1 : 0, branch => 'no_config' };
}

# --- Plan verification step 3 ---
my $step3 = 0;
if (-f $conf) {
	run_cmd('query.out', 'query.err', '-c', $conf, '-s', 'creds', '-a', 'query', '-Q', "Say only 'hello'.");
	run_cmd('query2.out', 'query2.err', '-c', $conf, '-s', 'creds', '-a', 'query', '-Q', "Say only 'hello'.");
	my $q  = slurp("$scratch/query.out");
	my $q2 = slurp("$scratch/query2.out");
	my $q_tokens  = extract_field($q, 'total_tokens');
	my $q2_tokens = extract_field($q2, 'total_tokens');
	$step3 = $q_tokens > 0
		&& $q2_tokens > 0
		&& ($q =~ /cost_in_usd/ || $q =~ /\$0\./)
		&& ($q2 =~ /cost_in_usd/ || $q2 =~ /\$0\./)
		&& structure_keys($q) eq structure_keys($q2);
	ok($step3, 'plan step 3: query outputs have usage tokens>0, cost, consistent structure');
	$manifest{steps}{step3_query} = {
		pass  => $step3 ? 1 : 0,
		files => ['query.out', 'query2.out'],
	};
}

# --- Plan verification step 4 ---
my $step4 = 0;
if (-f $conf) {
	run_cmd('session.out', 'session.err', '-c', $conf, '-s', 'creds', '-a', 'session',
		'--queries', "Say only 'one'.", '--queries', "Say only 'two'.");
	my $s = slurp("$scratch/session.out");
	my $single_tokens = extract_field($s, 'total_tokens');    # first query line
	my ($session_tokens) = $s =~ /session_total:.*total_tokens=(\d+)/;
	my $single_cost  = extract_cost_ticks($s);
	my ($session_cost) = $s =~ /session_total:.*cost_in_usd_ticks=(\d+)/;
	$session_tokens //= 0;
	$session_cost   //= 0;
	# first query total_tokens on line 5 typically 149; session should be 298
	my ($first_q_tokens) = $s =~ /^usage:.*total_tokens=(\d+)/m;
	$first_q_tokens //= $single_tokens;
	$step4 = $session_tokens > $first_q_tokens
		&& $session_cost > 0
		&& $s =~ /session_total:.*total_cost|cost_in_usd_ticks/;
	ok($step4, 'plan step 4: session summary total_tokens and cost exceed single query');
	$manifest{steps}{step4_session} = { pass => $step4 ? 1 : 0, files => ['session.out'] };
}

# --- Plan verification step 5 ---
my $prove_rc = system("cd $root && prove -q t/*.t > $scratch/prove.out 2>&1");
my $prove_out = slurp("$scratch/prove.out");
my $step5_prove = $prove_rc == 0 && $prove_out =~ /Result: PASS/;
ok($step5_prove, 'plan step 5a: pure unit tests pass (prove)');

# Source audit: real API paths, not mocks
my @audit;
for my $file (qw(grok-sanity lib/GrokAPI/Stats.pm lib/GrokAPI/TeamContext.pm)) {
	my $path = "$root/$file";
	next unless -f $path;
	my $src = slurp($path);
	push @audit, "=== $file ===";
	push @audit, "  keyinfo path"       if $src =~ /keyinfo/;
	push @audit, "  query_grok path"    if $src =~ /query_grok/;
	push @audit, "  usage_from_response" if $src =~ /usage_from_response/;
	push @audit, "  NO hardcoded usage" if $src !~ /total_tokens\s*=>\s*\d{3,}/;
}
my $xai_api = slurp("$root/../xAI-API/lib/xAI/API.pm");
push @audit, "=== xAI/API.pm ===";
push @audit, "  prepaid_balance mgmt" if $xai_api =~ /prepaid_balance/;
push @audit, "  usage_analytics mgmt" if $xai_api =~ /usage_analytics/;
write_file('source-audit.out', join("\n", @audit, ''));

my $step5_audit = grep { /usage_from_response/ } @audit;
ok($step5_audit, 'plan step 5b: source drives real keyinfo/query usage extraction');

system("prove -v $Bin/quota-boundary.t > $scratch/quota-boundary.t.out 2>&1");
my $qb = slurp("$scratch/quota-boundary.t.out");
my $step5c = $qb =~ /Result: PASS/ && $qb =~ /documents SuperGrok/;
ok($step5c, 'plan step 5c: SuperGrok 90% quota documented as non-goal (no public API)');

$manifest{steps}{step5_unit_and_source} = {
	pass  => ($step5_prove && $step5_audit && $step5c) ? 1 : 0,
	files => ['prove.out', 'source-audit.out', 'quota-boundary.t.out'],
	supergrok_note => 'consumer 90% quota not in dev API; buildlog/signals are local Grok Build tracking',
};

# --- Plan verification step 6 ---
require Config::Tiny;
my $has_mgmt = defined $ENV{XAI_MANAGEMENT_API_KEY} && $ENV{XAI_MANAGEMENT_API_KEY} ne '';
if (!$has_mgmt && -f $conf) {
	my $ct = Config::Tiny->read($conf);
	$has_mgmt = defined $ct->{mgmt}{management_key} && $ct->{mgmt}{management_key} ne '';
}

my $step6 = 0;
if ($has_mgmt) {
	my $team = '';
	if (-f "$scratch/keyinfo.out") {
		($team) = slurp("$scratch/keyinfo.out") =~ /team_id:\s+(\S+)/;
	}
	run_cmd('balance.out', 'balance.err', '-a', 'balance', '-T', $team) if $team;
	my $bal = slurp("$scratch/balance.out");
	$step6 = $bal =~ /prepaid_total_cents:\s*-?\d+/;
	ok($step6, 'plan step 6 live: balance.out numeric prepaid total');
	$manifest{step6_branch} = 'live';
	$manifest{steps}{step6_balance} = { pass => $step6 ? 1 : 0, files => ['balance.out'] };
} else {
	run_cmd(undef, 'balance.err', '-a', 'balance');
	my $err = slurp("$scratch/balance.err");
	$step6 = $err =~ /No management key/
		&& !-f "$scratch/balance.out";
	ok($step6, 'plan step 6 graceful: balance.err requires management key (no mgmt key in config)');
	$manifest{step6_branch} = 'graceful';
	$manifest{mgmt_blocker} = 'Add [mgmt] management_key to ~/.config/cxai/grok.conf for live balance/usage/limits';
	$manifest{steps}{step6_balance} = {
		pass   => $step6 ? 1 : 0,
		files  => ['balance.err'],
		assert => 'graceful No management key; balance.out absent',
	};
}

# --- Plan verification step 7: buildlog ---
my $step7 = 0;
my $log_path = $ENV{HOME} . '/.grok/logs/unified.jsonl';
if (-f $log_path) {
	my $bl_rc = run_cmd('buildlog.out', 'buildlog.err', '-a', 'buildlog', '--current');
	if ($bl_rc != 0 || !-s "$scratch/buildlog.out") {
		$bl_rc = run_cmd('buildlog.out', 'buildlog.err', '-a', 'buildlog', '-S', $goal_sid);
	}
	my $bl = slurp("$scratch/buildlog.out");
	my ($turns) = $bl =~ /turns:\s+(\d+)/;
	my ($total) = $bl =~ /total_tokens=(\d+)/;
	$step7 = ($turns // 0) > 0 && ($total // 0) > 0;
	ok($step7, 'plan step 7: buildlog.out turns>0 total_tokens>0 from unified.jsonl');
	$manifest{steps}{step7_buildlog} = {
		pass  => $step7 ? 1 : 0,
		files => ['buildlog.out'],
		note  => 'Grok Build per-session tokens; not SuperGrok subscription %',
	};
} else {
	ok(0, 'plan step 7: buildlog (unified.jsonl missing)');
	$manifest{steps}{step7_buildlog} = { pass => 0, error => 'unified.jsonl not found' };
}

# --- Plan verification step 8: signals ---
my $step8 = 0;
my $sig_rc = run_cmd('signals.out', 'signals.err', '-a', 'signals', '--current');
if ($sig_rc != 0 || !-s "$scratch/signals.out") {
	$sig_rc = run_cmd('signals.out', 'signals.err', '-a', 'signals', '-S', $goal_sid);
}
my $sig = slurp("$scratch/signals.out");
$step8 = $sig =~ /contextWindowUsage:/
	|| $sig =~ /contextTokensUsed:/
	|| $sig =~ /Grok Build harness signals/;
ok($step8, 'plan step 8: signals.out harness context fields (not SuperGrok quota API)');
$manifest{steps}{step8_signals} = {
	pass  => $step8 ? 1 : 0,
	files => ['signals.out'],
	note  => 'SuperGrok 90% email quota: non-goal; see quota-boundary.t.out',
};

# Scope manifest for auditor
$manifest{repos_in_scope} = [
	'/home/todd/git/sw/grokapi',
	'/home/todd/git/sw/xAI-API',
];
$manifest{out_of_scope_changed_files} = [
	'.playground/state.json',
	'.grok/docs/user-guide/*.md',
	'.grok/active_sessions.json',
	'.config/cxai/grok.conf',
];
$manifest{live_api_status} = (-f $conf)
	? 'LIVE: inference bearer in ~/.config/cxai/grok.conf; keyinfo/query/session captures are real API responses'
	: 'NO_CONFIG: graceful fallback only';

open my $mf, '>', "$scratch/evidence-manifest.json" or die $!;
print $mf JSON::PP->new->pretty->canonical->encode(\%manifest);
close $mf;
ok(-f "$scratch/evidence-manifest.json", 'evidence-manifest.json written');

# Auto-generated verification.txt (not hand-written)
my @vtxt;
push @vtxt, "Verification generated: $manifest{generated_at}";
push @vtxt, "Runner: t/run-evidence.sh (captures verify-plan.out via tee)";
push @vtxt, "Scratch: $scratch";
push @vtxt, "";
push @vtxt, "Plan steps exercised:";
for my $key (sort keys %{$manifest{steps}}) {
	my $s = $manifest{steps}{$key};
	my $p = $s->{pass} ? 'PASS' : 'FAIL';
	push @vtxt, "  $key: $p";
}
push @vtxt, "";
push @vtxt, "Step 6 branch: $manifest{step6_branch}";
push @vtxt, $manifest{mgmt_blocker} if $manifest{mgmt_blocker};
push @vtxt, "";
push @vtxt, "SuperGrok 90% quota: NOT available via xAI developer API (non-goal).";
push @vtxt, "Grok Build tracking: buildlog.out + signals.out (local harness parse).";
push @vtxt, "Live API: $manifest{live_api_status}";
push @vtxt, "";
push @vtxt, "Out-of-scope (must NOT be in git commits): "
	. join(', ', @{$manifest{out_of_scope_changed_files}});
write_file('verification.txt', join("\n", @vtxt, ''));

done_testing();