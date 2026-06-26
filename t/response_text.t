#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 2;

use FindBin qw($Bin);
use lib "$Bin/../../xAI-API/lib";

use xAI::API;

my $responses = {
	output => [
		{
			type    => 'message',
			content => [ { type => 'output_text', text => 'from output' } ],
		},
	],
};

is(xAI::API->response_text($responses), 'from output', 'responses API output text');

my $legacy = {
	choices => [ { message => { content => 'from choices' } } ],
};
is(xAI::API->response_text($legacy), 'from choices', 'chat completions choices text');

done_testing();