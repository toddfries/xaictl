#!/usr/bin/env perl

use strict;
use warnings;
use File::Temp;
use Test::More tests => 4;

use FindBin qw($Bin);
my $bin = "$Bin/../grok-sanity";

# Isolate from user's ~/.config/cxai/grok.conf (may have [mgmt] key).
my $empty_conf = File::Temp->new(SUFFIX => '.conf');
print {$empty_conf} "; empty config for graceful-path tests\n";
close $empty_conf;

{
	local $ENV{XAI_MANAGEMENT_API_KEY} = '';
	local $ENV{XAI_API_KEY}            = '';
	my $no_mgmt = `$bin -a balance -T fake-team-id -c $empty_conf 2>&1`;
	like($no_mgmt, qr/No management key/, 'balance without mgmt key is graceful');
}

{
	local $ENV{XAI_MANAGEMENT_API_KEY} = '';
	local $ENV{XAI_API_KEY}            = '';
	my $no_team = `$bin -a balance -M fake-mgmt-key -c $empty_conf 2>&1`;
	like($no_team, qr/team_id required/, 'balance with mgmt but no -T and no bearer');
}

my $help = `$bin --help 2>&1`;
like($help, qr/keyinfo/, 'help lists keyinfo');
like($help, qr/session/, 'help lists session');

done_testing();