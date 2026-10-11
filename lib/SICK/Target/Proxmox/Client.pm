package SICK::Target::Proxmox::Client;
# ABSTRACT: The verified HTTPS connection to the API of a Proxmox node

use Moo;
use Carp qw( croak );
use HTTP::Tiny;
use IO::Socket::SSL qw( SSL_VERIFY_PEER );
use JSON::MaybeXS ();
use Path::Tiny ();
use SICK::Names;
use SICK::Temp;
use Types::Standard qw( ArrayRef InstanceOf Int Str );
use namespace::autoclean;

our $VERSION = '0.001';

=head1 SYNOPSIS

    my $client = SICK::Target::Proxmox::Client->new(
      host         => 'pve1.example.internal',
      port         => 8006,
      ca           => [ '/etc/sick/pve-root-ca.pem', '/etc/sick/root.pem' ],
      fingerprints => [],
    );
    my $response = $client->post_json( '/api2/json/nodes/pve1/certificates/custom',
      $authorization, { certificates => $pem, key => $key_pem } );

=head1 DESCRIPTION

One HTTPS request to the API of a Proxmox VE node or a Proxmox Backup Server,
over a connection whose certificate was checked against the anchors the
operator named in the device list, and against nothing else
(F<docs/decisions/0001-trust-in-the-node.md>).

The connection is L<HTTP::Tiny> on L<IO::Socket::SSL>, set up the one way
F<docs/decisions/0002-http-client.md> describes:

=over 4

=item *

C<verify_SSL> is always passed as true, so that
C<PERL_HTTP_TINY_SSL_INSECURE_BY_DEFAULT> in the environment cannot turn it
off; the peer is verified (C<SSL_verify_mode>), and its name is checked
against C<host> as for HTTPS (C<SSL_verifycn_scheme> C<http>,
C<SSL_verifycn_name>), which is also sent as SNI where it is a name.

=item *

the C<ca> files are written, concatenated, into one PEM file in a private
temporary directory (L<SICK::Temp>) and given as C<SSL_ca_file>; that file
replaces every store of the system.

=item *

the C<fingerprints> become C<SSL_fingerprint>: a leaf certificate with one of
these SHA-256 fingerprints is accepted on its own, without the check of the
name. Without C<ca>, C<SSL_force_fingerprint> is set as well, so that the
certificate has to be one of the pinned ones and no store of the system
counts.

=item *

no proxy (C<proxy>, C<http_proxy> and C<https_proxy> are passed as
C<undef>, so the environment does not route the request elsewhere), no
redirects, no keep-alive.

=back

The check happens during the handshake: a node that passes neither anchor
never sees a byte of the request. There is no option, no environment
variable and no test hook that loosens any of this.

The client is handed the value of the C<Authorization> header for one
request and keeps it nowhere. It never quotes a request: not the header,
not the body.

=cut

has host => ( is => 'ro', isa => Str, required => 1 );

=attr host

Required. Where the node is reached, a DNS name or an address. The
certificate of the node has to carry it, unless it is pinned.

=cut

has port => ( is => 'ro', isa => Int, required => 1 );

=attr port

Required. The port of the API: C<8006> for Proxmox VE, C<8007> for Proxmox
Backup Server.

=cut

has ca => ( is => 'ro', isa => ArrayRef [Str], default => sub { [] } );

=attr ca

Paths of files with CA certificates (PEM, one or more per file). The
certificate of the node has to chain up to one of them. An empty list
by default.

=cut

has fingerprints => ( is => 'ro', isa => ArrayRef [Str], default => sub { [] } );

=attr fingerprints

SHA-256 fingerprints of leaf certificates the node may present: 64 hex
digits, colons allowed, any case. An empty list by default. At least one
C<ca> file or one fingerprint is required.

=cut

has timeout => ( is => 'ro', isa => Int, default => 60 );

=attr timeout

Seconds for connecting, and for every read and write of the request. C<60>:
Proxmox VE reloads its proxy before it answers an upload.

