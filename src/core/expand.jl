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
    order = if sweep_order !== nothing
        sweep_order
    elseif !isempty(spec.sweep_order)
        spec.sweep_order
    else
        spec.path_keys
    end

    # Deduplicate on the canonical identity, NOT on raw `Dict` equality. `Dict`
    # `==` treats `1 == 1.0`, but `canonical` (the on-disk identity used by the
    # downstream packages) keeps them distinct. Keying dedup on `canonical` makes
    # expand's notion of "same point" identical to the on-disk directory
    # identity: points that would share a directory are deduped, points that
    # would get different directories are both kept. (sample is fixed at 0 here;
    # it does not affect the param identity.)
    seen = Set{String}()
    points = Dict{String,Any}[]

    for block in spec.paramsets
        for pt in _cartesian_product(block, order)
            id = canonical(DataKey(pt, 0))
            if id ∉ seen
                push!(seen, id)
                push!(points, pt)
            end
        end
    end

    result = DataKey[]
    for pt in points
        for s in 1:spec.study.total_samples
            # `copy` so sibling samples don't alias one shared mutable `params`
            # Dict — mutating one key's params must not corrupt its siblings.
            push!(result, DataKey(copy(pt), s))
        end
    end
    result
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

    fixed = Dict{String,Any}(k => v for (k, v) in flat if !(v isa AbstractArray))
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
    result
end
