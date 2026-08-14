# AgenticDev

[![test](https://github.com/Praut-Startup-Support/AgenticDev/actions/workflows/test.yml/badge.svg)](https://github.com/Praut-Startup-Support/AgenticDev/actions/workflows/test.yml)
[![release](https://img.shields.io/github/v/release/Praut-Startup-Support/AgenticDev?include_prereleases&sort=semver)](https://github.com/Praut-Startup-Support/AgenticDev/releases)
[![licence: BSL 1.1](https://img.shields.io/badge/licence-BSL%201.1-blue)](LICENSE)
[![status: alpha](https://img.shields.io/badge/status-alpha-orange)](#)

**Self-hosted agentic development platform.** One VPS holds all data,
context, orchestration — and the agents themselves. Developers connect to
it over SSH and work in a disposable container, with instructions, scope,
and phase supplied by the server, and decisions, runs, and costs written
back to an auditable ledger. Nothing heavy is installed on their machines —
a desktop icon, and Tailscale only if you chose that mode.

🇨🇿 [Česká verze tohoto dokumentu](README.cs.md)

> **Status: alpha.** The sandbox has not yet been exercised against a real
> Docker daemon, and Tailscale Funnel has not been tested end to end. Read
> [Known limitations](#known-limitations) before you deploy this.

---

## What it actually is

Most "AI coding agent" setups put the agent on the developer's laptop and
hope for the best. AgenticDev inverts that:

- **The server supplies the working context.** Which project, which phase,
  which files are in scope, which instructions and skills the agent gets —
  all of it is composed on the server per phase and per project, not
  configured on each laptop.
- **Everything is written back.** Decisions, runs, costs, and artifacts land
  in Postgres on your own server, not in someone's chat history. The audit
  trail on top of them is append-only and hash-chained — the database
  refuses an `UPDATE`, a `DELETE`, or a `TRUNCATE` on it.
- **Onboarding is one link.** A person joins with a password, states who
  they are, and the admin gives them an account on the server with one
  command; you revoke it from the panel.

- **The agent is sandboxed.** It runs in a container with no route to the
  internet — the only path out is a proxy that allows the domains you list.
  The repository is mounted read-only and only the paths in scope are
  remounted writable, so a write outside scope fails at the kernel, not
  because the agent chose to behave.

One company = one VPS. There is no central service. We never learn that you
installed it. If you hand instances to other organizations, each one is
wholly theirs — their VPS, their admin, their data, and no account of yours
anywhere in it. Pick the domain mode for that; see
[Two ways to connect](#two-ways-to-connect).

---

## Requirements

| | |
|---|---|
| Server | Debian 12 or Ubuntu 22.04/24.04, root access. **Sized by team:** ~2.5 GB RAM for the stack plus ~1.5 GB per person working *at the same time* — the agents run here, so about 8 GB for three people |
| Network | **Either** Tailscale (nothing but the enrollment page is reachable from the internet) **or** a public domain with an A record (no third party; Caddy + Let's Encrypt). Pick at install time — see [Two ways to connect](#two-ways-to-connect) |
| Clients | macOS, Linux, or Windows. Tailscale and a desktop icon; no Docker, no WSL2 |
| Models | Each person signs in with their own subscription or API key, once, from the server |

## Two ways to connect

The installer asks which one you want. This is the one architectural choice
you make per instance, and it is a trade between security and independence.

| | **Tailscale** | **Domain** |
|---|---|---|
| Reachable from the internet | the enrollment page, nothing else | the panel, git and the API too — behind the admin password |
| Internal services (Postgres, Forgejo, MinIO) | on the tailnet only | on `127.0.0.1` only, reached through Caddy |
| TLS | issued by Tailscale for the `.ts.net` name | Let's Encrypt for your domain |
| Developer SSH login | the tailnet authenticates; nobody handles a key | ordinary SSH key, installed with `agenticdev-ctl keys add` |
| Needs a third party | yes — a Tailscale account per instance | no |
| Needs a domain with an A record | no | yes |

**Choose Tailscale** when you run the instance yourself and want the
smallest possible surface: exactly one path is exposed.

**Choose Domain** when you hand instances to other organizations. With
Tailscale, every one of them has to create a Tailscale account and click two
settings in a console you do not control (*Enable HTTPS*, *Add Funnel to
policy*). That does not scale past a couple of installs.

Whichever you pick, `BIND_ADDR` in `/srv/agenticdev/config/.env` decides
where Postgres and MinIO listen. **It must never be a public address or
`0.0.0.0`** — that puts the ledger on the internet. `agenticdev-ctl smoke`
checks it, and checks the actual listening sockets too.

**If you choose Tailscale**, set two things in the admin console first:

1. [DNS](https://login.tailscale.com/admin/dns) → *HTTPS Certificates* →
   **Enable HTTPS**. Without it the server cannot get a certificate for its
   `.ts.net` name.
2. [Access controls](https://login.tailscale.com/admin/acls) → *Funnel* →
   **Add Funnel to policy**. Without it the public enrollment page will not
   come up.

The installer checks both and tells you if either is missing.

---

## Install

Step-by-step runbook, including what to check afterwards and what to do when
it breaks: **[DEPLOY.md](DEPLOY.md)** (Czech). The short version:

### 1. Server — once

Check the machine first, then install. The preflight touches nothing; it
just tells you what would break the install.

```bash
scp tools/preflight-vps.sh root@your-vps:/root/
ssh root@your-vps 'bash /root/preflight-vps.sh'
```

Then install. The bootstrap downloads the release artifact, verifies its
checksum **and its cosign signature**, and only then runs it:

```bash
ssh -t root@your-vps 'bash <(curl -fsSL https://raw.githubusercontent.com/Praut-Startup-Support/AgenticDev/main/install.sh)'
```

The installer asks seven questions — domain, your name and email as the
instance's administrator, two passwords, model provider, and how people will
connect — and does the rest: Docker, firewall, SSH hardening, Postgres,
Forgejo, MinIO, Caddy, the control plane, daily backups. At the end it prints
the two links you hand out.

If you would rather not run anything out of a pipe, fetch the bootstrap,
read it, then run it — or skip it and drive the release artifact yourself:

```bash
curl -fLO https://github.com/Praut-Startup-Support/AgenticDev/releases/latest/download/agenticdev-install-vps.sh
curl -fLO https://github.com/Praut-Startup-Support/AgenticDev/releases/latest/download/agenticdev-install-vps.sh.sha256
sha256sum -c agenticdev-install-vps.sh.sha256

scp agenticdev-install-vps.sh root@your-vps:/root/
ssh -t root@your-vps 'bash /root/agenticdev-install-vps.sh'
```

The artifact itself refuses to run from a pipe on purpose — it has to unpack
its own payload from a file on disk.

Then verify the deployment actually works, rather than merely starts:

```bash
ssh root@your-vps 'agenticdev-ctl smoke'
```

It exercises the audit trail, enrollment, the panel, work-order issuance and
signing, and every phase's scope. Non-zero exit means something is wrong and
it says what.

Useful flags:

```bash
bash agenticdev-install-vps.sh --check      # verify the payload, touch nothing
bash agenticdev-install-vps.sh --yes        # non-interactive, reads env vars
bash agenticdev-install-vps.sh --mac-only   # regenerate the Mac installer only
```

When it finishes it prints two links:

| Link | Who | Where it works |
|---|---|---|
| **Admin panel** | you | Tailscale mode: tailnet only. Domain mode: any browser, behind the admin password |
| **Enrollment page** | your team | public internet either way |

It also names the administrator on that output — the name and email you gave
during the install become a `principal` row, so the audit trail can say who
approved a decision instead of leaving the actor blank.

You pick both passwords during the install.

If you give the instance a **public domain**, that table changes: Caddy then
serves the panel and the API on that domain too, guarded by the admin
password alone. Leave the domain empty to keep everything except enrollment
on the tailnet, which is the safer default and what the rest of this
document assumes.

### 2. People — an account each, on the server

Send the enrollment link to anyone. They open it, **give their name, surname
and email**, type the join password, and get the commands they need — in
Tailscale mode, join the tailnet and then run a thin installer; in domain
mode, just the installer. No Docker, no WSL2 — nothing heavy lands on their
machine.

They then appear in the panel under *čekají na účet*, with the exact command
to run:

```bash
agenticdev-ctl user add msvanda "Martin Švanda" martin@praut.cz
```

That creates their account on the VPS, generates their keys, registers them,
and uploads their SSH key to Forgejo. They work by clicking the icon, or:

```bash
tailscale ssh msvanda@your-vps      # Tailscale mode
ssh msvanda@your-domain             # domain mode
agenticdev
```

**In domain mode there is one extra step**, because the tailnet is no longer
doing the authenticating: the installer generates an SSH key on their machine
and prints the public half. They send you that line, and you install it:

```bash
sudo agenticdev-ctl keys add msvanda "ssh-ed25519 AAAA… msvanda@mac"
```

`agenticdev-ctl user add` already installs any key that came in with a
registration, and `agenticdev-ctl keys sync` picks up later ones. The control
plane never writes to `authorized_keys` itself — it runs in a container and
has no business reaching into `/home`.

The first time, they sign in to a model inside Pi with `/login` — their own
subscription or key. It stays in their own `~/.pi/agent` and is not shared,
so two people can work at once and each pays for their own usage.

> **An account on the VPS needs the `docker` group, and that is equivalent to
> root on that machine** — through the Docker socket you can read
> `/srv/agenticdev/config/.env`, which holds the signing key and every other
> secret. Fine for a small team that trusts itself. Do not give an account to
> anyone you would not give root.

**What is actually exposed to the internet:** exactly one path — the
enrollment page — published through [Tailscale
Funnel](https://tailscale.com/kb/1223/funnel). No public IP or domain needed.
The password is the only gate on it, so it is rate limited per IP and
globally, and locks an address out for an hour after five failures.

Everything else — the panel, git, the API — stays on your tailnet.

### 3. Admin panel

Model provider and API key, egress allowlist, both passwords, lease duration,
Tailscale keys, and SMTP are editable in the panel and take effect
immediately. Settings that need a container restart live in
`/srv/agenticdev/config/.env` and the panel shows them read-only.

Projects, tasks, a project's **active phase**, release channels, machine
revocation, and the kill switch are in there too. Switching a project's phase
is the lever that changes what an agent may write to — see below.

---

## Daily use

Click the **AgenticDev** icon — it opens a terminal on the server — or from
a shell on the VPS:

```bash
agenticdev work                 # pick a project, get a task, start a pod
agenticdev work acme            # straight to one project
agenticdev doctor               # check Docker access and model login
```

`adev` works as a shorthand for `agenticdev`.

The pod comes up with an egress proxy in front of it, a read-only context
bundle, secrets on tmpfs with a TTL, and a git checkout on a work branch.
Teardown removes all of it.

---

## How the sandbox works

`agenticdev work` runs on the VPS and brings up two containers there — not
on your machine:

```
   egress ── allowlist ──► internet
      ▲
      │  the only route out
      │
    pod ── no default route, no Docker socket, non-root, all caps dropped
      │
      └── /workspace   repo read-only, scope paths remounted rw
          /ctx         context bundle, read-only
          /run/agenticdev   token and policy, tmpfs, gone on teardown
```

Git operations that touch the network stay on the host — the agent commits
locally and never holds credentials to your repository. The launcher pushes
the work branch after the pod exits.

The harness refuses to start if the workspace root turns out to be
writable, or if the pod has no proxy configured. A misconfigured sandbox
fails loudly instead of quietly not protecting anything.

---

## How permissions work

This is the part worth understanding.

Each phase has a `scope` file listing the paths it may write to:

| Phase | Writable |
|---|---|
| discovery | `prd/**`, `docs/**` |
| design | + `design/**` |
| implementation | `src/**`, `tests/**`, ADRs |
| hardening | + `infra/**` |
| delivery | `docs/**`, README, CHANGELOG |
| support | `src/**`, `tests/**`, `docs/**`, ADRs |

The control plane sends that list to the launcher, which mounts the
repository read-only and remounts exactly those paths writable. So changing
what an agent may do during design means editing
`workspace/_phase/design/scope` — not editing a user, and not trusting the
agent to respect a rule.

`control-plane/app/workspace.py` also merges `.pi/settings.json` across the
base and phase layers, and chains `AGENTS.md` — but those carry
instructions, not the boundary. The boundary is the mount.

The same file pins the model for everyone via `enabledModels`, so two people
on different subscriptions run the same agent and only the bill differs. If
someone's subscription cannot serve that model, Pi says so and stops — a
silent substitution would be exactly the kind of degradation this design
refuses.

## Seeing what happened

There is no metrics stack. What there is, is a record you can read after the
fact — which is what you need to tune the thing:

| Where | What is in it |
|---|---|
| `event` table | append-only, hash-chained audit trail; the database refuses `UPDATE`, `DELETE` and `TRUNCATE` on it |
| `agent_run` table | one row per run: role, model, duration, outcome, transcript path. Written by the harness when the run ends |
| `/trees/.transcripts/*.log` | the full transcript of an automated run — every prompt, the agent's output, and the **complete** output of each failed check (the agent's prompt only gets the last 25 lines). Lives in the person's home on the VPS, so pod teardown cannot reach it |
| Panel → Úkoly → click a task | the timeline: events, runs and decisions merged in order |
| `git notes` + `Task-Id:` trailer | which session produced a given line — `agenticdev-git who src/a.ts 42` |

Interactive sessions keep their own transcript: Pi writes it to that
person's `~/.pi/agent`, which survives teardown too. A run with no assigned
task is not recorded at all — `agent_run.task_id` is `NOT NULL` — and the
harness says so on screen rather than failing quietly.

## What the three requirements actually rest on

Nothing on a laptop to configure or approve; one git process for the whole
company, automated for people who don't know git; the same agent for
everyone regardless of subscription. Which piece of code enforces each of
those, and the command that proves it on a live instance, is in
[docs/tri-pozadavky.md](docs/tri-pozadavky.md) (Czech).

---

## Where to change things

| I want to… | Edit |
|---|---|
| change what an agent may do in a phase | `workspace/_phase/<phase>/scope` |
| add a phase | `workspace/_phase/<new>/`, then `make verify` |
| change instructions for all projects | `workspace/_base/AGENTS.md` |
| add a service on the server | `vps/docker-compose.yml` and `vps/Caddyfile` |
| change the database schema | `vps/sql/001_schema.sql` — as a migration, not a rewrite |
| change what the harness enforces | `pod/harness/harness.py` |

---

## Building from source

The release artifact is a self-extracting script built from this repository.
You can build and verify it yourself:

```bash
make verify     # check that every path the tree promises actually exists
make dist       # build dist/agenticdev-install-vps.sh and its checksum
make check-dist # run the built artifact's own --check
make preflight  # check a fresh VPS before installing
make smoke      # verify a deployment end to end (run on the VPS)
```

`make dist` is deterministic: building the same commit twice produces the
same checksum.

---

## Known limitations

Honest status. These are tracked as blockers to 1.0:

- **The merge gate has never run against a live Forgejo.** The runner, the
  seeded workflow, branch protection and the webhook that sets `done` on
  merge are all in place, and `agenticdev-ctl gate <project>` now measures
  whether the required commit-status names match the ones Forgejo actually
  emits — the one thing that cannot be read off the code. Run it on your
  first PR. Until you see a red check block a merge, assume nothing.
- **A repository with no tests passes the gate green.** The workflow says so
  in the log as a warning. An empty gate is not a gate.
- **No metrics or tracing.** Grafana, Loki, Prometheus and Tempo are
  commented out in the compose file. What you do get is the ledger, a
  per-run record, a transcript file per run, and a per-task timeline in the
  panel — see [Seeing what happened](#seeing-what-happened).
- **Join tokens never expire** and are per-instance, not per-person.
- **Cost is not measured, and the panel says so.** Each run records its
  model, duration, outcome and transcript, but nothing reports token counts
  — so `cost_czk` stays 0 and the panel shows "útrata se neměří" rather
  than `0 Kč`, which would read as free. Wiring real numbers needs usage
  data out of the harness's model client. (The `len/3` estimate is the
  context-size budget gate, not spend; there is no `PRICING` table.)
- **The runner is root-equivalent.** It needs the Docker socket to run
  jobs, and it runs on the same machine as the database and the signing
  key. Anyone who can push a workflow to a project repo can read them.
- **The orchestration layer (directors) does not exist** in the form the
  architecture document describes — no signed, separately versioned
  packages with release channels. What runs is `pod/harness/director.py`:
  the task's progression is enforced by the project's own checks inside the
  harness ([ADR-0003](docs/adr/0003-postup-ukolu-vynucuje-harness.md)).
- **Container escape is out of scope.** The pod drops all capabilities,
  runs non-root, and has no Docker socket — but a container is not a
  hypervisor. Treat it as a strong fence, not a vault.

See [SECURITY.md](SECURITY.md) for the security implications.

---

## Licence

**Business Source License 1.1** — source-available, not OSI open source.

Free for evaluation, development, education, and production use at
organizations under **EUR 1,000,000** annual revenue, **provided you keep the
attribution** “AgenticDev — © Praut s.r.o.” in the admin interface, in the
docs you ship, and in the source headers. Larger organizations need a
commercial licence. Every version converts to **Apache-2.0 four years after
release**.

Plain-language explanation in both languages: [LICENSE-FAQ.md](LICENSE-FAQ.md).
Binding text: [LICENSE](LICENSE).

Commercial licensing: **svanda@praut.cz**

© 2026 Praut s.r.o.

---

## Website

A one-page site lives in [`site/`](site/) and deploys to GitHub Pages.
See [site/README.md](site/README.md) for the two things to fill in before
it goes live.

---

## Publishing your own fork

See [PUBLISHING.md](PUBLISHING.md) — placeholders to fill in, release
process, and a test checklist.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Contributions require a CLA, because
the project is dual-licensed and we cannot sell commercial licences for code
we do not hold the rights to.

- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) — one rule and a few examples
- [SUPPORT.md](SUPPORT.md) — where to take a question, a bug, or a hole
- [CHANGELOG.md](CHANGELOG.md) — what changed and when
