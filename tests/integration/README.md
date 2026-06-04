# Integration tests (`tests/integration/`)

End-to-end suite that drives a **real, already-provisioned Pithead server** through the
config matrix and asserts the stack behaves (issue
[#54](https://github.com/p2pool-starter-stack/pithead/issues/54)).

```
run.sh         entry point — connects (SSH or --local) and runs the matrix (+ --lifecycle,
               --fault-injection)
scenarios.sh   the declarative config matrix (data, not code)
lib.sh         shared helpers: target I/O, assertions, readiness waiters, redaction
selftest.sh    pure-logic self-test (no server) — runs in CI on every PR
fakes/         controllable fake monerod/Tari + a contract test pointing the REAL clients at
               them (tier 2; runs in CI, no docker)
mini-stack/    docker overlay running the real dashboard + docker-control vs the fakes, with a
               scenario runner for hold/release + reject/readmit (tier 3; needs docker)
```

The live matrix here is **tier 4** of the broader plan — see
[`docs/testing-strategy.md`](../../docs/testing-strategy.md) for all four tiers and the full
scenario catalog.

Quick start:

```bash
# Against a remote box over SSH
make test-integration ARGS="--host miner@10.0.0.5 --dir pithead"

# On the box itself
./run.sh --local --dir /home/miner/pithead --lifecycle

# Just the pure-logic checks (no server)
make test-integration-selftest
```

**Full guide — provisioning the box, the safety model, the matrix, artifacts, and
CI/release wiring — is in [`docs/integration-testing.md`](../../docs/integration-testing.md).**
