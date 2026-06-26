package GrokAPI::Evidence::Sanitize;

use strict;
use warnings;

use GrokAPI::Evidence::Redact;

our $VERSION = '0.01';

sub in_scope_path {
	my ($class, $path) = @_;
	return 0 unless defined $path && $path ne '';
	$path =~ s{\A(?:a|b)/}{};
	return $path =~ m{\Agit/sw/(?:grokapi|xAI-API)/};
}

sub filter_patch {
	my ($class, $patch) = @_;
	$patch //= '';
	return '' if $patch eq '';

	my @hunks;
	my $current = '';
	for my $line (split /\n/, $patch, -1) {
		if ($line =~ /^diff --git /) {
			push @hunks, $current if $current ne '';
			$current = $line;
		}
		elsif ($current ne '') {
			$current .= "\n$line";
		}
	}
	push @hunks, $current if $current ne '';

	my @kept;
	for my $hunk (@hunks) {
		my ($path) = $hunk =~ /^diff --git a\/(\S+)/;
		next unless defined $path && $class->in_scope_path($path);
		push @kept, $hunk;
	}

	my $out = join "\n", grep { $_ ne '' } @kept;
	$out .= "\n" if @kept && $out !~ /\n\z/;
	return GrokAPI::Evidence::Redact->redact_text($out);
}

sub patch_paths {
	my ($class, $patch) = @_;
	my @paths;
	for my $line (split /\n/, $patch // '') {
		next unless $line =~ /^diff --git a\/(\S+)/;
		push @paths, $1;
	}
	return @paths;
}

sub classify_patch_paths {
	my ($class, $patch) = @_;
	my %seen;
	my (@in_scope, @out_of_scope);
	for my $p ($class->patch_paths($patch)) {
		next if $seen{$p}++;
		if ($class->in_scope_path($p)) {
			push @in_scope, $p;
		} else {
			push @out_of_scope, $p;
		}
	}
	return (\@in_scope, \@out_of_scope);
}

sub find_latest_classifier_patch {
	my ($class, $goal_dir) = @_;
	return undef unless defined $goal_dir && -d $goal_dir;
	opendir my $dh, $goal_dir or return undef;
	my @patches = grep { /^goal-classifier-.*\.patch\z/ && !/SANITIZED/ } readdir $dh;
	closedir $dh;
	return undef unless @patches;
	@patches = sort @patches;
	return "$goal_dir/$patches[-1]";
}

sub git_deliverable_files {
	my ($class, %args) = @_;
	my @repos = @{$args{repos} // []};
	my @files;
	for my $repo (@repos) {
		next unless -d "$repo/.git";
		my $label = $repo =~ /xAI-API/ ? 'git/sw/xAI-API' : 'git/sw/grokapi';
		my @tracked = split /\n/, `git -C $repo ls-files 2>/dev/null`;
		for my $rel (@tracked) {
			next if $rel eq '';
			push @files, "$label/$rel";
		}
	}
	return sort @files;
}

1;