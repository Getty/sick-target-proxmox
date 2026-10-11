package Test::SICK::Proxmox::PKI;

# Test helper: certificate authorities, certificates and keys, made at test
# time with the openssl program in a temporary directory. Nothing here is a
# real certificate or key of anything; every one of them exists for the
# length of a test.
#
#   my $pki  = Test::SICK::Proxmox::PKI->new( dir => $dir );
#   my $root = $pki->ca( 'root', '/CN=Test Root CA' );
#   my $int  = $pki->ca( 'int', '/CN=Test Intermediate CA', $root );
#   my $leaf = $pki->leaf( 'node', '/CN=pve1', 'IP:127.0.0.1,DNS:pve1', $int );
#   my $self = $pki->leaf( 'pbs', '/CN=pbs1', 'DNS:localhost,DNS:pbs1' );   # self-signed
#
# Each returns a hash: cert (path), key (path), pem (the certificate),
# key_pem, chain_pem (the intermediates up to, not including, the root),
# served (path of the certificate followed by its chain, as a server
# presents it) and fingerprint (SHA-256, 64 lower-case hex digits).
#
# Keys are EC P-256: quick to make, and nothing in these tests depends on
# the kind of key.

use strict;
use warnings;
use Carp qw( croak );
use SICK::OpenSSL;

my $CONFIG = <<'CONFIG';
[req]
distinguished_name = dn
prompt             = no
[dn]
CN = unused
[ca_ext]
basicConstraints       = critical,CA:TRUE
keyUsage               = critical,keyCertSign,cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid
[leaf_ext]
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature,keyEncipherment
extendedKeyUsage       = serverAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid
subjectAltName         = $ENV::SAN
CONFIG

sub new {
  my ( $class, %arg ) = @_;
  croak 'PKI needs a dir' unless defined $arg{dir} && -d $arg{dir};
  my $self = bless { dir => $arg{dir}, serial => 4096 }, $class;
  $self->{config} = $self->_spew( 'openssl.cnf', $CONFIG );
  return $self;
}

sub dir { $_[0]{dir} }

# ca( $name, $subject, $issuer ) - a root without $issuer
sub ca {
  my ( $self, $name, $subject, $issuer ) = @_;
  return $self->_make( $name, $subject, 'ca_ext', 'DNS:unused.invalid', $issuer );
}

# leaf( $name, $subject, $san, $issuer ) - self-signed without $issuer
sub leaf {
  my ( $self, $name, $subject, $san, $issuer ) = @_;
  return $self->_make( $name, $subject, 'leaf_ext', $san, $issuer );
}

# A key that belongs to no certificate here.
sub stray_key {
  my ( $self, $name ) = @_;
  my $key = $self->{dir}.'/'.$name.'.key';
  $self->_openssl( [ 'genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', $key ] );
  return $self->_slurp($key);
}

sub _make {
  my ( $self, $name, $subject, $ext, $san, $issuer ) = @_;
  my $dir  = $self->{dir};
  my $key  = $dir.'/'.$name.'.key';
  my $cert = $dir.'/'.$name.'.crt';
  my %env  = ( SAN => $san, OPENSSL_CONF => $self->{config} );
  $self->_openssl( [ 'genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', $key ] );
  if ($issuer) {
    my $csr = $dir.'/'.$name.'.csr';
    $self->_openssl( [ 'req', '-new', '-config', $self->{config}, '-key', $key, '-subj', $subject, '-out', $csr ], \%env );
    $self->_openssl(
      [ 'x509', '-req', '-in', $csr, '-CA', $issuer->{cert}, '-CAkey', $issuer->{key},
        '-set_serial', $self->{serial}++, '-days', '30', '-sha256',
        '-extfile', $self->{config}, '-extensions', $ext, '-out', $cert ],
      \%env,
    );
  }
  else {
    $self->_openssl(
      [ 'req', '-new', '-x509', '-config', $self->{config}, '-extensions', $ext, '-key', $key,
        '-subj', $subject, '-days', '30', '-sha256', '-set_serial', $self->{serial}++, '-out', $cert ],
      \%env,
    );
  }
  my $pem = $self->_slurp($cert);
  # the chain a server sends along: the intermediates, never the root
  my $chain = q{};
  if ( $issuer && $issuer->{issuer} ) {
    $chain = $issuer->{pem}.$issuer->{chain_pem};
  }
  my $fingerprint = SICK::OpenSSL::run_checked( [ 'x509', '-noout', '-fingerprint', '-sha256', '-in', $cert ] );
  $fingerprint =~ s/\A.*=//s;
  $fingerprint =~ s/\s+//g;
  ( $fingerprint = lc $fingerprint ) =~ tr/://d;
  return {
    name        => $name,
    cert        => $cert,
    key         => $key,
    pem         => $pem,
    key_pem     => $self->_slurp($key),
    chain_pem   => $chain,
    served      => $self->_spew( $name.'.served.pem', $pem.$chain ),
    fingerprint => $fingerprint,
    issuer      => $issuer ? $issuer->{name} : undef,
  };
}

sub _openssl {
  my ( $self, $args, $env ) = @_;
  return SICK::OpenSSL::run_checked( $args, ( $env ? ( env => $env ) : () ), umask => 077 );
}

sub _slurp {
  my ( $self, $path ) = @_;
  open my $fh, '<', $path or croak 'cannot read '.$path.': '.$!;
  local $/;
  my $content = <$fh>;
  close $fh;
  return $content;
}

sub _spew {
  my ( $self, $name, $content ) = @_;
  my $path = $self->{dir}.'/'.$name;
  open my $fh, '>', $path or croak 'cannot write '.$path.': '.$!;
  print {$fh} $content;
  close $fh or croak 'cannot write '.$path.': '.$!;
  return $path;
}

1;
