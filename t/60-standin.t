#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw( tempdir );
use Time::HiRes qw( time sleep );
use lib 't/lib';

use HTTP::Tiny;
use JSON::MaybeXS qw( decode_json encode_json );
use SICK::OpenSSL;
use SICK::Target::Proxmox::Client;
use Test::SICK::Proxmox qw( fixtures random_secret standin );

# The stand-in itself: the answers of docs/api-notes.md that the targets
# never provoke - a request without a token, a key that does not belong, a
# missing force, booleans as strings. If one of these goes red, the stand-in
# has drifted from the notes.

plan skip_all => 'openssl is not installed' unless SICK::OpenSSL::available();

my $dir    = tempdir( CLEANUP => 1 );
my $f      = fixtures($dir);
my $secret = random_secret();
my $stray  = $f->{pki}->stray_key('stray');
my $chain  = $f->{issued}{pem}.$f->{issued}{chain_pem};

my %HEADER = ( ve => 'PVEAPIToken=sick@pve!sick='.$secret, bs => 'PBSAPIToken=sick@pbs!sick:'.$secret );
my %PIN    = ( ve => $f->{pve_fresh}{fingerprint}, bs => $f->{pbs_fresh}{fingerprint} );
my %PATH   = ( ve => '/api2/json/nodes/pve1/certificates/custom', bs => '/api2/json/nodes/localhost/certificates/custom' );

# post( $standin, $product, $body, header => ... ) - raw, over a verified connection
sub post {
  my ( $standin, $product, $body, %arg ) = @_;
  my $client = SICK::Target::Proxmox::Client->new( host => '127.0.0.1', port => $standin->port, fingerprints => [ $PIN{$product} ] );
  my $http = HTTP::Tiny->new( verify_SSL => 1, SSL_options => $client->ssl_options, keep_alive => 0, proxy => undef, https_proxy => undef );
  my %headers = ( 'Content-Type' => 'application/json' );
  $headers{Authorization} = exists $arg{header} ? $arg{header} : $HEADER{$product};
  delete $headers{Authorization} unless defined $headers{Authorization};
  return $http->request( 'POST', $client->url( $arg{path} || $PATH{$product} ),
    { headers => \%headers, content => ref $body ? encode_json($body) : $body } );
}

sub serves {
  my ( $standin, $product, $fingerprint ) = @_;
  my $out = SICK::OpenSSL::run_checked( [ 's_client', '-connect', '127.0.0.1:'.$standin->port ], stdin => q{} );
  my ($pem) = $out =~ /(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)/s;
  my $fp = SICK::OpenSSL::run_checked( [ 'x509', '-noout', '-fingerprint', '-sha256' ], stdin => $pem );
  $fp =~ s/\A.*=//s;
  $fp =~ s/[\s:]//g;
  return lc $fp eq $fingerprint;
}

subtest 'proxmox-ve' => sub {
  my $s = standin( 've', $f, $dir, $secret, auth_delay => 0.3 );

  my $start = time;
  my $res = post( $s, 've', { certificates => $chain }, header => undef );
  is( "$res->{status} $res->{reason}", '401 No ticket', 'no header: 401 No ticket' );
  is( $res->{content}, q{}, '  empty body' );
  cmp_ok( time - $start, '>=', 0.3, '  after the delay' );

  $res = post( $s, 've', { certificates => $chain }, header => $HEADER{bs} );
  is( "$res->{status} $res->{reason}", '401 Authentication failed!', 'the PBS scheme: 401 Authentication failed!' );

  $res = post( $s, 've', { certificates => $chain, key => $f->{issued}{key_pem}, force => 'true' } );
  is( $res->{status}, 400, 'force as the string true: 400' );
  is_deeply( [ sort keys %{ decode_json( $res->{content} )->{errors} } ], ['force'], '  errors names force' );

  $res = post( $s, 've', { certificates => $chain, key => $f->{issued}{key_pem}, colour => 'blue' } );
  is( $res->{status}, 400, 'an unknown parameter: 400' );

  $res = post( $s, 've', { certificates => $chain."trailing text\n", key => $f->{issued}{key_pem} } );
  is( $res->{status}, 400, 'text after the last certificate: 400' );

  $res = post( $s, 've', { certificates => $chain, key => $stray, force => 1, restart => 1 } );
  is( $res->{status}, 500, 'a key that does not belong: 500' );
  like( $res->{reason}, qr/\ASetting certificate files failed - key does not match the certificate \(chain\)/, '  with the words of the notes' );
  ok( serves( $s, 've', $f->{pve_fresh}{fingerprint} ), '  the old certificate stays' );

  $res = post( $s, 've', { certificates => $chain, key => $f->{issued}{key_pem}, force => "1" } );
  is( $res->{status}, 200, 'without restart ("1" as a boolean passes): 200' );
  my $data = decode_json( $res->{content} )->{data};
  is( ref $data, 'HASH', '  data is one object' );
  is( $data->{fingerprint}, uc join( ':', $f->{issued}{fingerprint} =~ /(..)/g ), '  fingerprint upper case with colons' );
  is( $data->{filename}, 'pveproxy-ssl.pem', '  filename' );
  sleep 0.2;
  ok( serves( $s, 've', $f->{pve_fresh}{fingerprint} ), '  without restart the old certificate is still served' );

  $res = post( $s, 've', { certificates => $chain, key => $f->{issued}{key_pem}, restart => JSON::MaybeXS::true } );
  is( "$res->{status} $res->{reason}", '500 Custom certificate file exists but force flag is not set.', 'a custom certificate exists, no force: 500' );
};

subtest 'proxmox-bs' => sub {
  my $s = standin( 'bs', $f, $dir, $secret, auth_delay => 0.3 );

  my $start = time;
  my $res = post( $s, 'bs', { certificates => $chain }, header => undef );
  is( $res->{status}, 401, 'no header: 401' );
  is( $res->{content}, 'authentication failed', '  plain-text body' );
  ok( !$res->{headers}{'content-type'}, '  no content type' );
  cmp_ok( time - $start, '>=', 0.3, '  after the delay' );

  $res = post( $s, 'bs', { certificates => $chain }, path => '/api2/json/nodes/localhost/nothing' );
  is( $res->{status}, 404, 'unknown path after authentication: 404' );
  is( $res->{content}, 'Path \'/api2/json/nodes/localhost/nothing\' not found.', '  with the path' );

  $res = post( $s, 'bs', { certificates => $chain, restart => '1' } );
  is( $res->{status}, 400, 'restart as the string 1: 400' );
  is( $res->{content}, 'parameter verification failed - \'restart\': Expected boolean value.', '  plain text' );

  $res = post( $s, 'bs', { certificates => $chain, key => $stray } );
  is( $res->{status}, 200, 'a key that does not belong: 200 all the same' );
  is( decode_json( $res->{content} )->{data}[0]{fingerprint}, join( ':', $f->{issued}{fingerprint} =~ /(..)/g ),
    '  naming the new file, fingerprint lower case' );
  ok( serves( $s, 'bs', $f->{pbs_fresh}{fingerprint} ), '  and the old certificate is still served' );

  $res = post( $s, 'bs', { certificates => $chain, key => $f->{issued}{key_pem} } );
  is( $res->{status}, 200, 'a matching key: 200' );
  is( ref decode_json( $res->{content} )->{data}, 'ARRAY', '  data is a list' );
  ok( serves( $s, 'bs', $f->{issued}{fingerprint} ), '  served at once' );
};

done_testing;
