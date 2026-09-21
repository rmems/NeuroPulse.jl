# SPDX-License-Identifier: MIT OR Apache-2.0

using Test
using NeuroPulse

const SURVIVOR_UUID = Base.UUID("b7e4c3f2-1d2e-4a5b-8c9d-0e1f2a3b4c5e")
const RETIRED_TF_UUID = Base.UUID("7f3c9f2a-6b2e-4d91-9c4f-1a2b3c4d5e6f")

@testset "Package identity (ADR 0002)" begin
    id = Base.PkgId(NeuroPulse)
    @test id.name == "NeuroPulse"
    @test id.uuid == SURVIVOR_UUID
    @test id.uuid != RETIRED_TF_UUID

    identified = Base.identify_package("NeuroPulse")
    @test identified !== nothing
    @test identified.name == "NeuroPulse"
    @test identified.uuid == SURVIVOR_UUID
    @test identified.uuid != RETIRED_TF_UUID
    @test identified == id

    @test Base.pkgdir(NeuroPulse) == realpath(joinpath(@__DIR__, ".."))
    @test Base.identify_package("TemporalFocus") === nothing
end
