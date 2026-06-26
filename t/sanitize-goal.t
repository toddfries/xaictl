#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 6;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use GrokAPI::Evidence::Sanitize;
use GrokAPI::Evidence::Redact;

my $class = 'GrokAPI::Evidence::Sanitize';

ok($class->in_scope_path('git/sw/grokapi/grok-sanity'), 'grokapi in scope');
ok(!$class->in_scope_path('.config/cxai/grok.conf'), 'config out of scope');
ok(!$class->in_scope_path('bin/myip'), 'bin/myip out of scope');

my $sample = <<'PATCH';
diff --git a/.config/cxai/grok.conf b/.config/cxai/grok.conf
--- /dev/null
+++ b/.config/cxai/grok.conf
+bearer = xai-fake-short-key
diff --git a/git/sw/grokapi/grok-sanity b/git/sw/grokapi/grok-sanity
--- a/git/sw/grokapi/grok-sanity
+++ b/git/sw/grokapi/grok-sanity
+echo ok
PATCH

my $filtered = $class->filter_patch($sample);
unlike($filtered, qr/\.config\/cxai/, 'filtered patch drops config');
like($filtered, qr/git\/sw\/grokapi\/grok-sanity/, 'filtered patch keeps grokapi');
ok(!GrokAPI::Evidence::Redact->has_secret($filtered), 'filtered patch redacted');

done_testing();