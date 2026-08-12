package xaictl::Kv;

use strict;
use warnings;
use JSON::PP qw(encode_json);
use POSIX    qw(strftime floor);
use Time::Local qw(timegm);

our $VERSION = '0.01';

# Optional Date::Manip for pretty local timestamps (xai-status convention).
our $HAVE_DATE_MANIP = eval { require Date::Manip; Date::Manip->import(); 1 };

sub new {
	my ($class, %args) = @_;
	return bless {
		lines    => [],
		json_raw => $args{json_raw} ? 1 : 0,
	}, $class;
}

sub json_raw {
	my ($self, $on) = @_;
	$self->{json_raw} = $on ? 1 : 0 if defined $on;
	return $self->{json_raw};
}

sub lines {
	my ($self) = @_;
	return @{ $self->{lines} };
}

sub clear {
	my ($self) = @_;
	@{ $self->{lines} } = ();
	return $self;
}

sub kv {
	my ($self, $key, $val) = @_;
	return $self unless defined $key && $key ne '';
	return $self unless defined $val;
	if (JSON::PP::is_bool($val)) {
		$val = $val ? 'true' : 'false';
	} elsif (ref $val eq 'JSON::PP::Boolean') {
		$val = $$val ? 'true' : 'false';
	}
	$val = "$val";
	$val =~ s/\r//g;
	$val =~ s/\n/\\n/g;
	push @{ $self->{lines} }, "$key=$val";
	return $self;
}

sub kv_absent {
	my ($self, $key) = @_;
	push @{ $self->{lines} }, "$key=" if defined $key && $key ne '';
	return $self;
}

sub kv_bool {
	my ($self, $key, $val) = @_;
	return $self unless defined $val;
	if (JSON::PP::is_bool($val) || ref $val eq 'JSON::PP::Boolean') {
		return $self->kv($key, $val ? 'true' : 'false');
	}
	return $self->kv($key, $val ? 'true' : 'false');
}

sub emit_json_value {
	my ($self, $key, $val) = @_;
	return $self unless defined $val;
	if (JSON::PP::is_bool($val) || ref $val eq 'JSON::PP::Boolean') {
		return $self->kv($key, $val ? 'true' : 'false');
	}
	if (ref $val eq 'HASH') {
		for my $k (sort keys %$val) {
			$self->emit_json_value("$key.$k", $val->{$k});
		}
		return $self;
	}
	if (ref $val eq 'ARRAY') {
		$self->kv("$key.count", scalar @$val);
		for my $i (0 .. $#$val) {
			$self->emit_json_value("$key.$i", $val->[$i]);
		}
		return $self;
	}
	return $self->kv($key, $val);
}

sub dump_raw {
	my ($self, $prefix, $data) = @_;
	return $self unless $self->{json_raw} && defined $data;
	my $j = JSON::PP->new->canonical(1)->pretty(0)->utf8(0)->encode($data);
	$j =~ s/\n//g;
	return $self->kv("$prefix.json", $j);
}

sub as_string {
	my ($self) = @_;
	return join("\n", @{ $self->{lines} }, '');
}

sub print_all {
	my ($self) = @_;
	print $self->as_string();
	return $self;
}

sub filter_prefixes {
	my ($self, @prefixes) = @_;
	return $self unless @prefixes;
	my @keep;
	for my $line (@{ $self->{lines} }) {
		my ($k) = $line =~ /^([^=]+)=/;
		next unless defined $k;
		push @keep, $line if _key_matches($k, \@prefixes);
	}
	$self->{lines} = \@keep;
	return $self;
}

sub _key_matches {
	my ($key, $prefixes) = @_;
	for my $p (@{$prefixes}) {
		return 1 if $key eq $p;
		return 1 if index($key, $p . '.') == 0;
	}
	return 0;
}

# --- money / percent helpers (shared with proxy + mgmt) ---

sub cent_val {
	my ($class_or_self, $obj) = @_;
	return undef unless ref $obj eq 'HASH';
	return $obj->{val} if exists $obj->{val};
	return 0 if !%$obj;
	return undef;
}

sub cents_to_usd {
	my ($class_or_self, $cents, %opt) = @_;
	return undef unless defined $cents;
	my $v = ($opt{signed} ? $cents : abs($cents)) / 100.0;
	return sprintf('%.2f', $v);
}

sub remaining_pct {
	my ($class_or_self, $used_pct) = @_;
	return undef unless defined $used_pct;
	my $r = 100.0 - $used_pct;
	$r = 0 if $r < 0;
	$r = 100 if $r > 100;
	return $r;
}

sub floor_pct {
	my ($class_or_self, $p) = @_;
	return undef unless defined $p;
	return int(floor($p + 0));
}

# --- dates (xai-status convention) ---

my $LOCAL_TZ_NAME;

