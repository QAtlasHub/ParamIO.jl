# util/path_keys.jl — path_keys の解決と検証

"""
    resolve_path_keys(flat_blocks) -> Vector{String}

Auto-detect `path_keys` from flattened paramset blocks (sorted).
Raises `AmbiguousPathKeyError` when the same leaf name appears in multiple groups
and the caller has not supplied explicit dotted notation.
"""
function resolve_path_keys(flat_blocks::Vector{Dict{String,Any}})::Vector{String}
    all_keys = Set{String}()
    for b in flat_blocks
        union!(all_keys, keys(b))
    end

    # leaf → set of groups it belongs to ("" for top-level keys)
    leaf_groups = Dict{String,Set{String}}()
    for k in all_keys
        group, leaf = _split_dotted(k)
        grps = get!(leaf_groups, leaf, Set{String}())
        push!(grps, group)
    end

    for (leaf, grps) in leaf_groups
        real = sort(filter(!isempty, collect(grps)))
        length(real) > 1 && throw(AmbiguousPathKeyError(leaf, real))
    end

    return sort(collect(all_keys))
end

"""
    _validate_path_keys(path_keys, flat_blocks)

Check that every `path_key` exists in at least one paramset block,
either as exact match (dotted) or unambiguous plain leaf name.
"""
function _validate_path_keys(
    path_keys::Vector{String}, flat_blocks::Vector{Dict{String,Any}}
)
    all_keys = Set{String}()
    for b in flat_blocks
        union!(all_keys, keys(b))
    end
    for pk in path_keys
        pk ∈ all_keys && continue  # exact match (dotted or top-level)
        # Try as plain leaf name
        _, leaf = _split_dotted(pk)
        if leaf == pk  # pk has no dot → plain leaf lookup
            matches = [k for k in all_keys if _split_dotted(k)[2] == pk]
            if length(matches) == 1
                continue  # found exactly one → OK
            elseif length(matches) > 1
                groups = sort([_split_dotted(k)[1] for k in matches])
                throw(AmbiguousPathKeyError(pk, groups))
            end
        end
        avail = join(sort(collect(all_keys)), ", ")
        error("path_key \"$pk\" not found in any paramset block. Available: $avail")
    end
end
