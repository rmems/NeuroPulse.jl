# SPDX-License-Identifier: MIT OR Apache-2.0

"""Standard-library-free path and checkout guards for the experiment harness."""
module HarnessCore

export configure_output_dir!, validate_checkout!, prepare_experiment!
export repo_root, result_dir, figure_path

const _RESULTS_ENV = "TEMPORALFOCUS_RESULTS_DIR"
const _SLUG_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._-]*$"

"""Return the absolute NeuroPulse checkout root derived from this source file."""
repo_root() = realpath(dirname(dirname(normpath(@__DIR__))))

"""Consume `--out-dir` and return the unconsumed command-line arguments."""
function configure_output_dir!(args::AbstractVector{<:AbstractString})
    remaining = String[]
    output = nothing
    i = 1
    while i <= length(args)
        arg = String(args[i])
        if arg == "--out-dir"
            i == length(args) && throw(ArgumentError("--out-dir requires a path"))
            output === nothing || throw(ArgumentError("--out-dir may be supplied only once"))
            output = String(args[i + 1])
            isempty(output) && throw(ArgumentError("--out-dir requires a non-empty path"))
            i += 2
        elseif startswith(arg, "--out-dir=")
            output === nothing || throw(ArgumentError("--out-dir may be supplied only once"))
            output = only(split(arg, '='; limit = 2)[2:2])
            isempty(output) && throw(ArgumentError("--out-dir requires a non-empty path"))
            i += 1
        else
            push!(remaining, arg)
            i += 1
        end
    end
    output === nothing || (ENV[_RESULTS_ENV] = abspath(output))
    return remaining
end

"""Fail unless the canonical TemporalFocus UUID is loaded from this checkout."""
function validate_checkout!(package_module::Module)
    package_id = Base.PkgId(package_module)
    string(package_id.uuid) == "b7e4c3f2-1d2e-4a5b-8c9d-0e1f2a3b4c5e" ||
        error("experiment loaded TemporalFocus with unexpected UUID $(package_id.uuid)")
    package_dir = Base.pkgdir(package_module)
    package_dir === nothing && error("experiment package has no pkgdir")
    actual = realpath(package_dir)
    expected = repo_root()
    actual == expected || error(
        "experiment loaded TemporalFocus from $actual; expected this checkout at $expected",
    )
    return expected
end

"""Validate the checkout, configure output routing, and return unconsumed arguments."""
function prepare_experiment!(package_module::Module, args::AbstractVector{<:AbstractString} = ARGS)
    validate_checkout!(package_module)
    return configure_output_dir!(args)
end

_results_root() =
    abspath(get(ENV, _RESULTS_ENV, joinpath(repo_root(), "experiments", "results")))

@inline function _check_name(name::AbstractString, kind::AbstractString)
    occursin(_SLUG_PATTERN, name) && name != ".." || throw(
        ArgumentError(
            "invalid $kind $(repr(name)): expected a path-free name matching " *
            _SLUG_PATTERN.pattern,
        ),
    )
    return String(name)
end

"""Return and create the selected result directory for `slug`."""
function result_dir(slug::AbstractString)
    dir = joinpath(_results_root(), _check_name(slug, "experiment slug"))
    mkpath(dir)
    return dir
end

"""Return a validated artifact path beneath the selected result directory."""
function figure_path(slug::AbstractString, name::AbstractString = "figure.png")
    return joinpath(result_dir(slug), _check_name(name, "artifact file name"))
end

end
