#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);
use JSON;
use File::Basename qw(dirname);

my $root    = "$Bin/..";
my $scratch = $ENV{GROK_GOAL_SCRATCH} // '/tmp/grok-goal-a7d760d85190/implementer';
my $bin     = "$root/grok-sanity";
my $conf    = $ENV{HOME} . '/.config/cxai/grok.conf';
my $guard   = "$Bin/scope-guard.sh";

mkdir $scratch;

sub slurp {
	my ($path) = @_;
	return '' unless -f $path;
	open my $fh, '<', $path or return '';
	local $/; return <$fh>;
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
	my $cmd = join ' ', map { quotemeta } $bin, @cmd;
	if (defined $out) {
		system("$cmd > $scratch/$out 2> $scratch/$err");
	} else {
		system("$cmd 2> $scratch/$err >/dev/null");
	}
	return $? >> 8;
}

my %manifest = (
	generated_at => scalar localtime,
	scratch      => $scratch,
	steps        => {},
);

# Step 0: scope guard (repos clean, no harness paths tracked)
my $guard_rc = system($guard);
ok($guard_rc == 0, 'step0 scope-guard');
$manifest{steps}{step0_scope_guard} = { pass => $guard_rc == 0 };

wipe_scratch();

# Step 1: help
ok(-x $bin, 'grok-sanity executable');
run_cmd('help.out', 'help.err', '--help');
my $help = slurp("$scratch/help.out");
my $step1 = $help =~ /keyinfo/
	&& $help =~ /\bquery\b/
	&& $help =~ /\bsession\b/
	&& $help =~ /balance/
	&& $help !~ /\bsessions\b/
	&& $help !~ /\bstatus\b/;
ok($step1, 'step1 help lists plan contract actions');
$manifest{steps}{step1_help} = {
	pass   => $step1,
	files  => ['help.out'],
	assert => 'keyinfo, query, session, balance; no sessions/status',
};

# Step 2: keyinfo
my $step2 = 0;
if (-f $conf) {
	run_cmd('keyinfo.out', 'keyinfo.err', '-c', $conf, '-s', 'creds', '-a', 'keyinfo');
	my $ki = slurp("$scratch/keyinfo.out");
	$step2 = $ki =~ /team_id:/
		&& $ki =~ /acls:/
		&& $ki =~ /api_key_blocked:/
		&& ($ki =~ /redacted_api_key:/ || $ki =~ /api_key_id:/);
	ok($step2, 'step2 keyinfo live');
	$manifest{steps}{step2_keyinfo} = { pass => $step2, files => ['keyinfo.out'] };
} else {
	run_cmd('keyinfo.out', 'keyinfo.err', '-a', 'keyinfo');
	my $ki = slurp("$scratch/keyinfo.out") . slurp("$scratch/keyinfo.err");
	$step2 = $ki =~ /No bearer token/;
	ok($step2, 'step2 keyinfo graceful');
	$manifest{steps}{step2_keyinfo} = { pass => $step2, branch => 'no_config' };
}

# Step 3: query (twice)
my $step3 = 0;
if (-f $conf) {
	run_cmd('query.out', 'query.err', '-c', $conf, '-s', 'creds', '-a', 'query', '-Q', "Say only 'hello'.");
	run_cmd('query2.out', 'query2.err', '-c', $conf, '-s', 'creds', '-a', 'query', '-Q', "Say only 'hello'.");
	my $q  = slurp("$scratch/query.out");
	my $q2 = slurp("$scratch/query2.out");
	$step3 = $q =~ /cost_in_usd_ticks=\d+/
		&& $q =~ /total_tokens=\d+/
		&& $q2 =~ /cost_in_usd_ticks=\d+/
		&& $q2 =~ /total_tokens=\d+/;
	ok($step3, 'step3 query usage');
	$manifest{steps}{step3_query} = {
		pass  => $step3,
		files => ['query.out', 'query2.out'],
	};
}

# Step 4: session
my $step4 = 0;
if (-f $conf) {
	run_cmd('session.out', 'session.err', '-c', $conf, '-s', 'creds', '-a', 'session',
		'--queries', "Say only 'one'.", '--queries', "Say only 'two'.");
	my $s = slurp("$scratch/session.out");
	$step4 = $s =~ /session_total:.*total_tokens=\d+/;
	ok($step4, 'step4 session totals');
	$manifest{steps}{step4_session} = { pass => $step4, files => ['session.out'] };
}

# Step 5: unit tests via prove
my $prove_rc = system("cd $root && prove -q t/*.t > $scratch/prove.out 2>&1");
my $prove_out = slurp("$scratch/prove.out");
my $step5 = $prove_rc == 0 && $prove_out =~ /Result: PASS/;
ok($step5, 'step5 prove all unit tests');
$manifest{steps}{step5_prove} = { pass => $step5, files => ['prove.out'] };

system("prove -v $Bin/quota-boundary.t > $scratch/quota-boundary.t.out 2>&1");
my $qb = slurp("$scratch/quota-boundary.t.out");
ok($qb =~ /ok\s+\d+\s+-\s+documents SuperGrok/, 'step5b quota-boundary');
$manifest{steps}{step5b_quota_boundary} = {
	pass  => ($qb =~ /Result: PASS/),
	files => ['quota-boundary.t.out'],
};

# Step 6: management branch
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
	ok($step6, 'step6 live balance.out');
	$manifest{step6_branch} = 'live';
	$manifest{steps}{step6_balance} = {
		pass  => $step6,
		files => ['balance.out'],
	};
} else {
	run_cmd(undef, 'balance.err', '-a', 'balance');
	my $err = slurp("$scratch/balance.err");
	$step6 = $err =~ /No management key/
		&& !-f "$scratch/balance.out";
	ok($step6, 'step6 graceful balance.err only');
	$manifest{step6_branch} = 'graceful';
	$manifest{steps}{step6_balance} = {
		pass   => $step6,
		files  => ['balance.err'],
		assert => 'No management key; balance.out absent',
	};
}

$manifest{repos_in_scope} = [
	'/home/todd/git/sw/grokapi',
	'/home/todd/git/sw/xAI-API',
];
$manifest{harness_out_of_scope} = [
	'.grok/active_sessions.json',
	'.grok/docs',
	'.playground/state.json',
];

open my $mf, '>', "$scratch/evidence-manifest.json" or die $!;
print $mf JSON::PP->new->pretty->canonical->encode(\%manifest);
close $mf;

ok(-f "$scratch/evidence-manifest.json", 'evidence-manifest.json written');

done_testing();