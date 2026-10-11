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
| `[observed PVE x.y]` / `[observed PBS x.y]` | observed on a real node, with its version. None yet. |
| `[derived]` | our conclusion from the statements it names; not read anywhere as such |

Everything here was read on 2026-10-11. Nothing was run against a real PVE
or PBS. Nothing from the cloned sources was executed.

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
  `[source: pve-manager PVE/Service/pveproxy.pm]`.
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
  `[source: pve-http-server src/PVE/APIServer/AnyEvent.pm]`.
- Query string parameters are merged into the body parameters and win over
  them `[source: pve-http-server AnyEvent.pm extract_params]`.
- A body on a method other than POST and PUT is answered with
  `501 Unexpected content for method 'DELETE'`. Parameters of a DELETE go
  into the query string `[source: pve-http-server AnyEvent.pm]`.
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
- With a JSON body pveproxy forwards JSON to pvedaemon, so a JSON boolean
  stays a JSON boolean `[source: pve-http-server AnyEvent.pm proxy_request]`.
- The earlier session did not try `"1"` (string) in a JSON body on a real
  pveproxy. The source accepts it `[source: pve-common JSONSchema.pm]`.

### The token

- Header: `Authorization: PVEAPIToken=sick@pve!sick=<secret>`
  `[source: pve-http-server AnyEvent.pm, Formatter.pm extract_auth_value;
  pve-access-control src/PVE/AccessControl.pm verify_token]`.
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
  `[source: pve-manager PVE/HTTPServer.pm auth_handler]`.
- The token is checked for: user enabled, token existing, token not expired
  (`expire` in epoch seconds, 0 = never), secret correct
  `[source: pve-access-control AccessControl.pm verify_token]`.
- An endpoint without `allowtoken` refuses tokens with 403. The upload,
  the delete and info have `allowtoken: 1` `[schema]`
  `[source: pve-manager PVE/HTTPServer.pm]`.
- Privilege separation (`privsep`, default 1): the token's privileges are
  the intersection of its own ACL and its user's. With `privsep 0` the token
  has its user's privileges `[schema]`
  `[source: pve-access-control src/PVE/RPCEnvironment.pm]`.

### Error answers common to all calls

- Authentication failed (wrong secret, unknown or expired token, malformed
  header): status `401`, reason phrase `Authentication failed!`, empty
  body, sent after a delay of 3 seconds
  `[source: pve-manager PVE/HTTPServer.pm auth_handler; pve-http-server
  AnyEvent.pm]`.
- No `Authorization` header and no cookie: `401 No ticket`, empty body,
  3 seconds delay `[source: same]`.
- Missing privilege: status `403`, reason phrase
  `Permission check failed (/nodes/pve1, Sys.Modify)`, body
  `{"data":null,"message":"Permission check failed (/nodes/pve1, Sys.Modify)\n"}`
  `[source: pve-access-control RPCEnvironment.pm check; pve-common
  src/PVE/Exception.pm raise_perm_exc; pve-http-server
  src/PVE/APIServer/Formatter/Standard.pm]`.
- Parameter verification failed: `400 Parameter verification failed.`,
  body `{"data":null,"errors":{"<param>":"<reason>"},"message":"Parameter verification failed.\n"}`
  `[source: pve-common JSONSchema.pm validate; Formatter/Standard.pm]`.
- Any other error in the handler (`die`): status `500`, reason phrase = the
  first line of the message, body `{"data":null,"message":"<message>"}`
  `[source: pve-manager PVE/HTTPServer.pm rest_handler; pve-http-server
  AnyEvent.pm response]`.
- Every error message reaches the HTTP reason phrase (first line only)
  `[source: pve-http-server AnyEvent.pm response]`. Our code quotes neither
  the reason phrase nor the body without checking they cannot hold the
  request `[derived]`.

### POST /api2/json/nodes/{node}/certificates/custom (upload)

