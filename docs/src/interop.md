# NeuroPulse interop contract

**Status:** frozen docs/contract (RM-460 / LIM-228 / GH#14)  
**Scope:** common data shapes at the package boundary — not new SNN types, not routing math.

This document freezes the compact interop shapes that callers and sibling systems
(including non-Julia sides) should use when feeding NeuroPulse and reading its
outputs. It describes what the package **owns** and what it **does not**.

> Routing state lives in `src/region_router.jl`; per-region summaries live in
> `src/activity_region.jl`. Prefer the generic names below. Legacy aliases
> (`LobeState`, `NeroOrchestrator`, …) remain for backward compatibility only.

---

## Ownership boundary

### What NeuroPulse owns

| Shape / symbol | Role |
|----------------|------|
| `ActivityRegion` | Compact per-region summary for one tick |
| `RegionRouter` | Mutable routing state (pre-allocated buffers) |
| `RoutingConfig` | Per-router scoring knobs (α/β/γ, EMA decay, min_score, epsilon) |
| `update_routing!` | In-place per-tick relevance update |
| `routing_diagnostics` | Lightweight string summary for logs |
| `adapt_leak!` | Optional stress → leak helper (not core routing) |
| `SpikeEvent` / `SpikeTrain` / `TemporalBuffer` | Attention submodule (ADR 0002 import) |
| `spike_attention_*` / `prune!` / `normalize_*!` | Coincidence kernels over spike events |

### What NeuroPulse does **not** own

- Neuron / synapse / membrane state
- Reservoir simulation or training loops
- Token embeddings, ANN/LLM adapters, or deployment supervision
- Hardware telemetry ingestion (callers reduce telemetry to compact rates)
- Finance / HFT semantics

`RegionRouter` still consumes compact rates and readouts — it does **not** take
spike trains. Spike trains are a separate public surface (`NeuroPulse.Attention`).

Callers that only need routing must reduce their internal state to the compact
shapes below before calling `update_routing!`.

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

For non-Julia consumers (e.g. a Rust side): treat the **routing** boundary as
arrays of `f32` with the dimensions above. `update_routing!` never requires spike
timestamps. Coincidence attention uses `SpikeEvent` / `SpikeTrain` /
`TemporalBuffer` on a separate surface.

---

## Explicit non-shapes

The following are **not** part of the **routing** freeze:

- Bare timestamp vectors or `(neuron, t)` pairs that are not `SpikeEvent`
- Full membrane or synapse tensors
- Shared “modulator” blobs beyond `ActivityRegion.output`

`SpikeEvent` / `SpikeTrain` / `TemporalBuffer` **are** package types (attention
surface). They are not inputs to `update_routing!`.

Scoring knobs **are** configurable via `RoutingConfig` / `RegionRouter(; config=...)`.
Inhibition **is** configurable via `RegionRouter(; inhibition_matrix=...)` (see
`RegionRouter` fields above). Default still seeds from the historical 4×4
`INHIBIT` table when `n_regions ≤ 4`.

If a workflow needs spike trains for coincidence attention, use
`NeuroPulse.Attention`. Only the per-tick compact activity summaries cross
into `update_routing!`.

---

## Consumer contract: Spikenaut-SNN

**Status:** consumer extension (GH#14 / RM-460), not a re-freeze — every
shape frozen above stands unchanged.

This section pins the shapes
[`rmems/Spikenaut-SNN`](https://github.com/rmems/Spikenaut-SNN) accepts from
the Julia SNN stack, so Spikenaut-SNN #95, #96, and #97 have named shapes to
map against. Spikenaut's own state contract (Spikenaut-SNN #20) applies
upstream of everything here: raw state → state adapter → encoder →
fixed-width stimuli, and logical signals are not physical axons — no
fabricated signals to fill channels.

### Stimulus frame (baseline)

The live consumer is a 16-channel stimulus frame per tick, produced by
silicon-bridge `examples/live_telemetry_loop.rs`:

| Property | Pinned value |
|----------|--------------|
| Channel count | **16** (`Input[16]` of the shipped `Input[16] → Linear[16×16] → LIF[16] → Output[16]` `NirGraph`) |
| Tick period | **500 ms** (`TICK_MS` default) |
| Live lanes | axons **0–4**, live-map order: `mem_util_pct`, `power_w`, `gpu_temp_c`, `sm_clock_mhz`, `mem_clock_mhz` |
| Idle lanes | axons **5–15** held at exactly `0` — unused width, not fake channels |
| Active lanes per frame | **1**, rotating (`lane = seq % 5`), because the flashed SoC decodes only the lowest nonzero lane of each `0xAA` frame as one input event and ignores its amplitude (silicon-hdl#112) |
| Lane value | `max(normalized * STIMULUS_GAIN, 1/256)` — gain-scaled (default `2.5`), floored at one Q8.8 step so the lane always encodes an event; the value affects logging, not on-chip membrane drive |
| Wire encoding | signed **Q8.8** per lane, SiliconBridge v3.0 UART |
| Normalization | per-field minmax onto `[0, 1]` with the frozen v3 ranges, clamped — an out-of-range sensor is a saturated axon, not a fault |

### What a SpikeStream.jl encoding must provide to replace it

A candidate encoding (Spikenaut-SNN #97) replaces the rotating baseline only
if it:

- emits the same **16-wide frame per 500 ms tick** (`Vector{Float32}` /
  `Vec<f32>`), or names the consumer that accepts a denser layout — current
  silicon decodes one lane per frame, so multi-lane frames are meaningful
  only to the software/replay path (silicon-bridge `replay_log`, or an
  analog `stim` consumer like `LiveStimAdapter`);
- keeps axons **5–15 at exactly `0`** unless the Spikenaut live map gains a
  legitimately measured signal there (Spikenaut-SNN #20's no-fabrication
  rule);
- preserves the frozen normalization semantics: per-field `[0, 1]`
  normalization, clamped, `Float32` end-to-end;
- **fails loud** on missing or non-finite samples — no zero-fill presented
  as a real measurement;
- stays representable in signed **Q8.8** after quantization, or states the
  precision it requires if it targets a different consumer.

### Rate vectors

NeuroPulse rates (`ActivityRegion.last_spike_rate` and the fields callers
reduce into it) are `Float32` in `[0, 1]` — the same normalization family
Spikenaut's frozen minmax produces. At the Spikenaut boundary a rate vector
is a **logical signal row**: it crosses the #20 adapter/encoder boundary as
`Vector{Float32}` / `Vec<f32>` and lands on axons only through the encoder.
Rates never write axons directly and never fabricate channels to fill 5–15.

### Spike trains / event lists — ownership

| Type family | Owner | Role |
|-------------|-------|------|
| `SpikeEvent` / `SpikeTrain` / `TemporalBuffer` | **TemporalFocus.jl** (imported as `NeuroPulse.Attention`, ADR 0002) | event-list types for coincidence / temporal attention inside the Julia stack |
| `SpikeEvent{T,I}` / `SpikeTrain` / `SpikeFeatureSnapshot` / `SpikeFeatureStream` | **SpikeStream.jl** | stream feature extraction and candidate stimulus encodings (#97) |
| `LiveTelemetryEncoder` rate encoder, AER bundle | **Spikenaut-SNN** (Rust, via `axon-encoder`) | spike-side encoding for consumers that eat spikes |

The two Julia `SpikeEvent` / `SpikeTrain` types are **not** unified, and
TemporalFocus spike types are not merged into NeuroPulse (non-goal).
Conversion is by field mapping:

- TemporalFocus `SpikeEvent(neuron_id, t, value)`: `neuron_id` is
  **1-based**, `t::Float32` in caller units, `value` an amplitude.
- SpikeStream `SpikeEvent(time, neuron_id)`: `time` is any finite `Real`,
  `neuron_id` an opaque integer label (0-based axon indices are legal).

**Accepted event format at the Spikenaut boundary:** an ordered stream of
`(axon, tick)` events — `axon` **0-based** in `0..15` (live-map order) and
`tick` the 500 ms frame index — equivalent per frame to one stimulus vector
with exactly the addressed lanes nonzero. On current silicon at most one
event lands per frame (lowest-lane decode), so multi-event-per-tick
producers serialize across ticks or target the software path.

### Readout

| NeuroPulse | Spikenaut-SNN |
|------------|---------------|
| `Vector{Float32}` length `n_out` per `ActivityRegion` | `Output[16]` node of the `NirGraph`; the shipped downstream readout is a **16×3 neuron-major** weight image (`parameters_output_weights.mem`, Q8.8-stored, scored in `f64` as `pred = readout * spikes`) over the 3 `spikenaut-output-row-v1` channels (`comfort`, `temp`, `power`) |

- NeuroPulse → Spikenaut: a readout vector crosses as `Vec<f32>`; when the
  consumer quantizes, elements snap to the signed Q8.8 grid (step `1/256`).
- Spikenaut → NeuroPulse: the 16-wide output (per-neuron spikes for the
  tick) is a valid `ActivityRegion.output` with `n_out = 16`, matching the
  `RegionRouter` default. Other widths need an explicit adapter — `n_out`
  is pinned by the router, not negotiated per tick.

### Routing weights

`Vector{Float32}` length `n_regions`, non-negative, sum **~1** (frozen
above) → Rust `&[f32]` / `Vec<f32>` of the same length. For a Q8.8
consumer, quantize elementwise at step `1/256` and renormalize to preserve
sum ~1. The default `min_score` (`0.01f0`) is above one Q8.8 step; any
floor below `1/256` quantizes to `0` and should be treated as `0` on the
wire.

### Rust-side summary

| Julia shape | Rust shape |
|-------------|------------|
| `Vector{Float32}` stimulus frame | `[f32; 16]` → signed-Q8.8 encode per lane |
| `Float32` rate | `f32` in `[0, 1]` (finite, clamped) |
| `(axon, tick)` event | `u8`/`usize` axon `0..15` + `u64` tick index |
| `Vector{Float32}` readout | `Vec<f32>` / `[f32; 16]` (width `n_out`) |
| `Vector{Float32}` routing weights | `Vec<f32>` length `n_regions`, sum ~1 |

FFI work now has its named consumer (Spikenaut-SNN), satisfying the
original GH#14 "no concrete consumer crate" condition; this section is the
mapping that FFI boundary should target.

### Cross-repo references

- [Spikenaut-SNN #20](https://github.com/rmems/Spikenaut-SNN/issues/20) — nervous-system state contract (adapter/encoder boundary)
- [Spikenaut-SNN #65](https://github.com/rmems/Spikenaut-SNN/issues/65) — AER bundle export from the canonical `NirGraph`
- [Spikenaut-SNN #95](https://github.com/rmems/Spikenaut-SNN/issues/95) — SynapticDistill.jl as offline trainer (model-step contract)
- [Spikenaut-SNN #96](https://github.com/rmems/Spikenaut-SNN/issues/96) — TemporalFocus.jl primitive audit (ownership assigned above)
- [Spikenaut-SNN #97](https://github.com/rmems/Spikenaut-SNN/issues/97) — SpikeStream.jl encodings vs the rotating baseline
- [silicon-hdl #112](https://github.com/rmems/silicon-hdl/issues/112) — lowest-nonzero-lane decode constraint
- silicon-bridge `examples/live_telemetry_loop.rs` — the live baseline producer
- Spikenaut-SNN `src/stim.rs` / `src/encode.rs` / `src/decision.rs` — analog `stim`, spike-side encoder, and readout contracts

---

## See also

- [`api.md`](api.md) — exported symbols and behavior notes
- [`overview.md`](overview.md) — architecture and intended usage
- Repository root README — “What NeuroPulse owns”
