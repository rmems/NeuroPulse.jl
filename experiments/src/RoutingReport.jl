# SPDX-License-Identifier: MIT OR Apache-2.0
# Plot/report layer only; numerical evaluation is independent of CairoMakie.
module RoutingReport
using CairoMakie, ExperimentUtils, Statistics, TemporalFocus
using ..RoutingSelection
const RS = RoutingSelection

function named_csv(slug,name,rows)
    source = write_metrics(slug,rows)
    name == "metrics.csv" && return source
    target = joinpath(result_dir(slug),name)
    mv(source,target; force=true)
    return target
end

function effective_config(cfg)
    result = deepcopy(cfg)
    result["methods"] = collect(RS.METHODS)
    state = RS.SelectionState(cfg)
    result["effective_routers"] = Dict(name => Dict(
        "config" => Dict(string(k) => getproperty(router.config,k) for k in fieldnames(RoutingConfig)),
        "inhibition_matrix_rows" => [collect(row) for row in eachrow(router.inhibition_matrix)],
        "n_out" => router.n_out) for (name,router) in state.routers)
    result["policies"] = Dict(
        "density" => "occupied source bins / observed recent bins; closed window on bin endpoints",
        "attention" => "same pruned history; discrete ignores pair dt; temporal continuous exp(-abs(dt)/tau)",
        "normalization" => "L1 for positive raw sum, otherwise uniform allocation and false evidence; router readout zero without evidence",
        "mask" => "global sample-interval loss for both streams; discard arrivals and hold all allocations/router state",
        "silence" => "observed zero evidence remains distinct from missing; observed router still updates",
        "top1" => "unique exact maximum only; ties incorrect including uniform",
        "handoff" => "confirmation at fifth consecutive observed correct sample; missing breaks streak; no cross-phase samples",
        "missed_handoff" => "blank raw delay and explicit missed=true; phase length cap used in comparison",
        "coverage" => "per method: no positive density for rate; no positive raw attention for attention; neither density nor temporal evidence for routers; uniform always has no data evidence; missing excluded and reported separately",
        "primary_metrics" => "all scheduled ticks including held missing allocations; observed accuracy also recorded",
        "pairing" => "same scene and mask across all methods; equal scene/seed weighting; no fitting or cell selection",
        "seed_rng" => "MersenneTwister; independent event jitter draws followed by interval-mask draws",
        "jitter" => "independent uniform [-amplitude,+amplitude] per event; out-of-horizon events dropped",
        "stale" => "previous target bursts continued after switches for declared duration",
        "strength" => "absolute background spike amplitude")
    return result
end

function summary_rows(result,cfg)
    rule = cfg["decision"]
    rows = NamedTuple[]
    for method in RS.METHODS
        ms = filter(m -> m.method == method,result.metrics)
        ps = filter(m -> m.method == method,result.pairs)
        verdict = isempty(ps) ? "baseline" : RS.paired_verdict(
            getproperty.(ps,:target_share_gain),getproperty.(ps,:strict_top1_gain),
            getproperty.(ps,:missed_handoffs_change),getproperty.(ps,:capped_delay_change),rule)
        push!(rows,(method=method,target_share=mean(m.target_share for m in ms),
            strict_top1=mean(m.strict_top1 for m in ms),
            missed_handoffs=sum(m.missed_handoffs for m in ms),
            handoffs=sum(m.handoffs for m in ms),mean_capped_delay=mean(m.mean_capped_delay for m in ms),
            weight_turnover=mean(m.weight_turnover for m in ms),
            observed_coverage=mean(m.observed_coverage for m in ms),
            no_evidence_coverage=mean(m.no_evidence_coverage for m in ms),
            target_share_gain=isempty(ps) ? 0. : mean(p.target_share_gain for p in ps),
            strict_top1_gain=isempty(ps) ? 0. : mean(p.strict_top1_gain for p in ps),verdict=verdict))
    end
    return rows
end

