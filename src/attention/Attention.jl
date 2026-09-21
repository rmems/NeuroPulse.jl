# SPDX-License-Identifier: MIT OR Apache-2.0

"""
    TemporalFocus.Attention

Coincidence-based and temporally decayed spike attention, imported from
[`rmems/TemporalFocus.jl`](https://github.com/rmems/TemporalFocus.jl) at
`eb38c70aad9f077e0775312a09e4dabe7b4bc016` (ADR 0002).

Public names are re-exported from the parent `TemporalFocus` module. The loadable
package name remains `TemporalFocus` (UUID `b7e4c3f2-…`); this submodule does not
introduce a second resolvable package.

# Exports
- [`SpikeEvent`](@ref), [`SpikeTrain`](@ref), [`TemporalBuffer`](@ref) — spike data types
- [`prune!`](@ref) — in-place temporal buffer pruning
- [`temporal_weight`](@ref) — exponential recency weighting
- [`spike_attention_discrete`](@ref), [`spike_attention_temporal`](@ref),
  [`spike_attention_continuous`](@ref) — attention kernels
- [`normalize_l1!`](@ref), [`normalize_max!`](@ref) — in-place weight normalization

All spike values and temporal quantities use `Float32`.
"""
module Attention

using LinearAlgebra

export SpikeEvent, SpikeTrain, TemporalBuffer
export prune!
export temporal_weight
export spike_attention_discrete
export spike_attention_temporal
export spike_attention_continuous
export normalize_l1!, normalize_max!

include("types.jl")
include("discrete.jl")
include("temporal.jl")
include("continuous.jl")
include("normalization.jl")

end
