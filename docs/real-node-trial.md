# Real PBS and PVE in containers: what the certificate API does

Trial of 2026-10-11 on the shared lab host (an LXC guest itself: no KVM, no sudo,
Docker 26.1.5, no `/dev/fuse` on the host). Goal: run the real Proxmox Backup Server
and the real Proxmox VE API in Docker containers and observe the certificate API, so
that `docs/api-notes.md` can cite "observed on PBS x.y / PVE x.y".

**Status: both ran.** PBS fully as packaged. PVE ran the real pmxcfs, pvedaemon and
pveproxy, but **without systemd**: the restart of pveproxy after an upload goes through
`systemctl`, so it was observed (a) with the real `systemctl` (fails, recorded below)
and (b) through a **systemctl shim** that does what the unit's `ExecReload` does
(`pveproxy restart`, run as a child of PID 1, which sends `HUP` to the pveproxy
master). Every PVE timing below is "with the shim", not "with systemd".

Not a single request went unverified: every `curl` and `openssl s_client` ran with
`--cacert` / `-CAfile` (the node's own self-signed or cluster CA certificate fetched
first, then the trial root). The token went into curl only through `-H @file`.

Names in this document are neutral: host `pbs1.example.internal`, node `pve1`
(`pve1.example.internal`), users `sick@pbs` / `sick@pve`, token id `sick`. The
container address is written `<node-ip>`. No PEM, no secret.

## Versions

| | Version |
|---|---|
| Base image | `debian:trixie` (glibc 2.41-12+deb13u4, OpenSSL 3.5.7-1~deb13u3) |
| PBS repo | `http://download.proxmox.com/debian/pbs trixie pbs-no-subscription`, key `proxmox-archive-keyring-trixie.gpg` (from enterprise.proxmox.com) |
| **proxmox-backup-server** | **4.2.8-1** (`proxmox-backup-manager versions`: running version 4.2.8) |
| PBS extras | proxmox-widget-toolkit 5.2.10, libjs-extjs 7.0.0-7 |
| PVE repo | `http://download.proxmox.com/debian/pve trixie pve-no-subscription`, same key |
| **pve-manager** | **9.2.21** (running version 9.2.21/4f6e0ac86f9e8c7f) |
| PVE libraries | pve-cluster / libpve-cluster-perl 9.1.6, libpve-access-control 9.1.2, libpve-common-perl 9.2.3, libpve-http-server-perl 6.0.5, libnet-ssleay-perl 1.94-3, qemu-server 9.2.10 (installed as a dependency, never used) |
| Client side | curl 8.14.1, OpenSSL 3.5.7 (same trixie image) |

`apt-get install --no-install-recommends` with an APT pin of priority -1 on
`proxmox-kernel* proxmox-default-kernel* pve-firmware* proxmox-firmware*` pulled no
kernel for either product. Install times: PBS image 45 s, PVE image 2 min 50 s.
Image sizes: `sick-pmx-pbs:4` 521 MB, `sick-pmx-pve:9` 1.7 GB.

## Setup

- One labelled network `sick-pmx-net`; containers `sick-pmx-pbs` / `sick-pmx-pve`
  (the node) and `sick-pmx-client` (curl, openssl). No port published; the client
  talks to the node by its network alias. Scratch dir (mode 0700) mounted into the
  client only.
- Hostname set with `--hostname pbs1 --domainname example.internal --dns-search
  example.internal`. **Without `--domainname`/`--dns-search` PBS takes the host's DNS
  search domain into its certificate's CN and SAN** (first attempt: CN
  `pbs1.<search-domain of the lab host>`); the container was recreated.
- **PBS**: `--tmpfs /run/proxmox-backup:...,uid=34,gid=34` (the package's
  `run-proxmox\x2dbackup.mount`), then `proxmox-backup-api` as root and
  `proxmox-backup-proxy` as `backup` via `setpriv` (the units: `Type=notify`,
  `User=backup` for the proxy). Both run without systemd; `NOTIFY_SOCKET` unset is
  harmless. No extra capabilities.
- **PVE**: pmxcfs needs FUSE. The host has no `/dev/fuse` (the kernel has `fuse` in
  `/proc/filesystems`, the LXC guest just has no node), so `--device /dev/fuse` was
  impossible. Used instead: **`--cap-add SYS_ADMIN --device-cgroup-rule 'c 10:229
  rwm'` and `mknod /dev/fuse c 10 229` inside the container** - the same device
  grant `--device /dev/fuse` would give, nothing more. Without it pmxcfs stops with
  `fuse: device not found, try 'modprobe fuse' first` / `[main] crit: fuse_mount error:
  No such file or directory`. With it pmxcfs runs in local mode (no corosync.conf);
  no `--privileged`, no AppArmor change.
- PVE daemons: `PVE::Daemon` starts in the background only when `getppid() == 1`
  (as under systemd); otherwise `pvedaemon start` runs `systemctl start pvedaemon` and
  fails (`System has not been booted with systemd as init system (PID 1). Can't
  operate.`). So PID 1 of the container is a small loop (`pve-init.sh`) that runs
  commands written into a FIFO as its direct children (`ctl.sh pvedaemon start`).
  `pvecm updatecerts --force` made the cluster CA and `pve-ssl.pem` (its ssh part
  fails: no ssh in the image; irrelevant here). `busybox syslogd` was added later to
  see the daemons' syslog.
