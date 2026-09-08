# core/format.jl — DataKey からパス文字列を生成

"""
    format_path(key, path_keys) -> String

Build a compact path segment from a `DataKey`.

Examples:
- plain key `"N"`, value `24`         → `"N24"`
- dotted key `"system.N"`, value `24` → `"sysN24"` (3-char group prefix)
- float value                         → two decimal places: `"g0.50"`
"""
function format_path(key::DataKey, path_keys::Vector{String})::String
    parts = String[]
    for pk in path_keys
        val = get(key.params, pk, nothing)
        if val !== nothing
            # Exact match (dotted "system.N" or top-level "N")
            push!(parts, _format_param(pk, val))
        else
            # pk is a plain leaf name — find it in params by leaf match
            _, leaf = _split_dotted(pk)
            leaf == pk || error("path_key \"$pk\" not found in DataKey.params")
            matches = [(k, v) for (k, v) in key.params if _split_dotted(k)[2] == pk]
            isempty(matches) && error("path_key \"$pk\" not found in DataKey.params")
            length(matches) > 1 && error(
                "Ambiguous leaf \"$pk\" in DataKey.params — use dotted notation. " *
                "Matches: $(join([m[1] for m in matches], ", "))",
            )
            # Plain name → format WITHOUT group prefix (user chose plain name intentionally)
            push!(parts, _format_val(pk, matches[1][2]))
        end
    end
    return join(parts, "_")
end

# Format one path_key + value: "sysN24", "chi40", "g0.50"
function _format_param(pk::String, val)::String
    group, leaf = _split_dotted(pk)
    prefix = isempty(group) ? "" : (length(group) >= 3 ? group[1:3] : group)
    return prefix * _format_val(leaf, val)
end

function _format_val(name::String, val)::String
    val isa AbstractFloat && return @sprintf("%s%.2f", name, val)
    val isa Integer && return @sprintf("%s%d", name, val)
    return "$(name)$(val)"
end

# ── content-aware injective float formatting ("auto" mode) ──────────────────────
#
# The 2-arg `format_path` above renders every float with `%.2f` ("fixed2"): the
# frozen legacy default. It is CONTENT-BLIND — 0.006 and 0.008 both collapse to
# "0.01", silently overwriting one run's directory with another's.
#
# "auto" mode fixes this by deriving each float axis's precision from the SET of
# values that axis takes across the whole sweep. Everything below is ADDITIVE:
# the 2-arg path and `_format_val` are untouched, so existing configs are
# byte-for-byte unchanged.

# The largest fixed-decimal precision `auto` will try before falling back to a
# per-value shortest round-trip string. 17 = the round-trip digit budget of a
# Float64; anything a smaller scale needs (e.g. 1e-18) lands in the fallback.
const _MAX_FIXED_DECIMALS = 17

"""
    AxisFloatFmt

Per-axis float rendering decision produced by [`build_axis_formats`](@ref).

- `fallback == false`: render every value of the axis with `%.<precision>f` — the
  MINIMAL uniform fixed precision that renders the axis's whole value set both
  LOSSLESSLY and INJECTIVELY.
- `fallback == true`:  render each value as its own shortest round-trippable
  decimal (`string(v)`), which is injective by construction. Used only when no
  fixed precision `≤ $(_MAX_FIXED_DECIMALS)` can represent the axis losslessly
  (e.g. an extreme scale spread such as `[1.0, 1e-18]`).
"""
struct AxisFloatFmt
    precision::Int
    fallback::Bool
end

# Treat -0.0 as 0.0 (per spec) and normalise everything to Float64 so the
# needed-precision search and the emitted string agree on one value identity.
_norm_zero(v::AbstractFloat)::Float64 = (v == 0 ? zero(Float64) : Float64(v))

# Minimal number of decimal places `d` such that `%.df` of `v` parses back to
# `v` exactly (the shortest LOSSLESS fixed rendering). Returns -1 if none exists
# at or below `_MAX_FIXED_DECIMALS` — the signal to fall back to per-value
# shortest strings. NOT `round(v, digits=d)`: that mis-handles binary floats.
function _needed_decimals(v::Float64)::Int
    v == 0.0 && return 0
    for d in 0:_MAX_FIXED_DECIMALS
        if parse(Float64, _fixed_decimal(v, d)) == v
            return d
        end
    end
    return -1
end

_fixed_decimal(v::Float64, d::Int)::String = Printf.format(Printf.Format("%.$(d)f"), v)

# Shortest round-trippable decimal (Ryu). Injective on Float64 by construction.
_shortest_decimal(v::Float64)::String = string(v)

