#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use GrokAPI::Management::Data;

my $class = 'GrokAPI::Management::Data';

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
like($ls, qr/# Files \(2 items\)/, 'ls header');
like($ls, qr/f1\s+one\.txt/, 'ls row');

my $lsl = $class->run_command(api => $mock_api, cmd => 'lsl', store => 'Files');
like($lsl, qr/id\s+name/, 'lsl columns');
like($lsl, qr/total: 2/, 'lsl total');

my $size = $class->run_command(api => $mock_api, cmd => 'size', store => 'Files');
is($size, "Files: 2 objects, 30 bytes total\n", 'size sum');

my $cat_out = $class->run_command(api => $mock_api, cmd => 'cat', store => 'Files', id => 'f1');
is($cat_out, "hello world\n", 'cat text content');

my $coll = $class->run_command(api => $mock_api, cmd => 'ls', store => 'Collections');
like($coll, qr/c1\s+docs/, 'collections ls');

my $binary = $class->format_cat({
	type  => 'content',
	bytes => "\x00\xff",
	path  => 'v1/files/x/content',
});
like($binary, qr/binary content \(2 bytes\)/, 'format_cat binary');

done_testing();