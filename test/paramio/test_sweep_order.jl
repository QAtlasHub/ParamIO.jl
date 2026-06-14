isdefined(@__MODULE__, :FIXTURES) || (const FIXTURES = joinpath(@__DIR__, "fixtures"))

"""
test_sweep_order.jl — sweep 順序制御の網羅テスト

検証ポイント:
- expand のデフォルト順序が path_keys に従うこと
- 同じ config を複数回 expand すると常に同じ順序になる（決定性）
- sweep_order kwarg で順序を上書きできる
- TOML の [datavault] sweep_order が反映される
- kwarg が TOML より優先される
- sweep_order に含まれない sweep キーは末尾に sorted で追加される
- multi-block でも各ブロックに同じ order が適用される
- 全スカラー / 単一スカラーでも壊れない
"""

using ParamIO

# ── ヘルパ ───────────────────────────────────────────────────────────────────

# DataKey のリストから sweep キーごとの値の出現順を取り出す
function sweep_sequence(keys, key_name)
    return [k.params[key_name] for k in keys]
end

# 連続する区間を「変化点」として抽出（外側ループほど変化が遅い）
function change_count(seq)
    n = 0
    for i in 2:length(seq)
        seq[i] != seq[i - 1] && (n += 1)
    end
    return n
end

# ── 決定性 ───────────────────────────────────────────────────────────────────

@testset "expand: 同じ config からの結果は決定的" begin
    spec = ParamIO.load(joinpath(FIXTURES, "basic.toml"))
    keys1 = ParamIO.expand(spec)
    keys2 = ParamIO.expand(spec)
    keys3 = ParamIO.expand(spec)
    @test keys1 == keys2 == keys3
end

@testset "expand: 順序も完全に同じ（params の各値の sequence が一致）" begin
    spec = ParamIO.load(joinpath(FIXTURES, "basic.toml"))
    keys1 = ParamIO.expand(spec)
    keys2 = ParamIO.expand(spec)
    @test sweep_sequence(keys1, "system.N") == sweep_sequence(keys2, "system.N")
end

# ── デフォルト順序: path_keys ────────────────────────────────────────────────

@testset "expand: デフォルト順序は path_keys に従う" begin
    # multi_block.toml: path_keys = ["system.N", "system.chi", "model.g", "model.h"]
    # 外側 = system.N (sweep)、内側 = model.h (sweep)
    spec = ParamIO.load(joinpath(FIXTURES, "multi_block.toml"))
    keys = ParamIO.expand(spec)

    # サンプル軸を除いた最初のサンプルだけ取り出す
    s1 = filter(k -> k.sample == 1, keys)

    # system.N の変化回数より model.h の変化回数のほうが多いはず
    n_seq = sweep_sequence(s1, "system.N")
    h_seq = sweep_sequence(s1, "model.h")
    @test change_count(h_seq) >= change_count(n_seq)
end

# ── kwarg による上書き ──────────────────────────────────────────────────────

@testset "expand: sweep_order kwarg で順序を上書きできる" begin
    spec = ParamIO.load(joinpath(FIXTURES, "basic.toml"))
    # basic.toml は N が sweep。kwarg で順序を変えても結果セットは同じ
    keys_default = ParamIO.expand(spec)
    keys_custom = ParamIO.expand(spec; sweep_order=["system.N"])
    @test Set(keys_default) == Set(keys_custom)
end

@testset "expand: sweep_order kwarg が外側→内側を切り替える" begin
    # 4 sweep軸 (a, b, c, d) を持つ動的 config
    mktempdir() do tmpdir
        cfg = joinpath(tmpdir, "fourdim.toml")
        write(
            cfg,
            """
[study]
project_name  = "fourdim"
total_samples = 1
outdir        = "out"

[datavault]
path_keys = ["a", "b", "c", "d"]

[[paramsets]]
a = [1, 2]
b = [10, 20, 30]
c = [100, 200]
d = ["x", "y"]
""",
        )
        spec = ParamIO.load(cfg)

        # デフォルト（path_keys 順）: a が外側、d が内側
        keys = ParamIO.expand(spec)
        @test length(keys) == 2 * 3 * 2 * 2
        a_seq = [k.params["a"] for k in keys]
        d_seq = [k.params["d"] for k in keys]
        # a は最も変化が遅い、d は最も速い
        @test change_count(d_seq) > change_count(a_seq)

        # 順序を逆転: d が外側、a が内側
        keys_rev = ParamIO.expand(spec; sweep_order=["d", "c", "b", "a"])
        @test length(keys_rev) == 2 * 3 * 2 * 2
        a_seq_rev = [k.params["a"] for k in keys_rev]
        d_seq_rev = [k.params["d"] for k in keys_rev]
        @test change_count(a_seq_rev) > change_count(d_seq_rev)

        # 結果セットは同じ
        @test Set(keys) == Set(keys_rev)
    end
