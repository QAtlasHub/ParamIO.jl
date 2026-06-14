# core/load.jl — config TOML の読み込みと継承マージ

"""
    load(path; inherit=true) -> ConfigSpec

Read a TOML config and return a `ConfigSpec`.
If `[base] inherit = "..."` is present, merge the parent file first
(parent `[[paramsets]]` come first in the union).

The optional `[datavault] sweep_order` key may be set in the TOML to
override the default sweep enumeration order (which is `path_keys`).
"""
function load(path::AbstractString; inherit::Bool=true)::ConfigSpec
    raw = _load_raw(path, inherit, String[])

    study_tbl = get(raw, "study", Dict{String,Any}())
    study = StudySpec(
        get(study_tbl, "project_name", "unnamed"),
        get(study_tbl, "total_samples", 1),
        get(study_tbl, "outdir", "out"),
    )

    raw_paramsets = get(raw, "paramsets", Vector{Dict{String,Any}}())
    flat_blocks = [_flatten_block(b) for b in raw_paramsets]

    if haskey(raw, "datavault") && haskey(raw["datavault"], "path_keys")
        path_keys = convert(Vector{String}, raw["datavault"]["path_keys"])
        _validate_path_keys(path_keys, flat_blocks)
    else
        path_keys = resolve_path_keys(flat_blocks)
    end

    # Optional explicit sweep_order
    sweep_order = if haskey(raw, "datavault") && haskey(raw["datavault"], "sweep_order")
        convert(Vector{String}, raw["datavault"]["sweep_order"])
    else
        String[]
    end

    ConfigSpec(study, path_keys, flat_blocks, sweep_order)
end

"""
    _load_raw(path, inherit, chain) -> Dict{String,Any}

Parse the TOML at `path`, **recursively** merging `[base] inherit` parents so
multi-level (grandparent and deeper) chains compose correctly. `chain` tracks
the absolute paths visited so far and is used to detect inheritance cycles.
"""
function _load_raw(
    path::AbstractString, inherit::Bool, chain::Vector{String}
)::Dict{String,Any}
    apath = abspath(path)
    if apath in chain
        error(
            "ParamIO.load: circular [base] inherit detected: " *
            join(vcat(chain, apath), " -> "),
        )
    end
    raw = TOML.parsefile(path)
    if inherit && haskey(raw, "base") && haskey(raw["base"], "inherit")
        parent_path = joinpath(dirname(path), raw["base"]["inherit"])
        parent_raw = _load_raw(parent_path, inherit, vcat(chain, apath))
        raw = _merge_configs(parent_raw, raw)
    end
    return raw
end
