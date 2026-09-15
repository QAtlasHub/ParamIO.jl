# core/project.jl — a coordinate projection of the key space.

"""
    project(spec, axes; total_samples=spec.study.total_samples) -> ConfigSpec

The spec over `axes` alone: every other parameter is dropped, so the keys `expand` returns from it
are the distinct values of `key -> (axes...)` across the original sweep.

Names resolve as they do for [`param`](@ref): exact dotted match, else a unique leaf. An axis absent
from any one `[[paramsets]]` block is refused, because the projection is then undefined on that
block's keys rather than merely narrower.

`DataKey.sample` is not a parameter, so no entry of `axes` can select it; `total_samples` is how a
projection that does not depend on the sample index collapses it to `1`.

```julia
states = expand(project(spec, ["system.L", "model.lambda", "thermal.beta"]))
```
"""
function project(
    spec::ConfigSpec, axes::AbstractVector; total_samples::Integer=spec.study.total_samples
)::ConfigSpec
    isempty(spec.paramsets) &&
        throw(ArgumentError("project: spec has no [[paramsets]] block"))

    available = Set{String}()
    for b in spec.paramsets
        union!(available, Base.keys(b))
    end

    resolved = String[]
    for a in axes
        k = _resolve_name(string(a), available)
        k ∈ resolved || push!(resolved, k)
    end

    for (i, b) in enumerate(spec.paramsets)
        missing_here = filter(k -> !haskey(b, k), resolved)
        isempty(missing_here) || throw(
            ArgumentError(
                "project: paramset block $i does not carry $(join(missing_here, ", ")), " *
                "so the projection is undefined on its keys. Available there: " *
                join(sort!(collect(Base.keys(b))), ", "),
            ),
        )
    end

    blocks = [Dict{String,Any}(k => b[k] for k in resolved) for b in spec.paramsets]

    return ConfigSpec(
        StudySpec(spec.study.project_name, Int(total_samples), spec.study.outdir),
        copy(resolved),
        blocks,
        filter(in(resolved), spec.sweep_order),
        spec.float_format,
    )
end
