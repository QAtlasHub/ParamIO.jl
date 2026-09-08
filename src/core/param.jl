# core/param.jl — reading one parameter out of a DataKey.

"""
    param(key, name) -> Any
    param(key, name, T) -> T

The value `name` selects in `key`, resolved the way `format_path` resolves a `path_key`: an exact
match on the dotted name first, then a unique match on the leaf.

`work_fn` is otherwise written as `Float64(key.params["system.kbT"])`, and both halves of that are
a hazard.

A misspelled name is a bare `KeyError` naming only the string that was wrong. It is raised inside
the work function, which is running on a worker, dispatched by `run!` — so the config that has the
right spelling and the function that has the wrong one are in different files, and nothing compares
them until a point is computed. `param` reports what the key does carry instead.

The type is the other half. TOML gives `2` as `Int64` and `2.0` as `Float64`, so a config edited
from `[2.0, 2.5]` to `[2, 3]` changes what reaches the kernel without changing anything a reader
would look at. `param(key, name, Float64)` converts, and `param(key, name, Int)` refuses a value
that is not one — `InexactError` at the boundary rather than a silent `Float64` two layers down.

```julia
a  = param(key, "system.a", Float64)
n  = param(key, "numerics.nsteps", Int)
kT = param(key, "kbT", Float64)          # leaf form, when it is unambiguous
```
"""
function param(key::DataKey, name::AbstractString)
    val = get(key.params, name, nothing)
    val !== nothing && return val

    _, leaf = _split_dotted(name)
    if leaf == name
        matches = [(k, v) for (k, v) in key.params if _split_dotted(k)[2] == name]
        if length(matches) == 1
            return matches[1][2]
        elseif length(matches) > 1
            # Same error the path builder raises for the same reason, carrying the GROUPS rather
            # than the full names — that is what its message asks the caller to disambiguate with.
            throw(
                AmbiguousPathKeyError(
                    name, sort!([_split_dotted(k)[1] for (k, _) in matches])
                ),
            )
        end
    end
    return error(
        "DataKey has no parameter \"$name\". It carries: " *
        join(sort!(collect(Base.keys(key.params))), ", ") *
        ".",
    )
end

function param(key::DataKey, name::AbstractString, ::Type{T}) where {T}
    return convert(T, param(key, name))
end
