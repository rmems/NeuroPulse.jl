# NeuroPulse roadmap and candid status

## Current state

NeuroPulse is a real library, but it is still an extraction in progress. The
public repository, Julia package, and loadable module are `NeuroPulse`, under
the canonical UUID `b7e4c3f2-1d2e-4a5b-8c9d-0e1f2a3b4c5e`.

It already provides:
- spike-density scoring
- EMA-based surprise tracking
- momentum-aware routing updates
- inhibition and normalization
- per-router scoring through `RoutingConfig`
- validated state snapshots through `save_state` / `load_state!`
- spike-event, train, buffer, and coincidence-attention APIs imported from the
  sibling TemporalFocus implementation under ADR 0002

At the same time, it still needs substantial work before it reaches the fuller long-term
shape rmems wants.

## What still needs work

### 1. Compatibility names

The preferred routing API is already generic: `ActivityRegion`, `RegionRouter`,
`update_routing!`, and `routing_diagnostics`. The older NERO names remain as
backward-compatible aliases:

Examples:
- `NeroOrchestrator`
- `nero_diagnostics`
- `NERO_*` constants

The Julia package/module rename to `NeuroPulse` is complete. Existing consumers
must replace `using TemporalFocus` with `using NeuroPulse`; the prior package
import is not exposed as a compatibility alias. The routing aliases should be
removed only through a documented deprecation path.

### 2. Default assumptions are still historical

The default region names are:
- `Region1`
- `Region2`
- `Region3`
- `Region4`

Those are useful examples, but they still imply a four-component layout. For
`n_regions <= 4`, the default inhibition matrix also preserves the historical
top-left layout. Larger routers already receive a generated distance-decaying
matrix, and every router may provide custom names and a custom inhibition
matrix. Future cleanup should separate example defaults from the core
conceptual model without changing those supported overrides.

### 3. Stress adaptation is generic with a default percent-scale adapter

`adapt_leak!` now supports a generic stress signal via the optional `stress_adapter`
keyword. The default adapter still interprets `[0, 100]` percent-scale input for
backward compatibility; callers may supply a custom adapter to map arbitrary stress
domains into `[0, 1]` before interpolation.

### 4. Configuration and state are implemented

`RoutingConfig` provides per-router `alpha`, `beta`, `gamma`, `ema_decay`,
`min_score`, and `epsilon` values. The module-level constants are defaults and
legacy `NERO_*` aliases; they do not prevent per-router tuning. Configuration is
validated at construction and when `router.config` is replaced.

`save_state` copies mutable routing state together with labels, graph,
inhibition matrix, and `RoutingConfig`. `load_state!` validates the target
router's dimensions and structural configuration before restoring the mutable
state; `load_state` remains a mutating compatibility alias. Future work here is
operational guidance for checkpoint versioning and persistence formats, not the
absence of snapshot support.

### 5. Documentation still needs to grow with the API

This README/docs pass is a cleanup step, not the end state. Useful future docs would include:
- worked examples for custom component layouts
- adapter guidance for reservoir systems
- design notes on choosing spike-rate normalization
- stability notes for long-running routing loops

### 6. Controlled evidence now exists; real traces come later

The isolated experiment gallery now characterizes coincidence temporal
weighting and hard-window behavior on deterministic synthetic spike scenes.
Those runs preserve their exact configuration, resolved environment, inputs,
source hashes, metrics, and figures. They establish reproducible kernel
behavior under controlled conditions.

They do not establish behavior on recorded Spikenaut workloads. A later
downstream characterization should consume a versioned trace through an
explicit adapter, record the trace digest, and keep workload conclusions
separate from these synthetic controls. Training effects and deployed runtime
benefits require their own measurements.

## Desired long-term direction

A stronger future NeuroPulse would look like this:

- clean package identity with generalized naming
- explicit ownership boundaries
- neutral examples by default
- documented recipes for the existing routing and inhibition configuration surfaces
- adapter notes with upstream SNN and reservoir libraries (compact `ActivityRegion` / `RegionRouter` shapes are already frozen in `interop.md`, GH#14)
- documentation that describes both current behavior and intended evolution

## What this library should remain

Even after more work, NeuroPulse should remain small.

It should be a routing/relevance library, not a monolithic platform.
That means future growth should sharpen the boundary rather than blur it.
