"""
test_format_auto.jl — content-aware, provably-INJECTIVE float path formatting ("auto" mode)

The legacy `%.2f` ("fixed2") format is content-blind: 0.006 and 0.008 both render
"0.01", silently overwriting one run's directory with another's. "auto" mode derives
each float axis's precision from the SET of values that axis takes across the sweep,
guaranteeing distinct values → distinct, round-trippable path segments.

These tests are the deliverable: they prove INJECTIVITY (no two distinct values share a
string) and LOSSLESSNESS (every segment parses back to its source value) across binary-
representation traps, the real AFM fine grid, sign/zero, scale spread, integer/float
mixes, pathological near-equal values, a random property battery, and the fallback path —
plus a byte-for-byte regression guard that fixed2 is completely unchanged.
"""

const _P = ParamIO
isdefined(@__MODULE__, :FIXTURES) || (const FIXTURES = joinpath(@__DIR__, "fixtures"))

# Tiny deterministic PRNG (no Random stdlib dependency in the test target).
mutable struct _LCG
    s::UInt64
end
function _next!(g::_LCG)
    g.s = 0x5851f42d4c957f2d * g.s + 0x14057b7ef767814f
    return g.s
end
_u01(g::_LCG) = (_next!(g) >> 11) / Float64(UInt64(1) << 53)
_irange(g::_LCG, a::Int, b::Int) = a + Int(_next!(g) % UInt64(b - a + 1))

# Render one axis exactly as `build_axis_formats` + `format_path` would: dedup on the
# normalized value (-0.0 ≡ 0.0), pick the axis format, and format each distinct value.
# Returns (distinct_values, segments, AxisFloatFmt).
function _render_axis(vals)
    dv = Float64[]
    seen = Set{Float64}()
    for v in vals
        nv = v == 0.0 ? 0.0 : Float64(v)
        nv in seen && continue
        push!(seen, nv)
        push!(dv, nv)
    end
    af = _P._axis_format(dv)
    segs = String[_P._format_val_auto("v", v, af) for v in dv]
    return dv, segs, af
end

# INJECTIVE: distinct (normalized) values → distinct strings.
# LOSSLESS:  every segment (minus the 1-char "v" name) parses back to its source value.
function _injective_and_lossless(vals)
    dv, segs, _ = _render_axis(vals)
    injective = length(Set(segs)) == length(dv)
    lossless = all(parse(Float64, s[2:end]) == v for (s, v) in zip(segs, dv))
    return injective && lossless
end

@testset "auto: binary-representation traps → injective + round-trip" begin
    # These are exactly the cases naive round(v, digits=d) / %.2f mangle.
    for set in ([0.006, 0.008], [0.1, 0.2, 0.3], [0.006, 0.06], [0.1, 0.3])
        @test _injective_and_lossless(set)
    end

    # fixed2 WOULD collide here (0.006, 0.008 → "0.01"); auto keeps them apart.
    _, segs, af = _render_axis([0.006, 0.008])
    @test af == _P.AxisFloatFmt(3, false)
    @test segs == ["v0.006", "v0.008"]

    # 0.006 vs 0.06 need the same precision (3) → padded, still distinct.
    _, segs2, _ = _render_axis([0.006, 0.06])
    @test segs2 == ["v0.006", "v0.060"]
end

@testset "auto: the real AFM fine grid → 14 distinct segments" begin
    grid = [
        0.002, 0.004, 0.006, 0.008, 0.01, 0.02, 0.03, 0.04, 0.05, 0.1, 0.2, 0.3, 0.4, 0.5
    ]
    dv, segs, af = _render_axis(grid)
    @test length(dv) == 14
    @test length(Set(segs)) == 14          # all 14 distinct — the whole point
    @test _injective_and_lossless(grid)
    @test af == _P.AxisFloatFmt(3, false)  # max needed decimals over the grid = 3
    @test segs[1] == "v0.002"
    @test segs[end] == "v0.500"
end

@testset "auto: sign / zero" begin
    # -1.0 vs 1.0 are DISTINCT and must stay distinct.
    dv, segs, _ = _render_axis([-1.0, 1.0])
    @test length(dv) == 2
    @test segs == ["v-1", "v1"]
    @test _injective_and_lossless([-1.0, 1.0])

    # -0.0 ≡ 0.0 : treated as ONE value, rendered once (no phantom second segment).
    dv0, segs0, _ = _render_axis([0.0, -0.0])
    @test length(dv0) == 1
    @test segs0 == ["v0"]

    # -0.5 vs 0.5 distinct.
    @test _injective_and_lossless([-0.5, 0.5])
    _, segs2, _ = _render_axis([-0.5, 0.5])
    @test segs2 == ["v-0.5", "v0.5"]
end