=cut

# The checks and messages of the constructor come first; the types are the
# second line.
around BUILDARGS => sub {
  my ( $orig, $class, @args ) = @_;
  my %arg = %{ $class->$orig(@args) };
  for my $list (qw( ca fingerprints )) {
    $arg{$list} = [ $arg{$list} ] if defined $arg{$list} && !ref $arg{$list};
    delete $arg{$list} unless defined $arg{$list};
  }
  croak $class.'->new needs at least one ca file or fingerprint: there is nothing else to trust the node by'
    unless @{ $arg{ca} || [] } || @{ $arg{fingerprints} || [] };
  for my $fingerprint ( @{ $arg{fingerprints} || [] } ) {
    croak $class.'->new: invalid SHA-256 fingerprint \''.( defined $fingerprint && !ref $fingerprint ? $fingerprint : q{} ).'\''
      unless defined $class->normalize_fingerprint($fingerprint);
  }
  return \%arg;
};

=method new

    my $client = SICK::Target::Proxmox::Client->new(
      host => $host, port => $port, ca => \@files, fingerprints => \@pins );

C<ca> and C<fingerprints> also take a single value. Croaks with
C<< ...->new needs at least one ca file or fingerprint ... >> without
either, and with C<< invalid SHA-256 fingerprint '<value>' >>. The C<ca>
files are read on the first request.

=cut

sub normalize_fingerprint {
  my ( $self, $fingerprint ) = @_;
  return undef unless defined $fingerprint && !ref $fingerprint;
  return undef
    unless $fingerprint =~ /\A[0-9A-Fa-f]{64}\z/
    || $fingerprint =~ /\A[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){31}\z/;
  ( my $hex = lc $fingerprint ) =~ tr/://d;
  return $hex;
}

=method normalize_fingerprint

    my $hex = $client->normalize_fingerprint('AB:CD:...');    # 'abcd...'

A SHA-256 fingerprint as 64 lower-case hex digits without colons, or
C<undef> when the value is none: 64 hex digits, or 32 pairs separated by
colons, in any case. Works on the class as well.

=cut

# The ca files, concatenated into one PEM file: SSL_ca_file takes one path.
# Public data; the directory goes with the client.
has _tmp => ( is => 'lazy', isa => InstanceOf ['SICK::Temp'], init_arg => undef );
sub _build__tmp { SICK::Temp->dir }

has _ca_file => ( is => 'lazy', init_arg => undef );

sub _build__ca_file {
  my ( $self ) = @_;
  return undef unless @{ $self->ca };
  my $pem = join q{}, map { $self->read_ca_file($_) } @{ $self->ca };
  return $self->_tmp->write( 'ca.pem', $pem, 0644 );
}

sub read_ca_file {
  my ( $self, $path ) = @_;
  my $file = Path::Tiny::path($path);
  croak 'cannot read ca file \''.$path.'\': Is a directory' if $file->is_dir;
  my $content = eval { $file->slurp_raw };
  croak 'cannot read ca file \''.$path.'\': '.( ref $@ && ref $@ eq 'Path::Tiny::Error' ? $@->{err} : 'unknown error' )
    unless defined $content;
  my @certs = $content =~ /(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)/sg;
  croak 'ca file \''.$path.'\' holds no PEM certificate' unless @certs;
  return join q{}, map { ( s/\r\n/\n/gr )."\n" } @certs;
}

=method read_ca_file

    my $pem = $client->read_ca_file($path);

The certificates of a C<ca> file as PEM, one block after the other. Croaks
with C<< cannot read ca file '<path>': <reason> >> and with
C<< ca file '<path>' holds no PEM certificate >>. Works on the class as
well.

=cut

