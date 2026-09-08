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

@testset "param: an ambiguous leaf names the groups, like the path builder" begin
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
end
