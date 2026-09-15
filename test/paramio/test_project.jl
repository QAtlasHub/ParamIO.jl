# project(spec, axes) — the spec over `axes` alone.

using ParamIO
using Test

const _FIX_PJ = joinpath(@__DIR__, "fixtures")

# What the projection is supposed to equal, computed the other way round: expand the FULL spec and
# group its keys by the axes. Independent of `project`, which projects the blocks and then dedups.
function _fibres(spec, axes)
    return Set(Tuple(ParamIO.param(k, a) for a in axes) for k in ParamIO.expand(spec))
end

@testset "project: the keys are the distinct values of the projected coordinates" begin
    spec = ParamIO.load(joinpath(_FIX_PJ, "multi_block.toml"))
    axes = ["system.N"]
    p = ParamIO.project(spec, axes; total_samples=1)

    @test length(ParamIO.expand(p)) == length(_fibres(spec, axes))
    @test Set(Tuple(ParamIO.param(k, a) for a in axes) for k in ParamIO.expand(p)) ==
        _fibres(spec, axes)

    # The fixture can collapse: 8 points fall onto 2, so an implementation that merely copied the
    # spec would fail here rather than pass by having nothing to do.
    @test length(ParamIO.expand(spec)) ÷ spec.study.total_samples == 8
    @test length(ParamIO.expand(p)) == 2
end

@testset "project: onto every axis is the identity, so collapsing is not unconditional" begin
    spec = ParamIO.load(joinpath(_FIX_PJ, "multi_block.toml"))
    all_axes = ["system.N", "system.chi", "model.g", "model.h"]
    p = ParamIO.project(spec, all_axes; total_samples=1)
    @test length(ParamIO.expand(p)) ==
        length(ParamIO.expand(spec)) ÷ spec.study.total_samples
end

@testset "project: a key carries the projected axes and nothing else" begin
    spec = ParamIO.load(joinpath(_FIX_PJ, "multi_block.toml"))
    p = ParamIO.project(spec, ["system.N", "model.g"])
    for k in ParamIO.expand(p)
        @test sort(collect(keys(k.params))) == ["model.g", "system.N"]
    end
    @test p.path_keys == ["system.N", "model.g"]
end

@testset "project: names resolve by leaf, and an ambiguous leaf is refused" begin
    spec = ParamIO.load(joinpath(_FIX_PJ, "multi_block.toml"))
    @test ParamIO.project(spec, ["N"]).path_keys == ["system.N"]
    @test ParamIO.expand(ParamIO.project(spec, ["N"]; total_samples=1)) ==
        ParamIO.expand(ParamIO.project(spec, ["system.N"]; total_samples=1))

    # `ambiguous.toml` cannot be `load`ed: auto-resolving path_keys throws first. Built by hand
    # so the raise under test is `project`'s own.
    amb = ParamIO.ConfigSpec(
        ParamIO.StudySpec("amb", 1, "out"),
        ["system.N"],
        [Dict{String,Any}("system.N" => [24, 48], "model.N" => [10, 20])],
        String[],
        "fixed2",
    )
    err = try
        ParamIO.project(amb, ["N"])
        nothing
    catch e
        e
    end
    @test err isa ParamIO.AmbiguousPathKeyError
    @test err.groups == ["model", "system"]
end

@testset "project: an axis no block carries is refused, not silently dropped" begin
    spec = ParamIO.load(joinpath(_FIX_PJ, "multi_block.toml"))
    @test_throws ErrorException ParamIO.project(spec, ["system.nosuch"])
end

@testset "project: an axis only SOME blocks carry is refused" begin
    # Projecting onto `b` would leave block 2's keys without it, so the fibre of a block-1 key and
    # the fibre of a block-2 key are not comparable. The blocks are built by hand because a
    # config this shape is exactly what `project` must reject.
    study = ParamIO.StudySpec("partial", 1, "out")
    spec = ParamIO.ConfigSpec(
        study,
        ["a"],
        [Dict{String,Any}("a" => [1, 2], "b" => [10, 20]), Dict{String,Any}("a" => [1, 2])],
        String[],
        "fixed2",
    )
    @test ParamIO.project(spec, ["a"]) isa ParamIO.ConfigSpec   # `a` is in both
    err = try
        ParamIO.project(spec, ["b"])
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("block 2", sprint(showerror, err))
end

@testset "project: total_samples is the only control over the sample dimension" begin
    spec = ParamIO.load(joinpath(_FIX_PJ, "multi_block.toml"))
    @test spec.study.total_samples == 2

    kept = ParamIO.project(spec, ["system.N"])
    @test kept.study.total_samples == 2
    @test length(ParamIO.expand(kept)) == 4          # 2 points x 2 samples

    collapsed = ParamIO.project(spec, ["system.N"]; total_samples=1)
    @test length(ParamIO.expand(collapsed)) == 2
end

@testset "project: the order of axes sets path_keys and nothing else" begin
    spec = ParamIO.load(joinpath(_FIX_PJ, "multi_block.toml"))
    fwd = ParamIO.project(spec, ["system.N", "model.g"]; total_samples=1)
    rev = ParamIO.project(spec, ["model.g", "system.N"]; total_samples=1)
    @test fwd.path_keys == ["system.N", "model.g"]
    @test rev.path_keys == ["model.g", "system.N"]
    @test Set(ParamIO.canonical.(ParamIO.expand(fwd))) ==
        Set(ParamIO.canonical.(ParamIO.expand(rev)))
end

@testset "project: float_format carries over, so a projected path renders like its parent" begin
    spec = ParamIO.load(joinpath(_FIX_PJ, "multi_block.toml"))
    @test ParamIO.project(spec, ["model.h"]).float_format == spec.float_format
end

@testset "project: a repeated axis is taken once" begin
    spec = ParamIO.load(joinpath(_FIX_PJ, "multi_block.toml"))
    @test ParamIO.project(spec, ["system.N", "N"]).path_keys == ["system.N"]
end
