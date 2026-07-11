# core/diagnose.jl — static grid diagnostics: catch campaign-corrupting config bugs pre-submit
#
# `diagnose` inspects the SAME enumeration `expand` produces and reports four failure modes that
# silently corrupt an HPC campaign — duplicated points, path collisions, invisible (path-omitted)
# swept params, and unresolved path-key ambiguity. It performs ZERO filesystem writes: the
# `ConfigSpec` form touches nothing; the `config_path` form only READS the TOML through `load`.

"""
    DiagnosticReport

Result of [`diagnose`](@ref): a static, non-throwing audit of a parameter grid.

Fields:
- `n_points`:         number of DISTINCT param points (post-dedup;
                      `== length(expand(spec)) ÷ n_samples`)
- `n_samples`:        `study.total_samples` (each point is repeated this many times by `expand`)
- `duplicates`:       `(point, multiplicity)` for every assignment the raw per-block enumeration
                      yields ≥2× (overlapping value lists / redundant `[[paramsets]]`)
- `collisions`:       `(path, points)` for every `format_path` output ≥2 DISTINCT points map to —
                      a real run would silently overwrite one with the other
- `invisible_params`: names of params that vary (>1 distinct value) but are NOT covered by
                      `path_keys` — the ROOT CAUSE of a collision
- `ambiguous`:        captured `AmbiguousPathKeyError`s (surfaced into the report, never thrown)
- `ok`:               `true` iff every check is clean (all of the above empty)
"""
struct DiagnosticReport
    n_points::Int
    n_samples::Int
    duplicates::Vector{Tuple{Dict{String,Any},Int}}
    collisions::Vector{Tuple{String,Vector{Dict{String,Any}}}}
    invisible_params::Vector{String}
    ambiguous::Vector{AmbiguousPathKeyError}
    ok::Bool
end

"""
    diagnose(spec::ConfigSpec) -> DiagnosticReport
    diagnose(config_path::AbstractString; inherit=true) -> DiagnosticReport

Statically audit the parameter grid a config expands to — BEFORE any run is submitted — and return
a [`DiagnosticReport`](@ref). Pure logic: performs **zero filesystem writes**. The `config_path`
form only reads the TOML through [`load`](@ref); the `ConfigSpec` form touches the filesystem not
at all.

Four checks, each a field on the report:

1. **duplicate points** — the raw per-block Cartesian enumeration yields the same assignment ≥2×
   (overlapping value lists or redundant `[[paramsets]]`). `expand` silently dedups these; here they
   are surfaced with their multiplicity.
2. **path collisions** — two DISTINCT points map to the same `format_path(key, path_keys)`, so a
   real run would silently overwrite one result with the other.
3. **invisible params** — params taking >1 distinct value across the grid that are NOT covered by
   `path_keys`. This is the ROOT CAUSE of (2): a swept axis with no directory segment to separate
   its points. The single most useful line in the report.
4. **ambiguous path keys** — an `AmbiguousPathKeyError` (a plain leaf shared by multiple groups)
   that would otherwise be thrown by `load` is captured into the report instead of thrown.

`ok` is `true` iff all four checks are clean.

# Example

```julia
report = ParamIO.diagnose("config.toml")   # loads + audits, never writes
report.ok || show(report)                  # inspect the offending detail
```
"""
function diagnose(spec::ConfigSpec)::DiagnosticReport
    order = isempty(spec.sweep_order) ? spec.path_keys : spec.sweep_order

    # Raw per-block enumeration, tallied on the on-disk identity (`canonical`) so "same point" here
    # means exactly what `expand` dedups on — and what a run directory would collapse together.
    counts = Dict{String,Int}()
    rep = Dict{String,Dict{String,Any}}()
    distinct_ids = String[]
    for block in spec.paramsets
        for pt in _cartesian_product(block, order)
            id = canonical(DataKey(pt, 0))
            if !haskey(counts, id)
                counts[id] = 0
                rep[id] = pt
                push!(distinct_ids, id)
            end
            counts[id] += 1
        end
    end
    points = [rep[id] for id in distinct_ids]

    # (1) duplicate points: any assignment the raw enumeration produced more than once
    duplicates = Tuple{Dict{String,Any},Int}[
        (rep[id], counts[id]) for id in distinct_ids if counts[id] >= 2
    ]

    # (3) invisible params: >1 distinct value across the grid, not covered by any path_key.
    # Values are compared via `_canonical_value` (the on-disk value identity), so `1` and `1.0`
    # count as distinct exactly as the directory layout would treat them.
    valuesets = Dict{String,Set{String}}()
    for pt in points
        for (k, v) in pt
            push!(get!(valuesets, k, Set{String}()), _canonical_value(v))
        end
    end
    invisible = sort!(
        String[
            k for (k, vs) in valuesets if
            length(vs) >= 2 && !_covered_by_path_keys(k, spec.path_keys)
        ],
    )

    # (2) path collisions: distinct points sharing one `format_path` output.
    # Use the SAME float format the config selects, so diagnose verifies the REAL
    # paths a run would create: fixed2 ⇒ legacy %.2f (as today); auto ⇒ the
    # content-aware, per-axis injective format from `build_axis_formats`.
    axis_formats = spec.float_format == "auto" ? build_axis_formats(spec) : nothing
    groups = Dict{String,Vector{Dict{String,Any}}}()
    group_order = String[]
    for pt in points
        p = _safe_format_path(DataKey(pt, 0), spec.path_keys, axis_formats)
        p === nothing && continue
        if !haskey(groups, p)
            groups[p] = Dict{String,Any}[]
            push!(group_order, p)
        end
        push!(groups[p], pt)
    end
    collisions = Tuple{String,Vector{Dict{String,Any}}}[
        (p, groups[p]) for p in group_order if length(groups[p]) >= 2
    ]

    ok = isempty(duplicates) && isempty(collisions) && isempty(invisible)
    return DiagnosticReport(
        length(points),
        spec.study.total_samples,
        duplicates,
        collisions,
        invisible,
        AmbiguousPathKeyError[],
        ok,
    )
