# expand_report — what deduplication removed to get expand's keys.

using ParamIO
using Test

const _FIX_ER = joinpath(@__DIR__, "fixtures")

@testset "expand_report: per-block contribution separates 'added nothing' from 'not read'" begin
    spec = ParamIO.load(joinpath(_FIX_ER, "overlap.toml"))
    r = ParamIO.expand_report(spec)

    @test [p.produced for p in r.per_paramset] == [4, 4, 2]
    @test [p.kept for p in r.per_paramset] == [4, 0, 1]
    @test [p.duplicate for p in r.per_paramset] == [0, 4, 1]

    # The second block contributed nothing and the third contributed one. A total alone reports
    # only `5`, which is the number both a read block and an unread one produce.
    @test r.points == 5
    @test r.duplicates == 5
end

@testset "expand_report: disjoint blocks read zero, so the counter is not stuck high" begin
    spec = ParamIO.load(joinpath(_FIX_ER, "multi_block.toml"))
    r = ParamIO.expand_report(spec)
    @test r.duplicates == 0
    @test all(p -> p.duplicate == 0, r.per_paramset)
    @test r.points == sum(p -> p.produced, r.per_paramset)
end

@testset "expand_report: sameness is canonical, not Dict equality" begin
    # `Dict("system.N" => 24) == Dict("system.N" => 24.0)` is true in Julia, so a dedup written
    # against `Dict` would collapse these two into one directory and lose a run.
    spec = ParamIO.load(joinpath(_FIX_ER, "int_float.toml"))
    r = ParamIO.expand_report(spec)
    @test r.points == 2
    @test r.duplicates == 0
    @test Dict("system.N" => 24) == Dict("system.N" => 24.0)
end

@testset "expand_report: keys agree with expand, and count points x samples" begin
    for f in ("overlap.toml", "multi_block.toml", "duplicate.toml", "all_scalar.toml")
        spec = ParamIO.load(joinpath(_FIX_ER, f))
        r = ParamIO.expand_report(spec)
        @test r.keys == ParamIO.expand(spec)
        @test length(r.keys) == r.points * spec.study.total_samples
        @test r.points + r.duplicates == sum(p -> p.produced, r.per_paramset)
    end
end

@testset "expand_report: sweep_order reaches the report as it reaches expand" begin
    spec = ParamIO.load(joinpath(_FIX_ER, "multi_block.toml"))
    order = ["model.h", "system.N"]
    r = ParamIO.expand_report(spec; sweep_order=order)
    @test r.keys == ParamIO.expand(spec; sweep_order=order)
    # Reordering permutes the keys without changing what is distinct.
    @test r.points == ParamIO.expand_report(spec).points
    @test r.keys != ParamIO.expand(spec)
end
