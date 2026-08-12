package xaictl::Management::Data;

use strict;
use warnings;
use JSON;

our $VERSION = '0.01';

sub normalize_store {
	my ($class, $name) = @_;
	$name //= 'Files';
	$name =~ s/\s+/_/g;
	my %map = (
		files         => 'Files',
		file          => 'Files',
		collections   => 'Collections',
		collection    => 'Collections',
		conversations => 'Conversations',
		conversation  => 'Conversations',
		cua_instances => 'CUA_instances',
		cua           => 'CUA_instances',
		cua_instances => 'CUA_instances',
		compliance    => 'Compliance',
	);
	return $map{lc $name} // $name;
}

sub store_catalog {
	my ($class) = @_;
	return {
		Files => {
			list_paths => ['v1/files?limit=100'],
			list_keys  => [qw(files data)],
			detail_fmt => 'v1/files/%s',
			content_fmt=> 'v1/files/%s/content',
			id_field   => 'id',
			name_field => 'filename',
			size_field => 'bytes',
			time_field => 'created_at',
		},
		Collections => {
			list_paths => ['v1/collections'],
			list_keys  => [qw(collections)],
			detail_fmt => 'v1/collections/%s',
			id_field   => 'collection_id',
			name_field => 'collection_name',
			size_field => 'document_count',
			time_field => 'create_time',
		},
		Conversations => {
			list_paths => [
				'v1/conversations?limit=100',
				'v1/conversation?limit=100',
			],
			list_keys  => [qw(conversations data items)],
			detail_fmt => 'v1/conversations/%s',
			id_field   => 'id',
			name_field => 'title',
			size_field => 'message_count',
			time_field => 'created_at',
		},
		CUA_instances => {
			list_paths => [
				'v1/cua-instances',
				'v1/cua/instances',
			],
			list_keys  => [qw(instances cuaInstances data)],
			detail_fmt => 'v1/cua-instances/%s',
			id_field   => 'id',
			name_field => 'name',
			size_field => 'status',
			time_field => 'created_at',
		},
		Compliance => {
			list_paths => [
				'v1/compliance/exports',
				'v1/compliance/export/status',
			],
			list_keys  => [qw(exports data items status)],
			detail_fmt => 'v1/compliance/exports/%s',
			id_field   => 'export_id',
			name_field => 'status',
			size_field => 'bytes',
			time_field => 'created_at',
		},
	};
}

sub list_items {
	my ($class, %args) = @_;
	my $api   = $args{api}   or die "api required\n";
	my $store = $class->normalize_store($args{store});
	my $cat   = $class->store_catalog()->{$store}
		or die "unknown store '$store' (try Files Collections Conversations CUA_instances Compliance)\n";

	my $last_err = 'no list path succeeded';
	for my $path (@{$cat->{list_paths}}) {
		my $res = $api->mgmt_request('GET', $path);
		next unless $res->{ok};
		my $items = $class->_extract_list($res->{data}, $cat->{list_keys});
		return ($items, $path) if defined $items;
		$last_err = "empty list from $path";
	}
	if ($store ne 'Files' && $store ne 'Collections') {
		die "$store: API endpoint not available ($last_err). ACL may grant access but REST path not published yet.\n";
	}
	die "$store: list failed ($last_err)\n";
}

sub _extract_list {
	my ($class, $data, $keys) = @_;
	return undef unless defined $data;
	if (ref $data eq 'ARRAY') {
		return $data;
	}
	return undef unless ref $data eq 'HASH';
	for my $k (@{$keys}) {
		return $data->{$k} if defined $data->{$k} && ref $data->{$k} eq 'ARRAY';
	}
	return undef;
}

sub get_item {
	my ($class, %args) = @_;
	my $api   = $args{api};
	my $store = $class->normalize_store($args{store});
	my $id    = $args{id} // die "id required for cat\n";
	my $cat   = $class->store_catalog()->{$store}
		or die "unknown store '$store'\n";

	if ($store eq 'Files' && $cat->{content_fmt}) {
		my $path = sprintf($cat->{content_fmt}, $id);
		my $res  = $api->mgmt_request_raw('GET', $path);
		die "Files cat failed: $res->{error}\n" unless $res->{ok};
		return { type => 'content', bytes => $res->{raw}, path => $path };
	}

	my $path = sprintf($cat->{detail_fmt}, $id);
	my $res  = $api->mgmt_request('GET', $path);
	die "$store cat failed: $res->{error}\n" unless $res->{ok};
	return { type => 'json', data => $res->{data}, path => $path };
}

