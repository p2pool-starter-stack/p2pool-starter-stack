# Config layer language

The architecture decision record for #1480: whether to port the config parse/validate/render
layer out of bash after the #1105 split, and what each install path must guarantee as a result.
Decision, ratified 2026-08-29: **no port — the layer stays bash, and validation gains a
schema-driven gate over `jq` against `config.reference.json`** (option 2 of the issue). Figures
below were measured against the source at `develop-v2` commit `32be481f`.

## The question

`pithead` stays bash on the merits: most of it is exec-and-glue — compose, systemd, RAUC, disk
and boot plumbing — where a port buys more lines and new quoting failure modes for no safety.
The #1105 split isolated the one layer where a port plausibly pays:
`lib/pithead/28-parse-and-validate-config.sh` (485 lines) and `lib/pithead/33-render-env.sh`
(494 lines), the modules that turn `config.json` into a validated `.env`. The project's
config-handling defects cluster here, not in orchestration: #1059 (wizard vs valid
config), #695/#696 (spurious save/preview changes), the masking fixes, #1342's mutation
windows.

Three options were on the table: a module-by-module Python port behind the same CLI surface, a
`jq`/schema middle path, or staying bash unchanged.

## The deciding axis: failure mode, not dependency count

Host `python3` is already invoked today, but every call site is deliberately soft. Both
invocations in `lib/pithead/25-address-types.sh` are `command -v`-guarded and degrade rather
than fail — the Monero address gate falls back to shape-only checks, the Tari gate returns
`"unchecked"` — and `pithead doctor` reports a missing python3 as info, not a failure. The
wizard's python3 runs inside a container. A box without python3 is a supported state that costs
two advisory address checks.

Parsing is not degradable. A Python port of this layer moves the failure mode from two advisory
gates to a CLI that cannot read its own config: python3 becomes a hard requirement on the path
every command passes through.

Costed on the same bar, the middle path adds nothing: **parsing is already hard on `jq`.**
`28-parse-and-validate-config.sh` invokes `jq` on 38 lines with no guard — its first executable
statement is `jq -e . "$CONFIG_FILE"` — and `33-render-env.sh` on 35 lines, also unguarded.
Suite-wide, 29 of the 52 `lib/pithead/` modules invoke it. A Python port would not retire `jq`
either: config handling would be hard on python3 while everything around it stays hard on `jq`,
so every Compose host would carry two interpreters where it carries one today.

## Decision

Validation becomes schema-driven, in `jq`, against `config.reference.json` — the closed-schema
contract file that already exists (#33 lineage). The gate rejects unknown keys and wrong types
at parse time instead of leaving them to surface downstream. Render stays bash. No module is
ported.

- Zero new dependency and no changed failure mode: the layer is already hard on `jq`, with the
  guarantee already in place on both install paths (next section).
- Reversible: this does not foreclose a later port. A narrower question can be reopened with
  evidence (see the last section).
- Staying bash unchanged was rejected because the defect cluster is real, and its
  validation-shaped half is what a schema gate addresses at this cost.

## What each install path must guarantee

Exactly what it guarantees today — the decision makes two existing lines load-bearing rather
than adding new ones.

| Path | Guarantee | Where it lives today |
|---|---|---|
| Appliance image | `jq` present in the rootfs | `os/rootfs/Dockerfile` installs it in the final stage, alongside the other on-appliance tools |
| Compose install | `jq` declared and checked | [`getting-started.md`](../getting-started.md) prerequisites and apt line; `pithead setup`'s dependency check; `pithead doctor` fails when it is missing |
| Both | python3 stays optional | degraded address checks, doctor reports info — unchanged |

NOTE: removing `jq` from the rootfs package list or the Compose prerequisites now breaks config
parsing outright, not a diagnostic nicety. Treat those lines as contract.

## What this does not decide

The gate does not touch the render/mutation half of the defect cluster: #695/#696-class
spurious diffs and #1342-class mutation windows live in `render_env` and the write paths, which
keep bash's quoting failure modes. If config defects keep landing there after the schema gate
ships, file a follow-up ADR scoped to a render-only port rather than reopening the whole
question.

No code ships with this record; the gate itself is follow-up work under #1480's lineage. The
issue's timing gate — do not start while the #1105 push runs — is satisfied: the push closed
before this record was filed, and this record changes `docs/dev/` only.
