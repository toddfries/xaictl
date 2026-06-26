package GrokAPI::Management::Probe;

use strict;
use warnings;
use JSON;

our $VERSION = '0.01';

# Catalog from https://docs.x.ai/developers/rest-api-reference/management
# method: GET = safe readonly probe; POST/PUT/DELETE listed for gap analysis only
sub endpoint_catalog {
	return {
		readonly => [
			{
				id       => 'mgmt_key_validation',
				method   => 'GET',
				path     => 'auth/management-keys/validation',
				needs_team => 0,
				category => 'auth',
			},
			{
				id       => 'list_api_keys',
				method   => 'GET',
				path     => 'auth/teams/{teamId}/api-keys',
				query    => 'pageSize=5',
				needs_team => 1,
				category => 'auth',
			},
			{
				id       => 'team_models',
				method   => 'GET',
				path     => 'auth/teams/{teamId}/models',
				needs_team => 1,
				category => 'auth',
			},
			{
				id       => 'team_endpoints',
				method   => 'GET',
				path     => 'auth/teams/{teamId}/endpoints',
				needs_team => 1,
				category => 'auth',
			},
			{
				id       => 'prepaid_balance',
				method   => 'GET',
				path     => 'v1/billing/teams/{teamId}/prepaid/balance',
				needs_team => 1,
				category => 'billing',
			},
			{
				id       => 'postpaid_preview',
				method   => 'GET',
				path     => 'v1/billing/teams/{teamId}/postpaid/invoice/preview',
				needs_team => 1,
				category => 'billing',
			},
			{
				id       => 'spending_limits',
				method   => 'GET',
				path     => 'v1/billing/teams/{teamId}/postpaid/spending-limits',
				needs_team => 1,
				category => 'billing',
			},
			{
				id       => 'billing_info',
				method   => 'GET',
				path     => 'v1/billing/teams/{teamId}/billing-info',
				needs_team => 1,
				category => 'billing',
			},
			{
				id       => 'payment_methods',
				method   => 'GET',
				path     => 'v1/billing/teams/{teamId}/payment-method',
				needs_team => 1,
				category => 'billing',
			},
			{
				id       => 'invoices',
				method   => 'GET',
				path     => 'v1/billing/teams/{teamId}/invoices',
				needs_team => 1,
				category => 'billing',
			},
			{
				id       => 'audit_events',
				method   => 'GET',
				path     => 'audit/teams/{teamId}/events',
				query    => 'pageSize=5',
				needs_team => 1,
				category => 'audit',
			},
			{
				id       => 'usage_analytics',
				method   => 'POST',
				path     => 'v1/billing/teams/{teamId}/usage',
				body     => sub {
					my ($class, %args) = @_;
					my ($y, $m) = _current_ym();
					return {
						analyticsRequest => {
							timeRange => {
								startTime => sprintf('%04d-%02d-01 00:00:00', $y, $m),
								endTime   => sprintf('%04d-%02d-28 23:59:59', $y, $m),
								timezone  => 'Etc/GMT',
							},
							timeUnit => 'TIME_UNIT_NONE',
							values   => [ { name => 'usd', aggregation => 'AGGREGATION_SUM' } ],
							groupBy  => ['description'],
							filters  => [],
						},
					};
				},
				needs_team => 1,
				category => 'billing',
				readonly_intent => 1,
			},
		],
		write_capable => [
			{ id => 'create_api_key',    method => 'POST',   path => 'auth/teams/{teamId}/api-keys', category => 'auth' },
			{ id => 'update_api_key',    method => 'PUT',    path => 'auth/api-keys/{apiKeyId}', category => 'auth' },
			{ id => 'delete_api_key',    method => 'DELETE', path => 'auth/api-keys/{apiKeyId}', category => 'auth' },
			{ id => 'rotate_api_key',    method => 'POST',   path => 'auth/api-keys/{apiKeyId}/rotate', category => 'auth' },
			{ id => 'set_billing_info',  method => 'POST',   path => 'v1/billing/teams/{teamId}/billing-info', category => 'billing' },
			{ id => 'prepaid_topup',     method => 'POST',   path => 'v1/billing/teams/{teamId}/prepaid/top-up', category => 'billing' },
			{ id => 'set_spending_limit',method => 'POST',   path => 'v1/billing/teams/{teamId}/postpaid/spending-limits', category => 'billing' },
			{ id => 'set_default_payment',method => 'POST',  path => 'v1/billing/teams/{teamId}/payment-method/default', category => 'billing' },
		],
	};
}

sub _current_ym {
	my ($sec, $min, $hour, $mday, $mon, $year) = localtime();
	return ($year + 1900, $mon + 1);
}

sub expand_path {
	my ($class, $path, $team_id) = @_;
	$path =~ s/\{teamId\}/$team_id/g if defined $team_id;
	return $path;
}

