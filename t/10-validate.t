#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw( tempdir );
use lib 't/lib';

use SICK::Config;
use SICK::Target;
use SICK::Target::ProxmoxBS;
use SICK::Target::ProxmoxVE;
use Test::SICK::Proxmox qw( device_for spew );

# validate: the options of the device list, before anything is issued or
# sent. No network, no token read.

my $dir = tempdir( CLEANUP => 1 );
my $ca  = spew( $dir.'/ca.pem', "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n" );
my $ca2 = spew( $dir.'/ca2.pem', "text before\n-----BEGIN CERTIFICATE-----\nBBBB\n-----END CERTIFICATE-----\n" );
my $not_ca = spew( $dir.'/not-ca.pem', "nothing in here\n" );
my $missing_token = $dir.'/no-such-token';    # validate must not read it
my $fp = 'ab' x 32;

my %CLASS = ( ve => 'SICK::Target::ProxmoxVE', bs => 'SICK::Target::ProxmoxBS' );
my %ID    = ( ve => 'sick@pve!sick', bs => 'sick@pbs!sick' );
my %PORT  = ( ve => 8006, bs => 8007 );

sub target {
  my ( $product, %options ) = @_;
  my %base = (
    port       => $PORT{$product},
    token_id   => $ID{$product},
    token_file => $missing_token,
    ca         => $ca,
    ( $product eq 've' ? ( node => 'pve1' ) : () ),
  );
  %base = ( %base, %options );
  my $roots = delete $base{trust_roots};
  delete $base{$_} for grep { !defined $base{$_} } keys %base;
  return $CLASS{$product}->new( device => device_for( $product, %base ), ( $roots ? ( trust_roots => $roots ) : () ) );
}

sub refused {
  my ( $product, $options, $expect, $name ) = @_;
  my $ok = eval { target( $product, %$options )->validate; 1 };
  my $error = $@;
  ok( !$ok, $name ) or return;
  like( $error, $expect, '  with the reason' );
  return $error;
}

for my $product (qw( ve bs )) {
  my $type = $product eq 've' ? 'proxmox-ve' : 'proxmox-bs';
  my $path = $product eq 've' ? 'devices.pve1' : 'devices.pbs1';

  subtest $type => sub {
    ok( eval { target($product)->validate; 1 }, 'a complete device passes, the token file is not read' ) or diag $@;
    ok( eval { target( $product, ca => [ $ca, $ca2 ] )->validate; 1 }, 'ca as a list' ) or diag $@;
    ok( eval { target( $product, ca => undef, fingerprint => $fp )->validate; 1 }, 'a fingerprint alone' ) or diag $@;
    ok( eval { target( $product, ca => undef, fingerprint => join( ':', map { uc } ( 'ab' x 32 ) =~ /(..)/g ) )->validate; 1 },
      'a fingerprint in upper case with colons' ) or diag $@;
    ok( eval { target( $product, fingerprint => [ $fp, 'cd' x 32 ] )->validate; 1 }, 'fingerprints as a list, next to ca' ) or diag $@;

    refused( $product, { token_id => undef }, qr/\A\Q$path\E: missing 'token_id'/, 'token_id is required' );
    refused( $product, { token_file => undef }, qr/\A\Q$path\E: missing 'token_file'/, 'token_file is required' );
    refused( $product, { colour => 'blue' }, qr/\A\Q$path\E: unknown key 'colour' for type '$type'/, 'unknown option' );

    refused( $product, { ca => undef }, qr/\A\Q$path\E: needs 'ca' or 'fingerprint' to trust/, 'no anchor: refused' );
    refused( $product, { ca => [] }, qr/\A\Q$path\E: 'ca' is an empty list/, 'an empty list of ca files is no anchor' );
    refused( $product, { ca => $dir.'/nope.pem' }, qr/\A\Q$path\E\.ca: cannot read ca file '\Q$dir\E\/nope\.pem': /,
      'a ca file that is not there' );
    refused( $product, { ca => $not_ca }, qr/\A\Q$path\E\.ca: ca file '\Q$not_ca\E' holds no PEM certificate/,
      'a ca file without a certificate' );
    refused( $product, { ca => { file => $ca } }, qr/'ca' must be a value or a list of values/, 'ca as a mapping' );

    for my $bad ( 'abc', 'ab' x 31, 'gg' x 32, 'ab:'.( 'ab' x 31 ), ( 'ab' x 32 ).'00' ) {
      refused( $product, { fingerprint => $bad }, qr/\A\Q$path\E\.fingerprint: invalid SHA-256 fingerprint '\Q$bad\E'/,
        'fingerprint '.$bad.' refused' );
    }
    refused( $product, { fingerprint => [ $fp, 'nope' ] }, qr/invalid SHA-256 fingerprint 'nope'/, 'one bad fingerprint in a list' );

    my $default = target( $product, port => undef );
    ok( eval { $default->validate; 1 }, 'no port: passes' ) or diag $@;
    is( $CLASS{$product}->default_port, $PORT{$product}, '  the type names its port as default_port' );
    is( ( $default->endpoint )[1], $PORT{$product}, '  and the target connects there' );
    my $nat = target( $product, port => 443 );
    ok( eval { $nat->validate; 1 }, 'port 443 written in the entry (a node behind port forwarding): passes' ) or diag $@;
    is( ( $nat->endpoint )[1], 443, '  and the target connects to 443' );

    my $root = "-----BEGIN CERTIFICATE-----\nCCCC\n-----END CERTIFICATE-----\n";
    ok( eval { target( $product, ca => undef, trust_roots => [$root] )->validate; 1 },
      'no ca and no fingerprint, but roots from the run: passes' ) or diag $@;
    my $error = refused( $product, { ca => undef, trust_roots => [] }, qr/\A\Q$path\E: needs 'ca' or 'fingerprint' to trust/,
      'no ca, no fingerprint and no roots from the run: refused' );
    like( $error, qr/the run hands it no roots of its CA; there is no other way/, '  saying that the run had no roots either' );

    refused( $product, { token_id => 'sick@pve' }, qr/\A\Q$path\E: invalid 'token_id'/, 'token_id without a token name' );
    refused( $product, { token_id => 'sick!sick' }, qr/invalid 'token_id'/, 'token_id without a realm' );
    refused( $product, { token_id => [ $ID{$product} ] }, qr/invalid 'token_id'/, 'token_id as a list' );
    refused( $product, { token_file => [ 'a', 'b' ] }, qr/'token_file' must be the path of a file/, 'token_file as a list' );

    # A secret pasted behind the token id must not end up in the message.
    my $pasted = 'a1b2c3d4-pasted-secret';
    my $joined = $product eq 've' ? $ID{ve}.'='.$pasted : $ID{bs}.':'.$pasted;
    $error = refused( $product, { token_id => $joined }, qr/invalid 'token_id'/, 'token_id with the secret appended' );
    unlike( $error, qr/\Q$pasted\E/, '  and the message does not quote it' );
  };
}

