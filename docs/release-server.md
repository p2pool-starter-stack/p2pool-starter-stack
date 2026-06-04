# The Release / Validation Server

How we validate a build **end-to-end before release**, why that needs a dedicated server, what
GitHub Actions does for free on every PR, and how to harden the server so it can't become a
liability. This is the operational companion to [Releasing](releasing.md) (the version/promote
pipeline) and [Integration Testing](integration-testing.md) (the harness it runs).

## Can GitHub Actions do the full end-to-end? (short answer: no — and that's fine)

**GitHub-hosted runners can't do the real-chain tier.** On a public repo the hosted Ubuntu
runners are generous and **free** (4 vCPU / 16 GiB RAM), but they are **ephemeral** — a fresh VM
per job, ~14 GiB of free disk, and a 6-hour job ceiling. A Monero chain is ~95 GiB pruned /
~270 GiB full and takes **days** to sync; Tari adds ~50 GiB. There is nowhere to keep that
synced state between runs, and no time to sync it inside a job. So the **real-daemon, real
merge-mining tier (tier 4) is simply not possible on hosted runners** — which is the whole
reason a dedicated, already-synced server exists ([#54](https://github.com/p2pool-starter-stack/pithead/issues/54)).

**But GitHub already runs almost everything else, free, on every PR.** Tiers 1–3 of the
[testing strategy](testing-strategy.md) need no real chain and run on the hosted runners in
minutes:

- **Tier 1 — unit/component** (dashboard pytest + coverage gate, frontend, the `pithead` shell
  suite, compose interpolation **and the #90 security/hardening invariants**).
- **Tier 2 — contract** (the real Monero/Tari clients vs. controllable fakes).
- **Tier 3 — the fake-daemon mini-stack** (the **real** dashboard + docker-control proxy driven
  against fake daemons, with **real Docker** on the hosted runner) — this proves the control
  plane end-to-end (sync hold/release, reject/readmit) on every PR.

So the split is clean:

| | Runs | Cost | Triggered |
|---|---|---|---|
| **Tiers 1–3** (logic, wiring, control plane, hardening) | GitHub-hosted runners | free (public repo) | **every PR** — the merge gate |
| **Tier 4** (real synced Monero+Tari, real merge-mining, prune/full DB, TLS/Tor, the config matrix, the staging smoke test) | the **dedicated server** | your hardware | pre-release / on-demand — the **release gate** |

The hosted runners catch the vast majority of regressions before merge; the dedicated server
proves the things only reality can — and it's the **blocking pre-release gate**.

## Validating PRs on the dedicated server — possible, but security-loaded

You *can* register the server as a GitHub Actions **self-hosted runner** so Actions dispatches
the tier-4 job to it (self-hosted minutes don't count against anything — also free). But there
is a sharp edge, and it's the single most important thing on this page:

> **GitHub explicitly recommends against self-hosted runners on public repositories.** Any user
> can open a pull request, and a malicious PR can run **arbitrary code on the runner**. Our
> server holds real **wallet payout addresses, Tor onion private keys, and RPC credentials**, so
> a compromised runner is a key-theft / persistent-backdoor event, not a flaky build.

The safe rule: **the keyed server only ever runs code we trust.** Concretely:

- **Do NOT trigger tier-4 on `pull_request`** (and never on a fork PR). "Require approval" only
  gates *starting* the run — once it starts, the PR's code still executes on the box.
- **Trigger tier-4 only on trusted code:** `workflow_dispatch` (a maintainer manually runs it on
  a ref they've reviewed) and/or `push` to `main` (post-merge). To E2E a specific fork PR, a
  maintainer reviews it first, then dispatches the workflow on that ref.
- Register the runner as **ephemeral / just-in-time** (one job, then auto-removed) in its own
  **runner group**, isolated from any private repos.
- Keep the runner **least-privilege**: a dedicated unprivileged user, the box runs nothing else
  sensitive, and ideally the runner can reach the stack only through `pithead`/`docker`, not the
  raw key files.

This is exactly how the workflow ships:
[`.github/workflows/release-gate.yml`](../.github/workflows/release-gate.yml) runs **only** on
`workflow_dispatch` (and `push` to `main`) on a `[self-hosted, pithead-release]` runner — never
automatically on a PR.

## Provisioning the server

Target an LTS Ubuntu (22.04 / 24.04). One-time:

1. **Install Pithead and let it fully sync** ([Getting Started](getting-started.md)) — full
   Monero + full Tari, all containers healthy, a worker (ideally two) mining. The synced
   `monero.data_dir` / `tari.data_dir` are the asset the harness reuses.
2. **Put the chains on a snapshot/reflink-capable filesystem** — **btrfs**, **zfs**, or
   **xfs (reflink=1)**. The pruned-vs-full axis needs two different DBs; on a CoW filesystem the
   harness can snapshot/restore the canonical chain cheaply instead of copying ~270 GiB (or
   skipping the axis). On ext4 the prune axis must copy the DB or be skipped — everything else in
   the matrix (which only changes `config.json` and reuses one chain) still works.
3. **Disk headroom** — enough for the chains plus a snapshot / second DB (budget ≥ ~150 GiB
   free beyond the live chains).
4. **Tools** — `jq`, `curl`, `docker` (compose v2), `sha256sum`, `git`, `tar`.

Check the box is fit at any time, **non-destructively**:

```bash
tests/integration/run.sh --host you@server --dir pithead --readiness
```

It asserts: chains synced (reusable), the chain filesystem is snapshot-capable, disk headroom,
`.env` is owner-only, the dashboard is bound to localhost, and the backup/rollback net is usable.

## Hardening checklist (the pitfalls)

Treat the box as **production-sensitive** — it holds keys *and* it's the thing that signs off
releases.

- **Secrets.** `.env` (RPC creds), `config.json` (wallet addresses), and the Tor data dir
  (onion private keys) must be **owner-only** (`chmod 600 .env`; the `--readiness` check verifies
  this). Never print secrets in logs; the harness hashes them on the box and redacts artifacts.
  If the box also *publishes* releases, the GHCR token lives in the environment / a secret store,
  never in the repo.
- **Network.** Firewall to least exposure: inbound **SSH** (key-only, no root login, fail2ban)
  and the **stratum** port scoped to the LAN ([workers › firewall](workers.md#firewall)); the
  **dashboard stays on localhost behind Caddy** and the **monerod RPC on localhost** (both
  asserted by `--readiness`). Nothing else should be reachable from the internet.
- **Untrusted code.** The runner only runs trusted code (see above). Prefer ephemeral/JIT
  runners; don't share the runner with private repos.
- **Least privilege.** A dedicated unprivileged user; the stack already runs least-privilege
  containers (`no-new-privileges`, `cap_drop`, read-only roots, scoped Docker socket proxies —
  regression-guarded in `tests/stack/test_compose.sh`).
- **Reproducible, clean baseline.** The matrix reuses the synced chains and never mutates the
  canonical copies (config-only changes, snapshot/restore for the prune axis), restores the
  original `config.json` at the end, and `--safety-backup` takes a `pithead backup` first and
  **rolls the box back** (down → restore → up) if anything fails.
- **Build isolation & integrity.** Build images in containers with pinned upstream versions and
  SHA256-verified binaries (the stack already does this); promote releases **by digest** so the
  published bundle is bit-for-bit what was validated ([Releasing](releasing.md)).

## How a release is validated end-to-end

1. **Every PR** → GitHub-hosted runners run tiers 1–3 (the merge gate). Cheap, free, fast.
2. **Pre-release (or on-demand for a reviewed PR)** → a maintainer dispatches the release-gate
   workflow on the dedicated server: `make test` (tiers 1–2 on the trusted box) **+** the tier-4
   live matrix against the real synced nodes (`run.sh --safety-backup`), then — per
   [Releasing](releasing.md) — the staging smoke test (pull the GHCR images on a clean host,
   real `setup → up → status → mine` check).
3. **Nothing is tagged or published until that's green**, and promotion is by digest, so the
   version users get is the exact bundle the server validated.
