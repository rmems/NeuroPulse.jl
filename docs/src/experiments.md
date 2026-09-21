# Experiment Gallery

The research harness contains six deterministic, synthetic characterizations
of NeuroPulse's coincidence-attention kernels. They were ported with their
scenes, sweep grids, decision rules, and contrary findings from
`rmems/TemporalFocus.jl` at
`c0b51e2f7d473411390dc4a7667fd161326c6492`.

These results describe controlled spike scenes. They do not characterize a
real Spikenaut trace, prove training improvement, or claim a deployed runtime
benefit. Real trace characterization is a later downstream step with its own
recorded input digest and adapter boundary.

## Reproduce

```bash
julia +1.12.7 --project=experiments -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia +1.12.7 --project=experiments experiments/run_all.jl --out-dir experiments/results
```

Every entrypoint validates that the canonical TemporalFocus UUID resolves to
this NeuroPulse checkout. A run contains `config.toml`, `metrics.csv`,
`figure.png`, `summary.md`, `provenance.toml`, and snapshots of the exact
resolved Project and Manifest.

## Download the recorded run

[Download the characterization evidence bundle](assets/experiments/characterization-evidence.tar.gz)
contains all seven completed runs: configurations, numerical metrics, figures,
interpretations, source/input hashes, and resolved environment snapshots.
These runs were generated from clean NeuroPulse commit `d121fa7` on Julia
1.12.7; subsequent root-test formatting does not alter their recorded code.

Archive SHA-256: `ded6513c25751d94b3f733716d82225d8b45a3d74255e41d69e4735e45c03a2c`. The archived environment records the original
local checkout path; follow the setup above with `Pkg.develop(path=".")` to
bind the canonical UUID to your checkout when reproducing.

## Controlled findings

| Experiment | Controlled question | Observed verdict |
|---|---|---|
| [Temporal Lens](https://github.com/rmems/NeuroPulse.jl/blob/main/experiments/temporal_lens.jl) | How does coincidence weight vary over `Δt × τ`? | The sampled field is symmetric, follows the exponential ratio law, and agrees bitwise with the Float32 reference over the grid. |
| [Three Regimes](https://github.com/rmems/NeuroPulse.jl/blob/main/experiments/three_regimes.jl) | What do discrete, temporal, and continuous kernels preserve on the same scene? | Discrete keeps every same-neuron match, temporal decays separated pairs, and continuous also rejects pairs outside its hard window. |
| [Focus Under Fire](https://github.com/rmems/NeuroPulse.jl/blob/main/experiments/focus_under_fire.jl) | How does controlled distractor load affect focus? | The pre-registered sweep separates the kernel behaviors; this is robustness on synthetic distractors, not a workload claim. |
| [Jitter Test](https://github.com/rmems/NeuroPulse.jl/blob/main/experiments/jitter_test.jl) | How much synthetic timestamp jitter can each configuration absorb? | Discrete attention is invariant to timestamp jitter; temporal tolerance varies non-monotonically with `τ` on the fixed scene. |
| [Attention Spotlight](https://github.com/rmems/NeuroPulse.jl/blob/main/experiments/attention_spotlight.jl) | How does focus move as deterministic buffers fill and prune? | The replay produces four stable focus segments and three handoffs while recording the exact generated scenario. |
| [Memory Gate](https://github.com/rmems/NeuroPulse.jl/blob/main/experiments/memory_gate.jl) | Where does the `τ × window` plane retain a target and reject stale pairs? | The grid contains clipped, decay-starved, selective, soft-decay, and over-retentive regimes; the best region is a corridor rather than a unique point. |

## Rendered outputs

### Temporal Lens

![Temporal Lens recency field](assets/experiments/temporal_lens.png)

### Three Regimes

![Three attention regimes](assets/experiments/three_regimes.png)

### Focus Under Fire

![Focus retention under synthetic distractors](assets/experiments/focus_under_fire.png)

### Jitter Test

![Timestamp jitter characterization](assets/experiments/jitter_test.png)

### Attention Spotlight

![Deterministic focus replay](assets/experiments/attention_spotlight.png)

### Memory Gate

![Tau by window memory surface](assets/experiments/memory_gate.png)
