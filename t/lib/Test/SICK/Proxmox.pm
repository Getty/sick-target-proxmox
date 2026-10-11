package Test::SICK::Proxmox;

# Test helper: the certificates of the scenarios, devices, token files and a
# secret made at test time. Neutral names only (pve1, pbs1, example.internal).
#
#   my $f = Test::SICK::Proxmox::fixtures($dir);
#   $f->{cluster_ca}     the cluster CA of a PVE cluster (pve-root-ca.pem)
#   $f->{pve_fresh}      pve-ssl.pem of a fresh node, signed by it, with
#                        127.0.0.1 among its names, served alone
#   $f->{pve_misnamed}   signed by the cluster CA, without 127.0.0.1
#   $f->{root}           our root
#   $f->{int}            our intermediate, signed by the root
#   $f->{issued}         a certificate of ours for 127.0.0.1, through the
#                        intermediate, served with the intermediate
#   $f->{issued2}        another one, for the same names
#   $f->{stranger_ca}    a CA nobody named
#   $f->{stranger}       a certificate of it for 127.0.0.1
#   $f->{pbs_fresh}      the self-signed proxy.pem of a fresh PBS: DNS
#                        names only, no address

use strict;
use warnings;
use Exporter qw( import );
use SICK::Bundle;
use SICK::Device;
use Test::SICK::Proxmox::PKI;
use Test::SICK::Proxmox::StandIn;

our @EXPORT_OK = qw( fixtures bundle_of device_for token_file random_secret standin spew );

sub fixtures {
  my ( $dir ) = @_;
  mkdir $dir.'/pki' or die 'cannot create '.$dir.'/pki: '.$!;
  my $pki = Test::SICK::Proxmox::PKI->new( dir => $dir.'/pki' );
  my %f;
  $f{cluster_ca}   = $pki->ca( 'cluster-ca', '/O=PVE Cluster Manager CA/OU=test/CN=Proxmox Virtual Environment' );
  $f{pve_fresh}    = $pki->leaf( 'pve-ssl', '/O=Proxmox Virtual Environment/OU=PVE Cluster Node/CN=pve1.example.internal',
    'IP:127.0.0.1,IP:::1,DNS:localhost,DNS:pve1,DNS:pve1.example.internal', $f{cluster_ca} );
  $f{pve_misnamed} = $pki->leaf( 'pve-misnamed', '/CN=pve1.example.internal',
    'DNS:pve1,DNS:pve1.example.internal', $f{cluster_ca} );
  $f{root}         = $pki->ca( 'root', '/CN=Test Root CA' );
  $f{int}          = $pki->ca( 'int', '/CN=Test Intermediate CA', $f{root} );
  $f{issued}       = $pki->leaf( 'issued', '/CN=127.0.0.1', 'IP:127.0.0.1,DNS:pve1.example.internal', $f{int} );
  $f{issued2}      = $pki->leaf( 'issued2', '/CN=127.0.0.1', 'IP:127.0.0.1,DNS:pve1.example.internal', $f{int} );
  $f{stranger_ca}  = $pki->ca( 'stranger-ca', '/CN=Stranger CA' );
  $f{stranger}     = $pki->leaf( 'stranger', '/CN=127.0.0.1', 'IP:127.0.0.1', $f{stranger_ca} );
  $f{pbs_fresh}    = $pki->leaf( 'proxy', '/O=Proxmox Backup Server/OU=TEST/CN=pbs1.example.internal',
    'DNS:localhost,DNS:pbs1,DNS:pbs1.example.internal' );
  $f{pki}          = $pki;
  return \%f;
}

# The bundle an issuer would hand out for a certificate of the fixtures.
sub bundle_of {
  my ( $cert, %arg ) = @_;
  return SICK::Bundle->new(
    cert  => $cert->{pem},
    chain => length $cert->{chain_pem} ? $cert->{chain_pem} : undef,
    key   => exists $arg{key} ? $arg{key} : $cert->{key_pem},
  );
}

# device_for( 've', port => $port, %options )
sub device_for {
  my ( $product, %arg ) = @_;
  my $port  = delete $arg{port};
  my $host  = exists $arg{host} ? delete $arg{host} : '127.0.0.1';
  my $names = delete $arg{names} || ['127.0.0.1'];
  my $name  = delete $arg{name} || ( $product eq 've' ? 'pve1' : 'pbs1' );
  return SICK::Device->new(
    name         => $name,
    type         => $product eq 've' ? 'proxmox-ve' : 'proxmox-bs',
    host         => $host,
    ( defined $port ? ( port => $port ) : () ),
    names        => $names,
    lifetime     => 30 * 86400,
    renew_before => 7 * 86400,
    key          => 'rsa2048',
    options      => \%arg,
  );
}

sub spew {
  my ( $path, $content, $mode ) = @_;
  open my $fh, '>', $path or die 'cannot write '.$path.': '.$!;
  print {$fh} $content;
  close $fh or die 'cannot write '.$path.': '.$!;
  chmod $mode, $path if defined $mode;
  return $path;
}

sub token_file {
  my ( $dir, $secret, $name ) = @_;
  return spew( $dir.'/'.( defined $name ? $name : 'token' ), $secret."\n", 0600 );
}

# A secret made here and now, of the shape Proxmox hands out (a UUID).
sub random_secret {
  open my $fh, '<', '/dev/urandom' or die 'cannot read /dev/urandom: '.$!;
  read $fh, my $bytes, 16;
  close $fh;
  my $hex = unpack 'H*', $bytes;
  return join '-', unpack 'A8 A4 A4 A4 A12', $hex;
}

# standin( 've', $f, $dir, $secret, %more ) - short delays unless given
sub standin {
  my ( $product, $f, $dir, $secret, %arg ) = @_;
  return Test::SICK::Proxmox::StandIn->start(
    product    => $product,
    dir        => $dir,
    serve      => $product eq 've' ? $f->{pve_fresh} : $f->{pbs_fresh},
    token_id   => $product eq 've' ? 'sick@pve!sick' : 'sick@pbs!sick',
    secret     => $secret,
    node       => 'pve1',
    auth_delay => 0.1,
    perm_delay => 0.05,
    %arg,
  );
}

1;
