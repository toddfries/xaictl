#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 4;

use FindBin qw($Bin);
my $bin = "$Bin/../grok-sanity";

my $no_mgmt = `$bin -a balance -T fake-team-id 2>&1`;
like($no_mgmt, qr/No management key/, 'balance without mgmt key is graceful');

my $no_team = `$bin -a balance -M fake-mgmt-key -c /dev/null 2>&1`;
like($no_team, qr/team_id required/, 'balance with mgmt but no -T and no bearer');

my $help = `$bin --help 2>&1`;
like($help, qr/keyinfo/, 'help lists keyinfo');
like($help, qr/session/, 'help lists session');

done_testing();