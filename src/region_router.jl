# SPDX-License-Identifier: MIT OR Apache-2.0
# region_router.jl — Generic region-based relevance routing
#
# Computes per-tick routing weights across activity regions using:
#
#   1. Spike Density  — normalised firing rate of the region (0..1).
#      A region that is firing actively is "engaged" with the current regime.
#
#   2. Manifold Surprise — how much the region's current readout deviates from its
#      recent exponential moving average (EMA).  High surprise → the region just
#      transitioned into a new attractor / regime.
#
# Final relevance = α × spike_density + β × manifold_surprise + γ × ema_momentum
# All scalars are Float32; no heap allocation in the hot path.

using LinearAlgebra: norm
using Printf

# ── Tuning Constants ──────────────────────────────────────────────────────────

const ALPHA = 0.50f0       # Weight: spike density contribution
const BETA = 0.35f0        # Weight: manifold surprise contribution
const GAMMA = 0.15f0       # Weight: readout EMA momentum
const EMA_DECAY = 0.05f0   # EMA smoothing factor (5% new estimate per tick)
const MIN_SCORE = 0.01f0   # Clamp: never let any region drop to zero relevance
const EPSILON = 1.0f-6     # Numerical stability floor for normalisation

# Backward-compatible aliases
const NERO_ALPHA = ALPHA
const NERO_BETA = BETA
const NERO_GAMMA = GAMMA
const NERO_EMA_DECAY = EMA_DECAY
const NERO_MIN_SCORE = MIN_SCORE
const NERO_EPSILON = EPSILON

# Default region names for the historical 4-component example layout.
# Callers should override these when modeling a different system boundary.
const DEFAULT_REGION_NAMES = ["Region1", "Region2", "Region3", "Region4"]
const NERO_DEFAULT_LOBE_NAMES = DEFAULT_REGION_NAMES

# Cross-region inhibition: lateral inhibition for winner-take-all routing.
# Layout: INHIBIT[from_region, to_region]. Higher values = stronger suppression.
const INHIBIT = Float32[
    0.0 0.08 0.05 0.02   # Region1 → {Region2, Region3, Region4}
    0.04 0.0 0.06 0.03   # Region2 → {Region1, Region3, Region4}
    0.02 0.03 0.0 0.05   # Region3 → {Region1, Region2, Region4}
    0.01 0.02 0.03 0.0   # Region4 → {Region1, Region2, Region3}
]
const NERO_INHIBIT = INHIBIT

"""
    default_inhibition_matrix(n_regions) -> Matrix{Float32}

Build the default cross-region inhibition matrix.

- For `n_regions <= 4`: top-left `n_regions × n_regions` slice of the historical
  asymmetric `INHIBIT` layout (copy). Preserves pre-LIM-229 behavior for smaller
  routers that previously applied `INHIBIT[1:n, 1:n]` via bounds checks.
- For `n_regions > 4`: zero diagonal; off-diagonal lateral inhibition that decays
  with index distance, `0.08f0 / abs(i - j)` (symmetric under `i ↔ j`).
"""
function default_inhibition_matrix(n_regions::Int)::Matrix{Float32}
    if n_regions <= 4
        return copy(INHIBIT[1:n_regions, 1:n_regions])
    end
    M = zeros(Float32, n_regions, n_regions)
    for i = 1:n_regions, j = 1:n_regions
        if i != j
            M[i, j] = 0.08f0 / Float32(abs(i - j))
        end
    end
    return M
end


# ── Per-router tuning ─────────────────────────────────────────────────────────

