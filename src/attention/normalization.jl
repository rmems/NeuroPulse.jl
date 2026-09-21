# SPDX-License-Identifier: MIT OR Apache-2.0

"""
    normalize_l1!(weights) -> weights

In-place L1 normalization of a weight vector.

Divides each element by `sum(weights)` when the sum is positive; otherwise
leaves `weights` unchanged.

# Arguments
- `weights::AbstractVector{<:AbstractFloat}`: vector mutated in place

# Returns
- the same `weights` vector after normalization (or unchanged if sum ≤ 0)
"""
function normalize_l1!(weights::AbstractVector{<:AbstractFloat})
    total = sum(weights)
    if total > zero(total)
        weights ./= total
    end
    return weights
end

"""
    normalize_max!(weights) -> weights

In-place max normalization of a weight vector.

Divides each element by `maximum(weights)` when the peak is positive; otherwise
leaves `weights` unchanged.

# Arguments
- `weights::AbstractVector{<:AbstractFloat}`: vector mutated in place

# Returns
- the same `weights` vector after normalization (or unchanged if peak ≤ 0)
"""
function normalize_max!(weights::AbstractVector{<:AbstractFloat})
    peak = maximum(weights)
    if peak > zero(peak)
        weights ./= peak
    end
    return weights
end
