# CLAUDE.md — SICK-Target-Proxmox

Device types for SICK (`../sick`): TLS certificates for the web interface and API of
Proxmox VE nodes and Proxmox Backup Server hosts, uploaded through the API of the node
itself. Dist `SICK-Target-Proxmox`.

Why it exists: the deploy hooks `proxmoxve` and `proxmoxbs` of acme.sh send the API
token and the private key without verifying the TLS certificate of the node, and put
the token on a command line (`../sick`, card k56 and `docs/findings/device-proxmox.md`).
The maintainer decided on 2026-10-11 to build an own device type instead of proposing a
change to acme.sh first.

Build and test: `prove -lr t` (serial, no `-j`), `dzil build`. SICK has to be on
`PERL5LIB` while it is not installed: `PERL5LIB=../sick/lib:$PERL5LIB prove -lr t`.
Never `dzil release` without explicit permission. `LICENSE` is committed.

## Rules of this repo

- **`docs/api-notes.md` is the source of truth** for what the API of PVE and PBS does.
  Every entry says how it is known: read in the API schema, read in the source,
  observed against the stand-in, observed on a real node (with its version). Code that
  depends on a behaviour of the API has that behaviour written down there first.
- **Perl follows the house rules** (skills `getty-perl-core`, `getty-perl-moo`): Moo for
  classes, `Path::Tiny` for files, `JSON::MaybeXS` for JSON, and what CPAN already has is
  taken from there.
- **No secrets** in code, tests, fixtures, logs or messages. The token is read from a
  file and goes into the request header; the private key goes into the request body.
  Neither is quoted anywhere else.
- **What can leak a token or a key, or change a real node, is in
  `.claude/rules/sick-proxmox-rules.md`** (hazards): verification that is never switched
  off, the token, the body, the live test, the stand-in, PVE against PBS. Read them
  before the first change.
- `# ABSTRACT:` lines are plain ASCII; every file under `lib/` carries its own
  `our $VERSION`.

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself — the
principle is a shared house rule (skilletor bundle `getty-cpan-dist@getty`); the lanes and
this repo's hazards are in `.claude/rules/sick-proxmox-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug / test anything under `lib/` and `t/` | `sick-worker-proxmox` (default) |
| Commits, `Changes`, card → done, pre-release audit | `sick-release-manager` |

The agents carry their conventions via `briefing.skills` (see `.claude/agents/`); the main
agent delegates rather than loading them. The skills under `.claude/skills/` are installed
by skilletor (`.claude/skilletor.json`) and are changed in their source, never here —
`sick-core`, the Target contract this distribution implements, comes from `../sick`.
`ssl-tls-pki` is domain knowledge the main agent loads too, before a decision on how a
node is trusted.

## Layout

- `lib/SICK/Target/ProxmoxVE.pm`, `ProxmoxBS.pm` - the two device types (SICK finds a
  type among the `.pm` files directly below `SICK/Target/`).
- `lib/SICK/Target/Proxmox/Role.pm` - options, validation and the order of `deploy`,
  shared by both; `Proxmox/Client.pm` - the verified HTTPS connection (HTTP::Tiny on
  IO::Socket::SSL, decision 2).
- `t/lib/Test/SICK/Proxmox/StandIn.pm` - the stand-in of both APIs; its header maps
  every behaviour to its entry in `docs/api-notes.md`. `PKI.pm` makes the test CAs.
- `t/90-live.t` - the live test, skipped unless `SICK_PROXMOX_LIVE_*` is set (never set
  it unasked).
- `docs/api-notes.md`, `docs/decisions/`, `docs/real-node-trial.md`,
  `docs/hq-checklist.md`.
