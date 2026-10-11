package SICK::Target::Proxmox::Role;
# ABSTRACT: What the Proxmox VE and Proxmox Backup Server targets share

use Carp qw( croak );
use JSON::MaybeXS ();
use SICK::Config;
use SICK::Target::Proxmox::Client;
use Moo::Role;

our $VERSION = '0.001';

requires qw(
  product api_port api_node token_id_valid authorization upload_fields
  answer_certificate api_message validate_type_options
);

=head1 SYNOPSIS

    package SICK::Target::ProxmoxXY;
    use Moo;
    extends 'SICK::Target';
    with 'SICK::Target::Proxmox::Role';

    sub product               { 'Proxmox XY' }
    sub api_port              { 8009 }
    sub api_node              { 'localhost' }
    sub token_id_valid        { ... }    # ( $token_id ) -> true or false
    sub authorization         { ... }    # ( $token_id, $secret ) -> header value
    sub upload_fields         { ... }    # ( $bundle ) -> hash reference of the body
    sub answer_certificate    { ... }    # ( $data ) -> the certificate info of the answer
    sub api_message           { ... }    # ( $response ) -> what of the answer may be quoted
    sub validate_type_options { ... }    # croaks on what only this type checks

=head1 DESCRIPTION

The part of L<SICK::Target::ProxmoxVE> and L<SICK::Target::ProxmoxBS> that
does not depend on the product: the options, their checks, and the order of
L</deploy>. Each type supplies what differs between the two APIs - the
scheme of the token header, the node in the path, the fields of the upload,
the shape of the answer, what of an error answer may be quoted
(F<docs/api-notes.md>).

=cut

sub required_options { qw( token_id token_file ), $_[0]->type_required_options }
sub optional_options { qw( ca fingerprint ) }
sub type_required_options { () }

=method required_options

C<token_id>, C<token_file> and what L</type_required_options> adds.

=method optional_options

C<ca> and C<fingerprint>; one of them is required, see L</validate>.

=method type_required_options

What a type requires on top. Nothing by default.

=cut

around validate => sub {
  my ( $orig, $self, @args ) = @_;
  $self->$orig(@args);
  my $device = $self->device;
  my $where  = $device->path;

  croak $where.': port 443 is the default of SICK; the API of '.$self->product.' listens on '
      .$self->api_port.', set \'port: '.$self->api_port.'\''
    if $device->port == 443;

  # The value is not quoted: a token id with the secret appended is a
  # likely mistake, and the message would carry the secret then.
  my $token_id = $self->option('token_id');
  croak $where.': invalid \'token_id\' (expected user@realm!tokenname, see the type\'s documentation)'
    unless defined $token_id && !ref $token_id && $self->token_id_valid($token_id);

  my $token_file = $self->option('token_file');
  croak $where.': \'token_file\' must be the path of a file'
    unless defined $token_file && !ref $token_file && length $token_file;

  $self->validate_type_options($where);

  my @ca   = $self->_list( $where, 'ca' );
  my @pins = $self->_list( $where, 'fingerprint' );
  croak $where.': needs \'ca\' or \'fingerprint\' to trust '.$self->product.' by; there is no other way'
    unless @ca || @pins;
  for my $path (@ca) {
    eval { SICK::Target::Proxmox::Client->read_ca_file($path); 1 }
      or croak $where.'.ca: '.$self->_first_line($@);
  }
  for my $pin (@pins) {
    croak $where.'.fingerprint: invalid SHA-256 fingerprint \''.$pin.'\' (64 hex digits, colons allowed)'
      unless defined SICK::Target::Proxmox::Client->normalize_fingerprint($pin);
  }
  return $self;
};

=method validate

    $target->validate;

The checks of L<SICK::Target/validate>, then: C<port> is not C<443> (the
default of SICK; the message names the port of the API), C<token_id> has the
form of a token id of the product (its value is never quoted),
C<token_file> is a path, the checks of the type, and at least one of C<ca>
and C<fingerprint>: every C<ca> file can be read and holds a PEM
certificate, every C<fingerprint> is a SHA-256 fingerprint. The token file
is not read here. Croaks with the path of the device in the list.

=cut

