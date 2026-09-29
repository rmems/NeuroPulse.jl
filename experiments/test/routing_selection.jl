using Test, TemporalFocus, TOML
const module_path = joinpath(@__DIR__, "..", "src", "RoutingSelection.jl")
@testset "routing study is available" begin
    @test isfile(module_path)
end
include(module_path)
using .RoutingSelection
const RS = RoutingSelection
const cfg = RS.default_config()

@testset "causal observations, silence, and missing masks" begin
    obs = [Observation(0.01f0, 2, 1f0, :context), Observation(0.02f0, 2, 1f0, :source)]
    state = SelectionState(cfg)
    silent = advance!(state, obs, 0f0, true)
    @test !silent.temporal_evidence
    @test silent.weights["temporal_attention"] == fill(1f0/6, 6)
    first = advance!(state, obs, 0.02f0, true)
    @test first.weights["temporal_attention"] == Float32[0,1,0,0,0,0]
    @test first.density[2] == 0.5f0 # two observed bins, one occupied source bin
    @test all(0 .<= first.density .<= 1)
    snapshot = selection_snapshot(state)
    masked = advance!(state, obs, 0.04f0, false)
    @test masked.observed == false
    @test ismissing(masked.temporal_evidence)
    @test masked.weights == first.weights
    @test state.routers["temporal_router"].tick_count == snapshot.routers["temporal_router"].tick_count
    fresh = SelectionState(cfg)
    restore_selection!(fresh, snapshot)
    @test isequal(advance!(fresh, obs, 0.04f0, false), masked)
    @test advance!(fresh, obs, 0.06f0, true) == advance!(state, obs, 0.06f0, true)
    @test_throws ArgumentError advance!(state, obs, 0.01f0, true)

    dropped = SelectionState(cfg)
    advance!(dropped, obs, 0f0, true)
    advance!(dropped, obs, 0.02f0, false)
    result = advance!(dropped, obs, 0.04f0, true)
    @test !result.temporal_evidence # no delayed ingestion of masked spikes
    @test all(iszero, result.density)

    future = vcat(obs, [Observation(4f0, 1, 1000f0, :source)])
    a, b = SelectionState(cfg), SelectionState(cfg)
    for t in Float32[0, .02, .04, .2]
        @test advance!(a, obs, t, true) == advance!(b, future, t, true)
    end
end

@testset "strict winners and handoff failures" begin
    @test strict_winner(Float32[.5,.5,0]) == 0
    @test strict_winner(Float32[0,0,0]) == 0
    @test strict_winner(Float32[.2,.6,.2]) == 2
    times = Float32[0,.02,.04,.06,.08,.10,.12,.14,.16,.18]
    @test sustained_delay(times, fill(2,10), trues(10), 2, 0f0, .2f0, 5) == Float64(.08f0)
    @test ismissing(sustained_delay(times, fill(0,10), trues(10), 2, 0f0, .2f0, 5))
    mask = Bool[true,true,true,true,false,true,true,true,true,false]
    @test ismissing(sustained_delay(times, fill(2,10), mask, 2, 0f0, .2f0, 5))
end

@testset "role labels are stripped and runs deterministic" begin
    scene = generate_scene(cfg, (strength=.35, stale=0., jitter=.012, missing=0., seed=11))
    @test all(x -> !hasproperty(x, :role) && !hasproperty(x, :target), scene.observations)
    a = evaluate_scene(cfg, scene)
    b = evaluate_scene(cfg, scene)
    @test isequal(a, b)
    @test length(a.metrics) == 8
    @test all(m -> m.handoffs == 3, a.metrics)
    @test only(filter(m -> m.method == "uniform", a.metrics)).strict_top1 == 0
    @test only(filter(m -> m.method == "uniform", a.metrics)).missed_handoffs == 3
    @test all(m -> 0 <= m.target_share <= 1, a.metrics)
end

@testset "paired verdict retains negative and uncertain results" begin
    rule = cfg["decision"]
    @test paired_verdict([.02], [.03], [0.0], [0.0], rule) == "supported"
    @test paired_verdict([-.02], [.03], [0.0], [0.0], rule) == "unsupported"
    @test paired_verdict([.002], [.003], [0.0], [0.0], rule) == "inconclusive"
    @test paired_verdict([.02], [.03], [1.0], [0.0], rule) == "unsupported"
end

@testset "evidence coverage follows each method's actual inputs" begin
    scene = generate_scene(cfg, (strength=.35, stale=0., jitter=.012, missing=0., seed=11))
    source_only = merge(scene,(observations=[Observation(.01f0,2,1f0,:source)],))
    results = evaluate_scene(cfg,source_only)
    rate = only(filter(m -> m.method == "firing_rate",results.metrics))
    attention = only(filter(m -> m.method == "temporal_attention",results.metrics))
    router = only(filter(m -> m.method == "temporal_router",results.metrics))
    @test rate.no_evidence_coverage < attention.no_evidence_coverage
    @test attention.no_evidence_coverage == 1.0
    @test router.no_evidence_coverage == rate.no_evidence_coverage
end

@testset "evaluation labels cannot steer selection" begin
    scene = generate_scene(cfg, (strength=1., stale=.25, jitter=.012, missing=.15, seed=29))
    baseline = evaluate_scene(cfg,scene)
    relabeled = evaluate_scene(cfg,merge(scene,(targets=fill(1,length(scene.targets)),)))
    @test [t.weights for t in baseline.traces] == [t.weights for t in relabeled.traces]
    @test [t.winner for t in baseline.traces] == [t.winner for t in relabeled.traces]
    @test [t.target_share for t in baseline.traces] != [t.target_share for t in relabeled.traces]
end
