# TemporalFocus interop contract

**Status:** frozen docs/contract (RM-460 / LIM-228 / GH#14)  
**Scope:** common data shapes at the package boundary — not new SNN types, not routing math.

This document freezes the compact interop shapes that callers and sibling systems
(including non-Julia sides) should use when feeding TemporalFocus and reading its
outputs. It describes what the package **owns** and what it **does not**.

> Routing state lives in `src/region_router.jl`; per-region summaries live in
> `src/activity_region.jl`. Prefer the generic names below. Legacy aliases
> (`LobeState`, `NeroOrchestrator`, …) remain for backward compatibility only.

---

## Ownership boundary

### What TemporalFocus owns

| Shape / symbol | Role |
|----------------|------|
| `ActivityRegion` | Compact per-region summary for one tick |
| `RegionRouter` | Mutable routing state (pre-allocated buffers) |
| `RoutingConfig` | Per-router scoring knobs (α/β/γ, EMA decay, min_score, epsilon) |
| `update_routing!` | In-place per-tick relevance update |
| `routing_diagnostics` | Lightweight string summary for logs |
| `adapt_leak!` | Optional stress → leak helper (not core routing) |

### What TemporalFocus does **not** own

- Spike **event lists** or full spike **trains**
- Neuron / synapse / membrane state
- Reservoir simulation or training loops
- Token embeddings, ANN/LLM adapters, or deployment supervision
- Hardware telemetry ingestion (callers reduce telemetry to compact rates)

Callers must reduce their internal state to the compact shapes below before
calling into TemporalFocus.

---

## Core shapes

### `ActivityRegion`

```julia
struct ActivityRegion
    last_spike_rate::Float32
    output::Vector{Float32}
end
```

| Field | Type | Contract |
|-------|------|----------|
| `last_spike_rate` | `Float32` | Normalised firing rate in **`[0, 1]`** for this region this tick |
| `output` | `Vector{Float32}` | Readout vector of length **`n_out`** (same `n_out` as the router) |

Constructor helper:

```julia
ActivityRegion(n_out::Int)  # zero rate, zero readout of length n_out
```

**Caller duties**

- Supply `last_spike_rate` already normalised to `[0, 1]` (package does not rescale Hz;
  `update_routing!` rejects finite rates outside that interval).
- Ensure `length(output) == router.n_out`.
- Prefer `Float32` end-to-end; mixed precision is not part of the contract.

**Legacy alias:** `LobeState === ActivityRegion`.

---

### `RegionRouter`

Mutable routing state. Pre-allocated at construction; the hot path of
`update_routing!` does no heap allocation on these fields.

| Field | Shape | Contract |
|-------|--------|----------|
| `n_regions` | `Int` | Number of regions |
| `n_out` | `Int` | Readout width per region |
| `region_names` | `Vector{String}` length `n_regions` | Human-readable labels |
| `adjacency_matrix` | `Matrix{Float32}` `n_regions × n_regions` | Binary edge **mask**: `adjacency_matrix[src, dst] > 0` gates whether lateral inhibition is applied for that pair. Magnitude is not a continuous weight in the hot path. |
| `inhibition_matrix` | `Matrix{Float32}` `n_regions × n_regions` | Lateral inhibition coefficients. Default: for `n_regions ≤ 4`, `INHIBIT[1:n, 1:n]` (historical 4×4 table, top-left slice); for `n > 4`, a scaled lateral matrix. Callers may pass a custom full `n×n` matrix via the constructor. |
| `routing_weights` | `Vector{Float32}` length `n_regions` | **Primary output**; sums to **~1** after each tick |
| `readout_ema` | `Matrix{Float32}` `n_regions × n_out` | Per-region EMA of readouts |
| `spike_density` | `Vector{Float32}` length `n_regions` | Last tick’s rates (copy of inputs) |
| `prev_routing_weights` | `Vector{Float32}` length `n_regions` | Prior-tick `routing_weights` snapshot used for the γ momentum term; after `update_routing!` holds the pre-update weights (not equal to the just-written `routing_weights` once weights change) |
| `prev_relevance` | `Vector{Float32}` length `n_regions` | Scratch / last raw scores |
| `surprise` | `Vector{Float32}` length `n_regions` | Manifold surprise per region |
| `scratch` | `Vector{Float32}` length `n_out` | Hot-path scratch buffer |
| `tick_count` | `Int64` | Global tick counter |
| `config` | `RoutingConfig` | Per-router α/β/γ, EMA decay, min_score, epsilon |

Constructor:

```julia
RegionRouter(; n_regions=4, n_out=16, region_names=DEFAULT_REGION_NAMES,
               inhibition_matrix=nothing, config=RoutingConfig())
```

Initial `routing_weights` are uniform (`1 / n_regions`). When `inhibition_matrix`
is `nothing`, a default matrix is generated as described above; otherwise the
provided matrix must be `n_regions × n_regions`. `config.min_score` must be
`≤ 1/n_regions` in Float32 (compared to the representable uniform weight).

**Legacy alias:** `NeroOrchestrator === RegionRouter`.

---

### `RoutingConfig`

Per-router scoring knobs used by `update_routing!`.

```julia
struct RoutingConfig
    alpha::Float32
    beta::Float32
    gamma::Float32
    ema_decay::Float32
    min_score::Float32
    epsilon::Float32
end
```

| Field | Contract |
|-------|----------|
| `alpha` | Weight for spike density contribution (≥ 0) |
| `beta` | Weight for manifold surprise contribution (≥ 0) |
| `gamma` | Weight for prior routing-weight momentum `|w_{t-1} - w_{t-2}|` when producing `w_t` (≥ 0); readout movement is `surprise` / β |
| `ema_decay` | EMA smoothing factor in **`[0, 1]`** |
| `min_score` | Soft floor for routing weights (≥ 0; `min_score ≤ 1/n_regions` in Float32) |
| `epsilon` | Numerical stability floor (> 0) |

Constructor:

```julia
RoutingConfig()  # defaults match module-level ALPHA..EPSILON constants
RoutingConfig(alpha, beta, gamma, ema_decay, min_score, epsilon)
```

All values must be finite. `min_score ≤ 1/n_regions` (Float32 uniform weight) is validated by `RegionRouter` / `config=` assignment.

---

## Tick contract

```julia
update_routing!(router::RegionRouter, regions::Vector{ActivityRegion}) -> nothing
```

| Input | Requirement |
|-------|-------------|
| `regions` | `Vector{ActivityRegion}` with **`length(regions) == router.n_regions`** |
| each `regions[i].last_spike_rate` | `Float32` in `[0, 1]` |
| each `regions[i].output` | `Vector{Float32}` of length **`router.n_out`** |

| Output (in-place on `router`) | Contract |
|-------------------------------|----------|
| `router.routing_weights` | length `n_regions`, **non-negative** entries **≥ `router.config.min_score`** (positive when `min_score > 0`; zeros possible if `min_score = 0` and Float32 softmax underflows), **sum ≈ 1** (floor-preserving renorm; `min_score ≤ 1/n_regions` in Float32) |
| `router.surprise`, `router.spike_density`, … | updated diagnostics; readable after the call |
| return value | `nothing` (consume `routing_weights`, not a return vector) |

**Legacy alias:** `update_relevance! === update_routing!`.

**Routing math notes (this freeze is not bit-identical to older heads):**
- `prev_routing_weights` snapshots pre-update weights so default nonzero `gamma` affects ticks after the first
- post-softmax min-score uses floor-preserving renorm (not clamp-then-`sum+ε` alone)
- `epsilon` remains the shared stability floor for surprise and the first softmax divide

---

## Numeric conventions (interop)

| Quantity | Convention |
|----------|------------|
| Element type for rates, weights, readouts, EMA | **`Float32`** |
| Spike / activity rates | **`[0, 1]`** (normalised by the caller) |
| `routing_weights` | length `n_regions`, sum **~1** (soft floor + renorm) |
| Readout length | **`n_out`** for every region |
| Time base | Caller-defined tick; package is tick-agnostic |

For non-Julia consumers (e.g. a Rust side): treat the boundary as arrays of `f32`
with the dimensions above. TemporalFocus never requires spike timestamps or event
lists at the API surface.

---

## Explicit non-shapes

The following are **not** package types and are **not** part of this freeze:

- Spike trains / event lists (`Vector` of times or `(neuron, t)` pairs)
- Full membrane or synapse tensors
- Shared “modulator” blobs beyond `ActivityRegion.output`

Scoring knobs **are** configurable via `RoutingConfig` / `RegionRouter(; config=...)`.
Inhibition **is** configurable via `RegionRouter(; inhibition_matrix=...)` (see
`RegionRouter` fields above). Default still seeds from the historical 4×4
`INHIBIT` table when `n_regions ≤ 4`.

If a workflow needs spike trains, they belong in the surrounding SNN/runtime
package; only the per-tick compact activity summaries cross into TemporalFocus.

---

## See also

- [`api.md`](api.md) — exported symbols and behavior notes
- [`overview.md`](overview.md) — architecture and intended usage
- Repository root README — “What TemporalFocus owns”
