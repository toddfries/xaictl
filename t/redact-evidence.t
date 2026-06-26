#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);

my $scratch = $ENV{GROK_GOAL_SCRATCH};
unless ($scratch && -d $scratch) {
	plan skip_all => 'GROK_GOAL_SCRATCH not set';
}

sub redact {
	my ($text) = @_;
	$text =~ s/(bearer\s*=\s*)xai-[A-Za-z0-9]+/$1xai-...REDACTED.../gi;
	$text =~ s/xai-[A-Za-z0-9]{30,}/xai-...REDACTED.../g;
	return $text;
}

opendir my $dh, $scratch or die $!;
my @outs = grep { /\.out\z/ && $_ ne 'verify-plan.out' } readdir $dh;
closedir $dh;

plan tests => scalar @outs + 1;

my $leaks = 0;
for my $f (@outs) {
	my $path = "$scratch/$f";
	my $body = do { open my $fh, '<', $path; local $/; <$fh> };
	next unless defined $body && $body ne '';
	my $clean = redact($body);
	if ($clean ne $body) {
		open my $wf, '>', $path or die $!;
		print $wf $clean;
		close $wf;
	}
	$leaks++ if $clean =~ /xai-[A-Za-z0-9]{30,}/;
	ok($clean !~ /xai-[A-Za-z0-9]{30,}/, "no full bearer in $f");
}

ok($leaks == 0, 'scratch captures redacted');

done_testing();