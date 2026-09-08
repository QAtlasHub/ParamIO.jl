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
