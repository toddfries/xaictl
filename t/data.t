#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use xaictl::Management::Data;

my $class = 'xaictl::Management::Data';

is($class->normalize_store('files'), 'Files', 'normalize files');
is($class->normalize_store('CUA_instances'), 'CUA_instances', 'normalize CUA');
is($class->normalize_store('compliance'), 'Compliance', 'normalize compliance');

my $cat = $class->store_catalog();
ok($cat->{Files}{list_paths}, 'Files catalog');
ok($cat->{Collections}{list_paths}, 'Collections catalog');
ok($cat->{Conversations}{list_paths}, 'Conversations catalog');

my $mock_api = bless {}, 'MockDataAPI';
{
	no warnings 'redefine';
	*MockDataAPI::mgmt_request = sub {
		my ($self, $method, $path) = @_;
		return { ok => 1, status => 200, data => { files => [
			{ id => 'f1', filename => 'one.txt', bytes => 10, created_at => '2026-01-01' },
			{ id => 'f2', filename => 'two.bin', bytes => 20, created_at => '2026-01-02' },
		] } } if $path =~ m{^v1/files};
		return { ok => 1, status => 200, data => { collections => [
			{ collection_id => 'c1', collection_name => 'docs', document_count => 3, create_time => 't1' },
		] } } if $path =~ m{^v1/collections};
		return { ok => 0, status => 404, error => 'not found' };
	};
	*MockDataAPI::mgmt_request_raw = sub {
		my ($self, $method, $path) = @_;
		return { ok => 1, status => 200, raw => "hello world\n" }
			if $path =~ m{^v1/files/f1/content};
		return { ok => 0, status => 404, error => 'missing' };
	};
}

my $ls = $class->run_command(api => $mock_api, cmd => 'ls', store => 'Files');
like($ls, qr/xai\.mgmt\.data\.store=Files/, 'ls store');
like($ls, qr/xai\.mgmt\.data\.count=2/, 'ls count');
like($ls, qr/xai\.mgmt\.data\.0\.id=f1/, 'ls row id');
like($ls, qr/xai\.mgmt\.data\.0\.name=one\.txt/, 'ls row name');

my $lsl = $class->run_command(api => $mock_api, cmd => 'lsl', store => 'Files');
like($lsl, qr/xai\.mgmt\.data\.0\.size=10/, 'lsl size');
like($lsl, qr/xai\.mgmt\.data\.count=2/, 'lsl count');

my $size = $class->run_command(api => $mock_api, cmd => 'size', store => 'Files');
like($size, qr/xai\.mgmt\.data\.count=2/, 'size count');
like($size, qr/xai\.mgmt\.data\.total_bytes=30/, 'size sum');

my $cat_out = $class->run_command(api => $mock_api, cmd => 'cat', store => 'Files', id => 'f1');
is($cat_out, "hello world\n", 'cat text content');

my $coll = $class->run_command(api => $mock_api, cmd => 'ls', store => 'Collections');
like($coll, qr/xai\.mgmt\.data\.0\.id=c1/, 'collections ls id');
like($coll, qr/xai\.mgmt\.data\.0\.name=docs/, 'collections ls name');

my $binary = $class->format_cat({
	type  => 'content',
	bytes => "\x00\xff",
	path  => 'v1/files/x/content',
});
like($binary, qr/binary content \(2 bytes\)/, 'format_cat binary');

done_testing();