#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 4;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use GrokAPI::Harness::Signals;

my $class = 'GrokAPI::Harness::Signals';
my $sid   = '019f038d-943e-7ff2-a7bb-999474ec5a6a';

my ($data, $path) = $class->read_signals($sid);
ok($data, 'reads current goal session signals');
ok($path && -f $path, 'signals path exists');

SKIP: {
	skip 'no signals file', 2 unless $data;
	ok(defined $data->{contextWindowUsage}, 'has contextWindowUsage');
	my $out = $class->format_report($data, session_id => $sid, path => $path);
	like($out, qr/contextWindowUsage:/, 'format includes usage percent');
}

done_testing();