# 1. How the target trusts a node

Status: decided 2026-10-11 by the session that built the distribution (not by
the maintainer; the maintainer decided that the distribution exists, see
`CLAUDE.md`). Card #2.

## Context

The device type sends two secrets to the node: the API token (header) and the
private key of the new certificate (body). The acme.sh hooks send both over a
connection they do not verify, and nothing can make them verify (`../sick`,
card k56, `docs/findings/device-proxmox.md`). That gap is the reason this
distribution exists.

The node does not carry a certificate of our CA before the first upload:

- **PVE** presents `pve-ssl.pem`, signed by the cluster's own CA
  (`/etc/pve/pve-root-ca.pem`), with the node name, `<node>.<search domain>`
  and the cluster address as SANs; see `docs/api-notes.md`. A name SICK uses
  that is not among them does not verify against the cluster CA.
- **PBS** presents a self-signed `proxy.pem` made at installation; the
  administrator sees its SHA-256 fingerprint in the dashboard and with
  `proxmox-backup-manager cert info`, and Proxmox's own clients pin exactly
  that fingerprint (see `docs/api-notes.md`).

After the first upload the node presents a certificate of our CA. When our
root is replaced, a node still presents a certificate of the old root until
it is renewed.

`SICK::Target::deploy` gets the bundle, not the root of the issuer: the target
cannot ask the run for our root (a card on `../sick` asks for it, see below).

## Decision

**A node is trusted by anchors the operator names in the device list, and by
nothing else.** Two kinds, any number of each, at least one in total:

- `ca` - one file or a list of files with CA certificates (PEM, one or more
  per file). The certificate of the node has to chain up to one of them, and
  its names have to match `host` of the device (host name check as for
  HTTPS: DNS SAN, or IP SAN for an address).
- `fingerprint` - one SHA-256 fingerprint or a list, of the leaf certificate
  the node presents. A match is enough on its own; the host name is not
  checked for a pinned certificate (the pin names that one certificate).

A connection is used for a request only after the handshake has passed one of
the two. The check happens on the connection that then carries the token: no
probe first and a second connection afterwards. A node that passes neither
gets nothing: no request, no header, no body; the device fails with a message
that names the host, the port and the fingerprint the node presented (public),
and says which anchors were tried (paths and fingerprints, also public).

There is **no switch to turn the check off**, no "accept once", no "trust on
first use", no fallback to the system's trust store, and no environment
variable that changes any of this - in tests either.

### The life of a device

1. **First upload, PVE.** `ca` names a copy of `/etc/pve/pve-root-ca.pem`
   (public; copied by the operator over a path they trust, e.g. `scp` with a
   known host key, or read from the GUI) and our root. Alternatively
   `fingerprint` pins the presented `pve-ssl.pem` (shown in the GUI under
   node, System, Certificates).
2. **First upload, PBS.** `fingerprint` pins the presented self-signed
   certificate (dashboard, "Show Fingerprint", or `proxmox-backup-manager
   cert info` on the host), and `ca` names our root.
3. **Afterwards** the node presents our certificate; our root in `ca` is what
   matches. A pin of step 1 or 2 is then stale. On PBS the pinned certificate
   is gone: the upload overwrites `proxy.pem` and `proxy.key`. On PVE
   `pve-ssl.pem` stays on disk as the fallback and is renewed by `pveupdate`
   within 14 days of its end, which also breaks a pin on it - for PVE the
   cluster CA is the better first anchor (`docs/api-notes.md`). A stale pin
   is one anchor too many; the operator removes it after the first run, and
   the POD says so.
4. **Root rollover.** During the overlap, `ca` names the old and the new root
   (the files SICK publishes as additional roots). A node renewed under the
   new root matches the new one, a node not yet renewed the old one. The old
   root leaves `ca` when every node presents the new hierarchy.
5. **Way back** (`DELETE .../certificates/custom`, see decision 4): PVE
   presents `pve-ssl.pem` again - trusted again only through the cluster CA
   or a pin, not through our root. PBS makes a **new** self-signed
   certificate with a new key: the old pin does not match it, a new one has
   to be read off the dashboard.

## Alternatives

- **Trust on first use / "accept once".** Rejected: the first connection
  carries the token and the key, exactly the case an attacker in the path
  wants. The house rules forbid it.
- **Only a CA file.** Not enough for PBS: a self-signed `proxy.pem` as a CA
  file works with OpenSSL only when it is a usable trust anchor (its names and
  extensions decide), and the operator has to copy a PEM instead of a
  fingerprint they can read off the dashboard. The pin is Proxmox's own
  idiom for PBS.
- **Only a fingerprint.** Every renewal changes the fingerprint; the pin would
  have to be updated after every run. Rejected for the steady state.
- **Fetch the cluster CA from the node.** Circular: it comes over the
  connection whose identity is in question.
- **Get our root from the issuer automatically.** The right steady state, but
  `deploy` does not see the issuer's root today. Asked of the core as a card
  on `../sick` (hand the root and the additional roots to the target); until
  then `ca` names it. When it exists, our root becomes an implicit anchor and
  `ca` is only needed for the cluster CA.
- **The system trust store.** Not ours to rely on: an unrelated public CA
  would then be able to vouch for a hypervisor. Rejected.
- **SSH to the node and copy the files.** A different trust model (host keys,
  root login on the hypervisor) and a different right; out of scope.

## Consequences

- A device of these types without `ca` and without `fingerprint` is an error
  of the device list (`validate`), before anything is issued.
- The first run of a fresh node needs one manual step from the operator: copy
  the cluster CA or read a fingerprint. This is the authenticated bootstrap;
  it cannot be automated without a channel that is already trusted.
- `presented_cert` stays the core's (`openssl s_client`, no token): the check
  of a run only reads the certificate and sends no secret. A node that
  presents an untrusted certificate is judged `foreign-ca`, renewed, and then
  fails in `deploy` before the first byte of a request - the issued
  certificate is not used.
