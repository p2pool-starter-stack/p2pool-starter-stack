# Integration Testing

How Pithead is validated end-to-end against a **real Ubuntu server** running full Monero and
full Tari nodes — the runtime/integration half of our testing, and the **blocking pre-release
gate** described in [Releasing](releasing.md) (issue
[#54](https://github.com/p2pool-starter-stack/pithead/issues/54)).

Our other suites are client-side and never touch a daemon: the `pithead` shell tests stub out
`docker`/`sudo`, the compose test only checks `docker compose config` interpolation, and the
dashboard pytest mocks its clients. They prove the *code* is correct; they can't prove that a
real `apply → sync-gate → mine → status` flow works on a real host. That's what this suite is
for.

The lives under [`tests/integration/`](../tests/integration/):

| File | Role |
|---|---|
| `run.sh` | Entry point. Connects to the box (SSH or `--local`), iterates the config matrix, asserts, captures artifacts, restores. |
| `scenarios.sh` | The **declarative config matrix** — adding a case is a one-line data edit. |
| `lib.sh` | Shared helpers: target I/O (SSH/local), assertions, readiness waiters, config rendering, secret redaction. |
| `selftest.sh` | Pure-logic self-test (no server). Runs in CI on every PR. |

---

## How it works

The suite assumes the box is **already deployed and synced with miners connected** — the whole
point of a dedicated test server is that the full Monero and Tari nodes are synced once and
*reused*, so each scenario runs in minutes instead of waiting days for a chain sync.

Given that, the harness moves between matrix scenarios with non-interactive **`pithead apply
-y`**, which:

- recreates only the containers whose resolved config changed,
- **reuses the synced chain data dirs** (it never re-syncs, never re-provisions Tor), and
- **preserves secrets** (`PROXY_AUTH_TOKEN`, onion addresses).

For each scenario it writes a `config.json`, applies it, **waits on real readiness signals**
(container health, `pithead status`, dashboard sync %, miner-released) with timeouts — never a
fixed `sleep` — then runs the assertion battery below. All reads happen *on the box*
(`pithead status`/`doctor` and `curl http://127.0.0.1:8000/api/state`), so SSH and `--local`
behave identically and we never depend on resolving the box's dashboard hostname.

Before the first scenario it snapshots the box's original `config.json` and a fingerprint of
its secrets; after the run it **restores the original config** and re-applies (unless
`--keep`).

### Safety model

The test box holds real synced nodes and real keys — treat it as production-sensitive.

- **Never mutates the canonical chains.** The harness only ever writes `config.json` and lets
  `apply` recreate containers. It does not `rm -rf` data dirs. The destructive `monero.prune`
  axis (a pruned vs. full DB are different on disk) is only exercised against a *separate*
  synced data dir you pass with `--pruned-data-dir` / `--full-data-dir`; without it the case
  is reported **SKIPPED**, never run against the canonical DB.
- **No silent coverage drops.** Any scenario whose prerequisite is missing (an alt data dir, a
  remote endpoint) is logged as `SKIPPED` with the reason — it never quietly disappears.
- **Secrets hygiene.** RPC creds, the proxy token, and onion addresses are never printed.
  Secret-preservation is checked by hashing them **on the box** (`sha256sum`) and comparing the
  hash — the plaintext never crosses the wire. All captured artifacts are passed through a
  redactor.
- **Continue-on-error.** A failing assertion doesn't abort the run; the whole matrix is
  collected and summarized, with per-scenario artifacts for the failures.

---

## Provisioning the test box

A one-time setup. Target the Ubuntu LTS releases we support (22.04 / 24.04).

1. **Install and deploy Pithead** normally (see [Getting Started](getting-started.md)) and let
   it fully sync. You want the box in the steady state: all containers healthy, Monero + Tari
   synced, and at least one miner (ideally two) connected and submitting shares.
2. **Reusable synced data.** The synced `monero.data_dir` and `tari.data_dir` are the key
   enabler — they're reused across every scenario. The same synced full monerod is also what
   the `remote` scenario points at as an external node (see `--remote-monero-host`).
3. **Tools on the box:** `jq`, `curl`, `docker` (with compose v2), and `sha256sum`. The first
   three are already Pithead prerequisites; `sha256sum` ships with coreutils.
4. **Access.** Key-based SSH from wherever you run the suite (or run it on the box with
   `--local`). If Docker needs root there, use `--pithead "sudo ./pithead"`.
5. *(Optional)* A second synced data dir for the **opposite** prune mode if you want to cover
   both pruned and full in one run — see the prune axis above.

> **Runner security.** Keep the box least-privilege and network-isolated; it holds real keys.
> This is a self-hosted/manual gate, not something we run on public CI.

---

## Running it

```bash
# Whole matrix over SSH
make test-integration ARGS="--host miner@10.0.0.5 --dir pithead"

# …or directly
tests/integration/run.sh --host miner@10.0.0.5 --dir pithead

# On the box itself, plus the lifecycle + node-down failover phase
tests/integration/run.sh --local --dir /home/miner/pithead --lifecycle

# A single scenario (see --list for names)
tests/integration/run.sh --host miner@10.0.0.5 --scenario remote-main-secure-tari \
    --remote-monero-host 10.0.0.5:18081

# Cover both prune modes (needs a second synced DB)
tests/integration/run.sh --host miner@10.0.0.5 --full-data-dir /srv/monero-full
```

Useful flags (full list in `run.sh --help`):

| Flag | Purpose |
|---|---|
| `--host <user@host>` / `--local` | Drive the box over SSH, or a stack on this machine. |
| `--dir <path>` | The Pithead stack directory **on the box** — relative to the SSH login dir or absolute (default `pithead`). Avoid a literal `~`; your local shell expands it before the box sees it. |
| `--pithead <cmd>` | How to invoke pithead there (e.g. `"sudo ./pithead"`). |
| `--scenario <name>` | Run just one scenario. |
| `--workers <n>` | Miners expected online while mining (default `2`). |
| `--remote-monero-host <h>` | External node endpoint for the `remote` scenario. |
| `--pruned-data-dir` / `--full-data-dir` | Synced alt DB to enable the opposite prune mode. |
| `--lifecycle` | Also run the lifecycle + node-down failover phase. |
| `--keep` | Don't restore the original config (leave the box on the last scenario). |
| `--out <dir>` | Where to write the manifest and failure artifacts. |
| `--list` | Print the matrix and axis coverage and exit. |

The runner exits non-zero if any assertion failed.

---

## The config matrix

Every axis below changes a real runtime path. The matrix covers the realistic combinations and
guarantees **every value of every axis is exercised at least once** (the `selftest` enforces
this, and `--list` prints it).

| Axis | Values | What it exercises |
|---|---|---|
| `monero.mode` | `local` / `remote` | profile gating, RPC wiring, `status` ignoring monerod in remote mode |
| `monero.prune` | `true` (pruned) / `false` (full) | pruned vs. full display ([#32](https://github.com/p2pool-starter-stack/pithead/issues/32)), DB size |
| `monero.rpc_lan_access` | `false` (127.0.0.1) / `true` (LAN) | RPC bind address, security posture |
| `p2pool.pool` | `main` / `mini` / `nano` | `P2POOL_FLAGS`, sidechain selection |
| `xvb.enabled` | `true` / `false` | XvB tunnel/donor wiring |
| `dashboard.secure` | `true` (Caddy TLS) / `false` | Caddy config / scheme |
| `dashboard.tari_required` | `true` (blocking) / `false` | sync-gate behavior ([#35](https://github.com/p2pool-starter-stack/pithead/issues/35)/[#51](https://github.com/p2pool-starter-stack/pithead/issues/51)) |

### What each scenario asserts

- **Expected containers up, unexpected absent** — every service for that config is running and
  healthy; in `remote` mode there is **no** `monerod`.
- **`pithead status` exit code** — `0` for a healthy config.
- **Dashboard reads live state** — `/api/state` is reachable; Monero is synced (`done`);
  pruned/full display matches `monero.prune` ([#32](https://github.com/p2pool-starter-stack/pithead/issues/32)); the sidechain `pool.type` matches `p2pool.pool`.
- **End-to-end mining** — workers are online (`proxy_workers >= --workers`), stratum has
  connections, and total hashes are accumulating ([#28](https://github.com/p2pool-starter-stack/pithead/issues/28)).
- **Posture propagated** — `MONERO_RPC_BIND`, `DASHBOARD_SECURE`, `XVB_ENABLED`, and
  `TARI_REQUIRED` in `.env` match the config; the Caddyfile uses the right scheme.
- **Idempotency** — a second `apply -y` with no change is a clean no-op.
- **Secrets preserved** — the proxy token and onion addresses are unchanged across every apply.

### Lifecycle + failover (`--lifecycle`)

For one representative config:

- `restart` brings the stack back healthy (`status` → `0`).
- An `apply` that changes the sidechain recreates only the affected containers and
  **preserves secrets**; the dashboard reflects the new pool; then it's reverted.
- **Node-down failover ([#31](https://github.com/p2pool-starter-stack/pithead/issues/31)):**
  stop `monerod` → `status` returns non-zero (node down) and the dashboard rejects workers
  (stops `xmrig-proxy`) → start `monerod` → workers readmitted → `status` → `0`.

> `upgrade` (which rebuilds/pulls images) is intentionally **not** run unattended — it's slow
> and changes the bundle under test. Validate it as part of the [release](releasing.md)
> staging smoke test instead.

---

## Artifacts & triage

Each run writes a **manifest** (`results/manifest.txt`) recording exactly what was under test
— the stack `VERSION`, git revision, and `docker compose images` — so a run is reproducible.

On a scenario failure, the harness captures (redacted) to `results/<scenario>/`:
`compose-ps.txt`, `status.txt`, `doctor.txt`, `config.json`, `env.redacted.txt`,
`api-state.json`, and `logs.txt` (last 200 lines per service). The end-of-run summary lists
each failed assertion and points at these.

---

## The self-test (CI)

`tests/integration/selftest.sh` exercises the harness's pure logic — config rendering and
value typing, expectation derivation (profile gating), secret redaction, the SSH/local exec
wrapper, JSON parsing, and **matrix axis coverage** — with no server. It runs in CI on every
PR (the `shell` job) and via `make test-integration-selftest`, so the harness itself is held to
the same lint/test standard as the rest of the stack.

---

## Release gate (#44)

The live matrix is the **required, blocking pre-release gate**: a release is not promoted or
published unless it's green against the real Monero + Tari nodes. It's surfaced as `make
test-integration` and wired into the `make release` pipeline's test gate — see
[Releasing › Pre-release gate](releasing.md#pre-release-gate-54). The version tagged/published
is the exact bundle this run validated.
