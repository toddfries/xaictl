package xaictl::Management::Report;

use strict;
use warnings;

our $VERSION = '0.01';

sub format_limits_note {
	require xaictl::Kv;
	my $kv = xaictl::Kv->new;
	$_[0]->emit_limits_note($kv);
	return $kv->as_string();
}

sub emit_limits_note {
	my ($class, $kv) = @_;
	my $p = 'xai.note';
	$kv->kv("$p.rate_limits",
		'Per-key QPS/QPM/TPM limits are set in console.x.ai (not returned by /api-key).');
	$kv->kv("$p.supergrok",
		'SuperGrok/Grok Build consumer quotas (e.g. 90% usage emails) are NOT in this API.');
	$kv->kv("$p.buildlog",
		'Grok Build per-session tokens: xaictl xai.buildlog --current');
	$kv->kv("$p.signals",
		'Grok Build context fill: xaictl xai.signals --current');
	$kv->kv("$p.developer_spend",
		'Developer API spend: per-request cost_usd; team billing needs management key.');
	$kv->kv("$p.rate_limit_docs",
		'https://docs.x.ai/developers/rate-limits');
	return $kv;
}

sub format_balance {
	my ($class, %args) = @_;
	require xaictl::Kv;
	my $kv = xaictl::Kv->new;
	$class->emit_balance($kv, %args);
	return $kv->as_string();
}

sub emit_balance {
	my ($class, $kv, %args) = @_;
	my $team_id = $args{team_id} // '';
	my $bal     = $args{balance} // {};
	my $prev    = $args{preview};
	my $p       = $args{prefix} // 'xai.mgmt.balance';

	$kv->kv("$p.team_id", $team_id);
	if (defined $bal->{total}) {
		$kv->kv("$p.prepaid_total_cents", $bal->{total}{val});
		my $usd = _cents_to_usd($bal->{total});
		$kv->kv("$p.prepaid_total_usd", sprintf('%.2f', $usd // 0));
	}
	if (defined $bal->{changes} && ref $bal->{changes} eq 'ARRAY') {
		my $shown = @{$bal->{changes}} > 5 ? 5 : @{$bal->{changes}};
		$kv->kv("$p.changes.count", $shown);
		for my $i (0 .. $shown - 1) {
			my $ch = $bal->{changes}[$i];
			$kv->kv("$p.changes.$i.origin", $ch->{changeOrigin});
			$kv->kv("$p.changes.$i.create_time", $ch->{createTime});
			$kv->kv("$p.changes.$i.amount_cents",
				ref $ch->{amount} eq 'HASH' ? $ch->{amount}{val} : $ch->{amount});
		}
	}

	if (defined $prev && ref $prev eq 'HASH') {
		my $pp = 'xai.mgmt.preview';
		if (defined $prev->{billingCycle}) {
			$kv->kv("$pp.billing_cycle", sprintf('%04d-%02d',
				$prev->{billingCycle}{year} // 0,
				$prev->{billingCycle}{month} // 0,
			));
		}
		$kv->kv("$pp.effective_spending_limit_cents", $prev->{effectiveSpendingLimit});
		my $invoice = $prev->{coreInvoice};
		if (defined $invoice && ref $invoice eq 'HASH') {
			if (defined $invoice->{prepaidCredits}) {
				$kv->kv("$pp.prepaid_credits_usd",
					sprintf('%.2f', _cents_to_usd($invoice->{prepaidCredits}) // 0));
			}
			if (defined $invoice->{prepaidCreditsUsed}) {
				$kv->kv("$pp.prepaid_credits_used_usd",
					sprintf('%.2f', _cents_to_usd($invoice->{prepaidCreditsUsed}) // 0));
			}
		}
	}
	$class->emit_limits_note($kv) unless $args{no_note};
	return $kv;
}

sub format_usage {
	my ($class, %args) = @_;
	require xaictl::Kv;
	my $kv = xaictl::Kv->new;
	$class->emit_usage($kv, %args);
	return $kv->as_string();
}

sub emit_usage {
	my ($class, $kv, %args) = @_;
	my $team_id = $args{team_id} // '';
	my $start   = $args{start}   // '';
	my $end     = $args{end}     // '';
	my $res     = $args{analytics} // {};
	my $p       = $args{prefix} // 'xai.mgmt.usage';

	$kv->kv("$p.team_id", $team_id);
	$kv->kv("$p.period.start", $start);
	$kv->kv("$p.period.end", $end);
	$kv->kv("$p.period.timezone", 'Etc/GMT');

	my $total_usd = 0;
	my $n = 0;
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
			my $safe = $label;
			$safe =~ s/[^A-Za-z0-9_.-]+/_/g;
			$kv->kv("$p.series.$n.label", $label);
			$kv->kv("$p.series.$n.usd", sprintf('%.6f', $sum));
			$kv->kv("$p.series.$safe.usd", sprintf('%.6f', $sum));
			$total_usd += $sum;
			$n++;
		}
	}
	$kv->kv("$p.series.count", $n);
	$kv->kv("$p.total_usd", sprintf('%.6f', $total_usd));
	$class->emit_limits_note($kv) unless $args{no_note};
	return $kv;
}

sub format_limits {
	my ($class, %args) = @_;
	require xaictl::Kv;
	my $kv = xaictl::Kv->new;
	$class->emit_limits($kv, %args);
	return $kv->as_string();
}

sub emit_limits {
	my ($class, $kv, %args) = @_;
	my $team_id = $args{team_id} // '';
	my $lim     = $args{limits} // {};
	my $p       = $args{prefix} // 'xai.mgmt.limits';

	$kv->kv("$p.team_id", $team_id);
	my $sl = $lim->{spendingLimits} // {};
	for my $field (qw(softSl effectiveSl hardSlAuto effectiveHardSl hardSlOverride)) {
		next unless defined $sl->{$field};
		my $snake = $field;
		$snake =~ s/([A-Z])/_\L$1/g;
		$snake = lcfirst $snake;
		$kv->kv("$p.$snake.cents", $sl->{$field}{val});
		$kv->kv("$p.$snake.usd", sprintf('%.2f', _cents_to_usd($sl->{$field}) // 0));
	}
	$class->emit_limits_note($kv) unless $args{no_note};
	return $kv;
}

sub _cents_to_usd {
	my ($cents_obj) = @_;
	require xAI::API;
	return xAI::API->cents_val_to_usd($cents_obj);
}

1;