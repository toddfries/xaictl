package GrokAPI::Management::Report;

use strict;
use warnings;

our $VERSION = '0.01';

sub format_limits_note {
	return join "\n",
		'',
		'--- Rate limits / SuperGrok context ---',
		'Per-key QPS/QPM/TPM limits are set in console.x.ai (not returned by /api-key).',
		'SuperGrok/Grok Build consumer quotas (e.g. 90% usage emails) are NOT in this API.',
		'Grok Build per-session tokens: grok-sanity -a buildlog --current',
		'Grok Build context fill: grok-sanity -a signals --current',
		'Developer API spend: per-request cost_usd; team billing needs management key.',
		'API tier docs: https://docs.x.ai/developers/rate-limits',
		'';
}

sub format_balance {
	my ($class, %args) = @_;
	my $team_id = $args{team_id} // '';
	my $bal     = $args{balance} // {};
	my $prev    = $args{preview};

	my @out;
	push @out, "=== Prepaid balance (team $team_id) ===";
	if (defined $bal->{total}) {
		my $usd = _cents_to_usd($bal->{total});
		push @out, sprintf('prepaid_total_cents: %s', $bal->{total}{val} // '(undef)');
		push @out, sprintf('prepaid_total_usd:   $%.2f', $usd // 0);
	}
	if (defined $bal->{changes} && ref $bal->{changes} eq 'ARRAY') {
		my $shown = @{$bal->{changes}} > 5 ? 5 : @{$bal->{changes}};
		push @out, "recent_changes (up to $shown):";
		for my $i (0 .. $shown - 1) {
			my $ch = $bal->{changes}[$i];
			push @out, sprintf(
				'  %s %s cents=%s',
				$ch->{changeOrigin} // '?',
				$ch->{createTime} // '?',
				$ch->{amount}{val} // '?',
			);
		}
	}

	if (defined $prev && ref $prev eq 'HASH') {
		push @out, '', '=== Postpaid preview ===';
		if (defined $prev->{billingCycle}) {
			push @out, sprintf(
				'billing_cycle: %04d-%02d',
				$prev->{billingCycle}{year} // 0,
				$prev->{billingCycle}{month} // 0,
			);
		}
		push @out, sprintf(
			'effective_spending_limit_cents: %s',
			$prev->{effectiveSpendingLimit} // '(undef)',
		);
		my $invoice = $prev->{coreInvoice};
		if (defined $invoice && ref $invoice eq 'HASH') {
			if (defined $invoice->{prepaidCredits}) {
				push @out, sprintf(
					'prepaid_credits_usd: $%.2f',
					_cents_to_usd($invoice->{prepaidCredits}) // 0,
				);
			}
			if (defined $invoice->{prepaidCreditsUsed}) {
				push @out, sprintf(
					'prepaid_credits_used_usd: $%.2f',
					_cents_to_usd($invoice->{prepaidCreditsUsed}) // 0,
				);
			}
		}
	}

	push @out, $class->format_limits_note();
	return join "\n", @out;
}

sub format_usage {
	my ($class, %args) = @_;
	my $team_id = $args{team_id} // '';
	my $start   = $args{start}   // '';
	my $end     = $args{end}     // '';
	my $res     = $args{analytics} // {};

	my @out;
	push @out, "=== Usage analytics (team $team_id) ===";
	push @out, "period: $start to $end (UTC)";

	my $total_usd = 0;
	if (defined $res->{timeSeries} && ref $res->{timeSeries} eq 'ARRAY') {
		for my $series (@{$res->{timeSeries}}) {
			my $label = (defined $series->{group} && @{$series->{group}})
				? $series->{group}[0] : '(unknown)';
			my $sum = 0;
			if (defined $series->{dataPoints} && ref $series->{dataPoints} eq 'ARRAY') {
				for my $dp (@{$series->{dataPoints}}) {
					next unless defined $dp->{values} && ref $dp->{values} eq 'ARRAY';
					$sum += $dp->{values}[0] // 0;
				}
			}
			push @out, sprintf('  %-40s $%.6f', $label, $sum);
			$total_usd += $sum;
		}
	}
	push @out, sprintf('total_usd_this_period: $%.6f', $total_usd);
	push @out, $class->format_limits_note();
	return join "\n", @out;
}

sub format_limits {
	my ($class, %args) = @_;
	my $team_id = $args{team_id} // '';
	my $lim     = $args{limits} // {};

	my @out;
	push @out, "=== Spending limits (team $team_id) ===";
	my $sl = $lim->{spendingLimits} // {};
	for my $field (qw(softSl effectiveSl hardSlAuto effectiveHardSl hardSlOverride)) {
		next unless defined $sl->{$field};
		push @out, sprintf(
			'%-20s cents=%s usd=$%.2f',
			$field . ':',
			$sl->{$field}{val} // '?',
			_cents_to_usd($sl->{$field}) // 0,
		);
	}
	push @out, $class->format_limits_note();
	return join "\n", @out;
}

sub _cents_to_usd {
	my ($cents_obj) = @_;
	require xAI::API;
	return xAI::API->cents_val_to_usd($cents_obj);
}

1;