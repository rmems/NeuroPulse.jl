# SPDX-License-Identifier: MIT OR Apache-2.0
"""Offline adapter only: current-tick spikes against strictly earlier session context."""
module SpikenautReplay
using JSON, SHA, TOML, Statistics, NeuroPulse
export ReplayRow, read_replay, replay_window, run_replay, parse_options, validate_config
const METHODS = ("uniform", "firing_rate", "discrete_attention", "temporal_attention", "temporal_router")
const FIXTURE = normpath(joinpath(@__DIR__,"..","fixtures","spikenaut"))
const SYNTHETIC_TRACE_SHA256 = "9f7b7144165350514a3351e607178e33b44542437cf4171a8b2bbc678a028bb4"
const DEFAULT_CONFIG = normpath(joinpath(@__DIR__,"..","configs","spikenaut_replay.toml"))
struct ReplayRow
    step::Int
    session::String
    source_line::Int
    spikes::Vector{Int} # explicitly converted from producer's zero-based IDs
    missing::Vector{String}
end
require(ok, message) = ok || throw(ArgumentError(message))
integer(x) = x isa Integer && !(x isa Bool)
finite_number(x) = x isa Real && !(x isa Bool) && isfinite(x) && isfinite(Float32(x))
function finite_tree(x)
    x isa AbstractDict && return all(finite_tree,values(x))
    x isa AbstractVector && return all(finite_tree,x)
    x isa Real && return isfinite(x)
    return true
end
function numeric_vector(x,n,label)
    require(x isa AbstractVector && length(x)==n && all(finite_number,x),"invalid $label shape or finite values")
end
function string_list(x,label)
    require(x isa AbstractVector && all(y -> y isa String && !isempty(y),x) && allunique(x),"invalid $label")
end

"""Validate the producer contract before replay. A digest binds bytes, not data authenticity.

No wall-clock time exists in v1. Global steps must start at zero and be consecutive;
source lines may skip filtered input lines but must strictly increase. Source/model
metadata remain unchanged in the supplied manifest; the LIF model is not rerun.
"""
function read_replay(trace_path, manifest_path)
    try
        manifest = JSON.parsefile(manifest_path)
        require(manifest["schema_version"]=="spikenaut.replay-manifest.v1","unsupported manifest schema")
        require(manifest["trace_schema"]=="spikenaut.replay-trace.v1","unsupported trace schema")
        bytes = read(trace_path)
        require(manifest["trace_sha256"]=="sha256:"*bytes2hex(sha256(bytes)),"trace digest mismatch")
        require(finite_tree(manifest),"non-finite manifest values")
        n = manifest["stepper"]["n_neurons"]
        require(integer(n) && n>0,"invalid neuron count")
        columns = manifest["encoder"]["columns"]
        string_list(columns,"encoder columns")
        require(!isempty(columns),"empty encoder columns")
        vocabulary = manifest["output"]["vocabulary"]
        string_list(vocabulary,"output vocabulary")
        require(!isempty(vocabulary),"empty output vocabulary")
        sessions = manifest["input"]["sessions"]
        string_list(sessions,"sessions")
        counts = Dict(s=>0 for s in sessions)
        missing_counts = Dict(c=>0 for c in columns)
        actual_sessions = String[]
        rows = ReplayRow[]
        previous_line = 0
        for (i,line) in enumerate(split(chomp(String(bytes)),'\n'))
            obj = JSON.parse(line)
            require(finite_tree(obj),"non-finite trace values at row $i")
            step,session,source_line = obj["step"],obj["session"],obj["source_line"]
            require(integer(step) && step==i-1,"steps must start at zero and be consecutive")
            require(session isa String && haskey(counts,session),"undeclared session")
            require(integer(source_line) && source_line>previous_line,"source lines must strictly increase")
            previous_line = source_line
            if isempty(rows) || session != rows[end].session
                require(!(session in actual_sessions),"session reappears after a boundary")
                push!(actual_sessions,session)
            end
            spikes,absent = obj["spikes"],obj["missing"]
            require(spikes isa AbstractVector && all(x -> integer(x) && 0<=x<n,spikes) && allunique(spikes),"invalid or duplicate zero-based neuron IDs")
            string_list(absent,"missing sensors")
            require(all(c -> c in columns,absent),"unknown missing sensor")
            numeric_vector(obj["stim"],n,"stimulus")
            numeric_vector(obj["scores"],length(vocabulary),"scores")
            numeric_vector(obj["decision"]["scores"],length(vocabulary),"decision scores")
            require(obj["decision"]["scores"]==obj["scores"],"decision score mismatch")
            # This adapter deliberately has no timestamp interpretation; refuse an extension
            # carrying non-null time rather than silently reinterpreting it as ticks.
            for key in ("timestamp","ts_utc","time")
                require(get(obj,key,nothing)===nothing,"timestamp-bearing trace requires a timestamp adapter")
            end
            counts[session] += 1
            for c in absent
                missing_counts[c] += 1
            end
            push!(rows,ReplayRow(step,session,source_line,Int.(spikes).+1,String.(absent)))
        end
        require(!isempty(rows),"empty replay")
        require(actual_sessions==sessions,"manifest session order mismatch")
        require(integer(manifest["input"]["n_steps"]) && length(rows)==manifest["input"]["n_steps"],"step count mismatch")
        require(all(integer,values(manifest["input"]["steps_per_session"])),"invalid session count types")
        require(all(integer,values(manifest["encoder"]["missing_counts"])),"invalid missing count types")
        require(counts==manifest["input"]["steps_per_session"],"per-session count mismatch")
        require(missing_counts==manifest["encoder"]["missing_counts"],"missing count mismatch")
        require(integer(manifest["results"]["sessions"]) && length(sessions)==manifest["results"]["sessions"],"session count mismatch")
        require(integer(manifest["results"]["spikes_fired"]) && sum(length(r.spikes) for r in rows)==manifest["results"]["spikes_fired"],"spike count mismatch")
        return (rows=rows,n=Int(n),manifest=manifest)
    catch e
        e isa InterruptException && rethrow()
        e isa ArgumentError && rethrow()
        throw(ArgumentError("invalid replay pair: $(sprint(showerror,e))"))
    end
