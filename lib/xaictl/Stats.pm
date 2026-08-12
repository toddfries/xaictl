package xaictl::Stats;

use strict;
use warnings;

our $VERSION = '0.01';
our $COST_TICKS_PER_USD = 10_000_000_000;

sub empty_totals {
	return {
		prompt_tokens      => 0,
		completion_tokens  => 0,
		total_tokens       => 0,
		cost_in_usd_ticks  => 0,
		query_count        => 0,
	};
}

sub usage_from_response {
	my ($class, $res) = @_;
	return {} unless defined $res && ref $res eq 'HASH';
	my $usage = $res->{usage};
	return {} unless defined $usage && ref $usage eq 'HASH';

	my $prompt = $usage->{prompt_tokens};
	$prompt //= $usage->{input_tokens};
	my $completion = $usage->{completion_tokens};
	$completion //= $usage->{output_tokens};
	my $total = $usage->{total_tokens};
	if (!defined $total) {
		$total = ($prompt // 0) + ($completion // 0);
	}

	return {
		prompt_tokens     => $prompt // 0,
		completion_tokens => $completion // 0,
		total_tokens      => $total // 0,
		cost_in_usd_ticks => $usage->{cost_in_usd_ticks} // 0,
	};
}

sub accumulate {
	my ($class, $totals, $usage) = @_;
	$totals //= $class->empty_totals();
	$usage  //= {};
	for my $field (qw(prompt_tokens completion_tokens total_tokens cost_in_usd_ticks)) {
		$totals->{$field} += ($usage->{$field} // 0);
	}
	$totals->{query_count}++;
	return $totals;
}

sub ticks_to_usd {
	my ($class, $ticks) = @_;
	return 0 unless defined $ticks && $ticks =~ /^-?\d+$/;
	return $ticks / $COST_TICKS_PER_USD;
}

sub format_usage {
	my ($class, $usage, $prefix) = @_;
	$usage  //= {};
	$prefix //= 'usage';
	my $ticks = $usage->{cost_in_usd_ticks} // 0;
	my $usd   = $class->ticks_to_usd($ticks);
	return join "\n",
		"$prefix.prompt_tokens=" . ($usage->{prompt_tokens} // 0),
		"$prefix.completion_tokens=" . ($usage->{completion_tokens} // 0),
		"$prefix.total_tokens=" . ($usage->{total_tokens} // 0),
		"$prefix.cost_in_usd_ticks=$ticks",
		sprintf('%s.cost_usd=%.8f', $prefix, $usd),
		'';
}

sub format_totals {
	my ($class, $totals) = @_;
	return $class->format_usage($totals, 'session_total');
}

sub response_text {
	my ($class, $res) = @_;
	require xAI::API;
	return xAI::API->response_text($res);
}

1;