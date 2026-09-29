# SPDX-License-Identifier: MIT OR Apache-2.0
module SpikenautReport
using CairoMakie, ExperimentUtils, TemporalFocus
using ..SpikenautReplay
const SR = SpikenautReplay
function named_csv(slug,name,rows)
    path = write_metrics(slug,rows)
    target = joinpath(result_dir(slug),name)
    mv(path,target;force=true)
    target
end
function effective_config(cfg,options,data)
    effective = deepcopy(cfg)
    effective["data_kind"] = options.data_kind
    effective["provenance_label_authority"] = options.builtin_fixture ? "committed synthetic method fixture" : "caller declaration only; not independently verified"
    effective["methods"] = collect(SR.METHODS)
    effective["n_neurons"] = data.n
    effective["policies"] = Dict(
        "time"=>"replay ticks in original file order; no elapsed-time or staleness inference",
        "source_context"=>"current tick source against strictly earlier events in same session, 1 <= lag <= window_ticks; no self match",
        "region_mapping"=>"one neuron per region; upstream ID 0 maps to Julia region 1; analysis choice, not model semantics",
        "density"=>"occupied bins / available bins in closed [t-window,t], shortened at session start",
        "attention_readout"=>"identity matrix; positive attention L1 shares, zero evidence uses uniform allocation and zero router readout",
        "router"=>"per-region density plus one temporal-attention share; fixed equal off-diagonal inhibition, zero diagonal",
        "missing"=>"any missing sensor excludes entire local [t-window,t] comparison; preserve timeline, discard missing arrivals, reset router/history at dropout; no router updates until eligibility resumes",
        "upstream_limitation"=>"local eligibility does not prove upstream LIF recovery after encode-zero input",
        "turnover"=>"total variation between consecutive eligible ticks in same session only; no bridge across exclusions",
        "metrics"=>"eligible-tick means, pooled across sessions; HHI=sum(p^2), entropy in bits; explicit counts retain excluded, missing and observed-silent ticks",
        "ties"=>"exact equal maxima have winner=0; no arbitrary tie break; winner IDs are one-based Julia regions",
        "evidence"=>"method-specific positive input: density for firing rate, pair scores for attention, either for router; uniform always false; excluded rows unknown",
        "claims"=>"descriptive offline replay only; no accuracy, forecast, training, energy, runtime or supervisor benefit inferred")
    router = SR.new_router(data.n,cfg)
    effective["effective_router"] = Dict("config"=>Dict(string(k)=>getproperty(router.config,k) for k in fieldnames(RoutingConfig)),
        "inhibition_matrix_rows"=>[collect(row) for row in eachrow(router.inhibition_matrix)],"n_out"=>1)
    effective
