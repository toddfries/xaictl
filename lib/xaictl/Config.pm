package xaictl::Config;

use strict;
use warnings;
use Config::Tiny;

our $VERSION = '0.01';

sub default_config_path {
	return $ENV{HOME} . '/.config/cxai/grok.conf';
}

sub read_config {
	my ($class, $path) = @_;
	$path //= $class->default_config_path();
	return {} unless -f $path;

	my $config = Config::Tiny->read($path);
	die "config file '$path' does not parse: " . Config::Tiny->errstr
		unless defined $config;

	my %out;
	for my $section (keys %{$config}) {
		next unless defined $config->{$section};
		%{$out{$section}} = %{$config->{$section}};
	}
	return \%out;
}

sub bearer_token {
	my ($class, %args) = @_;
	return $ENV{XAI_API_KEY} if defined $ENV{XAI_API_KEY} && $ENV{XAI_API_KEY} ne '';

	my $conf    = $args{config};
	my $section = $args{section} // 'creds';
	return undef unless defined $conf && ref $conf eq 'HASH';
	my $c = $conf->{$section};
	return undef unless defined $c && ref $c eq 'HASH';
	return $c->{bearer} // $c->{token} // $c->{api_key};
}

sub management_key {
	my ($class, %args) = @_;
	return $ENV{XAI_MANAGEMENT_API_KEY}
		if defined $ENV{XAI_MANAGEMENT_API_KEY} && $ENV{XAI_MANAGEMENT_API_KEY} ne '';

	my $conf    = $args{config};
	my $section = $args{mgmt_section} // 'mgmt';
	return undef unless defined $conf && ref $conf eq 'HASH';
	my $c = $conf->{$section};
	return undef unless defined $c && ref $c eq 'HASH';
	return $c->{management_key} // $c->{bearer} // $c->{key};
}

1;