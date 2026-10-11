#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw( tempdir );
use lib 't/lib';

use HTTP::Tiny;
use IO::Socket::SSL qw( SSL_VERIFY_PEER );
use SICK::OpenSSL;
use SICK::Target::Proxmox::Client;
use Test::SICK::Proxmox qw( fixtures random_secret standin );

# SICK::Target::Proxmox::Client: the options it hands to HTTP::Tiny, and that
# nothing in the environment loosens them - checked on the options and
# against the stand-in.

plan skip_all => 'openssl is not installed' unless SICK::OpenSSL::available();

my $dir    = tempdir( CLEANUP => 1 );
my $f      = fixtures($dir);
my $secret = random_secret();
my $Client = 'SICK::Target::Proxmox::Client';

subtest 'constructor' => sub {
  ok( !eval { $Client->new( host => '127.0.0.1', port => 8006 ); 1 }, 'no anchor: refused' );
  like( $@, qr/needs at least one ca file, root or fingerprint/, '  with the reason' );
  ok( !eval { $Client->new( host => '127.0.0.1', port => 8006, roots => [] ); 1 }, 'an empty list of roots is no anchor' );
  ok( !eval { $Client->new( host => '127.0.0.1', port => 8006, roots => ['nothing'] ); 1 }, 'a root that is no PEM: refused' );
  like( $@, qr/a root that is no PEM certificate/, '  with the reason' );
  ok( !eval { $Client->new( host => '127.0.0.1', port => 8006, fingerprints => ['abc'] ); 1 }, 'a bad fingerprint: refused' );
  like( $@, qr/invalid SHA-256 fingerprint 'abc'/, '  naming it' );
  is( $Client->normalize_fingerprint( join ':', map { uc } ( 'a1' x 32 ) =~ /(..)/g ), 'a1' x 32, 'fingerprints are normalized' );
  is( $Client->format_fingerprint( 'a1' x 32 ), join( ':', ('a1') x 32 ), 'and shown with colons' );
};

subtest 'ssl options: ca only' => sub {
  my $client = $Client->new( host => 'pve1.example.internal', port => 8006, ca => [ $f->{cluster_ca}{cert}, $f->{root}{cert} ] );
  my $ssl = $client->ssl_options;
  is( $ssl->{SSL_verify_mode}, SSL_VERIFY_PEER, 'the peer is verified' );
  is( $ssl->{SSL_verifycn_scheme}, 'http', 'its name is checked as for HTTPS' );
  is( $ssl->{SSL_verifycn_name}, 'pve1.example.internal', 'against the host' );
  is( $ssl->{SSL_hostname}, 'pve1.example.internal', 'which is the SNI' );
  ok( !exists $ssl->{SSL_fingerprint}, 'no pins' );
  ok( -r $ssl->{SSL_ca_file}, 'one ca file' );
  my $pem = do { local ( @ARGV, $/ ) = $ssl->{SSL_ca_file}; <> };
  is( scalar( () = $pem =~ /-----BEGIN CERTIFICATE-----/g ), 2, 'holding the certificates of both ca files' );
  like( $client->anchors, qr/\Aca \Q$f->{cluster_ca}{cert}\E, \Q$f->{root}{cert}\E\z/, 'anchors names the files' );
};

subtest 'ssl options: pins only' => sub {
  my $client = $Client->new( host => '127.0.0.1', port => 8007, fingerprints => [ $f->{pbs_fresh}{fingerprint} ] );
  my $ssl = $client->ssl_options;
  is_deeply( $ssl->{SSL_fingerprint}, [ 'sha256$'.$f->{pbs_fresh}{fingerprint} ], 'the pin, as sha256$hex' );
  is( $ssl->{SSL_force_fingerprint}, 1, 'forced: without a ca file, only the pin counts' );
  ok( !exists $ssl->{SSL_ca_file}, 'no ca file of ours' );
  is( $ssl->{SSL_hostname}, q{}, 'no SNI for an address' );
  is( $ssl->{SSL_verifycn_name}, '127.0.0.1', 'the name check is still set up (a pin match passes without it)' );
};

subtest 'ssl options: ca and pins' => sub {
  my $client = $Client->new( host => '127.0.0.1', port => 8007, ca => $f->{root}{cert}, fingerprints => $f->{pbs_fresh}{fingerprint} );
  my $ssl = $client->ssl_options;
  ok( $ssl->{SSL_ca_file} && $ssl->{SSL_fingerprint}, 'both' );
  ok( !$ssl->{SSL_force_fingerprint}, 'not forced: a certificate that misses the pin goes to the ca check' );
};

my $root_pem = do { local ( @ARGV, $/ ) = $f->{root}{cert}; <> };

