# SPDX-License-Identifier: MIT OR Apache-2.0
# This file consumes only spike observations, clock ticks, and availability masks.
# Phase/target/role labels are not stored in the runtime state or passed to advance!.
mutable struct SelectionState
    n::Int
    window::Float32
    tau::Float32
    source::TemporalBuffer
    context::TemporalBuffer
    readout::Matrix{Float32}
    next_event::Int
    last_time::Float32
    bins::Vector{Tuple{Float32,Bool,BitVector}}
    routers::Dict{String,RegionRouter}
    weights::Dict{String,Vector{Float32}}
end

function SelectionState(cfg)
    s, r = cfg["scenario"], cfg["router"]
    n = Int(s["n_neurons"])
    routers = Dict{String,RegionRouter}()
    for method in METHODS[5:end]
        inhibition = fill(Float32(method == "no_inhibition" ? 0 : r["inhibition"]), n,n)
        for i in 1:n
            inhibition[i,i] = 0f0
        end
        config = RoutingConfig(r["alpha"], method == "no_surprise" ? 0 : r["beta"],
            method == "no_momentum" ? 0 : r["gamma"], r["ema_decay"], r["min_score"], r["epsilon"])
        routers[method] = RegionRouter(n_regions=n,n_out=1,
            region_names=["Region$i" for i in 1:n], inhibition_matrix=inhibition, config=config)
    end
    window = Float32(s["buffer_window"])
    return SelectionState(n,window,Float32(s["tau"]),TemporalBuffer(window),TemporalBuffer(window),
        identity_readout(n),1,-Inf32,Tuple{Float32,Bool,BitVector}[],routers,
        Dict(m => fill(1f0/n,n) for m in METHODS))
end

"""L1 shares, with a uniform allocation but an explicit false evidence flag at zero."""
function shares(raw)
    total = sum(raw)
    total > 0 ? (Float32.(raw ./ total), true) : (fill(1f0/length(raw),length(raw)), false)
end

"""Advance causally. Missing intervals discard arrivals and hold all method state.

On an observed tick, density is occupied *source* sample bins / observed recent
sample bins, retaining bins whose endpoint is at most `window` old. Duplicate
spikes in a bin count once. Both attention methods use the same pruned history;
discrete attention ignores pair timing. Each router region gets this density and
one temporal L1 attention share (zero readout when there is no temporal evidence).
"""
function advance!(state::SelectionState, observations::Vector{Observation}, time::Real, observed::Bool)
    t = Float32(time)
    isfinite(t) && t > state.last_time || throw(ArgumentError("ticks must strictly increase"))
    occupied = falses(state.n)
    while state.next_event <= length(observations) && observations[state.next_event].t <= t
        e = observations[state.next_event]
        e.t > state.last_time || throw(ArgumentError("observations must be ordered and not replayed"))
        if observed
            e.stream in (:source,:context) || throw(ArgumentError("unknown observation stream"))
            1 <= e.neuron_id <= state.n || throw(ArgumentError("unknown region"))
            isfinite(e.value) && e.value >= 0 || throw(ArgumentError("nonnegative finite spike values required"))
            buffer = e.stream === :source ? state.source : state.context
            push!(buffer.events,SpikeEvent(e.neuron_id,e.t,e.value))
            e.stream === :source && e.value > 0 && (occupied[e.neuron_id] = true)
        end
        state.next_event += 1
    end
    push!(state.bins,(t,observed,occupied))
    filter!(b -> t-b[1] <= state.window, state.bins)
    prune!(state.source,t)
    prune!(state.context,t)
    state.last_time = t
    density = zeros(Float32,state.n)
    n_observed = count(b -> b[2],state.bins)
    if n_observed > 0
        for b in state.bins
            b[2] && (density .+= b[3])
        end
        density ./= n_observed
    end
    temporal_evidence = rate_evidence = discrete_evidence = missing
    if observed
        rate, rate_evidence = shares(density)
        discrete, discrete_evidence = shares(spike_attention_discrete(
            SpikeTrain(state.source.events),SpikeTrain(state.context.events),state.readout))
        temporal, temporal_evidence = shares(spike_attention_continuous(
            state.source,state.context,state.readout; τ=state.tau))
        state.weights["firing_rate"] = rate
        state.weights["discrete_attention"] = discrete
        state.weights["temporal_attention"] = temporal
        readouts = temporal_evidence ? temporal : zeros(Float32,state.n)
        regions = [ActivityRegion(density[i],Float32[readouts[i]]) for i in 1:state.n]
        for (name,router) in state.routers
            update_routing!(router,regions)
            state.weights[name] = copy(router.routing_weights)
        end
    end
    return (t=t,observed=observed,density=density,temporal_evidence=temporal_evidence,
            rate_evidence=rate_evidence,discrete_evidence=discrete_evidence,weights=deepcopy(state.weights))
end

"""Snapshot both router and experiment-side replay state for exact continuation."""
function selection_snapshot(state)
    return (n=state.n,window=state.window,tau=state.tau,source=copy(state.source.events),
        context=copy(state.context.events),next_event=state.next_event,last_time=state.last_time,
        bins=deepcopy(state.bins),weights=deepcopy(state.weights),
        routers=Dict(k => save_state(v) for (k,v) in state.routers))
end

function restore_selection!(state,snap)
    (state.n,state.window,state.tau) == (snap.n,snap.window,snap.tau) ||
        throw(ArgumentError("snapshot runtime configuration mismatch"))
    for (k,v) in state.routers
        load_state!(v,snap.routers[k])
    end
    empty!(state.source.events); append!(state.source.events,snap.source)
    empty!(state.context.events); append!(state.context.events,snap.context)
    state.next_event, state.last_time = snap.next_event,snap.last_time
    state.bins, state.weights = deepcopy(snap.bins),deepcopy(snap.weights)
    return state
end