- Test CA made at run time with openssl: root (EC P-256) -> intermediate (EC P-256)
  -> leaves `CN=<host>`, SAN `DNS:<host>`, 7 days: `rsa1`, `rsa2` (RSA 2048), `ec1`
  (P-256). Keys in both PKCS#8 (`BEGIN PRIVATE KEY`) and traditional (`BEGIN RSA
  PRIVATE KEY` / SEC1 `BEGIN EC PRIVATE KEY`) form. "chain" = leaf + intermediate,
  "revchain" = intermediate + leaf.
- JSON bodies were written into a 0600 file and sent with `--data-binary @file`.

# PBS 4.2.8

## a. What 8007 presents before anything

Made by `proxmox-backup-api` on first start (with `authkey`, `csrf.key`):

| | |
|---|---|
| Subject = Issuer | `O=Proxmox Backup Server, OU=<random UUID>, CN=pbs1.example.internal` (self-signed) |
| SAN | `IP:127.0.0.1, IP:::1, DNS:localhost, DNS:pbs1, DNS:pbs1.example.internal` (the container address is **not** in it) |
| Key | RSA 4096, sha256WithRSAEncryption, serial 00 |
| Validity | notBefore = now, notAfter = now + 1000 years (Oct 2026 -> Feb 3026) |
| Extensions | `CA:FALSE`, EKU serverAuth |
| Chain sent | 1 certificate; TLS 1.3, TLS_AES_256_GCM_SHA384 |

`openssl s_client` without a CA file: `Verify return code: 18 (self-signed
certificate)`. Pinning that certificate as `--cacert` verifies (the hostname is in
the SAN).

`proxmox-backup-manager cert info` (exit 0):

```
Subject: O = Proxmox Backup Server, OU = <UUID>, CN = pbs1.example.internal
    IP:[127, 0, 0, 1]
    IP:[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
    DNS:localhost
    DNS:pbs1
    DNS:pbs1.example.internal
Issuer: O = Proxmox Backup Server, OU = <UUID>, CN = pbs1.example.internal
Validity:
    Not Before: Oct 11 05:37:25 2026 GMT
    Not After : Feb 11 05:37:25 3026 GMT
Fingerprint (sha256): bd:af:ed:…:d2:a8
Public key type: rsaEncryption
Public key bits: 4096
```

Fingerprint format: **lowercase hex, colon-separated** (openssl prints uppercase).

## User, token, ACL (run, exact syntax)

```
proxmox-backup-manager user create sick@pbs --comment "SICK: certificate upload"   # exit 0, no output
proxmox-backup-manager user generate-token sick@pbs sick                           # exit 0
Result: {
  "tokenid": "sick@pbs!sick",
  "value": "<MASKED: a UUID>"
}
proxmox-backup-manager acl update /system/certificates Admin --auth-id "sick@pbs!sick"   # exit 0
proxmox-backup-manager acl update /system/certificates Admin --auth-id sick@pbs          # exit 0
```

`acl list` afterwards: two lines, path `/system/certificates`, propagate 1, role
`Admin`. Header: `Authorization: PBSAPIToken=sick@pbs!sick:<secret>`.

**The token needs the ACL on itself and on its user.** With the token ACL alone:
`403 Forbidden`, body `permission check failed`.

## b. GET /api2/json/nodes/localhost/certificates/info

| Case | Status line | Body |
|---|---|---|
| no ACL at all | `HTTP/1.1 403 Forbidden` | `permission check failed` (plain text, although `content-type: application/json;charset=UTF-8`, 23 bytes) |
| token ACL only | `HTTP/1.1 403 Forbidden` | `permission check failed` |
| wrong secret | `HTTP/1.1 401 Unauthorized` (+ `set-cookie: __Host-PBSAuthCookie=; Expires=Thu, 01 Jan 1970 …`) | `authentication failed`; answered after **~3 s** |
| user + token ACL | `HTTP/1.1 200 OK` | below |

```
{"data":[{"filename":"proxy.pem",
  "fingerprint":"bd:af:ed:…:d2:a8",
  "issuer":"O = Proxmox Backup Server, OU = <UUID>, CN = pbs1.example.internal",
  "notafter":33327697045,"notbefore":1791697045,
  "pem":"<PEM removed>",
  "public-key-bits":4096,"public-key-type":"rsaEncryption",
  "san":["localhost","pbs1","pbs1.example.internal"],
  "subject":"O = Proxmox Backup Server, OU = <UUID>, CN = pbs1.example.internal"}]}
```

One entry only (`proxy.pem`, the leaf). `san` lists **DNS names only** (the IP SANs
are left out). The node name in the path is not checked: `nodes/pbs1/…` and
`nodes/foo/…` answer the same 200.

## c. POST /api2/json/nodes/localhost/certificates/custom

Body JSON `{"certificates": <rsa1 leaf+intermediate>, "key": <rsa1, traditional RSA>,
"force": true, "restart": true}`:

```
HTTP/1.1 200 OK            (52 ms)
{"data":[{"filename":"proxy.pem","fingerprint":"6f:55:12:…:25:bb",
  "issuer":"CN = SICK Trial Intermediate","notafter":1792301887,"notbefore":1791697087,
  "pem":"<PEM removed>","public-key-bits":2048,"public-key-type":"rsaEncryption",
  "san":["pbs1.example.internal"],"subject":"CN = pbs1.example.internal"}]}
```

- The answer is the same shape as `info` (an array with one entry, the leaf).
- **Presented at once**: polled in parallel, the new leaf was on 8007 155 ms after the
  poll started (the call itself took 52 ms); in six further alternating uploads the
  very next TLS connection after the answer always presented the new leaf.
- The proxy keeps running (same PID); its log says `reloading certificate`. No
  restart of the process.
- Stored: `/etc/proxmox-backup/proxy.pem` = the chain as sent (2 certificates),
  `proxy.key` is **rewritten as PKCS#8** (`BEGIN PRIVATE KEY`) although a traditional
  RSA key was sent. Owner root:backup, 0640.
- Presented chain: leaf + intermediate; `openssl s_client -CAfile root.pem
  -verify_hostname pbs1.example.internal`: `Verify return code: 0 (ok)`.

## d. Negatives (PBS)

| Case | Status line | Body | Afterwards |
|---|---|---|---|
| wrong secret | `401 Unauthorized` | `authentication failed` (~3 s) | old cert presented |
| token without ACL (second token `sick@pbs!noacl`) | `403 Forbidden` | `permission check failed` | old cert |
| **no `force`**, a custom cert exists | `200 OK` | info of the new cert | **replaced**: `force` is not needed |
| `force: false` explicitly, custom cert exists | `200 OK` | info of the new cert | replaced |
| from the generated self-signed, no `force`, no `restart` | `200 OK` | info | presented at once |
| **key not matching the cert** (rsa2 chain + rsa1 key, force) | **`200 OK`** | info of the rsa2 cert | see below |
| booleans as strings `"1"` | `400 Bad Request` | `parameter verification failed:`<br>`- 'force': Expected boolean value.`<br>`- 'restart': Expected boolean value.` | unchanged |
| booleans as numbers `1` | `400 Bad Request` | same as above | unchanged |
| form-encoded (`--data-urlencode certificates@… key@…`, `force=1 restart=1`) | `200 OK` | info | presented at once (form `1` is a boolean there) |
| EC P-256 leaf, PKCS#8 key | `200 OK` | `"public-key-bits":256,"public-key-type":"id-ecPublicKey"` | presented; `Peer signature type: ecdsa_secp256r1_sha256`, verify ok |
| EC P-256 leaf, SEC1 `EC PRIVATE KEY` | `200 OK` | info | presented |
| RSA key PKCS#8 | `200 OK` | info | presented |
| **chain in wrong order** (intermediate first) | **`200 OK`** | info of the **intermediate** (`"subject":"CN = SICK Trial Intermediate","issuer":"CN = SICK Trial Root","san":[]`) | see below |
| leaf only (no intermediate) | `200 OK` | info | presented alone; a client with only the root then fails (`unable to get local issuer certificate`) |

**PBS does not check that key and certificate belong together before it writes
them.** Key mismatch and wrong chain order are answered `200 OK`; both files are
written; the proxy logs `error reloading certificate: private key does not match
certificate` and **keeps serving the previous certificate from memory**. The files on
disk are now broken: when the proxy was restarted afterwards it did not come up:

```
Error: private key does not match certificate
Caused by:
    error:0A0000BE:SSL routines:SSL_CTX_check_private_key:no private key assigned:../ssl/ssl_lib.c:2065:
```

Port 8007 was closed (connection refused) until `proxmox-backup-manager cert update
--force` (exit 0) made a new self-signed certificate, or until a `DELETE` (which works
as long as the old proxy is still running). An uploader therefore has to check
itself that the key matches the leaf and that the leaf comes first, and has to
compare what 8007 presents afterwards: a 200 does not mean the upload is in use.

## e. DELETE /api2/json/nodes/localhost/certificates/custom

```
HTTP/1.1 200 OK            (1093 ms)
{"data":null}
```

Afterwards 8007 presents a **new** self-signed certificate (new OU UUID, new RSA 4096
key, new fingerprint, validity again now + 1000 years), not the one from before the
upload. It is generated within the call (hence ~1.1 s) and presented right after the
answer. DELETE also repaired the broken files from (d).

## f. Logs

`/var/log/proxmox-backup/api/access.log` has one line per call
(`sick@pbs!sick [date] "POST /api2/json/nodes/localhost/certificates/custom" 200 1982
curl/8.14.1`); `auth.log` has `authentication failure; rhost=… msg=invalid
credentials`. The token secret was searched for (`grep -F -f`) in the daemons'
stdout and both logs: 0 hits.

# PVE 9.2.21

## a. What 8006 presents before anything

`pve-ssl.pem`, made by `pvecm updatecerts --force`:

| | |
|---|---|
| Subject | `OU=PVE Cluster Node, O=Proxmox Virtual Environment, CN=pve1.example.internal` |
| Issuer | `CN=Proxmox Virtual Environment, OU=<random UUID>, O=PVE Cluster Manager CA` |
| SAN | `IP:127.0.0.1, IP:::1, DNS:localhost, IP:<node-ip>, DNS:pve1, DNS:pve1.example.internal` (the node address **is** in it) |
| Key | RSA 2048, sha256WithRSAEncryption, serial 01 |
| Validity | notBefore = now - 1 day, notAfter = notBefore + 2 years |
| Extensions | `CA:FALSE`, EKU serverAuth |
| Chain sent | the leaf only (`Verify return code: 21 (unable to verify the first certificate)` without a CA file) |

`/etc/pve/pve-root-ca.pem`: self-signed, subject = issuer above, RSA 4096,
`CA:TRUE` critical, keyUsage `Certificate Sign, CRL Sign` critical, validity now - 1
day + 10 years. With it as `--cacert` the API verifies under the name
`pve1.example.internal`.

## User, role, token, ACL (run, exact syntax)

```
pveum user add sick@pve --comment "SICK: certificate upload"          # no output
pveum role add SICKCertificate --privs Sys.Modify                     # no output
pveum user token add sick@pve sick --privsep 1 --expire <now+1d> --comment SICK --output-format json
{"full-tokenid":"sick@pve!sick","info":{"comment":"SICK","expire":"<epoch>","privsep":"1"},"value":"<MASKED: a UUID>"}
pveum acl modify /nodes/pve1 --roles SICKCertificate --tokens 'sick@pve!sick'
pveum acl modify /nodes/pve1 --roles SICKCertificate --users sick@pve
```

(Every `pveum` call also prints the two syslog warnings of a container without
`/dev/log`.) Header: `Authorization: PVEAPIToken=sick@pve!sick=<secret>`.

## b. GET /api2/json/nodes/pve1/certificates/info

**Needs no ACL**: the endpoint's permission is `user => 'all'`
(`PVE/API2/Certificates.pm`), and the token without any ACL got `200 OK`:

```
{"data":[
 {"filename":"pve-root-ca.pem","subject":"/CN=Proxmox Virtual Environment/OU=<UUID>/O=PVE Cluster Manager CA",
  "issuer":"<same>","san":[],"notbefore":1791611127,"notafter":2106971127,
  "public-key-type":"rsaEncryption","public-key-bits":4096,"pem":"<PEM removed>",
  "fingerprint":"74:20:8C:…:85:B4"},
 {"filename":"pve-ssl.pem","subject":"/OU=PVE Cluster Node/O=Proxmox Virtual Environment/CN=pve1.example.internal",
  "issuer":"/CN=Proxmox Virtual Environment/OU=<UUID>/O=PVE Cluster Manager CA",
  "san":["127.0.0.1","0000:0000:0000:0000:0000:0000:0000:0001","localhost","<node-ip>","pve1","pve1.example.internal"],
  "notbefore":1791611127,"notafter":1854683127,"public-key-type":"rsaEncryption","public-key-bits":2048,
  "pem":"<PEM removed>","fingerprint":"1F:C0:4E:…:02:D1"}]}
```

Fingerprint format: **uppercase hex, colon-separated**; subject/issuer in the
`/A=b/C=d` form; `san` includes the IPs (IPv6 fully expanded). With a custom
certificate a third entry `"filename":"pveproxy-ssl.pem"` follows. An unknown node
in the path: `500 hostname lookup 'foo' failed - failed to get address info for: foo:
No address associated with hostname` (JSON `message` the same).

Wrong secret: `HTTP/1.1 401 Authentication failed!`, **empty body**, answered after
~3 s (`Server: pve-api-daemon/3.0`).

## c. POST /api2/json/nodes/pve1/certificates/custom

ACLs: none -> `403 Permission check failed (/nodes/pve1, Sys.Modify)` with
`{"message":"Permission check failed (/nodes/pve1, Sys.Modify)\n","data":null}`;
**token ACL only -> the same 403**; user + token ACL -> accepted.

### With the real systemctl (no systemd): the restart fails

Body `{"certificates":<rsa1 chain>,"key":<rsa1 traditional>,"force":"1","restart":"1"}`
(strings, as the acme.sh hook sends them):

```
HTTP/1.1 500 command 'systemctl reload-or-restart pveproxy' failed: exit code 1
{"data":null,"message":"command 'systemctl reload-or-restart pveproxy' failed: exit code 1\n\n"}
```

The files `pveproxy-ssl.pem`/`.key` **were written and stay** (the restart comes
after `set_cert_files`, nothing is rolled back); 8006 kept presenting `pve-ssl.pem`
for the 20 s polled. The restart is synchronous inside the call
(`PVE::Tools::run_command(['systemctl','reload-or-restart','pveproxy'])`), so on a
node where `systemctl` fails the caller gets a 500 for an upload that is on disk.

### With the systemctl shim

The shim logs every call and runs `pveproxy restart` as a child of PID 1, which is
what the unit's `ExecReload=/usr/bin/pveproxy restart` does under systemd
(`register_restart_command(1)`: send `HUP` to the master). The log shows exactly one
`systemctl reload-or-restart pveproxy` per upload with `restart` set.

```
HTTP/1.1 200 OK            (1.32-1.43 s for every upload with restart; ~35 ms without)
{"data":{"filename":"pveproxy-ssl.pem","fingerprint":"C7:46:51:…:4B:A1",
  "issuer":"/CN=SICK Trial Intermediate","subject":"/CN=pve1.example.internal",
  "san":["pve1.example.internal"],"notbefore":1791697568,"notafter":1792302368,
  "public-key-type":"rsaEncryption","public-key-bits":2048,"pem":"<PEM removed>"}}
```

Note: `data` is **one object**, not an array as on PBS.

pveproxy's syslog on the `HUP`:

```
pveproxy[157]: received signal HUP
pveproxy[157]: server closing
pveproxy[157]: server shutdown (restart)
pveproxy[157]: Using '/etc/pve/local/pveproxy-ssl.pem' as certificate for the web interface.   (+2 s)
pveproxy[157]: restarting server
pveproxy[157]: starting 3 worker(s)
…  (about 5 s later)
pveproxy[633]: worker exit   (the old workers)
```

**What 8006 presents after the answer flaps for several seconds.** The master keeps
its PID, starts new workers with the new certificate, and the old workers keep
accepting connections until they exit. Sampling one TLS connection every ~0.2 s after
the answer:

```
rsa1 upload (restart=1):  t+0 ms old | t+3870 new | t+4103 old | t+4563 new | t+5701 old | t+5929 new (stable)
rsa2 upload (restart=1):  t+1 ms old | t+2043 new | t+2960 old | t+3188 new | t+3417 old | … | t+6141 new (stable)
DELETE (restart=1):       t+0 ms custom | t+2725 pve-ssl | t+3188 custom | … | t+5702 pve-ssl (stable)
```

So "the new fingerprint was seen once" is not "the new certificate is in place": a
checker has to see it stably (here: from ~6 s after the answer). In a simple poll
loop the first sighting came 1.3-1.6 s after the answer. These timings are with the
shim; under systemd the same `HUP` path runs, but that is not observed here.

Stored: `pveproxy-ssl.pem` = the chain as sent, `pveproxy-ssl.key` = the key **as
sent** (a traditional key stays traditional), root:www-data 0640 in `/etc/pve/local/`.
Presented chain: leaf + intermediate; verify against the trial root ok.

## d. Negatives (PVE, shim in place)

| Case | Status line | Body | Afterwards |
|---|---|---|---|
| wrong secret | `401 Authentication failed!` | empty (~3 s) | unchanged |
| token without ACL | `403 Permission check failed (/nodes/pve1, Sys.Modify)` | `{"message":"Permission check failed (/nodes/pve1, Sys.Modify)\n","data":null}` | unchanged |
| **no `force`**, custom cert exists | `500 Custom certificate file exists but force flag is not set.` | `{"message":"Custom certificate file exists but force flag is not set.\n\n","data":null}` | unchanged |
| no `force`, no custom cert yet | `200 OK` | info | presented after restart |
| key not matching, same type (rsa1 chain + rsa2 key, force) | `500 Setting certificate files failed - 122: key does not match the certificate (chain) ()` | `{"data":null,"message":"Setting certificate files failed - 122: key does not match the certificate (chain) ()\n\n\n"}` | old files restored (`.old` copies), old cert presented |
| no `key` at all, stored key does not match the new chain | `500 Setting certificate files failed - 124: key does not match the certificate (chain) ()` | same form | restored |
| no `key` at all, stored key matches | `200 OK` | info | presented (`key` is optional when `pveproxy-ssl.key` exists) |
| booleans as strings `"1"` | `200 OK` | info | accepted (the hook's form works) |
| booleans JSON `true` | `200 OK` | info | accepted |
| booleans as numbers `1` | `200 OK` | info | accepted |
| form-encoded, `force=1 restart=1` | `200 OK` | info | accepted |
| EC P-256 leaf, PKCS#8 key | `200 OK` | `"public-key-type":"id-ecPublicKey","public-key-bits":256` | presented, verify ok |
| EC P-256 leaf, SEC1 key | `200 OK` | info | presented |
| RSA key PKCS#8 | `200 OK` | info | presented |
| **chain in wrong order** (intermediate first, rsa2 key) | **`200 OK`** | info of the **intermediate** (`"subject":"/CN=SICK Trial Intermediate","issuer":"/CN=SICK Trial Root","san":[]`, EC 256) | **pveproxy broken**, below |
| leaf only | `200 OK` | info | leaf presented alone |
| `restart` absent | `200 OK` (~35 ms) | info | files written, **not presented** (old cert stays until the next restart) |

**The key check of PVE misses a key of another type.** `set_cert_files` loads the
chain and the key into an OpenSSL context and rolls back on an error; that catches an
RSA key for an RSA leaf. With the chain in the wrong order the first certificate is
the EC intermediate and the key is RSA: OpenSSL puts a key of another type into
another slot without complaint, the check passes, the files are written, and after
the restart pveproxy accepts TCP on 8006 but every handshake ends with `unexpected
eof while reading` (curl exit 35). The API on 8006 is then unreachable, so it cannot
be repaired through the API; here it was repaired on the node (remove
`pveproxy-ssl.*`, `pveproxy restart`). The same would happen for any leaf/key pair of
different types (an EC leaf with an RSA key, or the reverse). As on PBS, the uploader
must check the order and the key itself.

## e. DELETE /api2/json/nodes/pve1/certificates/custom

```
HTTP/1.1 200 OK            (33 ms without restart, ~1.4 s with restart=1)
{"data":null}
```

Removes `pveproxy-ssl.pem`/`.key`. Without `restart` nothing changes on 8006 until the
next restart. With `restart=1` (here as query parameter) 8006 goes back to the
**same** `pve-ssl.pem` as before the upload (same fingerprint; it is not
regenerated), after the flapping shown above. A DELETE without custom files is also
`200 {"data":null}`.

## f. Logs

`/var/log/pveproxy/access.log`: `sick@pve!sick [date] "POST
/api2/json/nodes/pve1/certificates/custom HTTP/1.1" 200 1366`. The secret was
searched for in that log, the syslog and the shim log: 0 hits.

# Deviations from the earlier findings (written from reading)

`../sick/docs/findings/device-proxmox.md` and `../sick/contrib/devices/proxmox/README.md`:

1. **PBS `force` is not needed** to replace an existing custom certificate (`false`
   and absent both replaced it). PVE does need it (500 without).
2. **PBS rejects booleans as strings or numbers in JSON** (400 `Expected boolean
   value`); PVE takes `"1"`, `1` and `true`. The stand-in's split (PVE hook strings,
   PBS hook JSON booleans) matches what the real APIs accept.
