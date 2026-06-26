#!/usr/bin/env perl

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use JSON;
use File::Find;

use FindBin qw($Bin);

my $home = $ENV{HOME} // '/home/todd';
my $out  = "$Bin/workspace-baseline.json";

my %baseline = (
	generated_at => scalar localtime,
	home         => $home,
	absent       => ['.config/cxai/grok.conf'],
	volatile     => [
		'.grok/active_sessions.json',
		'.playground/state.json',
	],
	files        => {},
);

sub sha_file {
	my ($path) = @_;
	open my $fh, '<', $path or return undef;
	local $/; my $data = <$fh>;
	close $fh;
	return sha256_hex($data // '');
}

my $myip = "$home/bin/myip";
$baseline{files}{'bin/myip'} = sha_file($myip) if -f $myip;

my $docs = "$home/.grok/docs";
if (-d $docs) {
	find(
		sub {
			return unless -f $_;
			my $abs = $File::Find::name;
			my $rel = $abs;
			$rel =~ s{\A\Q$home\E/?}{};
			$baseline{files}{$rel} = sha_file($abs);
		},
		$docs,
	);
}

open my $fh, '>', $out or die "write $out: $!\n";
print $fh JSON::PP->new->pretty->canonical->encode(\%baseline);
close $fh;
print "wrote $out (", scalar(keys %{$baseline{files}}), " file checksums)\n";