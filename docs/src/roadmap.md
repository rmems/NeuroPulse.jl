# TemporalFocus roadmap and candid status

## Current state

TemporalFocus is a real library, but it is still an extraction in progress.

It already provides a useful routing core:
- spike-density scoring
- EMA-based surprise tracking
- momentum-aware routing updates
- inhibition and normalization

At the same time, it still needs substantial work before it reaches the fuller long-term
shape rmems wants.

## What still needs work

### 1. Naming cleanup

The repository/package name is now `TemporalFocus`, but parts of the API still expose older
NERO-specific naming.

Examples:
- `NeroOrchestrator`
- `nero_diagnostics`
- `NERO_*` constants

That is acceptable for now, but likely not the final naming scheme.

### 2. Default assumptions are still historical

The default region names are:
- `Region1`
- `Region2`
- `Region3`
- `Region4`

Those are useful examples, but they still imply a four-component layout. Future cleanup
should separate example defaults from the core conceptual model.

### 3. Stress adaptation is generic with a default percent-scale adapter

`adapt_leak!` now supports a generic stress signal via the optional `stress_adapter`
keyword. The default adapter still interprets `[0, 100]` percent-scale input for
backward compatibility; callers may supply a custom adapter to map arbitrary stress
domains into `[0, 1]` before interpolation.

### 4. Configuration surface is still minimal

Scoring weights (α/β/γ, EMA decay, floors) remain module-level constants. That keeps the
library simple, but it limits experimentation with alternate scoring weights and
floor/normalization policies.

Inhibition matrices are already configurable: pass `inhibition_matrix=` to
`RegionRouter` (or accept the default generator for any `n_regions`).

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

A stronger future TemporalFocus would look like this:

- clean package identity with generalized naming
- explicit ownership boundaries
- neutral examples by default
- configurable routing/inhibition policies
- adapter notes with upstream SNN and reservoir libraries (compact `ActivityRegion` / `RegionRouter` shapes are already frozen in `interop.md`, GH#14)
- documentation that describes both current behavior and intended evolution

## What this library should remain

Even after more work, TemporalFocus should remain small.

It should be a routing/relevance library, not a monolithic platform.
That means future growth should sharpen the boundary rather than blur it.
