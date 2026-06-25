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
