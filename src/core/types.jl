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
    ConfigSpec

Parsed representation of a config TOML.

Fields:
- `study`:        project-level metadata
- `path_keys`:    ordered keys used to build directory paths (dotted or plain)
- `paramsets`:    flattened `[[paramsets]]` blocks; each is a `Dict{String,Any}`
                  where sub-table keys are prefixed as `"group.leaf"`
- `sweep_order`:  optional explicit sweep ordering for `expand`. If empty,
                  `path_keys` is used as the default sweep order.
"""
struct ConfigSpec
    study::StudySpec
    path_keys::Vector{String}
    paramsets::Vector{Dict{String,Any}}
    sweep_order::Vector{String}
end

# Backward-compatible constructor (no sweep_order)
function ConfigSpec(
    study::StudySpec, path_keys::Vector{String}, paramsets::Vector{Dict{String,Any}}
)
    return ConfigSpec(study, path_keys, paramsets, String[])
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