3. **PBS writes a mismatched key or a wrongly ordered chain and answers 200**; the
   running proxy keeps the old certificate, the next start of the proxy fails. PVE
   checks the key but misses a key of another type than the first certificate; a
   wrongly ordered chain breaks pveproxy after the restart. Neither was in the
   findings; the stand-in rejects a mismatched key, which the real PBS does not.
4. **PVE with `restart=1` answers only after `systemctl reload-or-restart pveproxy`**
   (synchronous); if that fails the call is a 500 although the files are written. The
   findings say pveproxy restarts "in the background after the call has answered":
   the restart is triggered inside the call; what runs in the background is pveproxy
   re-executing after the `HUP`.
5. **PVE presents old and new certificate alternately for ~4-6 s** after the restart
   (old workers still accept). The stand-in switches once, 2 s after the answer.
6. **PBS needs the ACL on the user as well as on the token** (token ACL alone: 403).
   Same on PVE for the privsep token. The README's commands do both; confirmed.
7. **PVE `certificates/info` needs no privilege** (any authenticated token), PBS's
   needs one (403 without).
8. Answer shapes differ: PBS `data` is an array (also for POST), PVE POST `data` is
   an object; PBS fingerprints lowercase, PVE uppercase; PBS `san` drops IPs, PVE
   keeps them; PBS stores the key as PKCS#8, PVE as sent.
