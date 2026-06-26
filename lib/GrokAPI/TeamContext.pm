package GrokAPI::TeamContext;

use strict;
use warnings;

our $VERSION = '0.01';

sub team_id_for_mgmt {
	my ($class, %args) = @_;
	my $explicit = $args{explicit};
	return $explicit if defined $explicit && $explicit ne '';

	my $bearer     = $args{bearer};
	my $keyinfo_cb = $args{keyinfo_cb};
	if (defined $bearer && $bearer ne '') {
		die "team_id keyinfo lookup requires keyinfo_cb\n" unless $keyinfo_cb;
		my $info = $keyinfo_cb->();
		die "keyinfo did not return team_id\n"
			unless defined $info && ref $info eq 'HASH'
			&& defined $info->{team_id} && $info->{team_id} ne '';
		return $info->{team_id};
	}

	die "team_id required (-T) or inference bearer for keyinfo lookup\n";
}

1;