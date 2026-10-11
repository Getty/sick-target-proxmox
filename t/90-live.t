#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw( tempdir );

# The real thing: a certificate of a throwaway CA goes onto a real Proxmox VE
# node or Proxmox Backup Server, through SICK::Runner, and the port has to
# present it afterwards.
#
# THIS CHANGES THE NODE: its custom certificate is replaced and its proxy
# reloaded. Point it at a node you may do that to; the way back is in the
# documentation of the type.
#
#   SICK_PROXMOX_LIVE_TYPE         proxmox-ve or proxmox-bs (required)
#   SICK_PROXMOX_LIVE_HOST         address or name of the node (required)
#   SICK_PROXMOX_LIVE_TOKEN_ID     sick@pve!sick, sick@pbs!sick (required)
#   SICK_PROXMOX_LIVE_TOKEN_FILE   file with the secret on its first line (required)
#   SICK_PROXMOX_LIVE_NODE         the node name (proxmox-ve, required there)
#   SICK_PROXMOX_LIVE_CA           a ca file (the cluster CA of PVE), and/or
#   SICK_PROXMOX_LIVE_FINGERPRINT  the SHA-256 of the presented certificate
#   SICK_PROXMOX_LIVE_PORT         default 8006 / 8007
#   SICK_PROXMOX_LIVE_NAMES        names of the certificate, comma separated;
#                                  default: the host

my %live = map { $_ => $ENV{ 'SICK_PROXMOX_LIVE_'.$_ } } qw( TYPE HOST TOKEN_ID TOKEN_FILE NODE CA FINGERPRINT PORT NAMES );
plan skip_all => 'set SICK_PROXMOX_LIVE_TYPE, _HOST, _TOKEN_ID, _TOKEN_FILE and _CA or _FINGERPRINT to run against a node'
  unless ( grep { defined $live{$_} && length $live{$_} } qw( TYPE HOST TOKEN_ID TOKEN_FILE ) ) == 4
  && ( defined $live{CA} || defined $live{FINGERPRINT} );

require SICK::Config;
require SICK::Issuer;
require SICK::OpenSSL;
require SICK::Runner;

plan skip_all => 'openssl is not installed' unless SICK::OpenSSL::available();

my $ve    = $live{TYPE} eq 'proxmox-ve';
my $dir   = tempdir( CLEANUP => 1 );
my $port  = $live{PORT} || ( $ve ? 8006 : 8007 );
my @names = split /\s*,\s*/, $live{NAMES} || $live{HOST};

# the secret, only to make sure that it shows up nowhere
my $secret = do {
  open my $fh, '<', $live{TOKEN_FILE} or BAIL_OUT( 'cannot read the token file \''.$live{TOKEN_FILE}.'\': '.$! );
  my $line = <$fh>;
  $line =~ s/\r?\n\z//;
  $line;
};

my $yaml = "ca:\n  type: selfsigned\n  dir: '$dir/ca'\n"
  ."defaults:\n  lifetime: 30d\n  renew_before: 7d\n  key: rsa2048\n"
  ."devices:\n  node:\n    type: $live{TYPE}\n    host: '$live{HOST}'\n    port: $port\n"
  .'    names: ['.join( ', ', map { '\''.$_.'\'' } @names )."]\n"
  ."    token_id: '$live{TOKEN_ID}'\n    token_file: '$live{TOKEN_FILE}'\n"
  .( $ve ? "    node: '$live{NODE}'\n" : q{} )
  .( defined $live{FINGERPRINT} ? "    fingerprint: '$live{FINGERPRINT}'\n" : q{} )
  ."    ca:\n      - '$dir/ca/ca.crt'\n"
  .( defined $live{CA} ? "      - '$live{CA}'\n" : q{} );

my $config = SICK::Config->load_string( $yaml, 'live device list' );
my $issuer = SICK::Issuer->from_ca( %{ $config->ca } );
my $root   = $issuer->root_pem;
my @log;
my $runner = SICK::Runner->new( config => $config, issuer => $issuer, log => sub { push @log, $_[0]; note $_[0] } );

my ($before) = $runner->check;
isnt( $before->{reason}, 'unreachable', 'the node answers on its port' ) or BAIL_OUT( $before->{detail} );

my ($first) = $runner->run;
is( $first->{action}, 'renewed', 'first run: renewed' ) or diag $first->{error};

my ($after) = $runner->check;
is( $after->{reason}, 'ok', 'the node presents the certificate of the throwaway CA' ) or diag $after->{detail};
ok( $after->{presented} && $after->{presented}->is_issued_by($root), '  issued by its root' );

my ($second) = $runner->run;
is( $second->{action}, 'unchanged', 'second run: unchanged' ) or diag $second->{error};

my $all = join "\n", @log, map { defined $_ ? $_ : q{} } $first->{error}, $second->{error}, $after->{detail};
ok( index( $all, $secret ) < 0, 'the secret is in no log line and no message' );

done_testing;
