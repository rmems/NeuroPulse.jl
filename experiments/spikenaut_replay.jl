# SPDX-License-Identifier: MIT OR Apache-2.0
using CairoMakie, ExperimentUtils, NeuroPulse, TOML, SHA
include(joinpath(@__DIR__,"src","SpikenautReplay.jl"))
include(joinpath(@__DIR__,"src","SpikenautReport.jl"))
using .SpikenautReplay

function main(args=copy(ARGS))
    options = parse_options(prepare_experiment!(NeuroPulse,args))
    cfg = validate_config(TOML.parsefile(options.config))
    data = read_replay(options.trace,options.manifest)
    result = run_replay(data,cfg)
    slug = "spikenaut_replay"
    inputs = String[options.trace,options.manifest,options.config]
    if options.builtin_fixture
        telemetry = joinpath(SpikenautReplay.FIXTURE,"telemetry.jsonl")
        data.manifest["input"]["sha256"]=="sha256:"*bytes2hex(sha256(read(telemetry))) || error("committed telemetry digest mismatch")
        push!(inputs,telemetry)
        cp(telemetry,joinpath(result_dir(slug),"input-telemetry.jsonl");force=true)
    end
    write_config(slug,SpikenautReport.effective_config(cfg,options,data))
    cp(options.trace,joinpath(result_dir(slug),"input-trace.jsonl");force=true)
    cp(options.manifest,joinpath(result_dir(slug),"input-manifest.json");force=true)
    coverage = [(window_ticks=r.window_ticks,session=r.session,step=r.step,source_line=r.source_line,
        observed=r.observed,eligible=r.eligible,missing_sensors=r.missing_sensors,
        observed_silent=r.observed_silent) for r in result.traces if r.method=="uniform"]
    push!(inputs,SpikenautReport.named_csv(slug,"coverage.csv",coverage))
    push!(inputs,SpikenautReport.named_csv(slug,"traces.csv",result.traces))
    write_metrics(slug,result.metrics)
    report = SpikenautReport.summary(result,options,data)
    write_summary(slug,report)
    CairoMakie.activate!(type="png")
    save(figure_path(slug),SpikenautReport.figure(result,options))
    finalize_run(slug;input_paths=inputs)
    println(report)
    println("Artifacts: ",result_dir(slug))
end
abspath(PROGRAM_FILE)==abspath(@__FILE__) && main()
