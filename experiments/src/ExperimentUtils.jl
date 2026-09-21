# SPDX-License-Identifier: MIT OR Apache-2.0
# Ported from rmems/TemporalFocus.jl @ c0b51e2f7d473411390dc4a7667fd161326c6492.

"""
    ExperimentUtils

Shared artifact contract for TemporalFocus.jl experiments.

Every experiment writes into `experiments/results/<slug>/`:

| File | Written by | Contents |
|------|------------|----------|
| `config.toml` | [`write_config`](@ref) | deterministic configuration actually used |
| `metrics.csv` | [`write_metrics`](@ref) | machine-readable metric rows |
| `figure.png` | the experiment script, at [`figure_path`](@ref) | human-readable artifact |
| `summary.md` | [`write_summary`](@ref) | hypothesis, observation, and whether the result supports it |

[`finalize_run`](@ref) adds `provenance.toml` plus snapshots of the resolved
experiment `Project.toml` and `Manifest.toml`.

All paths are derived from [`repo_root`](@ref), which is computed from this
file's own location, so experiments run correctly from a fresh clone and never
depend on a local absolute path.

Pass `--out-dir PATH` to a script or `run_all.jl` to redirect the results root.
The `TEMPORALFOCUS_RESULTS_DIR` environment variable is the lower-level
equivalent used by child processes and tests.

This module depends only on Julia standard libraries. It does not load
TemporalFocus, CairoMakie, or any other experiment dependency, so it can be
`include`d from anywhere:

```julia
using ExperimentUtils                                        # experiments/ environment
include(joinpath(@__DIR__, "src", "ExperimentUtils.jl"))     # or standalone
using .ExperimentUtils
```
"""
module ExperimentUtils

using Dates
using SHA
using TOML

include("HarnessCore.jl")
using .HarnessCore: configure_output_dir!, validate_checkout!, prepare_experiment!
using .HarnessCore: repo_root, result_dir, figure_path

export configure_output_dir!, validate_checkout!, prepare_experiment!
export repo_root, result_dir, figure_path, write_config, write_metrics, write_summary
export finalize_run

const _CONFIG_FILE = "config.toml"
const _METRICS_FILE = "metrics.csv"
const _SUMMARY_FILE = "summary.md"

_toml_value(x::AbstractString) = String(x)
_toml_value(x::Bool) = x
_toml_value(x::Integer) = Int(x)
_toml_value(x::Symbol) = String(x)
_toml_value(x::Char) = string(x)
_toml_value(x::Union{Dates.DateTime,Dates.Date,Dates.Time}) = x
# TOML floats are IEEE 754 binary64 by specification, so configuration values
# are recorded as Float64. Round-tripping through the shortest decimal form
# keeps Float32 inputs readable (0.2f0 becomes 0.2, not 0.20000000298023224);
# `metrics.csv` keeps each value's own precision instead.
_toml_value(x::AbstractFloat) = isfinite(x) ? parse(Float64, _format_float(x)) : Float64(x)
_toml_value(x::AbstractDict) = _toml_table(x)
_toml_value(x::NamedTuple) = _toml_table(x)
_toml_value(x::Union{AbstractVector,Tuple}) = Any[_toml_value(v) for v in x]
_toml_value(x) = string(x)

function _toml_table(cfg)
    table = Dict{String,Any}()
    for (key, value) in pairs(cfg)
        table[string(key)] = _toml_value(value)
    end
    return table
end

function _git_output(args::Cmd)
    try
        return strip(read(pipeline(Cmd(`git -C $(repo_root()) $args`); stderr = devnull), String))
    catch
        return ""
    end
end

function _provenance()
    commit = _git_output(`rev-parse HEAD`)
    return Dict{String,Any}(
        "git_commit" => isempty(commit) ? "unknown" : commit,
        "git_dirty" => !isempty(_git_output(`status --porcelain`)),
        "julia_version" => string(VERSION),
    )
end