@testset "auto: scale spread" begin
    for set in ([0.002, 500.0], [1e-6, 1.0], [0.001, 1000.0])
        @test _injective_and_lossless(set)
    end
    _, segs, af = _render_axis([0.002, 500.0])
    @test af == _P.AxisFloatFmt(3, false)
    @test segs == ["v0.002", "v500.000"]

    _, segs2, _ = _render_axis([1e-6, 1.0])
    @test segs2 == ["v0.000001", "v1.000000"]
end

@testset "auto: integer-valued float + fractional mix must NOT collapse" begin
    # 1.0 must NOT become "1" when 1.5 forces one decimal place.
    dv, segs, af = _render_axis([1.0, 1.5, 2.0])
    @test af == _P.AxisFloatFmt(1, false)
    @test segs == ["v1.0", "v1.5", "v2.0"]
    @test _injective_and_lossless([1.0, 1.5, 2.0])

    # A pure integer-valued float axis collapses to 0 decimals (still injective).
    _, segs2, af2 = _render_axis([1.0, 2.0, 10.0])
    @test af2 == _P.AxisFloatFmt(0, false)
    @test segs2 == ["v1", "v2", "v10"]
end

@testset "auto: pathological near-equal values" begin
    @test _injective_and_lossless([0.1, 0.10000001])
    dv, segs, af = _render_axis([0.1, 0.10000001])
    @test length(Set(segs)) == 2
    @test af == _P.AxisFloatFmt(8, false)
    @test segs == ["v0.10000000", "v0.10000001"]
end

@testset "auto: fallback to per-value shortest round-trip (extreme scale)" begin
    # No fixed precision ≤ 17 can represent 1e-18 losslessly → per-value fallback.
    dv, segs, af = _render_axis([1.0, 1e-18])
    @test af.fallback
    @test segs == ["v1.0", "v1.0e-18"]
    @test _injective_and_lossless([1.0, 1e-18])

    # Fallback is injective BY CONSTRUCTION (Ryu shortest is a bijection).
    @test _injective_and_lossless([1.0, 1e-20, 3e-19, 1e-30])
end

@testset "auto: property battery — ALWAYS injective AND lossless" begin
    # (a) curated physics-flavoured sets
    curated = [
        [0.5],
        [0.0],
        [-1.0, 1.0],
        [0.1, 0.2, 0.3, 0.4, 0.5],
        [0.002, 0.004, 0.006, 0.008],
        [2.0, 10.0],
        [2.0, 5.0, 10.0],
        [0.01, 0.02, 0.03, 0.04, 0.05],
        [1.0, 1.5, 2.0, 2.5],
        [-0.5, 0.0, 0.5],
        [1e-3, 1e-2, 1e-1],
        [0.006, 0.06, 0.6],
        [123.456, 123.457],
        [0.0, -0.0, 1.0],
        [1e-6, 1e-3, 1.0, 1000.0],
    ]
    for set in curated
        @test _injective_and_lossless(set)
    end

    g = _LCG(0x0000_2026_0710_0001)
    scales = (1e-6, 1e-3, 0.01, 0.1, 1.0, 10.0, 100.0, 1000.0)

    # (b) deterministic mixed-magnitude / mixed-sign sets (fallback allowed —
    #     the guarantee holds either way).
    for _ in 1:300
        n = _irange(g, 1, 8)
        scale = scales[_irange(g, 1, length(scales))]
        set = Float64[
            round((_u01(g) - 0.5) * 2 * scale; digits=_irange(g, 0, 6)) for _ in 1:n
        ]
        @test _injective_and_lossless(set)
    end

    # (c) deterministic ROUND-decimal sets (the realistic sweep shape).
    for _ in 1:300
        n = _irange(g, 2, 6)
        d = _irange(g, 0, 5)
        mag = (1.0, 10.0, 100.0)[_irange(g, 1, 3)]
        set = Float64[round(_u01(g) * mag; digits=d) for _ in 1:n]
        @test _injective_and_lossless(set)
    end
end

@testset "auto: build_axis_formats end-to-end via ConfigSpec + format_path(3-arg)" begin
    study = _P.StudySpec("t", 1, "out")
    pk = ["system.N", "system.chi", "quench.h_quench"]
    block = Dict{String,Any}(
        "system.N" => [64],
        "system.chi" => [40, 80],
        "quench.h_quench" => [0.006, 0.008, 0.01, 0.02],
    )
    spec = _P.ConfigSpec(study, pk, [block], String[], "auto")
    af = build_axis_formats(spec)

    # Only the FLOAT axis gets an entry; integer axes (N, chi) do not.
    @test haskey(af, "quench.h_quench")
    @test !haskey(af, "system.N")
    @test !haskey(af, "system.chi")
    @test af["quench.h_quench"] == _P.AxisFloatFmt(3, false)

    # Every expanded key formats to a DISTINCT path (injective across the whole grid).
    keys = expand(spec)
    paths = String[format_path(k, pk, af) for k in keys]
    @test length(Set(paths)) == length(paths)
    # dotted keys carry their 3-char group prefix (system.N → "sysN", etc.)
    @test "sysN64_syschi40_queh_quench0.006" in paths
    @test "sysN64_syschi80_queh_quench0.020" in paths

    # A float axis with no entry in axis_formats degrades gracefully to fixed2.
    k1 = DataKey(Dict{String,Any}("g" => 0.5), 1)
    @test format_path(k1, ["g"], Dict{String,AxisFloatFmt}()) == "g0.50"
