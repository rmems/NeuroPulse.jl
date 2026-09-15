# Changelog

## Unreleased

### Added

- Executable GH#14 interop-contract tests for `ActivityRegion` / `RegionRouter` shapes (#14)
- `save_state` / `load_state!` (`load_state` alias) for `RegionRouter` checkpointing (#28)
- `LICENSE-MIT` and `LICENSE-APACHE-2.0` license files
- SPDX license identifiers to source files

### Changed

- `update_routing!` now rejects `regions` whose length is not `n_regions` (`ArgumentError`, #14)
- Switched license from GPL-3.0-or-later to dual MIT/Apache-2.0 (#13)

### Removed

- `LICENSE` (GPL-3.0-or-later)