end

function validate_config(cfg)
    require(Set(keys(cfg))==Set(["windows_ticks","tau_ticks","router"]),"unknown or missing config keys")
    windows = cfg["windows_ticks"]
    require(windows isa AbstractVector && !isempty(windows) && allunique(windows) &&
        all(w -> integer(w) && 1<=w<=2^24,windows),"windows must be distinct positive integer ticks")
    require(finite_number(cfg["tau_ticks"]) && cfg["tau_ticks"]>0,"tau must be positive finite ticks")
    r = cfg["router"]
    require(Set(keys(r))==Set(["alpha","beta","gamma","ema_decay","min_score","epsilon","inhibition"]),"unknown or missing router configuration")
    require(finite_number(r["inhibition"]) && r["inhibition"]>=0,"invalid inhibition")
    RoutingConfig((r[k] for k in ("alpha","beta","gamma","ema_decay","min_score","epsilon"))...)
    return cfg
end
function new_router(n,cfg)
    r = cfg["router"]
    matrix = fill(Float32(r["inhibition"]),n,n)
    for i in 1:n
        matrix[i,i] = 0f0
    end
    config = RoutingConfig((r[k] for k in ("alpha","beta","gamma","ema_decay","min_score","epsilon"))...)
    RegionRouter(n_regions=n,n_out=1,inhibition_matrix=matrix,config=config,
        region_names=["neuron_$(i-1)" for i in 1:n])
end
shares(raw) = sum(raw)>0 ? (Float32.(raw./sum(raw)),true) : (fill(1f0/length(raw),length(raw)),false)