end

function diagnose(config_path::AbstractString; inherit::Bool=true)::DiagnosticReport
    spec = try
        load(config_path; inherit=inherit)
    catch e
        e isa AmbiguousPathKeyError || rethrow()
        # `load` cannot even resolve `path_keys` (a plain leaf is shared by multiple groups).
        # Surface the ambiguity as a report entry instead of letting it throw.
        return DiagnosticReport(
            0,
            0,
            Tuple{Dict{String,Any},Int}[],
            Tuple{String,Vector{Dict{String,Any}}}[],
            String[],
            AmbiguousPathKeyError[e],
            false,
        )
    end
    return diagnose(spec)
end

"""
    _covered_by_path_keys(param_key, path_keys) -> Bool

`true` when some entry of `path_keys` selects `param_key`: an exact (dotted or top-level) match, or a
plain (dot-free) path_key equal to the param's leaf. Mirrors `format_path`'s plain-leaf lookup, so a
param is "visible" here iff `format_path` would put it in the directory name.
"""
function _covered_by_path_keys(param_key::String, path_keys::Vector{String})::Bool
    param_key in path_keys && return true
    leaf = _split_dotted(param_key)[2]
    for pk in path_keys
        if !occursin('.', pk) && pk == leaf
            return true
        end
    end
    return false
end

"""
    _safe_format_path(key, path_keys) -> Union{String,Nothing}

`format_path(key, path_keys)`, returning `nothing` instead of throwing (e.g. a path_key absent from a
heterogeneous block). A point with no formattable path cannot participate in a collision, so it is
simply skipped — keeping `diagnose` non-throwing.
"""
function _safe_format_path(key::DataKey, path_keys::Vector{String})
    try
        return format_path(key, path_keys)
    catch
        return nothing
    end
end

