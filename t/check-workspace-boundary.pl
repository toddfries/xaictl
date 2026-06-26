#!/usr/bin/env perl

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use JSON;

use FindBin qw($Bin);

my $home     = $ENV{HOME} // '/home/todd';
my $baseline = "$Bin/workspace-baseline.json";
my $rules    = "$Bin/forbidden-workspace-paths.txt";

die "missing $baseline (run capture-workspace-baseline.pl)\n" unless -f $baseline;
open my $bf, '<', $baseline or die $!;
local $/; my $base = decode_json(<$bf>);
close $bf;

sub sha_file {
	my ($path) = @_;
	open my $fh, '<', $path or return undef;
	local $/; my $data = <$fh>;
	close $fh;
	return sha256_hex($data // '');
}

my @errors;

for my $rel (@{$base->{absent} // []}) {
	my $path = "$home/$rel";
	push @errors, "must be absent: $rel" if -e $path;
}

for my $rel (keys %{$base->{files} // {}}) {
	my $path = "$home/$rel";
	unless (-f $path) {
		push @errors, "missing baseline file: $rel";
		next;
	}
	my $got = sha_file($path);
	my $want = $base->{files}{$rel};
	push @errors, "checksum mismatch: $rel" if !defined $got || $got ne $want;
}

my $zhc = "$home/git/sw/zhc-research";
if (-d "$zhc/.git") {
	my $dirty = `git -C $zhc status --porcelain 2>/dev/null`;
	chomp $dirty;
	push @errors, "git/sw/zhc-research is dirty" if $dirty ne '';
}

if (@errors) {
	print STDERR "workspace-boundary: FAIL\n";
	print STDERR "  $_\n" for @errors;
	exit 1;
}

print "workspace-boundary: ok\n";
exit 0;