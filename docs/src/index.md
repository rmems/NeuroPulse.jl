# TemporalFocus.jl

```@meta
CurrentModule = TemporalFocus
```

Spike-driven relevance routing and coincidence attention for modular neural systems.

TemporalFocus computes per-tick routing weights across activity-region summaries from:

- spike density
- readout surprise relative to an exponential moving average
- routing momentum
- lateral inhibition between components

The package boundary is intentionally narrow: it owns relevance routing, not a full SNN
runtime, training system, or hardware integration layer.

## Documentation

```@contents
Pages = ["overview.md", "api.md", "interop.md", "package-identity.md", "roadmap.md"]
Depth = 2
```

## Quick start

`ActivityRegion` is immutable — construct each region with concrete rates/readouts
(or replace entries in the vector). Mutating fields after construction is not supported.

```julia
using TemporalFocus

router = RegionRouter(
    n_regions = 4,
    n_out = 4,
    region_names = ["sensor", "reservoir", "memory", "decoder"],
)

regions = [
    ActivityRegion(0.85f0, Float32[0.9, 0.7, 0.3, 0.1]),
    ActivityRegion(0.45f0, Float32[0.2, 0.5, 0.4, 0.3]),
    ActivityRegion(0.25f0, Float32[0.1, 0.2, 0.8, 0.5]),
    ActivityRegion(0.15f0, Float32[0.1, 0.1, 0.3, 0.9]),
]
update_routing!(router, regions)
router.routing_weights
```

## Package

The public repository is **[NeuroPulse.jl](https://github.com/rmems/NeuroPulse.jl)**.
The loadable Julia module name is still **TemporalFocus** (UUID `b7e4c3f2-…`) until a
follow-up rename.

```@docs
TemporalFocus
```
