# util/grid.jl — compact sweep grids: a `{start, stop, length|step}` table → an explicit list
#
# Monte-Carlo and finite-size-scaling sweeps want many points on an axis (T over 50 temperatures, χ
# over a decade) without hand-typing the list. A *grid spec* is a TOML inline table that
# `_flatten_block` expands into the ordinary list the Cartesian product in `expand` already sweeps
# over — so nothing downstream changes: a grid is just a concise way to write a list.

const _GRID_KEYS = ("start", "stop", "length", "step", "scale")

"""
    _is_grid(v) -> Bool

`true` when `v` is a *grid spec*: a table carrying `start` and `stop` whose keys are **all** drawn
from `start`/`stop`/`length`/`step`/`scale`.

The all-keys rule is what keeps an ordinary parameter namespace that merely *contains* a
`start`/`stop` parameter from being mistaken for a grid — e.g. `[paramsets.window]` with
`start=0.0; stop=1.0; dt=0.01` has a non-grid key (`dt`), so it stays a namespace and flattens
normally.
"""
function _is_grid(v)::Bool
    v isa AbstractDict || return false
    (haskey(v, "start") && haskey(v, "stop")) || return false
    return all(k -> string(k) in _GRID_KEYS, keys(v))
end

"""
    _expand_grid(v) -> v

Expand a grid spec into the explicit sweep list it stands for; pass any non-grid value through
unchanged. Three forms (`start`/`stop` inclusive):

    {start=1.0,  stop=4.0, length=31}                 # linspace: 31 points  → Vector{Float64}
    {start=16,   stop=128, step=16}                   # 16:16:128            → Vector{Int}
    {start=1e-3, stop=1.0, length=7, scale="log"}     # 7 log-spaced points  → Vector{Float64}

`length` (point count, ≥ 2) and `step` are mutually exclusive — exactly one is required. The linear
length form is always `Float64` (a linspace); the step form follows Julia's `a:s:b`, so an
all-integer step keeps `Int`. `scale="log"` needs `length` (a geometric grid has no constant step)
and `start, stop > 0`.

Errors loudly on a malformed spec — a typo'd key (`lenght`) leaves the table with neither `length`
nor `step`, so a mistyped grid raises rather than silently degrading to a fixed table-valued
parameter.
"""
function _expand_grid(v)
    _is_grid(v) || return v
    a = v["start"]
    b = v["stop"]
    (a isa Real && b isa Real) || error(
        "ParamIO grid: `start`/`stop` must be numbers, got start=$(repr(a)) stop=$(repr(b))",
    )
    scale = lowercase(string(get(v, "scale", "linear")))
    scale in ("linear", "log") ||
        error("ParamIO grid: `scale` must be \"linear\" or \"log\", got $(repr(scale))")
    has_length = haskey(v, "length")
    has_step = haskey(v, "step")
    if has_length == has_step
        error("ParamIO grid {start, stop, …} needs exactly one of `length` or `step`")
    end

    if has_length
        n = v["length"]
        (n isa Integer && n >= 2) ||
            error("ParamIO grid: `length` must be an integer ≥ 2, got $(repr(n))")
        if scale == "log"
            (a > 0 && b > 0) || error(
                "ParamIO grid: scale=\"log\" needs start, stop > 0, got start=$a stop=$b",
            )
            return collect(exp10.(range(log10(float(a)), log10(float(b)); length=n)))
        end
        return collect(range(float(a), float(b); length=n))
    else
        scale == "log" && error(
            "ParamIO grid: scale=\"log\" needs `length`, not `step` " *
            "(a geometric grid has no constant step)",
        )
        s = v["step"]
        (s isa Real && !iszero(s)) ||
            error("ParamIO grid: `step` must be a nonzero number, got $(repr(s))")
        pts = collect(a:s:b)
        isempty(pts) && error(
            "ParamIO grid: `step`=$s from start=$a to stop=$b yields no points " *
            "(does the step sign match the direction?)",
        )
        return pts
    end
end

# ── const: a fixed value — the explicit dual of `list ⇒ sweep` ──────────────────
#
# `list ⇒ swept axis` is convenient but leaves no way to pass a list as a *value* — an inhomogeneous
# coupling vector {Jᵢ}, a field profile — since `J = [1.0, 0.5]` would sweep two runs. A `{const = X}`
# table pins X as one fixed value: `_flatten_block` wraps it as `_Literal`, which `expand` treats as
# fixed (it is not an `AbstractArray`) and unwraps back to X in every `DataKey`.

"""
    _Literal(value)

A flatten-time marker meaning "`value` is a fixed parameter value, not a swept axis". `expand`
classifies it as fixed (it is not an `AbstractArray`) and unwraps it to `value` in every `DataKey`,
so a list can be a *value* (`{const = [1.0, 0.5]}`) instead of a sweep.
"""
struct _Literal
    value::Any
end

_unwrap_literal(v) = v isa _Literal ? v.value : v

"""
    _is_const(v) -> Bool

`true` when `v` is a *const spec*: a table whose only key is `const`. `{const = X}` pins `X` as one
fixed value (never swept) — the explicit counterpart to `list ⇒ sweep`.
"""
_is_const(v)::Bool = v isa AbstractDict && length(v) == 1 && haskey(v, "const")

"""
    _is_spec(v) -> Bool

`true` when `v` is any leaf-table spec — a grid (`{start, stop, …}`, a swept list) or a const
(`{const = X}`, a fixed value). `_flatten_block` treats a spec as a leaf, not a namespace to descend.
"""
_is_spec(v)::Bool = _is_grid(v) || _is_const(v)

"""
    _flatten_value(v) -> v

Resolve a leaf value: a const spec → a `_Literal` (fixed), a grid spec → an explicit list (swept),
anything else unchanged.
"""
_flatten_value(v) = _is_const(v) ? _Literal(v["const"]) : _expand_grid(v)
