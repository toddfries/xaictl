#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 6;

my $grokapi = '/home/todd/git/sw/grokapi';
my $xaiapi  = '/home/todd/git/sw/xAI-API';

sub ls_files {
	my ($repo) = @_;
	return split /\n/, `cd $repo && git ls-files 2>/dev/null`;
}

my @grok = ls_files($grokapi);
my @xai  = ls_files($xaiapi);

ok(grep { $_ eq 'grok-sanity' } @grok, 'grokapi repo has grok-sanity');
ok(grep { $_ eq 'lib/xAI/API.pm' } @xai, 'xAI-API repo has API.pm');

my @bad_paths = grep { /\.grok\/|\.playground\/|grok\.conf/ } @grok, @xai;
is(scalar @bad_paths, 0, 'no harness or grok.conf paths tracked in sw repos');

my $secret_hits = 0;
for my $repo ($grokapi, $xaiapi) {
	for my $f (ls_files($repo)) {
		open my $fh, '<', "$repo/$f" or next;
		local $/; my $body = <$fh>;
		close $fh;
		$secret_hits++ if $body =~ /xai-[A-Za-z0-9]{40,}/;
	}
}
is($secret_hits, 0, 'no full xAI bearer tokens in tracked git files');

my $scope_manifest = '/tmp/grok-goal-a7d760d85190/implementer/scope-manifest.txt';
if (-f $scope_manifest) {
	my $sm = do { open my $fh, '<', $scope_manifest; local $/; <$fh> };
	like($sm, qr/out_of_scope_paths/, 'scope-manifest documents out-of-scope CHANGED_FILES');
} else {
	pass('scope-manifest optional until evidence run');
}

done_testing();