sub deploy {
  my ( $self, $bundle ) = @_;
  my ( $host, $port ) = $self->endpoint;
  my $where = $host.':'.$port;

  # Before any connection: what is not a pair must not leave this machine.
  croak 'not uploaded to '.$where.': the bundle has no private key, and '.$self->product
      .' needs the key with the certificate'
    unless defined $bundle->key;
  croak 'not uploaded to '.$where.': the private key does not belong to the certificate'
    unless $bundle->key_matches;

  # Both products write what they are given and answer 200 for a chain that
  # does not start with the certificate of the key; the port then keeps the
  # old certificate (PBS) or fails every handshake after the restart (PVE).
  my $fields = $self->upload_fields($bundle);
  my ($first) = defined $fields->{certificates} && !ref $fields->{certificates}
    ? $fields->{certificates} =~ /(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)/s
    : ();
  croak 'not uploaded to '.$where.': the certificate chain does not start with the certificate of the key'
    unless defined $first && $first."\n" eq $bundle->cert
    && defined $fields->{key} && $fields->{key} eq $bundle->key;

  my $client = SICK::Target::Proxmox::Client->new(
    host         => $host,
    port         => $port,
    ca           => [ $self->_list( $self->device->path, 'ca' ) ],
    fingerprints => [ $self->_list( $self->device->path, 'fingerprint' ) ],
  );
  my $secret   = $self->_secret;
  my $response = $client->post_json(
    '/api2/json/nodes/'.$self->api_node.'/certificates/custom',
    $self->authorization( $self->option('token_id'), $secret ),
    $fields,
  );

  croak $self->_failure( $client, $response, $secret ) unless $response->{status} eq '200';
  undef $secret;

  my $upload = 'upload to '.$where.' (node '.$self->api_node.')';
  my $answer = eval { JSON::MaybeXS->new( utf8 => 1 )->decode( $response->{content} ) };
  croak $upload.' answered 200, but not with JSON' unless ref $answer eq 'HASH';
  my $info = $self->answer_certificate( $answer->{data} );
  croak $upload.' answered 200, but without the certificate it installed'
    unless ref $info eq 'HASH';
  my $reported = $client->normalize_fingerprint( $info->{fingerprint} );
  croak $upload.' answered 200, but without a valid fingerprint of the certificate it installed'
    unless defined $reported;

  my $issued = $bundle->fingerprint_sha256;
  croak $upload.' answered 200, but the node reports the certificate SHA-256 '
      .$client->format_fingerprint($reported).', not the one uploaded ('.$client->format_fingerprint($issued).')'
    unless $reported eq $issued;

  $self->log( 'uploaded the certificate (SHA-256 '.substr( $issued, 0, 16 ).'...) to '.$where
      .', node '.$self->api_node );
  return;
}

=method deploy

    $target->deploy($bundle);

In this order:

=over 4

=item 1.

The bundle has to have a key, and the key has to belong to the certificate
(L<SICK::Bundle/key_matches>), and the C<certificates> of the upload have
to start with that certificate. Otherwise it croaks before any connection
is made: both products write a pair or a chain that does not fit and
answer C<200>, and the port then keeps the old certificate or fails every
handshake.

=item 2.

The secret is read from C<token_file> (L<SICK::Config/read_secret>) and has
to be printable ASCII without spaces; it is refused without being quoted.
The header is put together in memory.

=item 3.

One request: C<POST /api2/json/nodes/E<lt>nodeE<gt>/certificates/custom>
with the certificate, its chain and the key as JSON, over a connection that
passed C<ca> or C<fingerprint> (L<SICK::Target::Proxmox::Client>).

=item 4.

The answer has to be C<200> and has to name the certificate that was
uploaded, by its SHA-256 fingerprint.

=back

Croaks with C<< upload to <host>:<port> (node <node>) failed: <status>
<reason> >>, followed by what of the answer may be quoted
(L</api_message>); for a connection that did not come about, with the
reason of the TLS library, and when the certificate of the node did not
pass, with the SHA-256 fingerprint the node presents and the anchors that
were tried. A message never holds the token, the key or the body.

Returning does not mean the node serves the certificate: L<SICK::Runner>
asks the port afterwards.

=cut

#### internals

sub _list {
  my ( $self, $where, $name ) = @_;
  my $value = $self->option($name);
  return () unless defined $value;
  my @values = ref $value eq 'ARRAY' ? @$value : ($value);
  croak $where.': \''.$name.'\' must be a value or a list of values'
    if ref $value && ref $value ne 'ARRAY'
    || grep { !defined || ref || !length } @values;
  croak $where.': \''.$name.'\' is an empty list' if ref $value && !@values;
  return @values;
}