function summary_markdown(result,cfg,rows)
    main = only(filter(m -> m.method == cfg["decision"]["candidate"],rows))
    text = """
# Controlled routing selection

**Primary verdict: $(main.verdict).** Full temporal routing versus the fixed temporal-attention baseline across $(length(RS.study_cases(cfg))) paired scenes.

The declared descriptive rule requires mean target-share gain ≥ $(cfg["decision"]["minimum_target_share_gain"]), strict-top1 gain ≥ $(cfg["decision"]["minimum_strict_top1_gain"]), and no increase in missed handoffs or phase-capped delay. Nonpositive share/accuracy gain or an increase in misses/delay is unsupported; remaining positive gains are inconclusive. These are finite-grid comparisons, not population-level significance tests. The parameters and grid are declared in the input TOML before evaluation.

| Method | Target share | Strict top1 | Missed / handoffs | Capped delay (s) | Mean weight turnover | No-evidence coverage | Verdict vs temporal |
|---|---:|---:|---:|---:|---:|---:|---|
"""
    for r in rows
        text *= "| $(r.method) | $(round(r.target_share;digits=5)) | $(round(r.strict_top1;digits=5)) | $(r.missed_handoffs) / $(r.handoffs) | $(round(r.mean_capped_delay;digits=5)) | $(round(r.weight_turnover;digits=5)) | $(round(r.no_evidence_coverage;digits=5)) | $(r.verdict) |\n"
    end
    text *= """

Primary paired target-share gain: $(main.target_share_gain); strict-top1 gain: $(main.strict_top1_gain).

Every sample contributes to share and accuracy, including held allocations on missing intervals. A unique exact maximum is required; ties are incorrect. Handoffs require five consecutive observed correct samples, report confirmation delay, and record misses explicitly. The phase-length cap penalizes every miss instead of dropping it from the average. Weight turnover is mean total-variation distance between consecutive allocations. Initial acquisition is excluded from the three switch handoffs.

Mean observation coverage: $(main.observed_coverage). Full router observed no-input-evidence coverage over all scheduled samples: $(main.no_evidence_coverage). Missing intervals have unknown evidence (blank CSV cell), discard their arrivals, and hold method weights/router state. Observed silence still advances the router. Density counts occupied source bins divided by observed recent bins; No-evidence is computed separately for each method from the inputs it consumes: source density for rate, raw attention for attention methods, and either density or temporal attention for routers; the uniform comparator consumes no data and always has no data evidence. One neuron maps to one region, and the one-element router readout is the normalized temporal attention score, or zero when no evidence exists.

This controlled spike study does not establish deployed Spikenaut performance, training benefit, or hardware efficiency. The router uses density, *relative readout surprise*, and momentum; it does not pass the attention share straight through. Consequently, a strongly changing distractor can receive high router weight. Router ablations zero one coefficient or the equal off-diagonal inhibition matrix without renormalizing other coefficients. No hyperparameters were fitted to these results.

Artifacts: metrics.csv (scene × method), paired.csv (paired differences), handoffs.csv (every switch including failures), traces.csv (per-tick weights and evidence), events.csv (generated input plus provenance roles), masks.csv (availability and evaluation targets), aggregate.csv, config.toml (full effective configuration), figure.png, provenance.toml and resolved Project/Manifest snapshots. Runtime observations strip roles and targets; labels are used only in generation and evaluation. Hashes in provenance cover all auxiliary CSV files and the input configuration as well as source and environment files.
"""
    return text
end

function figure(rows,result,cfg)
    fig = Figure(size=(1300,1100))
    labels = replace.(collect(RS.METHODS),"_"=>"\n")
    for (index,(field,title)) in enumerate(((:target_share,"Mean target allocation"),
            (:strict_top1,"Strict top-1 accuracy (ties incorrect)"),
            (:missed_handoffs,"Missed handoffs (all scenes)"),
            (:mean_capped_delay,"Mean handoff confirmation delay, misses capped (s)")))
        row,col = divrem(index-1,2)
        ax = Axis(fig[row+1,col+1],title=title,xticks=(1:8,labels),xticklabelsize=10)
        barplot!(ax,1:8,Float64[getproperty(x,field) for x in rows],color=1:8,colormap=:viridis)
    end
    full = filter(x -> x.method == "temporal_router",result.pairs)
    xs,ys = cfg["grid"]["strength"],cfg["grid"]["stale"]
    gains = [mean(p.target_share_gain for p in full if p.strength == x && p.stale == y) for x in xs,y in ys]
    ax = Axis(fig[3,1],title="Router − temporal share, averaged over jitter / masks / seeds",
        xlabel="Distractor amplitude",ylabel="Stale duration (s)")
    limit = max(maximum(abs,gains),.001)
    hm = heatmap!(ax,Float64.(xs),Float64.(ys),gains,colormap=:balance,colorrange=(-limit,limit))
    Colorbar(fig[3,2],hm,label="Paired target-share gain",vertical=false)
    rowsize!(fig.layout,3,Relative(0.25))
    Label(fig[0,:],"Controlled attention + routing: fixed factorial study",fontsize=23)
    return fig
end
end
