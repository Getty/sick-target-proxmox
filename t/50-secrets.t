#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw( tempdir );
use lib 't/lib';

use SICK::Command;
use SICK::Config;
use SICK::Issuer;
use SICK::OpenSSL;
use SICK::Runner;
use Test::SICK::Proxmox qw( fixtures token_file random_secret standin spew );

# The token, a secret made here, travels in the Authorization header and
# nowhere else: not in a log line, an error, a result of the run, the
# argument list, environment or input of a program started on the way, the
# output of this process, or the log of the stand-in. The private keys of
# the run appear in no log line, error or result.

plan skip_all => 'openssl is not installed' unless SICK::OpenSSL::available();

my $dir    = tempdir( CLEANUP => 1 );
my $f      = fixtures($dir);
my $secret = random_secret();
my $token  = token_file( $dir, $secret );

my %standin = (
  pve_ok    => standin( 've', $f, $dir, $secret ),
  pbs_ok    => standin( 'bs', $f, $dir, $secret ),
  pve_auth  => standin( 've', $f, $dir, random_secret() ),    # wants another secret: 401
  pbs_auth  => standin( 'bs', $f, $dir, random_secret() ),
  pve_trust => standin( 've', $f, $dir, $secret, serve => $f->{stranger} ),
  pbs_kept  => standin( 'bs', $f, $dir, $secret, reload_fails => 1 ),
);

my $yaml = "ca:\n  type: selfsigned\n  dir: $dir/sick-ca\ndefaults:\n  lifetime: 30d\n  renew_before: 7d\n  key: ec256\ndevices:\n";
for my $name ( sort keys %standin ) {
  my $ve = $name =~ /\Apve/;
  $yaml .= "  $name:\n"
    ."    type: ".( $ve ? 'proxmox-ve' : 'proxmox-bs' )."\n"
    ."    host: 127.0.0.1\n    port: ".$standin{$name}->port."\n    names: [127.0.0.1]\n"
    ."    token_id: ".( $ve ? 'sick@pve!sick' : 'sick@pbs!sick' )."\n    token_file: $token\n"
    .( $ve ? "    node: pve1\n    ca: [ $f->{cluster_ca}{cert}, $dir/sick-ca/ca.crt ]\n"
           : "    fingerprint: $f->{pbs_fresh}{fingerprint}\n    ca: $dir/sick-ca/ca.crt\n" );
}

my $config = SICK::Config->load_string( $yaml, 'test list' );
my $issuer = SICK::Issuer->from_ca( %{ $config->ca } );
$issuer->root_pem;

# Every program started during the run, as it was started.
my @started;
my $run = \&SICK::Command::run;
my @log;
my @results;
my ( $out_file, $err_file ) = ( $dir.'/stdout', $dir.'/stderr' );
{
  no warnings 'redefine';
  local *SICK::Command::run = sub {
    my ( $argv, %opt ) = @_;
    push @started, {
      argv  => [@$argv],
      env   => { %{ $opt{env} || {} } },
      stdin => defined $opt{stdin} ? $opt{stdin} : q{},
      ENV   => {%ENV},
    };
    return $run->(@_);
  };

  open my $out, '>&', \*STDOUT or die $!;
  open my $err, '>&', \*STDERR or die $!;
  open STDOUT, '>', $out_file or die $!;
  open STDERR, '>', $err_file or die $!;
  my $runner = SICK::Runner->new(
    config          => $config,
    issuer          => $issuer,
    log             => sub { push @log, $_[0]; print STDERR $_[0], "\n" },
    verify_timeout  => 2,
    verify_interval => 0.2,
  );
  @results = $runner->run;
  open STDOUT, '>&', $out or die $!;
  open STDERR, '>&', $err or die $!;
}

my %result = map { $_->{device} => $_ } @results;
is( $result{pve_ok}{action}, 'renewed', 'pve_ok renewed' ) or diag $result{pve_ok}{error};
is( $result{pbs_ok}{action}, 'renewed', 'pbs_ok renewed' ) or diag $result{pbs_ok}{error};
like( $result{pve_auth}{error}, qr/failed: 401 /, 'pve_auth failed with 401' );
like( $result{pbs_auth}{error}, qr/failed: 401 /, 'pbs_auth failed with 401' );
like( $result{pve_trust}{error}, qr/certificate verify failed/, 'pve_trust failed on the certificate' );
like( $result{pbs_kept}{error}, qr/\Averification failed: /, 'pbs_kept failed at the verification' );

cmp_ok( scalar @started, '>', 10, 'programs were started on the way ('.scalar(@started).'), so the checks below look at something' );
ok( scalar( grep { $_->{argv}[1] eq 's_client' } @started ), '  among them openssl s_client, the look at the port' );

sub contains { my ( $text, $needle ) = @_; return defined $text && index( $text, $needle ) >= 0 }
sub flat { join "\n", map { ref $_ eq 'HASH' ? flat( %$_ ) : ref $_ eq 'ARRAY' ? flat(@$_) : defined $_ ? $_ : q{} } @_ }

my $out = do { local ( @ARGV, $/ ) = $out_file; <> };
my $err = do { local ( @ARGV, $/ ) = $err_file; <> };
like( $err, qr/pve_ok: uploaded the certificate/, 'the log went to STDERR as captured' );

ok( !contains( flat(@log), $secret ), 'the secret is in no log line' );
ok( !contains( flat( map { { %$_ } } @results ), $secret ), 'in no result or error of the run' );
ok( !grep( { contains( flat( $_->{argv} ), $secret ) } @started ), 'in no argument list of a program' );
ok( !grep( { contains( flat( $_->{env} ), $secret ) } @started ), 'in no environment given to a program' );
ok( !grep( { contains( flat( $_->{ENV} ), $secret ) } @started ), 'in no environment a program inherits' );
ok( !grep( { contains( $_->{stdin}, $secret ) } @started ), 'in no input of a program' );
ok( !contains( $out, $secret ) && !contains( $err, $secret ), 'in nothing printed' );
ok( !grep( { contains( $_->log_text, $secret ) } values %standin ), 'in no log of the stand-ins' );

# the keys of the run: in no message (they do go to openssl on its input,
# to be checked against their certificate)
my $key_text = qr/PRIVATE KEY|-----BEGIN/;
ok( !grep( { /$key_text/ } @log ), 'no key in a log line' );
ok( !grep( { /$key_text/ } map { defined $_->{error} ? $_->{error} : () } @results ), 'no key in an error' );
ok( !( $out =~ $key_text || $err =~ $key_text ), 'no key printed' );
ok( !grep( { /PRIVATE KEY/ } map { @{ $_->{argv} } } @started ), 'no key in an argument list' );

done_testing;
