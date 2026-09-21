# SPDX-License-Identifier: MIT OR Apache-2.0
# Extracted verbatim from attention_spotlight.jl; original source provenance in PORTED_FROM.toml.
module SpotlightScenario
export SPOTLIGHT_CONFIG, ReplayEvent, build_stream, dominant_neuron, sample_times, identity_readout

const SPOTLIGHT_CONFIG = (
    slug = "attention_spotlight",
    n_neurons = 6,
    # Retention window of both buffers; also bounds |dt| inside the kernel.
    buffer_window = 0.35f0,
    # Recency time constant: exp(-|dt| / τ). Short relative to the burst spacing
    # so that the freshest coincidences dominate the score.
    tau = 0.10f0,
    sample_dt = 0.02f0,
    t_end = 4.80f0,
    # Four phases, each spotlighting one neuron => three handoffs.
    phase_length = 1.20f0,
    phase_neurons = (2, 5, 3, 6),
    bursts_per_phase = 7,
    burst_start = 0.10f0,
    burst_spacing = 0.15f0,
    # Lag between the context spike and the source spike of one pattern pair.
    pattern_lag = 0.03f0,
    pattern_value = 1.0f0,
    # Low-amplitude chatter that keeps every other neuron slightly active.
    background_period = 0.15f0,
    background_lag = 0.07f0,
    background_value = 0.35f0,
    # Deterministic golden-ratio jitter (no RNG, identical on every platform).
    jitter = 0.012f0,
    # A focus segment must persist this many samples before it counts as a handoff.
    min_hold_steps = 5,
)

# ---------------------------------------------------------------------------
# Scenario: a recorded, causally ordered event stream.
# ---------------------------------------------------------------------------

"""
    ReplayEvent(t, neuron_id, value, stream, role)

One recorded spike in the replay scenario. `stream` is `:source` or `:context`
(which buffer it is delivered to) and `role` is `:pattern` or `:background`
(bookkeeping for the raster only).
"""
struct ReplayEvent
    t::Float32
    neuron_id::Int
    value::Float32
    stream::Symbol
    role::Symbol
end

# Low-discrepancy, RNG-free jitter: reproducible across Julia versions/platforms.
_jitter(k::Integer, amplitude::Float32) =
    amplitude * (2.0f0 * Float32(mod(k * 0.6180339887498949, 1.0)) - 1.0f0)

"""
    dominant_neuron(cfg, t) -> Int

Neuron that the scenario spotlights at time `t`.
"""
function dominant_neuron(cfg, t::Real)
    phase = 1 + floor(Int, Float32(t) / cfg.phase_length)
    return cfg.phase_neurons[clamp(phase, 1, length(cfg.phase_neurons))]
end

"""
    build_stream(cfg) -> Vector{ReplayEvent}

Build the recorded scenario: per-phase bursts on the spotlighted neuron plus
weak background chatter on the others, sorted into causal arrival order.

Both halves of a context/source pair must fall inside the replay horizon
`[0, cfg.t_end]`, so the recorded stream is exactly the stream the replay
consumes — no event is written to `scenario.csv` that never reaches a buffer.
Jitter counters are advanced before the horizon check, so filtering never
shifts the timing of the events that are kept.
"""
function build_stream(cfg)
    events = ReplayEvent[]

    burst_index = 0
    for (phase, dominant) in enumerate(cfg.phase_neurons)
        phase_start = Float32(phase - 1) * cfg.phase_length
        for burst in 0:(cfg.bursts_per_phase - 1)
            burst_index += 1
            t = phase_start + cfg.burst_start + Float32(burst) * cfg.burst_spacing +
                _jitter(burst_index, cfg.jitter)
            (0.0f0 <= t && t + cfg.pattern_lag <= cfg.t_end) || continue
            push!(events, ReplayEvent(t, dominant, cfg.pattern_value, :context, :pattern))
            push!(events, ReplayEvent(t + cfg.pattern_lag, dominant, cfg.pattern_value,
                                      :source, :pattern))
        end
    end

    # Tick through the horizon inclusively, with room for a tick that negative
    # jitter pulls back inside it; the pair-level check below decides which of
    # the last ticks actually fit, so a background pair that ends inside `t_end`
    # is never dropped just because the period does not divide the horizon.
    n_ticks = floor(Int, (cfg.t_end + cfg.jitter) / cfg.background_period)
    for tick in 0:n_ticks
        t = Float32(tick) * cfg.background_period + _jitter(1_000 + tick, cfg.jitter)
        (0.0f0 <= t && t + cfg.background_lag <= cfg.t_end) || continue
        neuron = 1 + mod(tick, cfg.n_neurons)
        dominant_context = dominant_neuron(cfg, t)
        dominant_source = dominant_neuron(cfg, t + cfg.background_lag)
        for _ in 1:cfg.n_neurons
            neuron != dominant_context && neuron != dominant_source && break
            neuron = 1 + mod(neuron, cfg.n_neurons)
        end
        neuron != dominant_context && neuron != dominant_source || continue
        push!(events, ReplayEvent(t, neuron, cfg.background_value, :context, :background))
        push!(events, ReplayEvent(t + cfg.background_lag, neuron, cfg.background_value,
                                  :source, :background))
    end

    sort!(events; alg = MergeSort,
          by = e -> (e.t, e.stream === :source ? 1 : 0, e.neuron_id, e.value))
    return events
end

"""
    identity_readout(n) -> Matrix{Float32}

Identity readout, so `spike_attention_continuous` returns the raw per-neuron
attention vector (`transpose(I) * attention == attention`) instead of a
projected readout.
"""
function identity_readout(n::Integer)
    readout = zeros(Float32, n, n)
    for i in 1:n
        readout[i, i] = 1.0f0
    end
    return readout
end

"""
    sample_times(cfg) -> Vector{Float32}

Timestamps the replay is sampled at: every `sample_dt` grid point inside the
horizon, plus `t_end` itself.

No sample lies beyond `cfg.t_end`, the last sample is exactly `cfg.t_end` (so
every recorded event is consumed), and no interior grid point is skipped when
`t_end` is not an exact multiple of `sample_dt`.
"""
function sample_times(cfg)
    # The small slack absorbs Float32 division error for horizons that *are*
    # exact multiples of the step (4.8f0 / 0.02f0 is not exactly 240).
    n_grid = floor(Int, cfg.t_end / cfg.sample_dt + 1.0f-4)
    times = Float32[min(Float32(step) * cfg.sample_dt, cfg.t_end) for step in 0:n_grid]
    if last(times) != cfg.t_end
        push!(times, cfg.t_end)
    end
    return times
end


end
