package GrokAPI::Harness::Signals;

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
	$signals //= {};
	my @out;
	push @out, '=== Grok Build harness signals ===';
	push @out, sprintf('session_id: %s', $args{session_id} // '(unknown)');
	push @out, sprintf('signals_file: %s', $args{path} // '(unknown)');
	for my $field (qw(
		turnCount contextWindowUsage contextTokensUsed contextWindowTokens
		sessionDurationSeconds primaryModelId
	)) {
		push @out, sprintf('%s: %s', $field, $signals->{$field} // '(undef)')
			if exists $signals->{$field};
	}
	push @out, '',
		'Note: contextWindowUsage is harness context-fill % (not SuperGrok consumer quota).',
		'SuperGrok subscription % (e.g. 90% email) has no public xAI API; check grok.com settings.',
		'Per-turn API tokens: grok-sanity -a buildlog --current',
		'';
	return join "\n", @out;
}

1;