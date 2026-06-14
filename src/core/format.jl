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
