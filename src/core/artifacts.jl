# core/artifacts.jl — intermediate results shared across sweep points.
#
# A cell of a sweep often needs something expensive that depends on only SOME of its axes — a
# ground state that does not depend on the drive frequency, a basis that does not depend on the
# temperature. `[artifacts.<name>]` says which axes, and this file turns that into an identity.
# Storing, locking and reusing it is DataVault's job; ParamIO only says what it IS.

const _ARTIFACT_FIELDS = ("depends_on", "version", "per_sample")

"""
    _parse_artifacts(raw, flat_blocks) -> Dict{String,ArtifactSpec}

Read the `[artifacts]` table. Refuses what would make the identity wrong rather than merely
unusual: an unknown field (a typo of `depends_on` would otherwise declare an artifact of
NOTHING, shared by every cell), an empty `depends_on`, and a name that some `[[paramsets]]`
block does not carry (the projection is then undefined on that block's keys).
"""
function _parse_artifacts(raw::Dict{String,Any}, flat_blocks)::Dict{String,ArtifactSpec}
    out = Dict{String,ArtifactSpec}()
    haskey(raw, "artifacts") || return out
    tbl = raw["artifacts"]
    tbl isa Dict ||
        error("ParamIO.load: `artifacts` must be a table of `[artifacts.<name>]`.")

    available = Set{String}()
    for b in flat_blocks
        union!(available, Base.keys(b))
    end

    for (name, a) in tbl
        a isa Dict || error(
            "ParamIO.load: `[artifacts.$name]` must be a table with `depends_on`; got $(repr(a)).",
        )
        unknown = setdiff(Base.keys(a), _ARTIFACT_FIELDS)
        isempty(unknown) || error(
            "ParamIO.load: `[artifacts.$name]` has unknown field(s) $(join(sort!(collect(unknown)), ", ")); " *
            "expected $(join(_ARTIFACT_FIELDS, ", ")).",
        )
        haskey(a, "depends_on") ||
            error("ParamIO.load: `[artifacts.$name]` must declare `depends_on`.")
        deps = a["depends_on"]
        deps isa AbstractVector && !isempty(deps) && all(d -> d isa AbstractString, deps) ||
            error(
                "ParamIO.load: `[artifacts.$name] depends_on` must be a non-empty list of " *
                "parameter names; got $(repr(deps)). An artifact of no parameters is one " *
                "value shared by every cell — declare that explicitly with a fixed parameter.",
            )
        version = get(a, "version", 1)
        version isa Integer ||
            error("ParamIO.load: `[artifacts.$name] version` must be an integer.")
        per_sample = get(a, "per_sample", false)
        per_sample isa Bool ||
            error("ParamIO.load: `[artifacts.$name] per_sample` must be true or false.")

        resolved = String[]
        for d in deps
            k = _resolve_name(String(d), available)
            k ∈ resolved || push!(resolved, k)
        end
        for (i, b) in enumerate(flat_blocks)
            missing_here = filter(k -> !haskey(b, k), resolved)
            isempty(missing_here) || error(
                "ParamIO.load: `[artifacts.$name]` depends on $(join(missing_here, ", ")), " *
                "which paramset block $i does not carry.",
            )
        end
        out[String(name)] = ArtifactSpec(String(name), resolved, Int(version), per_sample)
    end
    return out
end

"""
    project(key::DataKey, axes; sample=key.sample) -> DataKey

`key` restricted to `axes`: the same parameters under the same dotted names, every other one
dropped. Names resolve as for [`param`](@ref). The key-level counterpart of
[`project(spec, axes)`](@ref project).
"""
function project(key::DataKey, axes::AbstractVector; sample::Integer=key.sample)::DataKey
    available = Base.keys(key.params)
    params = Dict{String,Any}()
    for a in axes
        k = _resolve_name(string(a), available)
        params[k] = key.params[k]
    end
    return DataKey(params, Int(sample))
end

function _artifact(spec::ConfigSpec, name)::ArtifactSpec
    n = string(name)
    haskey(spec.artifacts, n) && return spec.artifacts[n]
    return error(
        "artifact \"$n\" is not declared. Declared: " * (
            if isempty(spec.artifacts)
                "(none — add an `[artifacts.$n]` table)"
            else
                join(sort!(collect(Base.keys(spec.artifacts))), ", ")
            end
        ),
    )
end

"""
    artifact_key(spec, name, key) -> DataKey

The point in the artifact's own key space that `key` needs: `key` projected onto the
artifact's `depends_on`, with the sample index kept only if it declared `per_sample = true`
(otherwise `1`). Two cells get the same artifact exactly when this is equal.
"""
function artifact_key(spec::ConfigSpec, name, key::DataKey)::DataKey
    a = _artifact(spec, name)
    return project(key, a.depends_on; sample=a.per_sample ? key.sample : 1)
end

"""
    artifact_identity(spec, name, key) -> String

The artifact's on-disk identity as a stable string:

    <name>@v<version>|<canonical(artifact_key(spec, name, key))>

Deterministic across Julia versions and insertion orders, because [`canonical`](@ref) is.
DataVault hashes this for a directory name and records it in full beside the artifact.
"""
function artifact_identity(spec::ConfigSpec, name, key::DataKey)::String
    a = _artifact(spec, name)
    return string(a.name, "@v", a.version, '|', canonical(artifact_key(spec, name, key)))
end

"""
    artifact_keys(spec, name) -> Vector{DataKey}

Every distinct artifact point the sweep needs — for building them ahead of the cells that
read them, or counting them.
"""
function artifact_keys(spec::ConfigSpec, name)::Vector{DataKey}
    a = _artifact(spec, name)
    return expand(
        project(
            spec, a.depends_on; total_samples=a.per_sample ? spec.study.total_samples : 1
        ),
    )
end
