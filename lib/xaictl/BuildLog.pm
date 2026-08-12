package xaictl::BuildLog;

use strict;
use warnings;
use JSON;

our $VERSION = '0.01';

sub default_log_path {
	return $ENV{HOME} . '/.grok/logs/unified.jsonl';
}

sub empty_totals {
	return {
		turn_count           => 0,
		prompt_tokens        => 0,
		completion_tokens    => 0,
		cached_prompt_tokens => 0,
		reasoning_tokens     => 0,
		total_tokens         => 0,
	};
}

sub accumulate_turn {
	my ($class, $totals, $ctx) = @_;
	$totals //= $class->empty_totals();
	return $totals unless defined $ctx && ref $ctx eq 'HASH';

	my $prompt     = $ctx->{prompt_tokens}        // 0;
	my $completion = $ctx->{completion_tokens}    // 0;
	my $cached     = $ctx->{cached_prompt_tokens} // 0;
	my $reasoning  = $ctx->{reasoning_tokens}     // 0;

	$totals->{turn_count}++;
	$totals->{prompt_tokens}        += $prompt;
	$totals->{completion_tokens}    += $completion;
	$totals->{cached_prompt_tokens} += $cached;
	$totals->{reasoning_tokens}     += $reasoning;
	$totals->{total_tokens}         += $prompt + $completion;
	return $totals;
}

sub parse_inference_line {
	my ($class, $line) = @_;
	return undef unless defined $line && $line =~ /\S/;
	my $obj = eval { decode_json($line) };
	return undef if $@ || ref $obj ne 'HASH';
	return undef unless ($obj->{msg} // '') eq 'shell.turn.inference_done';
	return undef unless defined $obj->{ctx} && ref $obj->{ctx} eq 'HASH';
	return {
		session_id => $obj->{sid},
		timestamp  => $obj->{ts},
		loop_index => $obj->{ctx}{loop_index},
		ctx        => $obj->{ctx},
	};
}

sub scan_log {
	my ($class, %args) = @_;
	my $path       = $args{log_path} // $class->default_log_path();
	my $session_id = $args{session_id};
	die "log file not found: $path\n" unless -f $path;

	my @turns;
	my $totals = $class->empty_totals();
	open my $fh, '<', $path or die "cannot read $path: $!\n";
	while (my $line = <$fh>) {
		my $rec = $class->parse_inference_line($line);
		next unless defined $rec;
		next if defined $session_id && $session_id ne '' && $rec->{session_id} ne $session_id;
		$class->accumulate_turn($totals, $rec->{ctx});
		push @turns, $rec;
	}
	close $fh;
	return (\@turns, $totals);
}

sub format_totals {
	my ($class, $totals, $prefix) = @_;
	$totals //= $class->empty_totals();
	$prefix //= 'xai.buildlog.totals';
	return join "\n",
		"$prefix.turns=" . ($totals->{turn_count} // 0),
		"$prefix.prompt_tokens=" . ($totals->{prompt_tokens} // 0),
		"$prefix.completion_tokens=" . ($totals->{completion_tokens} // 0),
		"$prefix.cached_prompt_tokens=" . ($totals->{cached_prompt_tokens} // 0),
		"$prefix.reasoning_tokens=" . ($totals->{reasoning_tokens} // 0),
		"$prefix.total_tokens=" . ($totals->{total_tokens} // 0),
		'';
}

sub emit_report {
	my ($class, $kv, %args) = @_;
	my $session_id = $args{session_id} // '';
	my $log_path   = $args{log_path}   // $class->default_log_path();
	my $turns      = $args{turns}      // [];
	my $totals     = $args{totals}     // $class->empty_totals();
	my $p          = $args{prefix}     // 'xai.buildlog';

	$kv->kv("$p.session_id", $session_id);
	$kv->kv("$p.log_file",   $log_path);
	$kv->kv("$p.turns",      scalar @{$turns});
	for my $i (0 .. $#{$turns}) {
		my $rec = $turns->[$i];
		my $ctx = $rec->{ctx} // {};
		my $tp  = "$p.turn.$i";
		$kv->kv("$tp.loop_index",          $ctx->{loop_index});
		$kv->kv("$tp.timestamp",           $rec->{timestamp});
		$kv->kv("$tp.prompt_tokens",       $ctx->{prompt_tokens});
		$kv->kv("$tp.completion_tokens",   $ctx->{completion_tokens});
		$kv->kv("$tp.cached_prompt_tokens",$ctx->{cached_prompt_tokens});
		$kv->kv("$tp.reasoning_tokens",    $ctx->{reasoning_tokens});
	}
	$kv->kv("$p.totals.turns",                 $totals->{turn_count});
	$kv->kv("$p.totals.prompt_tokens",         $totals->{prompt_tokens});
	$kv->kv("$p.totals.completion_tokens",     $totals->{completion_tokens});
	$kv->kv("$p.totals.cached_prompt_tokens",  $totals->{cached_prompt_tokens});
	$kv->kv("$p.totals.reasoning_tokens",      $totals->{reasoning_tokens});
	$kv->kv("$p.totals.total_tokens",          $totals->{total_tokens});
	return $kv;
}

sub read_active_session_id {
	my ($class) = @_;
	my $path = $ENV{HOME} . '/.grok/active_sessions.json';
	return undef unless -f $path;
	open my $fh, '<', $path or return undef;
	local $/; my $raw = <$fh>;
	close $fh;
	my $data = eval { decode_json($raw) };
	return undef if $@ || ref $data ne 'ARRAY' || !@{$data};
	return $data->[0]{session_id};
}

1;