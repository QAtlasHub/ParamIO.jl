# core/types.jl — ParamIO の中心データ構造とエラー型

"""
    AmbiguousPathKeyError

Raised when a plain leaf name (e.g. `"N"`) appears in multiple groups
(e.g. both `system.N` and `model.N`) and the user has not disambiguated
with dotted notation.
"""
struct AmbiguousPathKeyError <: Exception
    leaf::String
    groups::Vector{String}
end

function Base.showerror(io::IO, e::AmbiguousPathKeyError)
    hint = "\"$(e.groups[1]).$(e.leaf)\""
    return print(
        io,
        "AmbiguousPathKeyError: leaf \"$(e.leaf)\" appears in groups: ",
        join(e.groups, ", "),
        ". Use dotted notation (e.g., $hint) in [datavault] path_keys to disambiguate.",
    )
end

"""
    StudySpec

Project-level metadata extracted from `[study]` in a config TOML.
"""
struct StudySpec
    project_name::String
    total_samples::Int
    outdir::String
end

"""
    ArtifactSpec

An intermediate result that many sweep points share, declared in `[artifacts.<name>]`:

```toml
[artifacts.ground_state]
depends_on = ["run.U", "run.D", "run.cutoff"]   # the parameters it is a function of
version    = 2                                   # bump when the code that builds it changes
per_sample = false                               # true if it also depends on the sample index
```

Its identity is the key **projected onto `depends_on`** plus `version` — see
[`artifact_key`](@ref) and [`artifact_identity`](@ref). A parameter left out of `depends_on`
does not invalidate it, so an artifact that reads a knob it does not declare is silently
reused across that knob's values.

Fields: `name`, `depends_on` (resolved to dotted keys), `version`, `per_sample`.
"""
struct ArtifactSpec
    name::String
    depends_on::Vector{String}
    version::Int
    per_sample::Bool
end

"""
    ConfigSpec

Parsed representation of a config TOML.

Fields:
- `study`:        project-level metadata
- `path_keys`:    ordered keys used to build directory paths (dotted or plain)
- `paramsets`:    flattened `[[paramsets]]` blocks; each is a `Dict{String,Any}`
                  where sub-table keys are prefixed as `"group.leaf"`
- `sweep_order`:  optional explicit sweep ordering for `expand`. If empty,
                  `path_keys` is used as the default sweep order.
- `float_format`: how float path segments are rendered — `"fixed2"` (default:
                  the legacy `%.2f`) or `"auto"` (content-aware, per-axis
                  injective+lossless; see `build_axis_formats` / `format_path`).
                  Set via `[datavault] float_format`. Never affects `canonical`.
- `artifacts`:    `[artifacts.<name>]` tables, by name — see [`ArtifactSpec`](@ref).
                  Empty when the config declares none.
"""
struct ConfigSpec
    study::StudySpec
    path_keys::Vector{String}
    paramsets::Vector{Dict{String,Any}}
    sweep_order::Vector{String}
    float_format::String
    artifacts::Dict{String,ArtifactSpec}
end

# Backward-compatible constructor (no artifacts)
function ConfigSpec(
    study::StudySpec,
    path_keys::Vector{String},
    paramsets::Vector{Dict{String,Any}},
    sweep_order::Vector{String},
    float_format::String,
)
    return ConfigSpec(
        study, path_keys, paramsets, sweep_order, float_format, Dict{String,ArtifactSpec}()
    )
end

# Backward-compatible constructor (no float_format) → legacy fixed2 default
function ConfigSpec(
    study::StudySpec,
    path_keys::Vector{String},
    paramsets::Vector{Dict{String,Any}},
    sweep_order::Vector{String},
)
    return ConfigSpec(study, path_keys, paramsets, sweep_order, "fixed2")
end

# Backward-compatible constructor (no sweep_order, no float_format)
function ConfigSpec(
    study::StudySpec, path_keys::Vector{String}, paramsets::Vector{Dict{String,Any}}
)
    return ConfigSpec(study, path_keys, paramsets, String[], "fixed2")
end

"""
    DataKey

A single point in the parameter space, including sample index.
`params` keys match the dotted/plain scheme used in the config's `path_keys`.
"""
struct DataKey
    params::Dict{String,Any}
    sample::Int
end

Base.:(==)(a::DataKey, b::DataKey) = a.sample == b.sample && a.params == b.params
Base.hash(k::DataKey, h::UInt) = hash(k.sample, hash(k.params, h))
