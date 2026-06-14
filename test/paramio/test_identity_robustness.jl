isdefined(@__MODULE__, :FIXTURES) || (const FIXTURES = joinpath(@__DIR__, "fixtures"))

"""
test_identity_robustness.jl — identity & robustness fixes

- `expand` dedups on the `canonical` identity, not raw `Dict` equality, so
  Int-vs-Float-equal points (`8` vs `8.0`) no longer collapse into one (which
  disagreed with the on-disk directory identity).
- sibling samples of a point no longer alias one mutable `params` Dict.
- `[base] inherit` is recursive (grandparent chains compose) and cycle-guarded.
- `canonical` rejects keys containing reserved delimiters.
"""

@testset "expand: dedup on canonical, not Dict == (Int vs Float)" begin
    # One axis x = [8, 8.0]. `Dict` `==` says 8 == 8.0, but canonical (and the
    # on-disk identity) keep them distinct, so both points must survive.
    spec = ParamIO.ConfigSpec(
        ParamIO.StudySpec("t", 1, "out"),
        ["x"],
        [Dict{String,Any}("x" => Any[8, 8.0])],
        String[],
    )
    keys = ParamIO.expand(spec)
    @test length(keys) == 2
    @test Set(ParamIO.canonical(k) for k in keys) ==
        Set(["x=8;#sample=1", "x=8.0;#sample=1"])
end

@testset "expand: sibling samples have independent params" begin
    spec = ParamIO.ConfigSpec(
        ParamIO.StudySpec("t", 2, "out"), ["x"], [Dict{String,Any}("x" => 1)], String[]
    )
    keys = ParamIO.expand(spec)
    @test length(keys) == 2
    @test keys[1].params !== keys[2].params          # not aliased
    keys[1].params["x"] = 999
    @test keys[2].params["x"] == 1                    # sibling untouched
end

@testset "load: recursive [base] inherit (grandparent chain)" begin
    spec = ParamIO.load(joinpath(FIXTURES, "gc.toml"))
    # [study] is set only in the grandparent (gp) — must survive two levels.
    @test spec.study.project_name == "gp_study"
    # paramsets concatenate gp + mid + gc = 3 blocks (the old non-recursive
    # load dropped gp's block, yielding 2).
    @test length(spec.paramsets) == 3
    @test any(haskey(b, "model.gp_marker") for b in spec.paramsets)
    @test any(haskey(b, "model.mid_marker") for b in spec.paramsets)
    @test any(haskey(b, "model.gc_marker") for b in spec.paramsets)
end

@testset "load: circular inherit is rejected" begin
    @test_throws ErrorException ParamIO.load(joinpath(FIXTURES, "cycleA.toml"))  # 2-cycle
    @test_throws ErrorException ParamIO.load(joinpath(FIXTURES, "self.toml"))    # 1-cycle (self)
end

@testset "canonical: reserved delimiter in a key throws" begin
    @test_throws ArgumentError ParamIO.canonical(
        ParamIO.DataKey(Dict{String,Any}("a;b" => 1), 0)
    )
    @test_throws ArgumentError ParamIO.canonical(
        ParamIO.DataKey(Dict{String,Any}("a=b" => 1), 0)
    )
    # normal dotted keys are unaffected
    @test ParamIO.canonical(ParamIO.DataKey(Dict{String,Any}("system.N" => 8), 1)) ==
        "system.N=8;#sample=1"
end