"""
    RoutingConfig

Per-router scoring knobs. Defaults match the module-level ALPHA..EPSILON constants.

Note: the snapshot-order change in LIM-230 activates `gamma` (momentum term) by
capturing pre-update weights before the current tick overwrites them. Previously,
`gamma` had no effect since the snapshot occurred after the update.

All six fields must be finite. `alpha`/`beta`/`gamma`/`min_score` are non-negative,
`ema_decay ∈ [0, 1]`, and `epsilon > 0`.

`min_score` is also checked against router size in [`RegionRouter`](@ref):
`min_score ≤ 1/n_regions` in Float32 so a post-normalization floor is feasible.
"""
struct RoutingConfig
    alpha::Float32
    beta::Float32
    gamma::Float32
    ema_decay::Float32
    min_score::Float32
    epsilon::Float32

    function RoutingConfig(alpha, beta, gamma, ema_decay, min_score, epsilon)
        a = Float32(alpha)
        b = Float32(beta)
        g = Float32(gamma)
        d = Float32(ema_decay)
        m = Float32(min_score)
        e = Float32(epsilon)
        for (name, v) in (
            (:alpha, a),
            (:beta, b),
            (:gamma, g),
            (:ema_decay, d),
            (:min_score, m),
            (:epsilon, e),
        )
            isfinite(v) || throw(ArgumentError("$name must be finite, got $v"))
        end
        a >= 0.0f0 || throw(ArgumentError("alpha must be non-negative, got $a"))
        b >= 0.0f0 || throw(ArgumentError("beta must be non-negative, got $b"))
        g >= 0.0f0 || throw(ArgumentError("gamma must be non-negative, got $g"))
        0.0f0 <= d <= 1.0f0 || throw(ArgumentError("ema_decay must be in [0,1], got $d"))
        m >= 0.0f0 || throw(ArgumentError("min_score must be non-negative, got $m"))
        e > 0.0f0 || throw(
            ArgumentError("epsilon must be positive to prevent division by zero, got $e"),
        )
        new(a, b, g, d, m, e)
    end
end
RoutingConfig() = RoutingConfig(ALPHA, BETA, GAMMA, EMA_DECAY, MIN_SCORE, EPSILON)

function _validate_floor_feasibility(min_score::Float32, n_regions::Int)
    n_regions > 0 || throw(ArgumentError("n_regions must be positive, got $n_regions"))
    # Compare against the representable uniform weight, not `min_score * n` (which can
    # round to 1.0f0 while min_score is still strictly above 1/n in Float32).
    uniform = 1.0f0 / Float32(n_regions)
    if min_score > uniform
        throw(
            ArgumentError(
                "min_score ($min_score) exceeds representable uniform weight " *
                "1/n_regions ($uniform) for n_regions=$n_regions",
            ),
        )
    end
    return nothing
end

# ── Router State ──────────────────────────────────────────────────────────────

"""
    RegionRouter

Holds all mutable state for per-tick relevance routing.
Pre-allocated at startup; the hot-path `update_routing!` does NO heap
allocation — all work is in-place on these fields.

Fields:
  n_regions          — number of regions (default 4)
  n_out              — readout width per region (default 16)
  region_names       — human-readable region labels
  adjacency_matrix   — n_regions × n_regions directed adjacency weights
  inhibition_matrix  — n_regions × n_regions cross-region inhibition weights
  routing_weights    — current routing weights vector (sums to 1.0)
  readout_ema        — per-region EMA of the readout (n_regions × n_out)
  spike_density      — current spike density per region
  prev_routing_weights — previous tick routing weights (for momentum)
  prev_relevance     — scratch buffer for raw relevance scores during computation (readable after tick)
  surprise           — manifold surprise score per region
  scratch            — reusable scratch buffer (n_out elements)
  tick_count         — global tick counter
  config             — per-router scoring knobs (`RoutingConfig`)
"""
mutable struct RegionRouter
    n_regions::Int
    n_out::Int
    region_names::Vector{String}
    adjacency_matrix::Matrix{Float32}
    inhibition_matrix::Matrix{Float32}
    routing_weights::Vector{Float32}
    readout_ema::Matrix{Float32}
    spike_density::Vector{Float32}
    prev_routing_weights::Vector{Float32}
    prev_relevance::Vector{Float32}
    surprise::Vector{Float32}
    scratch::Vector{Float32}
    tick_count::Int64
    config::RoutingConfig
