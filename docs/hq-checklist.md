# To try at HQ: proxmox-ve and proxmox-bs on real nodes

What was not possible on agent-lab: a node under systemd, a PVE cluster, a
node SICK reaches over a real network. A real PBS 4.2.8 and PVE 9.2.21 ran in
containers here (`docs/real-node-trial.md`), without systemd and without a
cluster. Each entry: what to do, what counts as passed. When an entry passes,
write the observation with the version into `docs/api-notes.md`
(`[observed PVE x.y]`, `[observed PBS x.y]`) and drop the *not tried* from the
POD; when it fails, it becomes a card.

**This replaces the certificate of a real node and restarts its proxy.** Use
a node where a broken GUI for some minutes is acceptable, with console or SSH
access to repair it (`rm /etc/pve/local/pveproxy-ssl.*; systemctl restart
pveproxy` on PVE, `proxmox-backup-manager cert update --force` on PBS).

Before you start: SICK with this distribution (image with card #62 of
`../sick`, or `PERL5LIB` with both `lib/` directories), the CA and its root
file, a device list in a scratch directory. Never run `t/90-live.t` without
naming the node to the person responsible for it.

## Setup, both products

- [ ] **Token and rights with the commands of the POD** (decision 4): PVE
      `pveum user add`, `role add SICKCertificate --privs Sys.Modify`, `user
      token add ... --privsep 1 --expire`, two `acl modify` lines on
      `/nodes/<node>`; PBS `user create`, `user generate-token`, two `acl
      update /system/certificates Admin` lines. The secret straight into a
      file (mode 0600), never into a terminal history.
      *Passed:* every command works as written; with only the token's ACL line
      the upload is refused with 403 (seen in containers, confirm).

## Proxmox VE (under systemd)

- [ ] **First upload, trusted by the cluster CA.** Copy
      `/etc/pve/pve-root-ca.pem` over SSH with a known host key; device
      `type: proxmox-ve`, `port: 8006`, `node: <node>`, `ca: [<cluster CA>,
      <our root>]`, `host` a name in the SANs of `pve-ssl.pem` (`pvenode cert
      info`). `sick run <device>`.
      *Passed:* `renewed`; `openssl s_client -connect <host>:8006 -CAfile
      <our root>` verifies; `sick check` says `ok`; pveproxy's journal shows
      one restart; the token appears in no output of SICK and in no
      `/proc/*/cmdline` on SICK's host during the run.
- [ ] **Restart time under systemd.** During the run above, sample the
      presented fingerprint every 0.2 s for 20 s after the upload answer.
      *Passed:* the new leaf is stable within `verify_timeout` (30 s); write
      the first sighting and the time it became stable into the notes
      (containers with a shim: first 1.3-1.6 s, stable after ~6 s).
- [ ] **Second run uploads nothing.** `sick run` again.
      *Passed:* `unchanged`; `/var/log/pveproxy/access.log` has no new POST
      on `certificates/custom`.
- [ ] **First upload, trusted by a pin.** On a second node (or after the way
      back): `fingerprint: <SHA-256 of pve-ssl.pem>` and `ca: <our root>`, no
      cluster CA. *Passed:* `renewed`.
- [ ] **Wrong anchor.** `ca` only our root on a node that still presents
      `pve-ssl.pem` (or a wrong pin). *Passed:* the device fails before the
      upload, the message names host, port and the presented fingerprint; the
      node's access log has **no** request from SICK's address.
- [ ] **Cluster.** In a cluster of two or more, one device per node, each with
      its own `host` and `node`. *Passed:* each node presents its own new
      certificate; the access log of each node shows the POST for itself (no
      `proxyto` through another node).
- [ ] **Way back.** Take the device out of the list;
      `curl -X DELETE -H @header-file --cacert <our root>
      'https://<host>:8006/api2/json/nodes/<node>/certificates/custom?restart=1'`
      (header file mode 0600). *Passed:* 200; after a few seconds the node
      presents `pve-ssl.pem` again (same fingerprint as before the first
      upload); the GUI works.

## Proxmox Backup Server (under systemd)

- [ ] **First upload, trusted by a pin.** Fingerprint from the dashboard
      ("Show Fingerprint") or `proxmox-backup-manager cert info`; device
      `type: proxmox-bs`, `port: 8007`, `fingerprint: <it>`, `ca: <our root>`.
      *Passed:* `renewed`; `openssl s_client -connect <host>:8007 -CAfile <our
      root>` verifies; the proxy's PID is unchanged (reload, no restart).
- [ ] **Second run uploads nothing.** *Passed:* `unchanged`, no new POST in
      `/var/log/proxmox-backup/api/access.log`.
- [ ] **Datastore clients after the change.** A `proxmox-backup-client` or a
      PVE storage entry that pinned the old fingerprint. *Passed:* written
      down what they do (they pin the fingerprint: they need the new one or
      our root) - a note for the handbook, not a property of SICK.
- [ ] **Way back.** `DELETE .../nodes/localhost/certificates/custom` as above.
      *Passed:* 200; a **new** self-signed certificate (new fingerprint) is
      presented; the GUI works.

## Not to do

- No upload with a deliberately wrong key or chain order on a real node: in
  the containers both broke the proxy at its next start (PBS) or at once
  (PVE), and SICK refuses them before the request anyway (`t/`).
