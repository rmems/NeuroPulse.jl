using Test, TOML, SHA
@testset "replay CLI artifacts retain coverage and input provenance" begin
    script = joinpath(@__DIR__,"..","spikenaut_replay.jl")
    @test isfile(script)
    if isfile(script)
        mktempdir() do dir
            env = joinpath(@__DIR__,"..")
            run(`$(Base.julia_cmd()) --project=$env $script --out-dir $dir`)
            output = joinpath(dir,"spikenaut_replay")
            @test all(isfile(joinpath(output,p)) for p in ("metrics.csv","traces.csv","coverage.csv","config.toml","summary.md","figure.png","provenance.toml","Project.toml","Manifest.toml","input-trace.jsonl","input-manifest.json"))
            cfg = TOML.parsefile(joinpath(output,"config.toml"))
            @test cfg["data_kind"] == "synthetic"
            provenance = TOML.parsefile(joinpath(output,"provenance.toml"))
            @test provenance["inputs"]["trace.jsonl"] == "9f7b7144165350514a3351e607178e33b44542437cf4171a8b2bbc678a028bb4"
            @test haskey(provenance["inputs"],"manifest.json")
            @test haskey(provenance["inputs"],"spikenaut_replay.toml")
            @test haskey(provenance["inputs"],"traces.csv")
            @test read(joinpath(output,"input-manifest.json")) == read(joinpath(env,"fixtures","spikenaut","manifest.json"))
            @test length(readlines(joinpath(output,"traces.csv"))) == 201
            @test length(readlines(joinpath(output,"coverage.csv"))) == 41
        end
    end
end
