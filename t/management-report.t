#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 6;

use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../../xAI-API/lib";

use GrokAPI::Management::Report;

my $class = 'GrokAPI::Management::Report';

my $balance = {
	total => { val => '-1000' },
	changes => [
		{
			changeOrigin => 'PURCHASE',
			createTime   => '2025-02-24T15:28:02Z',
			amount       => { val => '-1000' },
		},
	],
};

my $preview = {
	billingCycle => { year => 2025, month => 11 },
	effectiveSpendingLimit => '20000',
	coreInvoice => {
		prepaidCredits     => { val => '-4500' },
		prepaidCreditsUsed => { val => '0' },
	},
};

my $bal_out = $class->format_balance(
	team_id => '65c1e471-205f-4566-9c5a-07198bcdf4ce',
	balance => $balance,
	preview => $preview,
);
like($bal_out, qr/prepaid_total_cents: -1000/, 'balance cents');
like($bal_out, qr/prepaid_total_usd:\s+\$-10\.00/, 'balance usd');
like($bal_out, qr/recent_changes/, 'balance changes');

my $usage_out = $class->format_usage(
	team_id   => 'team-1',
	start     => '2026-06-01 00:00:00',
	end       => '2026-06-26 23:59:59',
	analytics => {
		timeSeries => [
			{
				group      => ['Chat grok-4-0709'],
				dataPoints => [ { values => [0.75973725] } ],
			},
		],
	},
);
like($usage_out, qr/Chat grok-4-0709/, 'usage label');
like($usage_out, qr/total_usd_this_period: \$0\.759737/, 'usage total');

my $lim_out = $class->format_limits(
	team_id => 'team-1',
	limits  => {
		spendingLimits => {
			softSl       => { val => '20000' },
			effectiveSl  => { val => '20000' },
		},
	},
);
like($lim_out, qr/softSl:.*usd=\$200\.00/, 'limits softSl');

# capture for verification step 5
my $scratch = $ENV{GROK_GOAL_SCRATCH} // '/tmp/grok-goal-a7d760d85190/implementer';
if (-d $scratch) {
	open my $fh, '>', "$scratch/management-report.t.out" or die $!;
	print $fh $bal_out, "\n---\n", $usage_out, "\n---\n", $lim_out;
	close $fh;
}

done_testing();