# 2. What speaks HTTP to the node

Status: decided 2026-10-11 by the session that built the distribution. Card #2.
Evidence: a survey of the sources (read, not run) of the clients below, in the
versions Debian trixie ships, because the image of `../sick` installs Perl
dependencies as Debian packages.

## Decision

**`HTTP::Tiny` on `IO::Socket::SSL`, no Proxmox client library.** One client
object per connection, set up like this and in no other way:

- `verify_SSL => 1`, always passed: without it
  `PERL_HTTP_TINY_SSL_INSECURE_BY_DEFAULT` in the environment could switch
  verification off (HTTP::Tiny 0.090).
- `SSL_options`: `SSL_verify_mode` peer, `SSL_verifycn_scheme => 'http'`,
  `SSL_verifycn_name` and `SSL_hostname` (SNI) the `host` of the device.
- `ca` anchors: all files named under `ca`, concatenated into **one** PEM file
  (public data; `SSL_ca_file` takes one path) in a `SICK::Temp` directory.
  A user `SSL_ca_file` replaces HTTP::Tiny's search for the system store.
- `fingerprint` pins: `SSL_fingerprint => [ 'sha256$<hex>', ... ]`. A match of
  the leaf is accepted on its own, a miss leaves the CA check in charge
  (IO::Socket::SSL 2.089, documented as "an alternative to the normal
  validation"). With pins and no `ca`, also `SSL_force_fingerprint => 1`:
  otherwise the system store would be loaded and a public certificate for that
  name would pass.
- `proxy`, `http_proxy`, `https_proxy` passed as `undef`: an omitted key means
  the environment's `https_proxy` routes the token through a proxy.
- `max_redirect => 0`, `keep_alive => 0`, a `timeout`.
- The check runs in OpenSSL's verify callback during the handshake; HTTP::Tiny
  dies in `start_ssl` before `write_request`. No byte of the request leaves on
  an unverified connection.

Messages: a failed call is reported as method, path, status and reason, plus
the `message` of the API's JSON answer where the notes say it cannot repeat the
body. A status 599 (HTTP::Tiny's own errors) carries the TLS or connection
error text from `content`; that text never contains our header or body - with
one exception that is guarded before the call: HTTP::Tiny quotes a header value
with a control character (`Invalid HTTP header field value`), so the token is
checked to be printable ASCII without spaces, and refused without quoting it.

## Alternatives

| Candidate | Why not |
|---|---|
| `LWP::UserAgent` + `LWP::Protocol::https` | works, but two more packages, more defaults taken from the environment (`PERL_LWP_SSL_VERIFY_HOSTNAME`, `HTTPS_CA_FILE` turning the host name check off, `PERL_LWP_ENV_PROXY`), and errors as 500 responses whose `request->as_string` holds token and body |
| `Mojo::UserAgent`, `Net::Async::HTTP`, `Furl` | all on IO::Socket::SSL too; event loops and environment switches (`MOJO_INSECURE`, `MOJO_PROXY`) for two synchronous calls |
| `Net::Proxmox::VE` 0.44 (CPAN) | PVE only; on a failed request it dies with `$request->as_string` (token header and body); debug prints the same; the POST body is joined without escaping, which breaks a PEM; not in Debian |
| `PVE::APIClient::LWP` (Proxmox) | not on CPAN, not in Debian (Proxmox repository only); turns the host name check off when fingerprints are given, can prompt on STDIN, retries after an unknown fingerprint - a trust model that is not ours |
| `curl` as a program | the reason for this distribution: the header would be on a command line or in a file of a child |

Versions in Debian trixie: perl 5.40.1 (core HTTP::Tiny 0.088; the separate
`libhttp-tiny-perl` 0.090 with the CVE-2026-7017 patch that stops forwarding
`Authorization` across hosts on redirects), `libio-socket-ssl-perl` 2.089,
`libnet-ssleay-perl` 1.94. Redirects are off anyway.

## Consequences

- New dependencies: `HTTP::Tiny`, `IO::Socket::SSL` (and with it
  `Net::SSLeay`), `JSON::MaybeXS`. The image of `../sick` needs
  `libio-socket-ssl-perl` (and `libhttp-tiny-perl` for the patched version) -
  a card on `../sick`.
- Tests may set up the client only through the same code path; there is no
  test hook that loosens the options.
