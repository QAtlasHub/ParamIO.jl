#==============================================================================
 examples/inspect.jl — see exactly what ParamIO produces from a config.

 ParamIO is layer 1 of the HPC stack: it turns a config TOML into a
 Vector{DataKey} (the list of parameter points to compute). This script makes
 the output visible — run it and read the table.

     julia --project=. examples/inspect.jl
     julia --project=. examples/inspect.jl examples/sweep.toml
==============================================================================#

using ParamIO

const CONFIG = get(ARGS, 1, joinpath(@__DIR__, "sweep.toml"))

# load: TOML → ConfigSpec (study metadata + path_keys + paramset blocks)
spec = ParamIO.load(CONFIG)
println("project_name  = ", spec.study.project_name)
println("total_samples = ", spec.study.total_samples)
println("path_keys     = ", spec.path_keys, "   (dotted group.leaf names)")

# expand: ConfigSpec → Vector{DataKey}, the Cartesian product × samples
keys = ParamIO.expand(spec)
npoints = length(keys) ÷ spec.study.total_samples
println("\nexpand() → ", length(keys), " DataKeys  (",
        npoints, " points × ", spec.study.total_samples, " samples)\n")

# For each DataKey show:
#   .params      — note keys are DOTTED ("system.N"), and fixed scalar "model.J"
#                  rides along in EVERY key even though it isn't swept
#   format_path  — the compact directory segment DataVault uses (path_keys only)
#   canonical    — the stable identity string (ALL params; used by the manifest
#                  and per-key lock; order- and Julia-version-independent)
# compact, sorted "{k=v, …}" rendering so the columns line up
paramstr(p) = "{" * join(("$k=$v" for (k, v) in sort(collect(p); by=first)), ", ") * "}"

println(rpad("DataKey.params", 42), rpad("sample", 7), rpad("format_path", 16), "canonical")
println("-"^100)
for k in keys
    println(
        rpad(paramstr(k.params), 42),
        rpad(string(k.sample), 7),
        rpad(ParamIO.format_path(k, spec.path_keys), 16),
        ParamIO.canonical(k),
    )
end

println("""

Takeaways
  • work_fn reads params by the DOTTED key:  key.params["system.N"]  (NOT ["N"])
  • format_path uses only path_keys      →  the directory name on disk
  • canonical uses ALL params + sample   →  the unique key identity (manifest/lock)
""")
