# SICK-Target-Proxmox House Rules

Apply to every task in this repository unless explicitly overridden. Bias: caution over speed — the other end of this code is a hypervisor or a backup server, and what travels to it is an API token and a private key. Subagents get their conventions from the skills force-loaded via `briefing.skills`; skill content is never restated here, this file is for the orchestrating agent. House style, Moo, POD and release mechanics live in `getty-perl-core`, `getty-perl-moo`, `getty-perl-pod` and `getty-perl-release-author-getty`, the Target contract in `sick-core` (installed from `../sick`, changed there), TLS and PKI practice in `ssl-tls-pki`.

## Engineering discipline

1. **Think before coding** — State assumptions; ask rather than guess. Push back when a simpler approach exists. Stop when confused; name what's unclear.
2. **A design choice of yours is not a requirement of the maintainer** — write down who decided what. He decided that this distribution exists (2026-10-11, instead of proposing a change to acme.sh first); how it is built is ours to justify.
3. **Simplicity first, surgically applied** — minimum code that solves the problem, nothing speculative; touch only what you must.
4. **Read before you write** — `docs/api-notes.md` first, then the module. A call is written from an entry there, and every entry says how it is known.
5. **Tests verify intent, not just behavior** — reproduce a bug before fixing it, leave the regression test behind. A red test is a claim: say what it asserts before you change code to turn it green.
6. **Checkpoint and fail loud** — summarize done / verified / left after each significant step. "Tests pass" says which ran and against what: the stand-in, a Proxmox in a container or VM, or a real node.
7. **Surface conflicts, don't average them** — where the code and the notes disagree, the notes are right until a new observation is written into them.

## Delegation

Depends on whether the Agent/Task tool is available to you.

- **You can spawn subagents** (orchestrating main agent): do NOT touch behavior-relevant code yourself — delegate. Your lane: coordinate, inspect, plan, review diffs, run tests, edit prose. When in doubt, delegate. Why: only the `sick-*` agents get their skills force-loaded via `briefing.skills`; you get no briefing.

  | Task | Agent |
  |---|---|
  | Implement / refactor / debug / test anything under `lib/` and `t/` | `sick-worker-proxmox` (default) |
  | Commits, `Changes`, card → done, pre-release audit | `sick-release-manager` |

- **You cannot spawn subagents** (you ARE a `sick-*` agent): the lock does not apply — work per these rules.

Behavior-relevant = everything under `lib/` and `t/`. Prose in `README.md`, `docs/` and `CLAUDE.md` is not — but `docs/api-notes.md` only ever gains what was read or observed, marked as which.

**Only `sick-release-manager` commits.** The worker leaves a commit-ready tree and hands its card to `review`; you then dispatch the release-manager.

## Coordination — karr board (always in scope)

`karr` is always in scope — just use it. State lives in `refs/karr/*` of this repo.

- `karr list --compact` / `karr board` — open work · `karr show ID` — detail
- `karr create "Title" --priority high --tags a,b --body '…'` · `karr edit ID -a "note"` · `karr move ID in-progress --claim NAME` — full surface: skill `kanban-issues-karr-coordination`

What this distribution needs from the core (`SICK::Target`, `SICK::Command`, `SICK::OpenSSL`, `SICK::Bundle`, `SICK::Temp`) is a card on the board of `../sick`, with a pointer here — never an edit over there. **Serialize board mutations when fanning out** — collect the results, then loop `karr move`/`handoff`/`sync` one after the other.

## Release and everything outward — never without permission

`dzil build` / `dzil test` are fine anytime. `dzil release` and any change to the visibility of the GitHub repository need the maintainer's explicit go-ahead — also when a plan lists them as the next step. `git push` to `origin` is allowed where the hub said so for the session at hand, and nowhere else. Nothing is proposed to acme.sh or to Proxmox under the maintainer's name.

## Public issues (GitHub) — never act without instruction

`github.com/Getty/sick-target-proxmox` is a **public tracker**. Never act on an issue there on your own initiative — not even to read it: no listing, viewing, commenting, editing, closing or creating unless explicitly told to handle a specific issue. GitHub issues are not a queue to drain; karr is the internal agent board.

## Hazards specific to this repository

Short form; the mechanisms live in `docs/api-notes.md`, in `docs/real-node-trial.md` and in the agents' own lane notes.

- **The connection to the node is verified, always** — the hooks of acme.sh switch the check off and cannot switch it back on (`../sick`, card k56); that is why this distribution exists. No option, variable or test helper turns verification off. How a fresh node is trusted before it carries a certificate of our CA is a design decision written in `docs/api-notes.md`, never "accept once".
- **The token is a secret with `Sys.Modify` on a hypervisor.** It is read from a file and goes into the request header. Never on a command line, in the environment of a child, in a log, an exception, a test name, a card or a report.
- **The private key is in the request body.** Whatever quotes a request or an answer — an error message, a debug option, a recording of the stand-in — leaves the body out.
- **A live test replaces the certificate of a real node** and restarts its proxy. Never set its variables, never run it, unless told to for a named node.
- **The stand-in is not a Proxmox.** It answers what `docs/api-notes.md` says. "Green against the stand-in" is a statement about our side; what a node does with the upload is known only where the notes say "observed", with the version.
- **Two products, two APIs.** PVE (port 8006) and PBS (port 8007) look alike and differ in the details — paths, the token header, restart behaviour, what a certificate chain may contain. Nothing is carried over from one to the other without its own entry in the notes.
- **SICK is not installed** — `PERL5LIB=../sick/lib:$PERL5LIB prove -lr t`; without it every file fails at `use`. `../sick` moving is the usual reason for a red suite here: check its log before you look for the bug in this repository.
- **An untracked file does not exist for `dzil`** — `[@Author::GETTY]` gathers tracked files only; `prove` runs the untracked test and stays green. `git add` early.
- **Docker resources carry the label `sick=1`** and are cleaned up by that label and nothing else; other people's containers run on the same host.
- **The default kubeconfig of a host is not ours** — `kubectl`, `k3d` and `helm` only with `KUBECONFIG` set to a private file.
