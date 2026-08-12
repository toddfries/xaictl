#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 4;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use xaictl::Config;

my $class = 'xaictl::Config';
local $ENV{XAI_API_KEY} = 'xai-test-inference-key-012345678901234567890';
local $ENV{XAI_MANAGEMENT_API_KEY} = 'xai-test-management-key-012345678901234567890';

is($class->bearer_token(config => {}), $ENV{XAI_API_KEY}, 'bearer from XAI_API_KEY env');
is($class->management_key(config => {}), $ENV{XAI_MANAGEMENT_API_KEY}, 'mgmt from XAI_MANAGEMENT_API_KEY env');

delete $ENV{XAI_API_KEY};
delete $ENV{XAI_MANAGEMENT_API_KEY};

is($class->bearer_token(config => { creds => { bearer => 'xai-from-config' } }),
	'xai-from-config', 'bearer falls back to config section');
is($class->management_key(config => { mgmt => { management_key => 'xai-mgmt-config' } }),
	'xai-mgmt-config', 'mgmt falls back to config section');

done_testing();