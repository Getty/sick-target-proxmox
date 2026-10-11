# 4. The smallest right of the token, and the way back

Status: decided 2026-10-11 by the session that built the distribution. Card #2.
Every fact below is in `docs/api-notes.md` with its origin; the commands were
read in the sources and manuals and **not run**.

## Decision

### What the target calls

Only the upload: `POST /api2/json/nodes/<node>/certificates/custom` (PVE with
the node name, PBS with `localhost`). No `GET .../certificates/info` first:

- on PBS it needs the same right as the upload, so it would not make the
  token smaller, and it reports the file, not what the proxy serves;
- whether an upload is needed is decided by SICK from the certificate the
  port presents (`presented_cert`), which needs no token at all.

So a run that finds the node up to date sends no token. The token travels
only when there is a certificate to upload.

### PVE

`Sys.Modify` on `/nodes/<node>` is the only privilege that allows the upload;
only the built-in `Administrator` holds it, so a custom role with nothing else
is the smallest. It is still wide: on that node it also covers services,
network, DNS, hosts, time, APT, firewall, subscription and ACME. One token per
node keeps the damage to one node.

```
pveum user add sick@pve --comment 'SICK certificate upload'
pveum role add SICKCertificate --privs Sys.Modify
pveum user token add sick@pve sick --privsep 1 --expire <epoch> --comment 'SICK'
pveum acl modify /nodes/pve1 --roles SICKCertificate --users sick@pve
pveum acl modify /nodes/pve1 --roles SICKCertificate --tokens 'sick@pve!sick'
```

The user lives in the `pve` realm without a password, so it cannot log in. The
token is privilege-separated (`--privsep 1`): it has the intersection of its
own ACL and its user's, hence both ACL lines. `--expire` forces a rotation.

### PBS

`Sys.Modify` on `/system/certificates`. PBS has fixed roles and only `Admin`
holds `Sys.Modify`; there is no custom role. On that path `Admin` also covers
the ACME accounts and plugins, including reading the DNS plugin credentials.
Narrow path, wide role on it.

```
proxmox-backup-manager user create sick@pbs --comment 'SICK certificate upload'
proxmox-backup-manager user generate-token sick@pbs sick --expire <epoch> --comment 'SICK'
proxmox-backup-manager acl update /system/certificates Admin --auth-id sick@pbs
proxmox-backup-manager acl update /system/certificates Admin --auth-id 'sick@pbs!sick'
```

Tokens on PBS are always privilege-separated; both ACL lines are needed.

### Where the secret lives

`token_file`: one line, mode 0600, read with `SICK::Config->read_secret`.
The target puts it into the `Authorization` header in memory and nowhere else.

### The way back

1. Take the device out of the device list first, or the next run uploads
   again.
2. Delete the custom certificate:
   - **PVE**: GUI (node, System, Certificates, "Delete custom certificate"),
     or `DELETE /api2/json/nodes/<node>/certificates/custom?restart=1` -
     parameters in the query string, a body is refused. pveproxy falls back
     to `pve-ssl.pem` of the cluster CA. A DELETE without a custom
     certificate answers 200.
   - **PBS**: `DELETE /api2/json/nodes/localhost/certificates/custom`. PBS
     makes a **new** self-signed certificate with a new key and reloads; its
     fingerprint is new.
3. Remove the token and the ACL lines (`pveum user token remove`,
   `proxmox-backup-manager user delete-token`), and the user.

The distribution does not offer the DELETE as a command: it is a one-off by
the operator with the GUI or with `curl -H @header-file` (the header from a
file, never on the command line), documented in the POD. A `sick` command for
it would need a core change and a second right for a rare step.

## Alternatives

- **`GET info` before the upload to skip needless uploads.** Rejected: SICK
  already knows from the port, and the call would put the token on the wire on
  every run.
- **PVE `Administrator` or `PVEAdmin`.** `PVEAdmin` lacks `Sys.Modify`;
  `Administrator` is everything. Rejected.
- **A user with password and ticket login instead of a token.** A password is
  a wider secret (GUI login), needs a CSRF token and a second call. Rejected.
- **One token for all nodes of a cluster (ACL on `/nodes`).** Fewer secrets,
  one leak reaches every node. Allowed by the type (it does not check), not
  recommended.
