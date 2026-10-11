package Test::SICK::Proxmox::StandIn;

# A stand-in for the certificate upload of Proxmox VE (pveproxy, "ve") and
# of Proxmox Backup Server (proxmox-backup-proxy, "bs"): an HTTPS server on
# 127.0.0.1 and a random port, in a forked process, answering what
# docs/api-notes.md says and nothing more. It is not a Proxmox. Green against
# it is a statement about our side of the connection.
#
#   my $standin = Test::SICK::Proxmox::StandIn->start(
#     product  => 've',                     # or 'bs'
#     dir      => $dir,                     # its files and its log
#     serve    => $pki_leaf,                # what the port presents at first
#     token_id => 'sick@pve!sick',
#     secret   => $secret,                  # held in memory, never written
#     node     => 'pve1',                   # ve only
#   );
#   $standin->port; $standin->requests; $standin->handshakes_failed; ...
#
# What it implements, per behaviour, with the entry of docs/api-notes.md:
#
# Both
#   - TLS on the port, one certificate (the served file is leaf + chain, as
#     CTX_use_certificate_chain_file reads it), no selection by SNI
#     ("TLS of pveproxy" / "TLS of proxmox-backup-proxy").
#   - Body limit 512 KiB ("Request path and transport").
#
# Proxmox VE ("Proxmox VE (pveproxy, port 8006)")
#   - Token header PVEAPIToken, value after "=" or one space, cut at the
#     first ";", URI-unescaped, split at the LAST "=" ("The token").
#   - No Authorization header: 401 "No ticket", empty body; wrong token or
#     another scheme: 401 "Authentication failed!", empty body; both after
#     a delay of 3 seconds ("Error answers common to all calls").
#   - Missing privilege (option deny => 1): 403 "Permission check failed
#     (/nodes/<node>, Sys.Modify)" with the JSON body of the notes.
#   - Content types: application/json, form, or none; other: 506
#     ("Request path and transport"). A form body is not modelled (501).
#   - 400 "Parameter verification failed." with {"errors":{...}} for: an
#     unknown parameter (additionalProperties 0), certificates missing or
#     not pem-certificate-chain, key not one PEM block, force/restart not
#     1/0/true/false; message texts of the errors are the stand-in's own
#     wording where the notes give none ("POST .../certificates/custom").
#     Text after the last certificate block fails; whitespace after it is
#     taken as no text - an interpretation, the notes do not say.
#   - Without force and with a custom certificate present (option
#     has_custom => 1, or after an upload): 500 "Custom certificate file
#     exists but force flag is not set." ("What it does", 1).
#   - Key not matching the first certificate (checked as pvedaemon does,
#     CTX_use_certificate_chain_file then CTX_use_PrivateKey_file): 500
#     "Setting certificate files failed - key does not match the
#     certificate (chain)", the old files kept ("What it does", 3).
#   - Success: 200 {"data":{...}}, one object of the first certificate,
#     fingerprint upper case with colons ("Success").
#   - Any other error of the handler (option handler_dies => $message): 500,
#     reason the first line, body {"data":null,"message":...} ("Error
#     answers common to all calls").
#   - restart_fails => 1: `systemctl reload-or-restart pveproxy` fails inside
#     the call: 500 "command 'systemctl reload-or-restart pveproxy' failed:
#     exit code 1", the files ARE written, the old certificate stays served
#     (observed PVE 9.2.21 by the orchestrator, docs/real-node-trial.md, being
#     folded into docs/api-notes.md).
#   - restart: the new certificate is served on new connections after
#     restart_delay seconds (the real delay is open in the notes: "Restart
#     (PVE)"; tests set it); without restart the old one stays.
#
# Proxmox Backup Server ("Proxmox Backup Server (proxmox-backup-proxy, port 8007)")
#   - Token header PBSAPIToken, after "=" or one space, split at the FIRST
#     ":", secret percent-decoded ("The token").
#   - Authentication failed or no header: 401, plain-text body
#     "authentication failed", no content type, 3 seconds after the request
#     started ("Error answers common to all calls").
#   - Missing privilege (deny => 1): 403, body "permission check failed",
#     content type application/json, after 0.5 seconds.
#   - Unknown path after authentication: 404 "Path '<path>' not found.".
#   - Content type other than JSON or form: 400 "unsupported content type".
#     A form body is not modelled (501).
#   - Parameter errors: 400, plain text "parameter verification failed -
#     '<param>': <reason>"; force and restart in JSON only as JSON booleans
#     ("Booleans"); the reasons are the stand-in's wording.
#   - Any other error of the handler (handler_dies => $message): 400, the
#     plain text of the error ("Error answers common to all calls").
#   - force and restart are ignored ("POST .../certificates/custom").
#   - The files are written, then the proxy reloads them; if that fails -
#     the key does not match, or option reload_fails => 1 for "unreadable
#     file" - it keeps serving the old certificate and STILL answers 200
#     with the info of the new file ("What it does", 3).
#   - Success: 200 {"data":[{...}]}, an array of one, fingerprint lower case
#     with colons, san DNS names only, pem the whole file ("Success").
#   - The new certificate is served on new connections at once ("Restart (PBS)").
#
# Delays: auth_delay (3) and perm_delay (0.5, PBS) default to the values of
# the notes; tests make them short, which changes nothing but the time.
#
# Fault injection, NOT a behaviour of Proxmox, to test our checks:
#   report_fingerprint => $hex - the success answer names this fingerprint.
#
# Not modelled, answered with 501 "Not modelled by the stand-in": anything
# the notes do not describe (other paths and methods on PVE, a node other
# than the configured one on PVE, a body that is not a JSON object, a PBS
# upload without any certificate - open in the notes).
#
# The log (one JSON object per line, read by the test) holds per connection
# "accept", then "handshake" with ok 0/1, then "request" or "no-request".
# A request entry holds method, path, content type, the scheme of the
# Authorization header, whether it was right (auth: none/ok/wrong) and the
# status - never the secret, the key or the body.

