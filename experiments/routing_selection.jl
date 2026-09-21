# SPDX-License-Identifier: MIT OR Apache-2.0
using CairoMakie, ExperimentUtils, NeuroPulse, TOML
include(joinpath(@__DIR__,"src","RoutingSelection.jl"))
include(joinpath(@__DIR__,"src","RoutingReport.jl"))
using .RoutingSelection

function main(args=copy(ARGS))
    args = prepare_experiment!(NeuroPulse,args)
    config_path = joinpath(@__DIR__,"configs","routing_selection.toml")
    if !isempty(args)
        length(args) == 2 && args[1] == "--config" || throw(ArgumentError("usage: routing_selection.jl [--config TOML] [--out-dir PATH]"))
        config_path = abspath(args[2])
    end
    cfg = TOML.parsefile(config_path)
    result = run_study(cfg)
    rows = RoutingReport.summary_rows(result,cfg)
    slug = "routing_selection"
    write_config(slug,RoutingReport.effective_config(cfg))
    inputs = String[config_path]
    for (name,data) in (("events",result.inputs),("masks",result.masks),
            ("traces",result.traces),("handoffs",result.handoffs),("paired",result.pairs),("aggregate",rows))
        push!(inputs,RoutingReport.named_csv(slug,name*".csv",data))
    end
    write_metrics(slug,result.metrics)
    summary = RoutingReport.summary_markdown(result,cfg,rows)
    write_summary(slug,summary)
    CairoMakie.activate!(type="png")
    save(figure_path(slug),RoutingReport.figure(rows,result,cfg))
    finalize_run(slug; input_paths=inputs)
    println(summary)
    println("Artifacts: ",result_dir(slug))
end
abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
