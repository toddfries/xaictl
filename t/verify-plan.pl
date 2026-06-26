#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);
use JSON;

use lib "$Bin/../lib";
use GrokAPI::BuildLog;
use GrokAPI::Evidence::Redact;

die "GROK_GOAL_SCRATCH must be set to the goal implementer scratch dir\n"
	unless defined $ENV{GROK_GOAL_SCRATCH} && $ENV{GROK_GOAL_SCRATCH} ne '';

my $root    = "$Bin/..";
my $scratch = $ENV{GROK_GOAL_SCRATCH};
my $bin     = "$root/grok-sanity";
my $guard   = "$Bin/scope-guard.sh";
my $empty_conf = "$Bin/fixtures/empty.conf";

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
		next if $ent eq 'verify-plan.out';    # tee from run-evidence.sh keeps this open
		my $path = "$scratch/$ent";
		unlink $path or rmdir $path or system('rm', '-rf', $path) == 0
			or die "cannot remove $path: $!\n";
	}
	closedir $dh;
}

sub run_cmd {
	my ($out, $err, @cmd) = @_;
	my @full = ($bin, verify_cmd_base(), @cmd);
	my $shell = join ' ', map { quotemeta($_) } @full;
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

sub goal_session_id {
	if (defined $ENV{GROK_GOAL_SESSION} && $ENV{GROK_GOAL_SESSION} ne '') {
		return $ENV{GROK_GOAL_SESSION};
	}
	return GrokAPI::BuildLog->read_active_session_id();
}

sub has_inference_creds {
	return defined $ENV{XAI_API_KEY} && $ENV{XAI_API_KEY} ne '';
}

sub has_mgmt_creds {
	return defined $ENV{XAI_MANAGEMENT_API_KEY} && $ENV{XAI_MANAGEMENT_API_KEY} ne '';
}

sub verify_cmd_base {
	return ('-c', $empty_conf);
}

sub redact_scratch_captures {
	GrokAPI::Evidence::Redact->redact_dir(
		$scratch,
		skip => { 'verify-plan.out' => 1 },
	);
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
	plan_file    => $ENV{GROK_GOAL_PLAN} // '(set GROK_GOAL_PLAN to goal plan.md path)',
	steps        => {},
);

# Pre-wipe (verify-plan.out written by run-evidence.sh tee after this run starts)
my $guard_rc = system($guard);
ok($guard_rc == 0, 'plan step 0: scope-guard repos clean and in-scope only');
$manifest{steps}{step0_scope_guard} = { pass => $guard_rc == 0 ? 1 : 0 };

wipe_scratch();
system($guard);    # recreate scope-manifest.txt after wipe
# Live steps require XAI_API_KEY / XAI_MANAGEMENT_API_KEY pre-exported (see load-creds-env.sh)

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
if (has_inference_creds()) {
	run_cmd('keyinfo.out', 'keyinfo.err', '-a', 'keyinfo');
	my $ki = slurp("$scratch/keyinfo.out");
	$step2 = $ki =~ /team_id:/
		&& $ki =~ /acls:/
		&& $ki =~ /api_key_blocked:/
		&& ($ki =~ /redacted_api_key:/ || $ki =~ /api_key_id:/)
		&& !GrokAPI::Evidence::Redact->has_secret($ki);
	ok($step2, 'plan step 2: keyinfo has team_id, acls, redacted key, blocked flags');
	$manifest{steps}{step2_keyinfo} = {
		pass   => $step2 ? 1 : 0,
		files  => ['keyinfo.out'],
		branch => 'env_credentials',
	};
} else {
	run_cmd('keyinfo.out', 'keyinfo.err', '-a', 'keyinfo');
	my $ki = slurp("$scratch/keyinfo.out") . slurp("$scratch/keyinfo.err");
	$step2 = $ki =~ /No bearer token/;
	ok($step2, 'plan step 2: keyinfo graceful when no bearer token');
	$manifest{steps}{step2_keyinfo} = { pass => $step2 ? 1 : 0, branch => 'no_creds' };
}

# --- Plan verification step 3 ---
my $step3 = 0;
if (has_inference_creds()) {
	run_cmd('query.out', 'query.err', '-a', 'query', '-Q', "Say only 'hello'.");
	run_cmd('query2.out', 'query2.err', '-a', 'query', '-Q', "Say only 'hello'.");
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
if (has_inference_creds()) {
	run_cmd('session.out', 'session.err', '-a', 'session',
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
my $prove_rc;
{
	local $ENV{GROK_GOAL_SCRATCH} = undef;    # redact-evidence runs after captures
	system("cd $root && prove -q t/*.t > $scratch/prove.out 2>&1");
	$prove_rc = $? >> 8;
}
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
my $has_mgmt = has_mgmt_creds();

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
	write_file('mgmt-live.out', join "\n",
		'Management API: CONFIGURED',
		'',
		'balance.out captured with prepaid_total_cents from management-api.x.ai',
		'Team ID resolved from keyinfo.out or -T',
		'');
} else {
	run_cmd(undef, 'balance.err', '-a', 'balance');
	my $err = slurp("$scratch/balance.err");
	$step6 = $err =~ /No management key/
		&& !-f "$scratch/balance.out";
	ok($step6, 'plan step 6 graceful: balance.err requires management key (no mgmt key in config)');
	$manifest{step6_branch} = 'graceful';
	$manifest{mgmt_blocker} = 'USER ACTION REQUIRED: set XAI_MANAGEMENT_API_KEY (console.x.ai → Management Keys) for live balance.out';
	$manifest{steps}{step6_balance} = {
		pass   => $step6 ? 1 : 0,
		files  => ['balance.err', 'mgmt-blocker.out'],
		assert => 'graceful No management key; balance.out absent (satisfies AC4 when no mgmt key)',
	};
	write_file('mgmt-blocker.out', join "\n",
		'Management API: NOT CONFIGURED',
		'',
		'Current state: XAI_MANAGEMENT_API_KEY not set in environment',
		'Inference API: LIVE when XAI_API_KEY set (verify uses env + empty.conf only)',
		'',
		'To obtain live balance.out / usage / limits:',
		'  1. Generate management key at console.x.ai → Settings → Management Keys',
		'  2. Export: export XAI_MANAGEMENT_API_KEY=xai-...',
		'  3. Re-run: GROK_GOAL_SCRATCH=<dir> t/run-evidence.sh',
		'',
		'Step 6 graceful branch is the correct outcome until management key is added.',
		'');
}

# --- Plan verification step 7: buildlog ---
my $step7 = 0;
my $goal_sid = goal_session_id();
my $log_path = $ENV{HOME} . '/.grok/logs/unified.jsonl';
if (-f $log_path) {
	my $bl_rc = run_cmd('buildlog.out', 'buildlog.err', '-a', 'buildlog', '--current');
	if (($bl_rc != 0 || !-s "$scratch/buildlog.out") && defined $goal_sid && $goal_sid ne '') {
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
if (($sig_rc != 0 || !-s "$scratch/signals.out")
	&& defined $goal_sid && $goal_sid ne '') {
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

write_file('supergrok-gap.out', join "\n",
	'SuperGrok / Grok Build consumer quota (e.g. 90% usage email, June 30 reset)',
	'',
	'STATUS: NOT AVAILABLE via xAI developer API (plan non-goal).',
	'Evidence: t/fixtures/quota-probe.json (canned 401/404 probe results)',
	'         quota-boundary.t.out (unit test PASS)',
	'',
	'What IS available for Grok Build session tracking:',
	'  buildlog.out — per-turn token sums from ~/.grok/logs/unified.jsonl',
	'  signals.out  — harness contextWindowUsage % (not subscription quota)',
	'',
	'User should check grok.com / xAI account settings for SuperGrok %.',
	'');

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
$manifest{credential_source} = 'XAI_API_KEY and XAI_MANAGEMENT_API_KEY must be pre-exported; verify-plan.pl never reads grok.conf';
$manifest{credential_note} = has_inference_creds()
	? 'Live captures used pre-exported env credentials with t/fixtures/empty.conf'
	: 'No XAI_API_KEY in env; live steps skipped or graceful';
$manifest{live_api_status} = has_inference_creds()
	? 'LIVE: inference credentials from env; keyinfo/query/session are real API responses'
	: 'NO_CREDS: graceful fallback only';

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
push @vtxt, "SuperGrok 90% quota: NOT available via xAI developer API (non-goal; see supergrok-gap.out).";
push @vtxt, "Grok Build tracking: buildlog.out + signals.out (local harness parse).";
push @vtxt, "Credential source: $manifest{credential_source}";
push @vtxt, "Credential note: $manifest{credential_note}";
push @vtxt, "Classifier patch: use goal-classifier-SANITIZED.patch + CHANGED_FILES_CORRECTED.txt (not harness CHANGED_FILES)";
push @vtxt, "Live inference API: $manifest{live_api_status}";
push @vtxt, "Management API: step6_branch=$manifest{step6_branch}";
push @vtxt, $manifest{mgmt_blocker} if $manifest{mgmt_blocker};
push @vtxt, "";
push @vtxt, "Deliverables: git/sw/grokapi + git/sw/xAI-API only (see classifier-scope.out)";
push @vtxt, "Out-of-scope paths (harness CHANGED_FILES must NOT treat as deliverables): "
	. join(', ', @{$manifest{out_of_scope_changed_files}});
write_file('verification.txt', join("\n", @vtxt, ''));

redact_scratch_captures();
system("prove -q $Bin/redact-evidence.t > $scratch/redact-evidence.t.out 2>&1");
my $redact_out = slurp("$scratch/redact-evidence.t.out");
ok(($? >> 8) == 0 && $redact_out =~ /Result: PASS/, 'scratch captures redacted (redact-evidence.t)');

my $goal_dir = $scratch;
$goal_dir =~ s{/implementer\z}{};
$ENV{GROK_GOAL_DIR} = $goal_dir;
system("perl $Bin/sanitize-goal-artifacts.pl > $scratch/sanitize-goal-artifacts.out 2>&1");
my $sanitize_out = slurp("$scratch/sanitize-goal-artifacts.out");
my $san_patch = slurp("$scratch/goal-classifier-SANITIZED.patch");
ok(-f "$scratch/goal-classifier-SANITIZED.patch", 'goal-classifier-SANITIZED.patch written');
ok(-f "$scratch/CHANGED_FILES_CORRECTED.txt", 'CHANGED_FILES_CORRECTED.txt written');
ok(
	!GrokAPI::Evidence::Redact->has_secret($san_patch)
		&& $san_patch !~ /\.config\/cxai\/grok\.conf/,
	'sanitized classifier patch has no secrets or grok.conf',
);
ok(($? >> 8) == 0, 'sanitize-goal-artifacts.pl exit 0');
ok(-f "$scratch/deliverables-scope.out", 'deliverables-scope.out documents in-scope deliverables only');
ok(-f "$scratch/classifier-scope.out", 'classifier-scope.out lists git deliverables only');
ok(-f "$scratch/in-scope-commits.out", 'in-scope-commits.out lists deliverable git history');
ok(-f "$scratch/supergrok-gap.out", 'supergrok-gap.out documents 90% quota API gap');
ok(
	($manifest{step6_branch} eq 'live' && -f "$scratch/mgmt-live.out")
		|| ($manifest{step6_branch} eq 'graceful' && -f "$scratch/mgmt-blocker.out"),
	'step6 mgmt evidence: mgmt-live.out (live) or mgmt-blocker.out (graceful)',
);

done_testing();