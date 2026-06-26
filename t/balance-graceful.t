#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 2;

use FindBin qw($Bin);
my $bin = "$Bin/../grok-sanity";

my $missing = `$bin -a balance -T fake-team-id 2>&1`;
like($missing, qr/No management key/, 'balance without mgmt key is graceful');

my $help = `$bin --help 2>&1`;
like($help, qr/buildlog/, 'help lists buildlog action');

done_testing();