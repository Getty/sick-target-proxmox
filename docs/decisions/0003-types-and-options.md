# 3. Device types, modules and options

Status: decided 2026-10-11 by the session that built the distribution. Card #2.

## Decision

Two device types, one per product, because the two APIs differ in the details
(`docs/api-notes.md`) and a device list should say which one it talks to:

| `type:` | Module | Product, port |
|---|---|---|
| `proxmox-ve` | `SICK::Target::ProxmoxVE` | Proxmox VE, pveproxy, 8006 |
| `proxmox-bs` | `SICK::Target::ProxmoxBS` | Proxmox Backup Server, proxmox-backup-proxy, 8007 |

SICK compares type and module name without case and without anything that is
not a letter or digit, so `proxmoxve` and `ProxmoxVE` select the same module.
The names follow the acme.sh hooks (`proxmoxve`, `proxmoxbs`) that these types
replace.

What both share lives below `SICK::Target::Proxmox::` - a directory, so SICK
does not offer it as a device type of its own (it looks at the `.pm` files
directly below `SICK/Target/` only):

- `SICK::Target::Proxmox::Role` - the role both types consume: options,
  validation, the order of `deploy` (check key against certificate, connect
  verified, upload, report); each type supplies what differs (header scheme,
  path, node, fields, booleans).
- `SICK::Target::Proxmox::Client` - the verified HTTPS connection: trust
  anchors (decision 1), the token header, timeouts, error messages without
  header and body.

### Options

Core keys as for every device: `host`, `port`, `names`, `lifetime`, ...

| Option | Types | Required | Meaning |
|---|---|---|---|
| `token_id` | both | yes | `user@realm!tokenid`, e.g. `sick@pve!sick`; not secret |
| `token_file` | both | yes | file whose first line is the token's secret (`SICK::Config->read_secret`) |
| `node` | `proxmox-ve` | yes | the node name as in the GUI (`/nodes/<node>/...`); PBS always uses `localhost` |
| `ca` | both | one of `ca`, `fingerprint` | file or list of files with CA certificates (decision 1) |
| `fingerprint` | both | one of `ca`, `fingerprint` | SHA-256 of the node's leaf certificate, or a list; hex with or without colons, any case |

`port` has to be set: SICK's default port is 443, and these APIs listen on
8006 and 8007. The core cannot tell a port that was set from the default
(`SICK::Device` has no predicate), so the type refuses port 443 with a message
that names the right port. A card on `../sick` asks for a per-type default
port; with it the refusal goes away. (A node reached through port forwarding on
443 is the price until then.)

The token is split into `token_id` and `token_file` so that the device list
holds what is not secret and a file holds what is. The header is put together
in memory (`PVEAPIToken=<token_id>=<secret>`, `PBSAPIToken=<token_id>:<secret>`,
`docs/api-notes.md`).

`node` is not derived from `host`: a node name and a DNS name agree often, but
not by rule, and a wrong node is an upload to another cluster member (PVE
proxies a request for another node through the cluster).

## Alternatives

- **One type `proxmox` with `product: ve|bs`.** Fewer modules, but every
  difference becomes a branch, and the device list hides which API is spoken.
- **Type names `pve` / `pbs`.** Shorter, but less telling in a device list next
  to other vendors, and `pbs` means other things elsewhere.
- **The full token in one secret file.** Simpler, but then the token id - which
  an operator wants to read in the list and in messages - lives in the secret.
- **`node` defaulting to the first label of `host`.** Convenient and usually
  right; rejected because the wrong guess uploads to a different node.
