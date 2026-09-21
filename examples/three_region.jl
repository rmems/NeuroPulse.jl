# SPDX-License-Identifier: MIT OR Apache-2.0

using NeuroPulse

router = RegionRouter(
    n_regions = 3,
    n_out = 4,
    region_names = ["sensor", "memory", "decoder"],
)

regions = [
    ActivityRegion(0.85f0, Float32[0.9, 0.7, 0.3, 0.1]),
    ActivityRegion(0.35f0, Float32[0.2, 0.4, 0.8, 0.6]),
    ActivityRegion(0.15f0, Float32[0.1, 0.1, 0.3, 0.9]),
]

update_routing!(router, regions)

println("Three-region routing weights:")
println(router.routing_weights)
println(routing_diagnostics(router))
