#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use xaictl::Kv;

my $bin = "$Bin/../xaictl";
ok(-x $bin, 'xaictl is executable');

my $help = `$bin --help 2>&1`;
like($help, qr/keyinfo/, 'help lists keyinfo');
like($help, qr/\bquery\b/, 'help lists query');
like($help, qr/\bsession\b/, 'help lists session');
like($help, qr/xai\.mgmt\.balance/, 'help lists management balance');
like($help, qr/xai\.credits/, 'help lists credits');
like($help, qr/-n, --no-name/, 'help lists -n');

my $list = `$bin -l 2>&1`;
for my $sec (qw(auth credits keyinfo balance usage limits buildlog signals query session history)) {
	like($list, qr/^\Q$sec\E$/m, "list includes $sec");
}

my $bad = `$bin not-a-real-section 2>&1`;
like($bad, qr/unknown selector/, 'unknown selector errors');
ok(($? >> 8) != 0, 'unknown selector is non-zero');

my $kv = xaictl::Kv->new;
$kv->kv('xai.credits.prepaid_balance_usd', '1.25');
$kv->kv('xai.credits.credit_usage_percent', '13');
$kv->kv('keyinfo.team_id', 'abc');
$kv->kv('xai.mgmt.balance.prepaid_total_usd', '2.00');
$kv->filter_prefixes('xai.credits', 'xai.mgmt.balance');
my $out = $kv->as_string();
like($out, qr/xai\.credits\.prepaid_balance_usd=1\.25/, 'keeps credits prefix');
like($out, qr/xai\.mgmt\.balance\.prepaid_total_usd=2\.00/, 'keeps mgmt prefix');
unlike($out, qr/keyinfo\.team_id=/, 'drops non-matching prefix');

my $nv = xaictl::Kv->new(no_name => 1);
$nv->kv('xai.credits.prepaid_balance_usd', '1.25');
$nv->kv('hw.power', '1');
my $nstr = $nv->as_string();
is($nstr, "1.25\n1\n", '-n prints values only, one per line');
unlike($nstr, qr/=/, '-n has no key= prefix');

done_testing();
