package GrokAPI::Evidence::Redact;

use strict;
use warnings;

our $VERSION = '0.01';

sub redact_text {
	my ($class, $text) = @_;
	$text //= '';
	$text =~ s/(bearer\s*=\s*)xai-[A-Za-z0-9]+/$1xai-...REDACTED.../gi;
	$text =~ s/(management_key\s*=\s*)xai-[A-Za-z0-9]+/$1xai-...REDACTED.../gi;
	$text =~ s/(token\s*=\s*)xai-[A-Za-z0-9]+/$1xai-...REDACTED.../gi;
	$text =~ s/(api_key\s*=\s*)xai-[A-Za-z0-9]+/$1xai-...REDACTED.../gi;
	$text =~ s/xai-[A-Za-z0-9]{30,}/xai-...REDACTED.../g;
	return $text;
}

sub has_secret {
	my ($class, $text) = @_;
	return ($text // '') =~ /xai-[A-Za-z0-9]{30,}/;
}

sub redact_dir {
	my ($class, $dir, %opts) = @_;
	return 0 unless defined $dir && -d $dir;
	my $skip = $opts{skip} // { 'verify-plan.out' => 1 };
	my $count = 0;

	opendir my $dh, $dir or return 0;
	for my $ent (readdir $dh) {
		next if $ent eq '.' || $ent eq '..';
		next if $skip->{$ent};
		my $path = "$dir/$ent";
		next unless -f $path;
		next unless $ent =~ /\.(?:out|txt|json|conf)\z/;
		open my $fh, '<', $path or next;
		local $/; my $body = <$fh>;
		close $fh;
		next unless defined $body && $body ne '';
		my $clean = $class->redact_text($body);
		next if $clean eq $body;
		open my $wf, '>', $path or next;
		print $wf $clean;
		close $wf;
		$count++;
	}
	closedir $dh;
	return $count;
}

1;