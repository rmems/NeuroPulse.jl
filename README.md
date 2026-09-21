<p align="center">
  <img src="docs/logo.png" width="220" alt="NeuroPulse">
</p>

<h1 align="center">NeuroPulse.jl</h1>
<p align="center">Spike-driven relevance routing for modular neural systems</p>

<p align="center">
  <img src="https://img.shields.io/badge/language-Julia-9558B2" alt="Julia">
  <img src="https://img.shields.io/badge/license-MIT%2FApache--2.0-blue" alt="MIT OR Apache-2.0">
</p>

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://rmems.github.io/NeuroPulse.jl/dev)

---

NeuroPulse.jl is a small Julia library for computing per-component relevance scores from
spike activity and readout change over time. The core abstraction is a routing loop that
updates component weights from:

- spike density
- readout surprise relative to an exponential moving average
- routing momentum
- lateral inhibition between components

The library is intentionally narrow. It does not try to be a full SNN runtime, an LLM
integration layer, or a hardware supervisor.

## Project status

NeuroPulse is an extracted, early-stage library. It is useful today, but it still needs a
lot of work before it reaches the broader long-term shape rmems wants for it.

What this means in practice:

- the current API is small and focused
- several defaults still reflect the original research/runtime context
- documentation and boundaries are improving, but the package is not yet the final form
- downstream integrations should treat this as an evolving library rather than a finished platform

## What NeuroPulse owns

NeuroPulse owns spike-driven relevance routing **and** coincidence attention:

- `ActivityRegion` as a compact per-region summary (`Float32` rate in `[0,1]`, readout of length `n_out`)
- `RegionRouter` as the mutable routing state (`routing_weights` length `n_regions`, sum ~1)
- `update_routing!` as the per-tick routing update
- `routing_diagnostics` for lightweight inspection/logging
- `adapt_leak!` as a small optional helper for stress-aware leak adaptation
- `SpikeEvent` / `SpikeTrain` / `TemporalBuffer` and `spike_attention_*` kernels
  (`NeuroPulse.Attention`, imported from TemporalFocus.jl — ADR 0002)

Routing still consumes compact rates and readouts. Attention is a separate public
surface for spike events and trains. See [`docs/interop.md`](docs/interop.md) and
[`docs/src/package-identity.md`](docs/src/package-identity.md).

## What NeuroPulse does not own

NeuroPulse does not own:

- full neuron or reservoir simulation
- training loops or plasticity pipelines
- token embeddings or transformer execution
- hardware telemetry ingestion
- deployment/runtime supervision
- model-specific ANN/LLM adapters
- finance / HFT semantics (order books, positions, PnL, market data)

If a workflow needs those pieces, they should live in surrounding libraries or applications
that feed compact readouts (or spike trains) into NeuroPulse.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/rmems/NeuroPulse.jl")
```

The repository, package, and loadable module are all named **NeuroPulse**. The package
keeps its canonical UUID `b7e4c3f2-1d2e-4a5b-8c9d-0e1f2a3b4c5e`.

## Quick start

```julia
using NeuroPulse

router = RegionRouter(
    n_regions = 4,
    n_out = 8,
    region_names = ["sensor", "reservoir", "memory", "decoder"],
)

regions = [
    ActivityRegion(0.82f0, Float32[0.9, 0.7, 0.2, 0.1, 0.0, 0.1, 0.3, 0.5]),
    ActivityRegion(0.28f0, Float32[0.3, 0.2, 0.1, 0.0, 0.0, 0.0, 0.2, 0.2]),
    ActivityRegion(0.41f0, Float32[0.4, 0.6, 0.5, 0.2, 0.1, 0.1, 0.0, 0.1]),
    ActivityRegion(0.12f0, Float32[0.1, 0.1, 0.0, 0.0, 0.4, 0.6, 0.8, 0.9]),
]

update_routing!(router, regions)

routing_weights = router.routing_weights
println(routing_weights)
println(routing_diagnostics(router))
```

## Examples

Worked examples live in [`examples/`](examples/):

- [`examples/three_region.jl`](examples/three_region.jl) — minimal 3-region layout
- [`examples/six_region.jl`](examples/six_region.jl) — larger layout with custom region names
- [`examples/reservoir_integration.jl`](examples/reservoir_integration.jl) — pattern for feeding compact reservoir readouts into NeuroPulse

Run any example from the repository root:

```bash
julia --project=. examples/three_region.jl
```

## Controlled experiment gallery

Six deterministic, spike-native characterization experiments and a controlled
attention-plus-routing study now live in the
isolated [`experiments/`](experiments/) environment. They cover coincidence
weighting and windowing across temporal scales, kernel regimes, distractor
load, timestamp jitter, replayed focus movement, and the `τ × window` memory
surface. These are controlled synthetic scenes that characterize the current
attention kernels; they are not evidence from a deployed Spikenaut trace and
do not establish a downstream training or runtime benefit.

From the repository root:

```bash
julia +1.12.7 --project=experiments -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia +1.12.7 --project=experiments experiments/run_all.jl --out-dir experiments/results
```

Give concurrent runs distinct `--out-dir` roots so they do not overwrite one
another's artifacts.

Each run writes deterministic `config.toml` and `metrics.csv`, a `figure.png`,
and `summary.md`, plus SHA-256 provenance and snapshots of the resolved
experiment Project and Manifest. See the [experiment gallery](docs/src/experiments.md)
for the questions, observed verdicts, and the boundary between this evidence
and later real-trace work.

### Legacy API

The old NERO/lobe names still work as backward-compatible aliases:

```julia
# These are equivalent:
LobeState == ActivityRegion
NeroOrchestrator == RegionRouter
update_relevance! == update_routing!
nero_diagnostics == routing_diagnostics
```

## Core routing rule

At each tick, NeuroPulse computes a raw score for each component:

```
score_i = α · density_i + β · surprise_i + γ · momentum_i
```

with:

- `density_i`: current normalized spike activity
- `surprise_i`: deviation from the component's EMA readout
- `momentum_i`: change in routing weight relative to the previous tick

The raw scores are then:

1. reduced by cross-component inhibition
2. clamped with a floor so components do not go fully silent
3. normalized with a softmax-like pass to produce routing weights that sum to 1

## Public API

```julia
ActivityRegion(last_spike_rate::Float32, output::Vector{Float32})
ActivityRegion(n_out::Int)

