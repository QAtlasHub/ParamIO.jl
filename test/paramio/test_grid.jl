isdefined(@__MODULE__, :FIXTURES) || (const FIXTURES = joinpath(@__DIR__, "fixtures"))

"""
test_grid.jl — `{start, stop, length|step}` grid specs expand to sweep lists.

観点：
- 3つの形式（linspace / 整数 step / log）が正しい値・型・点数になる
- grid でない値（スカラー・リスト・grid キー以外を含む table）はそのまま素通し
- _is_grid の判別（start/stop を *含むだけ* の namespace を grid と誤認しない）
- 不正な spec は黙って固定値に落ちず error する（タイプミス検出）
- load → expand 統合：grid 軸が Cartesian 積にそのまま乗る
"""

const _eg = ParamIO._expand_grid
const _isg = ParamIO._is_grid

@testset "grid: linspace（length 形式）→ Float64" begin
    g = _eg(Dict("start" => 1.0, "stop" => 4.0, "length" => 4))
    @test g == [1.0, 2.0, 3.0, 4.0]
    @test eltype(g) == Float64
    # 端点を含む・点数ぴったり
    g31 = _eg(Dict("start" => 1.0, "stop" => 4.0, "length" => 31))
    @test length(g31) == 31
    @test g31[1] ≈ 1.0 && g31[end] ≈ 4.0
    @test g31 ≈ collect(range(1.0, 4.0; length=31))
    # 整数 start/stop でも linspace は Float（線形 length 形式の規約）
    gi = _eg(Dict("start" => 16, "stop" => 256, "length" => 5))
    @test eltype(gi) == Float64
    @test gi ≈ [16.0, 76.0, 136.0, 196.0, 256.0]
end

@testset "grid: 整数 step → Int を保つ（a:s:b）" begin
    g = _eg(Dict("start" => 16, "stop" => 128, "step" => 16))
    @test g == [16, 32, 48, 64, 80, 96, 112, 128]
    @test eltype(g) == Int
    # Float step は Float
    gf = _eg(Dict("start" => 1.0, "stop" => 2.0, "step" => 0.5))
    @test gf ≈ [1.0, 1.5, 2.0]
    @test eltype(gf) == Float64
end

@testset "grid: log（geometric）" begin
    g = _eg(Dict("start" => 1e-3, "stop" => 1.0, "length" => 4, "scale" => "log"))
    @test length(g) == 4
    @test g ≈ [1e-3, 1e-2, 1e-1, 1.0]
    @test eltype(g) == Float64
end

@testset "grid: 非 grid 値はそのまま素通し" begin
    @test _eg(32) == 32                       # スカラー
    @test _eg("TFIML") == "TFIML"             # 文字列スカラー
    @test _eg([1, 2, 3]) == [1, 2, 3]         # 既存の明示リスト
    nd = Dict("a" => 1, "b" => 2)             # grid キー以外を含む table
    @test _eg(nd) === nd
end

@testset "grid: _is_grid の判別" begin
    @test _isg(Dict("start" => 1.0, "stop" => 4.0, "length" => 7))
    @test _isg(Dict("start" => 1.0, "stop" => 4.0, "step" => 0.5))
    @test _isg(Dict("start" => 1.0, "stop" => 4.0))           # bare（expand 時に error）
    # start/stop を *含むだけ* の namespace は grid ではない（dt が grid キー以外）
    @test !_isg(Dict("start" => 0.0, "stop" => 10.0, "dt" => 0.01))
    @test !_isg(Dict("length" => 7))                          # start/stop 無し
    @test !_isg(32)                                           # スカラー
    @test !_isg([1, 2])                                       # リスト
end

@testset "grid: 不正な spec は error する（黙って固定値に落ちない）" begin
    @test_throws ErrorException _eg(Dict("start" => 1.0, "stop" => 4.0))                       # length/step 無し
    @test_throws ErrorException _eg(
        Dict("start" => 1.0, "stop" => 4.0, "length" => 4, "step" => 1)
    )  # 両方
    @test_throws ErrorException _eg(Dict("start" => 1.0, "stop" => 4.0, "length" => 1))        # length < 2
    @test_throws ErrorException _eg(Dict("start" => 1.0, "stop" => 4.0, "length" => 2.5))      # 非整数 length
    @test_throws ErrorException _eg(Dict("start" => 1.0, "stop" => 4.0, "step" => 0))          # step ゼロ
    @test_throws ErrorException _eg(Dict("start" => 4.0, "stop" => 1.0, "step" => 1.0))        # 空（向き不一致）
    @test_throws ErrorException _eg(
        Dict("start" => 0.0, "stop" => 1.0, "length" => 4, "scale" => "log")
    )  # log で非正
    @test_throws ErrorException _eg(
        Dict("start" => 1.0, "stop" => 4.0, "step" => 0.5, "scale" => "log")
    )  # log + step
    @test_throws ErrorException _eg(
        Dict("start" => 1.0, "stop" => 4.0, "length" => 4, "scale" => "bogus")
    )  # 不正 scale
end

@testset "grid: load → expand 統合（grid 軸 × リスト × namespace 衝突回避）" begin
    spec = ParamIO.load(joinpath(FIXTURES, "grid.toml"))
    keys = ParamIO.expand(spec)
    @test length(keys) == 14                                   # 7 (T grid) × 2 (chi) × 1 sample
    Ts = sort(unique(k.params["system.T"] for k in keys))
    @test Ts ≈ collect(range(1.0, 4.0; length=7))
    @test all(k.params["system.N"] == 32 for k in keys)        # 固定スカラーは全 key に乗る
    @test sort(unique(k.params["model.chi"] for k in keys)) == [16, 32]
    # `win` は start/stop を含むが grid ではない → 普通に flatten される（固定スカラー）
    @test all(k.params["win.start"] == 0.0 for k in keys)
    @test all(k.params["win.stop"] == 10.0 for k in keys)
    @test all(k.params["win.dt"] == 0.01 for k in keys)
end
