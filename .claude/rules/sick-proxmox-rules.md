# SICK-Target-Proxmox House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs. Bias:
caution — the other end of this code is a hypervisor or a backup server, and what travels to
it is an API token and a private key.

## What this repo is

SICK device types for the web interface and API of Proxmox VE nodes and Proxmox Backup Server
hosts, uploaded through the API of the node itself. Read first: `docs/api-notes.md`, then the
module. A call is written from an entry there, and every entry says how it is known; where
the code and the notes disagree, the notes are right until a new observation is written into
them.

## Decisions of this repo

- **This distribution exists on the maintainer's word** (2026-10-11, instead of proposing a
  change to acme.sh first); how it is built is ours to justify, in `docs/decisions/`.
- **Perl follows the house stack** (`getty-perl-core`, `getty-perl-moo`): Moo, `Path::Tiny`,
  `JSON::MaybeXS`; one module per device type directly below `SICK/Target/`, what they
  share in a role.
- **`# ABSTRACT:` lines are plain ASCII**; every file under `lib/` carries its own `our $VERSION`.

## Agent team

| Task | Agent |
|---|---|
| Implement / refactor / debug / test anything under `lib/` and `t/` | `sick-worker-proxmox` (default) |
| Commits, `Changes`, card → done, pre-release audit | `sick-release-manager` |
| Route a card to another repository of the family | `karr-coordinator` |
| Read-only research, audit, gap analysis | `sick-worker-proxmox` ("read-only, change nothing") |

Behavior-relevant = everything under `lib/` and `t/`. Prose in `README.md`, `docs/` and
`CLAUDE.md` is not — but `docs/api-notes.md` only ever gains what was read or observed, marked
as which.

What this distribution needs from the core is a card on the board of `../sick`, with a
pointer here — never an edit over there (`sick-coordination`). The Target contract lives in
`sick-core`; both skills and `karr-coordinator` are installed from `../sick`, changed there.

## Release

Any change to the visibility of the GitHub repository is under the publish gate too. Nothing
is proposed to acme.sh or to Proxmox under the maintainer's name.

## Hazards

Short form; the mechanisms live in `docs/api-notes.md`, in `docs/real-node-trial.md` and in
the agents' own lane notes.

- **The connection to the node is verified, always** — the hooks of acme.sh switch the check off and cannot switch it back on (`../sick`, card k56); that is why this distribution exists. No option, variable or test helper turns verification off. How a fresh node is trusted before it carries a certificate of our CA is a design decision written in `docs/api-notes.md`, never "accept once".
- **The token is a secret with `Sys.Modify` on a hypervisor.** It is read from a file and goes into the request header. Never on a command line, in the environment of a child, in a log, an exception, a test name, a card or a report.
- **The private key is in the request body.** Whatever quotes a request or an answer — an error message, a debug option, a recording of the stand-in — leaves the body out.
- **A live test replaces the certificate of a real node** and restarts its proxy. Never set its variables, never run it, unless told to for a named node.
- **The stand-in is not a Proxmox.** It answers what `docs/api-notes.md` says. "Green against the stand-in" is a statement about our side; what a node does with the upload is known only where the notes say "observed", with the version. "Tests pass" says which ran and against what: the stand-in, a Proxmox in a container or VM, or a real node.
- **Two products, two APIs.** PVE (port 8006) and PBS (port 8007) look alike and differ in the details — paths, the token header, restart behaviour, what a certificate chain may contain. Nothing is carried over from one to the other without its own entry in the notes.
- **SICK comes from `../sick`** — `PERL5LIB=../sick/lib:$PERL5LIB prove -lr t`; without it every file fails at `use`. `../sick` moving is the usual reason for a red suite here: check its log before you look for the bug in this repository.
- **An untracked file does not exist for `dzil`** — `[@Author::GETTY]` gathers tracked files only; `prove` runs the untracked test and stays green. `git add` early.
- **Docker resources carry the label `sick=1`** and are cleaned up by that label and nothing else; other people's containers run on the same host.
- **The default kubeconfig of a host is not ours** — `kubectl`, `k3d` and `helm` only with `KUBECONFIG` set to a private file.

## Perl specifics — reference, don't restate

House style, Moo, POD and release mechanics live in `getty-perl-core`, `getty-perl-moo`,
`getty-perl-pod` and `getty-perl-release-author-getty`; TLS and PKI practice in `ssl-tls-pki`;
`.claude/agents/` defines which agent briefs which.
