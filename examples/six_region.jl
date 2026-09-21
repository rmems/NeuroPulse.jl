# SPDX-License-Identifier: MIT OR Apache-2.0

using NeuroPulse

router = RegionRouter(
    n_regions = 6,
    n_out = 3,
    region_names = ["vision", "audio", "touch", "context", "planner", "action"],
)

# Keep this example focused on custom region sizing. The package's default
# lateral inhibition constants are tuned for the historical 4-region layout.
router.adjacency_matrix .= 0.0f0

regions = [
    ActivityRegion(0.92f0, Float32[0.9, 0.6, 0.2]),
    ActivityRegion(0.44f0, Float32[0.3, 0.8, 0.4]),
    ActivityRegion(0.31f0, Float32[0.2, 0.5, 0.7]),
    ActivityRegion(0.58f0, Float32[0.6, 0.6, 0.5]),
    ActivityRegion(0.27f0, Float32[0.4, 0.3, 0.9]),
    ActivityRegion(0.12f0, Float32[0.1, 0.2, 0.8]),
]

update_routing!(router, regions)

println("Six-region custom layout:")
for (name, weight) in zip(router.region_names, router.routing_weights)
    println(rpad(name, 10), " => ", round(weight; digits = 3))
end
println(routing_diagnostics(router))