use strict;
use warnings;
use Carp qw( croak );
use IO::Select;
use IO::Socket::INET;
use IO::Socket::SSL;
use JSON::MaybeXS ();
use Net::SSLeay;
use POSIX ();
use Socket qw( inet_ntop AF_INET AF_INET6 );
use Time::HiRes qw( sleep time );
use Time::Local qw( timegm );

my $LIMIT = 512 * 1024;
my $JSON  = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );
my $CERT  = qr/-----BEGIN CERTIFICATE-----\r?\n[A-Za-z0-9+\/=\r\n]+-----END CERTIFICATE-----/;

sub start {
  my ( $class, %arg ) = @_;
  croak 'product is ve or bs' unless defined $arg{product} && $arg{product} =~ /\A(?:ve|bs)\z/;
  for (qw( dir serve token_id secret )) { croak 'start needs '.$_ unless defined $arg{$_} }
  croak 'a ve stand-in needs a node' if $arg{product} eq 've' && !defined $arg{node};

  my $self = bless {
    product       => $arg{product},
    dir           => $arg{dir},
    log           => $arg{dir}.'/standin-'.$arg{product}.'-'.time.'-'.int( rand 1e6 ).'.log',
    token_id      => $arg{token_id},
    secret        => $arg{secret},
    node          => $arg{node},
    auth_delay    => defined $arg{auth_delay} ? $arg{auth_delay} : 3,
    perm_delay    => defined $arg{perm_delay} ? $arg{perm_delay} : 0.5,
    restart_delay => defined $arg{restart_delay} ? $arg{restart_delay} : 0,
    deny          => $arg{deny} ? 1 : 0,
    reload_fails  => $arg{reload_fails} ? 1 : 0,
    has_custom    => $arg{has_custom} ? 1 : 0,
    report_fp     => $arg{report_fingerprint},
    handler_dies  => $arg{handler_dies},
    restart_fails => $arg{restart_fails} ? 1 : 0,
    served        => { cert => $arg{serve}{served}, key => $arg{serve}{key} },
    pending       => undef,
    seq           => 0,
  }, $class;

  open my $touch, '>', $self->{log} or croak 'cannot create '.$self->{log}.': '.$!;
  close $touch;

  my $listen = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Listen    => 16,
    ReuseAddr => 1,
    Proto     => 'tcp',
  ) or croak 'cannot listen: '.$!;
  $self->{port} = $listen->sockport;

  my $pid = fork;
  croak 'cannot fork: '.$! unless defined $pid;
  unless ($pid) {
    # Child: never return into the test, never run its END blocks.
    eval {
      open STDIN,  '<', '/dev/null';
      open STDOUT, '>>', $self->{dir}.'/standin.out';
      open STDERR, '>>', $self->{dir}.'/standin.out';
      $SIG{TERM} = sub { POSIX::_exit(0) };
      $self->_serve($listen);
      1;
    };
    POSIX::_exit(0);
  }
  close $listen;
  $self->{pid}    = $pid;
  $self->{parent} = $$;
  delete $self->{secret};    # the test keeps its own copy
  return $self;
}