- Permission: `Sys.Modify` on `/nodes/{node}` `[schema]`
  `[source: pve-manager PVE/API2/Certificates.pm]`.
- `{node}`: the PVE node name, format `pve-node`
  (`^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?$`) `[schema]`
  `[source: pve-common JSONSchema.pm]`.
- `localhost` passes the format, but the files are written to
  `/etc/pve/nodes/<node>/`, so `localhost` would write to
  `/etc/pve/nodes/localhost/` `[source: pve-manager PVE/CertHelpers.pm
  cert_path_prefix]`. The real node name is required `[derived]`.
- Parameters `[schema]`:
  - `certificates` (string, required, format `pem-certificate-chain`):
    one or more `-----BEGIN CERTIFICATE-----` blocks separated by newlines.
    Text before the first block is stripped; text after the last block
    fails validation `[source: pve-common src/PVE/Certificate.pm check_pem]`.
  - `key` (string, optional, format `pem-string`): exactly one PEM block,
    any label `[source: pve-common Certificate.pm]`. Without `key`, the
    existing `pveproxy-ssl.key` is used; if there is none, 400 with
    `errors.key` "Attempted to upload custom certificate without
    (existing) key." `[source: pve-manager Certificates.pm]`.
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
     (or `... key file exists ...`).
  2. Copies the existing files to `.old`, writes
     `/etc/pve/nodes/<node>/pveproxy-ssl.pem` and `pveproxy-ssl.key`
     (the cluster file system; `/etc/pve/local` is a symlink to the
     node's own directory).
  3. Loads both into an OpenSSL context
     (`CTX_use_certificate_chain_file`, then `CTX_use_PrivateKey_file`).
     A key that does not match the first certificate fails here: both new
     files are removed, the `.old` ones are restored if both existed, and
     the answer is `500` with a message starting
     `Setting certificate files failed - ` and containing
     `key does not match the certificate (chain)`.
  4. With `restart` set: runs `systemctl reload-or-restart pveproxy`
     before answering (see "Restart" below).
- Success: `200`, body `{"data":{...}}` with one object (not an array)
  `[schema]` `[source: pve-common Certificate.pm get_certificate_info]`:
  `filename` (`pveproxy-ssl.pem`), `fingerprint`, `subject`, `issuer`
  (OpenSSL one-line form `/CN=.../O=...`), `notbefore`, `notafter` (epoch
  seconds), `san` (DNS names and IP addresses as strings), `pem` (the
  first certificate only), `public-key-type` (OpenSSL short name),
  `public-key-bits`. All describe the **first** certificate of the chain.
- `fingerprint`: SHA-256 of the DER certificate, upper-case hex pairs
  separated by `:` `[source: Net::SSLeay 1.94 SSLeay.xs
  X509_get_fingerprint]`. The schema pattern allows either case `[schema]`.
- The call is synchronous: no task (UPID) is returned `[source:
  pve-manager Certificates.pm]`.

### Restart (PVE)

- `restart=1` makes pvedaemon run `systemctl reload-or-restart pveproxy`
  inside the call, before the answer `[source: pve-manager
  Certificates.pm]`.
- `ExecReload` of `pveproxy.service` is `pveproxy restart`
  `[source: pve-manager services/pveproxy.service]`. It sends `SIGHUP` to
  the running pveproxy master and returns `[source: pve-common
  src/PVE/Daemon.pm register_restart_command, $reload_daemon]`.
- On `SIGHUP` the master stops accepting, leaves its workers running to
  finish open connections (`leave_children_open_on_reload`), and re-executes
  itself; the new process reads the certificate files again and starts new
  workers `[source: pve-common Daemon.pm; pve-manager
  PVE/Service/pveproxy.pm]`.
- Consequence `[derived]`: the answer to the upload comes from a worker of
  the old process; the new certificate is served on **new** connections
  once the new master runs. A keep-alive connection keeps the old
  certificate. The time between the answer and the new certificate is not
  known (see "Open").
- pveproxy uses `/etc/pve/local/pveproxy-ssl.pem` and
  `/etc/pve/local/pveproxy-ssl.key` if both exist, otherwise
  `/etc/pve/local/pve-ssl.pem` / `pve-ssl.key`. `TLS_KEY_FILE` in
  `/etc/default/pveproxy` replaces the path of the custom key
  `[source: pve-manager pveproxy.pm init]`.
- It serves the whole file as chain (`AnyEvent::TLS` `cert_file` uses
  `CTX_use_certificate_chain_file`) `[source: AnyEvent 7.17
  lib/AnyEvent/TLS.pm]`.
- Without `restart`, the files are written and pveproxy keeps serving the
  old certificate until its next reload or restart `[source: pve-manager
  Certificates.pm, pveproxy.pm]`.

### GET /api2/json/nodes/{node}/certificates/info

- Permission: `user => 'all'`, i.e. any authenticated user or token, no
  privilege needed; tokens allowed `[schema]` `[source: pve-access-control
  RPCEnvironment.pm check_api2_permissions]`.
- Answer: `{"data":[...]}`, one object per file that can be read, in this
  order: `pve-root-ca.pem` (the cluster CA), `pve-ssl.pem` (the node
  certificate), `pveproxy-ssl.pem` (the custom one, if present). Each object
  has the fields of the upload answer, `pem` included `[source: pve-manager
  Certificates.pm info; pve-common Certificate.pm]`.
- The node does not report which file pveproxy currently serves. It serves
  `pveproxy-ssl.pem` if it and its key exist at its last (re)start
  `[source: pve-manager pveproxy.pm]`.
- Note: `pve-docs certificate-management.adoc` says "There is no API or web
  interface endpoint for downloading the file" (`pve-root-ca.pem`), but this
  endpoint returns its `pem` to any authenticated caller `[docs: pve-docs
  certificate-management.adoc]` `[source: pve-manager Certificates.pm]`.
  Fetching it over a connection not yet verified proves nothing `[derived]`.
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
  without a custom certificate also answers 200 `[source: same]`.
- Afterwards pveproxy (after its reload) serves `pve-ssl.pem`, signed by the
  cluster CA `[source: pve-manager pveproxy.pm]`.

### What a fresh PVE node presents

- `pve-ssl.pem`, made by `gen_pve_ssl_cert` (run by `pvecm updatecerts` in
  `ExecStartPre` of pveproxy) `[source: pve-cluster
  src/PVE/Cluster/Setup.pm; pve-manager services/pveproxy.service]`:
  - Subject: `OU=PVE Cluster Node, O=Proxmox Virtual Environment, CN=<fqdn>`.
  - SANs, in this order: `IP:127.0.0.1`, `IP:::1`, `DNS:localhost`,
    `IP:<node address>`, `DNS:<nodename>`, and `DNS:<nodename>.<search>`
    if `/etc/resolv.conf` has a `search` or `domain` line (its first word).
    `<fqdn>` is that last name, or the node name without one. `<node
    address>` is the node's cluster address (`remote_node_ip`).
  - `basicConstraints=CA:FALSE`, `extendedKeyUsage=serverAuth`.
  - Key: RSA 2048. Lifetime: until 2 days before the CA expires, at most
    730 days; backdated one day (`faketime yesterday`).
  - Issuer: the cluster CA `/etc/pve/pve-root-ca.pem`, subject
    `CN=Proxmox Virtual Environment, OU=<random UUID>,
    O=PVE Cluster Manager CA`, RSA 4096, 3650 days,
    `keyUsage=critical,keyCertSign,cRLSign`; made once per cluster.
- `pveupdate` (daily) renews `pve-ssl.pem` when it expires within 14 days
  or has more than 2 years left, and reloads pveproxy `[source: pve-manager
  bin/pveupdate]`. A pin on the fingerprint of `pve-ssl.pem` breaks at that
  renewal; the cluster CA stays `[derived]`.
- pveproxy presents `pve-ssl.pem` alone; the CA is not in the file
  `[source: pve-cluster Setup.pm]`.
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
  the leaf, the key is checked against it
  (`CTX_use_certificate_chain_file`) `[source: pve-manager CertHelpers.pm]`.
- The order of the rest is not checked. The file is served as uploaded
  `[source: pve-manager CertHelpers.pm, pveproxy.pm]`.
- No key type is restricted in the code; whatever OpenSSL loads (RSA, EC)
  passes `[source: pve-manager CertHelpers.pm]`.
- The key "needs to be without password" `[docs: pve-docs
  certificate-management.adoc]`. The format check accepts an encrypted PEM
  block (any label) `[source: pve-common Certificate.pm]`; what the
  loading does with it is open.
- Traditional (`RSA PRIVATE KEY`, `EC PRIVATE KEY`) and PKCS#8
  (`PRIVATE KEY`) both pass the format check `[source: pve-common
  Certificate.pm]`; the key is stored as uploaded.

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
  `[derived]`.
- `Sys.Modify` on `/nodes/{node}` also allows, on that node: services
  start/stop/restart/reload, network configuration, DNS, hosts, time, APT
  update and repositories, firewall rules and options, subscription, ACME
  certificate order/renew/delete `[schema]`.
- Commands, syntax read in `pveum` and the API schema, **not run**
  `[source: pve-access-control src/PVE/CLI/pveum.pm]` `[schema]`
  `[docs: pve-docs pveum.adoc]`:

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
  pveum.adoc]`. `token add` prints the secret once (`value`) `[schema]`.
  Both ACL lines are needed with `--privsep 1` (intersection, above).

---

## Proxmox Backup Server (proxmox-backup-proxy, port 8007)

### Request path and transport

- The API listens on TCP 8007 with TLS, served by `proxmox-backup-proxy`.
  `protected` calls are forwarded to `proxmox-backup-api` on the same host,
  which runs as root `[source: proxmox proxmox-rest-server src/rest.rs
  proxy_protected_request; proxmox-backup src/api2/node/certificates.rs]`.
- Request bodies: `application/x-www-form-urlencoded` or
  `application/json` (parameters after `;` ignored); without content type,
  the body is parsed as form data; any other content type is a 400
  (`unsupported content type`) `[source: proxmox-rest-server rest.rs
  get_request_parameters]`.
- With a JSON body, the query string is **not** read; with a form body,
  query and body are merged `[source: same]`.
- Body limit 512 KiB (`Request body too large`, 400) `[source: same]`.
- A plain-HTTP request on port 8007 is answered with `301`/`308` to
  `https://` `[source: proxmox-rest-server rest.rs RedirectService]`; the
  request has crossed the network in the clear by then `[derived]`.

