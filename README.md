# SICK-Target-Proxmox

Device types for [SICK](https://github.com/Getty/sick): TLS certificates for the
web interface and API of Proxmox VE nodes and Proxmox Backup Server hosts,
uploaded through the API of the node itself, over a verified TLS connection.

| `type:` | Module | Port |
|---|---|---|
| `proxmox-ve` | `SICK::Target::ProxmoxVE` | 8006 |
| `proxmox-bs` | `SICK::Target::ProxmoxBS` | 8007 |

The node is trusted only by the roots of SICK's own CA, which the run hands
the target, and by what the device list names: CA files (`ca`, e.g. the PVE
cluster CA) or SHA-256 pins of the node's certificate (`fingerprint`, e.g.
the self-signed certificate of a fresh PBS). The roots cover a node once it
presents a certificate of SICK's CA; for the first upload a fresh node needs
`ca` or `fingerprint`. There is no way to switch verification off. The API
token is read from a file and goes into the request header only.

Without `port`, a device uses 8006 or 8007; a written `port` (also `443`, for
a node behind port forwarding) is taken as it is.

- `docs/api-notes.md` - what the APIs do, each statement with its origin
- `docs/decisions/` - why it is built this way
- `docs/real-node-trial.md` - PBS 4.2.8 and PVE 9.2.21 observed in containers
- `docs/hq-checklist.md` - what is left to try on real nodes

Tried: the unit suite against the stand-in under `t/`, and `sick run` with
both device types end to end against a real PVE 9.2.21 API and a real PBS
4.2.8 in containers, with the lab CA of SICK (`t/e2e/device-proxmox.sh`,
in the sick image of `../sick`, which carries this distribution; no systemd,
no cluster). Not tried: a node under systemd, a PVE cluster, a node
across a real network (`docs/hq-checklist.md`).