sub port { $_[0]{port} }

sub stop {
  my ( $self ) = @_;
  return unless $self->{pid} && $self->{parent} == $$;
  kill 'TERM', $self->{pid};
  waitpid $self->{pid}, 0;
  delete $self->{pid};
  return;
}

sub DESTROY { $_[0]->stop }

#### what the test reads

sub entries {
  my ( $self ) = @_;
  open my $fh, '<', $self->{log} or croak 'cannot read '.$self->{log}.': '.$!;
  my @entries = map { $JSON->decode($_) } grep { /\S/ } <$fh>;
  close $fh;
  return @entries;
}

sub requests          { grep { $_->{event} eq 'request' } $_[0]->entries }
sub uploads           { grep { $_->{event} eq 'request' && $_->{method} eq 'POST' } $_[0]->entries }
sub accepts           { scalar grep { $_->{event} eq 'accept' } $_[0]->entries }
sub handshakes_ok     { scalar grep { $_->{event} eq 'handshake' && $_->{ok} } $_[0]->entries }
sub handshakes_failed { scalar grep { $_->{event} eq 'handshake' && !$_->{ok} } $_[0]->entries }

sub log_text {
  my ( $self ) = @_;
  open my $fh, '<', $self->{log} or croak 'cannot read '.$self->{log}.': '.$!;
  local $/;
  my $text = <$fh>;
  close $fh;
  return $text;
}

# Waits until every connection the stand-in accepted is through: the
# handshake failed, or a request or none was read. A client that gave up on
# the certificate returns before the stand-in has written that down.
sub settle {
  my ( $self, $timeout ) = @_;
  my $deadline = time + ( defined $timeout ? $timeout : 5 );
  while ( time < $deadline ) {
    my @entries = $self->entries;
    my $accepted = grep { $_->{event} eq 'accept' } @entries;
    my $done     = grep {
      $_->{event} eq 'handshake' && !$_->{ok}
        || $_->{event} eq 'request'
        || $_->{event} eq 'no-request'
    } @entries;
    return 1 if $done >= $accepted;
    sleep 0.05;
  }
  return 0;
}

#### the server

sub _log {
  my ( $self, %entry ) = @_;
  open my $fh, '>>', $self->{log} or return;
  print {$fh} $JSON->encode( { %entry, conn => $self->{seq} } )."\n";
  close $fh;
  return;
}

sub _serve {
  my ( $self, $listen ) = @_;
  while (1) {
    my $conn = $listen->accept or next;
    $self->{seq}++;
    $self->_log( event => 'accept' );
    if ( $self->{pending} && time >= $self->{pending}{at} ) {
      $self->{served} = delete( $self->{pending} )->{files};
    }
    my $ok = IO::Socket::SSL->start_SSL(
      $conn,
      SSL_server    => 1,
      SSL_cert_file => $self->{served}{cert},
      SSL_key_file  => $self->{served}{key},
      Timeout       => 5,
    );
    unless ($ok) {
      $self->_log( event => 'handshake', ok => 0 );
      close $conn;
      next;
    }
    $self->_log( event => 'handshake', ok => 1 );
    my $request = $self->_read_request($conn);
    unless ($request) {
      $self->_log( event => 'no-request' );
      close $conn;
      next;
    }
    my $response = $self->{product} eq 've' ? $self->_ve($request) : $self->_bs($request);
    $self->_log(
      event        => 'request',
      method       => $request->{method},
      path         => $request->{path},
      content_type => $request->{headers}{'content-type'},
      scheme       => $request->{scheme},
      auth         => $request->{auth},
      status       => $response->{status},
    );
    $self->_write( $conn, $response );
    close $conn;
  }
}