subtest 'proxmox-ve: token id and node' => sub {
  ok( eval { target( 've', token_id => 'sick@pam!sick-1.a_b' )->validate; 1 }, 'token name with digits, . _ -' ) or diag $@;
  refused( 've', { token_id => 'sick@pve!1sick' }, qr/invalid 'token_id'/, 'token name must start with a letter' );
  refused( 've', { token_id => 'sick@pve!s' }, qr/invalid 'token_id'/, 'token name of one character' );
  refused( 've', { node => undef }, qr/\Adevices\.pve1: missing 'node'/, 'node is required' );
  refused( 've', { node => $_ }, qr/\Adevices\.pve1: invalid 'node'/, 'node '.$_.' refused' ) for qw( pve_1 -pve pve- pve1.example.internal );
  ok( eval { target( 've', node => 'pve-1a' )->validate; 1 }, 'node pve-1a' ) or diag $@;
};

subtest 'proxmox-bs: token id, no node' => sub {
  ok( eval { target( 'bs', token_id => 'sick@pbs!1_sick' )->validate; 1 }, 'token name may start with a digit or _' ) or diag $@;
  ok( eval { target( 'bs', token_id => 'sick@pbs!s' )->validate; 1 }, 'token name of one character' ) or diag $@;
  refused( 'bs', { token_id => 'sick@pbs!.sick' }, qr/invalid 'token_id'/, 'token name must not start with .' );
  refused( 'bs', { node => 'pbs1' }, qr/unknown key 'node' for type 'proxmox-bs'/, 'node is no option of proxmox-bs' );
};

subtest 'from a device list' => sub {
  my $yaml = <<"YAML";
ca:
  type: selfsigned
  dir: $dir/sick-ca
devices:
  pve1:
    type: proxmox-ve
    host: pve1.example.internal
    port: 8006
    names: [pve1.example.internal]
    node: pve1
    token_id: sick\@pve!sick
    token_file: $missing_token
    ca:
      - $ca
      - $ca2
  pbs1:
    type: proxmox-bs
    host: pbs1.example.internal
    port: 8007
    names: [pbs1.example.internal]
    token_id: sick\@pbs!sick
    token_file: $missing_token
    fingerprint: @{[ join ':', ( 'ab' x 32 ) =~ /(..)/g ]}
    ca: $ca
YAML
  my $config = SICK::Config->load_string( $yaml, 'test list' );
  for my $name (qw( pve1 pbs1 )) {
    my $device = $config->device($name);
    my $target = SICK::Target->class_for( $device->type )->new( device => $device );
    ok( eval { $target->validate; 1 }, $name.' as written in the documentation' ) or diag $@;
  }
};

done_testing;
