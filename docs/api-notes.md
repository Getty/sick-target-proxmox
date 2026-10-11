# API notes: Proxmox VE and Proxmox Backup Server

This file is the source of truth for what the APIs of Proxmox VE (PVE) and
Proxmox Backup Server (PBS) do, as far as this distribution depends on it.
Code that depends on a behaviour of an API has that behaviour written down
here first. Where the code and these notes disagree, the notes are right
until a new observation is written into them.

Every statement carries its origin:

| Tag | Meaning |
|---|---|
| `[schema]` | read in the API viewer schema (`apidoc.js`); version and date in "Sources read" |
| `[source: repo file]` | read in the source code; commit and version of the repository in "Sources read" |
| `[docs: repo file]` | read in the product documentation (also a source repository) |
| `[stand-in]` | observed against our stand-in API. None yet. |
| `[observed PBS 4.2.8]` | observed on a real PBS 4.2.8-1 in a container (below) |
| `[observed PVE 9.2.21, container]` | observed on a real PVE 9.2.21 in a container (below); restart timings with the shim |
| `[derived]` | our conclusion from the statements it names; not read anywhere as such |

Sources were read on 2026-10-11. Nothing from the cloned sources was
executed.

The observations are from a trial of 2026-10-11: setup, exact versions,
scripts and raw results in `docs/real-node-trial.md`. "Container" means:
the real Debian packages and the real daemons, in a Debian trixie Docker
container, **without systemd**. PBS ran as packaged (`proxmox-backup-api`
as root, `proxmox-backup-proxy` as `backup`, started as the units do);
nothing PBS does on an upload goes through systemd. PVE ran the real
pmxcfs (local mode, no cluster, no corosync), pvedaemon and pveproxy; the
restart of pveproxy after an upload goes through `systemctl`, which was
replaced by a **shim** that does what the unit's `ExecReload` does
(`pveproxy restart`, i.e. `HUP` to the master). Every PVE restart timing
is therefore "with the shim", not "under systemd". Every request of the
trial was verified (`--cacert`/`-CAfile`). A node under systemd and a
cluster are still to be observed: `docs/hq-checklist.md`.

PVE and PBS look alike and differ in the details. Nothing is carried over
from one to the other: each statement is in the section of its product.

Examples use neutral names only: node `pve1`, hosts
`pve1.example.internal` and `pbs1.example.internal`, users `sick@pve` and
`sick@pbs`, token id `sick`, addresses from 192.0.2.0/24. `<secret>` stands
for a token secret and is never a real value.

---

## Proxmox VE (pveproxy, port 8006)

### Request path and transport

- The API listens on TCP 8006 with TLS, served by `pveproxy`
  `[source: pve-manager PVE/Service/pveproxy.pm]`
  `[observed PVE 9.2.21, container]`.
- The upload and the delete are `protected`: pveproxy checks the
  authentication and the permission, then forwards the call to `pvedaemon`
  on the same node, which runs it as root `[schema]`
  `[source: pve-manager PVE/HTTPServer.pm rest_handler]`.
- They are `proxyto => 'node'`: in a cluster, the node that receives the
  call forwards it to the node named in the path
  `[source: pve-manager PVE/API2/Certificates.pm]`.
- Request bodies are accepted as `application/x-www-form-urlencoded`,
  `application/json`, or without content type (then parsed as form data).
  Any other content type is answered with 506
  `[source: pve-http-server src/PVE/APIServer/AnyEvent.pm]`. JSON and
  form bodies both work for the upload `[observed PVE 9.2.21, container]`.
- Query string parameters are merged into the body parameters and win over
  them `[source: pve-http-server AnyEvent.pm extract_params]`.
- A body on a method other than POST and PUT is answered with
  `501 Unexpected content for method 'DELETE'`. Parameters of a DELETE go
  into the query string `[source: pve-http-server AnyEvent.pm]`;
  `?restart=1` on a DELETE works `[observed PVE 9.2.21, container]`.
- The body limit is 512 KiB; larger is `501 for data too large`
  `[source: pve-http-server AnyEvent.pm $limit_max_post]`.
- A path parameter repeated in the body with a different value is a 400
  ("duplicate parameter (already defined in URI) with conflicting values!")
  `[source: pve-manager PVE/HTTPServer.pm]`.
- A plain-HTTP request on port 8006 is read completely, then answered with
  `301`/`308` to `https://` `[source: pve-http-server AnyEvent.pm
  ensure_tls_connection]`. The request, with its `Authorization` header,
  has already crossed the network in the clear by then `[derived]`.

### Booleans

- A parameter of type boolean passes validation as the string or number `1`
  or `0`, or as a JSON `true`/`false`. The strings `true`, `yes`, `on` fail
  with 400 (`type check ('boolean') failed - got 'true'`)
  `[source: pve-common src/PVE/JSONSchema.pm check_type]`.
- In a JSON body, `"1"` (string, as the acme.sh hook sends it), `1`
  (number) and `true` are all accepted for `force` and `restart`; in a form
  body `1` is accepted `[observed PVE 9.2.21, container]`. The strings
  `true`/`yes`/`on` were not tried.
- With a JSON body pveproxy forwards JSON to pvedaemon, so a JSON boolean
  stays a JSON boolean `[source: pve-http-server AnyEvent.pm proxy_request]`.

### The token

- Header: `Authorization: PVEAPIToken=sick@pve!sick=<secret>`
  `[source: pve-http-server AnyEvent.pm, Formatter.pm extract_auth_value;
  pve-access-control src/PVE/AccessControl.pm verify_token]`
  `[observed PVE 9.2.21, container]`.
- The value after `PVEAPIToken` is taken up to the first `;`, after `=` or
  a single space, and is URI-unescaped. It is split at the **last** `=` into
  token id and secret `[source: pve-http-server Formatter.pm;
  pve-access-control AccessControl.pm verify_token]`.
- Token id: `user@realm!tokenid`, the token part matching
  `[A-Za-z][A-Za-z0-9.\-_]+` (at least two characters, a letter first)
  `[source: pve-access-control AccessControl.pm $token_subid_regex,
  src/PVE/Auth/Plugin.pm $realm_regex]` `[schema]`.
- A ticket cookie (`PVEAuthCookie`, or in the `Authorization` header) takes
  precedence over the token. A client sends no cookie
  `[source: pve-http-server AnyEvent.pm]`.
- With a token, no CSRF prevention token is needed. The source says so
  explicitly ("skip the check with API tokens")
  `[source: pve-manager PVE/HTTPServer.pm auth_handler]`
  `[observed PVE 9.2.21, container]` (uploads with the token header only).
- The token is checked for: user enabled, token existing, token not expired
  (`expire` in epoch seconds, 0 = never), secret correct
  `[source: pve-access-control AccessControl.pm verify_token]`. A token
  with an expiry one day ahead worked `[observed PVE 9.2.21, container]`;
  an expired token was not tried.
- An endpoint without `allowtoken` refuses tokens with 403. The upload,
  the delete and info have `allowtoken: 1` `[schema]`
  `[source: pve-manager PVE/HTTPServer.pm]` `[observed PVE 9.2.21,
  container]`.
- Privilege separation (`privsep`, default 1): the token's privileges are
  the intersection of its own ACL and its user's. With `privsep 0` the token
  has its user's privileges `[schema]`
  `[source: pve-access-control src/PVE/RPCEnvironment.pm]`. With `privsep 1`
  and the ACL on the token alone, the upload is a 403; with the ACL on token
  and user it is accepted `[observed PVE 9.2.21, container]`.

