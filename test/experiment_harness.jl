using Test

@testset "isolated experiment harness" begin
    harness_path = joinpath(@__DIR__, "..", "experiments", "src", "HarnessCore.jl")
    include(harness_path)
    using .HarnessCore

    checkout = realpath(joinpath(@__DIR__, ".."))
    @test HarnessCore.repo_root() == checkout
    @test HarnessCore.validate_checkout!(TemporalFocus) == checkout

    previous = get(ENV, "TEMPORALFOCUS_RESULTS_DIR", nothing)
    try
        mktempdir() do tmp
            output = joinpath(tmp, "custom-results")
            remaining =
                HarnessCore.configure_output_dir!(["--out-dir", output, "jitter_test"],)
            @test remaining == ["jitter_test"]
            @test HarnessCore.result_dir("probe") == joinpath(output, "probe")
            @test_throws ArgumentError HarnessCore.result_dir("../escape")
        end
    finally
        if previous === nothing
            pop!(ENV, "TEMPORALFOCUS_RESULTS_DIR", nothing)
        else
            ENV["TEMPORALFOCUS_RESULTS_DIR"] = previous
        end
    end
end