sub ssl_options {
  my ( $self ) = @_;
  my $host = $self->host;
  my %ssl = (
    SSL_verify_mode     => SSL_VERIFY_PEER,
    SSL_verifycn_scheme => 'http',
    SSL_verifycn_name   => $host,
    SSL_hostname        => SICK::Names::is_ip($host) ? q{} : $host,
  );
  my @pins = map { 'sha256$'.$self->normalize_fingerprint($_) } @{ $self->fingerprints };
  $ssl{SSL_ca_file} = $self->_ca_file if @{ $self->ca };
  if (@pins) {
    $ssl{SSL_fingerprint} = \@pins;
    # Without a ca file the store of the system would be the other way in;
    # with this, only a pinned certificate passes.
    $ssl{SSL_force_fingerprint} = 1 unless @{ $self->ca };
  }
  return \%ssl;
}

=method ssl_options

The C<SSL_options> handed to L<HTTP::Tiny>, built from the attributes and
from nothing else. Reads the C<ca> files.

=cut

has _http => ( is => 'lazy', isa => InstanceOf ['HTTP::Tiny'], init_arg => undef );

sub _build__http {
  my ( $self ) = @_;
  return HTTP::Tiny->new(
    agent        => 'SICK-Target-Proxmox/'.( $VERSION || 'dev' ),
    verify_SSL   => 1,
    SSL_options  => $self->ssl_options,
    proxy        => undef,
    http_proxy   => undef,
    https_proxy  => undef,
    max_redirect => 0,
    keep_alive   => 0,
    timeout      => $self->timeout,
  );
}

sub url {
  my ( $self, $path ) = @_;
  my $host = $self->host;
  $host = '['.$host.']' if SICK::Names::is_ip($host) == 6;
  return 'https://'.$host.':'.$self->port.$path;
}

=method url

    my $url = $client->url('/api2/json/version');

C<https://>, host, port and the path.

=cut

sub post_json {
  my ( $self, $path, $authorization, $data ) = @_;
  croak 'post_json needs a path starting with /' unless defined $path && $path =~ m{\A/};
  croak 'post_json needs the value of the Authorization header' unless defined $authorization && length $authorization;
  croak 'post_json needs the body as a hash reference' unless ref $data eq 'HASH';
  my $body = JSON::MaybeXS->new( utf8 => 1, canonical => 1, convert_blessed => 1 )->encode($data);
  return $self->_http->request(
    'POST',
    $self->url($path),
    {
      headers => {
        'Authorization' => $authorization,
        'Content-Type'  => 'application/json',
        'Accept'        => 'application/json',
      },
      content => $body,
    }
  );
}

=method post_json

    my $response = $client->post_json( $path, $authorization, \%body );

Sends one C<POST> with C<\%body> as JSON and C<$authorization> as the
C<Authorization> header, and returns the response of L<HTTP::Tiny>: a hash
reference with C<status>, C<reason>, C<headers> and C<content>. Status
C<599> is HTTP::Tiny's own: no answer, the C<content> says why - a refused
connection, a timeout, a certificate that did not pass. Nothing is thrown
for a status; the caller decides.

=cut

sub anchors {
  my ( $self ) = @_;
  return join '; ',
    ( @{ $self->ca } ? 'ca '.join( ', ', @{ $self->ca } ) : () ),
    ( @{ $self->fingerprints }
      ? 'fingerprint '.join( ', ', map { $self->format_fingerprint($_) } @{ $self->fingerprints } )
      : () );
}

=method anchors

    my $text = $client->anchors;    # 'ca /etc/sick/root.pem; fingerprint ab:cd:...'

What the node is trusted by, for a message: the paths of the C<ca> files
and the pinned fingerprints. All of it is public.

=cut

sub format_fingerprint {
  my ( $self, $fingerprint ) = @_;
  my $hex = $self->normalize_fingerprint($fingerprint);
  return defined $hex ? join( ':', $hex =~ /(..)/g ) : $fingerprint;
}

=method format_fingerprint

    my $text = $client->format_fingerprint($hex);    # 'ab:cd:...'

A SHA-256 fingerprint the way the dashboard of Proxmox Backup Server shows
it: lower-case pairs separated by colons. Works on the class as well.

=cut

1;