### Error answers common to all calls

- Authentication failed (wrong secret, unknown or expired token, malformed
  header): status `401`, reason phrase `Authentication failed!`, empty
  body, sent after a delay of 3 seconds
  `[source: pve-manager PVE/HTTPServer.pm auth_handler; pve-http-server
  AnyEvent.pm]`. Wrong secret: `HTTP/1.1 401 Authentication failed!`, empty
  body, ~3 s `[observed PVE 9.2.21, container]`.
- No `Authorization` header and no cookie: `401 No ticket`, empty body,
  3 seconds delay `[source: same]`.
- Missing privilege: status `403`, reason phrase
  `Permission check failed (/nodes/pve1, Sys.Modify)`, body
  `{"data":null,"message":"Permission check failed (/nodes/pve1, Sys.Modify)\n"}`
  `[source: pve-access-control RPCEnvironment.pm check; pve-common
  src/PVE/Exception.pm raise_perm_exc; pve-http-server
  src/PVE/APIServer/Formatter/Standard.pm]` `[observed PVE 9.2.21,
  container]`.
- Parameter verification failed: `400 Parameter verification failed.`,
  body `{"data":null,"errors":{"<param>":"<reason>"},"message":"Parameter verification failed.\n"}`
  `[source: pve-common JSONSchema.pm validate; Formatter/Standard.pm]`.
- Any other error in the handler (`die`): status `500`, reason phrase = the
  first line of the message, body `{"data":null,"message":"<message>"}`
  `[source: pve-manager PVE/HTTPServer.pm rest_handler; pve-http-server
  AnyEvent.pm response]` `[observed PVE 9.2.21, container]` (the message
  in the body ends in one to three `\n`).
- Every error message reaches the HTTP reason phrase (first line only)
  `[source: pve-http-server AnyEvent.pm response]`. Our code quotes neither
  the reason phrase nor the body without checking they cannot hold the
  request `[derived]`.

### POST /api2/json/nodes/{node}/certificates/custom (upload)

- Permission: `Sys.Modify` on `/nodes/{node}` `[schema]`
  `[source: pve-manager PVE/API2/Certificates.pm]` `[observed PVE 9.2.21,
  container]` (a role with only `Sys.Modify` suffices).
- `{node}`: the PVE node name, format `pve-node`
  (`^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?$`) `[schema]`
  `[source: pve-common JSONSchema.pm]`.
- `localhost` passes the format, but the files are written to
  `/etc/pve/nodes/<node>/`, so `localhost` would write to
  `/etc/pve/nodes/localhost/` `[source: pve-manager PVE/CertHelpers.pm
  cert_path_prefix]`. The real node name is required `[derived]`.
- A name that is not a node of the cluster (tried on `info`): `500
  hostname lookup 'foo' failed - failed to get address info for: foo: No
  address associated with hostname` `[observed PVE 9.2.21, container]`.
- Parameters `[schema]`:
  - `certificates` (string, required, format `pem-certificate-chain`):
    one or more `-----BEGIN CERTIFICATE-----` blocks separated by newlines.
    Text before the first block is stripped; text after the last block
    fails validation `[source: pve-common src/PVE/Certificate.pm check_pem]`.
  - `key` (string, optional, format `pem-string`): exactly one PEM block,
    any label `[source: pve-common Certificate.pm]`. Without `key`, the
    existing `pveproxy-ssl.key` is used; if there is none, 400 with
    `errors.key` "Attempted to upload custom certificate without
    (existing) key." `[source: pve-manager Certificates.pm]`. Without `key`
    and a stored key that matches: 200; that does not match: the 500 of
    step 3 below, with the prefix `124:` `[observed PVE 9.2.21, container]`.
  - `force` (boolean, default 0): "Overwrite existing custom or ACME
    certificate files."
  - `restart` (boolean, default 0): "Restart pveproxy."
  - `node` (string, required; from the path).
  - `additionalProperties: 0`: any other parameter is a 400.