sub probe_readonly {
	my ($class, %args) = @_;
	my $api      = $args{api};
	my $team_id  = $args{team_id};
	my $catalog  = $class->endpoint_catalog();
	my @results;

	for my $ep (@{$catalog->{readonly}}) {
		next if $ep->{needs_team} && (!defined $team_id || $team_id eq '');
		my $path = $class->expand_path($ep->{path}, $team_id);
		$path .= '?' . $ep->{query} if $ep->{query};
		my $body;
		if ($ep->{body}) {
			$body = $ep->{body}->($class, team_id => $team_id);
		}
		my $res = $api->mgmt_request(
			$ep->{method},
			$path,
			$body,
		);
		push @results, {
			%{$ep},
			path    => $path,
			status  => $res->{status},
			ok      => $res->{ok} ? 1 : 0,
			summary => $class->summarize_response($ep->{id}, $res),
			error   => $res->{error},
		};
	}
	return \@results;
}

sub summarize_response {
	my ($class, $id, $res) = @_;
	return $res->{error} // 'request failed' unless $res->{ok};
	my $data = $res->{data} // {};

	if ($id eq 'mgmt_key_validation') {
		my @fields = grep { $_ !~ /token|key|secret/i } sort keys %{$data};
		return 'validation ok: ' . join(', ', map { "$_=" . (_short($data->{$_})) } @fields[0 .. ($#fields > 4 ? 4 : $#fields)]);
	}
	if ($id eq 'list_api_keys') {
		my $n = ref $data->{apiKeys} eq 'ARRAY' ? scalar @{$data->{apiKeys}} : 0;
		return "apiKeys=$n";
	}
	if ($id eq 'team_models') {
		my $n = 0;
		if (ref $data->{clusterConfigs} eq 'ARRAY') {
			for my $cc (@{$data->{clusterConfigs}}) {
				$n += scalar @{$cc->{languageModels} // []};
			}
		}
		return "language_models~$n clusters";
	}
	if ($id eq 'team_endpoints') {
		my $n = ref $data->{endpoints} eq 'ARRAY' ? scalar @{$data->{endpoints}} : 0;
		return "endpoints=$n";
	}
	if ($id eq 'prepaid_balance') {
		return 'total_cents=' . ($data->{total}{val} // '?');
	}
	if ($id eq 'audit_events') {
		my $n = ref $data->{events} eq 'ARRAY' ? scalar @{$data->{events}} : 0;
		return "events=$n";
	}
	if ($id eq 'usage_analytics') {
		my $n = ref $data->{timeSeries} eq 'ARRAY' ? scalar @{$data->{timeSeries}} : 0;
		return "timeSeries=$n";
	}
	if ($id eq 'payment_methods') {
		my $n = ref $data->{paymentMethods} eq 'ARRAY' ? scalar @{$data->{paymentMethods}} : 0;
		return "paymentMethods=$n";
	}
	if ($id eq 'invoices') {
		my $n = ref $data->{invoices} eq 'ARRAY' ? scalar @{$data->{invoices}} : 0;
		return "invoices=$n";
	}
	return 'ok';
}

sub _short {
	my ($v) = @_;
	return '(undef)' unless defined $v;
	return $v if !ref $v;
	return JSON::encode_json($v) if ref $v eq 'HASH' || ref $v eq 'ARRAY';
	return "$v";
}

sub format_report {
	my ($class, $results, %args) = @_;
	$results //= [];
	my $catalog = $class->endpoint_catalog();
	my @out;

	push @out, '=== Management API readonly probe ===';
	push @out, sprintf('team_id: %s', $args{team_id} // '(none)');
	push @out, sprintf('probed:  %s', scalar localtime);
	push @out, '';

	my ($ok_n, $deny_n, $err_n) = (0, 0, 0);
	for my $r (@{$results}) {
		my $flag = $r->{ok} ? 'OK' : ($r->{status} == 403 ? 'DENIED' : 'FAIL');
		$ok_n++   if $r->{ok};
		$deny_n++ if !$r->{ok} && ($r->{status} // 0) == 403;
		$err_n++  if !$r->{ok} && ($r->{status} // 0) != 403;
		push @out, sprintf(
			'%-22s %-4s %3s  %s',
			$r->{id}, $r->{method}, $r->{status} // '?', $r->{summary} // $r->{error} // '',
		);
	}

	push @out, '';
	push @out, sprintf('summary: %d ok, %d denied (403), %d other errors', $ok_n, $deny_n, $err_n);
	push @out, '';
	push @out, '=== Write-capable endpoints (NOT probed; need explicit write ACL) ===';
	for my $w (@{$catalog->{write_capable}}) {
		push @out, sprintf('  %-22s %-6s %s', $w->{id}, $w->{method}, $w->{path});
	}
	push @out, '';
	push @out, 'SuperGrok consumer quota (90% email) is NOT in Management API.';
	push @out, 'Grok Build tokens: grok-sanity -a buildlog --current';
	push @out, '';

	return join "\n", @out;
}

1;