end
showmetric(x) = ismissing(x) ? "unavailable" : string(round(x;digits=5))
function summary(result,options,data)
    text = """
# Offline Spikenaut replay: descriptive allocation report

**Data kind: $(options.data_kind).** $(length(data.rows)) original ticks, $(length(data.manifest["input"]["sessions"])) sessions, $(data.manifest["results"]["spikes_fired"]) upstream spikes. The default committed fixture is synthetic method data, not measured hardware or a holdout. Explicit external inputs default to `unverified/unspecified`; a measured label is only a caller declaration.

Question: how do allocation concentration, entropy and turnover change over the declared window grid when the same current spikes query strictly earlier context? There are no target labels, accuracy tests, forecasts, or supervisor conclusions in this study. A concentrated allocation does not establish a correct or useful allocation. No parameters are fitted to these results.

| Window (ticks) | Method | Eligible / all | No evidence / eligible | HHI concentration | Entropy (bits) | Turnover | Consecutive pairs |
|---:|---|---:|---:|---:|---:|---:|---:|
"""
    for r in result.metrics
        text *= "| $(r.window_ticks) | $(r.method) | $(r.eligible_ticks) / $(r.ticks) | $(r.no_evidence_ticks) / $(r.eligible_ticks) | $(showmetric(r.mean_concentration)) | $(showmetric(r.mean_entropy_bits)) | $(showmetric(r.mean_turnover)) | $(r.turnover_pairs) |\n"
    end
    text *= """

One neuron is one analysis region; producer IDs 0:$(data.n-1) map explicitly to Julia IDs 1:$(data.n). This is an analysis choice, not a claimed anatomical or functional grouping. Source is the current tick only, and context is previous ticks from the same session with lag in 1:window. Events are compared by matching neuron ID, so a first tick has no past-context attention evidence. Discrete attention ignores lag within this same pruned context; temporal attention applies exp(-lag/tau). Tick spacing is not known elapsed time: these inputs have no usable timestamps and staleness is undetectable.

Firing-rate density counts occupied bins in [t-window,t], including current tick, divided by the available bins in that window (shortened at session start). Each router region receives that density and one temporal L1 attention share; absent attention gives zero readout. All positive raw comparator scores are L1-normalized. With zero scores, allocation is uniform and evidence=false. Observed silence still advances an eligible router, whose history can affect its weights. Uniform is data-independent and always has evidence=false. Exact ties have no unique winner.

Any missing sensor marks its entire row unobserved and excludes every comparison whose closed [t-window,t] includes it. Missing arrivals are discarded, local event history and router state are reset, and observed subsequent ticks accumulate context while routing stays reset until the local window is clear. Original global steps are retained; windows are never shortened by compressing time. Every session independently resets history, router and turnover. **This excludes local contamination; it does not undo upstream LIF state that already evolved through encode-zero sensor dropout and does not prove upstream recovery.**

Coverage retains observed silence separately from missing/unobserved rows. In traces.csv and coverage.csv, unknown silence/evidence and excluded statistics are blank, not zero. Metrics average only eligible ticks, including observed zero-evidence uniform fallbacks; different windows may have different eligible sets. Turnover is total variation between consecutive eligible same-session allocations, never across an excluded interval or boundary. HHI is sum(p²), entropy is -sum(p log2 p). No significance or performance-benefit claim follows from these pooled descriptive means.

The producer manifest is preserved verbatim in input-manifest.json, including source commit/dirty fields, checkpoint and input lineage. Trace SHA-256 and schema declarations are verified along with neuron IDs, vector shapes, finite inputs, ordered sessions and aggregate counts. A digest checks consistency, not authenticity; producer checkpoint and original external telemetry are not independently re-attested here. $(options.builtin_fixture ? "The committed telemetry fixture is included and its declared input digest is checked." : "The external telemetry and checkpoint behind the supplied manifest were not provided to this adapter and have not been independently verified.") Upstream scores and decision diagnostics are not used to select routing weights or interpreted as a validated action policy.

Artifacts: config.toml records effective configuration and analysis policies; metrics.csv is window × method; traces.csv records all method/tick allocations; coverage.csv records each window/tick's masks, observation state and eligibility; input-trace.jsonl and input-manifest.json preserve exact supplied bytes. Provenance covers both inputs, configuration, auxiliary tables, source files and resolved Project/Manifest snapshots. The plot is descriptive and the supplied data kind is shown in its title.
"""
    text
end
function figure(result,options)
    fig = Figure(size=(1200,850))
    for (index,(field,title)) in enumerate(((:mean_concentration,"HHI concentration (eligible ticks)"),
        (:mean_entropy_bits,"Entropy, bits (eligible ticks)"),(:mean_turnover,"Turnover (consecutive eligible pairs)"),
        (:eligible_coverage,"Eligible coverage (all original ticks)")))
        row,col = divrem(index-1,2)
        ax = Axis(fig[row+1,col+1],title=title,xlabel="Window (replay ticks)")
        for method in SR.METHODS
            rows = filter(r -> r.method==method,result.metrics)
            scatterlines!(ax,[r.window_ticks for r in rows],
                [ismissing(getproperty(r,field)) ? NaN : Float64(getproperty(r,field)) for r in rows],label=replace(method,"_"=>" "))
        end
        index==1 && axislegend(ax;position=:rt,labelsize=11)
    end
    Label(fig[0,:],"Spikenaut offline replay — $(options.data_kind)",fontsize=23)
    Label(fig[3,:],"Past context only · missing windows excluded · descriptive allocations, no performance verdict",fontsize=15)
    fig
end
end
