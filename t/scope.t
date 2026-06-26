#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 2;

my $grokapi = '/home/todd/git/sw/grokapi';
my $xaiapi  = '/home/todd/git/sw/xAI-API';

my $grok_files = `cd $grokapi && git ls-files 2>/dev/null`;
my $xai_files  = `cd $xaiapi && git ls-files 2>/dev/null`;

ok($grok_files =~ /grok-sanity/, 'grokapi repo has grok-sanity');
like($xai_files, qr{lib/xAI/API\.pm}, 'xAI-API repo has API.pm');

done_testing();