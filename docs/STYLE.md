# Documentation style

The house voice for every prose doc in this repo (`README.md`, `docs/**`, `CONTRIBUTING.md`, component READMEs). It matches the cadence of the p2pool, xmrig, and monero READMEs.

Audience: competent, privacy-conscious Monero/Tari miners who run their own nodes and read marketing polish as a red flag. Assume they know mining, nodes, and wallets — don't define basics.

## Voice

- Open each doc with one factual line stating what it is. No pitch, no "whether you're X or Y", no benefits framing.
- Imperative mood for procedures: "Run", "Build", "Create a wallet" — not "You can run" or "Users should".
- Keep command blocks copy-paste ready, broken out per-OS or per-step, with one line of prose between them or none.
- State warnings flat. Use `NOTE:` for caveats. At most one `!` per doc, only where a mistake costs money, privacy, or data.
- Use concrete numbers, ports, and timings instead of vague qualifiers.
- Link out to deeper docs instead of inlining long explanations. Config keys live in [`configuration.md`](configuration.md) — link there, don't duplicate the table.

## Banned words

Do not use: leverage, robust, seamless, powerful, effortlessly, comprehensive, elevate, streamline, simply, unlock, empower, cutting-edge, blazing, lightning-fast.

CI enforces this list (`make lint-docs-voice`, run by the per-surface lint job). The rest of the voice is reviewed by humans.

## Accuracy

The code is the source of truth. Verify every command, flag, default value, port, and path against the actual source — `pithead`, `docker-compose.yml`, `config.reference.json`, `config.py`, the Dockerfiles, the `Makefile`, and the test scripts. When the code and a doc disagree, correct the doc to match the code.

For upstream claims (monerod/xmrig/Tari flags, version numbers, links to other projects), confirm against the upstream source before editing. Never invent a fact. If a claim can't be verified from the code or a fetchable source, leave a `[TODO: verify upstream — ...]` marker rather than guessing.

Testing docs and coverage expectations live in [`testing-strategy.md`](testing-strategy.md).
