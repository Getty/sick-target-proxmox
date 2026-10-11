# SICK-Target-Proxmox

Device types for [SICK](https://github.com/Getty/sick): TLS certificates for the
web interface and API of Proxmox VE nodes and Proxmox Backup Server hosts,
uploaded through the API of the node itself, over a verified TLS connection.

| `type:` | Module | Port |
|---|---|---|
| `proxmox-ve` | `SICK::Target::ProxmoxVE` | 8006 |
| `proxmox-bs` | `SICK::Target::ProxmoxBS` | 8007 |

The node is trusted only by what the device list names: CA files (`ca`, e.g.
the PVE cluster CA and the root of SICK's CA) or SHA-256 pins of the node's
certificate (`fingerprint`, e.g. the self-signed certificate of a fresh PBS).
There is no way to switch verification off. The API token is read from a file
and goes into the request header only.

- `docs/api-notes.md` - what the APIs do, each statement with its origin
- `docs/decisions/` - why it is built this way
- `docs/real-node-trial.md` - PBS 4.2.8 and PVE 9.2.21 observed in containers
- `docs/hq-checklist.md` - what is left to try on real nodes

Tried: the device types against the stand-in under `t/` only. The APIs were
observed on PBS 4.2.8 and PVE 9.2.21 in containers (no systemd, no cluster);
the device types themselves have not run against a real node yet.