- What it does `[source: pve-manager Certificates.pm, PVE/CertHelpers.pm
  set_cert_files]`, under the lock `/var/lock/pve-certs.lock` (10 s):
  1. Without `force`, an existing `pveproxy-ssl.pem` or `pveproxy-ssl.key`
     is an error: `500`, message
     `Custom certificate file exists but force flag is not set.`
     (or `... key file exists ...`). Observed: status line `500 Custom
     certificate file exists but force flag is not set.`, nothing changed;
     without `force` and no custom files yet: 200 `[observed PVE 9.2.21,
     container]`.
  2. Copies the existing files to `.old`, writes
     `/etc/pve/nodes/<node>/pveproxy-ssl.pem` and `pveproxy-ssl.key`
     (the cluster file system; `/etc/pve/local` is a symlink to the
     node's own directory). Stored: the chain as sent, the key **as sent**
     (a traditional key stays traditional), root:www-data 0640
     `[observed PVE 9.2.21, container]`.
  3. Loads both into an OpenSSL context
     (`CTX_use_certificate_chain_file`, then `CTX_use_PrivateKey_file`).
     A key **of the same type** that does not match the first certificate
     fails here: both new files are removed, the `.old` ones are restored,
     the old certificate stays presented, and the answer is
     `500 Setting certificate files failed - 122: key does not match the
     certificate (chain) ()` (the number varies: `124:` when the stored key
     was used) `[observed PVE 9.2.21, container]`. **A key of another type
     than the first certificate passes this check** (an RSA key with an EC
     first certificate): the files are written and the answer is 200
     `[observed PVE 9.2.21, container]`. The source reading had suggested
     that every non-matching key fails here; OpenSSL puts a key of another
     type into another slot of the context without complaint. See "Chains
     and keys (PVE)" for what follows.
  4. With `restart` set: runs `systemctl reload-or-restart pveproxy`
     before answering (see "Restart" below).
- Success: `200`, body `{"data":{...}}` with one object (not an array)
  `[schema]` `[source: pve-common Certificate.pm get_certificate_info]`
  `[observed PVE 9.2.21, container]`:
  `filename` (`pveproxy-ssl.pem`), `fingerprint`, `subject`, `issuer`
  (OpenSSL one-line form `/CN=.../O=...`), `notbefore`, `notafter` (epoch
  seconds), `san` (DNS names and IP addresses as strings), `pem` (the
  first certificate only), `public-key-type` (OpenSSL short name, e.g.
  `rsaEncryption`, `id-ecPublicKey`), `public-key-bits`. All describe the
  **first** certificate of the chain (a wrongly ordered chain answers with
  the intermediate's subject and an empty `san`) `[observed PVE 9.2.21,
  container]`.
- `fingerprint`: SHA-256 of the DER certificate, upper-case hex pairs
  separated by `:` `[source: Net::SSLeay 1.94 SSLeay.xs
  X509_get_fingerprint]` `[observed PVE 9.2.21, container]`. The schema
  pattern allows either case `[schema]`.
- The call is synchronous: no task (UPID) is returned `[source:
  pve-manager Certificates.pm]` `[observed PVE 9.2.21, container]`.
  Duration: ~35 ms without `restart`, 1.32-1.43 s with `restart` (with the
  shim) `[observed PVE 9.2.21, container]`.
- Key formats: RSA and EC P-256 keys, traditional (`RSA PRIVATE KEY`,
  SEC1 `EC PRIVATE KEY`) and PKCS#8 (`PRIVATE KEY`), are accepted and
  served `[observed PVE 9.2.21, container]`.

### Restart (PVE)

- `restart=1` makes pvedaemon run `systemctl reload-or-restart pveproxy`
  inside the call, before the answer `[source: pve-manager
  Certificates.pm]` `[observed PVE 9.2.21, container]` (exactly one such
  call per upload with `restart`).
- **When that command fails, the answer is a 500 although the files are
  written**: `500 command 'systemctl reload-or-restart pveproxy' failed:
  exit code 1`; `pveproxy-ssl.pem`/`.key` stay on disk (nothing is rolled
  back), the old certificate stays presented until the next restart
  `[observed PVE 9.2.21, container]` (with the real `systemctl` on a
  container without systemd).
- `ExecReload` of `pveproxy.service` is `pveproxy restart`
  `[source: pve-manager services/pveproxy.service]`. It sends `SIGHUP` to
  the running pveproxy master and returns `[source: pve-common
  src/PVE/Daemon.pm register_restart_command, $reload_daemon]`.
- On `SIGHUP` the master stops accepting, leaves its workers running, and
  re-executes itself (same PID); the new process reads the certificate
  files again and starts new workers `[source: pve-common Daemon.pm;
  pve-manager PVE/Service/pveproxy.pm]` `[observed PVE 9.2.21, container]`
  (syslog: `received signal HUP`, `server shutdown (restart)`, ~2 s later
  `Using '/etc/pve/local/pveproxy-ssl.pem' ...`, `starting 3 worker(s)`,
  ~5 s later the old workers exit).
- **The old workers keep accepting new connections until they exit**, so
  for several seconds new connections get the old or the new certificate
  alternately: first new certificate 1.3-1.6 s after the answer in a poll
  loop, alternation for ~4-6 s, stable from ~6 s after the answer
  `[observed PVE 9.2.21, container]` (with the shim). The source reading
  (`leave_children_open_on_reload`) had suggested that the old workers only
  finish connections already open and that new connections get the new
  certificate once the new master runs. A keep-alive connection keeps the
  old certificate `[derived]`.
- pveproxy uses `/etc/pve/local/pveproxy-ssl.pem` and
  `/etc/pve/local/pveproxy-ssl.key` if both exist, otherwise
  `/etc/pve/local/pve-ssl.pem` / `pve-ssl.key`. `TLS_KEY_FILE` in
  `/etc/default/pveproxy` replaces the path of the custom key
  `[source: pve-manager pveproxy.pm init]`.
- It serves the whole file as chain (`AnyEvent::TLS` `cert_file` uses
  `CTX_use_certificate_chain_file`) `[source: AnyEvent 7.17
  lib/AnyEvent/TLS.pm]`; leaf + intermediate uploaded, leaf +
  intermediate presented; a leaf alone is presented alone `[observed PVE
  9.2.21, container]`.
- Without `restart`, the files are written and pveproxy keeps serving the
  old certificate until its next reload or restart `[source: pve-manager
  Certificates.pm, pveproxy.pm]` `[observed PVE 9.2.21, container]`.

### GET /api2/json/nodes/{node}/certificates/info

- Permission: `user => 'all'`, i.e. any authenticated user or token, no
  privilege needed; tokens allowed `[schema]` `[source: pve-access-control
  RPCEnvironment.pm check_api2_permissions]`. A token without any ACL gets
  200 `[observed PVE 9.2.21, container]`.
- Answer: `{"data":[...]}`, one object per file that can be read, in this
  order: `pve-root-ca.pem` (the cluster CA), `pve-ssl.pem` (the node
  certificate), `pveproxy-ssl.pem` (the custom one, if present). Each object
  has the fields of the upload answer, `pem` included `[source: pve-manager
  Certificates.pm info; pve-common Certificate.pm]` `[observed PVE 9.2.21,
  container]`. IPv6 SANs appear fully expanded
  (`0000:0000:...:0001`) `[observed PVE 9.2.21, container]`.
- The node does not report which file pveproxy currently serves. It serves
  `pveproxy-ssl.pem` if it and its key exist at its last (re)start
  `[source: pve-manager pveproxy.pm]`.
- Note: `pve-docs certificate-management.adoc` says "There is no API or web
  interface endpoint for downloading the file" (`pve-root-ca.pem`), but this
  endpoint returns its `pem` to any authenticated caller `[docs: pve-docs
  certificate-management.adoc]` `[source: pve-manager Certificates.pm]`
  `[observed PVE 9.2.21, container]`. Fetching it over a connection not yet
  verified proves nothing `[derived]`.
- `GET /api2/json/nodes` (any authenticated user) lists the node names of
  the cluster with `ssl_fingerprint` of each node (of `pveproxy-ssl.pem` if
  present, else `pve-ssl.pem`) `[source: pve-manager PVE/API2/Nodes.pm;
  pve-cluster src/PVE/Cluster.pm get_node_fingerprint]`.
- CLI on the node: `pvenode cert info` prints the same `[source: pve-manager
  PVE/CLI/pvenode.pm]`.

### DELETE /api2/json/nodes/{node}/certificates/custom

- Permission: `Sys.Modify` on `/nodes/{node}`; tokens allowed `[schema]`.
- Parameters: `node`, `restart` (boolean, default 0), in the query string
  `[schema]` `[source: pve-http-server AnyEvent.pm]`.
- Removes `pveproxy-ssl.pem` and `pveproxy-ssl.key`; a missing file is not
  an error. With `restart`, reloads pveproxy as for the upload. Answer
  `200`, `{"data":null}` `[source: pve-manager Certificates.pm]`. A DELETE
  without a custom certificate also answers 200 `[source: same]`
  `[observed PVE 9.2.21, container]` (33 ms without, ~1.4 s with
  `restart`).
- Afterwards pveproxy (after its reload, with the same alternation as
  above) serves `pve-ssl.pem`, signed by the cluster CA `[source:
  pve-manager pveproxy.pm]`: the **same** `pve-ssl.pem` as before the
  upload, same fingerprint, not regenerated `[observed PVE 9.2.21,
  container]`. Without `restart` nothing changes on 8006 until the next
  restart `[observed PVE 9.2.21, container]`.

### What a fresh PVE node presents

- `pve-ssl.pem`, made by `gen_pve_ssl_cert` (run by `pvecm updatecerts` in
  `ExecStartPre` of pveproxy) `[source: pve-cluster
  src/PVE/Cluster/Setup.pm; pve-manager services/pveproxy.service]`
  (observed as made by `pvecm updatecerts --force`, all points below
  `[observed PVE 9.2.21, container]`):
  - Subject: `OU=PVE Cluster Node, O=Proxmox Virtual Environment, CN=<fqdn>`.
  - SANs, in this order: `IP:127.0.0.1`, `IP:::1`, `DNS:localhost`,
    `IP:<node address>`, `DNS:<nodename>`, and `DNS:<nodename>.<search>`
    if `/etc/resolv.conf` has a `search` or `domain` line (its first word).
    `<fqdn>` is that last name, or the node name without one. `<node
    address>` is the node's cluster address (`remote_node_ip`); in the
    container, its address on the Docker network.
  - `basicConstraints=CA:FALSE`, `extendedKeyUsage=serverAuth`.
  - Key: RSA 2048. Lifetime: until 2 days before the CA expires, at most
    730 days; backdated one day (`faketime yesterday`).
  - Issuer: the cluster CA `/etc/pve/pve-root-ca.pem`, subject
    `CN=Proxmox Virtual Environment, OU=<random UUID>,
    O=PVE Cluster Manager CA`, RSA 4096, 3650 days (backdated one day),
    `keyUsage=critical,keyCertSign,cRLSign`; made once per cluster. It
    carries `basicConstraints=critical,CA:TRUE` `[observed PVE 9.2.21,
    container]`.
- `pveupdate` (daily) renews `pve-ssl.pem` when it expires within 14 days
  or has more than 2 years left, and reloads pveproxy `[source: pve-manager
  bin/pveupdate]`. A pin on the fingerprint of `pve-ssl.pem` breaks at that
  renewal; the cluster CA stays `[derived]`.
- pveproxy presents `pve-ssl.pem` alone; the CA is not in the file
  `[source: pve-cluster Setup.pm]` `[observed PVE 9.2.21, container]`.
  With `pve-root-ca.pem` as trust anchor the API verifies under the FQDN
  `[observed PVE 9.2.21, container]`.
- The admin finds the fingerprints in `pvenode cert info` and
  `GET /nodes/{node}/certificates/info` `[source: pve-manager pvenode.pm,
  Certificates.pm]`. The docs tell the admin to copy `pve-root-ca.pem` out
  of band (scp, SSH) `[docs: pve-docs certificate-management.adoc]`.
- Consequence for the trust of the first upload `[derived]`: a fresh node
  is verifiable with the cluster CA as trust anchor, but only under one of
  the names in the SANs above. A name SICK uses that is not among them
  (another DNS name, an address other than the cluster address) does not
  verify. How the target trusts the node: `docs/decisions/0001-trust-in-the-node.md`.

### Chains and keys (PVE)

- A chain of leaf plus intermediates is accepted; the first certificate is
  taken as the leaf (`CTX_use_certificate_chain_file`) `[source:
  pve-manager CertHelpers.pm]`. The key is checked against it only when
  both are of the same type (upload, step 3) `[observed PVE 9.2.21,
  container]`.
- The order is not checked. The file is served as uploaded `[source:
  pve-manager CertHelpers.pm, pveproxy.pm]`. **A wrongly ordered chain
  (intermediate first) with the leaf's key breaks pveproxy**: with an EC
  intermediate and an RSA key, the check passes, the upload answers 200
  with the intermediate's info, and after the restart pveproxy accepts TCP
  on 8006 but every TLS handshake fails (`unexpected eof while reading`).
  The API is then unreachable, so the node can only be repaired on the
  node itself (remove `pveproxy-ssl.*`, restart pveproxy) `[observed PVE
  9.2.21, container]`. The same is expected for any first certificate and
  key of different types `[derived]`. With intermediate and key of the
  same type the check would refuse it (step 3) `[derived]`.
- No key type is restricted in the code; whatever OpenSSL loads (RSA, EC)
  passes `[source: pve-manager CertHelpers.pm]` `[observed PVE 9.2.21,
  container]` (RSA 2048, EC P-256).
- The key "needs to be without password" `[docs: pve-docs
  certificate-management.adoc]`. The format check accepts an encrypted PEM
  block (any label) `[source: pve-common Certificate.pm]`; what the
  loading does with it is open.
- Traditional (`RSA PRIVATE KEY`, `EC PRIVATE KEY`) and PKCS#8
  (`PRIVATE KEY`) both pass the format check `[source: pve-common
  Certificate.pm]` and are served; the key is stored as uploaded
  `[observed PVE 9.2.21, container]`.

### TLS of pveproxy

- Default: TLS 1.2 and 1.3 (min version TLS 1.1 in code, but the default
  cipher list holds only TLS 1.2 ECDHE suites), server cipher order, no
  compression, no renegotiation `[source: pve-http-server AnyEvent.pm
  new]`.
- Overridable in `/etc/default/pveproxy`: `CIPHERS`, `CIPHERSUITES`,
  `HONOR_CIPHER_ORDER`, `DISABLE_TLS_1_2`, `DISABLE_TLS_1_3`, `DHPARAMS`,
  `TLS_KEY_FILE` `[source: pve-http-server src/PVE/APIServer/Utils.pm]`.
- One certificate per port, no selection by SNI; the `Host` header is not
  checked on HTTPS requests `[source: pve-http-server AnyEvent.pm]`. SNI
  and `Host` are therefore not required `[derived]`.

### Privileges and setup (PVE)

- `Sys.Modify` is in the privilege group `root`, which only the built-in
  role `Administrator` holds. No other built-in role (`PVEAdmin` included)
  has it `[source: pve-access-control AccessControl.pm $privgroups,
  create_roles]`. A custom role with only `Sys.Modify` is the smallest
  `[derived]`, and it suffices for the upload `[observed PVE 9.2.21,
  container]`.
- `Sys.Modify` on `/nodes/{node}` also allows, on that node: services
  start/stop/restart/reload, network configuration, DNS, hosts, time, APT
  update and repositories, firewall rules and options, subscription, ACME
  certificate order/renew/delete `[schema]`.
- Commands, syntax read in `pveum` and the API schema `[source:
  pve-access-control src/PVE/CLI/pveum.pm]` `[schema]` `[docs: pve-docs
  pveum.adoc]`, run as written (with `--output-format json` on `token
  add`; no output otherwise) `[observed PVE 9.2.21, container]`:

  ```
  pveum user add sick@pve --comment 'SICK certificate upload'
  pveum role add SICKCertificate --privs Sys.Modify
  pveum user token add sick@pve sick --privsep 1 --expire <epoch> --comment 'SICK'
  pveum acl modify /nodes/pve1 --roles SICKCertificate --users sick@pve
  pveum acl modify /nodes/pve1 --roles SICKCertificate --tokens 'sick@pve!sick'
  ```

  `acl modify` takes `--roles` (required), `--users`, `--tokens`,
  `--groups`, `--propagate` `[schema]`. The manual writes the abbreviated
  `-user`, `-role`, `-token` (Getopt prefixes) `[docs: pve-docs
  pveum.adoc]`. `token add` prints the secret once (`value`) `[schema]`
  `[observed PVE 9.2.21, container]`. Both ACL lines are needed with
  `--privsep 1` (intersection, above) `[observed PVE 9.2.21, container]`.

---

## Proxmox Backup Server (proxmox-backup-proxy, port 8007)

### Request path and transport

- The API listens on TCP 8007 with TLS, served by `proxmox-backup-proxy`.
  `protected` calls are forwarded to `proxmox-backup-api` on the same host,
  which runs as root `[source: proxmox proxmox-rest-server src/rest.rs
  proxy_protected_request; proxmox-backup src/api2/node/certificates.rs]`
  `[observed PBS 4.2.8]` (port and daemons).
- Request bodies: `application/x-www-form-urlencoded` or
  `application/json` (parameters after `;` ignored); without content type,
  the body is parsed as form data; any other content type is a 400
  (`unsupported content type`) `[source: proxmox-rest-server rest.rs
  get_request_parameters]`. JSON and form bodies both work for the upload
  `[observed PBS 4.2.8]`.
- With a JSON body, the query string is **not** read; with a form body,
  query and body are merged `[source: same]`.
- Body limit 512 KiB (`Request body too large`, 400) `[source: same]`.
- A plain-HTTP request on port 8007 is answered with `301`/`308` to
  `https://` `[source: proxmox-rest-server rest.rs RedirectService]`; the
  request has crossed the network in the clear by then `[derived]`.

### Booleans

- Form body or query: `1|on|yes|true` and `0|off|no|false`, any case
  `[source: proxmox proxmox-schema src/schema.rs parse_boolean]`; form
  `force=1 restart=1` accepted `[observed PBS 4.2.8]`.
- JSON body: only JSON `true`/`false`; a string `"1"` fails with
  "Expected boolean value." `[source: proxmox-schema schema.rs
  BooleanSchema::verify_json]`. The string `"1"` **and the number `1`**
  both fail: `400 Bad Request`, body `parameter verification failed:` and
  one line `- '<param>': Expected boolean value.` per parameter; nothing
  changed `[observed PBS 4.2.8]`.

### The token

- Header: `Authorization: PBSAPIToken=sick@pbs!sick:<secret>`
  `[source: proxmox-backup src/auth.rs auth_token_prefix; proxmox
  proxmox-auth-api src/api/mod.rs extract_auth_data, http_check_auth]`
  `[docs: proxmox-backup docs/user-management.rst]` `[observed PBS 4.2.8]`.
- After `PBSAPIToken` one `=` or one space; the rest is split at the
  **first** `:` into token id and secret; the secret is percent-decoded
  `[source: proxmox-auth-api api/mod.rs]`.
- Token name: `[A-Za-z0-9_][A-Za-z0-9._\-]*` `[schema]`.
- A ticket cookie (`__Host-PBSAuthCookie` or `PBSAuthCookie`) takes
  precedence over the token `[source: proxmox-auth-api api/mod.rs]`.
- No CSRF token is needed with a token; the CSRF check is in the ticket
  branch only `[source: proxmox-auth-api api/mod.rs http_check_auth]`
  `[observed PBS 4.2.8]` (uploads with the token header only).
- The token must be active (enabled, not expired) and its secret correct
  `[source: same]`. An expired token was not tried.
- Tokens are always privilege-separated: they need ACL entries of their
  own, and the result is intersected with the user's `[docs: proxmox-backup
  docs/user-management.rst]`. With the ACL on the token alone: 403; on
  token and user: accepted `[observed PBS 4.2.8]`.

### Error answers common to all calls

- Authentication failed (also: no header): status `401`, body the plain
  text `authentication failed` (no content type), sent 3 seconds after the
  request started `[source: proxmox-rest-server rest.rs authorize_request,
  ApiService::call]`. Wrong secret: `HTTP/1.1 401 Unauthorized`, body
  `authentication failed`, ~3 s, plus a `set-cookie` clearing
  `__Host-PBSAuthCookie` `[observed PBS 4.2.8]`. A missing header was not
  tried.
- Missing privilege: status `403`, body the plain text
  `permission check failed` with content type `application/json`, sent
  0.5 seconds after the request started `[source: proxmox-rest-server
  rest.rs authorize_request; src/formatter.rs error_to_response]`.
  Observed: `HTTP/1.1 403 Forbidden`, body `permission check failed`
  (plain text, 23 bytes), content type `application/json;charset=UTF-8`
  `[observed PBS 4.2.8]`; the delay was not measured.
- Unknown path: `404`, body `Path '<path>' not found.`; only after a
  successful authentication `[source: proxmox-rest-server rest.rs]`.
- Parameter verification failed: `400`, body the plain text
  `parameter verification failed - '<param>': <reason>` (several:
  `parameter verification failed:` and one line per parameter)
  `[source: proxmox-schema schema.rs ParameterError; proxmox-rest-server
  formatter.rs]` `[observed PBS 4.2.8]` (the several-parameter form).
- Any other error of the handler: `400`, body the plain text of the error
  `[source: proxmox-rest-server formatter.rs error_to_response]`.
- Errors are not JSON on the `json` endpoint, although the content type
  says `application/json` `[source: same]` `[observed PBS 4.2.8]`. The
  reason phrase is the standard one of the status (`Unauthorized`,
  `Forbidden`, `Bad Request`) `[observed PBS 4.2.8]`.

### POST /api2/json/nodes/{node}/certificates/custom (upload)

- Permission: `Sys.Modify` on `/system/certificates` (not partial)
  `[schema]` `[source: proxmox-backup src/api2/node/certificates.rs]`
  `[observed PBS 4.2.8]` (role `Admin` there).
- `{node}`: any string of hostname format, schema text "Node name (or
  'localhost')"; the handler does not look at it `[schema]` `[source:
  proxmox-backup certificates.rs; src/api2/node/mod.rs]`. `localhost`, the
  host name and an unrelated name answer the same (tried on `info`)
  `[observed PBS 4.2.8]`. `localhost` is what the GUI uses `[source:
  proxmox-backup www/MainView.js]`.
- Parameters `[schema]` `[source: proxmox-backup certificates.rs]`:
  - `certificates` (string, required): parsed with
    `X509::stack_from_pem`, re-encoded, joined with newlines.
  - `key` (string, optional): parsed with `PKey::private_key_from_pem`,
    stored as PKCS#8. Without `key`, the existing `proxy.key` is used.
    A traditional RSA key is stored as `BEGIN PRIVATE KEY` (PKCS#8)
    `[observed PBS 4.2.8]`.
  - `restart` (boolean): "UI compatibility parameter, ignored".
  - `force` (boolean): declared, but the handler does not take it: it is
    ignored. An existing custom certificate is always replaced
    `[observed PBS 4.2.8]` (`force` absent and `false` both replace).
  - `node` (from the path).
- What it does `[source: proxmox-backup certificates.rs,
  src/config/mod.rs set_proxy_certificate, src/server/mod.rs
  reload_proxy_certificate]`:
  1. Writes `/etc/proxmox-backup/proxy.key`, then `proxy.pem`
     (root:backup 0640; `proxy.pem` = the chain as sent)
     `[observed PBS 4.2.8]`.
  2. Sends `reload-certificate` to the command socket of
     `proxmox-backup-proxy` and waits for its answer.
  3. The proxy builds a new TLS acceptor from the two files and swaps it
     in. **If that fails (key not matching the certificate, unreadable
     file), the proxy only logs `error reloading certificate` and keeps the
     old acceptor; the command still answers success**
     `[source: proxmox-backup src/bin/proxmox-backup-proxy.rs]`
     `[observed PBS 4.2.8]` (log: `error reloading certificate: private
     key does not match certificate`).
  4. Answers with `get_info()` of the new `proxy.pem`.
- **PBS does not refuse a key that does not match the certificate, nor a
  wrongly ordered chain.** Both upload answers are `200` with the info of
  the new file (for the wrong order: of the intermediate, `san` empty);
  both files are written; the proxy keeps serving the old certificate from
  memory; the next start of the proxy fails (`Error: private key does not
  match certificate`) and 8007 stays closed (connection refused) until the
  files are repaired on the node (`proxmox-backup-manager cert update
  --force`) or by a DELETE sent while the old proxy still runs
  `[observed PBS 4.2.8]`. This confirms what was derived from the source
  (`make_tls_acceptor()?` at start). Our client checks the pair and the
  order before the upload and checks the presented certificate after it
  `[derived]`.
- No check of the chain order, of the key type, or that `certificates`
  holds at least one certificate is in the handler `[source: proxmox-backup
  certificates.rs]`. What an empty `certificates` does is open.
- Success: `200`, `{"data":[{...}]}`, an **array** with one object
  `[schema]` `[source: proxmox-backup certificates.rs get_info]`
  `[observed PBS 4.2.8]`:
  `filename` (`proxy.pem`), `subject`, `issuer` (form `CN = ...`), `san`
  (DNS names only; IP SANs are left out), `notbefore`, `notafter`, `pem`
  (the whole `proxy.pem`, chain included), `public-key-type` (OpenSSL long
  name, e.g. `rsaEncryption`, `id-ecPublicKey`), `public-key-bits`,
  `fingerprint`. The other fields describe the first certificate of the
  file `[observed PBS 4.2.8]`. That `pem` holds the whole chain is
  `[source]` only: the trial's redaction cannot tell one PEM block from two.
- `fingerprint`: SHA-256 of the first certificate, **lower-case** hex pairs
  separated by `:` `[source: proxmox-backup pbs-tools/src/cert.rs
  fingerprint]` `[observed PBS 4.2.8]`.
- The call is synchronous, no task `[source: proxmox-backup
  certificates.rs]` `[observed PBS 4.2.8]` (~50 ms).
- Key formats: RSA and EC P-256 keys, traditional (`RSA PRIVATE KEY`,
  SEC1 `EC PRIVATE KEY`) and PKCS#8, are accepted and served
  `[observed PBS 4.2.8]`.

### Restart (PBS)

- No restart. The reload happens within the call, before the answer
  (above). New connections get the new certificate once the call has
  answered; an open keep-alive connection keeps the old one `[source:
  proxmox-backup proxmox-backup-proxy.rs]` `[derived]`. Observed: the
  proxy keeps its PID and logs `reloading certificate`; the very next TLS
  connection after the answer presented the new leaf, in each of six
  uploads checked that way (a parallel poll saw it 155 ms after the start
  of a 52 ms call) `[observed PBS 4.2.8]`.
- `restart` is ignored `[source: proxmox-backup certificates.rs]`. It was
  always sent as `true` or left out, with no visible effect
  `[observed PBS 4.2.8]`; `restart: false` was not tried.

### GET /api2/json/nodes/{node}/certificates/info

- Permission: `Sys.Modify` on `/system/certificates`, the same as the
  upload `[schema]` `[source: proxmox-backup certificates.rs]`. Without an
  ACL, and with the ACL on the token alone: 403 `[observed PBS 4.2.8]`.
- Answer: as the upload answer, one object for `proxy.pem`
  `[source: same]` `[observed PBS 4.2.8]`. It shows the file, not what the
  proxy serves (they differ after a failed reload, above) `[derived]`.
- `GET /api2/json/nodes/localhost/status` returns `info.fingerprint` of
  `proxy.pem` with `Sys.Audit` on `/system/status` `[schema]`
  `[source: proxmox-backup src/api2/node/status.rs]`.

### DELETE /api2/json/nodes/{node}/certificates/custom

- Permission: `Sys.Modify` on `/system/certificates` `[schema]`.
- Parameters: `node`, `restart` (ignored), in the query string `[schema]`.
- Removes `proxy.pem` (error if that fails) and `proxy.key` (only logged),
  generates a **new** self-signed certificate with a new key, reloads the
  proxy; answer `{"data":null}` `[source: proxmox-backup certificates.rs]`.
  Observed: `200 {"data":null}` after ~1.1 s (the key is generated within
  the call); 8007 then presents a new self-signed certificate (new OU
  UUID, new RSA 4096 key, new fingerprint, again 1000 years), not the one
  from before the upload `[observed PBS 4.2.8]`.
- There is no notion of "custom" on PBS: a DELETE on a node that still has
  its self-signed certificate replaces it with a new one, with a new
  fingerprint; it does not answer an error `[source: same]`.

### What a fresh PBS presents

- `proxy.pem`, made by `update_self_signed_cert` when `proxmox-backup-api`
  starts and the files are missing `[source: proxmox-backup
  src/config/mod.rs; src/bin/proxmox-backup-api.rs]` (all points below
  `[observed PBS 4.2.8]` as well):
  - Self-signed (issuer = subject); serial 00.
  - Subject: `O=Proxmox Backup Server, OU=<random UUID, upper-case hex>,
    CN=<fqdn>`.
  - SANs: `IP:127.0.0.1`, `IP:::1`, `DNS:localhost`, `DNS:<nodename>`
    (unless it is `localhost`), `DNS:<nodename>.<search>` if
    `/etc/resolv.conf` has a `search`/`domain` line (first word). **No IP
    address of the host.**
  - **The CN and the last SAN take whatever search domain the host has**:
    in a container without its own `--dns-search`, the search domain of the
    machine running it ended up in CN and SAN. The host name and the
    resolver's search domain at first start decide which name the
    certificate is valid for `[observed PBS 4.2.8]`.
  - `basicConstraints` CA false, `extendedKeyUsage=serverAuth`, subject and
    authority key identifiers (the key identifiers were not checked in the
    trial).
  - Key: RSA 4096. Lifetime: 365000 days, about 1000 years (notBefore =
    now).
  - It is presented alone (one certificate) `[observed PBS 4.2.8]`.
- The admin sees its SHA-256 fingerprint in `proxmox-backup-manager cert
  info` (line `Fingerprint (sha256): ...`, lower-case) and in the GUI:
  Dashboard, "Show Fingerprint" `[source: proxmox-backup
  src/bin/proxmox_backup_manager/cert.rs, www/panel/NodeInfo.js]` `[docs:
  proxmox-backup docs/managing-remotes.rst]` (`cert info`:
  `[observed PBS 4.2.8]`).
- Consequence for the trust of the first upload `[derived]`: there is no CA
  to anchor on; what the admin can hand over out of band is the fingerprint
  (or the file). The certificate names the host only by DNS names; pinned
  as trust anchor it verifies under such a name `[observed PBS 4.2.8]`. How
  the target trusts the node: `docs/decisions/0001-trust-in-the-node.md`.

### Chains and keys (PBS)

- A chain is accepted; it is served with `set_certificate_chain_file`, the
  first certificate as leaf `[source: proxmox proxmox-rest-server
  src/connection.rs TlsAcceptorBuilder::build]`. Leaf + intermediate
  uploaded, leaf + intermediate presented; a leaf alone is presented alone
  `[observed PBS 4.2.8]`.
- The order is not checked; certificates are re-encoded in the order given
  `[source: proxmox-backup certificates.rs]`. A wrongly ordered chain is
  written and answered 200 (upload, above) `[observed PBS 4.2.8]`.
- Key types: whatever `PKey::private_key_from_pem` reads (RSA, EC, ...);
  traditional and PKCS#8 are both read; stored as PKCS#8 `[source: same]`
  `[observed PBS 4.2.8]` (RSA 2048, EC P-256).
- The key "must not be password protected" `[docs: proxmox-backup
  docs/certificate-management.rst]`.

### TLS of proxmox-backup-proxy

- `SslAcceptor::mozilla_intermediate_v5` (TLS 1.2 and 1.3, Mozilla
  intermediate ciphers), no renegotiation; ciphers overridable in the node
  config (`ciphers-tls-1.2`, `ciphers-tls-1.3`) `[source: proxmox-rest-server
  connection.rs; proxmox-backup proxmox-backup-proxy.rs make_tls_acceptor]`.
  An OpenSSL 3.5 client negotiated TLS 1.3, `TLS_AES_256_GCM_SHA384`
  `[observed PBS 4.2.8]`.
- One certificate, no SNI callback; the `Host` header is used only for the
  plain-HTTP redirect `[source: proxmox-rest-server connection.rs,
  rest.rs]`. SNI and `Host` are not required `[derived]`.

### Privileges and setup (PBS)

- The roles of PBS are fixed. `Sys.Modify` is held by `Admin` only (all
  bits); no other role contains `PRIV_SYS_MODIFY` `[source: proxmox
  pbs-api-types src/acl.rs]`. There are no custom roles `[source: same,
  enum Role]`.
- `Admin` on `/system/certificates` also allows everything else checked on
  that path: ACME accounts and plugins (read, create, change, delete),
  including the plugin `data` (DNS API credentials), and ordering or
  renewing an ACME certificate `[schema]`.
- `/system/certificates` is a valid ACL path `[source: proxmox-backup
  pbs-config/src/acl.rs]` `[observed PBS 4.2.8]`.
- Commands, syntax read in the CLI source and the manual `[source:
  proxmox-backup src/bin/proxmox_backup_manager/user.rs, acl.rs]` `[docs:
  proxmox-backup docs/user-management.rst]` `[schema]`, run as written
  (exit 0; `generate-token` was run without `--expire` and `--comment`)
  `[observed PBS 4.2.8]`:

  ```
  proxmox-backup-manager user create sick@pbs --comment 'SICK certificate upload'
  proxmox-backup-manager user generate-token sick@pbs sick --expire <epoch> --comment 'SICK'
  proxmox-backup-manager acl update /system/certificates Admin --auth-id sick@pbs
  proxmox-backup-manager acl update /system/certificates Admin --auth-id 'sick@pbs!sick'
  ```

  `generate-token` prints `tokenid` and `value` (the secret) once
  `[docs: proxmox-backup docs/user-management.rst]` `[observed PBS 4.2.8]`.

---

## What the device types rely on

The behaviours the code of this distribution depends on, each with the
entry it rests on:

1. **Header formats**: PVE `PVEAPIToken=<user@realm!id>=<secret>`, PBS
   `PBSAPIToken=<user@realm!id>:<secret>` (both "The token") `[source]`
   `[observed PVE 9.2.21, container]` `[observed PBS 4.2.8]`.
2. **Upload path and fields**: `POST
   /api2/json/nodes/{node}/certificates/custom` with `certificates` (the
   chain, leaf first) and `key`; PVE on 8006 with the real node name, PBS
   on 8007 with `localhost` (both "upload") `[schema]` `[observed ...]`.
3. **PVE needs `force=true` and `restart=true`**: without `force` an
   existing custom certificate is a 500; without `restart` the files are
   written but not served. JSON `true` is accepted (PVE "Booleans",
   "upload" step 1, "Restart (PVE)") `[observed PVE 9.2.21, container]`.
4. **PBS gets neither `force` nor `restart`**: both are ignored, and only
   JSON booleans would pass in a JSON body (PBS "Booleans", "upload")
   `[observed PBS 4.2.8]`.
5. **Success answers**: PVE `data` is one object, PBS `data` an array of
   one; both describe the first certificate; the fingerprint is SHA-256 in
   colon-separated hex, upper case on PVE, lower case on PBS, so it is
   compared case-insensitively (both "upload") `[observed ...]`.
6. **Neither product reliably refuses a wrong key or a wrong chain
   order**: PBS writes both and answers 200; PVE refuses a mismatched key
   of the same type but writes a key of another type and a wrongly ordered
   chain, and pveproxy then fails every handshake ("Chains and keys", both
   products) `[observed ...]`. So the client checks before the request
   that the key belongs to the first certificate and that the first
   certificate is the leaf `[derived]`.
7. **A 200 does not mean the certificate is served**: PBS keeps the old
   one after a failed reload; PVE swaps it only after the restart, seconds
   after the answer. So what the port presents decides `[derived]`. PBS
   presents the new leaf on the next connection ("Restart (PBS)"). PVE
   needs a few seconds: first sighting 1.3-1.6 s, alternation with the old
   certificate until ~6 s ("Restart (PVE)") `[observed PVE 9.2.21,
   container]`. A single sighting of the new leaf proves that the new
   pveproxy master serves it, since only the re-executed master loads the
   new files; the old workers drain within ~6 s `[derived]` from the same
   entry.
8. **PVE answers 500 when the restart fails although the files are
   written** ("Restart (PVE)") `[observed PVE 9.2.21, container]`: such a
   500 is not "nothing happened".

---

## Where the earlier session disagrees

The earlier session (`../sick`: `docs/findings/device-proxmox.md`,
`contrib/devices/proxmox/README.md`, `t/e2e/proxmox-standin.py`) read the
schemas and some sources. Checked against the sources and the trial above:

1. **PBS does not check that the key matches the certificate.** The stand-in
   answers 500 for a mismatched key on PBS. The real handler writes the
   files, the proxy refuses them only in its log, the API answers 200, and
   the proxy keeps the old certificate until its next start, which then
   fails `[source: proxmox-backup certificates.rs,
   proxmox-backup-proxy.rs]` `[observed PBS 4.2.8]`. The same holds for a
   wrongly ordered chain `[observed PBS 4.2.8]`.
2. **PVE's default certificate is not self-signed.** The stand-in serves a
   self-signed certificate "like PVE's own node certificate". The real
   `pve-ssl.pem` is signed by the cluster CA and carries the cluster address
   as IP SAN `[source: pve-cluster Setup.pm]` `[observed PVE 9.2.21,
   container]`.
3. **PVE restart mechanism.** The findings say pveproxy "restarts in the
   background after the answer". The upload itself runs `systemctl
   reload-or-restart pveproxy` before answering, which sends SIGHUP; the
   master re-executes `[source: pve-manager Certificates.pm; pve-common
   Daemon.pm]`. If that command fails the answer is a 500 with the files
   written. Old and new certificate then alternate on new connections for
   ~4-6 s; the stand-in switches once, 2 s after the answer `[observed PVE
   9.2.21, container]`.
4. **DELETE without a custom certificate.** The stand-in answers 500 ("no
   custom certificate") on both. PVE answers 200 (missing files are
   ignored) `[observed PVE 9.2.21, container]`; PBS answers 200 and
   replaces its self-signed certificate with a new one `[source:
   pve-manager Certificates.pm; proxmox-backup certificates.rs]`.
5. **PBS ignores `force` as well as `restart`.** The findings mention only
   `restart` as ignored `[source: proxmox-backup certificates.rs]`
   `[observed PBS 4.2.8]`.
6. **401 answers.** The stand-in sends reason `authentication failure` with
   an empty body, at once. PVE: `401 Authentication failed!` (or
   `401 No ticket` without credentials), empty body, after 3 seconds. PBS:
   `401 Unauthorized` with the plain-text body `authentication failed`,
   after 3 seconds `[source: pve-manager HTTPServer.pm; proxmox-rest-server
   rest.rs]` `[observed PVE 9.2.21, container]` `[observed PBS 4.2.8]`
   (wrong secret; `No ticket` not tried).
7. **Error bodies on PBS are plain text, not JSON**, also for 400
   parameter errors; the stand-in sends JSON with `errors` on 400
   `[source: proxmox-rest-server formatter.rs]` `[observed PBS 4.2.8]`.
8. **Success answers.** The stand-in returns only `filename` and
   `fingerprint`, upper case for both. The real answers carry all fields of
   the certificate info (PVE an object, PBS an array of one); PVE's
   fingerprint is upper case, PBS's lower case `[source: pve-common
   Certificate.pm; proxmox-backup pbs-tools cert.rs]` `[observed PVE
   9.2.21, container]` `[observed PBS 4.2.8]`.
9. **PVE existing-certificate message.** The stand-in says
   `Custom certificate exists but 'force' is not set.`; the real text is
   `Custom certificate file exists but force flag is not set.` (status 500
   in both) `[source: pve-manager CertHelpers.pm]` `[observed PVE 9.2.21,
   container]`.
10. **Booleans.** The findings leave open whether pveproxy takes `"1"` in a
    JSON body: it does, as well as `1` and `true`. PBS does not accept
    `"1"` or `1` in a JSON body (only `true`) `[source: pve-common
    JSONSchema.pm; proxmox-schema schema.rs]` `[observed PVE 9.2.21,
    container]` `[observed PBS 4.2.8]`. The stand-in's split (PVE strings,
    PBS JSON booleans) matches.
11. **Scope of `Admin` on `/system/certificates` (PBS).** The README says it
    "covers the certificate and the ACME settings of the host, nothing
    else". Correct, but the ACME settings include reading the DNS plugin
    credentials `[schema]`.
12. **PVE key check.** Neither the findings nor the stand-in know that PVE
    misses a key of another type than the first certificate, which with a
    wrongly ordered chain leaves pveproxy failing every handshake
    `[observed PVE 9.2.21, container]`.
13. Confirmed as the earlier session read them: the paths; `Sys.Modify` on
    `/nodes/{node}` (PVE) and on `/system/certificates` (PBS); tokens
    allowed on PVE; `Admin` the only PBS role with `Sys.Modify`; the token
    header formats; PVE writes `pveproxy-ssl.pem`/`.key`, PBS
    `proxy.pem`/`.key`; PBS reloads within the call; `restart` ignored on
    PBS; PVE falls back to `pve-ssl.pem` after DELETE; the `pveum` and
    `proxmox-backup-manager` command syntax, with the ACL on user and token
    `[observed PVE 9.2.21, container]` `[observed PBS 4.2.8]`.

---

## Open: not known yet

To be observed on a real node, with its version, before code relies on it.
On a node under systemd and in a cluster: at HQ (`docs/hq-checklist.md`).

PVE

- The time from the upload answer (`restart=1`) to the new certificate,
  and the alternation, under systemd (only observed with the shim);
  whether any request fails during the re-exec.
- An encrypted key (with a passphrase): what the loading in pvedaemon does
  without a password callback (expected: an error, not a hang).
- A chain that includes the root.
- `localhost` as path node.
- The SANs of `pve-ssl.pem` on a node without `search` in
  `/etc/resolv.conf`.
- `TLS_KEY_FILE` set in `/etc/default/pveproxy`: the uploaded key is then
  not the one served.
- Clusters: upload through one node for another (`proxyto`).
- `401 No ticket` (no header); an expired token.
- The TLS versions and cipher suites a fresh node negotiates.

PBS

- `certificates` without any certificate: what is written, what answers.
- An encrypted key (with a passphrase); a chain that includes the root.
- `restart: false`: whether it suppresses the reload.
- An expired token; a missing header; the delay of the 403.
- DELETE on a host that has only its self-signed certificate (observed
  only after an upload).

Both

- IPv6 connections to the node.
- A node reached over a real network under a name SICK uses (the trial
  used a container network alias).

---

## Sources read

All read on 2026-10-11, as shallow clones of `https://git.proxmox.com/git/<repo>.git`
(HEAD of the default branch) unless stated otherwise.

