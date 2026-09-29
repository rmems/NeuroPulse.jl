# SPDX-License-Identifier: MIT OR Apache-2.0
"""Experiment-only causal selection study; no package API additions."""
module RoutingSelection
using TemporalFocus, Random, Statistics, TOML
include("SpotlightScenario.jl")
using .SpotlightScenario
export Observation, SelectionState, advance!, selection_snapshot, restore_selection!
export strict_winner, sustained_delay, generate_scene, evaluate_scene, paired_verdict
export default_config, study_cases, run_study
const METHODS = ("uniform", "firing_rate", "discrete_attention", "temporal_attention",
                 "temporal_router", "no_surprise", "no_momentum", "no_inhibition")
include("RoutingScenario.jl")
include("RoutingRuntime.jl")
include("RoutingEvaluation.jl")
end