sub _secret {
  my ( $self ) = @_;
  my $path   = $self->option('token_file');
  my $secret = SICK::Config->read_secret($path);
  # HTTP::Tiny quotes a header value it refuses; this refuses it first, and
  # without a word about it.
  croak 'token_file \''.$path.'\': the secret has to be one line of printable ASCII without spaces'
    unless $secret =~ /\A[\x21-\x7e]+\z/;
  return $secret;
}

# Only what cannot repeat the request: the first line, short, without a PEM
# block, a key or the secret.
sub quotable {
  my ( $self, $text, $secret ) = @_;
  return undef unless defined $text && !ref $text;
  my ($line) = grep { /\S/ } split /\r?\n/, $text;
  return undef unless defined $line;
  $line =~ s/\A\s+//;
  $line =~ s/\s+\z//;
  return undef
    if length $line > 200
    || $line =~ /-----BEGIN|PRIVATE KEY/
    || $line =~ /[\x00-\x1f\x7f]/
    || defined $secret && length $secret && index( $line, $secret ) >= 0;
  return $line;
}

=method quotable

    my $line = $target->quotable( $text, $secret );

The first line of C<$text> when it may go into a message, C<undef>
otherwise: longer than 200 characters, a PEM block or a private key in it,
a control character, or the secret.

=cut

sub _failure {
  my ( $self, $client, $response, $secret ) = @_;
  my ( $host, $port ) = $self->endpoint;
  my $message = 'upload to '.$host.':'.$port.' (node '.$self->api_node.') failed: ';
  my $status  = $response->{status};

  if ( $status eq '599' ) {
    my $error = $self->quotable( $response->{content}, $secret );
    $error = 'no connection' unless defined $error;
    $message .= $error;
    if ( $error =~ /certificate verify failed|hostname verification failed|verify error/i ) {
      $message .= '; the node presents SHA-256 '.$self->_presented($client).'; tried '.$client->anchors;
    }
    return $message;
  }

  my $reason = $self->quotable( $response->{reason}, $secret );
  $message .= $status.( defined $reason ? ' '.$reason : q{} );
  my $detail = $self->api_message($response);
  $detail = $self->quotable( $detail, $secret );
  $message .= ': '.$detail if defined $detail && ( !defined $reason || $detail ne $reason );
  return $message;
}

# The certificate the node presents, asked without a token (the core's
# presented_cert): public, and what the operator compares with the GUI.
sub _presented {
  my ( $self, $client ) = @_;
  my $presented = eval { $self->presented_cert };
  my $error     = $@;
  return 'unknown ('.$self->_first_line($error).')' if !defined $presented && $error;
  return 'unknown (no certificate)' unless defined $presented;
  return $client->format_fingerprint( $presented->fingerprint_sha256 );
}

sub _decode_json_body {
  my ( $self, $response ) = @_;
  my $content = $response->{content};
  return undef unless defined $content && length $content;
  my $data = eval { JSON::MaybeXS->new( utf8 => 1 )->decode($content) };
  return ref $data eq 'HASH' ? $data : undef;
}

sub _first_line {
  my ( $self, $error ) = @_;
  $error = defined $error ? q{}.$error : q{};
  $error =~ s/ at \S+ line [0-9]+\.?\s*\z//;
  my ($line) = grep { /\S/ } split /\r?\n/, $error;
  return defined $line ? $line : 'unknown error';
}

=head1 WHAT A TYPE SUPPLIES

=over 4

=item C<product>, C<api_port>

The name of the product for messages, and the port of its API.

=item C<api_node>

The node in the path of the upload.

=item C<token_id_valid($token_id)>

True when the token id has the form the product accepts.

=item C<authorization($token_id, $secret)>

The value of the C<Authorization> header.

=item C<upload_fields($bundle)>

The body of the upload, as a hash reference.

=item C<answer_certificate($data)>

The certificate info out of C<data> of the answer, or C<undef>.

=item C<api_message($response)>

What of an error answer may be quoted, or C<undef>; L</quotable> is
applied on top.

=item C<validate_type_options($where)>

Croaks on what only this type checks.

=back

=cut

1;
