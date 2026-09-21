# SPDX-License-Identifier: MIT OR Apache-2.0
"""
    TemporalFocus

Spike-driven relevance routing and coincidence attention for modular neural systems.

The loadable Julia module name is `TemporalFocus` (UUID
`b7e4c3f2-1d2e-4a5b-8c9d-0e1f2a3b4c5e`). The public repository is NeuroPulse.jl.

Routing computes per-tick weights across activity-region summaries using:
- spike density (α=0.50)
- manifold surprise via EMA deviation (β=0.35)
- routing momentum (γ=0.15)

Attention (`TemporalFocus.Attention`, imported from TemporalFocus.jl / ADR 0002)
owns spike events, trains, temporal buffers, and coincidence kernels.

The package is not a full SNN runtime, training system, or hardware integration layer.

## Generic routing API (preferred)

Use `ActivityRegion`, `RegionRouter`, `update_routing!`, and `routing_diagnostics`.

## Attention API

`SpikeEvent`, `SpikeTrain`, `TemporalBuffer`, `spike_attention_*`, `temporal_weight`,
`prune!`, `normalize_l1!`, `normalize_max!`.

## Legacy API (backward compatible)

`LobeState`, `NeroOrchestrator`, `update_relevance!`, and `nero_diagnostics` are
aliases that map to the generic types. They will continue to work but new code
should prefer the generic names.
"""
module TemporalFocus

# ── Generic API (preferred) ───────────────────────────────────────────────────

include("activity_region.jl")
include("region_router.jl")

# ── Attention (imported from rmems/TemporalFocus.jl @ eb38c70, ADR 0002) ───────

include("attention/Attention.jl")
using .Attention

# ── Exports ───────────────────────────────────────────────────────────────────

# Generic API (preferred)
export ActivityRegion,
    RegionRouter, RoutingConfig, update_routing!, routing_diagnostics, adapt_leak!
export save_state, load_state!, load_state

# Attention surface (re-exported from TemporalFocus.Attention)
export SpikeEvent, SpikeTrain, TemporalBuffer
export prune!, temporal_weight
export spike_attention_discrete, spike_attention_temporal, spike_attention_continuous
export normalize_l1!, normalize_max!

# Backward-compatible type aliases
const LobeState = ActivityRegion
const NeroOrchestrator = RegionRouter

# Backward-compatible function aliases (const for type stability)
const update_relevance! = update_routing!
const nero_diagnostics = routing_diagnostics

export LobeState, NeroOrchestrator, update_relevance!, nero_diagnostics

end # module
