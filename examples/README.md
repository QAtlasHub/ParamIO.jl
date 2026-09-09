# Example — what ParamIO produces

ParamIO is **layer 1** of the HPC compute stack: it turns one config TOML into
a `Vector{DataKey}` — the list of parameter points a sweep will compute.
`DataVault` then maps each `DataKey` to storage, and `SweepRunner` runs the
work over them. This example makes layer 1's output visible.

```bash
julia --project=. examples/inspect.jl
```

reads `examples/sweep.toml` (a 2-axis sweep, `N ∈ {8,16} × g ∈ {0.5,1.0}`, 2
samples each) and prints every `DataKey` it expands to:

```
project_name  = demo
total_samples = 2
path_keys     = ["system.N", "model.g"]   (dotted group.leaf names)

expand() → 8 DataKeys  (4 points × 2 samples)

DataKey.params                            sample format_path     canonical
----------------------------------------------------------------------------------------------------
{model.J=1.0, model.g=0.5, system.N=8}    1      sysN8_modg0.50  model.J=1.0;model.g=0.5;system.N=8;#sample=1
{model.J=1.0, model.g=0.5, system.N=8}    2      sysN8_modg0.50  model.J=1.0;model.g=0.5;system.N=8;#sample=2
{model.J=1.0, model.g=1.0, system.N=8}    1      sysN8_modg1.00  model.J=1.0;model.g=1.0;system.N=8;#sample=1
...
{model.J=1.0, model.g=1.0, system.N=16}   2      sysN16_modg1.00 model.J=1.0;model.g=1.0;system.N=16;#sample=2
```

## Read the table — these three facts trip everyone up

- **`DataKey.params` keys are DOTTED.** A `[paramsets.system] N = …` block
  becomes `key.params["system.N"]`. Your `work_fn` indexes `params["system.N"]`,
  **never** `params["N"]` (the leaf name alone raises `KeyError`).

- **Fixed scalars ride along.** `J = 1.0` is not swept, but it appears in *every*
  `DataKey` as `"model.J"`. Only *list*-valued params (`N`, `g`) create the
  Cartesian product.

- **`format_path` ≠ `canonical`.** `format_path` (the on-disk directory name)
  uses only `path_keys`. `canonical` (the unique, Julia-version-stable key
  identity used by `SweepRunner`'s manifest) uses *all* params plus
  the sample index. Two distinct DataKeys can share a `format_path` but never a
  `canonical`.

## The config schema (`sweep.toml`)

| Section | Read by | Meaning |
| --- | --- | --- |
| `[study]` | ParamIO + DataVault | `project_name`, `total_samples`, default `outdir` |
| `[datavault] path_keys` | ParamIO | dotted keys that name the directory / identity |
| `[[paramsets]]` blocks | ParamIO | list value ⇒ swept axis; scalar ⇒ fixed |

Optional: `[datavault] sweep_order` overrides the enumeration order;
`[base] inherit = "parent.toml"` merges a parent config first.

## Public API

| Function | Use |
| --- | --- |
| `load(path) -> ConfigSpec` | parse the TOML (and merge `[base] inherit`) |
| `expand(spec) -> Vector{DataKey}` | Cartesian product × samples |
| `format_path(key, path_keys) -> String` | compact directory segment |
| `canonical(key) -> String` | stable identity (used by SweepRunner) |

See the full stack wired together in
[`SweepRunner.jl/examples/`](../../SweepRunner.jl/examples/).