### Booleans

- Form body or query: `1|on|yes|true` and `0|off|no|false`, any case
  `[source: proxmox proxmox-schema src/schema.rs parse_boolean]`.
- JSON body: only JSON `true`/`false`; a string `"1"` fails with
  "Expected boolean value." `[source: proxmox-schema schema.rs
  BooleanSchema::verify_json]`.

### The token

- Header: `Authorization: PBSAPIToken=sick@pbs!sick:<secret>`
  `[source: proxmox-backup src/auth.rs auth_token_prefix; proxmox
  proxmox-auth-api src/api/mod.rs extract_auth_data, http_check_auth]`
  `[docs: proxmox-backup docs/user-management.rst]`.
- After `PBSAPIToken` one `=` or one space; the rest is split at the
  **first** `:` into token id and secret; the secret is percent-decoded
  `[source: proxmox-auth-api api/mod.rs]`.
- Token name: `[A-Za-z0-9_][A-Za-z0-9._\-]*` `[schema]`.
- A ticket cookie (`__Host-PBSAuthCookie` or `PBSAuthCookie`) takes
  precedence over the token `[source: proxmox-auth-api api/mod.rs]`.
- No CSRF token is needed with a token; the CSRF check is in the ticket
  branch only `[source: proxmox-auth-api api/mod.rs http_check_auth]`.