"""
    write_config(slug, cfg) -> String

Write the configuration a run actually used to `experiments/results/<slug>/config.toml`.

Keys are emitted sorted, so re-running with the same configuration reproduces the
same file. Values are normalized for TOML: `Float32` is widened through its
shortest decimal form (`0.2f0` → `0.2`), `Symbol` becomes a string, and nested
dictionaries/named tuples become sub-tables.

A deterministic `[provenance]` table (git commit, dirty flag, Julia version) is
appended automatically unless `cfg` already defines `provenance`. The generated
UTC timestamp is written separately by [`finalize_run`](@ref), so it cannot
change `config.toml` or `metrics.csv`.

# Arguments
- `slug::AbstractString`: experiment slug
- `cfg::AbstractDict`: configuration values (a `NamedTuple` is also accepted)

# Returns
- path of the written `config.toml`
"""
function write_config(slug::AbstractString, cfg::AbstractDict)
    table = _toml_table(cfg)
    get!(table, "provenance", _provenance())
    path = joinpath(result_dir(slug), _CONFIG_FILE)
    open(path, "w") do io
        TOML.print(io, table; sorted = true)
    end
    return path
end

write_config(slug::AbstractString, cfg::NamedTuple) = write_config(slug, Dict(pairs(cfg)))

# Every float type keeps its own precision: the value is printed by `string`,
# which is the shortest round-tripping form for Float32/Float64 and the full
# decimal expansion for BigFloat. Nothing is converted to a narrower type.
function _format_float(x::AbstractFloat)
    isnan(x) && return "NaN"
    isinf(x) && return x > 0 ? "Inf" : "-Inf"
    s = string(x)
    # Julia < 1.12 prints Float32 with an `f` exponent marker ("0.2f0", "1.0f-5").
    if occursin('f', s)
        s = replace(s, 'f' => 'e')
        endswith(s, "e0") && (s = s[1:(end - 2)])
    end
    return s
end

# Float16 shows as "Float16(0.2)"; widening to Float64 is exact and prints a
# plain number.
_format_float(x::Float16) = _format_float(Float64(x))

_csv_cell(::Nothing) = ""
_csv_cell(::Missing) = ""
_csv_cell(x::Bool) = x ? "true" : "false"
_csv_cell(x::Integer) = string(x)
_csv_cell(x::AbstractFloat) = _format_float(x)
_csv_cell(x) = _csv_escape(string(x))

function _csv_escape(s::AbstractString)
    if any(c -> c == ',' || c == '"' || c == '\n' || c == '\r', s)
        return string('"', replace(s, '"' => "\"\""), '"')
    end
    return String(s)
end

"""
    write_metrics(slug, rows) -> String

Write machine-readable metrics to `experiments/results/<slug>/metrics.csv`.

# Arguments
- `slug::AbstractString`: experiment slug
- `rows`: non-empty collection of `NamedTuple`s sharing the same field names,
  e.g. `[(dt = 0.1f0, tau = 0.2f0, weight = 0.6f0), ...]`. Field names become
  the header row, in declaration order.

Floats are written in their shortest round-tripping decimal form (`Float32`
never leaks a `f0` suffix), `nothing`/`missing` become empty cells, and string
cells are quoted only when they contain a comma, quote, or newline.

# Returns
- path of the written `metrics.csv`

# Throws
- `ArgumentError` if `rows` is empty, holds anything other than `NamedTuple`s,
  or the rows disagree on field names
"""
function write_metrics(slug::AbstractString, rows)
    collected = collect(rows)
    isempty(collected) && throw(ArgumentError("metrics rows must not be empty"))
    for (i, row) in enumerate(collected)
        row isa NamedTuple ||
            throw(ArgumentError("metrics row $(i) is a $(typeof(row)); expected a NamedTuple"))
    end
    header = keys(first(collected))
    for (i, row) in enumerate(collected)
        keys(row) == header ||
            throw(ArgumentError("metrics row $(i) has columns $(keys(row)); expected $(header)"))
    end

    path = joinpath(result_dir(slug), _METRICS_FILE)
    open(path, "w") do io
        println(io, join((_csv_escape(string(name)) for name in header), ","))
        for row in collected
            println(io, join((_csv_cell(value) for value in values(row)), ","))
        end
    end
    return path
end

