# param(key, name[, T]) — reading one parameter out of a DataKey.
#
# The two hazards this closes are the reason it exists, so both are asserted directly rather than
# through the happy path.

using ParamIO
using Test

const _K = ParamIO.DataKey(
    Dict{String,Any}(
        "system.a" => 2, "system.kbT" => 2.5, "numerics.nsteps" => 400, "model.a" => 9
    ),
    1,
)

@testset "param: dotted, and leaf when it is unambiguous" begin
    @test param(_K, "system.kbT") == 2.5          # exact dotted match
    @test param(_K, "kbT") == 2.5                 # unique leaf
    @test param(_K, "nsteps") == 400
end

@testset "param: an ambiguous leaf throws AmbiguousPathKeyError, naming the groups" begin
    # NOT the exception `format_path` raises for this condition — that one throws a bare
    # `error`. The two disagree, and a `catch` written against one does not catch the other.
    # `a` is in both `system` and `model`. Resolving it silently to either would make the value a
    # study reads depend on Dict iteration order.
    err = try
        param(_K, "a")
        nothing
    catch e
        e
    end
    @test err isa ParamIO.AmbiguousPathKeyError
    @test err.groups == ["model", "system"]
    @test occursin("model", sprint(showerror, err))
end

@testset "param: a missing name reports what the key does carry" begin
    # The failure this replaces is a bare KeyError raised on a worker, naming only the wrong string.
    err = try
        param(_K, "system.kbt")                   # lower-case t
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    msg = err.msg
    @test occursin("system.kbt", msg)             # what was asked for
    @test occursin("system.kbT", msg)             # …and what exists, which is the point
    @test occursin("numerics.nsteps", msg)
end

@testset "param: the type is converted, and a lossy conversion is refused" begin
    # TOML gives `2` as Int64 and `2.0` as Float64, so a config edited from [2.0, 2.5] to [2, 3]
    # changes what reaches the kernel without changing anything a reader would look at.
    @test param(_K, "system.a") isa Int           # as stored
    @test param(_K, "system.a", Float64) === 2.0  # …and as asked for
    @test param(_K, "numerics.nsteps", Int) === 400

    # Asking for an Int when the value is not one must fail at the boundary, not two layers down.
    @test_throws InexactError param(_K, "system.kbT", Int)

    # …and so must the conversions `convert` performs SILENTLY. These are the ones it allows:
    # a Float64 cannot hold 2^53+1, and a Float32 cannot hold 2.1. Without the round-trip check
    # both come back as a different number with no signal — which is the hazard one type down from
    # the one this function exists to close.
    # The values matter: 2.5 is exact in Float32, so it cannot show this and would pass for the
    # wrong reason. 2.1 is not, and 2^53+1 is the smallest integer Float64 cannot hold.
    lossy = ParamIO.DataKey(
        Dict{String,Any}("system.seed" => 9007199254740993, "system.x" => 2.1), 1
    )
    @test_throws InexactError param(lossy, "system.seed", Float64)
    @test_throws InexactError param(lossy, "system.x", Float32)
    @test param(_K, "system.kbT", Float32) === 2.5f0   # …and an exact narrowing still goes through
end

@testset "param: an exact match wins before ambiguity is considered" begin
    # A top-level name and a leaf of the same spelling can coexist. The rule resolves the exact
    # match first, so `N` is the top-level one and no ambiguity is reported — even though the leaf
    # `N` genuinely sits in two groups. Worth pinning: read the other way round it looks like a bug.
    k = ParamIO.DataKey(Dict{String,Any}("N" => 99, "system.N" => 24, "model.N" => 8), 1)
    @test param(k, "N") == 99
    @test param(k, "system.N") == 24
end

# ── the conversion, across the type space ────────────────────────────────────
#
# `param(key, name, T)` is generic in `T`, so its behaviour is whatever `convert` does plus one
# guard. Testing it on `Int` and `Float64` alone measures two cells of a table with several
# interesting corners, and the guard was in fact wrong in one of them until this file grew.

struct Celsius
    v::Float64
end
Base.convert(::Type{Celsius}, x::Real) = Celsius(float(x))

const _T = ParamIO.DataKey(
    Dict{String,Any}(
        "n" => 3,                        # TOML integer
        "x" => 2.1,                      # TOML float, not exact in Float32
        "half" => 2.5,                   # …but exactly representable, so it must NOT be refused
        "big" => 9007199254740993,       # 2^53 + 1: the smallest integer Float64 cannot hold
        "s" => "abc",                    # TOML string
        "b" => true,                     # TOML boolean
        "v" => [1, 2, 3],                # TOML array carried as a fixed value
    ),
    1,
)

@testset "param(_, _, T): conversions that must go through" begin
    @test param(_T, "n", Float64) === 3.0
    @test param(_T, "n", Int) === 3
    @test param(_T, "half", Float32) === 2.5f0      # exact narrowing is not a loss
    @test param(_T, "n", Rational{Int}) == 3//1
    @test param(_T, "n", BigInt) == big(3)
    @test param(_T, "half", BigFloat) == big"2.5"
    @test param(_T, "s", String) == "abc"
    @test param(_T, "v", Vector{Float64}) == [1.0, 2.0, 3.0]
    @test param(_T, "n", Any) === 3                 # identity, not an error
end

@testset "param(_, _, T): conversions that must be refused" begin
    @test_throws InexactError param(_T, "x", Float32)      # 2.1 does not fit
    @test_throws InexactError param(_T, "big", Float64)    # 2^53+1 does not fit
    @test_throws InexactError param(_T, "x", Int)          # convert's own refusal
    @test_throws InexactError param(_T, "n", Bool)         # 3 is not a Bool
    @test_throws MethodError param(_T, "s", Int)           # no conversion exists
    @test_throws MethodError param(_T, "n", Symbol)
end

@testset "param(_, _, T): the guard stops at the numeric tower" begin
    # A user type with a `convert` method and no `==` falls back to identity comparison, so a
    # round-trip check applied here would refuse a conversion that is entirely correct — it would be
    # measuring "a different object", not "a different value". This is the case that made the first
    # version of the guard wrong.
    @test param(_T, "n", Celsius) == Celsius(3.0)
    @test Celsius(3.0) != 3                          # …and the reason it would have been refused
end

@testset "param(_, _, T): Bool is a number in Julia, and that shows" begin
    # Not a defect to fix here, but worth pinning so nobody is surprised later: `Bool <: Integer`,
    # so a boolean converts to and from the numeric types without complaint.
    @test param(_T, "b", Int) === 1
    @test param(_T, "b", Float64) === 1.0
    @test param(_T, "b", Bool) === true
end