end

"""
Validate `config` against this router's `n_regions` when replacing `router.config`.
"""
function Base.setproperty!(router::RegionRouter, name::Symbol, value)
    if name === :config
        value isa RoutingConfig ||
            throw(ArgumentError("config must be a RoutingConfig, got $(typeof(value))"))
        _validate_floor_feasibility(value.min_score, getfield(router, :n_regions))
        return setfield!(router, :config, value)
    end
    return invoke(setproperty!, Tuple{Any,Symbol,Any}, router, name, value)
end

"""
    RegionRouter(; n_regions=4, n_out=16, region_names=DEFAULT_REGION_NAMES,
                   inhibition_matrix=nothing, config=RoutingConfig()) -> RegionRouter

Build the static region graph and pre-allocate all working buffers.

If `inhibition_matrix` is `nothing`, a default matrix is built via
`default_inhibition_matrix(n_regions)`. Otherwise the provided matrix is
converted to `Matrix{Float32}` and must be `n_regions × n_regions`.
"""
function RegionRouter(;
    n_regions::Int = 4,
    n_out::Int = 16,
    region_names::Vector{String} = DEFAULT_REGION_NAMES,
    inhibition_matrix::Union{Nothing,AbstractMatrix} = nothing,
    config::RoutingConfig = RoutingConfig(),
)
    _validate_floor_feasibility(config.min_score, n_regions)

    # Auto-generate region names if not enough provided
    if length(region_names) < n_regions
        region_names =
            vcat(region_names, ["Region$i" for i = (length(region_names)+1):n_regions])
    end
    region_names = region_names[1:n_regions]

    adjacency_matrix = zeros(Float32, n_regions, n_regions)
    for i = 1:n_regions, j = 1:n_regions
        i != j && (adjacency_matrix[i, j] = 1.0f0)
    end

    if inhibition_matrix === nothing
        inh = default_inhibition_matrix(n_regions)
    else
        inh = Matrix{Float32}(inhibition_matrix)
        if size(inh) != (n_regions, n_regions)
            throw(
                ArgumentError(
                    "inhibition_matrix must be n_regions × n_regions, got $(size(inh)) for n_regions=$n_regions",
                ),
            )
        end
    end

    RegionRouter(
        n_regions,
        n_out,
        region_names,
        adjacency_matrix,
        inh,
        fill(1.0f0 / n_regions, n_regions),
        zeros(Float32, n_regions, n_out),
        zeros(Float32, n_regions),
        fill(1.0f0 / n_regions, n_regions),
        zeros(Float32, n_regions),
        zeros(Float32, n_regions),
        zeros(Float32, n_out),
        Int64(0),
        config,
    )
end

# ── Core Update ───────────────────────────────────────────────────────────────

