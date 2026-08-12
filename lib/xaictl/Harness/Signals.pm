package xaictl::Harness::Signals;

use strict;
use warnings;
use JSON;

our $VERSION = '0.01';

sub session_signals_path {
	my ($class, $session_id) = @_;
	die "session_id required\n" unless defined $session_id && $session_id ne '';
	my $root = $ENV{HOME} . '/.grok/sessions';
	my $target = "$session_id/signals.json";
	my @matches;
	$class->_find_signals($root, $target, \@matches);
	return $matches[0] if @matches == 1;
	return undef;
}

sub _find_signals {
	my ($class, $dir, $target_suffix, $matches) = @_;
	opendir my $dh, $dir or return;
	while (my $ent = readdir $dh) {
		next if $ent eq '.' || $ent eq '..';
		my $path = "$dir/$ent";
		if (-d $path) {
			$class->_find_signals($path, $target_suffix, $matches);
			next;
		}
		push @{$matches}, $path if $path =~ /\Q$target_suffix\E\z/;
	}
	closedir $dh;
}

sub read_signals {
	my ($class, $session_id) = @_;
	my $path = $class->session_signals_path($session_id);
	return (undef, undef) unless defined $path;
	open my $fh, '<', $path or die "cannot read $path: $!\n";
	local $/; my $raw = <$fh>;
	close $fh;
	my $data = decode_json($raw);
	die "signals.json parse error for $path\n" unless ref $data eq 'HASH';
	return ($data, $path);
}

sub format_report {
	my ($class, $signals, %args) = @_;
	require xaictl::Kv;
	my $kv = xaictl::Kv->new;
	$class->emit_report($kv, $signals, %args);
	return $kv->as_string();
}

sub emit_report {
	my ($class, $kv, $signals, %args) = @_;
	$signals //= {};
	my $p = $args{prefix} // 'xai.signals';
	$kv->kv("$p.session_id",    $args{session_id});
	$kv->kv("$p.signals_file",  $args{path});
	my %map = (
		turnCount              => 'turn_count',
		contextWindowUsage     => 'context_window_usage',
		contextTokensUsed      => 'context_tokens_used',
		contextWindowTokens    => 'context_window_tokens',
		sessionDurationSeconds => 'session_duration_secs',
		primaryModelId         => 'primary_model_id',
		toolCallCount          => 'tool_call_count',
		errorCount             => 'error_count',
		compactionCount        => 'compaction_count',
	);
	for my $src (sort keys %map) {
		next unless exists $signals->{$src};
		$kv->kv("$p.$map{$src}", $signals->{$src});
	}
	$kv->kv("$p.note",
		'context_window_usage is harness context-fill % (not SuperGrok consumer quota)');
	return $kv;
}

1;