- The token must be active (enabled, not expired) and its secret correct
  `[source: same]`.
- Tokens are always privilege-separated: they need ACL entries of their
  own, and the result is intersected with the user's `[docs: proxmox-backup
  docs/user-management.rst]`.

### Error answers common to all calls

- Authentication failed (also: no header): status `401`, body the plain
  text `authentication failed` (no content type), sent 3 seconds after the
  request started `[source: proxmox-rest-server rest.rs authorize_request,
  ApiService::call]`.
- Missing privilege: status `403`, body the plain text
  `permission check failed` with content type `application/json`, sent
  0.5 seconds after the request started `[source: proxmox-rest-server
  rest.rs authorize_request; src/formatter.rs error_to_response]`.
- Unknown path: `404`, body `Path '<path>' not found.`; only after a
  successful authentication `[source: proxmox-rest-server rest.rs]`.
- Parameter verification failed: `400`, body the plain text
  `parameter verification failed - '<param>': <reason>` (several:
  `parameter verification failed:` and one line per parameter)
  `[source: proxmox-schema schema.rs ParameterError; proxmox-rest-server
  formatter.rs]`.
- Any other error of the handler: `400`, body the plain text of the error
  `[source: proxmox-rest-server formatter.rs error_to_response]`.
- Errors are not JSON on the `json` endpoint, although the content type
  says `application/json` `[source: same]`. The reason phrase is the
  standard one of the status `[derived]` (hyper; not read).

### POST /api2/json/nodes/{node}/certificates/custom (upload)

- Permission: `Sys.Modify` on `/system/certificates` (not partial)
  `[schema]` `[source: proxmox-backup src/api2/node/certificates.rs]`.
- `{node}`: any string of hostname format, schema text "Node name (or
  'localhost')"; the handler does not look at it `[schema]` `[source:
  proxmox-backup certificates.rs; src/api2/node/mod.rs]`. `localhost` is
  what the GUI uses `[source: proxmox-backup www/MainView.js]`.
- Parameters `[schema]` `[source: proxmox-backup certificates.rs]`:
  - `certificates` (string, required): parsed with
    `X509::stack_from_pem`, re-encoded, joined with newlines.
  - `key` (string, optional): parsed with `PKey::private_key_from_pem`,
    stored as PKCS#8. Without `key`, the existing `proxy.key` is used.
  - `restart` (boolean): "UI compatibility parameter, ignored".
  - `force` (boolean): declared, but the handler does not take it: it is
    ignored. An existing custom certificate is always replaced.
  - `node` (from the path).
- What it does `[source: proxmox-backup certificates.rs,
  src/config/mod.rs set_proxy_certificate, src/server/mod.rs
  reload_proxy_certificate]`:
  1. Writes `/etc/proxmox-backup/proxy.key`, then `proxy.pem`.
  2. Sends `reload-certificate` to the command socket of
     `proxmox-backup-proxy` and waits for its answer.
  3. The proxy builds a new TLS acceptor from the two files and swaps it
     in. **If that fails (key not matching the certificate, unreadable
     file), the proxy only logs `error reloading certificate` and keeps the
     old acceptor; the command still answers success**
     `[source: proxmox-backup src/bin/proxmox-backup-proxy.rs]`.
  4. Answers with `get_info()` of the new `proxy.pem`.
- Consequence `[derived]`: **PBS does not refuse a key that does not match
  the certificate.** The upload answers 200 with the info of the new file;
  the proxy keeps serving the old certificate; the mismatched pair stays on
  disk, and the next start of the proxy fails, because the initial
  acceptor must build (`make_tls_acceptor()?` at start). Our client checks
  the pair before the upload and checks the presented certificate after it.
- No check of the chain order, of the key type, or that `certificates`
  holds at least one certificate is in the handler `[source: proxmox-backup
  certificates.rs]`. What an empty `certificates` does is open.
- Success: `200`, `{"data":[{...}]}`, an **array** with one object
  `[schema]` `[source: proxmox-backup certificates.rs get_info]`:
  `filename` (`proxy.pem`), `subject`, `issuer`, `san` (DNS names only; IP
  SANs are left out), `notbefore`, `notafter`, `pem` (the whole `proxy.pem`,
  chain included), `public-key-type` (OpenSSL long name),
  `public-key-bits`, `fingerprint`.
- `fingerprint`: SHA-256 of the first certificate, **lower-case** hex pairs
  separated by `:` `[source: proxmox-backup pbs-tools/src/cert.rs
  fingerprint]`.
- The call is synchronous, no task `[source: proxmox-backup
  certificates.rs]`.

### Restart (PBS)

- No restart. The reload happens within the call, before the answer
  (above). New connections get the new certificate once the call has
  answered; an open keep-alive connection keeps the old one `[source:
  proxmox-backup proxmox-backup-proxy.rs]` `[derived]`.
- `restart` is ignored `[source: proxmox-backup certificates.rs]`.

### GET /api2/json/nodes/{node}/certificates/info

- Permission: `Sys.Modify` on `/system/certificates`, the same as the
  upload `[schema]` `[source: proxmox-backup certificates.rs]`.
- Answer: as the upload answer, one object for `proxy.pem`
  `[source: same]`. It shows the file, not what the proxy serves
  (they differ after a failed reload, above) `[derived]`.
- `GET /api2/json/nodes/localhost/status` returns `info.fingerprint` of
  `proxy.pem` with `Sys.Audit` on `/system/status` `[schema]`
  `[source: proxmox-backup src/api2/node/status.rs]`.

### DELETE /api2/json/nodes/{node}/certificates/custom

- Permission: `Sys.Modify` on `/system/certificates` `[schema]`.
- Parameters: `node`, `restart` (ignored), in the query string `[schema]`.
- Removes `proxy.pem` (error if that fails) and `proxy.key` (only logged),
  generates a **new** self-signed certificate with a new key, reloads the
  proxy; answer `{"data":null}` `[source: proxmox-backup certificates.rs]`.
- There is no notion of "custom" on PBS: a DELETE on a node that still has
  its self-signed certificate replaces it with a new one, with a new
  fingerprint; it does not answer an error `[source: same]`.

### What a fresh PBS presents

- `proxy.pem`, made by `update_self_signed_cert` when `proxmox-backup-api`
  starts and the files are missing `[source: proxmox-backup
  src/config/mod.rs; src/bin/proxmox-backup-api.rs]`:
  - Self-signed (issuer = subject).
  - Subject: `O=Proxmox Backup Server, OU=<random UUID, upper-case hex>,
    CN=<fqdn>`.
  - SANs: `IP:127.0.0.1`, `IP:::1`, `DNS:localhost`, `DNS:<nodename>`
    (unless it is `localhost`), `DNS:<nodename>.<search>` if
    `/etc/resolv.conf` has a `search`/`domain` line (first word). **No IP
    address of the host.**
  - `basicConstraints` CA false, `extendedKeyUsage=serverAuth`, subject and
    authority key identifiers.
  - Key: RSA 4096. Lifetime: 365000 days.
- The admin sees its SHA-256 fingerprint in `proxmox-backup-manager cert
  info` (line `Fingerprint (sha256): ...`) and in the GUI: Dashboard, "Show
  Fingerprint" `[source: proxmox-backup src/bin/proxmox_backup_manager/cert.rs,
  www/panel/NodeInfo.js]` `[docs: proxmox-backup docs/managing-remotes.rst]`.
- Consequence for the trust of the first upload `[derived]`: there is no CA
  to anchor on; what the admin can hand over out of band is the fingerprint
  (or the file). The certificate names the host only by DNS names. How the
  target trusts the node: `docs/decisions/0001-trust-in-the-node.md`.

### Chains and keys (PBS)

- A chain is accepted; it is served with `set_certificate_chain_file`, the
  first certificate as leaf `[source: proxmox proxmox-rest-server
  src/connection.rs TlsAcceptorBuilder::build]`.
- The order is not checked; certificates are re-encoded in the order given
  `[source: proxmox-backup certificates.rs]`.
- Key types: whatever `PKey::private_key_from_pem` reads (RSA, EC, ...);
  traditional and PKCS#8 are both read; stored as PKCS#8 `[source: same]`.
- The key "must not be password protected" `[docs: proxmox-backup
  docs/certificate-management.rst]`.

### TLS of proxmox-backup-proxy

- `SslAcceptor::mozilla_intermediate_v5` (TLS 1.2 and 1.3, Mozilla
  intermediate ciphers), no renegotiation; ciphers overridable in the node
  config (`ciphers-tls-1.2`, `ciphers-tls-1.3`) `[source: proxmox-rest-server
  connection.rs; proxmox-backup proxmox-backup-proxy.rs make_tls_acceptor]`.
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
  pbs-config/src/acl.rs]`.
