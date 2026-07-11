isdefined(@__MODULE__, :FIXTURES) || (const FIXTURES = joinpath(@__DIR__, "fixtures"))

# ── clean grid → ok ─────────────────────────────────────────────────────────────

@testset "diagnose: clean grid → ok=true" begin
    spec = ParamIO.load(joinpath(FIXTURES, "basic.toml"))
    report = diagnose(spec)

    @test report isa DiagnosticReport
    @test report.ok
    @test isempty(report.collisions)
    @test isempty(report.invisible_params)
    @test isempty(report.duplicates)
    @test isempty(report.ambiguous)

    # 2 distinct points (N=24,48; g single-value list; chi/h fixed) × 3 samples
    @test report.n_points == 2
    @test report.n_samples == 3
    @test report.n_points * report.n_samples == length(ParamIO.expand(spec))

    # path form must agree with spec form on the same clean config
    report_path = diagnose(joinpath(FIXTURES, "basic.toml"))
    @test report_path.ok
    @test report_path.n_points == report.n_points
end

@testset "diagnose: clean multi-block grid → ok=true" begin
    spec = ParamIO.load(joinpath(FIXTURES, "multi_block.toml"))
    report = diagnose(spec)

    @test report.ok
    @test report.n_points == 8   # 2 (block1) + 6 (block2) distinct points
    @test report.n_points * report.n_samples == length(ParamIO.expand(spec))
end

# ── invisible param (root cause) ⇒ path collision ───────────────────────────────

@testset "diagnose: swept param omitted from path_keys → invisible + collision" begin
    report = diagnose(joinpath(FIXTURES, "invisible.toml"))

    @test !report.ok

    # (3) model.h varies across the grid but is not in path_keys → named as invisible
    @test report.invisible_params == ["model.h"]

    # (2) the omission makes 4 distinct points collapse onto 2 directory names
    @test !isempty(report.collisions)
    @test length(report.collisions) == 2
    collided_paths = sort([p for (p, _) in report.collisions])
    @test collided_paths == ["sysN24", "sysN48"]
    # each collided path carries 2 distinct points
    @test all(length(pts) == 2 for (_, pts) in report.collisions)

    # no false duplicates: the 4 points are genuinely distinct
    @test isempty(report.duplicates)
end

# ── duplicate value in a list ───────────────────────────────────────────────────

@testset "diagnose: duplicate value in list → duplicate detected" begin
    report = diagnose(joinpath(FIXTURES, "duplicate.toml"))

    @test !report.ok
    @test !isempty(report.duplicates)
    @test length(report.duplicates) == 1

    dup_point, mult = report.duplicates[1]
    @test mult == 2
    @test dup_point["system.N"] == 24

    # dedup still leaves 2 distinct points (24, 48); no phantom collision
    @test report.n_points == 2
    @test isempty(report.collisions)
    @test isempty(report.invisible_params)
end

# ── ambiguous path keys: surfaced, NOT thrown ───────────────────────────────────

@testset "diagnose: ambiguous path keys surfaced, not thrown" begin
    # `load` on this fixture throws AmbiguousPathKeyError; `diagnose` must capture it.
    report = diagnose(joinpath(FIXTURES, "ambiguous.toml"))   # must NOT throw

    @test report isa DiagnosticReport
    @test !report.ok
    @test !isempty(report.ambiguous)
    @test report.ambiguous[1] isa ParamIO.AmbiguousPathKeyError
    @test report.ambiguous[1].leaf == "N"
    @test "system" in report.ambiguous[1].groups
    @test "model" in report.ambiguous[1].groups
end

# ── show / MIME rendering is a clean, non-throwing report ────────────────────────

@testset "diagnose: show(::DiagnosticReport) renders cleanly" begin
    clean = diagnose(joinpath(FIXTURES, "basic.toml"))
    s = sprint(show, MIME("text/plain"), clean)
    @test occursin("DiagnosticReport", s)
    @test occursin("✓", s)
    @test !occursin("✗", s)   # a clean report has no failing marks

    bad = diagnose(joinpath(FIXTURES, "invisible.toml"))
    s2 = sprint(show, MIME("text/plain"), bad)
    @test occursin("✗", s2)
    @test occursin("invisible params", s2)
    @test occursin("model.h", s2)          # the culprit is named
    @test occursin("path collisions", s2)
end
