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
- **A `{start, stop, length|step}` table is a grid** — a concise swept axis that expands to a
  list before the product (`length`→linspace `Float64`, integer `step`→`a:s:b` `Int`,
  `scale="log"`→geometric). A namespace that merely *contains* a `start`/`stop` param (plus, say,
  `dt`) is **not** a grid. See README's *Grid axes*.
- **A `{const = X}` table is a fixed value** — the explicit dual of `list ⇒ sweep`: it pins `X`
  (even a list) as one value, never swept. `J = {const = [1, 0.5]}` is one 2-vector; `J = [1, 0.5]`
  is two runs. Implemented as a `_Literal` marker that `expand` unwraps.

## Where to look for usage

- **`examples/inspect.jl`** — run it; prints exactly what `expand` produces (dotted keys, `format_path`, `canonical`). Start here.
- `README.md` — config schema + API.
- Full stack: [`../ParallelManager.jl/examples/`](../ParallelManager.jl/examples/).

## Source layout

`src/core/` = public API (`types`, `load`, `expand`, `format`, `canonical`).
`src/util/` = internal (`grid`, `flatten`, `path_keys`) — renamable without notice.

## Invariant when changing this package

**`canonical()`'s output schema is FROZEN** — `ParallelManager`'s `Manifest` and
the per-key lock use it as a directory-safe identity. Changing its format
silently orphans every existing manifest/lock. Run the test suite locally before pushing.
