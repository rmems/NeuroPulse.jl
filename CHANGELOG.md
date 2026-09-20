# Changelog

## Unreleased

### Added

- Import TemporalFocus.jl attention surface as `TemporalFocus.Attention`
  (`SpikeEvent`, `SpikeTrain`, `TemporalBuffer`, `spike_attention_*`, `prune!`,
  `temporal_weight`, `normalize_l1!`, `normalize_max!`) from
  `rmems/TemporalFocus.jl@eb38c70` (ADR 0002, #43)
- Executable GH#14 interop-contract tests for `ActivityRegion` / `RegionRouter` shapes (#14)
- `save_state` / `load_state!` (`load_state` alias) for `RegionRouter` checkpointing (#28)
- `LICENSE-MIT` and `LICENSE-APACHE-2.0` license files
- SPDX license identifiers to source files

### Changed

- CI test job runs Julia 1.12 on `ubuntu-latest` only (no OS matrix)
- `update_routing!` now rejects `regions` whose length is not `n_regions`, and spike rates outside `[0, 1]` (`ArgumentError`, #14)
- Switched license from GPL-3.0-or-later to dual MIT/Apache-2.0 (#13)

### Removed

- `LICENSE` (GPL-3.0-or-later)