9. **PBS DELETE generates a new self-signed certificate**; PVE DELETE falls back to
   the unchanged `pve-ssl.pem` of the cluster CA.
10. 401 bodies: PBS `authentication failed`, PVE empty (status text `Authentication
    failed!`); both delay the answer ~3 s.
11. PBS's own certificate is valid 1000 years and does not carry the node address;
    PVE's `pve-ssl.pem` is valid 2 years, carries the node address, and is signed by
    a per-cluster CA whose certificate is readable by any token via `info`.

# What did not work / was not tried

- PVE restart under real systemd: not possible here; all PVE restart timings are with
  the shim. The 500 with the real `systemctl` is the real behaviour of a node without
  systemd, not of a normal node.
- PVE in a cluster (corosync), `proxyto` to another node: not tried.
- ACME endpoints, `pvenode cert set`, `proxmox-backup-manager cert update` other than
  as a repair: not tried. Expired token, token expiry: not tried (the PVE token had
  an expiry of one day and worked).
- A key with a passphrase, a chain with the root included, a leaf without the node
  name in its SAN, IPv6: not tried.
- PBS: `restart` was always accepted but has no visible effect (the proxy reloads in
  any case); whether `restart:false` suppresses the reload was not tried.
- No root password was set for either product (not needed: all admin steps ran as
  root in the container with the CLI tools).

