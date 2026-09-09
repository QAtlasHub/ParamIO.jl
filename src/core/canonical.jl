# core/canonical.jl — Julia バージョン跨ぎで安定な DataKey 文字列化

"""
    canonical(key::DataKey) -> String

Return a string representation of `key` that is:

- **Deterministic** — same `key` always yields the same string, regardless of
  how `params` was constructed.
- **Order-independent** — permuting insertion order of `params` does not change
  the result (fields are sorted by key name).
- **Stable across Julia versions** — does not depend on `hash`, which is only
  guaranteed stable within a Julia version.

This is intended for use as a directory-safe identity by downstream packages
that need a lookup key (e.g. `SweepRunner.Manifest`).

## Schema(固定。変更不可)

    <k1>=<v1>;<k2>=<v2>;...;#sample=<n>

- Keys are sorted lexicographically.
- Values are formatted per `_canonical_value`:
  - `Int`, `Bool`: decimal digits / `true` / `false`
  - `Float64`, `Float32`: `repr(v)` (round-trippable, e.g. `"1.5"`, `"NaN"`)
  - `String`: double-quoted, inner `"` and `\\` escaped
  - `Symbol`: `:name`
  - `Nothing`: `nothing`
  - Anything else: `repr(v)` as a last resort
- Sample index is always appended as `#sample=<n>` so it cannot collide with
  user params.

## Examples

```jldoctest
julia> using ParamIO

julia> k = DataKey(Dict{String,Any}("N" => 8, "J" => 1.0), 3);

julia> canonical(k)
"J=1.0;N=8;#sample=3"

julia> canonical(DataKey(Dict{String,Any}("N" => 8, "J" => 1.0), 3)) ==
       canonical(DataKey(Dict{String,Any}("J" => 1.0, "N" => 8), 3))
true
```
"""
function canonical(key::DataKey)::String
    pairs = sort!(collect(key.params); by=first)
    io = IOBuffer()
    first_pair = true
    for (k, v) in pairs
        _check_canonical_key(k)
        first_pair || print(io, ';')
        first_pair = false
        print(io, k, '=', _canonical_value(v))
    end
    first_pair || print(io, ';')
    print(io, "#sample=", key.sample)
    return String(take!(io))
end

"""
    _check_canonical_key(k)

Guard the `canonical` grammar: keys must not contain the reserved delimiters
`;` or `=` (or a newline), otherwise two distinct `DataKey`s could serialize to
the same string and collide on one on-disk identity. Config-sourced keys are
always `group.leaf` (delimiter-free); this protects hand-built `DataKey`s.
"""
function _check_canonical_key(k::AbstractString)
    if occursin(';', k) || occursin('=', k) || occursin('\n', k)
        throw(
            ArgumentError(
                "ParamIO.canonical: param key $(repr(k)) contains a reserved " *
                "delimiter (';', '=', or newline). Keys must be delimiter-free " *
                "so the canonical identity stays unambiguous.",
            ),
        )
    end
    return nothing
end

function _canonical_value(v::Bool)
    return v ? "true" : "false"
end

function _canonical_value(v::Integer)
    return string(v)
end

function _canonical_value(v::AbstractFloat)
    return repr(v)  # round-trippable
end

function _canonical_value(v::AbstractString)
    s = replace(String(v), "\\" => "\\\\", "\"" => "\\\"")
    return string('"', s, '"')
end

function _canonical_value(v::Symbol)
    return string(':', v)
end

function _canonical_value(::Nothing)
    return "nothing"
end

function _canonical_value(v)
    # Fallback: show() via repr. Not as stable, but better than erroring.
    return repr(v)
end
