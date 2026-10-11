#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';

use JSON::MaybeXS qw( encode_json );
use SICK::Target::Proxmox::Client;
use SICK::Target::ProxmoxBS;
use SICK::Target::ProxmoxVE;
use Test::SICK::Proxmox qw( device_for random_secret );

# What of an error answer goes into the message of a failed upload. The
# answers are built here in the shapes docs/api-notes.md gives; no network.

my $secret = random_secret();
my $key    = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49\n-----END PRIVATE KEY-----\n";
my $client = SICK::Target::Proxmox::Client->new( host => '127.0.0.1', port => 8006, fingerprints => [ 'ab' x 32 ] );

my %target = (
  ve => SICK::Target::ProxmoxVE->new( device => device_for( 've', port => 8006, node => 'pve1' ) ),
  bs => SICK::Target::ProxmoxBS->new( device => device_for( 'bs', port => 8007 ) ),
);

sub failure {
  my ( $product, %response ) = @_;
  return $target{$product}->_failure( $client, { headers => {}, %response }, $secret );
}

my $where_ve = 'upload to 127.0.0.1:8006 (node pve1) failed: ';
my $where_bs = 'upload to 127.0.0.1:8007 (node localhost) failed: ';

subtest 'quotable' => sub {
  my $t = $target{ve};
  is( $t->quotable("first line\nsecond line"), 'first line', 'the first line only' );
  is( $t->quotable("\n  padded  \n"), 'padded', 'trimmed, empty lines skipped' );
  is( $t->quotable( 'x' x 200 ), 'x' x 200, '200 characters pass' );
  is( $t->quotable( 'x' x 201 ), undef, '201 do not' );
  is( $t->quotable('see -----BEGIN CERTIFICATE-----'), undef, 'a PEM block does not' );
  is( $t->quotable('the PRIVATE KEY is wrong'), undef, 'PRIVATE KEY does not' );
  is( $t->quotable( 'token '.$secret.' refused', $secret ), undef, 'the secret does not' );
  is( $t->quotable("tab\there"), undef, 'a control character does not' );
  is( $t->quotable(undef), undef, 'undef is nothing' );
};

subtest 'proxmox-ve' => sub {
  is( failure( 've', status => 401, reason => 'Authentication failed!', content => q{} ),
    $where_ve.'401 Authentication failed!', '401: the reason phrase' );
  is( failure( 've', status => 401, reason => 'No ticket', content => q{} ),
    $where_ve.'401 No ticket', '401 without a header' );

  my $body = encode_json( {
    data    => undef,
    errors  => { certificates => 'value '.$key.' is not valid', key => 'got \''.$key.'\'' },
    message => "Parameter verification failed.\n",
  } );
  my $message = failure( 've', status => 400, reason => 'Parameter verification failed.', content => $body );
  is( $message, $where_ve.'400 Parameter verification failed.: parameters certificates, key', '400: only the names of the parameters' );
  unlike( $message, qr/BEGIN|MIGH/, '  nothing of their values' );

  is( failure( 've', status => 500, reason => 'Custom certificate file exists but force flag is not set.',
      content => encode_json( { data => undef, message => "Custom certificate file exists but force flag is not set.\n" } ) ),
    $where_ve.'500 Custom certificate file exists but force flag is not set.', '500: the message, once' );

  $message = failure( 've', status => 500, reason => 'got '.$secret,
    content => encode_json( { data => undef, message => 'got '.$secret."\n" } ) );
  is( $message, $where_ve.'500', '500 repeating the secret: the status alone' );

  $message = failure( 've', status => 500, reason => 'bad',
    content => encode_json( { data => undef, message => "bad\n".$key } ) );
  is( $message, $where_ve.'500 bad', '500 with the key after the first line: the first line' );

  is( failure( 've', status => 506, reason => 'Unsupported content type', content => q{} ),
    $where_ve.'506 Unsupported content type', 'another status' );
};

subtest 'proxmox-bs' => sub {
  is( failure( 'bs', status => 401, reason => 'Unauthorized', content => 'authentication failed' ),
    $where_bs.'401 Unauthorized: authentication failed', '401: reason and plain-text body' );
  is( failure( 'bs', status => 403, reason => 'Forbidden', content => 'permission check failed' ),
    $where_bs.'403 Forbidden: permission check failed', 'missing privilege' );
  is( failure( 'bs', status => 400, reason => 'Bad Request', content => "parameter verification failed - 'key': ".$key ),
    $where_bs.'400 Bad Request', '400: the body is never quoted' );
  is( failure( 'bs', status => 404, reason => 'Not Found', content => 'Path \'/api2/json/x\' not found.' ),
    $where_bs.'404 Not Found: Path \'/api2/json/x\' not found.', 'unknown path' );
};

subtest '599: no answer' => sub {
  my $message = failure( 've', status => 599, reason => 'Internal Exception',
    content => "Could not connect to '127.0.0.1:8006': Connection refused\n" );
  is( $message, $where_ve.'Could not connect to \'127.0.0.1:8006\': Connection refused', 'the reason of HTTP::Tiny' );

  $message = failure( 've', status => 599, reason => 'Internal Exception',
    content => 'Invalid HTTP header field value (PVEAPIToken=sick@pve!sick='.$secret.")\n" );
  is( $message, $where_ve.'no connection', 'a text holding the secret is not quoted' );
};

done_testing;
