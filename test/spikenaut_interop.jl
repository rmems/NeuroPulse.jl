# SPDX-License-Identifier: MIT OR Apache-2.0
# Consumer contract examples; no telemetry, external packages, or hardware.
# Standalone: julia --project=. test/spikenaut_interop.jl

using NeuroPulse
using Test

@testset "Spikenaut interop examples" begin
    @testset "Neuron-major image and NeuroPulse readout boundary" begin
        # Each group of three Q8.8 words belongs to one neuron; the first
        # and last neurons fire. Non-symmetric rows catch incorrect layout.
        words = zeros(Int16, 48)
        words[1:3] .= (256, -128, 64)
        words[46:48] .= (-64, 512, 32)
        weights = permutedims(reshape(Float64.(words) ./ 256, 3, 16))
        mask = falses(16)
        mask[1] = mask[16] = true
        scores = transpose(weights) * Float64.(mask)
        @test size(weights) == (16, 3)
        @test scores == [0.75, 1.5, 0.375] # comfort, temp, power

        for readout in (Float32.(mask), Float32.(scores))
            router = RegionRouter(n_regions = 2, n_out = length(readout))
            regions = [ActivityRegion(0.0f0, readout), ActivityRegion(1.0f0, readout)]
            @test update_routing!(router, regions) === nothing
            @test sum(router.routing_weights) ≈ 1.0f0

            wrong_width = [ActivityRegion(0.0f0, readout[1:end-1]), regions[2]]
            @test_throws ArgumentError update_routing!(router, wrong_width)
            for bad_rate in (-0.01f0, 1.01f0, Float32(NaN), Float32(Inf))
                bad = [ActivityRegion(bad_rate, readout), regions[2]]
                @test_throws ArgumentError update_routing!(router, bad)
            end
        end
    end

    @testset "Host tick and signed Q8.8 reference examples" begin
        # Reference arithmetic, not an event ingestion API or a UART test.
        elapsed_ms = [0, 499, 500, 999, 1000]
        @test fld.(elapsed_ms, 500) == [0, 0, 1, 1, 2]

        # Parameter endpoints, sub-step truncation, and the UART clamp.
        grid_values = [-128.0, -1/256, -1/512, 0.0, 1/512, 1/256, 127.99609375]
        @test trunc.(Int, 256 .* grid_values) == [-32768, -1, 0, 0, 0, 1, 32767]
        uart_words = trunc.(Int, 256 .* clamp.([-128.0f0, 128.0f0], -127.99f0, 127.99f0))
        @test uart_words == [-32765, 32765]
    end

    @test read(joinpath(@__DIR__, "..", "docs", "interop.md")) ==
          read(joinpath(@__DIR__, "..", "docs", "src", "interop.md"))
end