RoutingConfig(alpha, beta, gamma, ema_decay, min_score, epsilon)
RegionRouter(; n_regions=4, n_out=16, region_names=DEFAULT_REGION_NAMES,
             inhibition_matrix=nothing, config=RoutingConfig())

update_routing!(router::RegionRouter, regions::Vector{ActivityRegion})
routing_diagnostics(router::RegionRouter)
adapt_leak!(leak_rate::Ref{Float32}, stress::Real; min_leak=0.01f0, max_leak=0.25f0, stress_adapter=nothing)
save_state(router::RegionRouter)
load_state!(router::RegionRouter, snapshot)

SpikeEvent(neuron_id, t, value=1.0f0)
SpikeTrain(events=SpikeEvent[])
TemporalBuffer(window, events=SpikeEvent[])
spike_attention_discrete(source, context, readout)
spike_attention_temporal(source, context, readout; τ=1.0f0)
spike_attention_continuous(source_buffer, context_buffer, readout; τ=1.0f0)
```

Legacy aliases (`LobeState`, `NeroOrchestrator`, `update_relevance!`,
`nero_diagnostics`, and mutating `load_state`) resolve to the same
types/functions; use the preferred names above for new code.

## Default assumptions and current limitations

A few defaults still reflect the package's original extraction context:

- the default region names are `Region1`–`Region4` (historical 4-component example layout)
- for up to four regions, the default inhibition matrix preserves the historical
  example layout; larger routers receive a generated distance-decaying matrix,
  and callers may provide any validated `n_regions × n_regions` matrix
- `adapt_leak!` default stress scale is percent-like in `[0, 100]` (custom `stress_adapter` allowed)
- NERO terminology remains available as backward-compatible aliases, while the
  preferred API uses `ActivityRegion` / `RegionRouter` naming

Per-router scoring is configurable through `RoutingConfig`; module constants
serve as defaults. `save_state` and `load_state!` round-trip mutable routing
state and configuration while rejecting structurally incompatible targets.

Those defaults are serviceable, but they are not the final abstraction boundary.

## Documentation

- [Dev docs](https://rmems.github.io/NeuroPulse.jl/dev) — updates from `main` (Documenter `deploydocs`)
- Stable docs (`/stable`) appear only after the first version tag is pushed; until then use **dev**

Source markdown lives in `docs/` (Documenter pages under `docs/src/`):

- `docs/src/overview.md` — architecture, scope, and intended usage
- `docs/src/api.md` — exported types/functions and behavior notes
- `docs/src/interop.md` — frozen data-shape / interop contract (rates, readouts, routing weights)
- `docs/src/package-identity.md` — canonical UUID, rename guidance, and ADR 0002 provenance
- `docs/src/roadmap.md` — gaps, next cleanup targets, and candid project status

(Root copies under `docs/*.md` may exist for GitHub browsing; Documenter builds from `docs/src/`.)

Build locally with:

```bash
julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia --project=docs docs/make.jl
```

## Historical note

This repository is **NeuroPulse.jl** (`rmems/NeuroPulse.jl`). Code written against the
pre-rename package must change `using TemporalFocus` to `using NeuroPulse`; the old package
import is not provided as a compatibility alias. The routing aliases such as
`NeroOrchestrator` and `update_relevance!` remain available under `NeuroPulse`.

The sibling `rmems/TemporalFocus.jl` repository is the historical source of the imported
attention surface (ADR 0002). Do not add that repository's retired UUID `7f3c9f2a-…` to an
environment that already depends on this package.

Earlier names (`SpikenautAttention` / `SpikenautNero`) are historical only. NERO remains in
the current public API via `NeroOrchestrator` and `nero_diagnostics`.

## Development

Run tests with:

```bash
julia --project -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

## License

This project is licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE-2.0](LICENSE-APACHE-2.0) or <http://www.apache.org/licenses/LICENSE-2.0>)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or <http://opensource.org/licenses/MIT>)

at your option.

Contributions intentionally submitted for inclusion in this package by you, as
defined in the Apache-2.0 license, shall be dual-licensed as above, without any
additional terms or conditions.