# `axis_formats === nothing` ⇒ fixed2 (2-arg); otherwise auto (3-arg). Non-throwing.
function _safe_format_path(
    key::DataKey, path_keys::Vector{String}, axis_formats::Union{AbstractDict,Nothing}
)
    try
        return if axis_formats === nothing
            format_path(key, path_keys)
        else
            format_path(key, path_keys, axis_formats)
        end
    catch
        return nothing
    end
end

# ── pretty printing ─────────────────────────────────────────────────────────────

function Base.show(io::IO, ::MIME"text/plain", r::DiagnosticReport)
    nfail =
        (!isempty(r.invisible_params)) +
        (!isempty(r.collisions)) +
        (!isempty(r.duplicates)) +
        (!isempty(r.ambiguous))
    n_keys = r.n_points * r.n_samples
    header = r.ok ? "✓ OK" : "✗ $(nfail)/4 checks failed"
    println(
        io,
        "DiagnosticReport: ",
        header,
        "  (",
        r.n_points,
        " point(s) × ",
        r.n_samples,
        " sample(s) = ",
        n_keys,
        " key(s))",
    )

    # (3) invisible params — the single most useful diagnostic, shown first
    if isempty(r.invisible_params)
        _diag_line(io, true, "invisible params", "none")
    else
        _diag_line(
            io,
            false,
            "invisible params",
            "$(length(r.invisible_params)) swept axis(es) absent from path_keys",
        )
        for p in r.invisible_params
            println(io, "        • ", p, "  (varies but has no path segment → collisions)")
        end
    end

    # (2) path collisions
    if isempty(r.collisions)
        _diag_line(io, true, "path collisions", "none")
    else
        _diag_line(
            io,
            false,
            "path collisions",
            "$(length(r.collisions)) path(s) silently overwritten",
        )
        for (path, pts) in r.collisions
            diff = _differing_keys(pts)
            println(
                io,
                "        ",
                path,
                "  ←  ",
                length(pts),
                " keys differ in [",
                join(diff, ", "),
                "]:",
            )
            for pt in pts
                println(io, "            ", _fmt_subpoint(pt, diff))
            end
        end
    end

    # (1) duplicate points
    if isempty(r.duplicates)
        _diag_line(io, true, "duplicate points", "none")
    else
        _diag_line(
            io,
            false,
            "duplicate points",
            "$(length(r.duplicates)) assignment(s) enumerated ≥2×",
        )
        for (pt, mult) in r.duplicates
            println(io, "        ×", mult, "  ", _fmt_point(pt))
        end
    end

    # (4) ambiguous path keys
    if isempty(r.ambiguous)
        _diag_line(io, true, "ambiguous path keys", "none")
    else
        _diag_line(
            io, false, "ambiguous path keys", "$(length(r.ambiguous)) unresolved leaf(es)"
        )
        for e in r.ambiguous
            println(
                io,
                "        leaf \"",
                e.leaf,
                "\" appears in groups: ",
                join(e.groups, ", "),
            )
        end
    end
    return nothing
end

function _diag_line(io::IO, ok::Bool, label::AbstractString, msg::AbstractString)
    return println(io, "  ", ok ? "✓" : "✗", " ", rpad(label, 20), msg)
end

function _fmt_point(pt::AbstractDict)
    ks = sort!(collect(keys(pt)))
    return "{" * join(("$k=$(pt[k])" for k in ks), ", ") * "}"
end

function _fmt_subpoint(pt::AbstractDict, subkeys::Vector{String})
    return "{" * join(("$k=$(get(pt, k, nothing))" for k in subkeys), ", ") * "}"
end

"""
    _differing_keys(pts) -> Vector{String}

The param keys whose value is not constant across `pts` — i.e. the axes on which a set of
path-colliding points actually differ. These are exactly the params that should have appeared in
`path_keys` to keep the points apart.
"""
function _differing_keys(pts::Vector{Dict{String,Any}})::Vector{String}
    allkeys = Set{String}()
    for p in pts
        union!(allkeys, keys(p))
    end
    diff = String[]
    for k in sort!(collect(allkeys))
        vals = Set(_canonical_value(get(p, k, nothing)) for p in pts)
        length(vals) >= 2 && push!(diff, k)
    end
    return diff
end
