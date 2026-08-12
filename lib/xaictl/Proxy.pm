package xaictl::Proxy;
# Extracted from xai-status.pl — cli-chat-proxy + OIDC dump helpers.

use strict;
use warnings;
use utf8;
use JSON::PP     qw(decode_json encode_json);
use LWP::UserAgent;
use HTTP::Request;
use POSIX        qw(strftime floor);
use Time::Local  qw(timegm);
use File::Spec;
use File::Basename qw(dirname);
use Fcntl        qw(:flock :seek);
use URI::Escape  qw(uri_escape);
use Date::Manip;
use xaictl::Kv;

# xai-status.pl — dump xAI / Grok Build account status in sysctl-like form.
#
# Mirrors the HTTP calls Grok Build makes via the cli-chat-proxy:
#   GET /v1/billing?format=credits   (GetGrokCreditsConfig — preferred)
#   GET /v1/billing                  (legacy GrokBuildBillingConfig)
#   GET /v1/auto-topup-rule          (GetAutoTopupRule)
#   GET /v1/user                     (profile / identity)
#   GET /v1/user?include=subscription
#   GET /v1/settings                 (remote flags + tier display)
#   GET /v1/models                   (available models)
#
# Auth: reads ~/.grok/auth.json (same store as `grok login`), uses the
# bearer token + user_id, and sends the same headers as xai-grok-shell.
#
# Token refresh (mirrors Grok's AuthManager::refresh_chain):
#   1. Advisory flock on auth.json.lock (same file Grok uses)
#   2. Re-read auth.json — if a sibling already refreshed, adopt it
#   3. OIDC discovery: GET {issuer}/.well-known/openid-configuration
#   4. POST token_endpoint  grant_type=refresh_token + client_id + RT
#   5. Write new access_token (+ rotated RT if any) back to auth.json
#   Grok does NOT keep tokens memory-only; successful refresh always
#   persists to disk so other Grok/Perl processes can share the session.
#
# Usage:
#   scripts/xai-status.pl              # all sections (auto-refresh if near expiry)
#   scripts/xai-status.pl -s billing   # one section (repeatable)
#   scripts/xai-status.pl --refresh    # force OIDC refresh, then dump status
#   scripts/xai-status.pl --no-refresh # never touch the IdP / auth.json
#   scripts/xai-status.pl -j           # also dump raw JSON per section
#   scripts/xai-status.pl -a PATH      # alternate auth.json
#   scripts/xai-status.pl -b URL       # alternate proxy base
#
# Env overrides:
#   GROK_HOME
#   GROK_PRODUCTION_CLI_CHAT_PROXY_BASE_URL
#   GROK_CLI_CHAT_PROXY_BASE_URL
#   XAI_STATUS_AUTH / GROK_AUTH_PATH
#
# Dates (Date::Manip → local TZ):
#   YYYYMMDD HHMMSS.<ms> ±HH:MM
#   plus key.raw (RFC3339) and key.unix (epoch)
#
# Docs:
#   scripts/xai-status.1       — mandoc manual
#   scripts/xai-status-api.md  — formal HTTP/OIDC API spec for other implementers

my $DEFAULT_PROXY = 'https://cli-chat-proxy.grok.com/v1';
my $TOKEN_HEADER  = 'xai-grok-cli';
my $CLIENT_MODE   = 'headless';
my $CLIENT_VER    = 'xaictl/1.0';
# Same 5-minute early-invalidation buffer as GrokAuth (DEFAULT_EARLY_INVALIDATION_SECS).
my $EARLY_INVALIDATION_SECS = 300;

my %SECTIONS = map { $_ => 1 } qw(
  auth user subscription billing credits legacy autotopup settings models history
);


# ===========================================================================
# Object API (used by xaictl). CLI lives in ../../xaictl.
# ===========================================================================

our $VERSION = '0.01';

# File-scoped state (original script used my $auth / $ua / ...).
our $auth;
our $ua;
our $grok_home;
our $proxy_base;
our $json_raw = 0;
our $history_max_sessions = 200;
our $KV;

sub new {
    my ($class, %opt) = @_;
    my $self = bless {
        kv        => $opt{kv} || xaictl::Kv->new,
        json_raw  => $opt{json_raw} ? 1 : 0,
        auth_path => $opt{auth_path},
        proxy_base=> $opt{proxy_base},
        timeout   => $opt{timeout} // 20,
        grok_home => $opt{grok_home},
        force_refresh => $opt{force_refresh} ? 1 : 0,
        no_refresh    => $opt{no_refresh} ? 1 : 0,
        history_max_sessions => $opt{history_max_sessions} // 200,
        auth => undef,
        scope => undef,
        ua => undef,
        refresh_info => undef,
        ready => 0,
    }, $class;
    $self->{kv}->json_raw($self->{json_raw});
    return $self;
}

sub kv_obj { $_[0]{kv} }

sub _bind {
    my ($self) = @_;
    $KV = $self->{kv};
    $json_raw = $self->{json_raw};
    $auth = $self->{auth};
    $ua = $self->{ua};
    $grok_home = $self->{grok_home};
    $proxy_base = $self->{proxy_base};
    $history_max_sessions = $self->{history_max_sessions};
}