sub field {
	my ($class, $item, $field) = @_;
	return '' unless defined $item && ref $item eq 'HASH';
	return $item->{$field} // '';
}

sub format_ls {
	my ($class, $items, $store) = @_;
	return $class->_format_list($items, $store, 0);
}

sub format_lsl {
	my ($class, $items, $store) = @_;
	return $class->_format_list($items, $store, 1);
}

sub _format_list {
	my ($class, $items, $store, $long) = @_;
	require xaictl::Kv;
	my $kv = xaictl::Kv->new;
	$class->emit_list($kv, $items, $store, long => $long);
	return $kv->as_string();
}

sub emit_list {
	my ($class, $kv, $items, $store, %args) = @_;
	$items //= [];
	my $cat = $class->store_catalog()->{$store};
	my $p   = $args{prefix} // 'xai.mgmt.data';
	$kv->kv("$p.store", $store);
	$kv->kv("$p.count", scalar @{$items});
	for my $i (0 .. $#{$items}) {
		my $it   = $items->[$i];
		my $id   = $class->field($it, $cat->{id_field}) || $class->field($it, 'id');
		my $name = $class->field($it, $cat->{name_field}) || $id;
		$kv->kv("$p.$i.id",   $id);
		$kv->kv("$p.$i.name", $name);
		if ($args{long}) {
			my $size = $class->field($it, $cat->{size_field});
			$size = $class->field($it, 'bytes') if $size eq '' && $store eq 'Files';
			$kv->kv("$p.$i.size", $size);
			$kv->kv("$p.$i.time", $class->field($it, $cat->{time_field}));
		}
	}
	return $kv;
}

sub format_size {
	my ($class, $items, $store) = @_;
	require xaictl::Kv;
	my $kv = xaictl::Kv->new;
	$class->emit_size($kv, $items, $store);
	return $kv->as_string();
}

sub emit_size {
	my ($class, $kv, $items, $store, %args) = @_;
	$items //= [];
	my $p     = $args{prefix} // 'xai.mgmt.data';
	my $count = scalar @{$items};
	my $bytes = 0;
	if ($store eq 'Files') {
		for my $it (@{$items}) {
			my $b = $it->{bytes} // $it->{size} // 0;
			$bytes += $b if $b =~ /^\d+$/;
		}
	}
	$kv->kv("$p.store", $store);
	$kv->kv("$p.count", $count);
	$kv->kv("$p.total_bytes", $bytes) if $store eq 'Files';
	return $kv;
}

sub format_cat {
	my ($class, $result) = @_;
	$result //= {};
	if (($result->{type} // '') eq 'content') {
		my $raw = $result->{bytes} // '';
		if ($raw =~ /[^\x09\x0a\x0d\x20-\x7e]/) {
			return sprintf("# binary content (%d bytes) from %s\n", length($raw), $result->{path} // '?');
		}
		return $raw;
	}
	my $json = JSON::PP->new->pretty->canonical->encode($result->{data} // {});
	return $json;
}

sub run_command {
	my ($class, %args) = @_;
	my $cmd   = lc($args{cmd}   // 'ls');
	my $store = $class->normalize_store($args{store} // 'Files');
	my $id    = $args{id};
	my $api   = $args{api};

	die "unknown cmd '$cmd' (try ls lsl cat size)\n"
		unless $cmd =~ /^(ls|lsl|cat|size)$/;

	if ($cmd eq 'cat') {
		my $result = $class->get_item(api => $api, store => $store, id => $id);
		return $class->format_cat($result);
	}

	my ($items) = $class->list_items(api => $api, store => $store);
	return $class->format_size($items, $store) if $cmd eq 'size';
	return $class->format_lsl($items, $store)   if $cmd eq 'lsl';
	return $class->format_ls($items, $store);
}

1;