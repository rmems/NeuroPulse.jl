# SPDX-License-Identifier: MIT OR Apache-2.0

@inline function _require_finite(x::Number, label::AbstractString)
    isfinite(x) || throw(ArgumentError("$label must be finite, got $x"))
    return x
end

@inline function _require_finite_event(event::SpikeEvent)
    _require_finite(event.t, "spike time")
    _require_finite(event.value, "spike value")
    return event
end

function _require_finite_events(events)
    for event in events
        _require_finite_event(event)
    end
    return events
end

function _require_finite_readout(readout::AbstractMatrix)
    for val in readout
        _require_finite(val, "readout value")
    end
    return readout
end

function _require_finite_scores(scores, label::AbstractString)
    for x in scores
        _require_finite(x, label)
    end
    return scores
end

@inline function _check_positive_rows(v::AbstractMatrix)
    nrows = size(v, 1)
    nrows > 0 || throw(ArgumentError("value matrix must have at least one row"))
    _require_finite_readout(v)
    return nrows
end

@inline function _check_neuron_id(neuron_id::Int, upper::Int, label::AbstractString)
    1 <= neuron_id <= upper || throw(
        ArgumentError("$(label) neuron_id $(neuron_id) is outside valid range 1:$(upper)"),
    )
    return neuron_id
end

@inline function _apply_readout(weights::AbstractVector{<:Real}, readout::AbstractMatrix)
    length(weights) == size(readout, 1) ||
        throw(DimensionMismatch("attention weights length must match readout rows"))
    out = transpose(readout) * weights
    return _require_finite_scores(out, "attention score")
end

"""
    spike_attention_discrete(source_spikes, context_spikes, readout)

Coincidence-based spike attention without temporal decay.

For each source event, accumulates products of source and context spike values
on matching neuron IDs, then applies the readout matrix. Timing is ignored;
only neuron identity and spike values matter.

# Arguments
- `source_spikes::SpikeTrain`: source spike train
- `context_spikes::SpikeTrain`: context spike train
- `readout::AbstractMatrix`: readout with one row per neuron (row count must be ≥ 1)

# Returns
- readout vector `transpose(readout) * attention`, where `attention` is a
  `Vector{Float32}` of length `size(readout, 1)`

# Throws
- `ArgumentError` if the readout has no rows, a source `neuron_id` is outside
  `1:size(readout, 1)`, any spike time, spike value, or readout entry is
  `NaN` or `Inf`, or a product/accumulation overflows to a non-finite score
"""
function spike_attention_discrete(
    source_spikes::SpikeTrain,
    context_spikes::SpikeTrain,
    readout::AbstractMatrix,
)
    n = _check_positive_rows(readout)
    _require_finite_events(source_spikes.events)
    _require_finite_events(context_spikes.events)
    attention = zeros(Float32, n)

    @inbounds for source_event in source_spikes.events
        source_id = _check_neuron_id(source_event.neuron_id, n, "source")
        for context_event in context_spikes.events
            if source_id == context_event.neuron_id
                attention[source_id] += source_event.value * context_event.value
            end
        end
    end
    _require_finite_scores(attention, "attention weight")

    return _apply_readout(attention, readout)
end
