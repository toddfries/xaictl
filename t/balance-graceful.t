#!/usr/bin/env perl

use strict;
use warnings;
use File::Temp;
use Test::More tests => 6;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use GrokAPI::TeamContext;

my $bin = "$Bin/../grok-sanity";

# Isolate from user's ~/.config/cxai/grok.conf (may have [mgmt] key).
my $empty_conf = File::Temp->new(SUFFIX => '.conf');
print {$empty_conf} "; empty config for graceful-path tests\n";
close $empty_conf;

{
	local $ENV{XAI_MANAGEMENT_API_KEY} = '';
	local $ENV{XAI_API_KEY}            = '';
	my $no_mgmt = `$bin -a balance -T 00000000-0000-0000-0000-000000000001 -c $empty_conf 2>&1`;
	like($no_mgmt, qr/No management key/, 'balance without mgmt key is graceful (no live API call)');
}

# Invalid team_id rejected locally — never contacts management API.
eval {
	GrokAPI::TeamContext->team_id_for_mgmt(explicit => 'fake-team-id');
};
like($@, qr/invalid UUID/, 'invalid team_id blocked before management API');

eval { GrokAPI::TeamContext->team_id_for_mgmt() };
like($@, qr/team_id required/, 'team_id required when no -T and no bearer');

my $valid = '1d67d1a7-61bb-420a-a20d-6b18c314b98e';
is(
	GrokAPI::TeamContext->team_id_for_mgmt(explicit => $valid),
	$valid,
	'valid UUID team_id accepted',
);

my $help = `$bin --help 2>&1`;
like($help, qr/keyinfo/, 'help lists keyinfo');
like($help, qr/session/, 'help lists session');

done_testing();