subtest 'ssl options: roots of the run' => sub {
  my $client = $Client->new( host => '127.0.0.1', port => 8006, roots => [$root_pem] );
  my $ssl = $client->ssl_options;
  ok( -r $ssl->{SSL_ca_file}, 'the roots go into the ca file' );
  my $pem = do { local ( @ARGV, $/ ) = $ssl->{SSL_ca_file}; <> };
  is( $pem, $root_pem, '  holding the root' );
  is( $client->anchors, 'the roots of the run (1)', 'anchors counts them' );

  $client = $Client->new( host => '127.0.0.1', port => 8006, ca => $f->{cluster_ca}{cert}, roots => [$root_pem] );
  $pem = do { local ( @ARGV, $/ ) = $client->ssl_options->{SSL_ca_file}; <> };
  is( scalar( () = $pem =~ /-----BEGIN CERTIFICATE-----/g ), 2, 'next to a ca file: one file with both' );

  $client = $Client->new( host => '127.0.0.1', port => 8007, roots => [$root_pem], fingerprints => $f->{pbs_fresh}{fingerprint} );
  ok( !$client->ssl_options->{SSL_force_fingerprint}, 'with a pin: not forced, the roots are a ca' );
};

subtest 'the HTTP client ignores the environment' => sub {
  local $ENV{PERL_HTTP_TINY_SSL_INSECURE_BY_DEFAULT} = 1;
  local $ENV{https_proxy} = 'http://127.0.0.1:9';
  local $ENV{HTTPS_PROXY} = 'http://127.0.0.1:9';
  local $ENV{all_proxy}   = 'http://127.0.0.1:9';
  my $client = $Client->new( host => '127.0.0.1', port => 8006, ca => $f->{root}{cert} );
  my $http   = $client->_http;
  ok( $http->verify_SSL, 'verify_SSL is on although PERL_HTTP_TINY_SSL_INSECURE_BY_DEFAULT says otherwise' );
  ok( !defined $http->https_proxy && !defined $http->proxy, 'no proxy taken from the environment' );
  is( $http->max_redirect, 0, 'no redirects' );
  ok( !$http->keep_alive, 'no keep-alive' );
};

# post_json against the stand-in. The header is right; what decides is the
# certificate the port presents.
sub post {
  my ( $standin, %anchor ) = @_;
  my $client = $Client->new( host => '127.0.0.1', port => $standin->port, %anchor );
  return $client->post_json( '/api2/json/nodes/localhost/certificates/custom', 'PBSAPIToken=sick@pbs!sick:'.$secret,
    { certificates => $f->{issued}{pem}.$f->{issued}{chain_pem}, key => $f->{issued}{key_pem} } );
}

subtest 'a pin matches: the name is not checked' => sub {
  my $standin = standin( 'bs', $f, $dir, $secret );
  my $res = post( $standin, fingerprints => [ $f->{pbs_fresh}{fingerprint} ] );
  is( $res->{status}, 200, 'the self-signed certificate without 127.0.0.1 among its names passes by its pin' ) or diag $res->{content};
};

subtest 'a pin misses, the ca decides' => sub {
  my $standin = standin( 'bs', $f, $dir, $secret, serve => $f->{issued} );
  my $res = post( $standin, ca => $f->{root}{cert}, fingerprints => [ $f->{stranger}{fingerprint} ] );
  is( $res->{status}, 200, 'our certificate passes by our root although the pin does not match' ) or diag $res->{content};
};

subtest 'trusted by the roots of the run alone' => sub {
  my $standin = standin( 'bs', $f, $dir, $secret, serve => $f->{issued} );
  my $res = post( $standin, roots => [$root_pem] );
  is( $res->{status}, 200, 'our certificate, served with the intermediate, passes by the root of the run' ) or diag $res->{content};

  my $stranger = standin( 'bs', $f, $dir, $secret, serve => $f->{stranger} );
  $res = post( $stranger, roots => [$root_pem] );
  is( $res->{status}, 599, 'a certificate that chains to nothing named: no answer' );
  like( $res->{content}, qr/certificate verify failed/, '  the certificate did not pass' );
  ok( $stranger->settle, 'the stand-in is through with every connection' );
  is( scalar $stranger->requests, 0, 'the stand-in read no request' );
};

subtest 'the environment does not make a stranger trusted' => sub {
  # SSL_CERT_FILE names the CA of the stranger: a client that falls back to
  # the store of the environment would accept it.
  local $ENV{SSL_CERT_FILE} = $f->{stranger_ca}{cert};
  local $ENV{SSL_CERT_DIR}  = $f->{pki}->dir;
  local $ENV{PERL_HTTP_TINY_SSL_INSECURE_BY_DEFAULT} = 1;

  my $standin = standin( 'bs', $f, $dir, $secret, serve => $f->{stranger} );
  my $res = post( $standin, ca => $f->{root}{cert} );
  is( $res->{status}, 599, 'with a ca of ours: no answer' );
  like( $res->{content}, qr/certificate verify failed/, '  the certificate did not pass' );

  $res = post( $standin, fingerprints => [ $f->{pbs_fresh}{fingerprint} ] );
  is( $res->{status}, 599, 'with a pin only: no answer either, the pin is forced' );
  like( $res->{content}, qr/certificate verify failed/, '  the certificate did not pass' );

  ok( $standin->settle, 'the stand-in is through with every connection' );
  is( scalar $standin->requests, 0, 'the stand-in read no request' );
  is( $standin->handshakes_failed, 2, 'both handshakes failed' );
  is( $standin->handshakes_ok, 0, 'none completed' );
};

done_testing;
