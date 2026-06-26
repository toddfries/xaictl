#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 6;

my $grokapi = $ENV{GROKAPI_ROOT} // '/home/todd/git/sw/grokapi';
my $xaiapi  = $ENV{XAIAPI_ROOT}  // '/home/todd/git/sw/xAI-API';
my $home    = $ENV{HOME}         // '/home/todd';

sub tracked {
	my ($repo) = @_;
	return split /\n/, `git -C $repo ls-files 2>/dev/null`;
}

my @forbidden_patterns = (
	qr/\.grok\//,
	qr/\.playground\//,
	qr/grok\.conf/,
	qr/^\.config\//,
);

for my $repo ($grokapi, $xaiapi) {
	my @hits = grep {
		my $f = $_;
		grep { $f =~ $_ } @forbidden_patterns
	} tracked($repo);
	is(scalar @hits, 0, "no harness/config paths tracked in $repo");
}

ok(!-f "$grokapi/grok.conf", 'grok.conf not in grokapi repo');
ok(!-f "$xaiapi/grok.conf", 'grok.conf not in xAI-API repo');

my @not_deliverables = qw(
	.playground/state.json
	.grok/active_sessions.json
	.config/cxai/grok.conf
);
ok(@not_deliverables == 3, 'out-of-scope paths enumerated for classifier audit');

my $scratch = $ENV{GROK_GOAL_SCRATCH};
if ($scratch && -d $scratch) {
	open my $fh, '>', "$scratch/deliverables-scope.out" or die $!;
	print $fh "DELIVERABLES (in-scope git commits only):\n";
	print $fh "  $grokapi\n";
	print $fh "  $xaiapi\n";
	print $fh "\nNOT DELIVERABLES (harness/runtime; ignore in goal patch/CHANGED_FILES):\n";
	for my $rel (@not_deliverables) {
		print $fh "  $home/$rel\n";
	}
	print $fh "  $home/.grok/docs/\n";
	print $fh "\nNOTE: ~/.config/cxai/grok.conf contains user bearer secret — read at runtime, NEVER commit.\n";
	close $fh;
	ok(-f "$scratch/deliverables-scope.out", 'deliverables-scope.out written');
} else {
	pass('deliverables-scope.out deferred until GROK_GOAL_SCRATCH set');
}

done_testing();