using Test, SHA, JSON, TOML
const replay_source = joinpath(@__DIR__, "..", "src", "SpikenautReplay.jl")
isfile(replay_source) && include(replay_source)
@testset "offline replay adapter exists" begin
    @test isdefined(@__MODULE__, :SpikenautReplay)
end
if isdefined(@__MODULE__, :SpikenautReplay)
    using .SpikenautReplay
    const fixture = joinpath(@__DIR__, "..", "fixtures", "spikenaut")
    const replay_cfg = TOML.parsefile(joinpath(@__DIR__, "..", "configs", "spikenaut_replay.toml"))
    fixture_rows() = [JSON.parse(x) for x in readlines(joinpath(fixture,"trace.jsonl"))]
    fixture_manifest() = JSON.parsefile(joinpath(fixture,"manifest.json"))
    function with_pair(f; mutate_rows=identity, mutate_manifest=identity, digest=true)
        mktempdir() do dir
            rows, manifest = fixture_rows(), fixture_manifest()
            mutate_rows(rows); mutate_manifest(manifest)
            trace, meta = joinpath(dir,"trace.jsonl"),joinpath(dir,"manifest.json")
            write(trace,join(JSON.json.(rows),"\n")*"\n")
            digest && (manifest["trace_sha256"] = "sha256:"*bytes2hex(sha256(read(trace))))
            write(meta,JSON.json(manifest))
            f(trace,meta)
        end
    end
    @testset "producer contract validation and explicit index conversion" begin
        data = read_replay(joinpath(fixture,"trace.jsonl"),joinpath(fixture,"manifest.json"))
        @test length(data.rows) == 10
        @test data.n == 16
        @test data.rows[2].spikes == [2,4,13,16]
        @test data.rows[5].missing == ["mem_clock_mhz"]
        for mutate in (m -> m["schema_version"]="wrong", m -> m["trace_schema"]="wrong",
                m -> m["input"]["n_steps"]=9, m -> m["results"]["spikes_fired"]=33,
                m -> m["results"]["sessions"]=3, m -> m["input"]["steps_per_session"]["gpu-000001"]=4,
                m -> m["input"]["sessions"]=reverse(m["input"]["sessions"]),
                m -> m["encoder"]["missing_counts"]["sm_clock_mhz"]=0,
                m -> m["encoder"]["missing_counts"]["sm_clock_mhz"]=true,
                m -> m["input"]["steps_per_session"]["gpu-000001"]=5.0)
            with_pair(mutate_manifest=mutate) do t,m
                @test_throws ArgumentError read_replay(t,m)
            end
        end
        with_pair(digest=false) do t,m
            @test_throws ArgumentError read_replay(t,m)
        end
        for mutate in (r -> r[2]["spikes"]=[16], r -> r[2]["spikes"]=[-1],
                r -> r[2]["spikes"]=[1,1],r -> r[2]["spikes"]=[true],
                r -> r[2]["step"]=0,r -> r[2]["step"]=3,
                r -> r[7]["session"]="gpu-000001",r -> r[2]["source_line"]=1,
                r -> r[2]["stim"]=[1.0],r -> r[2]["scores"]=[1.0],
                r -> r[2]["stim"][1]="NaN",r -> r[2]["scores"][1]=Inf,
                r -> r[2]["timestamp"]="2026-09-21T00:00:00Z",r -> r[2]["missing"]=["unknown"],
                r -> r[2]["missing"]=["power_w","power_w"],
                r -> delete!(r[2],"spikes"))
            with_pair(mutate_rows=mutate) do t,m
                @test_throws ArgumentError read_replay(t,m)
            end
        end
    end
    # Tiny hand-constructed rows isolate causal behavior from the upstream LIF model.
    row(t,ids;session="a",absent=String[]) = ReplayRow(t,session,t+1,ids,absent)
    @testset "strictly past context, no self match, bounded windows and session reset" begin
        rows = [row(0,[1]),row(1,[1]),row(2,[2]),row(3,[1]),row(4,[1];session="b")]
        result = replay_window(rows,2,1,replay_cfg)
        temporal = filter(x -> x.method=="temporal_attention",result)
        @test !temporal[1].evidence
        @test temporal[1].weights == [0.5f0,0.5f0]
        @test temporal[2].evidence
        @test temporal[2].weights == [1f0,0f0]
        @test !temporal[3].evidence
        @test !temporal[4].evidence # tick 1 is too old
        @test !temporal[5].evidence # session reset
        future = vcat(rows,[row(5,[1,2];session="b")])
        @test isequal(result,replay_window(future,2,1,replay_cfg)[1:length(result)])
        @test isequal(result,replay_window(rows,2,1,replay_cfg))
    end
    @testset "missing masks preserve time and erase routing contamination" begin
        a = [row(0,[1]),row(1,[1];absent=["power_w"]),row(2,[2]),row(3,[2]),row(4,[2])]
        b = [row(0,[2]),row(1,[2];absent=["power_w"]),row(2,[2]),row(3,[2]),row(4,[2])]
        x,y = replay_window(a,2,1,replay_cfg),replay_window(b,2,1,replay_cfg)
        ta = filter(r -> r.method=="temporal_router",x)
        tb = filter(r -> r.method=="temporal_router",y)
        @test [r.step for r in ta] == 0:4
        @test [r.eligible for r in ta] == [true,false,false,true,true]
        @test ismissing(ta[2].evidence)
        @test ismissing(ta[3].entropy_bits)
        @test ta[4].weights == tb[4].weights
        @test ismissing(ta[4].turnover) # do not bridge excluded windows
        @test !ismissing(ta[5].turnover)
    end
    @testset "observed silence and ties remain descriptive" begin
        result = replay_window([row(0,Int[]),row(1,Int[])],2,1,replay_cfg)
        @test all(r -> r.eligible && r.observed_silent,result)
        @test all(r -> r.evidence == false,result)
        @test all(r -> r.winner == 0,result)
        @test all(r -> r.entropy_bits ≈ 1,result)
        @test all(r -> r.concentration ≈ .5,result)
    end
    @testset "CLI requires input pairs and honest provenance defaults" begin
        @test_throws ArgumentError parse_options(["--trace","t"])
        @test_throws ArgumentError parse_options(["--manifest","m"])
        @test_throws ArgumentError parse_options(["--bogus","x"])
        @test parse_options(String[]).data_kind == "synthetic"
        @test_throws ArgumentError parse_options(["--data-kind","measured-user-declared"])
        explicit = ["--trace",joinpath(fixture,"trace.jsonl"),"--manifest",joinpath(fixture,"manifest.json")]
        @test parse_options(explicit).data_kind == "synthetic"
        @test_throws ArgumentError parse_options(vcat(explicit,["--data-kind","measured-user-declared"]))
        mktempdir() do dir
            t,m=joinpath(dir,"renamed-trace.jsonl"),joinpath(dir,"renamed-manifest.json")
            cp(joinpath(fixture,"trace.jsonl"),t); cp(joinpath(fixture,"manifest.json"),m)
            copied = ["--trace",t,"--manifest",m]
            @test parse_options(copied).data_kind == "synthetic"
            @test_throws ArgumentError parse_options(vcat(copied,["--data-kind","measured-user-declared"]))
        end

        @test parse_options(["--trace","t","--manifest","m"]).data_kind == "unverified/unspecified"
        @test parse_options(["--trace","t","--manifest","m","--data-kind","measured-user-declared"]).data_kind == "measured-user-declared"
    end
    @testset "all missing gives unavailable statistics rather than silence" begin
        data = (rows=[row(0,[1];absent=["power_w"]),row(1,Int[];absent=["power_w"])],n=2)
        result = run_replay(data,replay_cfg)
        @test all(r -> r.eligible_ticks==0 && r.missing_ticks==2 && r.observed_silent_ticks==0,result.metrics)
        @test all(r -> ismissing(r.mean_entropy_bits) && ismissing(r.mean_turnover),result.metrics)
        @test all(r -> ismissing(r.weights) && ismissing(r.observed_silent),result.traces)
    end
    @testset "configuration rejects invalid temporal scales" begin
        for value in (0,-1,Inf,NaN)
            invalid = deepcopy(replay_cfg); invalid["tau_ticks"] = value
            @test_throws ArgumentError validate_config(invalid)
        end
        for value in ([0],[1,1],[1.5],[true])
            invalid = deepcopy(replay_cfg); invalid["windows_ticks"] = value
            @test_throws ArgumentError validate_config(invalid)
        end
    end

end
