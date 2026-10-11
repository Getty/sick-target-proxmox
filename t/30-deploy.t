#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw( tempdir );
use Time::HiRes qw( sleep time );
use lib 't/lib';

use SICK::OpenSSL;
use SICK::Target::ProxmoxBS;
use SICK::Target::ProxmoxVE;
use Test::SICK::Proxmox qw( fixtures bundle_of device_for token_file random_secret standin );

# deploy of both types against the stand-in (t/lib/Test/SICK/Proxmox/StandIn.pm),
# which answers what docs/api-notes.md says. What a real node does is not
# tested here.

plan skip_all => 'openssl is not installed' unless SICK::OpenSSL::available();

my $dir    = tempdir( CLEANUP => 1 );
my $f      = fixtures($dir);
my $secret = random_secret();
my $token  = token_file( $dir, $secret );

my %CLASS  = ( ve => 'SICK::Target::ProxmoxVE', bs => 'SICK::Target::ProxmoxBS' );
my %ID     = ( ve => 'sick@pve!sick', bs => 'sick@pbs!sick' );
my %SCHEME = ( ve => 'PVEAPIToken', bs => 'PBSAPIToken' );
my %NODE   = ( ve => 'pve1', bs => 'localhost' );

# target( $product, $standin, %options ) -> ( $target, \@log )
sub target {
  my ( $product, $standin, %options ) = @_;
  my $roots = delete $options{trust_roots};
  my @log;
  my $device = device_for(
    $product,
    port       => $standin->port,
    token_id   => $ID{$product},
    token_file => $token,
    ( $product eq 've' ? ( node => 'pve1' ) : () ),
    %options,
  );
  my $target = $CLASS{$product}->new( device => $device, log => sub { push @log, $_[0] }, ( $roots ? ( trust_roots => $roots ) : () ) );
  $target->validate;
  return ( $target, \@log );
}

