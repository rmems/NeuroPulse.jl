# SPDX-License-Identifier: MIT OR Apache-2.0
# Generation may know labels. Observation is the entire runtime event interface.
struct Observation
    t::Float32
    neuron_id::Int
    value::Float32
    stream::Symbol
end

default_config() = TOML.parsefile(joinpath(@__DIR__, "..", "configs", "routing_selection.toml"))

function scenario_config(cfg)
    original = SpotlightScenario.SPOTLIGHT_CONFIG
    values = cfg["scenario"]
    return (; (k => (k == :slug ? "routing_selection" :
                    k == :phase_neurons ? Tuple(Int.(values[string(k)])) :
                    convert(typeof(v), values[string(k)])) for (k,v) in pairs(original))...)
end

function validate_config(cfg)
    s = scenario_config(cfg)
    s.n_neurons > 1 || throw(ArgumentError("at least two neurons required"))
    for x in (s.sample_dt, s.phase_length, s.t_end, s.buffer_window, s.tau,
              s.burst_spacing, s.background_period)
        isfinite(x) && x > 0 || throw(ArgumentError("time scales must be finite and positive"))
    end
    s.t_end == Float32(length(s.phase_neurons)) * s.phase_length ||
        throw(ArgumentError("horizon must equal the declared phases"))
    all(i -> 1 <= i <= s.n_neurons, s.phase_neurons) || throw(ArgumentError("invalid target"))
    s.min_hold_steps >= 1 || throw(ArgumentError("hold steps must be positive"))
    s.bursts_per_phase > 0 || throw(ArgumentError("bursts must be positive"))
    all(x -> isfinite(x) && x >= 0, (s.pattern_lag,s.background_lag,s.pattern_value,s.background_value,s.jitter)) ||
        throw(ArgumentError("amplitudes/lags/jitter must be finite and nonnegative"))
    for name in ("strength", "stale", "jitter", "missing")
        xs = cfg["grid"][name]
        !isempty(xs) && all(x -> isfinite(x) && x >= 0, xs) || throw(ArgumentError("invalid grid $name"))
    end
    all(x -> x <= 1, cfg["grid"]["missing"]) || throw(ArgumentError("missing probability outside [0,1]"))
    !isempty(cfg["grid"]["seeds"]) || throw(ArgumentError("no seeds"))
    cfg["decision"]["baseline"] == "temporal_attention" || throw(ArgumentError("fixed baseline is temporal_attention"))
    cfg["decision"]["candidate"] == "temporal_router" || throw(ArgumentError("fixed candidate is temporal_router"))
    for key in ("minimum_target_share_gain", "minimum_strict_top1_gain")
        x = cfg["decision"][key]
        isfinite(x) && x > 0 || throw(ArgumentError("decision thresholds must be positive"))
    end
    cfg["router"]["inhibition"] == 0.02 || throw(ArgumentError("inhibition must be 0.02"))
    return s
end

function study_cases(cfg)
    validate_config(cfg)
    g = cfg["grid"]
    return [(strength=a, stale=b, jitter=c, missing=d, seed=Int(seed))
            for a in g["strength"] for b in g["stale"] for c in g["jitter"]
            for d in g["missing"] for seed in g["seeds"]]
end

"""Generate spikes and separate evaluation labels; all methods get identical inputs.

Strength sets background amplitude. Stale duration continues the previous target's
pattern bursts after each switch. Independent bounded timestamp jitter is applied
to every event, then the stream is stably sorted. A seeded global observation mask
removes complete sample intervals from both channels, never treating loss as silence.
"""
function generate_scene(cfg, condition)
    s = scenario_config(cfg)
    rng = MersenneTwister(condition.seed)
    generation = merge(s, (background_value=Float32(condition.strength),))
    events = build_stream(generation)
    for phase in 2:length(s.phase_neurons)
        start = Float32(phase-1) * s.phase_length
        for k in 0:ceil(Int, condition.stale / s.burst_spacing)
            offset = Float32(k) * s.burst_spacing
            offset < condition.stale || continue
            t = start + offset
            push!(events, ReplayEvent(t, s.phase_neurons[phase-1], s.pattern_value, :context, :stale))
            push!(events, ReplayEvent(t+s.pattern_lag, s.phase_neurons[phase-1], s.pattern_value, :source, :stale))
        end
    end
    jittered = ReplayEvent[]
    for e in events
        t = e.t + Float32((2rand(rng)-1) * condition.jitter)
        0 <= t <= s.t_end || continue
        push!(jittered, ReplayEvent(t,e.neuron_id,e.value,e.stream,e.role))
    end
    sort!(jittered; alg=MergeSort, by=e -> (e.t,e.stream === :source ? 1 : 0,e.neuron_id,e.value))
    times = sample_times(s)
    observed = rand(rng, length(times)) .>= condition.missing
    observations = [Observation(e.t,e.neuron_id,e.value,e.stream) for e in jittered]
    return (condition=condition, events=jittered, observations=observations,
            times=times, observed=observed, targets=[dominant_neuron(s,t) for t in times])
end