sub local_tz_name {
	return $LOCAL_TZ_NAME if defined $LOCAL_TZ_NAME;

	if (defined $ENV{TZ} && length $ENV{TZ} && $ENV{TZ} ne 'localtime') {
		my $tz = $ENV{TZ};
		$tz =~ s{^:}{};
		$tz =~ s{^.*/zoneinfo/}{};
		if ($tz !~ m{^/} && length $tz) {
			$LOCAL_TZ_NAME = $tz;
			return $LOCAL_TZ_NAME;
		}
	}

	if (-l '/etc/localtime') {
		my $target = readlink('/etc/localtime') // '';
		if ($target =~ m{(?:^|/)zoneinfo/(.+)$}) {
			$LOCAL_TZ_NAME = $1;
			return $LOCAL_TZ_NAME;
		}
	}

	$LOCAL_TZ_NAME = 'UTC';
	return $LOCAL_TZ_NAME;
}

sub parse_rfc3339 {
	my ($class_or_self, $s) = @_;
	return undef unless defined $s && length $s;

	if ($s =~ /^
		(\d{4})-(\d{2})-(\d{2})
		[T ]
		(\d{2}):(\d{2}):(\d{2})
		(?:\.\d+)?
		(?:Z|([+-])(\d{2}):?(\d{2}))?
		$/x
	) {
		my ($Y, $M, $D, $h, $m, $sec, $sign, $oh, $om) =
		  ($1, $2, $3, $4, $5, $6, $7, $8, $9);
		my $t = eval { timegm($sec, $m, $h, $D, $M - 1, $Y) };
		return undef unless defined $t;
		if (defined $sign) {
			my $off = ($oh // 0) * 3600 + ($om // 0) * 60;
			$t -= ($sign eq '+') ? $off : -$off;
		}
		return $t;
	}

	return undef unless $HAVE_DATE_MANIP;
	my $d = Date::Manip::Date->new;
	my $err = $d->parse($s);
	if ($err) {
		my $alt = $s;
		$alt =~ s/T/ /;
		$err = $d->parse($alt);
	}
	if (!$err) {
		my $sec = eval { $d->secs_since_1970_GMT() };
		return $sec if defined $sec && $sec =~ /^-?\d+$/;
	}
	return undef;
}

sub format_date_local_fast {
	my ($class_or_self, $s) = @_;
	return undef unless defined $s && length $s;
	my $ep = $class_or_self->parse_rfc3339($s);
	return undef unless defined $ep;
	my ($frac) = $s =~ /\.(\d+)/;
	$frac //= '0';
	my $ms = substr($frac . '000', 0, 3);
	my @lt = localtime($ep);
	my $body = strftime('%Y%m%d %H%M%S', @lt);
	my $as_utc = eval {
		timegm($lt[0], $lt[1], $lt[2], $lt[3], $lt[4], $lt[5] + 1900);
	};
	my $off = defined $as_utc ? ($as_utc - $ep) : 0;
	my $sign = $off >= 0 ? '+' : '-';
	$off = abs($off);
	my $oh = int($off / 3600);
	my $om = int(($off % 3600) / 60);
	return sprintf('%s.%s %s%02d:%02d', $body, $ms, $sign, $oh, $om);
}

sub format_date_local {
	my ($class_or_self, $s) = @_;
	return undef unless defined $s && length $s;
	if ($HAVE_DATE_MANIP) {
		my ($frac) = $s =~ /\.(\d+)/;
		$frac //= '0';
		my $ms = substr($frac . '000', 0, 3);
		my $d = Date::Manip::Date->new;
		my $err = $d->parse($s);
		if ($err) {
			my $alt = $s;
			$alt =~ s/T/ /;
			$err = $d->parse($alt);
		}
		if (!$err) {
			my $tz = local_tz_name();
			$d->convert($tz) if $tz ne 'UTC';
			my $ymd_hms = $d->printf('%Y%m%d %H%M%S');
			if (defined $ymd_hms && length $ymd_hms) {
				my $z = $d->printf('%z') // '+0000';
				my $zfmt = $z;
				if ($z =~ /^([+-])(\d{2})(\d{2})$/) {
					$zfmt = "$1$2:$3";
				} elsif ($z =~ /^([+-])(\d{2}):(\d{2})$/) {
					$zfmt = "$1$2:$3";
				} elsif ($z =~ /^([+-])(\d{2})$/) {
					$zfmt = "$1$2:00";
				}
				return "$ymd_hms.$ms $zfmt";
			}
		}
	}
	return $class_or_self->format_date_local_fast($s);
}

sub kv_date {
	my ($self, $key, $raw, %opt) = @_;
	return $self unless defined $raw && length $raw;
	$self->kv("$key.raw", $raw);
	my $local = $opt{fast}
	  ? $self->format_date_local_fast($raw)
	  : $self->format_date_local($raw);
	$local //= $self->format_date_local_fast($raw);
	$self->kv($key, defined $local ? $local : $raw);
	my $epoch = $self->parse_rfc3339($raw);
	$self->kv("$key.unix", $epoch) if defined $epoch;
	return $self;
}

1;
