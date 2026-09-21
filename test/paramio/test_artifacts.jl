# [artifacts.<name>] — the identity of an intermediate result shared across sweep points.

using ParamIO
using Test

const _FIX_AR = joinpath(@__DIR__, "fixtures")

function _ar_write(body)
    path = tempname() * ".toml"
    write(path, """
                [study]
                project_name = "t"
                [[paramsets]]
                [paramsets.run]
                U = [0.0, 0.2]
                omega1 = [1.0, 2.0]
                """ * body)
    return path
end

@testset "artifacts: load resolves depends_on to dotted keys" begin
    spec = ParamIO.load(joinpath(_FIX_AR, "artifacts.toml"))
    gs = spec.artifacts["ground_state"]
    @test gs.depends_on == ["run.U", "run.D", "run.cutoff", "run.deltas"]
    @test gs.version == 3
    @test gs.per_sample == false
    @test spec.artifacts["noise"].per_sample == true
    @test spec.artifacts["noise"].version == 1
end

@testset "artifacts: cells share an identity exactly when their projections agree" begin
    spec = ParamIO.load(joinpath(_FIX_AR, "artifacts.toml"))
    keys = ParamIO.expand(spec)
    ids = Dict{Any,Set{String}}()
    for k in keys
        # Grouped the OTHER way round: by the declared axes read straight off the key, not by
        # `artifact_key`, so the two can disagree.
        g = (param(k, "run.U"), param(k, "run.D"))
        push!(get!(ids, g, Set{String}()), artifact_identity(spec, :ground_state, k))
    end
    @test length(ids) == 4
    @test all(s -> length(s) == 1, values(ids))                   # ω₁ and sample are shared
    @test length(unique(first.(collect.(values(ids))))) == 4      # (U, D) are not
    # The control: 24 cells collapse onto 4, so an identity that ignored the projection fails.
    @test length(keys) == 24
end

@testset "artifacts: version and per_sample enter the identity" begin
    spec = ParamIO.load(joinpath(_FIX_AR, "artifacts.toml"))
    k = first(ParamIO.expand(spec))
    id = artifact_identity(spec, "ground_state", k)
    @test startswith(id, "ground_state@v3|")
    @test occursin("run.deltas=[0.5, 0.1]", id)
    @test !occursin("omega1", id)

    bumped = ConfigSpec(
        spec.study,
        spec.path_keys,
        spec.paramsets,
        spec.sweep_order,
        spec.float_format,
        Dict(
            "ground_state" => ArtifactSpec(
                "ground_state", spec.artifacts["ground_state"].depends_on, 4, false
            ),
        ),
    )
    @test artifact_identity(bumped, "ground_state", k) != id

    s1 = ParamIO.DataKey(k.params, 1)
    s2 = ParamIO.DataKey(k.params, 2)
    @test artifact_identity(spec, "noise", s1) != artifact_identity(spec, "noise", s2)
    @test artifact_identity(spec, "ground_state", s1) ==
        artifact_identity(spec, "ground_state", s2)
end

@testset "artifacts: artifact_keys lists each distinct point once" begin
    spec = ParamIO.load(joinpath(_FIX_AR, "artifacts.toml"))
    aks = artifact_keys(spec, "ground_state")
    @test length(aks) == 4
    @test all(k -> k.sample == 1, aks)
    @test Set(canonical.(aks)) == Set(
        canonical(artifact_key(spec, "ground_state", k)) for k in ParamIO.expand(spec)
    )
    @test length(artifact_keys(spec, "noise")) == 2 * spec.study.total_samples
end

@testset "artifacts: what would make the identity wrong is refused" begin
    @test_throws ErrorException ParamIO.load(
        _ar_write("[artifacts.a]\ndepend_on = [\"U\"]\n")
    )
    @test_throws ErrorException ParamIO.load(_ar_write("[artifacts.a]\ndepends_on = []\n"))
    @test_throws ErrorException ParamIO.load(
        _ar_write("[artifacts.a]\ndepends_on = [\"nope\"]\n")
    )
    @test_throws ErrorException ParamIO.load(
        _ar_write("[artifacts.a]\ndepends_on = [\"U\"]\nversion = \"2\"\n")
    )
    # A block that does not carry a declared axis makes the projection undefined there.
    two_blocks = _ar_write(
        "[[paramsets]]\n[paramsets.run]\nomega1 = [3.0]\n[artifacts.a]\ndepends_on = [\"U\"]\n",
    )
    @test_throws ErrorException ParamIO.load(two_blocks)

    spec = ParamIO.load(_ar_write("[artifacts.a]\ndepends_on = [\"U\"]\n"))
    @test_throws ErrorException artifact_identity(spec, "b", first(ParamIO.expand(spec)))
    # And a config with no [artifacts] still loads, with none.
    @test isempty(ParamIO.load(_ar_write("")).artifacts)
end

@testset "artifacts: project keeps an artifact only if its axes survive" begin
    spec = ParamIO.load(joinpath(_FIX_AR, "artifacts.toml"))
    p = ParamIO.project(spec, ["run.U", "run.D", "run.cutoff", "run.deltas"])
    @test haskey(p.artifacts, "ground_state")
    @test haskey(p.artifacts, "noise")
    q = ParamIO.project(spec, ["run.U", "run.omega1"])
    @test !haskey(q.artifacts, "ground_state")
    @test haskey(q.artifacts, "noise")
end

@testset "artifacts: project(key, axes) keeps dotted names and resolves leaves" begin
    k = ParamIO.DataKey(
        Dict{String,Any}("run.U" => 0.2, "run.D" => 64, "run.omega1" => 1.2), 5
    )
    p = ParamIO.project(k, ["U", "run.D"])
    @test p.params == Dict{String,Any}("run.U" => 0.2, "run.D" => 64)
    @test p.sample == 5
    @test ParamIO.project(k, ["U"]; sample=1).sample == 1
end

@testset "artifacts: a child config inherits and may add artifacts" begin
    dir = mktempdir()
    write(
        joinpath(dir, "parent.toml"),
        "[study]\nproject_name = \"p\"\n[[paramsets]]\n[paramsets.run]\nU = [0.0, 0.2]\nD = [8]\n" *
        "[artifacts.gs]\ndepends_on = [\"U\"]\n",
    )
    write(
        joinpath(dir, "child.toml"),
        "[base]\ninherit = \"parent.toml\"\n[artifacts.gs]\ndepends_on = [\"U\", \"D\"]\nversion = 2\n",
    )
    spec = ParamIO.load(joinpath(dir, "child.toml"))
    @test spec.artifacts["gs"].depends_on == ["run.U", "run.D"]
    @test spec.artifacts["gs"].version == 2
end