end

@testset "expand: sweep_order に部分指定すると残りは sorted で末尾追加" begin
    mktempdir() do tmpdir
        cfg = joinpath(tmpdir, "partial.toml")
        write(
            cfg,
            """
[study]
project_name  = "partial"
total_samples = 1
outdir        = "out"

[datavault]
path_keys = ["a", "b", "c"]

[[paramsets]]
a = [1, 2]
b = [10, 20]
c = [100, 200]
""",
        )
        spec = ParamIO.load(cfg)
        # b だけ指定 → b が外側、残り (a, c) は sorted で内側
        keys = ParamIO.expand(spec; sweep_order=["b"])
        @test length(keys) == 8
        b_seq = [k.params["b"] for k in keys]
        @test change_count(b_seq) <= change_count([k.params["a"] for k in keys])
    end
end

# ── TOML の sweep_order キー ─────────────────────────────────────────────────

@testset "load: [datavault] sweep_order を読み込む" begin
    spec = ParamIO.load(joinpath(FIXTURES, "sweep_order.toml"))
    @test spec.sweep_order == ["model.h", "system.N", "system.chi", "model.g"]
end

@testset "expand: TOML の sweep_order が path_keys より優先される" begin
    spec = ParamIO.load(joinpath(FIXTURES, "sweep_order.toml"))
    keys = ParamIO.expand(spec)

    # sweep_order: ["model.h", "system.N", "system.chi", "model.g"]
    # → model.h が最も変化が遅く、model.g が最も速い
    h_seq = [k.params["model.h"] for k in keys]
    g_seq = [k.params["model.g"] for k in keys]
    @test change_count(g_seq) > change_count(h_seq)
end

@testset "expand: kwarg が TOML より優先" begin
    spec = ParamIO.load(joinpath(FIXTURES, "sweep_order.toml"))
    # kwarg で逆転
    keys = ParamIO.expand(
        spec; sweep_order=["model.g", "system.chi", "system.N", "model.h"]
    )
    g_seq = [k.params["model.g"] for k in keys]
    h_seq = [k.params["model.h"] for k in keys]
    # g が最も遅い、h が最も速いはず
    @test change_count(h_seq) > change_count(g_seq)
end

# ── エッジケース ─────────────────────────────────────────────────────────────

@testset "expand: sweep 軸ゼロ (全スカラー) でも壊れない" begin
    spec = ParamIO.load(joinpath(FIXTURES, "all_scalar.toml"))
    keys = ParamIO.expand(spec)
    @test length(keys) == 3  # total_samples のみ
end

@testset "expand: sweep_order に存在しないキーが含まれていても無視" begin
    spec = ParamIO.load(joinpath(FIXTURES, "basic.toml"))
    keys = ParamIO.expand(spec; sweep_order=["nonexistent_key", "system.N"])
    @test length(keys) > 0  # 存在しないキーはスキップして system.N で動く
end

@testset "expand: ConfigSpec を直接コンストラクト（後方互換）" begin
    # sweep_order を渡さない既存パターン
    study = StudySpec("test", 2, "out")
    paramsets = [Dict{String,Any}("N" => [24, 48], "g" => 0.5)]
    spec = ConfigSpec(study, ["N", "g"], paramsets)
    @test spec.sweep_order == String[]
    keys = ParamIO.expand(spec)
    @test length(keys) == 2 * 2  # 2 N × 2 samples
end