"""
    update_routing!(router, regions) -> nothing

Compute relevance scores for all regions from the current activity states.
`regions` is a `Vector{ActivityRegion}` — one per region. Throws `ArgumentError` if
`length(regions) != router.n_regions` or if any region's `output` length is not
`router.n_out`.

The result is stored in `router.routing_weights` (n_regions × Float32).

Algorithm per region i:
  1. spike_density[i]  = regions[i].last_spike_rate
  2. readout_ema[i,:]  = (1-EMA_DECAY)×old_ema + EMA_DECAY×regions[i].output
  3. surprise[i]       = norm(readout_delta) / (norm(readout_ema) + ε)
  4. momentum[i]       = |routing_weights[i] - prev_routing_weights[i]|
  5. raw[i]            = α×density + β×surprise + γ×momentum

Cross-region inhibition:
  6. inhibited[i] = raw[i] - Σⱼ inhibition_matrix[j,i] × raw[j]
     (only over adjacent edges where adjacency_matrix[j,i] > 0)

Softmax normalisation → sum(relevance) = 1.0, each ≥ MIN_SCORE.
"""
function update_routing!(router::RegionRouter, regions::Vector{ActivityRegion})
    n = router.n_regions
    length(regions) == n || throw(
        ArgumentError(
            "regions length $(length(regions)) does not match n_regions=$n",
        ),
    )
    cfg = router.config
    _validate_floor_feasibility(cfg.min_score, n)
    raw = router.prev_relevance   # staging buffer; committed after finiteness checks
    d = cfg.ema_decay

    # ── Stage 1-3: score collection WITHOUT committing EMA / weights ──────
    # Surprise uses the post-update EMA formula, but `readout_ema` is only written
    # after inhibition finiteness checks pass (retry-safe for matrix fixes).
    # Norms accumulate in Float64 so large finite Float32 readouts do not overflow.
    for i = 1:n
        region = regions[i]

        spike_rate = region.last_spike_rate
        isfinite(spike_rate) ||
            throw(ArgumentError("non-finite spike rate for region $i (got $spike_rate)"))

        out = region.output
        length(out) == router.n_out || throw(
            ArgumentError(
                "region $i output length $(length(out)) does not match n_out=$(router.n_out)",
            ),
        )
        for val in out
            isfinite(val) ||
                throw(ArgumentError("non-finite readout value for region $i (got $val)"))
        end

        @views ema_row = router.readout_ema[i, :]
        # Stage ema_new into scratch; use overflow-safe BLAS norm for delta/ema_new.
        @. router.scratch = (1.0f0 - d) * ema_row + d * out
        # delta = out - ema_new into... reuse via temporary Float64 norms:
        delta_sq = 0.0
        ema_new_sq = 0.0
        @inbounds for j = 1:router.n_out
            new_e = Float64(router.scratch[j])
            del = Float64(out[j]) - new_e
            delta_sq += del * del
            ema_new_sq += new_e * new_e
        end
        surprise = Float32(sqrt(delta_sq) / (sqrt(ema_new_sq) + Float64(cfg.epsilon)))
        isfinite(surprise) || throw(
            ArgumentError(
                "non-finite surprise for region $i (got $surprise); " *
                "check ema_decay/epsilon/readout scale",
            ),
        )

        momentum = abs(router.routing_weights[i] - router.prev_routing_weights[i])
        raw_score = cfg.alpha * spike_rate + cfg.beta * surprise + cfg.gamma * momentum
        isfinite(raw_score) || throw(
            ArgumentError(
                "non-finite raw score for region $i (got $raw_score); " *
                "check alpha/beta/gamma magnitudes",
            ),
        )

        router.spike_density[i] = spike_rate
        router.surprise[i] = surprise
        raw[i] = raw_score
    end

    # ── Stage 4: validate inhibition (no EMA / weight mutation yet) ───────
    for dst = 1:n
        inh_sum = 0.0f0
        for src = 1:n
            if router.adjacency_matrix[src, dst] > 0.0f0
                inh_sum += router.inhibition_matrix[src, dst] * raw[src]
            end
        end
        isfinite(inh_sum) || throw(
            ArgumentError(
                "non-finite inhibition sum for region $dst (got $inh_sum); " *
                "check inhibition_matrix magnitudes",
            ),
        )
        inhibited_raw = raw[dst] - inh_sum
        isfinite(inhibited_raw) || throw(
            ArgumentError(
                "non-finite inhibited score for region $dst (raw=$inhibited_raw); " *
                "check inhibition_matrix magnitudes",
            ),
        )
    end

    # Commit EMA only after inhibition validation (caller can fix matrix and retry).
    for i = 1:n
        @views ema_row = router.readout_ema[i, :]
        @. ema_row = (1.0f0 - d) * ema_row + d * regions[i].output
    end

    # Snapshot pre-update weights, then write inhibited scores into routing_weights.
    copyto!(router.prev_routing_weights, router.routing_weights)
    inhibited = router.routing_weights
    for dst = 1:n
        inh_sum = 0.0f0
        for src = 1:n
            if router.adjacency_matrix[src, dst] > 0.0f0
                inh_sum += router.inhibition_matrix[src, dst] * raw[src]
            end
        end
        inhibited[dst] = max(raw[dst] - inh_sum, cfg.min_score)
    end

    # ── Stage 5: softmax normalisation ────────────────────────────────────
    # `epsilon` is the shared stability floor (surprise denom + softmax normalizer).
    max_val = maximum(inhibited)
    s = 0.0f0
    for i = 1:n
        inhibited[i] = exp(inhibited[i] - max_val)
        s += inhibited[i]
    end
    inhibited ./= (s + cfg.epsilon)

    for i = 1:n
        if inhibited[i] < cfg.min_score
            inhibited[i] = cfg.min_score
        end
    end

    total = sum(inhibited)
    floor_mass = Float32(n) * cfg.min_score
    excess = total - floor_mass
    if excess > cfg.epsilon
        for i = 1:n
            inhibited[i] =
                cfg.min_score +
                (inhibited[i] - cfg.min_score) * (1.0f0 - floor_mass) / excess
        end
    else
        for i = 1:n
            inhibited[i] = 1.0f0 / Float32(n)
        end
    end

    router.tick_count += 1
    return nothing
