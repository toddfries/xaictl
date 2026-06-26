#!/usr/bin/env perl

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use GrokAPI::Evidence::Redact;
use GrokAPI::Evidence::Sanitize;

my $scratch = $ENV{GROK_GOAL_SCRATCH}
	or die "GROK_GOAL_SCRATCH required\n";

my $goal_dir = $ENV{GROK_GOAL_DIR};
if (!$goal_dir || !-d $goal_dir) {
	$goal_dir = $scratch;
	$goal_dir =~ s{/implementer\z}{};
}

my $grokapi = $ENV{GROKAPI_ROOT} // '/home/todd/git/sw/grokapi';
my $xaiapi  = $ENV{XAIAPI_ROOT}  // '/home/todd/git/sw/xAI-API';

my $class = 'GrokAPI::Evidence::Sanitize';

sub write_file {
	my ($name, $text) = @_;
	open my $fh, '>', "$scratch/$name" or die "write $name: $!\n";
	print $fh $text;
	close $fh;
}

my $patch_path = $class->find_latest_classifier_patch($goal_dir);
my $raw_patch  = '';
if ($patch_path && -f $patch_path) {
	open my $fh, '<', $patch_path or die "read $patch_path: $!\n";
	local $/; $raw_patch = <$fh> // '';
	close $fh;
}

my $sanitized = $class->filter_patch($raw_patch);
write_file('goal-classifier-SANITIZED.patch', $sanitized);

my ($in_scope, $out_scope) = $class->classify_patch_paths($raw_patch);
write_file('CHANGED_FILES_CORRECTED.txt', join("\n",
	'# Deliverable paths only (git/sw/grokapi + git/sw/xAI-API)',
	'',
	(map { "  $_" } @{$class->git_deliverable_files(repos => [$grokapi, $xaiapi])}),
	'',
	'# In-scope paths present in latest classifier patch:',
	(map { "  $_" } @{$in_scope}),
	'',
));

write_file('CHANGED_FILES_EXCLUDED.txt', join("\n",
	'# Out-of-scope paths in latest classifier patch (NOT deliverables):',
	'',
	(map { "  $_" } @{$out_scope}),
	'',
	'# User credential store (never a deliverable):',
	'  .config/cxai/grok.conf',
	'',
	'# Harness/runtime (never deliverables):',
	'  .playground/state.json',
	'  .grok/active_sessions.json',
	'  .grok/docs/',
	'',
));

my $has_secret = GrokAPI::Evidence::Redact->has_secret($sanitized);
my $has_oos    = grep { !$class->in_scope_path($_) } $class->patch_paths($sanitized);

write_file('sanitize-report.out', join "\n",
	"sanitize-goal-artifacts: " . ($has_secret ? 'FAIL secrets' : 'ok no secrets'),
	"sanitized patch bytes: " . length($sanitized),
	"sanitized paths: " . scalar($class->patch_paths($sanitized)),
	"out-of-scope in sanitized: $has_oos",
	"source patch: " . ($patch_path // '(none)'),
	'');

exit($has_secret || $has_oos ? 1 : 0);