#!/bin/bash
# Export XAI_* into the current shell only. Does not modify any file.
# verify-plan.pl never reads grok.conf — it requires these env vars for live steps.
set -euo pipefail

CONF="${GROK_CONF:-${HOME}/.config/cxai/grok.conf}"
[ -f "$CONF" ] || return 0

read_cred() {
	local section="$1" key="$2"
	perl -MConfig::Tiny -e '
		my ($path, $sec, $k) = @ARGV;
		my $c = Config::Tiny->read($path) or exit 0;
		my $v = $c->{$sec}{$k};
		print defined $v ? $v : "";
	' "$CONF" "$section" "$key" 2>/dev/null || true
}

if [ -z "${XAI_API_KEY:-}" ]; then
	val="$(read_cred creds bearer)"
	[ -n "$val" ] && export XAI_API_KEY="$val"
fi
if [ -z "${XAI_MANAGEMENT_API_KEY:-}" ]; then
	val="$(read_cred mgmt management_key)"
	[ -n "$val" ] && export XAI_MANAGEMENT_API_KEY="$val"
fi