end

# ── Checkpointing ─────────────────────────────────────────────────────────────

"""
    save_state(router::RegionRouter) -> NamedTuple

Copy mutable routing state into a serializable `NamedTuple` for checkpointing.

Includes `n_regions` and `n_out` for load-time validation, plus copies of
`region_names`, `adjacency_matrix`, and `inhibition_matrix` so loads can reject
routers whose labels/graph/inhibition config does not match the experiment that
produced the snapshot. Also records `config::RoutingConfig` so scoring knobs
round-trip with the checkpoint. Mutable array fields are independent copies
(`copy`) so later `update_routing!` calls do not mutate the snapshot. Element
types are immutable (`Float32` / `String` / `RoutingConfig`), so `copy` is
sufficient for arrays.
"""
function save_state(router::RegionRouter)
    return (
        n_regions = router.n_regions,
        n_out = router.n_out,
        region_names = copy(router.region_names),
        adjacency_matrix = copy(router.adjacency_matrix),
        inhibition_matrix = copy(router.inhibition_matrix),
        config = router.config,
        routing_weights = copy(router.routing_weights),
        readout_ema = copy(router.readout_ema),
        spike_density = copy(router.spike_density),
        prev_routing_weights = copy(router.prev_routing_weights),
        prev_relevance = copy(router.prev_relevance),
        surprise = copy(router.surprise),
        scratch = copy(router.scratch),
        tick_count = router.tick_count,
    )
end

