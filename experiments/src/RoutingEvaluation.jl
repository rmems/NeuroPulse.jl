# SPDX-License-Identifier: MIT OR Apache-2.0
# Ground truth is used only here, after the runtime has produced allocations.
function strict_winner(weights)
    best = maximum(weights)
    best > 0 && count(==(best),weights) == 1 ? argmax(weights) : 0
end

"""Delay until the fifth observed consecutive correct sample; missing means missed.

A tie, wrong winner, or missing observation breaks the streak. Phase endpoints
are exclusive, so a hold cannot borrow samples from the next phase. Delay is the
confirmation time, not the retrospectively inferred beginning of the streak.
"""
function sustained_delay(times,winners,observed,target,start,stop,hold)
    streak = 0
    for (t,w,seen) in zip(times,winners,observed)
        start <= t < stop || continue
        streak = seen && w == target ? streak+1 : 0
        streak >= hold && return Float64(t-start)
    end
    return missing
end

# Evidence is about the actual observed inputs, never the existence of output weights.
function method_evidence(method, step)
    step.observed || return missing
    method == "uniform" && return false # data-independent comparator
    method == "firing_rate" && return step.rate_evidence
    method == "discrete_attention" && return step.discrete_evidence
    method == "temporal_attention" && return step.temporal_evidence
    return step.rate_evidence || step.temporal_evidence # router consumes both
end

function evaluate_scene(cfg,scene)
    s = scenario_config(cfg)
    state = SelectionState(cfg)
    steps = [advance!(state,scene.observations,t,seen) for (t,seen) in zip(scene.times,scene.observed)]
    metrics, handoffs, traces = NamedTuple[],NamedTuple[],NamedTuple[]
    n, nseen = length(steps),count(scene.observed)
    for method in METHODS
        no_evidence = count(x -> x.observed && !method_evidence(method,x),steps)
        weights = [x.weights[method] for x in steps]
        winners = strict_winner.(weights)
        correct = winners .== scene.targets
        delays = Union{Missing,Float64}[]
        for phase in 2:length(s.phase_neurons)
            start = Float32(phase-1)*s.phase_length
            delay = sustained_delay(scene.times,winners,scene.observed,s.phase_neurons[phase],
                                     start,start+s.phase_length,s.min_hold_steps)
            push!(delays,delay)
            push!(handoffs,merge(scene.condition,(method=method,phase=phase,target=s.phase_neurons[phase],
                start=start,delay=delay,missed=ismissing(delay),
                capped_delay=ismissing(delay) ? Float64(s.phase_length) : delay)))
        end
        observed_correct = nseen == 0 ? missing : sum(correct .& scene.observed)/nseen
        row = merge(scene.condition,(method=method,
            target_share=mean(w[y] for (w,y) in zip(weights,scene.targets)),
            strict_top1=mean(correct),observed_strict_top1=observed_correct,
            tie_fraction=count(==(0),winners)/n,
            handoffs=length(delays),missed_handoffs=count(ismissing,delays),
            mean_capped_delay=mean(ismissing(d) ? Float64(s.phase_length) : d for d in delays),
            weight_turnover=mean(sum(abs.(weights[i].-weights[i-1]))/2 for i in 2:n),
            winner_turnover=count(i -> winners[i] != winners[i-1],2:n),
            observed_coverage=nseen/n,missing_coverage=1-nseen/n,
            no_evidence_coverage=no_evidence/n,
            no_evidence_given_observed=nseen == 0 ? missing : no_evidence/nseen))
        push!(metrics,row)
        for (k,step) in enumerate(steps)
            push!(traces,merge(scene.condition,(method=method,t=step.t,observed=step.observed,
                target=scene.targets[k],winner=winners[k],target_share=weights[k][scene.targets[k]],
                correct=correct[k],method_evidence=method_evidence(method,step),temporal_evidence=step.temporal_evidence,
                rate_evidence=step.rate_evidence,discrete_evidence=step.discrete_evidence,
                weights=join(weights[k],';'),density=join(step.density,';'))))
        end
    end
    return (metrics=metrics,handoffs=handoffs,traces=traces)
end

"""Finite-grid descriptive verdict from paired candidate-minus-baseline metrics."""
function paired_verdict(share,accuracy,misses,delay,rule)
    a,b,c,d = mean(share),mean(accuracy),mean(misses),mean(delay)
    if a >= rule["minimum_target_share_gain"] && b >= rule["minimum_strict_top1_gain"] && c <= 0 && d <= 0
        return "supported"
    elseif a <= 0 || b <= 0 || c > 0 || d > 0
        return "unsupported"
    end
    return "inconclusive"
end

function paired_rows(metrics,cfg)
    baseline = cfg["decision"]["baseline"]
    rows = NamedTuple[]
    for base in filter(m -> m.method == baseline,metrics)
        key = (base.strength,base.stale,base.jitter,base.missing,base.seed)
        for candidate in filter(m -> m.method != baseline &&
                (m.strength,m.stale,m.jitter,m.missing,m.seed) == key,metrics)
            push!(rows,(strength=base.strength,stale=base.stale,jitter=base.jitter,
                missing=base.missing,seed=base.seed,method=candidate.method,baseline=baseline,
                target_share_gain=candidate.target_share-base.target_share,
                strict_top1_gain=candidate.strict_top1-base.strict_top1,
                missed_handoffs_change=candidate.missed_handoffs-base.missed_handoffs,
                capped_delay_change=candidate.mean_capped_delay-base.mean_capped_delay))
        end
    end
    return rows
end

function run_study(cfg)
    metrics,handoffs,traces,inputs,masks = (NamedTuple[] for _ in 1:5)
    for (case_id,condition) in enumerate(study_cases(cfg))
        scene = generate_scene(cfg,condition)
        result = evaluate_scene(cfg,scene)
        append!(metrics,result.metrics); append!(handoffs,result.handoffs); append!(traces,result.traces)
        append!(inputs,[merge(condition,(case_id=case_id,t=e.t,neuron=e.neuron_id,value=e.value,
            stream=e.stream,role=e.role)) for e in scene.events])
        append!(masks,[merge(condition,(case_id=case_id,t=t,observed=seen,target=target))
            for (t,seen,target) in zip(scene.times,scene.observed,scene.targets)])
    end
    pairs = paired_rows(metrics,cfg)
    return (metrics=metrics,handoffs=handoffs,traces=traces,inputs=inputs,masks=masks,pairs=pairs)
end