"""
    write_summary(slug, md) -> String

Write a human-readable summary to `experiments/results/<slug>/summary.md`.

The summary is where an experiment states its hypothesis and whether the
observed result supports it. A trailing newline is added if `md` lacks one.

# Arguments
- `slug::AbstractString`: experiment slug
- `md::AbstractString`: Markdown body

# Returns
- path of the written `summary.md`
"""
function write_summary(slug::AbstractString, md::AbstractString)
    path = joinpath(result_dir(slug), _SUMMARY_FILE)
    open(path, "w") do io
        write(io, md)
        endswith(md, "\n") || write(io, "\n")
    end
    return path
end

_sha256_file(path::AbstractString) = open(path, "r") do io
    bytes2hex(SHA.sha256(io))
end

function _source_files(checkout_root::AbstractString = repo_root())
    files = String[]
    package_root = joinpath(checkout_root, "src")
    experiment_root = joinpath(checkout_root, "experiments")
    results_root = normpath(joinpath(experiment_root, "results"))
    for source_root in (package_root, experiment_root)
        isdir(source_root) || continue
        for (root, dirs, names) in walkdir(source_root)
            filter!(dir -> normpath(joinpath(root, dir)) != results_root, dirs)
            append!(files, joinpath(root, name) for name in names if endswith(name, ".jl"))
        end
    end
    return sort!(files)
end

function _source_hashes(checkout_root::AbstractString = repo_root())
    root = realpath(checkout_root)
    return Dict(
        relpath(path, root) => _sha256_file(path) for path in _source_files(root)
    )
end

function _labeled_hashes(paths)
    hashes = Dict{String,Any}()
    for path in paths
        resolved = realpath(path)
        label = basename(resolved)
        haskey(hashes, label) && throw(
            ArgumentError("cannot record two provenance inputs named $(repr(label))"),
        )
        hashes[label] = _sha256_file(resolved)
    end
    return hashes
end

"""
    finalize_run(slug; input_paths=[], script_path=PROGRAM_FILE,
                 environment_dir=dirname(Base.active_project())) -> String

Validate the four required artifacts, snapshot the exact resolved experiment
`Project.toml` and `Manifest.toml`, and write `provenance.toml`. Hashes cover the
artifacts, the executing script, any data-dependent inputs supplied by the
experiment, every Julia source file under `src/` and `experiments/` (excluding
generated results), and the resolved environment. The UTC generation time
lives only in `provenance.toml`; deterministic metrics and configuration remain
timestamp-free.
"""
function finalize_run(
    slug::AbstractString;
    input_paths::AbstractVector{<:AbstractString} = String[],
    script_path::AbstractString = PROGRAM_FILE,
    environment_dir::AbstractString = dirname(Base.active_project()),
)
    dir = result_dir(slug)
    required = [_CONFIG_FILE, _METRICS_FILE, "figure.png", _SUMMARY_FILE]
    for name in required
        isfile(joinpath(dir, name)) || error(
            "experiment $(repr(slug)) did not produce required artifact $name",
        )
    end

    project_source = joinpath(environment_dir, "Project.toml")
    manifest_source = joinpath(environment_dir, "Manifest.toml")
    isfile(project_source) || error("resolved experiment Project.toml not found at $project_source")
    isfile(manifest_source) || error("resolved experiment Manifest.toml not found at $manifest_source")
    project_snapshot = joinpath(dir, "Project.toml")
    manifest_snapshot = joinpath(dir, "Manifest.toml")
    cp(project_source, project_snapshot; force = true)
    cp(manifest_source, manifest_snapshot; force = true)

    artifact_names = vcat(required, ["Project.toml", "Manifest.toml"])
    artifacts = Dict(name => _sha256_file(joinpath(dir, name)) for name in artifact_names)

    script_inputs = String[script_path]
    append!(script_inputs, input_paths)
    inputs = _labeled_hashes(script_inputs)

    package_sources = _source_hashes()

    commit = _git_output(`rev-parse HEAD`)
    provenance = Dict{String,Any}(
        "generated" => Dict(
            "utc" => Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SSZ"),
            "julia_version" => string(VERSION),
        ),
        "git" => Dict(
            "commit" => isempty(commit) ? "unknown" : commit,
            "dirty" => !isempty(_git_output(`status --porcelain`)),
        ),
        "artifacts" => artifacts,
        "inputs" => inputs,
        "package_sources" => package_sources,
    )
    path = joinpath(dir, "provenance.toml")
    open(path, "w") do io
        TOML.print(io, provenance; sorted = true)
    end
    return path
end

end
