#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);

my @targets = grep { -f $_ } map { "$Bin/$_" } qw(
	verify-plan.pl
	run-evidence.sh
	scope-guard.sh
	check-workspace-boundary.pl
);

plan tests => scalar(@targets) * 4;

my @forbidden = (
	qr/Config::Tiny->read/,
	qr/load-creds/,
	qr/load-creds-env/,
);

for my $path (@targets) {
	open my $fh, '<', $path or die $!;
	local $/; my $body = <$fh>;
	close $fh;
	my $base = $path;
	$base =~ s{.*/}{};

	for my $pat (@forbidden) {
		my $hits = () = $body =~ /$pat/g;
		is($hits, 0, "$base has no $pat");
	}

	my $conf_hits = () = $body =~ /\Q$ENV{HOME}\E\/\.config\/cxai\/grok\.conf/g;
	is($conf_hits, 0, "$base does not reference user grok.conf path");
}

done_testing();