# Teardown

Containers `sick-pmx-pbs`, `sick-pmx-pve`, `sick-pmx-client` and the network
`sick-pmx-net` removed; no volumes were created. Kept as cache, labelled `sick=1`:
images `sick-pmx-pbs:4` (521 MB) and `sick-pmx-pve:9` (1.7 GB). Token files, test CA
and bodies deleted from the scratch dir; the scripts stay there.

# Appendix: scripts

Final versions as run. Paths: build contexts under
`$HOME/.local/share/sick-lab/pmx-real/{pbs,pve}-build/`, scripts under
`…/pmx-real/work/` (mounted as `/work` into the client). Commands as run, in order:

```sh
# PBS
docker network create --label sick=1 sick-pmx-net
docker run -d --name sick-pmx-pbs --label sick=1 --network sick-pmx-net --hostname pbs1 \
  --domainname example.internal --dns-search example.internal --network-alias pbs1.example.internal \
  --tmpfs /run/proxmox-backup:rw,nosuid,nodev,mode=755,uid=34,gid=34 sick-pmx-pbs:4 sleep infinity
docker run -d --name sick-pmx-client --label sick=1 --network sick-pmx-net -v "$S/work:/work" sick-pmx-pbs:4 sleep infinity
docker cp work/pbs-start.sh sick-pmx-pbs:/root/ && docker exec sick-pmx-pbs sh /root/pbs-start.sh
# user/token/ACL as above; token output redirected into a 0600 file on the host, header file
#   "Authorization: PBSAPIToken=<tokenid>:<value>" built from it with python3 -I (no echo)
docker exec sick-pmx-client sh /work/mkca.sh /work/ca-pbs pbs1.example.internal
# then pbs-neg.sh / pbs-neg2.sh-style calls of mkbody.pl + post.sh (see the tables)

# PVE
docker create --name sick-pmx-pve --label sick=1 --network sick-pmx-net --hostname pve1 \
  --domainname example.internal --dns-search example.internal --network-alias pve1.example.internal \
  --cap-add SYS_ADMIN --device-cgroup-rule 'c 10:229 rwm' sick-pmx-pve:9 sh /pve-init.sh
docker cp work/pve-init.sh sick-pmx-pve:/pve-init.sh
docker cp work/ctl.sh sick-pmx-pve:/usr/local/sbin/ctl.sh
docker cp work/systemctl-shim.sh sick-pmx-pve:/usr/local/sbin/systemctl-shim
docker start sick-pmx-pve
docker exec sick-pmx-pve sh -c 'ctl.sh pmxcfs; ctl.sh pvecm updatecerts --force; ctl.sh pvedaemon start; ctl.sh pveproxy start'
# (later) syslog:  apt-get install busybox; busybox syslogd -n -O /var/log/messages
# (after the run with the real systemctl) shim in place:
docker exec sick-pmx-pve sh -c 'mv /usr/bin/systemctl /usr/bin/systemctl.real; cp /usr/local/sbin/systemctl-shim /usr/bin/systemctl; chmod 755 /usr/bin/systemctl /usr/local/sbin/ctl.sh'
# header file "Authorization: PVEAPIToken=<full-tokenid>=<value>" built like the PBS one

# teardown
docker ps -aq --filter label=sick=1 --filter name=sick-pmx- | xargs -r docker rm -f
docker network rm sick-pmx-net
```

## `pbs-build/Dockerfile`

```dockerfile
FROM debian:trixie
LABEL sick=1
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl openssl procps \
 && curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg -o /usr/share/keyrings/proxmox-archive-keyring.gpg \
 && printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pbs\nSuites: trixie\nComponents: pbs-no-subscription\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' > /etc/apt/sources.list.d/pbs.sources \
 && printf 'Package: proxmox-kernel* proxmox-default-kernel* pve-firmware* proxmox-firmware*\nPin: release *\nPin-Priority: -1\n' > /etc/apt/preferences.d/no-kernel \
 && apt-get update && apt-get install -y --no-install-recommends proxmox-backup-server ; echo "exit $?" > /install-status
```

## `pve-build/Dockerfile`

```dockerfile
FROM debian:trixie
LABEL sick=1
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl openssl procps \
 && curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg -o /usr/share/keyrings/proxmox-archive-keyring.gpg \
 && printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pve\nSuites: trixie\nComponents: pve-no-subscription\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' > /etc/apt/sources.list.d/pve.sources \
 && printf 'Package: proxmox-kernel* proxmox-default-kernel* pve-firmware* proxmox-firmware*\nPin: release *\nPin-Priority: -1\n' > /etc/apt/preferences.d/no-kernel \
 && apt-get update && apt-get install -y --no-install-recommends pve-manager ; echo "exit $?" > /install-status
```