sub _read_request {
  my ( $self, $conn ) = @_;
  my $buffer   = q{};
  my $deadline = time + 5;
  my $select   = IO::Select->new($conn);
  while ( index( $buffer, "\r\n\r\n" ) < 0 ) {
    return undef if time > $deadline || length $buffer > 65536;
    unless ( $conn->pending ) {
      next unless $select->can_read(0.2);
    }
    my $n = sysread $conn, my $chunk, 16384;
    return undef unless $n;
    $buffer .= $chunk;
  }
  my ( $head, $body ) = split /\r\n\r\n/, $buffer, 2;
  my ( $line, @lines ) = split /\r\n/, $head;
  my ( $method, $target ) = $line =~ m{\A([A-Z]+) (\S+) HTTP/1\.[01]\z} or return undef;
  my %headers;
  for (@lines) {
    my ( $name, $value ) = /\A([^:]+):\s*(.*?)\s*\z/ or next;
    $headers{ lc $name } = $value;
  }
  my $length = $headers{'content-length'} || 0;
  my %request = (
    method  => $method,
    path    => ( $target =~ s/\?.*//r ),
    headers => \%headers,
    started => time,
  );
  if ( $length > $LIMIT ) {
    $request{too_large} = 1;
    return \%request;
  }
  while ( length $body < $length ) {
    return undef if time > $deadline;
    unless ( $conn->pending ) {
      next unless $select->can_read(0.2);
    }
    my $n = sysread $conn, my $chunk, 65536;
    return undef unless $n;
    $body .= $chunk;
  }
  $request{body} = $body;
  $self->_check_token( \%request );
  return \%request;
}

# Which scheme the header names and whether it is right; the secret is
# compared here and kept nowhere else.
sub _check_token {
  my ( $self, $request ) = @_;
  my $header = $request->{headers}{authorization};
  unless ( defined $header ) {
    @$request{qw( scheme auth )} = ( undef, 'none' );
    return;
  }
  my ($scheme) = $header =~ /\A([A-Za-z]+)/;
  $request->{scheme} = defined $scheme ? $scheme : 'other';
  my ( $id, $secret );
  if ( $self->{product} eq 've' && $header =~ /\APVEAPIToken[= ](.*)\z/s ) {
    my $value = $1;
    $value =~ s/;.*//s;
    $value =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
    my $at = rindex $value, '=';
    ( $id, $secret ) = ( substr( $value, 0, $at ), substr( $value, $at + 1 ) ) if $at > 0;
  }
  elsif ( $self->{product} eq 'bs' && $header =~ /\APBSAPIToken[= ](.*)\z/s ) {
    my $value = $1;
    my $at    = index $value, ':';
    if ( $at > 0 ) {
      ( $id, $secret ) = ( substr( $value, 0, $at ), substr( $value, $at + 1 ) );
      $secret =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
    }
  }
  $request->{auth}
    = defined $id && $id eq $self->{token_id} && $secret eq $self->{secret} ? 'ok' : 'wrong';
  return;
}

sub _write {
  my ( $self, $conn, $response ) = @_;
  my $body = defined $response->{body} ? $response->{body} : q{};
  my $head = 'HTTP/1.1 '.$response->{status}.' '.$response->{reason}."\r\n"
    .( defined $response->{type} ? 'Content-Type: '.$response->{type}."\r\n" : q{} )
    .'Content-Length: '.length($body)."\r\n"
    ."Connection: close\r\n\r\n";
  print {$conn} $head.$body;
  return;
}

sub _wait_until {
  my ( $self, $request, $seconds ) = @_;
  my $left = $request->{started} + $seconds - time;
  sleep $left if $left > 0;
  return;
}

sub _not_modelled {
  return { status => 501, reason => 'Not modelled by the stand-in', body => q{} };
}

#### Proxmox VE

sub _ve_error {
  my ( $self, $status, $message, $errors ) = @_;
  my ($first) = split /\n/, $message;
  return {
    status => $status,
    reason => $first,
    type   => 'application/json;charset=UTF-8',
    body   => $JSON->encode( { data => undef, message => $message."\n", ( $errors ? ( errors => $errors ) : () ) } ),
  };
}

sub _ve {
  my ( $self, $request ) = @_;
  return { status => 501, reason => 'for data too large', body => q{} } if $request->{too_large};

  if ( $request->{auth} ne 'ok' ) {
    $self->_wait_until( $request, $self->{auth_delay} );
    return { status => 401, reason => $request->{auth} eq 'none' ? 'No ticket' : 'Authentication failed!', body => q{} };
  }

  my ($node) = $request->{path} =~ m{\A/api2/json/nodes/([^/]+)/certificates/custom\z};
  return $self->_not_modelled unless $request->{method} eq 'POST' && defined $node && $node eq $self->{node};

  my $type = $request->{headers}{'content-type'};
  if ( defined $type && length $type ) {
    return $self->_not_modelled if $type =~ m{\Aapplication/x-www-form-urlencoded\b}i;
    return { status => 506, reason => 'Unsupported content type', body => q{} }
      unless $type =~ m{\Aapplication/json\b}i;
  }
  else {
    return $self->_not_modelled;
  }

  return $self->_ve_error( 403, 'Permission check failed (/nodes/'.$node.', Sys.Modify)' ) if $self->{deny};

  my $param = eval { $JSON->decode( $request->{body} ) };
  return $self->_not_modelled unless ref $param eq 'HASH';

  my %errors;
  my %known = map { $_ => 1 } qw( certificates key force restart node );
  $errors{$_} = 'property is not defined in schema and the schema does not allow additional properties'
    for grep { !$known{$_} } keys %$param;
  if ( defined $param->{node} && $param->{node} ne $node ) {
    $errors{node} = 'duplicate parameter (already defined in URI) with conflicting values!';
  }
  my $certificates = $param->{certificates};
  if ( !defined $certificates ) {
    $errors{certificates} = 'property is missing and it is not optional';
  }
  else {
    ( my $chain = $certificates ) =~ s/\A.*?(?=-----BEGIN CERTIFICATE-----)//s;
    $errors{certificates} = 'not a PEM certificate chain'
      unless !ref $chain && $chain =~ /\A$CERT(?:\s*$CERT)*\s*\z/;
  }
  my $key = $param->{key};
  if ( defined $key ) {
    my @blocks = !ref $key ? $key =~ /-----BEGIN [A-Z0-9 ]+-----/g : ();
    $errors{key} = 'not a single PEM block' unless @blocks == 1;
  }
  for my $flag (qw( force restart )) {
    my $value = $param->{$flag};
    next unless defined $value;
    next if JSON::MaybeXS::is_bool($value) || !ref $value && $value =~ /\A[01]\z/;
    $errors{$flag} = 'type check (\'boolean\') failed - got \''.( ref $value ? 'a reference' : $value ).'\'';
  }
  return $self->_ve_error( 400, 'Parameter verification failed.', \%errors ) if %errors;

  my $force   = $param->{force}   ? 1 : 0;
  my $restart = $param->{restart} ? 1 : 0;

  if ( !defined $key && !$self->{has_custom} ) {
    return $self->_ve_error( 400, 'Parameter verification failed.',
      { key => 'Attempted to upload custom certificate without (existing) key.' } );
  }
  return $self->_ve_error( 500, $self->{handler_dies} ) if defined $self->{handler_dies};
  return $self->_ve_error( 500, 'Custom certificate file exists but force flag is not set.' )
    if $self->{has_custom} && !$force;

  ( my $chain = $certificates ) =~ s/\A.*?(?=-----BEGIN CERTIFICATE-----)//s;
  my $files = $self->_write_files( 'pveproxy-ssl', $chain, $key );
  unless ( $self->_loads($files) ) {
    # the new files are removed, the old ones stay
    return $self->_ve_error( 500, 'Setting certificate files failed - key does not match the certificate (chain)' );
  }
  $self->{has_custom} = 1;
  return $self->_ve_error( 500, 'command \'systemctl reload-or-restart pveproxy\' failed: exit code 1' )
    if $restart && $self->{restart_fails};
  $self->{pending} = { at => time + $self->{restart_delay}, files => $files } if $restart;

  my $info = $self->_info( $chain, 'pveproxy-ssl.pem' );
  $info->{fingerprint} = uc join ':', $info->{fingerprint} =~ /(..)/g;
  $info->{pem}         = ( $chain =~ /($CERT)/ )[0]."\n";
  $info->{san}         = [ @{ delete $info->{dns} }, @{ delete $info->{ip} } ];
  $info->{fingerprint} = uc join ':', $self->{report_fp} =~ /(..)/g if defined $self->{report_fp};
  return {
    status => 200,
    reason => 'OK',
    type   => 'application/json;charset=UTF-8',
    body   => $JSON->encode( { data => $info } ),
  };
}

#### Proxmox Backup Server

sub _bs_text {
  my ( $self, $status, $reason, $text, $type ) = @_;
  return { status => $status, reason => $reason, body => $text, type => $type };
}

sub _bs {
  my ( $self, $request ) = @_;
  return $self->_bs_text( 400, 'Bad Request', 'Request body too large' ) if $request->{too_large};

  if ( $request->{auth} ne 'ok' ) {
    $self->_wait_until( $request, $self->{auth_delay} );
    return $self->_bs_text( 401, 'Unauthorized', 'authentication failed' );
  }

  my ($node) = $request->{path} =~ m{\A/api2/json/nodes/([A-Za-z0-9.-]+)/certificates/custom\z};
  return $self->_bs_text( 404, 'Not Found', 'Path \''.$request->{path}.'\' not found.', 'application/json' )
    unless $request->{method} eq 'POST' && defined $node;

  if ( $self->{deny} ) {
    $self->_wait_until( $request, $self->{perm_delay} );
    return $self->_bs_text( 403, 'Forbidden', 'permission check failed', 'application/json' );
  }

  my $type = $request->{headers}{'content-type'};
  return $self->_not_modelled
    if !defined $type || !length $type || $type =~ m{\Aapplication/x-www-form-urlencoded\b}i;
  return $self->_bs_text( 400, 'Bad Request', 'unsupported content type', 'application/json' )
    unless $type =~ m{\Aapplication/json\b}i;

  my $param = eval { $JSON->decode( $request->{body} ) };
  return $self->_not_modelled unless ref $param eq 'HASH';

  my @errors;
  for my $flag (qw( force restart )) {
    push @errors, '\''.$flag.'\': Expected boolean value.'
      if defined $param->{$flag} && !JSON::MaybeXS::is_bool( $param->{$flag} );
  }
  push @errors, '\'certificates\': property is missing and it is not optional'
    unless defined $param->{certificates};
  if (@errors) {
    my $text = @errors == 1
      ? 'parameter verification failed - '.$errors[0]
      : join "\n", 'parameter verification failed:', @errors;
    return $self->_bs_text( 400, 'Bad Request', $text, 'application/json' );
  }

  return $self->_bs_text( 400, 'Bad Request', $self->{handler_dies}, 'application/json' )
    if defined $self->{handler_dies};

  my @certs = ref $param->{certificates} ? () : $param->{certificates} =~ /($CERT)/g;
  return $self->_not_modelled unless @certs;
  my $chain = join "\n", @certs;
  $chain .= "\n";
  my $key = $param->{key};
  my $files = $self->_write_files( 'proxy', $chain, defined $key ? $key : $self->_slurp( $self->{served}{key} ) );

  # the proxy reloads; when that fails it keeps the old acceptor, and the
  # call answers success all the same
  $self->{served} = $files if !$self->{reload_fails} && $self->_loads($files);

  my $info = $self->_info( $chain, 'proxy.pem' );
  $info->{fingerprint} = lc join ':', $info->{fingerprint} =~ /(..)/g;
  $info->{pem}         = $chain;
  $info->{san}         = delete $info->{dns};
  delete $info->{ip};
  $info->{fingerprint} = lc join ':', $self->{report_fp} =~ /(..)/g if defined $self->{report_fp};
  return {
    status => 200,
    reason => 'OK',
    type   => 'application/json;charset=UTF-8',
    body   => $JSON->encode( { data => [$info] } ),
  };
}

#### files and certificates

sub _write_files {
  my ( $self, $base, $chain, $key ) = @_;
  my $n    = ++$self->{files};
  my $cert = $self->{dir}.'/'.$self->{product}.'-'.$base.'-'.$n.'.pem';
  my $kf   = $self->{dir}.'/'.$self->{product}.'-'.$base.'-'.$n.'.key';
  for ( [ $cert, $chain ], [ $kf, $key ] ) {
    open my $fh, '>', $_->[0] or die 'cannot write '.$_->[0].': '.$!;
    chmod 0600, $_->[0];
    print {$fh} $_->[1];
    close $fh;
  }
  return { cert => $cert, key => $kf };
}

# As pvedaemon and the proxy of PBS load them: the chain, then the key,
# which OpenSSL checks against the first certificate.
sub _loads {
  my ( $self, $files ) = @_;
  my $ctx = Net::SSLeay::CTX_new() or return 0;
  my $ok = Net::SSLeay::CTX_use_certificate_chain_file( $ctx, $files->{cert} )
    && Net::SSLeay::CTX_use_PrivateKey_file( $ctx, $files->{key}, &Net::SSLeay::FILETYPE_PEM )
    && Net::SSLeay::CTX_check_private_key($ctx);
  Net::SSLeay::ERR_clear_error();
  Net::SSLeay::CTX_free($ctx);
  return $ok ? 1 : 0;
}

# The certificate info of the first certificate, as both products report it.
sub _info {
  my ( $self, $chain, $filename ) = @_;
  my ($first) = $chain =~ /($CERT)/;
  my $bio = Net::SSLeay::BIO_new( Net::SSLeay::BIO_s_mem() );
  Net::SSLeay::BIO_write( $bio, $first );
  my $x509 = Net::SSLeay::PEM_read_bio_X509($bio);
  Net::SSLeay::BIO_free($bio);
  die 'cannot read the uploaded certificate' unless $x509;
  my ( @dns, @ip );
  my @san = Net::SSLeay::X509_get_subjectAltNames($x509);
  while ( my ( $kind, $value ) = splice @san, 0, 2 ) {
    push @dns, $value if $kind == 2;
    if ( $kind == 7 ) {
      push @ip, length $value == 4 ? inet_ntop( AF_INET, $value ) : length $value == 16 ? inet_ntop( AF_INET6, $value ) : $value;
    }
  }
  my $pkey = Net::SSLeay::X509_get_pubkey($x509);
  my %info = (
    filename          => $filename,
    fingerprint       => ( lc( Net::SSLeay::X509_get_fingerprint( $x509, 'sha256' ) ) =~ tr/://dr ),
    subject           => Net::SSLeay::X509_NAME_oneline( Net::SSLeay::X509_get_subject_name($x509) ),
    issuer            => Net::SSLeay::X509_NAME_oneline( Net::SSLeay::X509_get_issuer_name($x509) ),
    notbefore         => $self->_epoch( Net::SSLeay::P_ASN1_TIME_get_isotime( Net::SSLeay::X509_get_notBefore($x509) ) ),
    notafter          => $self->_epoch( Net::SSLeay::P_ASN1_TIME_get_isotime( Net::SSLeay::X509_get_notAfter($x509) ) ),
    'public-key-type' => Net::SSLeay::OBJ_nid2sn( Net::SSLeay::EVP_PKEY_id($pkey) ),
    'public-key-bits' => Net::SSLeay::EVP_PKEY_bits($pkey),
    dns               => \@dns,
    ip                => \@ip,
  );
  Net::SSLeay::EVP_PKEY_free($pkey);
  Net::SSLeay::X509_free($x509);
  return \%info;
}

sub _epoch {
  my ( $self, $iso ) = @_;
  my @t = $iso =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})/ or return undef;
  return timegm( $t[5], $t[4], $t[3], $t[2], $t[1] - 1, $t[0] );
}

sub _slurp {
  my ( $self, $path ) = @_;
  open my $fh, '<', $path or die 'cannot read '.$path.': '.$!;
  local $/;
  my $content = <$fh>;
  close $fh;
  return $content;
}

1;
