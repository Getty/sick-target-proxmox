# CLAUDE.md — SICK-Target-Proxmox

Device types for SICK (`../sick`): TLS certificates for the web interface and API of
Proxmox VE nodes and Proxmox Backup Server hosts, uploaded through the API of the node
itself. Dist `SICK-Target-Proxmox`. What the APIs do is in `docs/api-notes.md`, the design
in `docs/decisions/`; the family's handbook is in `../sick/docs/handbook/`.

Why it exists: the deploy hooks `proxmoxve` and `proxmoxbs` of acme.sh send the API token
and the private key without verifying the TLS certificate of the node, and put the token
on a command line (`../sick`, card k56 and `docs/findings/device-proxmox.md`).

Build and test: `prove -lr t` (serial, no `-j`), `dzil build`. The core comes from the
checkout beside this one: `PERL5LIB=../sick/lib:$PERL5LIB prove -lr t`. Never
`dzil release` without explicit permission. `LICENSE` is committed.

The repository's decisions and hazards are in `.claude/rules/sick-proxmox-rules.md`; read
the hazards before the first change — what travels to a node is a token and a private key.

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself —
principle in the shared rule `getty-agent-delegation` (skilletor bundle
`getty-cpan-dist@getty`), lanes in `.claude/rules/sick-proxmox-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug / test anything under `lib/` and `t/` | `sick-worker-proxmox` (default) |
| Commits, `Changes`, card → done, pre-release audit | `sick-release-manager` |
| Route a card to another repository of the family | `karr-coordinator` |
| Read-only research, audit, gap analysis | `sick-worker-proxmox` ("read-only, change nothing") |

Every subagent is one of these agents — never the built-in `general-purpose`/`Explore`/`Plan`.

The agents carry their skills via `briefing.skills` (see `.claude/agents/`); the main agent
delegates rather than loading them. Everything under `.claude/skills/` and the agent
`karr-coordinator` are installed by skilletor (`.claude/skilletor.json`) and changed in
their source, never here — `sick-core` (the Target contract) and `sick-coordination` (who
owns what in the family) come from `../sick`. `ssl-tls-pki` is domain knowledge the main
agent loads too, before a decision on how a node is trusted.

## Layout

```
lib/SICK/Target/ProxmoxVE.pm, ProxmoxBS.pm  the two device types (SICK finds a type among the .pm files directly below SICK/Target/)
lib/SICK/Target/Proxmox/Role.pm             options, validation and the order of deploy, shared by both
lib/SICK/Target/Proxmox/Client.pm           the verified HTTPS connection (HTTP::Tiny on IO::Socket::SSL, decision 0002)
t/lib/Test/SICK/Proxmox/StandIn.pm          the stand-in of both APIs; its header maps every behaviour to docs/api-notes.md
t/lib/Test/SICK/Proxmox/PKI.pm              the test CAs
t/90-live.t                                 the live test, skipped unless SICK_PROXMOX_LIVE_* is set (never set it unasked)
t/e2e/                                      a real PVE/PBS API in a container, run from the sick image
docs/api-notes.md, docs/decisions/, docs/real-node-trial.md, docs/hq-checklist.md
```