"""
    _axis_format(vals::Vector{Float64}) -> AxisFloatFmt

Choose the injective+lossless rendering for ONE float axis, given its DISTINCT
value set. Precision = the max over values of `_needed_decimals` (so every value
is lossless at that uniform precision; losslessness ⇒ injectivity, since two
distinct values that both round-trip cannot share a string). If any value needs
more than `_MAX_FIXED_DECIMALS`, or the uniform precision is somehow not
injective, fall back to per-value shortest strings. Injectivity is `@assert`ed.
"""
function _axis_format(vals::Vector{Float64})::AxisFloatFmt
    needed = map(_needed_decimals, vals)
    if !any(==(-1), needed)
        d = maximum(needed)
        strs = String[_fixed_decimal(v, d) for v in vals]
        lossless = all(parse(Float64, s) == v for (s, v) in zip(strs, vals))
        if lossless && length(Set(strs)) == length(vals)
            @assert length(Set(strs)) == length(vals) "ParamIO auto: fixed-precision collision"
            return AxisFloatFmt(d, false)
        end
    end
    # Fallback: per-value shortest round-trip string — injective by construction.
    fb = String[_shortest_decimal(v) for v in vals]
    @assert length(Set(fb)) == length(vals) "ParamIO auto: shortest-string collision (unreachable)"
    return AxisFloatFmt(0, true)
end

"""
    build_axis_formats(spec::ConfigSpec) -> Dict{String,AxisFloatFmt}

Compute, once from `expand(spec)`, the content-aware float format for every FLOAT
`path_key` axis. Integer / string / other axes get no entry (they are formatted
exactly as in fixed2). The result is passed to the 3-arg
[`format_path`](@ref) to render `auto`-mode paths.

Each entry guarantees: distinct values of that axis → distinct, round-trippable
path segments (the anti-collision guarantee `fixed2` cannot make).
"""
function build_axis_formats(spec::ConfigSpec)::Dict{String,AxisFloatFmt}
    all_keys = expand(spec)
    ordered = Dict{String,Vector{Float64}}()   # pk → distinct values, first-seen order
    seen = Dict{String,Set{Float64}}()
    for pk in spec.path_keys
        for k in all_keys
            v = _resolve_axis_value(k, pk)
            v isa AbstractFloat || continue
            nv = _norm_zero(v)
            s = get!(seen, pk, Set{Float64}())
            if nv ∉ s
                push!(s, nv)
                push!(get!(ordered, pk, Float64[]), nv)
            end
        end
    end
    return Dict{String,AxisFloatFmt}(pk => _axis_format(vals) for (pk, vals) in ordered)
end

# Resolve the value a `path_key` selects in a `DataKey`, mirroring `format_path`'s
# exact-then-leaf lookup. Returns `nothing` when absent or ambiguous (build then
# simply skips it — a non-float / unresolvable axis gets no auto entry).
function _resolve_axis_value(key::DataKey, pk::String)
    # Absent and ambiguous are both "no auto entry" here, so this asks for the outcome rather than
    # catching a raise: a `try` would have taken an InterruptException, or a bug in the resolver,
    # with the same hand as the two conditions it means to allow — and `build_axis_formats` would
    # then report "this axis has no auto format", which is how two distinct values come to share a
    # directory name (see the header of this file).
    found = _lookup_name(pk, Base.keys(key.params))
    found isa String || return nothing
    return key.params[found]
end

"""
    format_path(key, path_keys, axis_formats) -> String

`auto`-mode path builder: identical to the 2-arg [`format_path`](@ref) except
float segments are rendered with the content-aware, provably-injective per-axis
format in `axis_formats` (from [`build_axis_formats`](@ref)) instead of `%.2f`.
Integer / string / other segments are byte-for-byte identical to fixed2. A float
axis with no entry in `axis_formats` degrades to the fixed2 rendering.
"""
function format_path(
    key::DataKey, path_keys::Vector{String}, axis_formats::AbstractDict{String,AxisFloatFmt}
)::String
    parts = String[]
    for pk in path_keys
        val = get(key.params, pk, nothing)
        if val !== nothing
            push!(parts, _format_param_auto(pk, val, get(axis_formats, pk, nothing)))
        else
            _, leaf = _split_dotted(pk)
            leaf == pk || error("path_key \"$pk\" not found in DataKey.params")
            matches = [(k, v) for (k, v) in key.params if _split_dotted(k)[2] == pk]
            isempty(matches) && error("path_key \"$pk\" not found in DataKey.params")
            length(matches) > 1 && error(
                "Ambiguous leaf \"$pk\" in DataKey.params — use dotted notation. " *
                "Matches: $(join([m[1] for m in matches], ", "))",
            )
            push!(
                parts, _format_val_auto(pk, matches[1][2], get(axis_formats, pk, nothing))
            )
        end
    end
    return join(parts, "_")
end

function _format_param_auto(pk::String, val, af::Union{AxisFloatFmt,Nothing})::String
    group, leaf = _split_dotted(pk)
    prefix = isempty(group) ? "" : (length(group) >= 3 ? group[1:3] : group)
    return prefix * _format_val_auto(leaf, val, af)
end

function _format_val_auto(name::String, val, af::Union{AxisFloatFmt,Nothing})::String
    if val isa AbstractFloat
        af === nothing && return _format_val(name, val)   # no axis context → fixed2
        v = _norm_zero(val)
        s = af.fallback ? _shortest_decimal(v) : _fixed_decimal(v, af.precision)
        return string(name, s)
    end
    return _format_val(name, val)   # Int / String / other: identical to fixed2
end