"""
    load_state!(router::RegionRouter, snap) -> RegionRouter

Restore mutable routing state in-place from a snapshot produced by `save_state`.

Throws `ArgumentError` if:
- `n_regions` / `n_out` or any array size does not match the target router
- snapshot is missing required structural fields `region_names`,
  `adjacency_matrix`, or `inhibition_matrix` (always written by `save_state`)
- those structural fields do not equal the target router's configuration

Structural fields are validated but not restored — the target router must
already be configured for the same experiment labels/graph/inhibition.

When the snapshot includes `config` (always written by current `save_state`),
it is restored onto the target router so scoring knobs match the checkpointed
experiment. Older snapshots without `config` leave the target's config unchanged.
"""
function load_state!(router::RegionRouter, snap)
    n = router.n_regions
    n_out = router.n_out

    snap_n = Int(snap.n_regions)
    snap_n_out = Int(snap.n_out)
    if snap_n != n || snap_n_out != n_out
        throw(
            ArgumentError(
                "snapshot dimensions (n_regions=$(snap_n), n_out=$(snap_n_out)) do not match router (n_regions=$n, n_out=$n_out)",
            ),
        )
    end

    # Required structural routing config (always present in save_state output).
    hasproperty(snap, :region_names) ||
        throw(ArgumentError("snapshot is missing required field region_names"))
    hasproperty(snap, :adjacency_matrix) ||
        throw(ArgumentError("snapshot is missing required field adjacency_matrix"))
    hasproperty(snap, :inhibition_matrix) ||
        throw(ArgumentError("snapshot is missing required field inhibition_matrix"))
    _check_vec_len(snap.region_names, n, :region_names)
    _check_mat_size(snap.adjacency_matrix, (n, n), :adjacency_matrix)
    _check_mat_size(snap.inhibition_matrix, (n, n), :inhibition_matrix)
    if collect(String, snap.region_names) != router.region_names
        throw(ArgumentError("snapshot region_names do not match router region_names"))
    end
    if snap.adjacency_matrix != router.adjacency_matrix
        throw(
            ArgumentError(
                "snapshot adjacency_matrix does not match router adjacency_matrix",
            ),
        )
    end
    if snap.inhibition_matrix != router.inhibition_matrix
        throw(
            ArgumentError(
                "snapshot inhibition_matrix does not match router inhibition_matrix",
            ),
        )
    end

    _check_vec_len(snap.routing_weights, n, :routing_weights)
    _check_mat_size(snap.readout_ema, (n, n_out), :readout_ema)
    _check_vec_len(snap.spike_density, n, :spike_density)
    _check_vec_len(snap.prev_routing_weights, n, :prev_routing_weights)
    _check_vec_len(snap.prev_relevance, n, :prev_relevance)
    _check_vec_len(snap.surprise, n, :surprise)
    if hasproperty(snap, :scratch)
        _check_vec_len(snap.scratch, n_out, :scratch)
    end

    if hasproperty(snap, :config)
        cfg = snap.config
        cfg isa RoutingConfig || throw(
            ArgumentError("snapshot config must be a RoutingConfig, got $(typeof(cfg))"),
        )
        _validate_floor_feasibility(cfg.min_score, n)
        router.config = cfg
    end

    copyto!(router.routing_weights, snap.routing_weights)
    copyto!(router.readout_ema, snap.readout_ema)
    copyto!(router.spike_density, snap.spike_density)
    copyto!(router.prev_routing_weights, snap.prev_routing_weights)
    copyto!(router.prev_relevance, snap.prev_relevance)
    copyto!(router.surprise, snap.surprise)
    if hasproperty(snap, :scratch)
        copyto!(router.scratch, snap.scratch)
    else
        # Working buffer only; zero when absent so restore is deterministic.
        fill!(router.scratch, 0.0f0)
    end
    router.tick_count = Int64(snap.tick_count)

    return router
end

"""
    load_state(router::RegionRouter, snap) -> RegionRouter

Alias for [`load_state!`](@ref). Prefer `load_state!` for the mutating API.
"""
const load_state = load_state!

@inline function _check_vec_len(v, expected::Int, name::Symbol)
    length(v) == expected || throw(
        ArgumentError(
            "snapshot $name length $(length(v)) does not match expected $expected",
        ),
    )
    return nothing
end

@inline function _check_mat_size(m, expected::Tuple{Int,Int}, name::Symbol)
    size(m) == expected || throw(
        ArgumentError("snapshot $name size $(size(m)) does not match expected $expected"),
    )
    return nothing
end

# ── Diagnostics ───────────────────────────────────────────────────────────────

"""
    routing_diagnostics(router::RegionRouter) -> String

One-line routing state summary for logging.
"""
function routing_diagnostics(router::RegionRouter)::String
    region_strs = [
        @sprintf("%s=%.2f", router.region_names[i], router.routing_weights[i]) for
        i = 1:router.n_regions
    ]
    dominant = argmax(router.routing_weights)
    surprise_str =
        join([@sprintf("%.3f", router.surprise[i]) for i = 1:router.n_regions], ",")
    @sprintf(
        "[tick=%d] %s | dominant=%s | surprise=[%s]",
        router.tick_count,
        join(region_strs, " "),
        router.region_names[dominant],
        surprise_str
    )
end