sub prepare {
    my ($self) = @_;
    return $self if $self->{ready};

    $grok_home = $self->{grok_home}
      // $ENV{GROK_HOME}
      // File::Spec->catdir($ENV{HOME} // die("HOME unset\n"), '.grok');
    $self->{grok_home} = $grok_home;
    $self->{auth_path} //= $ENV{XAI_STATUS_AUTH}
      // $ENV{GROK_AUTH_PATH}
      // File::Spec->catfile($grok_home, 'auth.json');
    $self->{proxy_base} //= $ENV{GROK_CLI_CHAT_PROXY_BASE_URL}
      // $ENV{GROK_PRODUCTION_CLI_CHAT_PROXY_BASE_URL}
      // $DEFAULT_PROXY;
    $self->{proxy_base} =~ s{/*$}{};
    $proxy_base = $self->{proxy_base};

    my ($a, $scope) = load_auth($self->{auth_path});
    $self->{auth} = $a;
    $self->{scope} = $scope;
    $auth = $a;
    $self->{ua} = LWP::UserAgent->new(
        timeout => $self->{timeout},
        agent   => $CLIENT_VER,
        ssl_opts => { verify_hostname => 1 },
    );
    $ua = $self->{ua};
    $self->_bind();

    if (!$self->{no_refresh}) {
        my $need = $self->{force_refresh} || token_needs_refresh($auth);
        if ($need) {
            my $info = refresh_and_persist($self->{auth_path}, $scope, $auth);
            $self->{refresh_info} = $info;
            if ($info && $info->{ok} && $info->{auth}) {
                $self->{auth} = $info->{auth};
                $auth = $info->{auth};
            }
        }
    }
    $self->{ready} = 1;
    return $self;
}

sub dump_refresh {
    my ($self) = @_;
    $self->prepare();
    $self->_bind();
    kv('xai.date.format',   '%Y%m%d %H%M%S.<ms> ±HH:MM');
    kv('xai.date.local_tz', local_tz_name());
    emit_refresh_section($self->{refresh_info}, $self->{auth}, $self->{scope}, $self->{auth_path});
    return $self->{refresh_info};
}

sub dump_sections {
    my ($self, @sections) = @_;
    $self->prepare();
    $self->_bind();
    my %want = map { $_ => 1 } @sections;
    $want{credits} = 1 if $want{billing};
    $want{legacy}  = 1 if $want{billing};

    emit_auth_section($self->{auth}, $self->{scope}, $self->{auth_path}, $self->{proxy_base})
      if $want{auth};
    emit_refresh_section($self->{refresh_info}, $self->{auth}, $self->{scope}, $self->{auth_path})
      if $self->{refresh_info};

    my %done;
    for my $sec (@sections) {
        next if $sec eq 'auth' || $sec eq 'billing';
        next if $done{$sec}++;
        if ($sec eq 'user') {
            fetch_and_emit_user(0);
        } elsif ($sec eq 'subscription') {
            fetch_and_emit_user(1);
        } elsif ($sec eq 'credits') {
            fetch_and_emit_credits();
        } elsif ($sec eq 'legacy') {
            fetch_and_emit_legacy_billing();
        } elsif ($sec eq 'autotopup') {
            fetch_and_emit_autotopup();
        } elsif ($sec eq 'settings') {
            fetch_and_emit_settings();
        } elsif ($sec eq 'models') {
            fetch_and_emit_models();
        } elsif ($sec eq 'history') {
            emit_full_history_intel();
        }
    }
    return $self;
}

# ===========================================================================
# Auth load
# ===========================================================================
sub load_auth {
    my ($path) = @_;
    # Read raw octets: JSON::PP::decode_json expects UTF-8 bytes, not a
    # character-decoded string (names may contain emoji / non-ASCII).
    open my $fh, '<:raw', $path
      or die "cannot read auth.json at $path: $!\n"
        . "  (run `grok login` first, or pass -a PATH)\n";
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $store = decode_json($raw);
    die "auth.json is not an object\n" unless ref $store eq 'HASH';

    # Prefer non-legacy scopes; skip WebLogin (same as GrokAuth::lookup_auth).
    my ($best_scope, $best);
    for my $k (sort keys %$store) {
        my $a = $store->{$k};
        next unless ref $a eq 'HASH' && defined $a->{key} && length $a->{key};
        my $mode = $a->{auth_mode} // '';
        next if $mode eq 'web_login' || $mode eq 'grok';    # legacy WebLogin
        next if $k eq 'https://accounts.x.ai/sign-in';
        # Prefer OIDC/session scopes over bare API keys when both exist.
        my $score = 0;
        $score += 10 if ($a->{auth_mode} // '') =~ /oidc|oauth/i;
        $score += 5  if defined $a->{user_id} && length $a->{user_id};
        $score += 1  if $k =~ /auth\.x\.ai/;
        if (!$best || $score > ($best->{_score} // 0)) {
            $best = { %$a, _score => $score };
            $best_scope = $k;
        }
    }
    # Fall back to xai::api_key if that is all we have.
    if (!$best && $store->{'xai::api_key'} && ref $store->{'xai::api_key'} eq 'HASH') {
        $best = { %{ $store->{'xai::api_key'} }, _score => 0 };
        $best_scope = 'xai::api_key';
    }
    die "no usable credentials in $path\n" unless $best && $best->{key};
    delete $best->{_score};
    return ($best, $best_scope);
}

sub read_auth_store {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $store = eval { decode_json($raw) };
    return (ref $store eq 'HASH') ? $store : undef;
}

sub token_needs_refresh {
    my ($a) = @_;
    return 0 unless $a && $a->{refresh_token} && $a->{oidc_issuer} && $a->{oidc_client_id};
    my $exp = parse_rfc3339($a->{expires_at} // '');
    return 1 unless defined $exp;    # no expires_at → refresh to be safe for OIDC
    return 1 if time() >= ($exp - $EARLY_INVALIDATION_SECS);
    return 0;
}

sub token_is_hard_expired {
    my ($a) = @_;
    my $exp = parse_rfc3339($a->{expires_at} // '');
    return 0 unless defined $exp;
    return time() >= $exp;
}

# ---------------------------------------------------------------------------
# OIDC refresh — same protocol as xai-grok-shell auth/oidc/{protocol,refresh}.rs
# ---------------------------------------------------------------------------
sub refresh_and_persist {
    my ($path, $scope, $mem_auth) = @_;
    my $info = {
        ok      => 0,
        reason  => undef,
        adopted => 0,
        rotated_refresh_token => 0,
        token_endpoint => undef,
        auth    => undef,
    };

    unless ($mem_auth->{refresh_token} && $mem_auth->{oidc_issuer} && $mem_auth->{oidc_client_id}) {
        $info->{reason} = 'missing_refresh_fields';
        return $info;
    }

    my $lock_path = $path;
    $lock_path =~ s/auth\.json$/auth.json.lock/;
    if ($lock_path eq $path) {
        $lock_path = $path . '.lock';
    }

    # Exclusive lock across IdP call + write — matches Grok's AuthFileLock so
    # two processes never double-spend the same refresh token.
    open my $lock_fh, '>>', $lock_path
      or do {
        $info->{reason} = "lock_open_failed: $!";
        return $info;
      };
    chmod 0600, $lock_path;
    unless (flock($lock_fh, LOCK_EX)) {
        $info->{reason} = "lock_failed: $!";
        close $lock_fh;
        return $info;
    }

    # Re-read under lock: sibling Grok/Perl may already have refreshed.
    my $store = read_auth_store($path);
    if ($store && ref $store->{$scope} eq 'HASH') {
        my $disk = $store->{$scope};
        if (!token_is_hard_expired($disk)
            && defined $disk->{key}
            && $disk->{key} ne ($mem_auth->{key} // ''))
        {
            # Sibling already wrote a fresher access token — adopt, no IdP call.
            $info->{ok}      = 1;
            $info->{adopted} = 1;
            $info->{reason}  = 'adopted_sibling_disk_token';
            $info->{auth}    = { %$disk };
            flock($lock_fh, LOCK_UN);
            close $lock_fh;
            return $info;
        }
        # Prefer disk's refresh_token if it differs (sibling rotated RT).
        if (defined $disk->{refresh_token}
            && length $disk->{refresh_token}
            && $disk->{refresh_token} ne ($mem_auth->{refresh_token} // ''))
        {
            $mem_auth = { %$disk };
        } elsif (ref $disk eq 'HASH') {
            # Merge disk identity fields but keep our RT if same
            $mem_auth = { %$disk, %$mem_auth, refresh_token => ($disk->{refresh_token} // $mem_auth->{refresh_token}) };
        }
    }

    my $issuer = $mem_auth->{oidc_issuer};
    $issuer =~ s{/*$}{};
    my $discovery = oidc_discover($issuer);
    unless ($discovery && $discovery->{token_endpoint}) {
        $info->{reason} = 'discovery_failed';
        flock($lock_fh, LOCK_UN);
        close $lock_fh;
        return $info;
    }
    $info->{token_endpoint} = $discovery->{token_endpoint};

    my $tokens = oidc_refresh_tokens(
        $discovery->{token_endpoint},
        $mem_auth->{refresh_token},
        $mem_auth->{oidc_client_id},
        $mem_auth->{principal_type},
        $mem_auth->{principal_id},
    );
    unless ($tokens && $tokens->{access_token}) {
        $info->{reason} = $tokens && $tokens->{_error}
          ? $tokens->{_error}
          : 'token_exchange_failed';
        # invalid_grant: one more re-read — sibling may have rotated mid-flight
        if (($info->{reason} // '') =~ /invalid_grant/) {
            my $store2 = read_auth_store($path);
            if ($store2 && ref $store2->{$scope} eq 'HASH') {
                my $disk2 = $store2->{$scope};
                if (!token_is_hard_expired($disk2)
                    && defined $disk2->{key}
                    && $disk2->{key} ne ($mem_auth->{key} // ''))
                {
                    $info->{ok}      = 1;
                    $info->{adopted} = 1;
                    $info->{reason}  = 'adopted_sibling_after_invalid_grant';
                    $info->{auth}    = { %$disk2 };
                    flock($lock_fh, LOCK_UN);
                    close $lock_fh;
                    return $info;
                }
            }
        }
        flock($lock_fh, LOCK_UN);
        close $lock_fh;
        return $info;
    }

    my $new = { %$mem_auth };
    $new->{key}        = $tokens->{access_token};
    $new->{auth_mode}  = $mem_auth->{auth_mode} // 'oidc';
    $new->{create_time}= rfc3339_now();
    if (defined $tokens->{expires_in}) {
        $new->{expires_at} = rfc3339_from_epoch(time() + int($tokens->{expires_in}));
    }
    if (defined $tokens->{refresh_token} && length $tokens->{refresh_token}) {
        $info->{rotated_refresh_token} = 1
          if $tokens->{refresh_token} ne ($mem_auth->{refresh_token} // '');
        $new->{refresh_token} = $tokens->{refresh_token};
    }
    # else keep old RT (IdP did not rotate) — same as Grok build_grok_auth

    # Persist under the same lock
    $store = read_auth_store($path) // {};
    $store->{$scope} = $new;
    eval { write_auth_store($path, $store); 1 } or do {
        $info->{reason} = "persist_failed: $@";
        # Still hand back the fresh token for this process even if disk write failed
        $info->{auth} = $new;
        $info->{ok}   = 0;
        flock($lock_fh, LOCK_UN);
        close $lock_fh;
        return $info;
    };

    $info->{ok}     = 1;
    $info->{reason} = 'refreshed';
    $info->{auth}   = $new;
    flock($lock_fh, LOCK_UN);
    close $lock_fh;
    return $info;
}

sub oidc_discover {
    my ($issuer) = @_;
    my $url = $issuer . '/.well-known/openid-configuration';
    my $req = HTTP::Request->new(GET => $url);
    $req->header(Accept => 'application/json');
    my $res = $ua->request($req);
    return undef unless $res->is_success;
    my $data = eval { decode_json($res->content) };
    return (ref $data eq 'HASH') ? $data : undef;
}

sub oidc_refresh_tokens {
    my ($token_endpoint, $refresh_token, $client_id, $principal_type, $principal_id) = @_;
    my @pairs = (
        grant_type    => 'refresh_token',
        refresh_token => $refresh_token,
        client_id     => $client_id,
    );
    push @pairs, principal_type => $principal_type
      if defined $principal_type && length $principal_type;
    push @pairs, principal_id => $principal_id
      if defined $principal_id && length $principal_id;

    my $body = '';
    while (my ($k, $v) = splice @pairs, 0, 2) {
        $body .= '&' if length $body;
        $body .= uri_escape($k) . '=' . uri_escape($v);
    }

    my $req = HTTP::Request->new(POST => $token_endpoint);
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');
    $req->header(Accept         => 'application/json');
    $req->content($body);
    my $res = $ua->request($req);
    my $raw = $res->content // '';
    my $data = eval { decode_json($raw) };
    if (!$res->is_success) {
        my $code = (ref $data eq 'HASH' && $data->{error}) ? $data->{error} : ('http_' . $res->code);
        my $desc = (ref $data eq 'HASH') ? ($data->{error_description} // '') : '';
        return { _error => $code . ($desc ? ": $desc" : '') };
    }
    return (ref $data eq 'HASH') ? $data : { _error => 'bad_json' };
}

sub write_auth_store {
    my ($path, $store) = @_;
    my $json = JSON::PP->new->canonical(0)->pretty(1)->space_after(1)->utf8(1)->encode($store);
    # Atomic write: temp + rename (same idea as Grok write_auth_json_atomic)
    my $dir  = dirname($path);
    my $tmp  = File::Spec->catfile($dir, sprintf('auth.json.%d.tmp', $$));
    open my $fh, '>:raw', $tmp or die "write temp $tmp: $!";
    print {$fh} $json or die "write temp: $!";
    close $fh or die "close temp: $!";
    chmod 0600, $tmp;
    rename $tmp, $path or die "rename $tmp -> $path: $!";
}

sub rfc3339_now {
    return rfc3339_from_epoch(time());
}

sub rfc3339_from_epoch {
    my ($t) = @_;
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($t));
}

sub emit_refresh_section {
    my ($info, $a, $scope, $path) = @_;
    return unless $info;
    kv('xai.auth.refresh.ok',      $info->{ok} ? 'true' : 'false');
    kv('xai.auth.refresh.reason',  $info->{reason});
    kv('xai.auth.refresh.adopted_sibling', $info->{adopted} ? 'true' : 'false');
    kv('xai.auth.refresh.rotated_refresh_token',
       $info->{rotated_refresh_token} ? 'true' : 'false');
    kv('xai.auth.refresh.token_endpoint', $info->{token_endpoint});
    if ($info->{ok} && $a) {
        kv_date('xai.auth.refresh.new_expires_at', $a->{expires_at});
        if (defined $a->{expires_at}) {
            my $exp = parse_rfc3339($a->{expires_at});
            kv('xai.auth.refresh.new_expires_in_secs', $exp - time()) if defined $exp;
        }
        kv('xai.auth.refresh.persisted_to', $path);
        kv('xai.auth.refresh.scope', $scope);
    }
}

sub auth_headers {
    my %h = (
        'Authorization'         => 'Bearer ' . $auth->{key},
        'X-XAI-Token-Auth'      => $TOKEN_HEADER,
        'x-grok-client-version' => $CLIENT_VER,
        'x-grok-client-mode'    => $CLIENT_MODE,
        'Accept'                => 'application/json',
    );
    $h{'x-userid'} = $auth->{user_id} if defined $auth->{user_id} && length $auth->{user_id};
    $h{'x-email'}  = $auth->{email}   if defined $auth->{email}   && length $auth->{email};
    return %h;
}

sub http_get {
    my ($path) = @_;
    my $url = $proxy_base . $path;
    my $req = HTTP::Request->new(GET => $url);
    my %h   = auth_headers();
    $req->header($_ => $h{$_}) for keys %h;
    my $res = $ua->request($req);
    # Prefer raw bytes for JSON::PP; fall back to decoded_content.
    my $body = $res->content // '';
    my $data;
    if (length $body) {
        eval { $data = decode_json($body); 1 } or do {
            my $txt = eval { $res->decoded_content } // $body;
            eval { $data = decode_json($txt); 1 } or $data = undef;
        };
    }
    return {
        url    => $url,
        status => $res->code,
        ok     => $res->is_success,
        body   => $body,
        data   => $data,
        error  => $res->is_success ? undef : ($res->status_line // 'error'),
    };
}

# ===========================================================================
# Emit helpers (sysctl-style)
# ===========================================================================
sub kv {
    my ($key, $val) = @_;
    $KV->kv($key, $val) if $KV;
}

sub kv_absent {
    my ($key) = @_;
    $KV->kv_absent($key) if $KV;
}

sub cent_val {
    my ($obj) = @_;
    return undef unless ref $obj eq 'HASH';
    return $obj->{val} if exists $obj->{val};
    # proto3 may omit zero
    return 0 if !%$obj;
    return undef;
}

sub cents_to_usd {
    my ($cents, %opt) = @_;
    return undef unless defined $cents;
    # Billing stores some prepaid/top-up amounts as negative cents (ledger
    # convention). Default: absolute USD. Pass signed => 1 to keep the sign
    # (e.g. remaining allowance when over limit).
    my $v = ($opt{signed} ? $cents : abs($cents)) / 100.0;
    return sprintf('%.2f', $v);
}

sub remaining_pct {
    my ($used_pct) = @_;
    return undef unless defined $used_pct;
    my $r = 100.0 - $used_pct;
    $r = 0 if $r < 0;
    $r = 100 if $r > 100;
    return $r;
}

sub floor_pct {
    my ($p) = @_;
    return undef unless defined $p;
    # Match pager / SpendingLimiter: floor, so 99.994 → 99 until truly full.
    return int(floor($p + 0));
}

sub emit_auth_section {
    my ($a, $scope, $path, $base) = @_;
    # Date formatting convention for all timestamp fields in this dump.
    kv('xai.date.format',   '%Y%m%d %H%M%S.<ms> ±HH:MM');
    kv('xai.date.local_tz', local_tz_name());
    kv('xai.auth.file',             $path);
    kv('xai.auth.scope',            $scope);
    kv('xai.auth.mode',             $a->{auth_mode});
    kv('xai.auth.user_id',          $a->{user_id});
    kv('xai.auth.email',            $a->{email});
    kv('xai.auth.first_name',       $a->{first_name});
    kv('xai.auth.last_name',        $a->{last_name});
    kv('xai.auth.principal_type',   $a->{principal_type});
    kv('xai.auth.principal_id',     $a->{principal_id});
    kv('xai.auth.team_id',          $a->{team_id});
    kv('xai.auth.oidc_issuer',      $a->{oidc_issuer});
    kv('xai.auth.oidc_client_id',   $a->{oidc_client_id});
    kv_date('xai.auth.create_time', $a->{create_time});
    kv_date('xai.auth.expires_at',  $a->{expires_at});
    if (defined $a->{expires_at}) {
        my $exp = parse_rfc3339($a->{expires_at});
        if (defined $exp) {
            kv('xai.auth.expires_in_secs', $exp - time());
            kv('xai.auth.expired',         (time() >= $exp) ? 'true' : 'false');
        }
    }
    kv('xai.auth.coding_data_retention_opt_out',
       defined $a->{coding_data_retention_opt_out}
         ? ($a->{coding_data_retention_opt_out} ? 'true' : 'false')
         : undef);
    kv('xai.proxy.base_url', $base);
    # Never print the bearer / refresh tokens.
    kv('xai.auth.bearer_present',
       (defined $a->{key} && length $a->{key}) ? 'true' : 'false');
    kv('xai.auth.refresh_token_present',
       (defined $a->{refresh_token} && length $a->{refresh_token}) ? 'true' : 'false');
}

sub emit_http_meta {
    my ($prefix, $r) = @_;
    kv("$prefix.http.url",    $r->{url});
    kv("$prefix.http.status", $r->{status});
    kv("$prefix.http.ok",     $r->{ok} ? 'true' : 'false');
    if (!$r->{ok}) {
        my $detail = $r->{error} // '';
        if (ref $r->{data} eq 'HASH') {
            $detail = $r->{data}{error} // $r->{data}{message} // $detail;
        }
        kv("$prefix.http.error", $detail);
    }
}

sub dump_raw {
    my ($prefix, $data) = @_;
    return unless $json_raw && defined $data;
    my $j = JSON::PP->new->canonical(1)->pretty(0)->utf8(0)->encode($data);
    $j =~ s/\n//g;
    kv("$prefix.json", $j);
}

# ===========================================================================
# Sections
# ===========================================================================
sub fetch_and_emit_user {
    my ($with_sub) = @_;
    my $path = $with_sub ? '/user?include=subscription' : '/user';
    my $pfx  = $with_sub ? 'xai.subscription' : 'xai.user';
    my $r    = http_get($path);
    emit_http_meta($pfx, $r);
    dump_raw($pfx, $r->{data});
    return unless $r->{ok} && ref $r->{data} eq 'HASH';
    my $u = $r->{data};

    # camelCase from proxy
    for my $pair (
        [ userId                  => 'user_id' ],
        [ email                   => 'email' ],
        [ firstName               => 'first_name' ],
        [ lastName                => 'last_name' ],
        [ profileImageAssetId     => 'profile_image_asset_id' ],
        [ principalType           => 'principal_type' ],
        [ principalId             => 'principal_id' ],
        [ teamId                  => 'team_id' ],
        [ teamName                => 'team_name' ],
        [ teamRole                => 'team_role' ],
        [ organizationId          => 'organization_id' ],
        [ organizationName        => 'organization_name' ],
        [ organizationRole        => 'organization_role' ],
        [ organizationRbacRoleId  => 'organization_rbac_role_id' ],
        [ organizationType        => 'organization_type' ],
        [ userBlockedReason       => 'user_blocked_reason' ],
        [ hasGrokCodeAccess       => 'has_grok_code_access' ],
        [ codingDataRetentionOptOut => 'coding_data_retention_opt_out' ],
        [ subscriptionTier        => 'subscription_tier' ],
    ) {
        my ($src, $dst) = @$pair;
        my $v = $u->{$src};
        if (JSON::PP::is_bool($v) || ref $v eq 'JSON::PP::Boolean') {
            kv("$pfx.$dst", $v ? 'true' : 'false');
        } elsif (defined $v && !ref $v) {
            kv("$pfx.$dst", $v);
        } elsif (!defined $v) {
            # still useful for blocked reason etc.
            kv("$pfx.$dst", '') if $dst =~ /blocked|subscription/;
        }
    }
    if (ref $u->{teamBlockedReasons} eq 'ARRAY') {
        kv("$pfx.team_blocked_reasons.count", scalar @{ $u->{teamBlockedReasons} });
        kv("$pfx.team_blocked_reasons", join(',', @{ $u->{teamBlockedReasons} }));
    }
}

sub fetch_and_emit_credits {
    # Preferred path used by x.ai/billing extension.
    my $r = http_get('/billing?format=credits');
    my $pfx = 'xai.credits';
    emit_http_meta($pfx, $r);
    dump_raw($pfx, $r->{data});
    return unless $r->{ok} && ref $r->{data} eq 'HASH';
    my $cfg = $r->{data}{config};
    unless (ref $cfg eq 'HASH') {
        kv("$pfx.config", 'null');
        return;
    }

    my $pct = $cfg->{creditUsagePercent};
    kv("$pfx.credit_usage_percent",       $pct);
    kv("$pfx.credit_usage_percent_floor", floor_pct($pct));
    my $rem = remaining_pct($pct);
    kv("$pfx.credit_remaining_percent",   $rem);
    kv("$pfx.credit_remaining_percent_floor", floor_pct($rem));

    my $period = $cfg->{currentPeriod};
    if (ref $period eq 'HASH') {
        kv("$pfx.period.type",  $period->{type});
        kv_date("$pfx.period.start", $period->{start});
        kv_date("$pfx.period.end",   $period->{end});
        kv("$pfx.period.label", period_label($period->{type}));
        if (defined $period->{end}) {
            my $end_t = parse_rfc3339($period->{end});
            if (defined $end_t) {
                kv("$pfx.period.seconds_until_reset", $end_t - time());
            }
        }
    }

    my $prepaid = cent_val($cfg->{prepaidBalance});
    kv("$pfx.prepaid_balance_cents", $prepaid);
    kv("$pfx.prepaid_balance_usd",   cents_to_usd($prepaid));
    kv("$pfx.has_prepaid_credits",
       (defined $prepaid && abs($prepaid) > 0) ? 'true' : 'false');

    my $od_cap  = cent_val($cfg->{onDemandCap});
    my $od_used = cent_val($cfg->{onDemandUsed});
    kv("$pfx.on_demand_cap_cents",  $od_cap);
    kv("$pfx.on_demand_cap_usd",    cents_to_usd($od_cap));
    kv("$pfx.on_demand_used_cents", $od_used);
    kv("$pfx.on_demand_used_usd",   cents_to_usd($od_used));
    kv("$pfx.pay_as_you_go",
       (defined $od_cap && $od_cap > 0) ? 'true' : 'false');

    # effective usage: when included is exhausted and on-demand cap > 0,
    # show on-demand ratio; else the included percent (matches pager helper).
    if (defined $pct) {
        my $eff = $pct;
        if (defined $od_cap && $od_cap > 0 && $pct >= 100.0) {
            $eff = ($od_used // 0) / $od_cap * 100.0;
            $eff = 100 if $eff > 100;
        }
        kv("$pfx.effective_usage_percent", $eff);
        kv("$pfx.effective_usage_percent_floor", floor_pct($eff));
    }

    if (exists $cfg->{isUnifiedBillingUser}) {
        my $v = $cfg->{isUnifiedBillingUser};
        kv("$pfx.is_unified_billing_user",
           (JSON::PP::is_bool($v) ? ($v ? 'true' : 'false')
            : ($v ? 'true' : 'false')));
    }
    kv("$pfx.top_up_method", $cfg->{topUpMethod});
    kv_date("$pfx.billing_period_start", $cfg->{billingPeriodStart});
    kv_date("$pfx.billing_period_end",   $cfg->{billingPeriodEnd});

    # productUsage[] — per-product split (GrokBuild / GrokChat / …)
    if (ref $cfg->{productUsage} eq 'ARRAY') {
        my @pu = @{ $cfg->{productUsage} };
        kv("$pfx.product_usage.count", scalar @pu);
        for my $i (0 .. $#pu) {
            my $p = $pu[$i];
            next unless ref $p eq 'HASH';
            my $name = $p->{product} // "idx$i";
            my $safe = $name;
            $safe =~ s/[^A-Za-z0-9_]+/_/g;
            kv("$pfx.product_usage.$safe.product",       $p->{product});
            kv("$pfx.product_usage.$safe.usage_percent", $p->{usagePercent});
            kv("$pfx.product_usage.$safe.usage_percent_floor",
               floor_pct($p->{usagePercent}));
            kv("$pfx.product_usage.$safe.remaining_percent",
               remaining_pct($p->{usagePercent}));
            # also index form
            kv("$pfx.product_usage.$i.product",       $p->{product});
            kv("$pfx.product_usage.$i.usage_percent", $p->{usagePercent});
        }
    }

    # history (if present on credits shape)
    emit_history($pfx, $cfg->{history});

    # Human summary lines (what /usage shows)
    if (defined $pct) {
        kv("$pfx.summary.usage_line",
           sprintf('%s: %d%%', period_label($period->{type} // ''), floor_pct($pct)));
    }
    if (defined $prepaid && abs($prepaid) > 0) {
        kv("$pfx.summary.credits_line",
           sprintf('Credits: $%s', cents_to_usd($prepaid)));
    }
}

sub fetch_and_emit_legacy_billing {
    my $r = http_get('/billing');
    my $pfx = 'xai.billing_legacy';
    emit_http_meta($pfx, $r);
    dump_raw($pfx, $r->{data});
    return unless $r->{ok} && ref $r->{data} eq 'HASH';
    my $cfg = $r->{data}{config};
    unless (ref $cfg eq 'HASH') {
        kv("$pfx.config", 'null');
        return;
    }
    my $limit = cent_val($cfg->{monthlyLimit});
    my $used  = cent_val($cfg->{used});
    kv("$pfx.monthly_limit_cents", $limit);
    kv("$pfx.monthly_limit_usd",   cents_to_usd($limit));
    kv("$pfx.used_cents",          $used);
    kv("$pfx.used_usd",            cents_to_usd($used));
    if (defined $limit && $limit > 0 && defined $used) {
        my $pct = $used / $limit * 100.0;
        $pct = 100 if $pct > 100;
        kv("$pfx.usage_percent",       $pct);
        kv("$pfx.usage_percent_floor", floor_pct($pct));
        kv("$pfx.remaining_cents",     $limit - $used);
        kv("$pfx.remaining_usd",       cents_to_usd($limit - $used, signed => 1));
    }
    my $od_cap = cent_val($cfg->{onDemandCap});
    kv("$pfx.on_demand_cap_cents", $od_cap);
    kv("$pfx.on_demand_cap_usd",   cents_to_usd($od_cap));
    kv_date("$pfx.billing_period_start", $cfg->{billingPeriodStart});
    kv_date("$pfx.billing_period_end",   $cfg->{billingPeriodEnd});
    emit_history($pfx, $cfg->{history});
}

sub emit_history {
    my ($pfx, $hist) = @_;
    return unless ref $hist eq 'ARRAY';
    kv("$pfx.history.count", scalar @$hist);
    for my $i (0 .. $#$hist) {
        my $h = $hist->[$i];
        next unless ref $h eq 'HASH';
        my $hp = "$pfx.history.$i";
        if (ref $h->{billingCycle} eq 'HASH') {
            kv("$hp.year",  $h->{billingCycle}{year});
            kv("$hp.month", $h->{billingCycle}{month});
        }
        if (ref $h->{period} eq 'HASH') {
            kv("$hp.period.type",  $h->{period}{type});
            kv_date("$hp.period.start", $h->{period}{start});
            kv_date("$hp.period.end",   $h->{period}{end});
        }
        for my $f (qw(includedUsed onDemandUsed totalUsed)) {
            my $c = cent_val($h->{$f});
            next unless defined $c;
            my $snake = $f;
            $snake =~ s/([A-Z])/_\L$1/g;
            $snake = lcfirst $snake;
            kv("$hp.${snake}_cents", $c);
            kv("$hp.${snake}_usd",   cents_to_usd($c));
        }
    }
}

sub fetch_and_emit_autotopup {
    my $r = http_get('/auto-topup-rule');
    my $pfx = 'xai.autotopup';
    emit_http_meta($pfx, $r);
    dump_raw($pfx, $r->{data});
    return unless $r->{ok} && ref $r->{data} eq 'HASH';
    my $rule = $r->{data}{rule};
    if (!defined $rule) {
        kv("$pfx.present", 'false');
        return;
    }
    unless (ref $rule eq 'HASH') {
        kv("$pfx.present", 'false');
        return;
    }
    kv("$pfx.present", 'true');
    # proto3 omits false → treat missing enabled as false (shell does this).
    my $en = $rule->{enabled};
    if (!defined $en) {
        kv("$pfx.enabled", 'false');
    } elsif (JSON::PP::is_bool($en) || ref $en eq 'JSON::PP::Boolean') {
        kv("$pfx.enabled", $en ? 'true' : 'false');
    } else {
        kv("$pfx.enabled", $en ? 'true' : 'false');
    }
    my $min = cent_val($rule->{minBeforeHittingSl});
    my $amt = cent_val($rule->{topupAmount});
    my $max = cent_val($rule->{maxAmountPerMonth});
    kv("$pfx.min_before_hitting_sl_cents", $min);
    kv("$pfx.min_before_hitting_sl_usd",   cents_to_usd($min));
    kv("$pfx.topup_amount_cents",          $amt);
    kv("$pfx.topup_amount_usd",            cents_to_usd($amt));
    kv("$pfx.max_amount_per_month_cents",  $max);
    kv("$pfx.max_amount_per_month_usd",    cents_to_usd($max));
}

sub fetch_and_emit_settings {
    my $r = http_get('/settings');
    my $pfx = 'xai.settings';
    emit_http_meta($pfx, $r);
    dump_raw($pfx, $r->{data});
    return unless $r->{ok} && ref $r->{data} eq 'HASH';
    my $s = $r->{data};

    # High-signal account/status fields first (what the pager uses for tier /
    # billing UI), then dump everything else flattened.
    my @priority = qw(
      allow_access
      subscription_tier
      subscription_tier_display
      on_demand_enabled
      usage_billing_redirect_url
      gate_message
      gate_url
      gate_label
      default_model
      release_channel
      min_client_version
      force_update
      telemetry_enabled
      image_gen_enabled
      video_gen_enabled
      web_fetch_enabled
      voice_mode_enabled
      memory_enabled
      subagents_enabled
      dream_enabled
      goal_enabled
      privacy_notice_rollout
      coding_data_retention_opt_out
      disable_codebase_upload
      sharing_enabled
      strip_competitor_branding
    );
    my %seen;
    for my $k (@priority) {
        next unless exists $s->{$k};
        $seen{$k} = 1;
        emit_json_value("$pfx.$k", $s->{$k});
    }
    for my $k (sort keys %$s) {
        next if $seen{$k};
        # Skip bulky nested arrays in the default view unless -j was used
        # (raw JSON already dumped). Still emit counts.
        if (ref $s->{$k} eq 'ARRAY') {
            kv("$pfx.$k.count", scalar @{ $s->{$k} });
            # announcements: show ids + messages
            if ($k eq 'announcements') {
                for my $i (0 .. $#{ $s->{$k} }) {
                    my $a = $s->{$k}[$i];
                    next unless ref $a eq 'HASH';
                    kv("$pfx.$k.$i.id",       $a->{id});
                    kv("$pfx.$k.$i.severity", $a->{severity});
                    kv("$pfx.$k.$i.title",    $a->{title});
                    kv("$pfx.$k.$i.message",  $a->{message});
                }
            } elsif ($k eq 'campaigns') {
                for my $i (0 .. $#{ $s->{$k} }) {
                    my $c = $s->{$k}[$i];
                    next unless ref $c eq 'HASH';
                    kv("$pfx.$k.$i.id", $c->{id});
                }
            } elsif ($k eq 'tips') {
                # just count; tips are UX copy
            } else {
                # leave as count only
            }
            next;
        }
        if (ref $s->{$k} eq 'HASH') {
            emit_json_value("$pfx.$k", $s->{$k});
            next;
        }
        emit_json_value("$pfx.$k", $s->{$k});
    }
}

sub fetch_and_emit_models {
    my $r = http_get('/models');
    my $pfx = 'xai.models';
    emit_http_meta($pfx, $r);
    dump_raw($pfx, $r->{data});
    return unless $r->{ok} && ref $r->{data} eq 'HASH';
    my $data = $r->{data}{data};
    return unless ref $data eq 'ARRAY';
    kv("$pfx.count", scalar @$data);
    for my $i (0 .. $#$data) {
        my $m = $data->[$i];
        next unless ref $m eq 'HASH';
        my $id = $m->{id} // $m->{model} // $i;
        my $safe = $id;
        $safe =~ s/[^A-Za-z0-9_.-]+/_/g;
        my $mp = "$pfx.$safe";
        for my $f (qw(
            id model name description object owned_by context_window
            auto_compact_threshold_percent system_prompt_label api_backend
            reasoning_effort supports_reasoning_effort supports_backend_search
            compactions_remaining compaction_at_tokens
        )) {
            next unless exists $m->{$f};
            emit_json_value("$mp.$f", $m->{$f});
        }
        if (ref $m->{reasoning_efforts} eq 'ARRAY') {
            kv("$mp.reasoning_efforts.count", scalar @{ $m->{reasoning_efforts} });
            for my $j (0 .. $#{ $m->{reasoning_efforts} }) {
                my $re = $m->{reasoning_efforts}[$j];
                next unless ref $re eq 'HASH';
                kv("$mp.reasoning_efforts.$j.id",    $re->{id});
                kv("$mp.reasoning_efforts.$j.label", $re->{label});
                kv("$mp.reasoning_efforts.$j.default",
                   ($re->{default} ? 'true' : 'false')) if exists $re->{default};
            }
        }
    }
}

sub emit_json_value {
    my ($key, $val) = @_;
    return if !defined $val;
    if (JSON::PP::is_bool($val) || ref $val eq 'JSON::PP::Boolean') {
        kv($key, $val ? 'true' : 'false');
    } elsif (ref $val eq 'HASH') {
        for my $k (sort keys %$val) {
            emit_json_value("$key.$k", $val->{$k});
        }
    } elsif (ref $val eq 'ARRAY') {
        kv("$key.count", scalar @$val);
        for my $i (0 .. $#$val) {
            emit_json_value("$key.$i", $val->[$i]);
        }
    } else {
        kv($key, $val);
    }
}

sub period_label {
    my ($t) = @_;
    $t //= '';
    return 'Weekly limit'  if $t =~ /WEEKLY/i;
    return 'Monthly limit' if $t =~ /MONTHLY/i;
    return 'Usage';
}

# ===========================================================================
# History intel — every scrap we can find (server + local)
# ===========================================================================
#
# Sources:
#   1. GET /billing          — monthly $ history (cents), current month used/limit
#   2. GET /billing?format=credits — current week % / prepaid (no server day ledger)
#   3. ~/.grok/logs/unified.jsonl — billing poll snapshots (prepaid + %) over time
#   4. ~/.grok/sessions/**/summary.json + signals.json — local session activity
#
# There is still no server "tokens per hour" API. This section reconstructs
# the best available timeline from polls + sessions on THIS machine.

sub emit_full_history_intel {
    my $pfx = 'xai.history';
    kv("$pfx.note",
       'No server day/hour token ledger. Monthly $ from API; prepaid/% timeline and sessions from local grok home only.');
    kv("$pfx.local_tz", local_tz_name());
    kv("$pfx.grok_home", $grok_home);

    emit_history_server_billing($pfx);
    emit_history_unified_log($pfx);
    emit_history_sessions($pfx);
    emit_history_reconciliation_hints($pfx);
}

sub emit_history_server_billing {
    my ($pfx) = @_;
    my $sp = "$pfx.server";

    # Live credits snapshot (current period only)
    my $cr = http_get('/billing?format=credits');
    emit_http_meta("$sp.credits", $cr);
    if ($cr->{ok} && ref $cr->{data}{config} eq 'HASH') {
        my $c = $cr->{data}{config};
        kv("$sp.credits.credit_usage_percent", $c->{creditUsagePercent});
        kv("$sp.credits.credit_remaining_percent",
           remaining_pct($c->{creditUsagePercent}));
        my $pp = cent_val($c->{prepaidBalance});
        kv("$sp.credits.prepaid_balance_cents", $pp);
        kv("$sp.credits.prepaid_balance_usd",   cents_to_usd($pp));
        if (ref $c->{currentPeriod} eq 'HASH') {
            kv("$sp.credits.period.type", $c->{currentPeriod}{type});
            kv_date("$sp.credits.period.start", $c->{currentPeriod}{start});
            kv_date("$sp.credits.period.end",   $c->{currentPeriod}{end});
        }
        if (ref $c->{productUsage} eq 'ARRAY') {
            kv("$sp.credits.product_usage.count", scalar @{ $c->{productUsage} });
            for my $i (0 .. $#{ $c->{productUsage} }) {
                my $p = $c->{productUsage}[$i];
                next unless ref $p eq 'HASH';
                my $name = $p->{product} // $i;
                $name =~ s/[^A-Za-z0-9_]+/_/g;
                kv("$sp.credits.product_usage.$name.usage_percent", $p->{usagePercent});
            }
        }
        # credits-format history if ever populated
        if (ref $c->{history} eq 'ARRAY' && @{ $c->{history} }) {
            kv("$sp.credits.history.count", scalar @{ $c->{history} });
            emit_history("$sp.credits", $c->{history});
        } else {
            kv("$sp.credits.history.count", 0);
            kv("$sp.credits.history.note",
               'GetGrokCreditsConfig history empty; no weekly archive from server');
        }
    }

    # Legacy monthly $ history — the only multi-period server ledger
    my $lg = http_get('/billing');
    emit_http_meta("$sp.monthly", $lg);
    if ($lg->{ok} && ref $lg->{data}{config} eq 'HASH') {
        my $c = $lg->{data}{config};
        my $limit = cent_val($c->{monthlyLimit});
        my $used  = cent_val($c->{used});
        kv("$sp.monthly.current.limit_cents", $limit);
        kv("$sp.monthly.current.limit_usd",   cents_to_usd($limit));
        kv("$sp.monthly.current.used_cents",  $used);
        kv("$sp.monthly.current.used_usd",    cents_to_usd($used));
        if (defined $limit && $limit > 0 && defined $used) {
            my $pct = $used / $limit * 100.0;
            $pct = 100 if $pct > 100;
            kv("$sp.monthly.current.usage_percent", sprintf('%.2f', $pct));
            kv("$sp.monthly.current.over_limit",
               ($used > $limit) ? 'true' : 'false');
            kv("$sp.monthly.current.overage_usd",
               cents_to_usd($used - $limit, signed => 1)) if $used > $limit;
        }
        kv_date("$sp.monthly.current.period_start", $c->{billingPeriodStart});
        kv_date("$sp.monthly.current.period_end",   $c->{billingPeriodEnd});

        my $hist = $c->{history};
        if (ref $hist eq 'ARRAY') {
            kv("$sp.monthly.history.count", scalar @$hist);
            my $sum_total = 0;
            my $sum_od    = 0;
            my $sum_inc   = 0;
            # Sort newest first by year/month
            my @rows = sort {
                (($b->{billingCycle}{year}  // 0) <=> ($a->{billingCycle}{year}  // 0))
                  || (($b->{billingCycle}{month} // 0) <=> ($a->{billingCycle}{month} // 0))
            } @$hist;
            for my $i (0 .. $#rows) {
                my $h = $rows[$i];
                next unless ref $h eq 'HASH';
                my $y = $h->{billingCycle}{year}  // 0;
                my $m = $h->{billingCycle}{month} // 0;
                my $key = sprintf('%04d%02d', $y, $m);
                my $inc = cent_val($h->{includedUsed}) // 0;
                my $od  = cent_val($h->{onDemandUsed}) // 0;
                my $tot = cent_val($h->{totalUsed});
                $tot = $inc + $od unless defined $tot;
                $sum_total += $tot;
                $sum_od    += $od;
                $sum_inc   += $inc;
                my $hp = "$sp.monthly.history.$key";
                kv("$hp.year",  $y);
                kv("$hp.month", $m);
                kv("$hp.included_used_cents", $inc);
                kv("$hp.included_used_usd",   cents_to_usd($inc));
                kv("$hp.on_demand_used_cents", $od);
                kv("$hp.on_demand_used_usd",   cents_to_usd($od));
                kv("$hp.total_used_cents", $tot);
                kv("$hp.total_used_usd",   cents_to_usd($tot));
                # Also index form for stable ordering
                kv("$sp.monthly.history.$i.key", $key);
                kv("$sp.monthly.history.$i.total_used_usd", cents_to_usd($tot));
            }
            # Include current month in a combined rollup note
            if (defined $used) {
                kv("$sp.monthly.rollup.history_only_total_usd", cents_to_usd($sum_total));
                kv("$sp.monthly.rollup.history_plus_current_used_usd",
                   cents_to_usd($sum_total + $used));
                kv("$sp.monthly.rollup.note",
                   'history[] is past months only; add current.used for MTD. Prepaid top-ups may not equal these on-demand/included fields.');
            }
        } else {
            kv("$sp.monthly.history.count", 0);
        }
    }
}

sub emit_history_unified_log {
    my ($pfx) = @_;
    my $up = "$pfx.local.unified";
    my $log = File::Spec->catfile($grok_home, 'logs', 'unified.jsonl');
    kv("$up.path", $log);

    unless (-f $log) {
        kv("$up.present", 'false');
        kv("$up.note", 'No unified.jsonl — no local billing poll history on this machine');
        return;
    }
    kv("$up.present", 'true');
    my @st = stat($log);
    kv("$up.size_bytes", $st[7]) if @st;

    # Scan all billing credit fetches
    my @snaps;           # all snapshots (ts_epoch, ts_raw, pct, prepaid, od_used, tier)
    my @changes;         # only when (prepaid,pct) changes
    my $raw_lines = 0;
    my $bill_lines = 0;
    my $parse_err = 0;

    open my $fh, '<:raw', $log or do {
        kv("$up.read_error", "$!");
        return;
    };
    while (my $line = <$fh>) {
        $raw_lines++;
        next unless index($line, 'billing: fetched credits config') >= 0
          || (index($line, 'creditUsagePercent') >= 0 && index($line, 'prepaidBalance') >= 0);
        $bill_lines++;
        my $o = eval { decode_json($line) };
        if (!$o || ref $o ne 'HASH') { $parse_err++; next; }
        my $cfg = ($o->{ctx} && ref $o->{ctx} eq 'HASH') ? ($o->{ctx}{config} // {}) : {};
        next unless ref $cfg eq 'HASH';
        my $pct = $cfg->{creditUsagePercent};
        my $pp  = cent_val($cfg->{prepaidBalance});
        my $od  = cent_val($cfg->{onDemandUsed});
        my $ts  = $o->{ts} // '';
        my $ep  = parse_rfc3339($ts);
        my $tier = $o->{ctx}{subscriptionTier} if ref $o->{ctx} eq 'HASH';
        my $row = {
            ts      => $ts,
            epoch   => $ep,
            pct     => $pct,
            prepaid => $pp,
            od_used => $od,
            tier    => $tier,
            pid     => $o->{pid},
            ver     => $o->{ver},
        };
        push @snaps, $row;
        if (!@changes
            || ($changes[-1]{prepaid} // -1) != ($pp // -1)
            || ($changes[-1]{pct} // -1) != ($pct // -1))
        {
            push @changes, $row;
        }
    }
    close $fh;

    kv("$up.lines_total", $raw_lines);
    kv("$up.billing_snapshots", $bill_lines);
    kv("$up.billing_snapshots_parsed", scalar @snaps);
    kv("$up.parse_errors", $parse_err);
    kv("$up.change_events", scalar @changes);

    if (!@snaps) {
        kv("$up.note", 'No billing credit snapshots found in unified.jsonl');
        return;
    }

    kv_date("$up.first_ts", $snaps[0]{ts},  fast => 1);
    kv_date("$up.last_ts",  $snaps[-1]{ts}, fast => 1);
    if (defined $snaps[0]{epoch} && defined $snaps[-1]{epoch}) {
        kv("$up.span_secs", $snaps[-1]{epoch} - $snaps[0]{epoch});
        kv("$up.span_hours",
           sprintf('%.2f', ($snaps[-1]{epoch} - $snaps[0]{epoch}) / 3600));
        kv("$up.span_days",
           sprintf('%.2f', ($snaps[-1]{epoch} - $snaps[0]{epoch}) / 86400));
    }

    # Prepaid extremes across all snapshots
    my ($pp_min, $pp_max, $pct_min, $pct_max);
    my $pp_max_ts;
    for my $s (@snaps) {
        if (defined $s->{prepaid}) {
            if (!defined $pp_min || $s->{prepaid} < $pp_min) { $pp_min = $s->{prepaid}; }
            if (!defined $pp_max || $s->{prepaid} > $pp_max) {
                $pp_max = $s->{prepaid};
                $pp_max_ts = $s->{ts};
            }
        }
        if (defined $s->{pct}) {
            if (!defined $pct_min || $s->{pct} < $pct_min) { $pct_min = $s->{pct}; }
            if (!defined $pct_max || $s->{pct} > $pct_max) { $pct_max = $s->{pct}; }
        }
    }
    kv("$up.prepaid.max_cents", $pp_max);
    kv("$up.prepaid.max_usd",   cents_to_usd($pp_max));
    kv_date("$up.prepaid.max_at", $pp_max_ts, fast => 1) if $pp_max_ts;
    kv("$up.prepaid.min_cents", $pp_min);
    kv("$up.prepaid.min_usd",   cents_to_usd($pp_min));
    # Net prepaid burn from first seen max-ish to last (if prepaid declined)
    if (defined $pp_max && defined $snaps[-1]{prepaid}) {
        my $burn = $pp_max - ($snaps[-1]{prepaid} // 0);
        kv("$up.prepaid.burn_from_peak_cents", $burn);
        kv("$up.prepaid.burn_from_peak_usd",   cents_to_usd($burn, signed => 1));
    }
    # First→last prepaid delta
    if (defined $snaps[0]{prepaid} && defined $snaps[-1]{prepaid}) {
        my $d = $snaps[0]{prepaid} - $snaps[-1]{prepaid};
        kv("$up.prepaid.first_cents", $snaps[0]{prepaid});
        kv("$up.prepaid.first_usd",   cents_to_usd($snaps[0]{prepaid}));
        kv("$up.prepaid.last_cents",  $snaps[-1]{prepaid});
        kv("$up.prepaid.last_usd",    cents_to_usd($snaps[-1]{prepaid}));
        kv("$up.prepaid.delta_first_to_last_cents", $d);
        kv("$up.prepaid.delta_first_to_last_usd",
           cents_to_usd($d, signed => 1));
        kv("$up.prepaid.note",
           'Positive delta_first_to_last means prepaid declined (spent). Does not include top-ups after first snapshot unless reflected in peak.');
    }
    kv("$up.usage_percent.min", $pct_min);
    kv("$up.usage_percent.max", $pct_max);
    kv("$up.usage_percent.first", $snaps[0]{pct});
    kv("$up.usage_percent.last",  $snaps[-1]{pct});

    # Change-event timeline (every prepaid or % step)
    kv("$up.timeline.count", scalar @changes);
    for my $i (0 .. $#changes) {
        my $c = $changes[$i];
        my $tp = "$up.timeline.$i";
        kv_date("$tp.ts", $c->{ts}, fast => 1);
        kv("$tp.usage_percent", $c->{pct});
        kv("$tp.prepaid_cents", $c->{prepaid});
        kv("$tp.prepaid_usd",   cents_to_usd($c->{prepaid}));
        if ($i > 0) {
            my $prev = $changes[$i - 1];
            if (defined $c->{prepaid} && defined $prev->{prepaid}) {
                my $dp = $prev->{prepaid} - $c->{prepaid};
                kv("$tp.prepaid_delta_cents", $dp);
                kv("$tp.prepaid_delta_usd", cents_to_usd($dp, signed => 1));
            }
            if (defined $c->{pct} && defined $prev->{pct}) {
                kv("$tp.usage_percent_delta", $c->{pct} - $prev->{pct});
            }
            if (defined $c->{epoch} && defined $prev->{epoch}) {
                kv("$tp.secs_since_prev", $c->{epoch} - $prev->{epoch});
            }
        }
        kv("$tp.subscription_tier", $c->{tier}) if defined $c->{tier};
        kv("$tp.client_version", $c->{ver}) if defined $c->{ver};
    }

    # Day buckets (local calendar day)
    my %day;    # yyyymmdd => { first, last, pp_open, pp_close, pp_min, pp_max, pct_open, pct_close, pct_min, pct_max, n, burn }
    my %hour;   # yyyymmddHH => same
    for my $s (@snaps) {
        next unless defined $s->{epoch};
        my @lt = localtime($s->{epoch});
        my $dkey = strftime('%Y%m%d', @lt);
        my $hkey = strftime('%Y%m%d%H', @lt);
        for my $pair ( [ \%day, $dkey ], [ \%hour, $hkey ] ) {
            my ($map, $key) = @$pair;
            my $b = $map->{$key} //= {
                n => 0,
                first_ts => $s->{ts},
                last_ts  => $s->{ts},
            };
            $b->{n}++;
            $b->{last_ts} = $s->{ts};
            _bucket_update($b, $s);
        }
    }

    my @days = sort keys %day;
    kv("$up.by_day.count", scalar @days);
    my $di = 0;
    for my $dk (@days) {
        my $b = $day{$dk};
        my $bp = "$up.by_day.$dk";
        _emit_bucket($bp, $b);
        kv("$up.by_day.$di.key", $dk);
        $di++;
    }

    my @hours = sort keys %hour;
    kv("$up.by_hour.count", scalar @hours);
    # Emit all hours that have data (user asked for every scrap)
    for my $hk (@hours) {
        _emit_bucket("$up.by_hour.$hk", $hour{$hk});
    }

    # Fast burn windows: consecutive change events with prepaid drop > $1 in < 1h
    my @bursts;
    for my $i (1 .. $#changes) {
        my $a = $changes[$i - 1];
        my $b = $changes[$i];
        next unless defined $a->{prepaid} && defined $b->{prepaid};
        next unless defined $a->{epoch} && defined $b->{epoch};
        my $dp = $a->{prepaid} - $b->{prepaid};
        next unless $dp > 0;  # spent
        my $dt = $b->{epoch} - $a->{epoch};
        next unless $dt > 0 && $dt <= 3600;
        push @bursts, {
            from => $a, to => $b,
            cents => $dp, secs => $dt,
            usd_per_hour => ($dp / 100) / ($dt / 3600),
        };
    }
    # Top bursts by cents
    @bursts = sort { $b->{cents} <=> $a->{cents} } @bursts;
    kv("$up.fast_burns.count", scalar @bursts);
    my $topn = @bursts > 20 ? 20 : scalar @bursts;
    for my $i (0 .. $topn - 1) {
        my $b = $bursts[$i];
        my $bp = "$up.fast_burns.$i";
        kv_date("$bp.from_ts", $b->{from}{ts}, fast => 1);
        kv_date("$bp.to_ts",   $b->{to}{ts},   fast => 1);
        kv("$bp.secs", $b->{secs});
        kv("$bp.prepaid_spent_cents", $b->{cents});
        kv("$bp.prepaid_spent_usd",   cents_to_usd($b->{cents}));
        kv("$bp.usd_per_hour", sprintf('%.2f', $b->{usd_per_hour}));
    }
}

sub _bucket_update {
    my ($b, $s) = @_;
    if (defined $s->{prepaid}) {
        $b->{pp_open} = $s->{prepaid} unless defined $b->{pp_open};
        $b->{pp_close} = $s->{prepaid};
        $b->{pp_min} = $s->{prepaid}
          if !defined $b->{pp_min} || $s->{prepaid} < $b->{pp_min};
        $b->{pp_max} = $s->{prepaid}
          if !defined $b->{pp_max} || $s->{prepaid} > $b->{pp_max};
    }
    if (defined $s->{pct}) {
        $b->{pct_open} = $s->{pct} unless defined $b->{pct_open};
        $b->{pct_close} = $s->{pct};
        $b->{pct_min} = $s->{pct}
          if !defined $b->{pct_min} || $s->{pct} < $b->{pct_min};
        $b->{pct_max} = $s->{pct}
          if !defined $b->{pct_max} || $s->{pct} > $b->{pct_max};
    }
}

sub _emit_bucket {
    my ($bp, $b) = @_;
    return unless $b;
    kv("$bp.samples", $b->{n});
    kv_date("$bp.first_ts", $b->{first_ts}, fast => 1) if $b->{first_ts};
    kv_date("$bp.last_ts",  $b->{last_ts},  fast => 1) if $b->{last_ts};
    if (defined $b->{pp_open}) {
        kv("$bp.prepaid.open_cents",  $b->{pp_open});
        kv("$bp.prepaid.open_usd",    cents_to_usd($b->{pp_open}));
        kv("$bp.prepaid.close_cents", $b->{pp_close});
        kv("$bp.prepaid.close_usd",   cents_to_usd($b->{pp_close}));
        kv("$bp.prepaid.min_cents",   $b->{pp_min});
        kv("$bp.prepaid.min_usd",     cents_to_usd($b->{pp_min}));
        kv("$bp.prepaid.max_cents",   $b->{pp_max});
        kv("$bp.prepaid.max_usd",     cents_to_usd($b->{pp_max}));
        my $burn = $b->{pp_open} - $b->{pp_close};
        kv("$bp.prepaid.spent_cents", $burn);
        kv("$bp.prepaid.spent_usd",   cents_to_usd($burn, signed => 1));
    }
    if (defined $b->{pct_open}) {
        kv("$bp.usage_percent.open",  $b->{pct_open});
        kv("$bp.usage_percent.close", $b->{pct_close});
        kv("$bp.usage_percent.min",   $b->{pct_min});
        kv("$bp.usage_percent.max",   $b->{pct_max});
        kv("$bp.usage_percent.delta", $b->{pct_close} - $b->{pct_open});
    }
}

sub emit_history_sessions {
    my ($pfx) = @_;
    my $sp = "$pfx.local.sessions";
    my $root = File::Spec->catdir($grok_home, 'sessions');
    kv("$sp.root", $root);
    unless (-d $root) {
        kv("$sp.present", 'false');
        return;
    }
    kv("$sp.present", 'true');

    # Collect summary.json + sibling signals.json
    my @sessions;
    _walk_find($root, 'summary.json', \@sessions);

    kv("$sp.summary_files", scalar @sessions);

    my @rows;
    for my $sum_path (@sessions) {
        my $dir = dirname($sum_path);
        my $sum = _read_json_file($sum_path);
        next unless $sum && ref $sum eq 'HASH';
        my $sig_path = File::Spec->catfile($dir, 'signals.json');
        my $sig = (-f $sig_path) ? _read_json_file($sig_path) : undef;
        my $id = ($sum->{info} && ref $sum->{info} eq 'HASH')
          ? ($sum->{info}{id} // '')
          : '';
        $id ||= basename($dir);
        my $cwd = ($sum->{info} && ref $sum->{info} eq 'HASH')
          ? ($sum->{info}{cwd} // '')
          : '';
        my $created = $sum->{created_at} // '';
        my $updated = $sum->{updated_at} // '';
        my $model   = $sum->{current_model_id} // '';
        my $agent   = $sum->{agent_name} // '';
        my $msgs    = $sum->{num_chat_messages} // $sum->{num_messages} // 0;
        my $row = {
            id => $id,
            cwd => $cwd,
            created => $created,
            updated => $updated,
            created_epoch => parse_rfc3339($created),
            updated_epoch => parse_rfc3339($updated),
            model => $model,
            agent => $agent,
            num_chat_messages => $msgs,
            path => $dir,
        };
        if ($sig && ref $sig eq 'HASH') {
            $row->{turn_count} = $sig->{turnCount};
            $row->{context_tokens_used} = $sig->{contextTokensUsed};
            $row->{context_window_tokens} = $sig->{contextWindowTokens};
            $row->{tool_call_count} = $sig->{toolCallCount};
            $row->{session_duration_secs} = $sig->{sessionDurationSeconds};
            $row->{primary_model} = $sig->{primaryModelId} // $model;
            if (ref $sig->{modelsUsed} eq 'ARRAY') {
                $row->{models} = join(',', @{ $sig->{modelsUsed} });
            }
            $row->{error_count} = $sig->{errorCount};
            $row->{compaction_count} = $sig->{compactionCount};
        }
        push @rows, $row;
    }

    # Sort by updated desc
    @rows = sort {
        ($b->{updated_epoch} // 0) <=> ($a->{updated_epoch} // 0)
    } @rows;

    kv("$sp.count", scalar @rows);

    # Aggregate by local day of updated_at
    my %by_day;
    my %models;
    my $total_turns = 0;
    my $total_ctx_tokens = 0;  # NOT billable pool — context window only
    my $with_signals = 0;
    for my $r (@rows) {
        $models{ $r->{primary_model} || $r->{model} || 'unknown' }++
          if ($r->{primary_model} || $r->{model});
        if (defined $r->{turn_count}) {
            $with_signals++;
            $total_turns += $r->{turn_count} // 0;
        }
        $total_ctx_tokens += $r->{context_tokens_used} // 0;
        if (defined $r->{updated_epoch}) {
            my $dk = strftime('%Y%m%d', localtime($r->{updated_epoch}));
            my $d = $by_day{$dk} //= {
                sessions => 0, turns => 0, context_tokens => 0, msgs => 0,
            };
            $d->{sessions}++;
            $d->{turns} += $r->{turn_count} // 0;
            $d->{context_tokens} += $r->{context_tokens_used} // 0;
            $d->{msgs} += $r->{num_chat_messages} // 0;
        }
    }
    kv("$sp.with_signals", $with_signals);
    kv("$sp.total_turns", $total_turns);
    kv("$sp.total_context_tokens_used_sum", $total_ctx_tokens);
    kv("$sp.total_context_tokens_note",
       'Sum of per-session contextTokensUsed (context window occupancy signals), NOT account billing tokens and NOT double-count-safe across sessions.');

    kv("$sp.models.count", scalar keys %models);
    for my $m (sort keys %models) {
        my $safe = $m;
        $safe =~ s/[^A-Za-z0-9_.-]+/_/g;
        kv("$sp.models.$safe.sessions", $models{$m});
    }

    my @dkeys = sort keys %by_day;
    kv("$sp.by_day.count", scalar @dkeys);
    for my $dk (@dkeys) {
        my $d = $by_day{$dk};
        kv("$sp.by_day.$dk.sessions", $d->{sessions});
        kv("$sp.by_day.$dk.turns", $d->{turns});
        kv("$sp.by_day.$dk.chat_messages", $d->{msgs});
        kv("$sp.by_day.$dk.context_tokens_sum", $d->{context_tokens});
    }

    # Per-session dump (capped)
    my $n = scalar @rows;
    my $limit = $history_max_sessions;
    $limit = $n if $n < $limit;
    kv("$sp.dump.count", $limit);
    kv("$sp.dump.truncated", ($n > $limit) ? 'true' : 'false');
    for my $i (0 .. $limit - 1) {
        my $r = $rows[$i];
        my $rp = "$sp.dump.$i";
        kv("$rp.id", $r->{id});
        kv("$rp.cwd", $r->{cwd});
        kv_date("$rp.created_at", $r->{created}, fast => 1) if $r->{created};
        kv_date("$rp.updated_at", $r->{updated}, fast => 1) if $r->{updated};
        kv("$rp.model", $r->{primary_model} || $r->{model});
        kv("$rp.models", $r->{models}) if $r->{models};
        kv("$rp.agent_name", $r->{agent}) if $r->{agent};
        kv("$rp.num_chat_messages", $r->{num_chat_messages});
        kv("$rp.turn_count", $r->{turn_count}) if defined $r->{turn_count};
        kv("$rp.context_tokens_used", $r->{context_tokens_used})
          if defined $r->{context_tokens_used};
        kv("$rp.context_window_tokens", $r->{context_window_tokens})
          if defined $r->{context_window_tokens};
        kv("$rp.tool_call_count", $r->{tool_call_count})
          if defined $r->{tool_call_count};
        kv("$rp.session_duration_secs", $r->{session_duration_secs})
          if defined $r->{session_duration_secs};
        kv("$rp.error_count", $r->{error_count}) if defined $r->{error_count};
        kv("$rp.path", $r->{path});
    }
}

sub emit_history_reconciliation_hints {
    my ($pfx) = @_;
    my $hp = "$pfx.reconcile";
    kv("$hp.card_charges.note",
       'Card/bank charges (e.g. $276) are purchase events, not exported as a CLI invoice list. Check bank statement, email receipts, accounts.x.ai / console.x.ai.');
    kv("$hp.tokens_per_day.note",
       'Server does not expose tokens/day or tokens/hour for the plan pool. Local signals only have context-window tokens per session.');
    kv("$hp.prepaid_vs_monthly.note",
       'Legacy monthly used/onDemand is a dollar meter; prepaidBalance is bought credits burned after included pool hits 100%. They overlap poorly—use unified timeline for prepaid burn.');
    kv("$hp.coverage.note",
       'unified.jsonl only covers periods when Grok on THIS host polled billing. Other machines, Grok Chat web, and API keys are invisible here.');
    kv("$hp.suggested_watch",
       'cron: xai-status.pl --no-refresh -s credits -s legacy >> ~/xai-status-history.log');
}

sub _walk_find {
    my ($dir, $name, $out) = @_;
    opendir my $dh, $dir or return;
    my @ents = readdir $dh;
    closedir $dh;
    for my $e (@ents) {
        next if $e eq '.' || $e eq '..';
        my $p = File::Spec->catfile($dir, $e);
        if (-d $p) {
            _walk_find($p, $name, $out);
        } elsif ($e eq $name && -f $p) {
            push @$out, $p;
        }
    }
}

sub _read_json_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return eval { decode_json($raw) };
}

# ===========================================================================
# Date::Manip helpers — local TZ, format %Y%m%d %H%M%S.<ms> ±HH:MM
# ===========================================================================

# Cache of system zone name (e.g. US/Central from /etc/localtime).
my $LOCAL_TZ_NAME;

sub local_tz_name {
    return $LOCAL_TZ_NAME if defined $LOCAL_TZ_NAME;

    if (defined $ENV{TZ} && length $ENV{TZ} && $ENV{TZ} ne 'localtime') {
        my $tz = $ENV{TZ};
        $tz =~ s{^:}{};
        $tz =~ s{^.*/zoneinfo/}{};
        if (length $tz && $tz !~ m{/}) {
            # bare name like US/Central or America/Chicago may still contain /
        }
        $tz =~ s{^.*/zoneinfo/}{};
        if ($tz =~ m{^/}) {
            # absolute path without zoneinfo — try basename path strip
            $tz =~ s{^.*/zoneinfo/}{};
        }
        if ($tz !~ m{^/} && length $tz) {
            $LOCAL_TZ_NAME = $tz;
            return $LOCAL_TZ_NAME;
        }
    }

    # OpenBSD/FreeBSD/Linux: /etc/localtime → /usr/share/zoneinfo/<Zone>
    for my $lt (qw(/etc/localtime)) {
        if (-l $lt) {
            my $target = readlink($lt) // next;
            if ($target =~ m{(?:^|/)zoneinfo/(.+)$}) {
                $LOCAL_TZ_NAME = $1;
                return $LOCAL_TZ_NAME;
            }
        }
    }

    # Fallback: ask Date::Manip what "now" is in, via offset only.
    # convert() needs a named zone; default to UTC and still format offset
    # from a local "now" parse if needed.
    $LOCAL_TZ_NAME = 'UTC';
    return $LOCAL_TZ_NAME;
}

# Convert an RFC3339 / ISO-8601 timestamp to local wall time:
#   YYYYMMDD HHMMSS.<ms> ±HH:MM
# Milliseconds come from the source fractional seconds (truncated/padded to 3).
# On failure returns undef.
sub format_date_local {
    my ($s) = @_;
    return undef unless defined $s && length $s;

    my ($frac) = $s =~ /\.(\d+)/;
    $frac //= '0';
    # Milliseconds = first 3 fractional digits (pad if shorter).
    my $ms = substr($frac . '000', 0, 3);

    my $d = Date::Manip::Date->new;
    my $err = $d->parse($s);
    if ($err) {
        # Date::Manip sometimes wants a space instead of T.
        my $alt = $s;
        $alt =~ s/T/ /;
        $err = $d->parse($alt);
        return undef if $err;
    }

    my $tz = local_tz_name();
    if ($tz ne 'UTC') {
        my $cerr = $d->convert($tz);
        # If convert fails, keep the parsed instant and format its offset.
        if ($cerr) {
            # last-ditch: re-parse and leave zone as-is
        }
    }

    my $ymd_hms = $d->printf('%Y%m%d %H%M%S');
    return undef unless defined $ymd_hms && length $ymd_hms;

    my $z = $d->printf('%z');    # +0000 / -0500
    $z = '+0000' unless defined $z && length $z;
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

# Emit a timestamp field as local formatted value, plus .raw (API original)
# and .unix (epoch seconds).
# $opt{fast} => use POSIX localtime (history mass dumps); default Date::Manip.
sub kv_date {
    my ($key, $raw, %opt) = @_;
    $KV->kv_date($key, $raw, %opt) if $KV;
}

# RFC3339 / ISO-8601 → unix epoch (UTC seconds).
# Fast path: regex (hot for history scans). Date::Manip only on odd shapes.
sub parse_rfc3339 {
    my ($s) = @_;
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

# Fast local format without Date::Manip (history buckets / many lines).
# Format: YYYYMMDD HHMMSS.<ms> ±HH:MM using system localtime + tm_gmtoff.
sub format_date_local_fast {
    my ($s) = @_;
    return undef unless defined $s && length $s;
    my $ep = parse_rfc3339($s);
    return undef unless defined $ep;
    my ($frac) = $s =~ /\.(\d+)/;
    $frac //= '0';
    my $ms = substr($frac . '000', 0, 3);
    my @lt = localtime($ep);
    my $body = strftime('%Y%m%d %H%M%S', @lt);
    # Offset: prefer tm_gmtoff when available (OpenBSD/BSD), else compute.
    my $off;
    if (@lt >= 10 && defined $lt[9]) {
        # Some perls expose tm_gmtoff as index 9? Not portable.
    }
    # Compute offset from UTC via timegm of the local broken-down time.
    my $as_utc = eval {
        timegm($lt[0], $lt[1], $lt[2], $lt[3], $lt[4], $lt[5] + 1900);
    };
    if (defined $as_utc) {
        $off = $as_utc - $ep;
    } else {
        $off = 0;
    }
    my $sign = $off >= 0 ? '+' : '-';
    $off = abs($off);
    my $oh = int($off / 3600);
    my $om = int(($off % 3600) / 60);
    return sprintf('%s.%s %s%02d:%02d', $body, $ms, $sign, $oh, $om);
}

1;