- Commands, syntax read in the CLI source and the manual, **not run**
  `[source: proxmox-backup src/bin/proxmox_backup_manager/user.rs, acl.rs]`
  `[docs: proxmox-backup docs/user-management.rst]` `[schema]`:

  ```
  proxmox-backup-manager user create sick@pbs --comment 'SICK certificate upload'
  proxmox-backup-manager user generate-token sick@pbs sick --expire <epoch> --comment 'SICK'
  proxmox-backup-manager acl update /system/certificates Admin --auth-id sick@pbs
  proxmox-backup-manager acl update /system/certificates Admin --auth-id 'sick@pbs!sick'
  ```

  `generate-token` prints `tokenid` and `value` (the secret) once
  `[docs: proxmox-backup docs/user-management.rst]`.

---

## Where the earlier session disagrees

The earlier session (`../sick`: `docs/findings/device-proxmox.md`,
`contrib/devices/proxmox/README.md`, `t/e2e/proxmox-standin.py`) read the
schemas and some sources. Checked against the sources above:

1. **PBS does not check that the key matches the certificate.** The stand-in
   answers 500 for a mismatched key on PBS. The real handler writes the
   files, the proxy refuses them only in its log, the API answers 200, and
   the proxy keeps the old certificate until its next start, which then
   fails `[source: proxmox-backup certificates.rs,
   proxmox-backup-proxy.rs]`.