## `work/pbs-start.sh`

```sh
#!/bin/sh
# run inside sick-pmx-pbs as root: start api (root) and proxy (backup) as the units do
B=/usr/lib/x86_64-linux-gnu/proxmox-backup
pgrep -f "^$B/proxmox-backup-api" >/dev/null || { nohup $B/proxmox-backup-api >>/var/log/pbs-api.log 2>&1 & }
sleep 2
pgrep -f "^$B/proxmox-backup-proxy" >/dev/null || { nohup setpriv --reuid=backup --regid=backup --init-groups $B/proxmox-backup-proxy >>/var/log/pbs-proxy.log 2>&1 & }
sleep 2
pgrep -a -f "$B/proxmox-backup-" 
```

## `work/pve-init.sh`

```sh
#!/bin/sh
# PID 1 of sick-pmx-pve. PVE::Daemon only starts in the background when getppid()==1
# (as under systemd); otherwise "start" calls systemctl. This loop runs control
# commands as direct children of PID 1: "ID command args" written into /run/sick-ctl.
[ -e /dev/fuse ] || mknod -m 666 /dev/fuse c 10 229
rm -f /run/sick-ctl; mkfifo -m 600 /run/sick-ctl
trap 'exit 0' TERM INT
while :; do
  if read -r id cmd < /run/sick-ctl; then
    ( exec $cmd ) > /run/sick-ctl-$id.out 2>&1; echo $? > /run/sick-ctl-$id.rc
  fi
done
```

## `work/ctl.sh`

```sh
#!/bin/sh
# usage (inside sick-pmx-pve): ctl.sh command args... -> runs it as child of PID 1, waits, prints output
id=$$.$(date +%s%N)
echo "$id $*" > /run/sick-ctl
while [ ! -e /run/sick-ctl-$id.rc ]; do sleep 0.05; done
cat /run/sick-ctl-$id.out; rc=$(cat /run/sick-ctl-$id.rc); rm -f /run/sick-ctl-$id.*; exit $rc
```

## `work/systemctl-shim.sh`

```sh
#!/bin/sh
# SHIM for /usr/bin/systemctl in sick-pmx-pve (no systemd). Logs every call; maps the
# pveproxy/pvedaemon jobs to what their units' Exec* lines run, as children of PID 1.
echo "$(date +%T.%N) systemctl $*" >> /var/log/systemctl-shim.log
case "$1 $2" in
  "reload-or-restart pveproxy"|"reload pveproxy") exec /usr/local/sbin/ctl.sh /usr/bin/pveproxy restart ;;
  "reload-or-restart pvedaemon"|"reload pvedaemon") exec /usr/local/sbin/ctl.sh /usr/bin/pvedaemon restart ;;
  "start pveproxy"|"start pvedaemon") exec /usr/local/sbin/ctl.sh /usr/bin/$2 start ;;
  *) echo "systemctl shim: not handled: $*" >&2; exit 1 ;;
esac
```

## `work/mkca.sh`

```sh
#!/bin/sh
# throwaway test CA: root -> intermediate -> leaves. usage: mkca.sh DIR HOSTNAME
set -e
D=$1; H=$2; mkdir -p "$D"; cd "$D"; umask 077
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout root.key -out root.pem -days 30 -subj "/CN=SICK Trial Root" \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout int.key -out int.csr -subj "/CN=SICK Trial Intermediate" 2>/dev/null
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' > int.ext
openssl x509 -req -in int.csr -CA root.pem -CAkey root.key -CAcreateserial -days 30 -extfile int.ext -out int.pem 2>/dev/null
printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s\n' "$H" > leaf.ext
leaf() { # name keytype-args...
  n=$1; shift
  openssl req -newkey "$@" -nodes -keyout $n.key -out $n.csr -subj "/CN=$H" 2>/dev/null
  openssl x509 -req -in $n.csr -CA int.pem -CAkey int.key -CAcreateserial -days 7 -extfile leaf.ext -out $n.pem 2>/dev/null
  cat $n.pem int.pem > $n.chain.pem
  cat int.pem $n.pem > $n.revchain.pem
}
leaf rsa1 rsa:2048          # key file is PKCS#8 (OpenSSL 3 default)
openssl pkey -in rsa1.key -traditional -out rsa1.trad.key
leaf rsa2 rsa:2048
openssl pkey -in rsa2.key -traditional -out rsa2.trad.key
leaf ec1 ec -pkeyopt ec_paramgen_curve:P-256
openssl pkey -in ec1.key -traditional -out ec1.trad.key   # SEC1 "EC PRIVATE KEY"
for f in rsa1 rsa2 ec1; do printf '%s ' $f; openssl x509 -in $f.pem -noout -fingerprint -sha256; done
head -1 rsa1.key rsa1.trad.key ec1.key ec1.trad.key
```

## `work/mkbody.pl`

```perl
#!/usr/bin/perl
# usage: mkbody.pl OUT CERTFILE KEYFILE [name=jsonvalue ...]  -> JSON body file (mode 0600)
# PEM only contains base64, '-', ' ', '\n', so escaping \n and quotes is enough.
use strict; use warnings;
my ($out, $c, $k, @extra) = @ARGV;
sub slurp { local $/; open my $f, '<', $_[0] or die "$_[0]: $!"; <$f> }
sub js { my $s = shift; $s =~ s/\\/\\\\/g; $s =~ s/"/\\"/g; $s =~ s/\n/\\n/g; "\"$s\"" }
my @f;
push @f, '"certificates":' . js(slurp($c)) if $c ne '-';
push @f, '"key":' . js(slurp($k)) if $k ne '-';
for (@extra) { my ($n, $v) = split /=/, $_, 2; push @f, js($n) . ":$v" }
umask 077; open my $o, '>', $out or die; print $o '{' . join(',', @f) . '}'; close $o;
```

## `work/fp.sh`

```sh
#!/bin/sh
# usage: fp.sh HOST PORT -> sha256 fingerprint of the presented leaf (or "none")
echo | timeout 5 openssl s_client -connect "$1:$2" -servername "$1" 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' || true
```

## `work/poll.sh`

```sh
#!/bin/sh
# usage: poll.sh HOST PORT EXPECTED_FP [MAX_SECONDS] -> prints elapsed ms until presented, or TIMEOUT
start=$(date +%s%N); max=${4:-60}
while :; do
  f=$(sh /work/fp.sh "$1" "$2"); now=$(date +%s%N); ms=$(( (now-start)/1000000 ))
  [ "$f" = "$3" ] && { echo "presented after ${ms} ms"; exit 0; }
  [ $ms -gt $((max*1000)) ] && { echo "TIMEOUT after ${ms} ms (presented: ${f:-none})"; exit 1; }
  sleep 0.1
done
```

## `work/sample.sh`

