#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use GrokAPI::Evidence::Redact;

my $scratch = $ENV{GROK_GOAL_SCRATCH};
unless ($scratch && -d $scratch) {
	plan skip_all => 'GROK_GOAL_SCRATCH not set';
}

GrokAPI::Evidence::Redact->redact_dir(
	$scratch,
	skip => { 'verify-plan.out' => 1 },
);

opendir my $dh, $scratch or die $!;
my @files = grep {
	$_ ne '.' && $_ ne '..' && $_ ne 'verify-plan.out' && -f "$scratch/$_"
} readdir $dh;
closedir $dh;

plan tests => scalar @files + 1;

my $leaks = 0;
for my $f (sort @files) {
	my $path = "$scratch/$f";
	open my $fh, '<', $path or die $!;
	local $/; my $body = <$fh>;
	close $fh;
	next unless defined $body && $body ne '';
	$leaks++ if GrokAPI::Evidence::Redact->has_secret($body);
	ok(!GrokAPI::Evidence::Redact->has_secret($body), "no full bearer in $f");
}

ok($leaks == 0, 'scratch artifacts redacted');

done_testing();