# util/resolve.jl — the one place a name is resolved against a set of parameter keys.
#
# The rule is: an exact match on the dotted name, else a unique match on the leaf, else an error
# saying which of the two went wrong. It was written out four times — twice inline in `format_path`,
# once in `_resolve_axis_value`, once in `_validate_path_keys` — and the copies had already drifted:
# two of them raise `AmbiguousPathKeyError` and two raise a bare `error` for the same condition.

"""
    _resolve_name(name, available) -> String

The key in `available` that `name` selects, by the rule above. Throws
[`AmbiguousPathKeyError`](@ref) when a plain leaf sits in more than one group, and an error naming
what is available when nothing matches.

Returns the KEY, not the value, so callers that need the group prefix (or the value, or neither)
all get what they need from one rule.
"""
function _resolve_name(name::AbstractString, available)
    name ∈ available && return String(name)

    _, leaf = _split_dotted(String(name))
    if leaf == name
        matches = sort!([k for k in available if _split_dotted(String(k))[2] == name])
        if length(matches) == 1
            return String(matches[1])
        elseif length(matches) > 1
            throw(
                AmbiguousPathKeyError(
                    String(name), sort!([_split_dotted(String(k))[1] for k in matches])
                ),
            )
        end
    end
    return error(
        "\"$name\" not found. Available: " *
        join(sort!(String[String(k) for k in available]), ", "),
    )
end
