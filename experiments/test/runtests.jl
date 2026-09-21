using ExperimentUtils
using TemporalFocus
using Test
using TOML

@testset "experiment provenance" begin
    @test validate_checkout!(TemporalFocus) == realpath(joinpath(@__DIR__, "..", ".."))

    previous = get(ENV, "TEMPORALFOCUS_RESULTS_DIR", nothing)
    try
        mktempdir() do tmp
            output = joinpath(tmp, "results")
            @test configure_output_dir!(["--out-dir", output]) == String[]

            config_path = write_config("probe", Dict("seed" => 7))
            write_metrics("probe", [(condition = "fixed", value = 1.0f0)])
            write(figure_path("probe"), "png fixture")
            write_summary("probe", "# Probe")

            environment = joinpath(tmp, "environment")
            mkpath(environment)
            write(joinpath(environment, "Project.toml"), "name = \"Fixture\"\n")
            write(joinpath(environment, "Manifest.toml"), "julia_version = \"1.12.7\"\n")
            script = joinpath(tmp, "probe.jl")
            input = joinpath(tmp, "input.csv")
            write(script, "# deterministic experiment\n")
            write(input, "sample,value\n1,2\n")

            provenance_path = finalize_run(
                "probe";
                input_paths = [input],
                script_path = script,
                environment_dir = environment,
            )

            run_dir = dirname(config_path)
            @test isfile(joinpath(run_dir, "Project.toml"))
            @test isfile(joinpath(run_dir, "Manifest.toml"))
            provenance = TOML.parsefile(provenance_path)
            @test haskey(provenance, "generated")
            @test provenance["inputs"]["input.csv"] ==
                  "60b3b24639da18b1e6b21eb61ce584eb9f82c96770af3cb6c6c44515be749955"
            @test haskey(provenance["inputs"], "probe.jl")
            @test haskey(provenance, "package_sources")
            @test haskey(provenance["artifacts"], "metrics.csv")

            config = TOML.parsefile(config_path)
            @test !haskey(get(config, "provenance", Dict()), "generated_utc")
        end
    finally
        if previous === nothing
            pop!(ENV, "TEMPORALFOCUS_RESULTS_DIR", nothing)
        else
            ENV["TEMPORALFOCUS_RESULTS_DIR"] = previous
        end
    end
end
