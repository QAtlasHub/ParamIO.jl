# core/expand.jl — Cartesian 展開と sweep 順序制御

"""
    expand(spec; sweep_order=nothing) -> Vector{DataKey}

Expand all `[[paramsets]]` blocks via Cartesian product,
deduplicate across blocks, and return one `DataKey` per (param_point × sample).

# Sweep ordering

The Cartesian product is evaluated **outermost-to-innermost** in a deterministic
order. The default order is, in priority:

1. The `sweep_order` keyword argument (if provided)
2. `spec.sweep_order` (set via `[datavault] sweep_order` in the TOML)
3. `spec.path_keys`
4. Sorted leftover keys

Sweep keys not listed in the chosen ordering are appended at the end in
sorted order, so the result is always deterministic.

# Deduplication

Two blocks that produce the same point yield one key, so `length(expand(spec))` is not the product
of the axis lengths whenever blocks overlap. The first block to produce a point also fixes its
position, which is what makes a small leading block a way to order a long acquisition: put the slice
to close first at the top, overlapping a later broader block, and only the position survives.

Sameness is `canonical`, the on-disk directory identity, not `Dict` equality: `1` and `1.0` get
different directories and are both kept. [`expand_report`](@ref) returns how many were collapsed,
which is what separates "my new block added nothing" from "my new block was not read".

# Example

```julia
spec = ParamIO.load("config.toml")
keys = ParamIO.expand(spec)                                 # uses path_keys order
keys = ParamIO.expand(spec; sweep_order=["model.h", "system.N"])  # explicit
```
"""
function expand(
    spec::ConfigSpec; sweep_order::Union{Nothing,Vector{String}}=nothing
)::Vector{DataKey}
    return expand_report(spec; sweep_order=sweep_order).keys
end

"""
    expand_report(spec; sweep_order=nothing) -> NamedTuple

[`expand`](@ref)'s keys together with what deduplication removed to get them:

- `keys`, `points`: the keys, and the distinct parameter points behind them
  (`length(keys) == points * spec.study.total_samples`);
- `duplicates`: points dropped for repeating an earlier one;
- `per_paramset`: one `(; produced, kept, duplicate)` per `[[paramsets]]` block, in block order.

`per_paramset[i].kept == 0` is a block that contributed nothing, which a total alone cannot tell
from a block that was never read.
"""
function expand_report(spec::ConfigSpec; sweep_order::Union{Nothing,Vector{String}}=nothing)
    order = if sweep_order !== nothing
        sweep_order
    elseif !isempty(spec.sweep_order)
        spec.sweep_order
    else
        spec.path_keys
    end

    # Dedup on the canonical identity, NOT on raw `Dict` equality. `Dict` `==` treats `1 == 1.0`,
    # but `canonical` (the on-disk identity used by the downstream packages) keeps them distinct,
    # so points that would share a directory are deduped and points that would get different ones
    # are both kept. (sample is fixed at 0 here; it does not affect the param identity.)
    seen = Set{String}()
    points = Dict{String,Any}[]
    per_paramset = @NamedTuple{produced::Int, kept::Int, duplicate::Int}[]

    for block in spec.paramsets
        produced = 0
        kept = 0
        for pt in _cartesian_product(block, order)
            produced += 1
            id = canonical(DataKey(pt, 0))
            if id ∉ seen
                push!(seen, id)
                push!(points, pt)
                kept += 1
            end
        end
        push!(per_paramset, (; produced, kept, duplicate=produced - kept))
    end

    result = DataKey[]
    for pt in points
        for s in 1:spec.study.total_samples
            # `copy` so sibling samples don't alias one shared mutable `params` Dict; mutating one
            # key's params must not corrupt its siblings.
            push!(result, DataKey(copy(pt), s))
        end
    end

    return (;
        keys=result,
        points=length(points),
        duplicates=sum(p -> p.duplicate, per_paramset; init=0),
        per_paramset,
    )
end

"""
    _cartesian_product(flat, order) -> Vector{Dict{String,Any}}

All Cartesian combinations of array-valued keys. Scalars stay fixed.

`order` specifies the outermost-to-innermost iteration order.
Sweep keys not in `order` are appended at the end in sorted order, so the
result is always deterministic regardless of `Dict` iteration order.
"""
function _cartesian_product(
    flat::Dict{String,Any}, order::Vector{String}
)::Vector{Dict{String,Any}}
    # Sweep keys (array-valued) in the requested order
    sweep_keys = String[]
    seen_in_order = Set{String}()
    for k in order
        if haskey(flat, k) && flat[k] isa AbstractArray && k ∉ seen_in_order
            push!(sweep_keys, k)
            push!(seen_in_order, k)
        end
    end
    # Append remaining sweep keys (sorted for determinism)
    for k in sort(collect(keys(flat)))
        if flat[k] isa AbstractArray && k ∉ seen_in_order
            push!(sweep_keys, k)
        end
    end

    # `_Literal` (a `{const = …}` value) is fixed, not swept — it is not an `AbstractArray`, so it
    # lands here; unwrap it to the bare value it carries.
    fixed = Dict{String,Any}(
        k => _unwrap_literal(v) for (k, v) in flat if !(v isa AbstractArray)
    )
    isempty(sweep_keys) && return [copy(fixed)]

    ranges = [flat[k] for k in sweep_keys]
    result = Dict{String,Any}[]

    function recurse(idx::Int, current::Dict{String,Any})
        if idx > length(sweep_keys)
            push!(result, merge(fixed, current))
            return nothing
        end
        for val in ranges[idx]
            recurse(idx + 1, merge(current, Dict{String,Any}(sweep_keys[idx] => val)))
        end
    end
    recurse(1, Dict{String,Any}())
    return result
end