"""Retain every tick; exclude [t-window,t] if any sensor was missing.

Density counts occupied observed bins in that closed window. Source is current
spikes only; context is strictly earlier spikes. A missing row clears history,
router and turnover references. During excluded warm-up, observed history is
collected but the router remains reset. On local eligibility it starts fresh.
This bounds local contamination; it cannot undo upstream encode-zero LIF state.
Kernel times are relative to current tick (source=0, context<0), avoiding large
absolute-step Float32 rounding. Session boundaries reset everything.
"""
function replay_window(rows,n,window,cfg)
    validate_config(cfg)
    require(integer(window) && 1<=window<=2^24,"invalid replay window")
    router = new_router(n,cfg)
    history = ReplayRow[]
    previous = Dict{String,Vector{Float32}}()
    last_missing = nothing
    session = nothing
    output = NamedTuple[]
    readout = zeros(Float32,n,n)
    for i in 1:n
        readout[i,i] = 1f0
    end
    for row in rows
        if row.session != session
            empty!(history); empty!(previous)
            router = new_router(n,cfg)
            last_missing = nothing
            session = row.session
        end
        observed = isempty(row.missing)
        if !observed
            empty!(history); empty!(previous)
            router = new_router(n,cfg)
            last_missing = row.step
        end
        filter!(r -> row.step-r.step<=window,history)
        eligible = observed && (last_missing===nothing || row.step-last_missing>window)
        weights = Dict(m=>fill(1f0/n,n) for m in METHODS)
        evidence = Dict{String,Union{Bool,Missing}}(m=>missing for m in METHODS)
        if eligible
            source = SpikeEvent[SpikeEvent(i,0f0) for i in row.spikes]
            context = SpikeEvent[SpikeEvent(i,r.step-row.step) for r in history for i in r.spikes]
            density = zeros(Float32,n)
            for r in history, i in r.spikes
                density[i] += 1f0
            end
            for i in row.spikes
                density[i] += 1f0
            end
            density ./= length(history)+1
            weights["firing_rate"],evidence["firing_rate"] = shares(density)
            weights["discrete_attention"],evidence["discrete_attention"] = shares(
                spike_attention_discrete(SpikeTrain(source),SpikeTrain(context),readout))
            weights["temporal_attention"],evidence["temporal_attention"] = shares(
                spike_attention_continuous(TemporalBuffer(window,source),TemporalBuffer(window,context),readout;τ=cfg["tau_ticks"]))
            attention_readout = evidence["temporal_attention"] ? weights["temporal_attention"] : zeros(Float32,n)
            update_routing!(router,[ActivityRegion(density[i],Float32[attention_readout[i]]) for i in 1:n])
            weights["temporal_router"] = copy(router.routing_weights)
            evidence["temporal_router"] = evidence["firing_rate"] || evidence["temporal_attention"]
            evidence["uniform"] = false
        end
        for method in METHODS
            w = weights[method]
            turnover = eligible && haskey(previous,method) ? sum(abs.(Float64.(w).-previous[method]))/2 : missing
            winner = eligible ? (count(==(maximum(w)),w)==1 ? argmax(w) : 0) : missing
            push!(output,(window_ticks=window,session=row.session,step=row.step,source_line=row.source_line,
                method=method,observed=observed,eligible=eligible,missing_sensors=join(row.missing,";"),
                observed_silent=observed ? isempty(row.spikes) : missing,
                evidence=evidence[method],winner=winner,
                concentration=eligible ? sum(abs2,Float64.(w)) : missing,
                entropy_bits=eligible ? -sum(p>0 ? Float64(p)*log2(Float64(p)) : 0. for p in w) : missing,
                turnover=turnover,weights=eligible ? w : missing))
            eligible ? (previous[method]=copy(w)) : pop!(previous,method,nothing)
        end
        observed && push!(history,row)
    end
    output
end
mean_or_missing(values) = isempty(values) ? missing : mean(values)
function run_replay(data,cfg)
    traces = NamedTuple[]
    metrics = NamedTuple[]
    for window in cfg["windows_ticks"]
        append!(traces,replay_window(data.rows,data.n,window,cfg))
        for method in METHODS
            rows = filter(r -> r.window_ticks==window && r.method==method,traces)
            eligible = filter(r -> r.eligible,rows)
            turns = collect(skipmissing(getproperty.(eligible,:turnover)))
            push!(metrics,(window_ticks=window,method=method,ticks=length(rows),
                observed_ticks=count(r -> r.observed,rows),missing_ticks=count(r -> !r.observed,rows),
                observed_silent_ticks=count(r -> r.observed_silent===true,rows),
                eligible_ticks=length(eligible),excluded_observed_ticks=count(r -> r.observed && !r.eligible,rows),
                eligible_coverage=length(eligible)/length(rows),
                no_evidence_ticks=count(r -> r.evidence===false,eligible),
                unique_winner_ticks=count(r -> r.winner>0,eligible),
                mean_concentration=mean_or_missing(getproperty.(eligible,:concentration)),
                mean_entropy_bits=mean_or_missing(getproperty.(eligible,:entropy_bits)),
                turnover_pairs=length(turns),mean_turnover=mean_or_missing(turns)))
        end
    end
    (traces=traces,metrics=metrics)
end
function parse_options(args)
    opts = Dict{String,String}()
    allowed = ("--trace","--manifest","--config","--data-kind")
    require(iseven(length(args)),"options require values")
    for i in 1:2:length(args)
        key,value = args[i],args[i+1]
        require(key in allowed && !haskey(opts,key) && !isempty(value),"unknown, duplicate or empty option $key")
        opts[key] = value
    end
    paired = haskey(opts,"--trace")
    require(paired==haskey(opts,"--manifest"),"--trace and --manifest must be supplied together")
    trace = get(opts,"--trace",joinpath(FIXTURE,"trace.jsonl"))
    # Identify known synthetic content even when passed explicitly or renamed.
    known_fixture = !paired || (isfile(trace) && bytes2hex(sha256(read(trace)))==SYNTHETIC_TRACE_SHA256)
    kind = get(opts,"--data-kind",known_fixture ? "synthetic" : "unverified/unspecified")
    require(!known_fixture || kind=="synthetic","known synthetic fixture must be labeled synthetic")
    require(kind in ("synthetic","unverified/unspecified","measured-user-declared"),"unsupported data-kind label")
    (trace=trace,
     manifest=get(opts,"--manifest",joinpath(FIXTURE,"manifest.json")),
     config=get(opts,"--config",DEFAULT_CONFIG),data_kind=kind,builtin_fixture=known_fixture)
end
end
