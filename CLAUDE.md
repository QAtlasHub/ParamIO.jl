# CLAUDE.md — ParamIO.jl

**Layer 1 of the infra HPC stack** (ParamIO → DataVault → ParallelManager):
config TOML → `Vector{DataKey}`. Pure parsing + Cartesian enumeration; no IO, no
storage. See [`../CLAUDE.md`](../CLAUDE.md) for how the three layers fit together.

## Role / public API

- `load(path) -> ConfigSpec` — parse TOML (merges `[base] inherit` if present).
- `expand(spec) -> Vector{DataKey}` — Cartesian product of list-valued params × `total_samples`.
- `format_path(key, path_keys) -> String` — compact on-disk directory segment.
- `canonical(key) -> String` — stable, order-/version-independent key identity.

## Two facts that trip up callers

- **`DataKey.params` keys are DOTTED**: a `[paramsets.system] N=…` block →
  `key.params["system.N"]`, not `["N"]`. Fixed scalars still appear in every key.
- **List value ⇒ swept axis; scalar ⇒ fixed.** Only lists create the product.

## Where to look for usage

- **`examples/inspect.jl`** — run it; prints exactly what `expand` produces (dotted keys, `format_path`, `canonical`). Start here.
- `README.md` — config schema + API.
- Full stack: [`../ParallelManager.jl/examples/`](../ParallelManager.jl/examples/).

## Source layout

`src/core/` = public API (`types`, `load`, `expand`, `format`, `canonical`).
`src/util/` = internal (`flatten`, `path_keys`) — renamable without notice.

## Invariant when changing this package

**`canonical()`'s output schema is FROZEN** — `ParallelManager`'s `Manifest` and
the per-key lock use it as a directory-safe identity. Changing its format
silently orphans every existing manifest/lock. Run the test suite locally before pushing.
