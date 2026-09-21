# SPDX-License-Identifier: MIT OR Apache-2.0

using Test
using TemporalFocus

const SURVIVOR_UUID = Base.UUID("b7e4c3f2-1d2e-4a5b-8c9d-0e1f2a3b4c5e")
const RETIRED_TF_UUID = Base.UUID("7f3c9f2a-6b2e-4d91-9c4f-1a2b3c4d5e6f")

@testset "Package identity (ADR 0002)" begin
    id = Base.PkgId(TemporalFocus)
    @test id.name == "TemporalFocus"
    @test id.uuid == SURVIVOR_UUID
    @test id.uuid != RETIRED_TF_UUID

    # Julia resolves a package name to at most one (name, uuid). The loaded
    # TemporalFocus must be NeuroPulse's UUID; the retired TemporalFocus.jl
    # UUID must not win (and cannot coexist under the same name).
    identified = Base.identify_package("TemporalFocus")
    @test identified !== nothing
    @test identified.name == "TemporalFocus"
    @test identified.uuid == SURVIVOR_UUID
    @test identified.uuid != RETIRED_TF_UUID
    @test identified == id
end
