# core/param.jl — reading one parameter out of a DataKey.

"""
    param(key, name) -> Any
    param(key, name, T) -> T

The value `name` selects in `key`, resolved by the same rule as a `path_key`: an exact match on the
dotted name, else a unique match on the leaf. See `_resolve_name`.

`work_fn` is otherwise written as `Float64(key.params["system.kbT"])`, and both halves of that are
a hazard.

A misspelled name is a bare `KeyError` naming only the string that was wrong. It is raised inside
the work function, which is running on a worker, dispatched by `run!` — so the config that has the
right spelling and the function that has the wrong one are in different files, and nothing compares
them until a point is computed. `param` reports what the key does carry instead.

The type is the other half. TOML gives `2` as `Int64` and `2.0` as `Float64`, so a config edited
from `[2.0, 2.5]` to `[2, 3]` changes what reaches the kernel without changing anything a reader
would look at.

`param(key, name, T)` converts and then checks the value survived it, so any `T` that would have
altered the number is refused rather than returned. `convert` alone is not enough: it raises for
`Int` from `2.5`, but silently rounds for `Float64` from `2^53 + 1` and for `Float32` from `2.1` —
the same silent change of number, one type down from the one this exists to prevent.

```julia
a  = param(key, "system.a", Float64)
n  = param(key, "numerics.nsteps", Int)
kT = param(key, "kbT", Float64)          # leaf form, when it is unambiguous
```
"""
function param(key::DataKey, name::AbstractString)
    return key.params[_resolve_name(name, Base.keys(key.params))]
end

function param(key::DataKey, name::AbstractString, ::Type{T}) where {T}
    val = param(key, name)
    converted = convert(T, val)
    # `==` between an Int and a Float is exact in Julia, so this catches the roundings `convert`
    # performs silently. `isequal(_, true)` because a comparison can also be `missing`.
    isequal(converted == val, true) || throw(InexactError(:param, T, val))
    return converted
end