2. **PVE's default certificate is not self-signed.** The stand-in serves a
   self-signed certificate "like PVE's own node certificate". The real
   `pve-ssl.pem` is signed by the cluster CA and carries the cluster address
   as IP SAN `[source: pve-cluster Setup.pm]`.
3. **PVE restart mechanism.** The findings say pveproxy "restarts in the
   background after the answer". The upload itself runs `systemctl
   reload-or-restart pveproxy` before answering, which sends SIGHUP; the
   master re-executes, old workers finish their connections. The certificate
   changes for new connections some time after the answer; the delay is not
   known `[source: pve-manager Certificates.pm; pve-common Daemon.pm]`.
4. **DELETE without a custom certificate.** The stand-in answers 500 ("no
   custom certificate") on both. PVE answers 200 (missing files are
   ignored); PBS answers 200 and replaces its self-signed certificate with a
   new one `[source: pve-manager Certificates.pm; proxmox-backup
   certificates.rs]`.
5. **PBS ignores `force` as well as `restart`.** The findings mention only
   `restart` as ignored `[source: proxmox-backup certificates.rs]`.
6. **401 answers.** The stand-in sends reason `authentication failure` with
   an empty body, at once. PVE: `401 Authentication failed!` (or
   `401 No ticket` without credentials), empty body, after 3 seconds. PBS:
   401 with the plain-text body `authentication failed`, after 3 seconds
   `[source: pve-manager HTTPServer.pm; proxmox-rest-server rest.rs]`.
7. **Error bodies on PBS are plain text, not JSON**, also for 400
   parameter errors; the stand-in sends JSON with `errors` on 400
   `[source: proxmox-rest-server formatter.rs]`.
8. **Success answers.** The stand-in returns only `filename` and
   `fingerprint`, upper case for both. The real answers carry all fields of
   the certificate info (PVE an object, PBS an array of one); PVE's
   fingerprint is upper case, PBS's lower case `[source: pve-common
   Certificate.pm; proxmox-backup pbs-tools cert.rs]`.
9. **PVE existing-certificate message.** The stand-in says
   `Custom certificate exists but 'force' is not set.`; the real text is
   `Custom certificate file exists but force flag is not set.` (status 500
   in both) `[source: pve-manager CertHelpers.pm]`.
10. **Booleans.** The findings leave open whether pveproxy takes `"1"` in a
    JSON body: the source accepts it. PBS does not accept `"1"` in a JSON
    body (only `true`) `[source: pve-common JSONSchema.pm; proxmox-schema
    schema.rs]`.
11. **Scope of `Admin` on `/system/certificates` (PBS).** The README says it
    "covers the certificate and the ACME settings of the host, nothing
    else". Correct, but the ACME settings include reading the DNS plugin
    credentials `[schema]`.
12. Confirmed as the earlier session read them: the paths; `Sys.Modify` on
    `/nodes/{node}` (PVE) and on `/system/certificates` (PBS); tokens
    allowed on PVE; `Admin` the only PBS role with `Sys.Modify`; the token
    header formats; PVE writes `pveproxy-ssl.pem`/`.key`, PBS
    `proxy.pem`/`.key`; PBS reloads within the call; `restart` ignored on
    PBS; PVE falls back to `pve-ssl.pem` after DELETE; the `pveum` and
    `proxmox-backup-manager` command syntax.

---

## Open: not known yet

To be observed on a real node, with its version, before code relies on it:

PVE

- The time from the upload answer (`restart=1`) to the new certificate on a
  new connection; whether any request fails during the re-exec.
- The real 401 answer: status line, empty body, the 3-second delay.
- `"1"` and `true` as booleans in a JSON body (source says both pass).
- A mismatched key: status 500 and the exact message; the old custom files
  restored.
- An encrypted key: what the loading in pvedaemon does without a password
  callback (expected: an error, not a hang).
- An EC key and a leaf+intermediate chain served in full.
- `{node}` not a member of the cluster, and `localhost`, as path node.
- The SANs of `pve-ssl.pem` on a node with and without `search` in
  `/etc/resolv.conf`; whether the CA certificate carries
  `basicConstraints=CA:TRUE` (not set explicitly in `gen_pveca_cert`).
- `TLS_KEY_FILE` set in `/etc/default/pveproxy`: the uploaded key is then
  not the one served.
- Clusters: upload through one node for another (`proxyto`).

PBS

- **A mismatched key**: answer 200, the proxy keeps the old certificate,
  the log line, and a failing proxy start afterwards.
- `certificates` without any certificate: what is written, what answers.
- The real 401 and 403 answers: status line, body, content type, delays.
- An encrypted key; an EC key; a chain served in full.
- `{node}` other than `localhost` (for example the node name).
- The SANs and subject of a fresh `proxy.pem`.
- DELETE on a host with only its self-signed certificate (new fingerprint).

Both

- The `pveum` and `proxmox-backup-manager` commands above, run.
- The TLS versions and cipher suites a fresh node negotiates.

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
