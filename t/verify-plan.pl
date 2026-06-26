#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);
my $root    = "$Bin/..";
my $scratch = $ENV{GROK_GOAL_SCRATCH} // '/tmp/grok-goal-a7d760d85190/implementer';
my $bin     = "$root/grok-sanity";
my $conf    = $ENV{HOME} . '/.config/cxai/grok.conf';

mkdir $scratch;

sub slurp {
	my ($path) = @_;
	open my $fh, '<', $path or return '';
	local $/; return <$fh>;
}

sub run_cmd {
	my ($out, $err, @cmd) = @_;
	system("$bin @cmd > $scratch/$out 2> $scratch/$err");
	return $? >> 8;
}

# Step 1
run_cmd('help.out', 'help.err', '--help');
my $help = slurp("$scratch/help.out");
ok($help =~ /keyinfo/ && $help =~ /session/ && $help =~ /balance/, 'step1 help');

# Step 2
if (-f $conf) {
	run_cmd('keyinfo.out', 'keyinfo.err', '-c', $conf, '-s', 'creds', '-a', 'keyinfo');
	my $ki = slurp("$scratch/keyinfo.out");
	ok($ki =~ /team_id:/ && $ki =~ /acls:/, 'step2 keyinfo live');
} else {
	run_cmd('keyinfo-missing.out', 'keyinfo-missing.err', '-a', 'keyinfo');
	ok(slurp("$scratch/keyinfo-missing.out") =~ /No bearer token/, 'step2 keyinfo graceful');
}

# Step 3
if (-f $conf) {
	run_cmd('query.out', 'query.err', '-c', $conf, '-s', 'creds', '-a', 'query', '-Q', "Say only 'hello'.");
	run_cmd('query2.out', 'query2.err', '-c', $conf, '-s', 'creds', '-a', 'query', '-Q', "Say only 'hello'.");
	my $q = slurp("$scratch/query.out");
	ok($q =~ /cost_in_usd_ticks=\d+/ && $q =~ /total_tokens=\d+/, 'step3 query usage');
}

# Step 4
if (-f $conf) {
	run_cmd('session.out', 'session.err', '-c', $conf, '-s', 'creds', '-a', 'session',
		'--queries', "Say only 'one'.", '--queries', "Say only 'two'.");
	my $s = slurp("$scratch/session.out");
	ok($s =~ /session_total:.*total_tokens=\d+/, 'step4 session totals');
}

# Step 6 management branch
require Config::Tiny;
my $has_mgmt = defined $ENV{XAI_MANAGEMENT_API_KEY} && $ENV{XAI_MANAGEMENT_API_KEY} ne '';
if (!$has_mgmt && -f $conf) {
	my $ct = Config::Tiny->read($conf);
	$has_mgmt = defined $ct->{mgmt}{management_key} && $ct->{mgmt}{management_key} ne '';
}
if ($has_mgmt) {
	my $team = '';
	if (-f "$scratch/keyinfo.out") {
		($team) = slurp("$scratch/keyinfo.out") =~ /team_id:\s+(\S+)/;
	}
	run_cmd('balance.out', 'balance.err', '-a', 'balance', '-T', $team) if $team;
	my $bal = slurp("$scratch/balance.out");
	ok($bal =~ /prepaid_total_cents:/, 'step6 live balance.out');
} else {
	run_cmd('balance.out', 'balance.err', '-a', 'balance', '-T', '00000000-0000-0000-0000-000000000001');
	my $err = slurp("$scratch/balance.err");
	ok($err =~ /No management key/, 'step6 graceful balance.err');
	unlink "$scratch/balance.out" if -f "$scratch/balance.out" && -z _;
}

done_testing();