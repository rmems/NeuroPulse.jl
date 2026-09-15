using Test
using TemporalFocus

@testset "TemporalFocus" begin

    # ── Generic API tests (preferred) ─────────────────────────────────────────

    @testset "ActivityRegion construction" begin
        r = ActivityRegion(8)
        @test r.last_spike_rate == 0.0f0
        @test length(r.output) == 8
        @test all(iszero, r.output)

        r2 = ActivityRegion(0.5f0, Float32[0.1, 0.2, 0.3])
        @test r2.last_spike_rate == 0.5f0
        @test length(r2.output) == 3
    end

    @testset "RegionRouter construction" begin
        router = RegionRouter()
        @test router.n_regions == 4
        @test router.n_out == 16
        @test length(router.routing_weights) == 4
        @test isapprox(sum(router.routing_weights), 1.0f0, atol = 1e-5)
        @test router.tick_count == 0
        @test router.region_names == ["Region1", "Region2", "Region3", "Region4"]
        @test router.config isa RoutingConfig
        @test router.config.alpha == TemporalFocus.ALPHA
        @test router.config.beta == TemporalFocus.BETA
        @test router.config.gamma == TemporalFocus.GAMMA
        @test router.config.ema_decay == TemporalFocus.EMA_DECAY
        @test router.config.min_score == TemporalFocus.MIN_SCORE
        @test router.config.epsilon == TemporalFocus.EPSILON
    end

    @testset "RoutingConfig default matches module constants" begin
        cfg = RoutingConfig()
        @test cfg.alpha == TemporalFocus.ALPHA
        @test cfg.beta == TemporalFocus.BETA
        @test cfg.gamma == TemporalFocus.GAMMA
        @test cfg.ema_decay == TemporalFocus.EMA_DECAY
        @test cfg.min_score == TemporalFocus.MIN_SCORE
        @test cfg.epsilon == TemporalFocus.EPSILON
    end

    @testset "RoutingConfig validation" begin
        A, B, G, D, M, E = (
            TemporalFocus.ALPHA,
            TemporalFocus.BETA,
            TemporalFocus.GAMMA,
            TemporalFocus.EMA_DECAY,
            TemporalFocus.MIN_SCORE,
            TemporalFocus.EPSILON,
        )
        @test_throws ArgumentError RoutingConfig(A, B, G, D, M, 0.0f0)          # epsilon
        @test_throws ArgumentError RoutingConfig(-1.0f0, B, G, D, M, E)         # alpha
        @test_throws ArgumentError RoutingConfig(A, -0.1f0, G, D, M, E)         # beta
        @test_throws ArgumentError RoutingConfig(A, B, -0.1f0, D, M, E)         # gamma
        @test_throws ArgumentError RoutingConfig(A, B, G, 1.5f0, M, E)          # ema_decay
        @test_throws ArgumentError RoutingConfig(A, B, G, -0.1f0, M, E)         # ema_decay
        @test_throws ArgumentError RoutingConfig(A, B, G, D, -0.01f0, E)        # min_score
        @test_throws ArgumentError RoutingConfig(Inf32, B, G, D, M, E)          # non-finite
        @test_throws ArgumentError RoutingConfig(A, B, G, D, NaN32, E)
        @test_throws ArgumentError RegionRouter(
            config = RoutingConfig(A, B, G, D, 0.4f0, E),
        )  # min_score * 4 > 1
        @test_throws ArgumentError RegionRouter(n_regions = 0)
        # Direct config reassignment must re-check floor feasibility
        r = RegionRouter()
        bad = RoutingConfig(A, B, G, D, 0.4f0, E)
        @test_throws ArgumentError (r.config = bad)
        r.config = RoutingConfig(A, B, G, D, M, E)  # valid
        @test r.config.min_score == M
        @test_throws ArgumentError (r.config = "not-a-config")
        # Float32 product can round to 1 while floor is still > 1/n
        n41 = 41
        too_high = nextfloat(1.0f0 / Float32(n41))
        @test_throws ArgumentError RegionRouter(
            n_regions = n41,
            n_out = 4,
            config = RoutingConfig(A, B, G, D, too_high, E),
        )
    end

    @testset "update_routing! rejects non-finite derived scores" begin
        # ema_decay=0 keeps EMA at 0; tiny epsilon + large readout can overflow surprise
        cfg = RoutingConfig(
            TemporalFocus.ALPHA,
            TemporalFocus.BETA,
            TemporalFocus.GAMMA,
            0.0f0,
            TemporalFocus.MIN_SCORE,
            floatmin(Float32),
        )
        router = RegionRouter(
            n_regions = 2,
            n_out = 4,
            region_names = ["A", "B"],
            config = cfg,
            inhibition_matrix = zeros(Float32, 2, 2),
        )
        regions = [
            ActivityRegion(1.0f0, fill(1.0f32, 4)),
            ActivityRegion(0.0f0, zeros(Float32, 4)),
        ]
        @test_throws ArgumentError update_routing!(router, regions)
    end

    @testset "min_score saturating floor uses uniform renorm" begin
        # When min_score * n_regions == 1 and softmax is already uniform,
        # excess ≈ 0 and the uniform fallback branch runs (codecov).
        # Zero inhibition + identical inputs → equal raw scores → uniform softmax.
        cfg = RoutingConfig(
            TemporalFocus.ALPHA,
            TemporalFocus.BETA,
            TemporalFocus.GAMMA,
            TemporalFocus.EMA_DECAY,
            0.25f0,  # 0.25 * 4 == 1
            TemporalFocus.EPSILON,
        )
        router = RegionRouter(config = cfg, inhibition_matrix = zeros(Float32, 4, 4))
        regions = [ActivityRegion(1.0f0, ones(Float32, 16)) for _ = 1:4]
        update_routing!(router, regions)
        @test isapprox(sum(router.routing_weights), 1.0f0, atol = 1e-5)
        @test all(w -> isapprox(w, 0.25f0; atol = 1e-4), router.routing_weights)

        # Single-region router: softmax is always 1, floor mass == 1 → same branch.
        cfg1 = RoutingConfig(
            TemporalFocus.ALPHA,
            TemporalFocus.BETA,
            TemporalFocus.GAMMA,
            TemporalFocus.EMA_DECAY,
            1.0f0,
            TemporalFocus.EPSILON,
        )
        r1 = RegionRouter(
            n_regions = 1,
            n_out = 4,
            region_names = ["Only"],
            config = cfg1,
            inhibition_matrix = zeros(Float32, 1, 1),
        )
        update_routing!(r1, [ActivityRegion(0.7f0, ones(Float32, 4))])
        @test isapprox(r1.routing_weights[1], 1.0f0, atol = 1e-5)
    end

    @testset "gamma momentum affects routing after first tick" begin
        # With momentum snapshot fixed, gamma > 0 changes weights vs gamma = 0
        # once routing_weights diverge from the uniform init.
        base = (
            TemporalFocus.ALPHA,
            TemporalFocus.BETA,
            TemporalFocus.EMA_DECAY,
            TemporalFocus.MIN_SCORE,
            TemporalFocus.EPSILON,
        )
        r0 = RegionRouter(
            config = RoutingConfig(base[1], base[2], 0.0f0, base[3], base[4], base[5]),
        )
        r1 = RegionRouter(
            config = RoutingConfig(base[1], base[2], 0.9f0, base[3], base[4], base[5]),
        )
        for _ = 1:8
            regions = [
                ActivityRegion(1.0f0, ones(Float32, 16)),
                ActivityRegion(0.2f0, 0.2f0 .* ones(Float32, 16)),
                ActivityRegion(0.0f0, zeros(Float32, 16)),
                ActivityRegion(0.0f0, zeros(Float32, 16)),
            ]
            update_routing!(r0, regions)
            update_routing!(r1, regions)
        end
        @test r0.routing_weights != r1.routing_weights
        @test r0.prev_routing_weights != r0.routing_weights ||
              r1.prev_routing_weights != r1.routing_weights
    end

    @testset "per-router alpha changes routing_weights (LIM-230 / GH#24)" begin
        # Same inputs, different alpha → different routing after enough ticks
        cfg_default = RoutingConfig()
        cfg_high_alpha = RoutingConfig(
            0.95f0,
            TemporalFocus.BETA,
            TemporalFocus.GAMMA,
            TemporalFocus.EMA_DECAY,
            TemporalFocus.MIN_SCORE,
            TemporalFocus.EPSILON,
        )
        router_a = RegionRouter(config = cfg_default)
        router_b = RegionRouter(config = cfg_high_alpha)

        for _ = 1:40
            regions = [
                ActivityRegion(1.0f0, ones(Float32, 16)),
                ActivityRegion(0.0f0, zeros(Float32, 16)),
                ActivityRegion(0.0f0, zeros(Float32, 16)),
                ActivityRegion(0.0f0, zeros(Float32, 16)),
            ]
            update_routing!(router_a, regions)
            update_routing!(router_b, regions)
        end

        @test router_a.routing_weights != router_b.routing_weights
        # Higher alpha weights spike density more → region 1 should dominate more
        @test router_b.routing_weights[1] > router_a.routing_weights[1]
        @test isapprox(sum(router_a.routing_weights), 1.0f0, atol = 1e-4)
        @test isapprox(sum(router_b.routing_weights), 1.0f0, atol = 1e-4)
    end

    @testset "update_routing! sums to 1.0" begin
        router = RegionRouter()
        regions = [ActivityRegion(rand(Float32), rand(Float32, 16)) for _ = 1:4]
        update_routing!(router, regions)
        @test isapprox(sum(router.routing_weights), 1.0f0, atol = 1e-4)
        @test router.tick_count == 1
    end

    @testset "routing_diagnostics non-empty" begin
        router = RegionRouter()
        regions = [ActivityRegion(rand(Float32), rand(Float32, 16)) for _ = 1:4]
        update_routing!(router, regions)
        s = routing_diagnostics(router)
        @test length(s) > 0
        @test occursin("tick=", s)
        @test occursin("dominant", s)
    end

    @testset "active region gains relevance" begin
        router = RegionRouter()
        for _ = 1:30
            regions = [
                ActivityRegion(1.0f0, ones(Float32, 16)),
                ActivityRegion(0.0f0, zeros(Float32, 16)),
                ActivityRegion(0.0f0, zeros(Float32, 16)),
                ActivityRegion(0.0f0, zeros(Float32, 16)),
            ]
            update_routing!(router, regions)
        end
        @test router.routing_weights[1] > router.routing_weights[2]
        @test router.routing_weights[1] > router.routing_weights[3]
        @test router.routing_weights[1] > router.routing_weights[4]
    end

    @testset "custom region count" begin
        router = RegionRouter(n_regions = 3, n_out = 8, region_names = ["A", "B", "C"])
        regions = [ActivityRegion(rand(Float32), rand(Float32, 8)) for _ = 1:3]
        update_routing!(router, regions)
        @test length(router.routing_weights) == 3
        @test isapprox(sum(router.routing_weights), 1.0f0, atol = 1e-4)
    end

    @testset "interop data-shape contract (GH#14)" begin
        n_regions, n_out = 3, 8
        router = RegionRouter(
            n_regions = n_regions,
            n_out = n_out,
            region_names = ["A", "B", "C"],
        )

        @test fieldnames(ActivityRegion) === (:last_spike_rate, :output)
        region = ActivityRegion(0.5f0, zeros(Float32, n_out))
        @test region.last_spike_rate isa Float32
        @test region.output isa Vector{Float32}
        @test eltype(region.output) === Float32
        @test length(region.output) == n_out

        @test router.routing_weights isa Vector{Float32}
        @test length(router.routing_weights) == n_regions
        @test isapprox(sum(router.routing_weights), 1.0f0, atol = 1e-5)
        @test size(router.readout_ema) == (n_regions, n_out)
        @test eltype(router.readout_ema) === Float32
        @test length(router.spike_density) == n_regions
        @test length(router.surprise) == n_regions
        @test length(router.prev_routing_weights) == n_regions
        @test size(router.inhibition_matrix) == (n_regions, n_regions)
        @test size(router.adjacency_matrix) == (n_regions, n_regions)
        @test router.config isa RoutingConfig

        regions = [
            ActivityRegion(0.9f0, ones(Float32, n_out)),
            ActivityRegion(0.4f0, 0.5f0 .* ones(Float32, n_out)),
            ActivityRegion(0.1f0, zeros(Float32, n_out)),
        ]
        @test all(r -> 0.0f0 <= r.last_spike_rate <= 1.0f0, regions)
        update_routing!(router, regions)
        @test length(router.routing_weights) == n_regions
        @test eltype(router.routing_weights) === Float32
        @test all(>=(router.config.min_score), router.routing_weights)
        @test isapprox(sum(router.routing_weights), 1.0f0, atol = 1e-4)

        wrong = [
            ActivityRegion(0.5f0, zeros(Float32, n_out - 1)),
            ActivityRegion(0.5f0, zeros(Float32, n_out)),
            ActivityRegion(0.5f0, zeros(Float32, n_out)),
        ]
        @test_throws ArgumentError update_routing!(router, wrong)

        # Compact contract only — no spike-train / event-list types in this package.
        @test !isdefined(TemporalFocus, :SpikeTrain)
        @test !isdefined(TemporalFocus, :TemporalBuffer)
        @test !isdefined(TemporalFocus, :SpikeEvent)
    end

    # ── Backward compatibility tests ─────────────────────────────────────────

    @testset "backward-compatible aliases exist" begin
        @test LobeState === ActivityRegion
        @test NeroOrchestrator === RegionRouter
        @test update_relevance! === update_routing!
        @test nero_diagnostics === routing_diagnostics
    end

    @testset "LobeState construction (backward compat)" begin
        l = LobeState(8)
        @test l isa ActivityRegion
        @test l.last_spike_rate == 0.0f0
        @test length(l.output) == 8
    end

    @testset "NeroOrchestrator construction (backward compat)" begin
        n = NeroOrchestrator()
        @test n isa RegionRouter
        @test n.n_regions == 4
        @test n.n_out == 16
        @test isapprox(sum(n.routing_weights), 1.0f0, atol = 1e-5)
        @test n.tick_count == 0
    end

    @testset "update_relevance! works (backward compat)" begin
        n = NeroOrchestrator()
        lobes = [LobeState(rand(Float32), rand(Float32, 16)) for _ = 1:4]
        update_relevance!(n, lobes)
        @test isapprox(sum(n.routing_weights), 1.0f0, atol = 1e-4)
        @test n.tick_count == 1
    end

    @testset "all scores ≥ MIN_SCORE" begin
        router = RegionRouter()
        for _ = 1:20
            regions = [ActivityRegion(rand(Float32), rand(Float32, 16)) for _ = 1:4]
            update_routing!(router, regions)
        end
        for r in router.routing_weights
            @test r >= TemporalFocus.MIN_SCORE
        end
    end

    @testset "tick counter increments" begin
        router = RegionRouter()
        regions = [ActivityRegion(16) for _ = 1:4]
        for i = 1:5
            update_routing!(router, regions)
            @test router.tick_count == i
        end
    end

    @testset "diagnostics string contains expected content" begin
        router = RegionRouter()
        regions = [ActivityRegion(rand(Float32), rand(Float32, 16)) for _ = 1:4]
        update_routing!(router, regions)
        s = routing_diagnostics(router)
        @test length(s) > 0
        @test occursin("tick=", s)
        @test occursin("dominant", s)
    end

    @testset "prev_relevance field exists and is populated (regression LIM-5)" begin
        router = RegionRouter()
        @test hasproperty(router, :prev_relevance)
        @test length(router.prev_relevance) == 4
        @test all(iszero, router.prev_relevance)

        regions = [
            ActivityRegion(1.0f0, ones(Float32, 16)),
            ActivityRegion(0.0f0, zeros(Float32, 16)),
            ActivityRegion(0.0f0, zeros(Float32, 16)),
            ActivityRegion(0.0f0, zeros(Float32, 16)),
        ]
        update_routing!(router, regions)

        @test !all(iszero, router.prev_relevance)
        @test length(router.prev_relevance) == 4

        prev_first = copy(router.prev_relevance)
        update_routing!(router, regions)
        @test router.prev_relevance != prev_first
    end

    @testset "NERO_* constant aliases exist" begin
        @test TemporalFocus.NERO_ALPHA === TemporalFocus.ALPHA
        @test TemporalFocus.NERO_BETA === TemporalFocus.BETA
        @test TemporalFocus.NERO_GAMMA === TemporalFocus.GAMMA
        @test TemporalFocus.NERO_EMA_DECAY === TemporalFocus.EMA_DECAY
        @test TemporalFocus.NERO_MIN_SCORE === TemporalFocus.MIN_SCORE
        @test TemporalFocus.NERO_EPSILON === TemporalFocus.EPSILON
        @test TemporalFocus.NERO_DEFAULT_LOBE_NAMES === TemporalFocus.DEFAULT_REGION_NAMES
        @test TemporalFocus.NERO_INHIBIT === TemporalFocus.INHIBIT
    end

    # ── Configurable inhibition matrix (LIM-229 / GH#23) ─────────────────────

    @testset "inhibition_matrix: NERO_INHIBIT === INHIBIT" begin
        @test TemporalFocus.NERO_INHIBIT === TemporalFocus.INHIBIT
    end

    @testset "inhibition_matrix: n=4 default equals historical INHIBIT" begin
        router = RegionRouter()
        @test hasproperty(router, :inhibition_matrix)
        @test size(router.inhibition_matrix) == (4, 4)
        @test router.inhibition_matrix == TemporalFocus.INHIBIT
        @test eltype(router.inhibition_matrix) == Float32
    end

    @testset "inhibition_matrix: n=3 default equals INHIBIT[1:3,1:3]" begin
        router = RegionRouter(n_regions = 3, n_out = 8)
        expected = TemporalFocus.INHIBIT[1:3, 1:3]
        @test size(router.inhibition_matrix) == (3, 3)
        @test router.inhibition_matrix == expected
        @test eltype(router.inhibition_matrix) == Float32
        # Historical asymmetry preserved (2→1 is 0.04, not geometric 0.08)
        @test router.inhibition_matrix[2, 1] == 0.04f0
        @test router.inhibition_matrix[1, 2] == 0.08f0
    end

    @testset "inhibition_matrix: n=6 default has zero diagonal and positive off-diag" begin
        router = RegionRouter(n_regions = 6, n_out = 8)
        M = router.inhibition_matrix
        @test size(M) == (6, 6)
        @test eltype(M) == Float32
        for i = 1:6
            @test M[i, i] == 0.0f0
        end
        @test any(M[i, j] > 0 for i = 1:6, j = 1:6 if i != j)
    end

    @testset "inhibition_matrix: n=6 update_routing! runs without error" begin
        router = RegionRouter(n_regions = 6, n_out = 8)
        regions = [ActivityRegion(rand(Float32), rand(Float32, 8)) for _ = 1:6]
        update_routing!(router, regions)
        @test length(router.routing_weights) == 6
        @test isapprox(sum(router.routing_weights), 1.0f0, atol = 1e-4)
        @test router.tick_count == 1
    end

    @testset "inhibition_matrix: non-zero inhibition differs from zero matrix" begin
        n = 4
        n_out = 8
        names = ["A", "B", "C", "D"]
        regions = [
            ActivityRegion(1.0f0, ones(Float32, n_out)),
            ActivityRegion(0.8f0, 0.8f0 .* ones(Float32, n_out)),
            ActivityRegion(0.2f0, 0.2f0 .* ones(Float32, n_out)),
            ActivityRegion(0.1f0, 0.1f0 .* ones(Float32, n_out)),
        ]

        r_zero = RegionRouter(
            n_regions = n,
            n_out = n_out,
            region_names = names,
            inhibition_matrix = zeros(Float32, n, n),
        )
        r_inh = RegionRouter(
            n_regions = n,
            n_out = n_out,
            region_names = names,
            inhibition_matrix = TemporalFocus.INHIBIT,
        )
        for _ = 1:10
            update_routing!(r_zero, regions)
            update_routing!(r_inh, regions)
        end
        @test r_zero.routing_weights != r_inh.routing_weights
    end

    @testset "inhibition_matrix: custom matrix accepted" begin
        custom = Float32[
            0.0 0.1 0.0
            0.05 0.0 0.1
            0.0 0.05 0.0
        ]
        router = RegionRouter(
            n_regions = 3,
            n_out = 4,
            region_names = ["A", "B", "C"],
            inhibition_matrix = custom,
        )
        @test router.inhibition_matrix == custom
        @test eltype(router.inhibition_matrix) == Float32
        regions = [ActivityRegion(rand(Float32), rand(Float32, 4)) for _ = 1:3]
        update_routing!(router, regions)
        @test isapprox(sum(router.routing_weights), 1.0f0, atol = 1e-4)
    end

    @testset "inhibition_matrix: wrong size throws ArgumentError" begin
        @test_throws ArgumentError RegionRouter(
            n_regions = 3,
            inhibition_matrix = zeros(Float32, 2, 2),
        )
    end


    # ── Checkpointing (LIM-234 / GH#28) ───────────────────────────────────────

    @testset "save_state / load_state! round-trip" begin
        custom_cfg = RoutingConfig(
            0.7f0,
            TemporalFocus.BETA,
            TemporalFocus.GAMMA,
            TemporalFocus.EMA_DECAY,
            TemporalFocus.MIN_SCORE,
            TemporalFocus.EPSILON,
        )
        router = RegionRouter(
            n_regions = 3,
            n_out = 8,
            region_names = ["A", "B", "C"],
            config = custom_cfg,
        )
        for _ = 1:5
            regions = [
                ActivityRegion(0.9f0, ones(Float32, 8)),
                ActivityRegion(0.1f0, 0.2f0 .* ones(Float32, 8)),
                ActivityRegion(0.0f0, zeros(Float32, 8)),
            ]
            update_routing!(router, regions)
        end

        snap = save_state(router)
        @test snap isa NamedTuple
        @test snap.n_regions == 3
        @test snap.n_out == 8
        @test snap.tick_count == 5
        @test snap.region_names == ["A", "B", "C"]
        @test snap.region_names !== router.region_names
        @test snap.config == custom_cfg
        @test snap.routing_weights == router.routing_weights
        @test snap.readout_ema == router.readout_ema
        # Snapshot must own independent buffers (not views into the router)
        @test snap.routing_weights !== router.routing_weights
        @test snap.readout_ema !== router.readout_ema
        @test snap.spike_density !== router.spike_density
        @test snap.prev_routing_weights !== router.prev_routing_weights
        @test snap.prev_relevance !== router.prev_relevance
        @test snap.surprise !== router.surprise
        @test snap.scratch !== router.scratch

        # Capture expected state at the snapshot point
        expected_weights = copy(router.routing_weights)
        expected_ema = copy(router.readout_ema)
        expected_density = copy(router.spike_density)
        expected_prev_w = copy(router.prev_routing_weights)
        expected_prev_rel = copy(router.prev_relevance)
        expected_surprise = copy(router.surprise)
        expected_scratch = copy(router.scratch)
        expected_tick = router.tick_count
        expected_cfg = router.config

        # Mutate router away from snapshot (including config)
        router.config = RoutingConfig()
        for _ = 1:3
            regions = [ActivityRegion(rand(Float32), rand(Float32, 8)) for _ = 1:3]
            update_routing!(router, regions)
        end
        @test router.tick_count == 8
        @test router.routing_weights != expected_weights
        @test router.config != expected_cfg

        # Restore
        load_state!(router, snap)
        @test router.tick_count == expected_tick
        @test router.routing_weights == expected_weights
        @test router.readout_ema == expected_ema
        @test router.spike_density == expected_density
        @test router.prev_routing_weights == expected_prev_w
        @test router.prev_relevance == expected_prev_rel
        @test router.surprise == expected_surprise
        @test router.scratch == expected_scratch
        @test router.config == expected_cfg

        # load_state alias works
        mutate_snap = save_state(router)
        router.tick_count = 0
        fill!(router.routing_weights, 0.0f0)
        load_state(router, mutate_snap)
        @test router.tick_count == expected_tick
        @test router.routing_weights == expected_weights
        @test router.config == expected_cfg

        # Further ticks after restore remain consistent with a fresh twin
        twin = RegionRouter(n_regions = 3, n_out = 8, region_names = ["A", "B", "C"])
        load_state!(twin, snap)
        @test twin.config == expected_cfg
        regions = [
            ActivityRegion(0.5f0, 0.5f0 .* ones(Float32, 8)),
            ActivityRegion(0.4f0, 0.3f0 .* ones(Float32, 8)),
            ActivityRegion(0.2f0, 0.1f0 .* ones(Float32, 8)),
        ]
        update_routing!(router, regions)
        update_routing!(twin, regions)
        @test router.tick_count == twin.tick_count == expected_tick + 1
        @test router.routing_weights == twin.routing_weights
        @test router.readout_ema == twin.readout_ema
        @test router.surprise == twin.surprise
    end

    @testset "load_state! rejects dimension mismatch" begin
        router = RegionRouter(n_regions = 4, n_out = 16)
        other = RegionRouter(n_regions = 3, n_out = 8, region_names = ["A", "B", "C"])
        update_routing!(
            other,
            [ActivityRegion(rand(Float32), rand(Float32, 8)) for _ = 1:3],
        )
        snap = save_state(other)
        @test_throws ArgumentError load_state!(router, snap)

        # Same n_regions/n_out labels but wrong vector length
        bad = (
            n_regions = 4,
            n_out = 16,
            region_names = copy(router.region_names),
            adjacency_matrix = copy(router.adjacency_matrix),
            inhibition_matrix = copy(router.inhibition_matrix),
            routing_weights = zeros(Float32, 2),
            readout_ema = zeros(Float32, 4, 16),
            spike_density = zeros(Float32, 4),
            prev_routing_weights = zeros(Float32, 4),
            prev_relevance = zeros(Float32, 4),
            surprise = zeros(Float32, 4),
            scratch = zeros(Float32, 16),
            tick_count = Int64(0),
        )
        @test_throws ArgumentError load_state!(router, bad)
    end

    @testset "load_state! rejects region_names mismatch" begin
        source = RegionRouter(n_regions = 3, n_out = 4, region_names = ["A", "B", "C"])
        update_routing!(
            source,
            [ActivityRegion(rand(Float32), rand(Float32, 4)) for _ = 1:3],
        )
        snap = save_state(source)
        target = RegionRouter(n_regions = 3, n_out = 4, region_names = ["X", "Y", "Z"])
        @test_throws ArgumentError load_state!(target, snap)
        err = try
            load_state!(target, snap)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("region_names", sprint(showerror, err))
    end

    @testset "load_state! rejects inhibition_matrix mismatch" begin
        n = 3
        n_out = 4
        names = ["A", "B", "C"]
        custom = Float32[
            0.0 0.1 0.0
            0.05 0.0 0.1
            0.0 0.05 0.0
        ]
        source = RegionRouter(
            n_regions = n,
            n_out = n_out,
            region_names = names,
            inhibition_matrix = custom,
        )
        update_routing!(
            source,
            [ActivityRegion(rand(Float32), rand(Float32, n_out)) for _ = 1:n],
        )
        snap = save_state(source)
        @test snap.inhibition_matrix == custom
        @test snap.inhibition_matrix !== source.inhibition_matrix

        # Same size, default inhibition — must not silently load
        target = RegionRouter(n_regions = n, n_out = n_out, region_names = names)
        @test target.inhibition_matrix != custom
        @test_throws ArgumentError load_state!(target, snap)

        # Matching custom matrix still loads
        twin = RegionRouter(
            n_regions = n,
            n_out = n_out,
            region_names = names,
            inhibition_matrix = custom,
        )
        load_state!(twin, snap)
        @test twin.routing_weights == source.routing_weights
        @test twin.tick_count == source.tick_count
    end

    @testset "load_state! rejects snapshot missing structural fields" begin
        router = RegionRouter(n_regions = 3, n_out = 4, region_names = ["A", "B", "C"])
        update_routing!(
            router,
            [ActivityRegion(rand(Float32), rand(Float32, 4)) for _ = 1:3],
        )
        snap = save_state(router)
        # Older/hand-built snapshot without structural fields
        incomplete = (
            n_regions = snap.n_regions,
            n_out = snap.n_out,
            routing_weights = snap.routing_weights,
            readout_ema = snap.readout_ema,
            spike_density = snap.spike_density,
            prev_routing_weights = snap.prev_routing_weights,
            prev_relevance = snap.prev_relevance,
            surprise = snap.surprise,
            scratch = snap.scratch,
            tick_count = snap.tick_count,
        )
        @test_throws ArgumentError load_state!(router, incomplete)

        # Missing only adjacency_matrix
        no_adj = (
            n_regions = snap.n_regions,
            n_out = snap.n_out,
            region_names = snap.region_names,
            inhibition_matrix = snap.inhibition_matrix,
            routing_weights = snap.routing_weights,
            readout_ema = snap.readout_ema,
            spike_density = snap.spike_density,
            prev_routing_weights = snap.prev_routing_weights,
            prev_relevance = snap.prev_relevance,
            surprise = snap.surprise,
            scratch = snap.scratch,
            tick_count = snap.tick_count,
        )
        err_adj = try
            load_state!(router, no_adj)
            nothing
        catch e
            e
        end
        @test err_adj isa ArgumentError
        @test occursin("adjacency_matrix", sprint(showerror, err_adj))

        # Missing only inhibition_matrix
        no_inh = (
            n_regions = snap.n_regions,
            n_out = snap.n_out,
            region_names = snap.region_names,
            adjacency_matrix = snap.adjacency_matrix,
            routing_weights = snap.routing_weights,
            readout_ema = snap.readout_ema,
            spike_density = snap.spike_density,
            prev_routing_weights = snap.prev_routing_weights,
            prev_relevance = snap.prev_relevance,
            surprise = snap.surprise,
            scratch = snap.scratch,
            tick_count = snap.tick_count,
        )
        err_inh = try
            load_state!(router, no_inh)
            nothing
        catch e
            e
        end
        @test err_inh isa ArgumentError
        @test occursin("inhibition_matrix", sprint(showerror, err_inh))

        # Missing only region_names
        no_names = (
            n_regions = snap.n_regions,
            n_out = snap.n_out,
            adjacency_matrix = snap.adjacency_matrix,
            inhibition_matrix = snap.inhibition_matrix,
            routing_weights = snap.routing_weights,
            readout_ema = snap.readout_ema,
            spike_density = snap.spike_density,
            prev_routing_weights = snap.prev_routing_weights,
            prev_relevance = snap.prev_relevance,
            surprise = snap.surprise,
            scratch = snap.scratch,
            tick_count = snap.tick_count,
        )
        err_names = try
            load_state!(router, no_names)
            nothing
        catch e
            e
        end
        @test err_names isa ArgumentError
        @test occursin("region_names", sprint(showerror, err_names))

        # Legacy snapshot without scratch: fill! zero path
        no_scratch = (
            n_regions = snap.n_regions,
            n_out = snap.n_out,
            region_names = snap.region_names,
            adjacency_matrix = snap.adjacency_matrix,
            inhibition_matrix = snap.inhibition_matrix,
            config = snap.config,
            routing_weights = snap.routing_weights,
            readout_ema = snap.readout_ema,
            spike_density = snap.spike_density,
            prev_routing_weights = snap.prev_routing_weights,
            prev_relevance = snap.prev_relevance,
            surprise = snap.surprise,
            tick_count = snap.tick_count,
        )
        fill!(router.scratch, 1.0f0)
        load_state!(router, no_scratch)
        @test all(iszero, router.scratch)

        # adjacency_matrix mismatch
        bad_adj = merge(snap, (; adjacency_matrix = ones(Float32, 3, 3)))
        @test_throws ArgumentError load_state!(router, bad_adj)
    end


    @testset "update_routing! rejects output length mismatch" begin
        router = RegionRouter(n_out = 8)
        regions = [ActivityRegion(0.5f0, ones(Float32, 4)) for _ = 1:4]  # wrong width
        @test_throws ArgumentError update_routing!(router, regions)
    end

    @testset "update_routing! accepts large finite readouts" begin
        # Float32 sum-of-squares would overflow ~1e20; Float64 staging must accept.
        router = RegionRouter(n_out = 4, inhibition_matrix = zeros(Float32, 4, 4))
        big = fill(1.0f20, 4)
        regions = [ActivityRegion(0.5f0, copy(big)) for _ = 1:4]
        update_routing!(router, regions)
        @test all(isfinite, router.routing_weights)
        @test isapprox(sum(router.routing_weights), 1.0f0, atol = 1e-3)
    end

    # ── adapt_leak! (LIM-233 / GH#27) ──────────────────────────────────────────

    @testset "adapt_leak! default stress percent scale [0, 100]" begin
        # Default adapter: stress is a percent-like signal in [0, 100] → unit interval,
        # then lerped to leak bounds. (Back-compat with old fan-speed call sites.)
        leak = Ref(0.0f0)
        adapt_leak!(leak, 0)   # zero stress → min_leak
        @test leak[] == 0.01f0

        adapt_leak!(leak, 100) # full stress → max_leak
        @test leak[] == 0.25f0

        adapt_leak!(leak, 50)  # mid stress
        @test isapprox(leak[], 0.13f0, atol = 1e-5)

        # stress outside [0, 100] clamps to endpoints
        adapt_leak!(leak, -10)
        @test leak[] == 0.01f0
        adapt_leak!(leak, 200)
        @test leak[] == 0.25f0
    end

    @testset "adapt_leak! custom min/max with stress" begin
        leak = Ref(0.0f0)
        adapt_leak!(leak, 0; min_leak = 0.05f0, max_leak = 0.50f0)
        @test leak[] == 0.05f0

        adapt_leak!(leak, 100; min_leak = 0.05f0, max_leak = 0.50f0)
        @test leak[] == 0.50f0

        adapt_leak!(leak, 50; min_leak = 0.05f0, max_leak = 0.50f0)
        @test isapprox(leak[], 0.275f0, atol = 1e-5)
    end

    @testset "adapt_leak! Real stress bounds kwargs" begin
        leak = Ref(0.0f0)
        # Float64 kwargs accepted and converted to Float32 internally
        adapt_leak!(leak, 0; min_leak = 0.05, max_leak = 0.50)
        @test leak[] == 0.05f0

        adapt_leak!(leak, 100; min_leak = 0.05, max_leak = 0.50)
        @test leak[] == 0.50f0

        adapt_leak!(leak, 50; min_leak = 0.05, max_leak = 0.50)
        @test isapprox(leak[], 0.275f0, atol = 1e-5)
    end

    @testset "adapt_leak! inverted stress bounds" begin
        leak = Ref(0.0f0)
        @test_throws ArgumentError adapt_leak!(leak, 50; min_leak = 0.5f0, max_leak = 0.1f0)
        @test_throws ArgumentError adapt_leak!(leak, 50; min_leak = 0.5, max_leak = 0.1)
    end

    @testset "adapt_leak! custom stress_adapter" begin
        leak = Ref(0.0f0)
        # identity adapter: stress already in unit interval [0, 1]
        unit_adapter = s -> Float32(s)
        adapt_leak!(leak, 0.0; stress_adapter = unit_adapter)
        @test leak[] == 0.01f0

        adapt_leak!(leak, 1.0; stress_adapter = unit_adapter)
        @test leak[] == 0.25f0

        adapt_leak!(leak, 0.5; stress_adapter = unit_adapter)
        @test isapprox(leak[], 0.13f0, atol = 1e-5)

        # custom stress adapter + custom min/max
        adapt_leak!(
            leak,
            0.25;
            min_leak = 0.1f0,
            max_leak = 0.9f0,
            stress_adapter = unit_adapter,
        )
        @test isapprox(leak[], 0.1f0 + 0.25f0 * (0.9f0 - 0.1f0), atol = 1e-5)
    end

    @testset "adapt_leak! rejects non-finite bounds" begin
        leak = Ref(0.0f0)
        @test_throws ArgumentError adapt_leak!(leak, 50; min_leak = NaN)
        @test_throws ArgumentError adapt_leak!(leak, 50; max_leak = Inf)
        @test_throws ArgumentError adapt_leak!(leak, 50; min_leak = -Inf, max_leak = Inf)
        @test_throws ArgumentError adapt_leak!(leak, 50; min_leak = NaN, max_leak = 0.2f0)
    end

    @testset "adapt_leak! clamps custom adapter output" begin
        leak = Ref(0.0f0)
        over_adapter = s -> Float32(s) + 10.0f0
        adapt_leak!(leak, 50.0; stress_adapter = over_adapter)
        @test leak[] == 0.25f0

        under_adapter = s -> Float32(s) - 100.0f0
        adapt_leak!(leak, 50.0; stress_adapter = under_adapter)
        @test leak[] == 0.01f0

        # clamping respects custom bounds
        adapt_leak!(
            leak,
            50.0;
            min_leak = 0.1f0,
            max_leak = 0.5f0,
            stress_adapter = over_adapter,
        )
        @test leak[] == 0.5f0
    end

    @testset "adapt_leak! rejects NaN and clamps infinities" begin
        leak = Ref(0.0f0)
        # NaN propagates through clamp and must raise ArgumentError
        @test_throws ArgumentError adapt_leak!(leak, NaN)
        @test_throws ArgumentError adapt_leak!(leak, 0.0; stress_adapter = _ -> NaN)

        # Infinities are clamped to the unit bounds
        adapt_leak!(leak, Inf)
        @test leak[] == 0.25f0
        adapt_leak!(leak, -Inf)
        @test leak[] == 0.01f0
        adapt_leak!(leak, 0.0; stress_adapter = _ -> Inf)
        @test leak[] == 0.25f0
    end

end
