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

Grid specs (`{start, stop, length|step}` tables) are expanded to explicit sweep lists here, so the
rest of the pipeline sees an ordinary list axis (see `grid.jl`). A grid table is treated as a leaf
value, not a sub-table to descend into — `_is_grid` distinguishes it from a parameter namespace.
"""
function _flatten_block(block::Dict)::Dict{String,Any}
    result = Dict{String,Any}()
    for (k, v) in block
        if v isa Dict && !_is_grid(v)
            for (sk, sv) in v
                result["$k.$sk"] = _expand_grid(sv)
            end
        else
            result[string(k)] = _expand_grid(v)
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