```sh
#!/bin/sh
# usage: sample.sh HOST PORT SECONDS -> one line per new TLS connection: ms since start, fp prefix
start=$(date +%s%N); end=$(( $3 * 1000 ))
while :; do
  ms=$(( ($(date +%s%N)-start)/1000000 )); [ $ms -gt $end ] && break
  echo "$ms $(sh /work/fp.sh $1 $2 | cut -c1-11)"; sleep 0.2
done | awk '{ if ($2!=last) { print "  t+" $1 "ms -> " ($2==""?"(no TLS)":$2) ; last=$2; n++ } else c[$2]++ } END { print "  (" NR " samples)" }'
```

## `work/post.sh`

```sh
#!/bin/sh
# usage: post.sh BASEURL CACERT HDRFILE BODYFILE [METHOD] [content-type]
# prints status line, answer body (PEM stripped), and the time of the call. Body/secret never printed.
m=${5:-POST}; ct=${6:-application/json}
s=$(date +%s%N)
curl -sS -o /tmp/ans -D /tmp/hdr -X "$m" --cacert "$2" -H @"$3" -H "Content-Type: $ct" ${4:+--data-binary @"$4"} "$1"; rc=$?
e=$(date +%s%N)
echo "curl exit $rc, $(( (e-s)/1000000 )) ms"; head -1 /tmp/hdr
sed -E 's/-----BEGIN [A-Z ]+-----[^"]*-----END [A-Z ]+-----(\\n)?/<PEM removed>/g' /tmp/ans; echo
```

## `work/get.sh`

```sh
#!/bin/sh
# usage: get.sh URL CACERT HDRFILE -> status line + body (PEM stripped), time
s=$(date +%s%N); curl -sS -o /tmp/ans -D /tmp/hdr --cacert "$2" -H @"$3" "$1"; rc=$?
echo "curl exit $rc, $(( ($(date +%s%N)-s)/1000000 )) ms"; head -1 /tmp/hdr
sed -E 's/-----BEGIN [A-Z ]+-----[^"]*-----END [A-Z ]+-----(\\n)?/<PEM removed>/g' /tmp/ans; echo
```

## `work/pbs-neg.sh`

```sh
#!/bin/sh
# negatives against PBS; run in sick-pmx-client, cwd /work
B=https://pbs1.example.internal:8007/api2/json/nodes/localhost/certificates/custom
C=ca-pbs; CA=$C/root.pem; H=pbs1.example.internal
fp() { echo "presented now: $(sh fp.sh $H 8007 | cut -c1-23)..."; }
t() { echo; echo "### $1"; }
fp
t "wrong secret, valid body (rsa2)"; perl mkbody.pl b.json $C/rsa2.chain.pem $C/rsa2.trad.key force=true restart=true; sh post.sh $B $CA pbs-hdr-wrong.txt b.json; fp
t "token without ACL, valid body (rsa2)"; sh post.sh $B $CA pbs-hdr-noacl.txt b.json; fp
t "no force, custom cert exists (rsa2)"; perl mkbody.pl b.json $C/rsa2.chain.pem $C/rsa2.trad.key restart=true; sh post.sh $B $CA pbs-hdr.txt b.json; fp
t "force=false explicit (rsa2)"; perl mkbody.pl b.json $C/rsa2.chain.pem $C/rsa2.trad.key force=false restart=true; sh post.sh $B $CA pbs-hdr.txt b.json; fp
t "key not matching cert (rsa2 chain, rsa1 key), force"; perl mkbody.pl b.json $C/rsa2.chain.pem $C/rsa1.trad.key force=true restart=true; sh post.sh $B $CA pbs-hdr.txt b.json; fp
t "booleans as strings \"1\" (rsa2, PKCS#8 key)"; perl mkbody.pl b.json $C/rsa2.chain.pem $C/rsa2.key 'force="1"' 'restart="1"'; sh post.sh $B $CA pbs-hdr.txt b.json; fp
t "booleans as numbers 1 (rsa2, PKCS#8 key)"; perl mkbody.pl b.json $C/rsa2.chain.pem $C/rsa2.key force=1 restart=1; sh post.sh $B $CA pbs-hdr.txt b.json; fp
```

## `work/pbs-neg2.sh`

```sh
#!/bin/sh
B=https://pbs1.example.internal:8007/api2/json/nodes/localhost/certificates/custom
C=ca-pbs; CA=$C/root.pem; H=pbs1.example.internal
fp() { echo "presented now: $(sh fp.sh $H 8007 | cut -c1-23)..."; }
t() { echo; echo "### $1"; }
fp
t "from generated self-signed: rsa1 chain, PKCS#8 RSA key, no force, no restart"; perl mkbody.pl b.json $C/rsa1.chain.pem $C/rsa1.key; sh post.sh $B pbs-self2.pem pbs-hdr.txt b.json; fp
t "form-encoded body (rsa2, trad key, force=1 restart=1)"
s=$(date +%s%N); curl -sS -o /tmp/ans -D /tmp/hdr --cacert $CA -H @pbs-hdr.txt --data-urlencode certificates@$C/rsa2.chain.pem --data-urlencode key@$C/rsa2.trad.key -d force=1 -d restart=1 https://$H:8007/api2/json/nodes/localhost/certificates/custom; echo "curl exit $?, $(( ($(date +%s%N)-s)/1000000 )) ms"; head -1 /tmp/hdr; sed -E 's/-----BEGIN [A-Z ]+-----[^"]*-----END [A-Z ]+-----(\\n)?/<PEM removed>/g' /tmp/ans; echo; fp
t "EC P-256 leaf, PKCS#8 key"; perl mkbody.pl b.json $C/ec1.chain.pem $C/ec1.key force=true restart=true; sh post.sh $B $CA pbs-hdr.txt b.json; fp
echo "chain presented:"; echo | openssl s_client -connect $H:8007 -showcerts -CAfile $CA -verify_hostname $H 2>&1 | grep -E "^ *[0-9] s:|Verify return code|Peer signature type"
t "back to rsa1, then EC P-256 leaf with SEC1 (EC PRIVATE KEY) key"; perl mkbody.pl b.json $C/rsa1.chain.pem $C/rsa1.key force=true; sh post.sh $B $CA pbs-hdr.txt b.json >/dev/null; fp
perl mkbody.pl b.json $C/ec1.chain.pem $C/ec1.trad.key force=true restart=true; sh post.sh $B $CA pbs-hdr.txt b.json; fp
t "chain in wrong order (intermediate first), rsa2 + its key"; perl mkbody.pl b.json $C/rsa2.revchain.pem $C/rsa2.key force=true restart=true; sh post.sh $B $CA pbs-hdr.txt b.json; fp
echo "chain presented:"; echo | openssl s_client -connect $H:8007 -showcerts -CAfile $CA 2>&1 | grep -E "^ *[0-9] s:|Verify return code"
```

## `work/pve-neg.sh`

