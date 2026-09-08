# util/resolve.jl — the one place a name is resolved against a set of parameter keys.
#
# The rule is: an exact match on the dotted name, else a unique match on the leaf.
#
# It is also written out inline in `format_path` (both forms) and in `_validate_path_keys`, and
# those copies do not agree on what an ambiguous leaf is: `_validate_path_keys` throws
# `AmbiguousPathKeyError`, both `format_path` copies throw a bare `error`. Anything reusing the rule
# should come here rather than add a fourth reading of it.

"""
    _lookup_name(name, available) -> String | Vector{String} | Nothing

The outcome of resolving `name`, without deciding what to do about it:

- a `String` — the key it selects;
- a `Vector{String}` — the groups a plain leaf appears in, when there is more than one;
- `nothing` — nothing matched.

Split out from [`_resolve_name`](@ref) so that the caller which treats "absent" and "ambiguous" as
ordinary outcomes does not have to reach them through a `catch`. A `try` around a raise is a filter
that cannot say what it caught: it takes `InterruptException` and a genuine bug with the same hand
as the two conditions it means to allow.
"""
function _lookup_name(name::AbstractString, available)
    name ∈ available && return String(name)

    _, leaf = _split_dotted(String(name))
    leaf == name || return nothing

    matches = sort!(
        String[String(k) for k in available if _split_dotted(String(k))[2] == name]
    )
    length(matches) == 1 && return matches[1]
    isempty(matches) && return nothing
    return sort!(unique!(String[_split_dotted(k)[1] for k in matches]))
end

"""
    _resolve_name(name, available) -> String

The key in `available` that `name` selects. Throws [`AmbiguousPathKeyError`](@ref) when a plain leaf
sits in more than one group, and an error naming what is available when nothing matches.

Returns the KEY, not the value, so callers that need the group prefix (or the value, or neither) all
get what they need from one rule.
"""
function _resolve_name(name::AbstractString, available)
    found = _lookup_name(name, available)
    found isa String && return found
    found isa Vector && throw(AmbiguousPathKeyError(String(name), found))
    return error(
        "\"$name\" not found. Available: " *
        join(sort!(String[String(k) for k in available]), ", "),
    )
end
