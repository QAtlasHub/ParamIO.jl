"""
ParamIO — config TOML を読み込み、`DataKey` のリストに展開する

ファイル構成:
- `core/types.jl`     データ構造とエラー型
- `core/load.jl`      TOML 読み込みと継承マージ
- `core/expand.jl`    Cartesian 展開と sweep 順序制御
- `core/format.jl`    DataKey からパス文字列を生成
- `util/grid.jl`      `{start,stop,length|step}` grid spec → sweep リスト展開
- `util/flatten.jl`   サブテーブルのフラット化、ドット記法分解
- `util/path_keys.jl` path_keys の自動解決と検証
"""
module ParamIO

using TOML, Printf

export ConfigSpec, StudySpec, DataKey, AmbiguousPathKeyError
export load, expand, format_path, resolve_path_keys
export build_axis_formats, AxisFloatFmt
export canonical
export param
export diagnose, DiagnosticReport

# ── Core ──────────────────────────────────────────────────────────────────────
include("core/types.jl")

# ── Util (core が依存する) ────────────────────────────────────────────────────
include("util/grid.jl")
include("util/flatten.jl")
include("util/path_keys.jl")

# ── Core API ──────────────────────────────────────────────────────────────────
include("core/load.jl")
include("core/expand.jl")
include("core/format.jl")
include("core/param.jl")
include("core/canonical.jl")
include("core/diagnose.jl")

end # module ParamIO