```sh
#!/bin/sh
# negatives against PVE; run in sick-pmx-client, cwd /work. pve-trust.pem = PVE cluster CA + test root
B=https://pve1.example.internal:8006/api2/json/nodes/pve1/certificates/custom
C=ca-pve; CA=pve-trust.pem; H=pve1.example.internal
fp() { sleep 3; echo "presented 3 s later: $(sh fp.sh $H 8006 | cut -c1-23)..."; }
t() { echo; echo "### $1"; }
echo "presented: $(sh fp.sh $H 8006 | cut -c1-23)... (rsa2=C7:46:51:5E, rsa1=AB:97:A4:5D)"
t "wrong secret (rsa1 body)"; perl mkbody.pl b.json $C/rsa1.chain.pem $C/rsa1.trad.key force=true restart=true; sh post.sh $B $CA pve-hdr-wrong.txt b.json; fp
t "token without ACL (rsa1 body)"; sh post.sh $B $CA pve-hdr-noacl.txt b.json; fp
t "no force, custom cert exists (rsa1)"; perl mkbody.pl b.json $C/rsa1.chain.pem $C/rsa1.trad.key restart=true; sh post.sh $B $CA pve-hdr.txt b.json; fp
t "key not matching (rsa1 chain, rsa2 key), force"; perl mkbody.pl b.json $C/rsa1.chain.pem $C/rsa2.trad.key force=true restart=true; sh post.sh $B $CA pve-hdr.txt b.json; fp
t "JSON true booleans, rsa1, PKCS#8 RSA key"; perl mkbody.pl b.json $C/rsa1.chain.pem $C/rsa1.key force=true restart=true; sh post.sh $B $CA pve-hdr.txt b.json; fp
t "JSON numbers 1, rsa2, trad key"; perl mkbody.pl b.json $C/rsa2.chain.pem $C/rsa2.trad.key force=1 restart=1; sh post.sh $B $CA pve-hdr.txt b.json; fp
t "form-encoded (rsa1, trad key, force=1 restart=1)"
s=$(date +%s%N); curl -sS -o /tmp/ans -D /tmp/hdr --cacert $CA -H @pve-hdr.txt --data-urlencode certificates@$C/rsa1.chain.pem --data-urlencode key@$C/rsa1.trad.key -d force=1 -d restart=1 $B; echo "curl exit $?, $(( ($(date +%s%N)-s)/1000000 )) ms"; head -1 /tmp/hdr; sed -E 's/-----BEGIN [A-Z ]+-----[^"]*-----END [A-Z ]+-----(\\n)?/<PEM removed>/g' /tmp/ans; echo; fp
t "EC P-256, PKCS#8 key"; perl mkbody.pl b.json $C/ec1.chain.pem $C/ec1.key force=true restart=true; sh post.sh $B $CA pve-hdr.txt b.json; fp
echo | openssl s_client -connect $H:8006 -showcerts -CAfile $C/root.pem -verify_hostname $H 2>&1 | grep -E "^ *[0-9] s:|Verify return code|Peer signature type"
t "rsa1 then EC P-256 with SEC1 key"; perl mkbody.pl b.json $C/rsa1.chain.pem $C/rsa1.key force=true restart=true; sh post.sh $B $CA pve-hdr.txt b.json >/dev/null; fp
perl mkbody.pl b.json $C/ec1.chain.pem $C/ec1.trad.key force=true restart=true; sh post.sh $B $CA pve-hdr.txt b.json; fp
t "chain in wrong order (intermediate first), rsa2 + its key"; perl mkbody.pl b.json $C/rsa2.revchain.pem $C/rsa2.key force=true restart=true; sh post.sh $B $CA pve-hdr.txt b.json; fp
t "no key at all (key optional, existing key file), rsa2 chain whose key differs from the stored one"; perl mkbody.pl b.json $C/rsa2.chain.pem - force=true restart=true; sh post.sh $B $CA pve-hdr.txt b.json; fp
t "leaf only, rsa1 + key"; perl mkbody.pl b.json $C/rsa1.pem $C/rsa1.key force=true restart=true; sh post.sh $B $CA pve-hdr.txt b.json; fp
echo | openssl s_client -connect $H:8006 -showcerts 2>&1 | grep -E "^ *[0-9] s:"
```

## `work/pve-neg2.sh`

```sh
#!/bin/sh
B=https://pve1.example.internal:8006/api2/json/nodes/pve1/certificates/custom; C=ca-pve; CA=pve-trust.pem; H=pve1.example.internal
echo "### no key, rsa2 chain, stored key is rsa1's, force=1"; perl mkbody.pl b.json $C/rsa2.chain.pem - force=1; sh post.sh $B $CA pve-hdr.txt b.json
echo "### no key, rsa1 chain, stored key is rsa1's, force=1 restart=1"; perl mkbody.pl b.json $C/rsa1.chain.pem - force=1 restart=1; sh post.sh $B $CA pve-hdr.txt b.json | head -2; sleep 8; echo "presented: $(sh fp.sh $H 8006 | cut -c1-11)"
echo "### leaf only rsa2 + key, force=1 restart=1"; perl mkbody.pl b.json $C/rsa2.pem $C/rsa2.key force=1 restart=1; sh post.sh $B $CA pve-hdr.txt b.json | head -2; sleep 8; echo | openssl s_client -connect $H:8006 -showcerts 2>&1 | grep -E "^ *[0-9] s:"
echo "### DELETE without restart"; sh post.sh $B $CA pve-hdr.txt "" DELETE; sleep 3; echo "presented: $(sh fp.sh $H 8006 | cut -c1-11)"
echo "### DELETE again with restart=1 (no custom files now)"; sh post.sh "$B?restart=1" $CA pve-hdr.txt "" DELETE; sh sample.sh $H 8006 9
```

## `work/pve-timing.sh`

```sh
#!/bin/sh
B=https://pve1.example.internal:8006/api2/json/nodes/pve1/certificates/custom; C=ca-pve; CA=pve-trust.pem; H=pve1.example.internal
echo "presented: $(sh fp.sh $H 8006 | cut -c1-11) (pve-ssl=1F:C0:4E:DD rsa1=AB:97:A4:5D rsa2=C7:46:51:5E)"
echo "### rsa1, no force, no custom cert yet, restart=1"; perl mkbody.pl b.json $C/rsa1.chain.pem $C/rsa1.key restart=1; sh post.sh $B $CA pve-hdr.txt b.json | head -2; sh sample.sh $H 8006 10
echo "### rsa2, force=1 restart=1"; perl mkbody.pl b.json $C/rsa2.chain.pem $C/rsa2.key force=1 restart=1; sh post.sh $B $CA pve-hdr.txt b.json | head -2; sh sample.sh $H 8006 10
echo "### rsa1, force=1, restart absent"; perl mkbody.pl b.json $C/rsa1.chain.pem $C/rsa1.key force=1; sh post.sh $B $CA pve-hdr.txt b.json | head -2; sh sample.sh $H 8006 6
```