sub deploy_error {
  my ( $target, $bundle ) = @_;
  return eval { $target->deploy($bundle); 1 } ? undef : ( $@ =~ s/ at \S+ line [0-9]+\.?\s*\z//r );
}

# The stand-in saw a connection, the handshake failed, and no request.
sub nothing_sent {
  my ( $standin, $what ) = @_;
  ok( $standin->settle, $what.': the stand-in is through with every connection' );
  is( scalar $standin->requests, 0, $what.': the stand-in read no request, so no header and no body' );
  cmp_ok( $standin->handshakes_failed, '>=', 1, $what.': the handshake failed' );
  return;
}

# Waits up to $seconds for the port to present the certificate.
sub presents {
  my ( $target, $fingerprint, $seconds ) = @_;
  my $deadline = time + ( $seconds || 0 );
  while (1) {
    my $presented = $target->presented_cert;
    return 1 if $presented && $presented->fingerprint_sha256 eq $fingerprint;
    return 0 if time >= $deadline;
    sleep 0.1;
  }
}

my $issued   = bundle_of( $f->{issued} );
my $root_pem = do { local ( @ARGV, $/ ) = $f->{root}{cert}; <> };

sub colons { join q{:}, $_[0] =~ m{(..)}g }
my %COLONS = map { $_ => colons( $f->{$_}{fingerprint} ) } qw( stranger pve_fresh pbs_fresh );

for my $product (qw( ve bs )) {
  my $fresh = $product eq 've' ? $f->{pve_fresh} : $f->{pbs_fresh};

  subtest $product.': first upload, the node trusted by '.( $product eq 've' ? 'its cluster CA' : 'the pin of its certificate' ) => sub {
    my $standin = standin( $product, $f, $dir, $secret, restart_delay => 0.5 );
    my %anchor = $product eq 've'
      ? ( ca => [ $f->{cluster_ca}{cert}, $f->{root}{cert} ] )
      : ( fingerprint => $f->{pbs_fresh}{fingerprint}, ca => $f->{root}{cert} );
    my ( $target, $log ) = target( $product, $standin, %anchor );

    my $error = deploy_error( $target, $issued );
    is( $error, undef, 'deploy returns' );
    ok( $standin->settle, 'the stand-in is through' );
    my @requests = $standin->requests;
    is( scalar @requests, 1, 'one request' );
    is( $requests[0]{method}, 'POST', '  a POST' );
    is( $requests[0]{path}, '/api2/json/nodes/'.$NODE{$product}.'/certificates/custom', '  to the upload of node '.$NODE{$product} );
    is( $requests[0]{scheme}, $SCHEME{$product}, '  with the token scheme of the product' );
    is( $requests[0]{auth}, 'ok', '  and the right token' );
    is( $requests[0]{content_type}, 'application/json', '  as JSON' );
    is( $requests[0]{status}, 200, '  answered 200' );
    is( scalar @$log, 1, 'one log line' );
    like( $log->[0], qr/\Auploaded the certificate \(SHA-256 \Q@{[ substr $f->{issued}{fingerprint}, 0, 16 ]}\E\.\.\.\) to 127\.0\.0\.1:[0-9]+, node $NODE{$product}\z/,
      '  naming certificate, port and node' );
    if ( $product eq 've' ) {
      ok( presents( $target, $fresh->{fingerprint} ), 'right after the answer the old certificate is still served (pveproxy reloads)' );
    }
    ok( presents( $target, $f->{issued}{fingerprint}, 5 ), 'then the port presents the new one' );
  };

  subtest $product.': trusted by our root, served with the intermediate' => sub {
    my $standin = standin( $product, $f, $dir, $secret, serve => $f->{issued}, has_custom => 1 );
    my ($target) = target( $product, $standin, ca => $f->{root}{cert} );
    is( deploy_error( $target, bundle_of( $f->{issued2} ) ), undef, 'deploy returns' );
    ok( presents( $target, $f->{issued2}{fingerprint}, 5 ), 'and the port presents the next certificate' );
  };

  subtest $product.': trusted by the roots of the run, no ca, no pin' => sub {
    my $standin = standin( $product, $f, $dir, $secret, serve => $f->{issued}, has_custom => 1 );
    my ($target) = target( $product, $standin, trust_roots => [$root_pem] );
    is( deploy_error( $target, bundle_of( $f->{issued2} ) ), undef, 'deploy returns' );
    is( scalar $standin->uploads, 1, 'one upload' );
  };

  subtest $product.': a fresh node, the roots of the run only' => sub {
    my $standin = standin( $product, $f, $dir, $secret );
    my ($target) = target( $product, $standin, trust_roots => [$root_pem] );
    my $error = deploy_error( $target, $issued );
    like( $error, qr/failed: .*certificate verify failed/, 'deploy fails: the roots do not cover the certificate of a fresh node' );
    like( $error, qr/the node presents SHA-256 \Q@{[ colons( $fresh->{fingerprint} ) ]}\E/, '  naming what the node presents' );
    like( $error, qr/tried the roots of the run \(1\)\z/, '  and the anchors that were tried' );
    nothing_sent( $standin, 'roots only, fresh node' );
  };

  subtest $product.': trusted by a pin' => sub {
    my $standin = standin( $product, $f, $dir, $secret );
    my ($target) = target( $product, $standin, fingerprint => uc $fresh->{fingerprint} );
    is( deploy_error( $target, $issued ), undef, 'deploy returns' );
    is( scalar $standin->uploads, 1, 'one upload' );
  };

  subtest $product.': a CA nobody named' => sub {
    my $standin = standin( $product, $f, $dir, $secret, serve => $f->{stranger} );
    my ($target) = target( $product, $standin, ca => [ $f->{cluster_ca}{cert}, $f->{root}{cert} ] );
    my $error = deploy_error( $target, $issued );
    like( $error, qr/\Aupload to 127\.0\.0\.1:[0-9]+ \(node $NODE{$product}\) failed: .*certificate verify failed/, 'deploy fails: the certificate did not pass' );
    like( $error, qr/the node presents SHA-256 \Q$COLONS{stranger}\E/, '  naming the fingerprint the node presents' );
    like( $error, qr/tried ca \Q$f->{cluster_ca}{cert}\E, \Q$f->{root}{cert}\E\z/, '  and the anchors that were tried' );
    nothing_sent( $standin, 'unknown CA' );
  };

  subtest $product.': a wrong pin' => sub {
    my $standin = standin( $product, $f, $dir, $secret );
    my ($target) = target( $product, $standin, fingerprint => $f->{stranger}{fingerprint} );
    my $error = deploy_error( $target, $issued );
    like( $error, qr/failed: .*certificate verify failed/, 'deploy fails' );
    like( $error, qr/the node presents SHA-256 \Q@{[ colons( $fresh->{fingerprint} ) ]}\E/, '  naming what the node presents' );
    like( $error, qr/tried fingerprint \Q$COLONS{stranger}\E\z/, '  and the pin' );
    nothing_sent( $standin, 'wrong pin' );
  };

  subtest $product.': the name does not match, ca anchor' => sub {
    # PVE: a certificate of the cluster CA without 127.0.0.1 among its names;
    # PBS: our certificate, reached as localhost, which it does not name.
    my $standin = $product eq 've'
      ? standin( 've', $f, $dir, $secret, serve => $f->{pve_misnamed} )
      : standin( 'bs', $f, $dir, $secret, serve => $f->{issued} );
    my ($target) = $product eq 've'
      ? target( 've', $standin, ca => $f->{cluster_ca}{cert} )
      : target( 'bs', $standin, ca => $f->{root}{cert}, host => 'localhost', names => ['localhost'] );
    my $error = deploy_error( $target, $issued );
    like( $error, qr/failed: .*hostname verification failed/, 'deploy fails on the name' );
    like( $error, qr/the node presents SHA-256 /, '  naming what the node presents' );
    nothing_sent( $standin, 'name mismatch' );
  };

  subtest $product.': wrong token' => sub {
    my $standin = standin( $product, $f, $dir, $secret );
    my $other   = random_secret();
    my ($target) = target( $product, $standin, fingerprint => $fresh->{fingerprint}, token_file => token_file( $dir, $other, 'other-token' ) );
    my $error = deploy_error( $target, $issued );
    like( $error, $product eq 've'
        ? qr/\Aupload to 127\.0\.0\.1:[0-9]+ \(node pve1\) failed: 401 Authentication failed!\z/
        : qr/\Aupload to 127\.0\.0\.1:[0-9]+ \(node localhost\) failed: 401 Unauthorized: authentication failed\z/,
      'deploy fails with 401 and the words of the API' );
    unlike( $error, qr/\Q$other\E|\Q$secret\E/, '  and without a secret' );
    ok( $standin->settle, 'the stand-in is through' );
    is( ( $standin->requests )[0]{auth}, 'wrong', 'the stand-in saw a wrong token' );
  };

  subtest $product.': missing privilege' => sub {
    my $standin = standin( $product, $f, $dir, $secret, deny => 1 );
    my ($target) = target( $product, $standin, fingerprint => $fresh->{fingerprint} );
    like( deploy_error( $target, $issued ), $product eq 've'
        ? qr/failed: 403 Permission check failed \(\/nodes\/pve1, Sys\.Modify\)\z/
        : qr/failed: 403 Forbidden: permission check failed\z/,
      'deploy fails with 403' );
  };

  subtest $product.': the handler fails' => sub {
    my $standin = standin( $product, $f, $dir, $secret, handler_dies => 'cannot write certificate files: disk full' );
    my ($target) = target( $product, $standin, fingerprint => $fresh->{fingerprint} );
    like( deploy_error( $target, $issued ), $product eq 've'
        ? qr/failed: 500 cannot write certificate files: disk full\z/
        : qr/failed: 400 Bad Request\z/,
      $product eq 've' ? 'deploy fails with 500 and its message' : 'deploy fails with 400, the body of a 400 is not quoted' );
    ok( presents( $target, $fresh->{fingerprint} ), 'the old certificate stays' );
  };

  subtest $product.': the handler fails with a message that repeats the key' => sub {
    my $standin = standin( $product, $f, $dir, $secret, handler_dies => "bad key -----BEGIN PRIVATE KEY-----\nMIGH" );
    my ($target) = target( $product, $standin, fingerprint => $fresh->{fingerprint} );
    my $error = deploy_error( $target, $issued );
    like( $error, qr/failed: (?:500|400 Bad Request)\z/, 'deploy fails with the status alone' );
    unlike( $error, qr/BEGIN|PRIVATE KEY|MIGH/, '  nothing of the key quoted' );
  };

  subtest $product.': the key does not belong to the certificate' => sub {
    my $standin = standin( $product, $f, $dir, $secret );
    my ($target) = target( $product, $standin, fingerprint => $fresh->{fingerprint} );
    my $mismatched = bundle_of( $f->{issued}, key => $f->{pki}->stray_key('stray-'.$product) );
    like( deploy_error( $target, $mismatched ), qr/\Anot uploaded to 127\.0\.0\.1:[0-9]+: the private key does not belong to the certificate\z/,
      'deploy refuses' );
    sleep 0.2;
    is( $standin->accepts, 0, 'the stand-in saw no connection at all' );

    my $keyless = bundle_of( $f->{issued}, key => undef );
    like( deploy_error( $target, $keyless ), qr/\Anot uploaded to .*: the bundle has no private key/, 'a bundle without a key: refused' );
    sleep 0.2;
    is( $standin->accepts, 0, 'still no connection' );
  };

  subtest $product.': a chain that does not start with the certificate' => sub {
    # SICK::Bundle puts the certificate first; this one is made to fail at
    # that, as a regression would. Both products write such a chain and
    # answer 200 (observed, see docs/api-notes.md).
    my $standin = standin( $product, $f, $dir, $secret );
    my ($target) = target( $product, $standin, fingerprint => $fresh->{fingerprint} );
    my $reversed = Test::ReversedBundle->new( cert => $f->{issued}{pem}, chain => $f->{issued}{chain_pem}, key => $f->{issued}{key_pem} );
    like( $reversed->fullchain, qr/\A\Q$f->{int}{pem}\E/, 'the chain of this bundle starts with the intermediate' );
    like( deploy_error( $target, $reversed ),
      qr/\Anot uploaded to 127\.0\.0\.1:[0-9]+: the certificate chain does not start with the certificate of the key\z/,
      'deploy refuses' );
    sleep 0.2;
    is( $standin->accepts, 0, 'the stand-in saw no connection at all' );
  };

  if ( $product eq 've' ) {
    subtest 've: the restart of pveproxy fails inside the call' => sub {
      my $standin = standin( 've', $f, $dir, $secret, restart_fails => 1 );
      my ($target) = target( 've', $standin, fingerprint => $fresh->{fingerprint} );
      like( deploy_error( $target, $issued ),
        qr/failed: 500 command 'systemctl reload-or-restart pveproxy' failed: exit code 1\z/, 'deploy fails with the 500' );
      ok( presents( $target, $fresh->{fingerprint} ), 'the port keeps the old certificate' );
    };
  }

  subtest $product.': the answer names another certificate' => sub {
    my $standin = standin( $product, $f, $dir, $secret, report_fingerprint => $f->{stranger}{fingerprint} );
    my ($target) = target( $product, $standin, fingerprint => $fresh->{fingerprint} );
    like( deploy_error( $target, $issued ),
      qr/answered 200, but the node reports the certificate SHA-256 \Q$COLONS{stranger}\E, not the one uploaded/,
      'deploy fails' );
  };

  subtest $product.': nothing listens' => sub {
    my $standin = standin( $product, $f, $dir, $secret );
    my $port    = $standin->port;
    $standin->stop;
    my $device = device_for( $product, port => $port, token_id => $ID{$product}, token_file => $token,
      fingerprint => $fresh->{fingerprint}, ( $product eq 've' ? ( node => 'pve1' ) : () ) );
    my $target = $CLASS{$product}->new( device => $device );
    my $error  = deploy_error( $target, $issued );
    like( $error, qr/\Aupload to 127\.0\.0\.1:$port \(node $NODE{$product}\) failed: .*(?:connect|refused)/i, 'deploy fails without a connection' );
    unlike( $error, qr/presents/, '  and does not claim a certificate' );
  };

  subtest $product.': a secret that cannot go into a header' => sub {
    my $standin = standin( $product, $f, $dir, $secret );
    my ($target) = target( $product, $standin, fingerprint => $fresh->{fingerprint},
      token_file => token_file( $dir, 'has a space', 'spaced-token' ) );
    my $error = deploy_error( $target, $issued );
    like( $error, qr/\Atoken_file '.*spaced-token': the secret has to be one line of printable ASCII without spaces\z/, 'refused' );
    unlike( $error, qr/has a space/, '  without quoting it' );
    sleep 0.2;
    is( scalar $standin->requests, 0, 'nothing was sent' );
  };
}

done_testing;

package Test::ReversedBundle;
use parent -norequire, 'SICK::Bundle';
sub fullchain { $_[0]->chain.$_[0]->cert }
