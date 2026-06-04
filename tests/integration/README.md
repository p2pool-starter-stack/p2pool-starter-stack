# Integration tests (`tests/integration/`)

End-to-end suite that drives a **real, already-provisioned Pithead server** through the
config matrix and asserts the stack behaves (issue
[#54](https://github.com/p2pool-starter-stack/pithead/issues/54)).

```
run.sh         entry point — connects (SSH or --local) and runs the matrix
scenarios.sh   the declarative config matrix (data, not code)
lib.sh         shared helpers: target I/O, assertions, readiness waiters, redaction
selftest.sh    pure-logic self-test (no server) — runs in CI on every PR
```

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
