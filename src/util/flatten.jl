# util/flatten.jl — TOML 構造のフラット化と継承マージ

"""
    _split_dotted(k) -> (group, leaf)

Split a dotted key like `"system.N"` into `("system", "N")`.
A plain key like `"N"` becomes `("", "N")`.
"""
function _split_dotted(k::String)
    idx = findfirst('.', k)
    idx === nothing && return ("", k)
    return (k[1:(idx - 1)], k[(idx + 1):end])
end

"""
    _flatten_block(block) -> Dict{String,Any}

Flatten one `[[paramsets]]` block: sub-tables become dotted top-level keys.

Example:
    {"system" => {"N" => [24,48], "chi" => 40}}
    → {"system.N" => [24,48], "system.chi" => 40}

Leaf-table specs are resolved here (see `grid.jl`), so the rest of the pipeline sees ordinary
values: a grid (`{start, stop, length|step}`) becomes a swept list, a const (`{const = X}`) becomes
a fixed `_Literal(X)`. A spec is treated as a leaf, not a sub-table to descend into — `_is_spec`
distinguishes it from a parameter namespace.
"""
function _flatten_block(block::Dict)::Dict{String,Any}
    result = Dict{String,Any}()
    for (k, v) in block
        if v isa Dict && !_is_spec(v)
            for (sk, sv) in v
                result["$k.$sk"] = _flatten_value(sv)
            end
        else
            result[string(k)] = _flatten_value(v)
        end
    end
    return result
end

"""
    _merge_configs(parent, child) -> Dict{String,Any}

Merge two raw TOML dicts; child overrides parent.
`[[paramsets]]` arrays are concatenated (parent first).
"""
function _merge_configs(parent::Dict{String,Any}, child::Dict{String,Any})::Dict{String,Any}
    result = deepcopy(parent)
    for (k, v) in child
        if k == "paramsets" && haskey(result, "paramsets")
            result["paramsets"] = vcat(result["paramsets"], v)
        elseif v isa Dict && haskey(result, k) && result[k] isa Dict
            result[k] = _merge_configs(result[k], v)
        else
            result[k] = v
        end
    end
    return result
end