| Repository / source | Files | Commit | Version (debian/changelog) | Commit date |
|---|---|---|---|---|
| pve-manager | `PVE/API2/Certificates.pm`, `PVE/CertHelpers.pm`, `PVE/HTTPServer.pm`, `PVE/Service/pveproxy.pm`, `PVE/API2/Nodes.pm`, `PVE/CLI/pvenode.pm`, `PVE/API2Tools.pm`, `services/pveproxy.service`, `bin/pveupdate` | `76177f3d466d` | 9.2.21 | 2026-10-09 |
| pve-common | `src/PVE/Certificate.pm`, `src/PVE/JSONSchema.pm`, `src/PVE/RESTHandler.pm`, `src/PVE/Daemon.pm`, `src/PVE/Exception.pm`, `src/PVE/INotify.pm` | `defd246f31f3` | 9.2.3 | 2026-10-03 |
| pve-cluster | `src/PVE/Cluster/Setup.pm`, `src/PVE/Cluster.pm` | `7091d92e5949` | 9.1.6 | 2026-05-24 |
| pve-http-server | `src/PVE/APIServer/AnyEvent.pm`, `Formatter.pm`, `Formatter/Standard.pm`, `Utils.pm` | `5c9e4ea77336` | 6.0.5 | 2026-01-14 |
| pve-access-control | `src/PVE/AccessControl.pm`, `src/PVE/RPCEnvironment.pm`, `src/PVE/Auth/Plugin.pm`, `src/PVE/CLI/pveum.pm` | `dff26b458651` | 9.1.2 | 2026-09-17 |
| pve-docs | `certificate-management.adoc`, `pveum.adoc` | `b423460d22af` | 9.2.13 | 2026-09-24 |
| proxmox-backup | `src/api2/node/certificates.rs`, `src/api2/node/mod.rs`, `src/api2/node/status.rs`, `src/config/mod.rs`, `src/server/mod.rs`, `src/bin/proxmox-backup-proxy.rs`, `src/bin/proxmox-backup-api.rs`, `src/bin/proxmox_backup_manager/{cert,user,acl}.rs`, `src/auth.rs`, `pbs-tools/src/cert.rs`, `pbs-config/src/acl.rs`, `www/MainView.js`, `www/panel/NodeInfo.js`, `docs/{certificate-management,user-management,managing-remotes}.rst` | `78f77d53718b` | 4.2.8 | 2026-10-02 |
| proxmox (Rust workspace) | `proxmox-rest-server/src/{rest,formatter,connection}.rs` (1.1.1), `proxmox-auth-api/src/api/mod.rs` (1.0.5), `proxmox-schema/src/{schema,api_types}.rs` (5.4.0), `pbs-api-types/src/acl.rs` (1.0.20) | `10a8526d88f3` | per crate, in parentheses; proxmox-backup 4.2.8 requires rest-server 1.1.1, auth-api 1.0.5, pbs-api-types 1.0.20, schema 5 | 2026-10-07 |
| PVE API schema | `https://pve.proxmox.com/pve-docs/api-viewer/apidoc.js` | sha256 `68a8ac7b4994525a1df5530e2d96f4fc76b6401f07861ac8a51635a0b9ce7c53` | Last-Modified 2026-09-24 | - |
| PBS API schema | `https://pbs.proxmox.com/docs/api-viewer/apidoc.js` | sha256 `b404de40c61752e5019b6f12e900105833851d9ef7c640ca7365e2e79d355a37` | Last-Modified 2026-10-02 (PBS 4.2.8) | - |
| AnyEvent (CPAN) | `lib/AnyEvent/TLS.pm` | metacpan source MLEHMANN/AnyEvent-7.17 | 7.17; the Debian package version on a node was not checked | - |
| Net::SSLeay (CPAN) | `SSLeay.xs` (`X509_get_fingerprint`), `lib/Net/SSLeay.pm` (`die_now`) | metacpan source CHRISN/Net-SSLeay-1.94 | 1.94; the Debian package version on a node was not checked | - |

The proxmox workspace is read at HEAD; whether HEAD of
`proxmox-rest-server` equals the published 1.1.1 was not checked (shallow
clone). The PVE schema hash equals the one the earlier session gives
(`68a8ac7b...9ce7c53`); for the PBS schema the earlier session gives no
hash.

The observations (`[observed ...]`) are from the packages listed in
`docs/real-node-trial.md`, "Versions": proxmox-backup-server 4.2.8-1;
pve-manager 9.2.21 with pve-cluster 9.1.6, libpve-access-control 9.1.2,
libpve-common-perl 9.2.3, libpve-http-server-perl 6.0.5,
libnet-ssleay-perl 1.94-3 - the same versions as the sources read.
