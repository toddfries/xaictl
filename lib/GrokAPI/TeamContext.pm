package GrokAPI::TeamContext;

use strict;
use warnings;

our $VERSION = '0.02';

our $UUID_RE = qr/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i;

sub is_valid_team_id {
	my ($class, $team_id) = @_;
	return defined $team_id && $team_id ne '' && $team_id =~ $UUID_RE;
}

sub team_id_for_mgmt {
	my ($class, %args) = @_;
	my $explicit = $args{explicit};
	if (defined $explicit && $explicit ne '') {
		die "team_id invalid UUID format (not calling management API): $explicit\n"
			unless $class->is_valid_team_id($explicit);
		return $explicit;
	}

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