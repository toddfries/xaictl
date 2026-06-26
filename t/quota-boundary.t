#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use JSON;
use GrokAPI::Management::Report;

my $fixture_path = "$Bin/fixtures/quota-probe.json";
open my $fh, '<', $fixture_path or die "missing $fixture_path: $!\n";
local $/; my $raw = <$fh>;
close $fh;
my $probe = decode_json($raw);
ok(ref $probe eq 'HASH' && ref $probe->{endpoints} eq 'ARRAY', 'quota-probe fixture loads');
ok(@{$probe->{endpoints}} >= 5, 'fixture lists probed endpoints');

for my $ep (@{$probe->{endpoints}}) {
	my $status = $ep->{status};
	ok($status == 401 || $status == 404, "no consumer quota API at $ep->{url} ($status)");
}

my $note = GrokAPI::Management::Report->format_limits_note();
like($note, qr/SuperGrok/i, 'documents SuperGrok');
like($note, qr/90%/i, 'documents 90% email quota gap');
like($note, qr/NOT in this API/i, 'states quota not in dev API');
like($note, qr/buildlog/i, 'points to buildlog for Grok Build tokens');
like($note, qr/signals/i, 'points to signals for harness context');

done_testing();