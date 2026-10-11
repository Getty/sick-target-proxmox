#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw( tempdir );
use lib 't/lib';

use SICK::Config;
use SICK::Issuer;
use SICK::OpenSSL;
use SICK::Runner;
use Test::SICK::Proxmox qw( fixtures token_file random_secret standin );

# Both types through SICK::Runner, against the stand-in: check, issue
# (SICK::Issuer::SelfSigned), deploy, and the port asked again. The run
# counts a device as renewed only when the port presents the new
# certificate.

plan skip_all => 'openssl is not installed' unless SICK::OpenSSL::available();

my $dir    = tempdir( CLEANUP => 1 );
my $f      = fixtures($dir);
my $secret = random_secret();
my $token  = token_file( $dir, $secret );

my $pve  = standin( 've', $f, $dir, $secret, restart_delay => 1 );
my $pbs  = standin( 'bs', $f, $dir, $secret );
my $pbs2 = standin( 'bs', $f, $dir, $secret, reload_fails => 1 );
my $pbs3 = standin( 'bs', $f, $dir, $secret );

my $yaml = <<"YAML";
ca:
  type: selfsigned
  dir: $dir/sick-ca
defaults:
  lifetime: 30d
  renew_before: 7d
  key: ec256
devices:
  pve1:
    type: proxmox-ve
    host: 127.0.0.1
    port: @{[ $pve->port ]}
    names: [127.0.0.1]
    node: pve1
    token_id: sick\@pve!sick
    token_file: $token
    ca: [ $f->{cluster_ca}{cert}, $dir/sick-ca/ca.crt ]
  pbs1:
    type: proxmox-bs
    host: 127.0.0.1
    port: @{[ $pbs->port ]}
    names: [127.0.0.1]
    token_id: sick\@pbs!sick
    token_file: $token
    fingerprint: $f->{pbs_fresh}{fingerprint}
    ca: $dir/sick-ca/ca.crt
  pbs2:
    type: proxmox-bs
    host: 127.0.0.1
    port: @{[ $pbs2->port ]}
    names: [127.0.0.1]
    token_id: sick\@pbs!sick
    token_file: $token
    fingerprint: $f->{pbs_fresh}{fingerprint}
    ca: $dir/sick-ca/ca.crt
  pbs3:
    type: proxmox-bs
    host: 127.0.0.1
    port: @{[ $pbs3->port ]}
    names: [127.0.0.1]
    token_id: sick\@pbs!sick
    token_file: $token
    fingerprint: $f->{pbs_fresh}{fingerprint}
YAML

my $config = SICK::Config->load_string( $yaml, 'test list' );
my $issuer = SICK::Issuer->from_ca( %{ $config->ca } );
ok( $issuer->root_pem, 'the throwaway CA exists, so that its root can be named in ca' );

my @log;
my $runner = SICK::Runner->new(
  config          => $config,
  issuer          => $issuer,
  log             => sub { push @log, $_[0]; note $_[0] },
  verify_timeout  => 5,
  verify_interval => 0.2,
);

my %check = map { $_->{device} => $_ } $runner->check( 'pve1', 'pbs1' );
is( $check{pve1}{reason}, 'foreign-ca', 'pve1 presents the certificate of its cluster CA: foreign-ca' );
is( $check{pbs1}{reason}, 'foreign-ca', 'pbs1 presents its self-signed certificate: foreign-ca' );
is( scalar $pve->requests, 0, 'checking sends nothing to pve1' );
is( scalar $pbs->requests, 0, 'nor to pbs1' );

my %first = map { $_->{device} => $_ } $runner->run( [ 'pve1', 'pbs1' ] );
for my $name (qw( pve1 pbs1 )) {
  is( $first{$name}{action}, 'renewed', 'first run: '.$name.' renewed' ) or diag $first{$name}{error};
  is( $first{$name}{error}, undef, '  without an error' );
}
is( scalar $pve->uploads, 1, 'pve1 got one upload' );
is( scalar $pbs->uploads, 1, 'pbs1 got one upload' );
ok( scalar( grep { /\Apve1: uploaded the certificate/ } @log ), 'the target logged the upload' );

my $root = $issuer->root_pem;
for my $name (qw( pve1 pbs1 )) {
  my ($state) = $runner->check($name);
  is( $state->{reason}, 'ok', $name.' now presents a certificate of the throwaway CA' );
  ok( $state->{presented} && $state->{presented}->is_issued_by($root), '  issued by its root' );
}

my %second = map { $_->{device} => $_ } $runner->run( [ 'pve1', 'pbs1' ] );
for my $name (qw( pve1 pbs1 )) {
  is( $second{$name}{action}, 'unchanged', 'second run: '.$name.' unchanged' ) or diag $second{$name}{error};
}
is( scalar $pve->uploads, 1, 'pve1 got no second upload' );
is( scalar $pbs->uploads, 1, 'pbs1 got no second upload' );
is( scalar $pve->requests, 1, 'and no request at all: the token stayed home' );

# Proxmox Backup Server answers 200 when the proxy fails to load the new
# files, and keeps serving the old certificate (docs/api-notes.md). Only the
# second look at the port finds that out.
my ($kept) = $runner->run( ['pbs2'] );
is( $kept->{action}, 'failed', 'pbs2: the upload was answered 200, the port kept the old certificate: failed' );
like( $kept->{error}, qr/\Averification failed: the device does not present the new certificate/, '  at the verification' );
is( scalar $pbs2->uploads, 1, '  after one upload' );
is( ( $pbs2->uploads )[0]{status}, 200, '  which was answered 200' );

# pbs3 names only the pin of its fresh certificate, no ca: after the first
# upload the pin is stale, and the second upload passes by the root the run
# hands the target (SICK::Target/trust_roots).
my ($pinned) = $runner->run( ['pbs3'] );
is( $pinned->{action}, 'renewed', 'pbs3, pin only: first run renewed' ) or diag $pinned->{error};
my ($by_root) = $runner->run( ['pbs3'], force => 1 );
is( $by_root->{action}, 'renewed', 'pbs3, forced again: the stale pin misses, the root of the run lets the upload through' )
  or diag $by_root->{error};
is( scalar $pbs3->uploads, 2, '  two uploads' );

done_testing;
