# SPDX-License-Identifier: MIT OR Apache-2.0

using NeuroPulse

"""
    reservoir_readout(seed, width)

Toy stand-in for a reservoir or upstream model readout. Real integrations should
replace this with the compact Float32 vector emitted by the surrounding system.
"""
function reservoir_readout(seed::Float32, width::Int)
    width32 = Float32(width)
    return Float32[sin(seed + Float32(i) / width32) for i = 1:width]
end

router = RegionRouter(
    n_regions = 4,
    n_out = 5,
    region_names = ["input", "reservoir_a", "reservoir_b", "readout"],
)

for tick = 1:3
    regions = [
        ActivityRegion(0.55f0 + 0.05f0 * tick, reservoir_readout(Float32(tick), 5)),
        ActivityRegion(0.75f0, reservoir_readout(Float32(tick) + 0.3f0, 5)),
        ActivityRegion(0.30f0 + 0.10f0 * tick, reservoir_readout(Float32(tick) + 0.6f0, 5)),
        ActivityRegion(0.20f0, reservoir_readout(Float32(tick) + 0.9f0, 5)),
    ]

    update_routing!(router, regions)
    println(routing_diagnostics(router))
end
