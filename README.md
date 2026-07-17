# ParamIO.jl

[![docs: stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://codes.sota-shimozono.com/ParamIO.jl/stable/)
[![docs: dev](https://img.shields.io/badge/docs-dev-purple.svg)](https://codes.sota-shimozono.com/ParamIO.jl/dev/)
[![Julia](https://img.shields.io/badge/julia-v1.12+-9558b2.svg)](https://julialang.org)
[![Code Style: Blue](https://img.shields.io/badge/Code%20Style-Blue-4495d1.svg)](https://github.com/invenia/BlueStyle)

[![codecov](https://codecov.io/gh/QAtlasHub/ParamIO.jl/graph/badge.svg?token=57dh1RFl0t)](https://codecov.io/gh/QAtlasHub/ParamIO.jl)
[![Build Status](https://github.com/sotashimozono/ParamIO.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/sotashimozono/ParamIO.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Read a config TOML and expand it into a list of `DataKey` — one per parameter
point in a sweep. Pure parsing and Cartesian enumeration: no IO, no storage, no
side effects.

ParamIO is **layer 1 of a three-package HPC stack**. It answers *what to
compute*; [`DataVault.jl`](https://github.com/sotashimozono/DataVault.jl) answers
*where results go* (`DataKey` → storage), and
[`ParallelManager.jl`](https://github.com/sotashimozono/ParallelManager.jl)
answers *do it* (`run!(work_fn, vault, keys)`, parallel and crash-recoverable).

```text
ParamIO            DataVault           ParallelManager
config.toml  ──►   Vault(config)  ──►  run!(work_fn, vault, keys)
   │  expand
   ▼
Vector{DataKey}
```

## Quick start

```julia
using ParamIO

spec = ParamIO.load("config.toml")     # TOML → ConfigSpec
keys = ParamIO.expand(spec)            # → Vector{DataKey}, one per (point × sample)

k = keys[1]
k.params              # Dict("system.N" => 8, "model.g" => 0.5, …)  — DOTTED keys
k.sample              # 1
ParamIO.format_path(k, spec.path_keys) # "sysN8_modg0.50"  — the on-disk dir name
ParamIO.canonical(k)  # "model.g=0.5;system.N=8;#sample=1"  — stable identity
```

Run [`examples/inspect.jl`](examples/inspect.jl) to print the full expansion of a
sample config — the fastest way to see what `expand` produces:

```bash
julia --project=. examples/inspect.jl
```

## Config schema

```toml
[study]
project_name  = "demo"          # study name (used by DataVault)
total_samples = 2               # repeats per parameter point
outdir        = "out"           # default output root

[datavault]
path_keys = ["system.N", "model.g"]   # DOTTED keys that name the on-disk dirs
# sweep_order = [...]                  # optional: override enumeration order

[[paramsets]]
[paramsets.system]
N = [8, 16]                     # list  ⇒ swept axis
T = { start = 1.0, stop = 4.0, length = 31 }   # grid ⇒ swept axis (31-pt linspace)
[paramsets.model]
g = [0.5, 1.0]                  # list  ⇒ swept axis
J = 1.0                         # scalar ⇒ fixed (still present in every DataKey)
```

`expand` takes the Cartesian product of all list-valued params across every
`[[paramsets]]` block, multiplies by `total_samples`, and deduplicates. Optional
`[base] inherit = "parent.toml"` merges a parent config first.

### Grid axes — concise sweeps

For a fine Monte-Carlo or finite-size-scaling sweep, write an axis as a **grid** instead of a
hand-typed list. It expands to a list *before* the product, so it sweeps exactly like one:

| form | expands to |
| --- | --- |
| `{ start = 1.0, stop = 4.0, length = 31 }` | 31-point linspace, inclusive → `Float64` |
| `{ start = 16, stop = 128, step = 16 }` | `16:16:128` → `Int` |
| `{ start = 1e-3, stop = 1.0, length = 7, scale = "log" }` | 7 log-spaced points |

`length` (≥ 2) and `step` are mutually exclusive; exactly one is required. A malformed grid
**errors** (it never silently degrades to a fixed value). A namespace that merely *contains* a
`start`/`stop` parameter alongside others (e.g. a `dt`) is **not** a grid.

### Fixed list values — `{ const = … }`

A plain list is **always** a swept axis. To pass a list as a *value* — an inhomogeneous coupling
vector, a field profile — wrap it in `const`; it is never swept:

```toml
J  = { const = [1.0, 0.5, 0.5] }   # one fixed 3-vector, carried in every DataKey
Js = [1.0, 0.5, 0.5]               # three separate runs (a sweep)
```

So the two leaf-table forms are duals: a **grid** (`{ start, stop, … }`) is a swept list, a
**const** (`{ const = … }`) is a fixed value.

## The one thing that trips people up

`DataKey.params` is keyed by the **dotted** `group.leaf` path, matching
`path_keys`:

```julia
key.params["system.N"]   # ✅
key.params["N"]          # ❌ KeyError
```

A fixed scalar (`J` above) is **not** swept but **is** carried in every `DataKey`
as `"model.J"`. Only `path_keys` participate in `format_path` (the directory
name); `canonical` uses *all* params plus the sample index.

## API

| Function | Use |
| --- | --- |
| `load(path; inherit=true) -> ConfigSpec` | parse TOML, merge `[base] inherit` |
| `expand(spec; sweep_order=nothing) -> Vector{DataKey}` | Cartesian product × samples |
| `format_path(key, path_keys) -> String` | compact directory segment |
| `canonical(key) -> String` | stable, Julia-version-independent key identity |
| `resolve_path_keys(blocks) -> Vector{String}` | auto-detect `path_keys` if omitted |

## Source layout

```text
src/
├── ParamIO.jl        module entry (includes + exports)
├── core/             public API
│   ├── types.jl      DataKey, ConfigSpec, StudySpec, errors
│   ├── load.jl       TOML load + inherit merge
│   ├── expand.jl     Cartesian expansion + sweep order
│   ├── format.jl     format_path
│   └── canonical.jl  canonical (FROZEN schema — downstream identity)
└── util/             internal (flatten, path_keys)
```

## See also

- [DataVault.jl](https://github.com/sotashimozono/DataVault.jl) — storage layer
- [ParallelManager.jl](https://github.com/sotashimozono/ParallelManager.jl) — the runtime
- [`../CLAUDE.md`](../CLAUDE.md) — how the three packages fit together

Issues / requests: [GitHub Issues](https://github.com/sotashimozono/ParamIO.jl/issues).

## License

MIT.