#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 4;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use GrokAPI::Evidence::Redact;

my $class = 'GrokAPI::Evidence::Redact';
my $secret = 'bearer = xai-fake-inference-key-for-unit-test';
my $clean  = $class->redact_text($secret);

like($clean, qr/xai-\.\.\.REDACTED\.\.\./, 'redacts bearer assignment');
ok(!$class->has_secret($clean), 'redacted text has no secret');

my $mgmt = 'management_key = xai-fake-mgmt-key-for-unit-test';
$mgmt = $class->redact_text($mgmt);
like($mgmt, qr/management_key = xai-\.\.\.REDACTED\.\.\./, 'redacts management_key');

my $bare = $class->redact_text('token xai-fake-bare-token-for-unit-test');
ok(!$class->has_secret($bare), 'redacts bare token');

done_testing();