end

@testset "auto: build_axis_formats leaves int/string axes untouched" begin
    study = _P.StudySpec("t", 1, "out")
    pk = ["model.type", "system.N", "model.g"]
    block = Dict{String,Any}(
        "model.type" => "TFIML", "system.N" => [24, 48], "model.g" => [0.5]
    )
    spec = _P.ConfigSpec(study, pk, [block], String[], "auto")
    af = build_axis_formats(spec)
    @test collect(keys(af)) == ["model.g"]   # only the float axis
    for k in expand(spec)
        seg = format_path(k, pk, af)
        @test occursin("modtypeTFIML", seg)  # string unchanged (group prefix "mod")
        @test occursin("modg0.5", seg)       # float, minimal precision
    end
end

@testset "auto: diagnose uses the config-selected format" begin
    study = _P.StudySpec("t", 1, "out")
    pk = ["system.N", "quench.h"]
    # 0.006/0.008 → "0.01"; 0.002/0.004 → "0.00"; 0.01 also "0.01": fixed2 collides.
    block = Dict{String,Any}(
        "system.N" => [64], "quench.h" => [0.002, 0.004, 0.006, 0.008, 0.01, 0.02]
    )
    spec_fixed = _P.ConfigSpec(study, pk, [block], String[], "fixed2")
    spec_auto = _P.ConfigSpec(study, pk, [block], String[], "auto")

    rep_fixed = diagnose(spec_fixed)
    @test !rep_fixed.ok
    @test !isempty(rep_fixed.collisions)      # the bug, under fixed2

    rep_auto = diagnose(spec_auto)
    @test rep_auto.ok                         # content-aware format separates them
    @test isempty(rep_auto.collisions)
    @test rep_auto.n_points == 6
end

@testset "auto: load parses [datavault] float_format" begin
    dir = mktempdir()

    # explicit auto
    p_auto = joinpath(dir, "auto.toml")
    write(
        p_auto,
        """
        [study]
        project_name = "t"
        total_samples = 1
        [datavault]
        float_format = "auto"
        path_keys = ["quench.h"]
        [[paramsets]]
        [paramsets.quench]
        h = [0.006, 0.008]
        """,
    )
    spec_auto = load(p_auto)
    @test spec_auto.float_format == "auto"
    @test diagnose(spec_auto).ok

    # default (unset) → fixed2
    p_def = joinpath(dir, "def.toml")
    write(
        p_def,
        """
        [study]
        project_name = "t"
        total_samples = 1
        [datavault]
        path_keys = ["quench.h"]
        [[paramsets]]
        [paramsets.quench]
        h = [0.01, 0.02]
        """,
    )
    @test load(p_def).float_format == "fixed2"

    # invalid value → informative error
    p_bad = joinpath(dir, "bad.toml")
    write(
        p_bad,
        """
        [study]
        project_name = "t"
        [datavault]
        float_format = "nonsense"
        path_keys = ["quench.h"]
        [[paramsets]]
        [paramsets.quench]
        h = [0.01]
        """,
    )
    @test_throws Exception load(p_bad)
end

@testset "REGRESSION GUARD: fixed2 is byte-for-byte unchanged" begin
    # Default ConfigSpec still selects fixed2.
    study = _P.StudySpec("t", 1, "out")
    @test _P.ConfigSpec(study, ["N"], [Dict{String,Any}("N" => 1)]).float_format == "fixed2"
    @test _P.ConfigSpec(study, ["N"], [Dict{String,Any}("N" => 1)], String[]).float_format ==
        "fixed2"

    # The 2-arg format_path (fixed2) outputs, unchanged from before this feature.
    k = DataKey(Dict{String,Any}("N" => 0, "g" => 0.0, "h" => -0.5, "M" => -3), 1)
    @test format_path(k, ["N", "g", "h", "M"]) == "N0_g0.00_h-0.50_M-3"
    @test format_path(DataKey(Dict{String,Any}("g" => 1.234567), 1), ["g"]) == "g1.23"
    @test format_path(DataKey(Dict{String,Any}("eps" => 1.0e-6), 1), ["eps"]) == "eps0.00"
    @test format_path(
        DataKey(Dict{String,Any}("system.N" => 24, "chi" => 40), 1), ["system.N", "chi"]
    ) == "sysN24_chi40"
    @test format_path(DataKey(Dict{String,Any}("model.g" => 0.5), 1), ["g"]) == "g0.50"

    # A fixed2 config routes diagnose through the 2-arg (legacy) formatter unchanged.
    spec = load(joinpath(FIXTURES, "basic.toml"))
    @test spec.float_format == "fixed2"
    @test diagnose(spec).ok
end
