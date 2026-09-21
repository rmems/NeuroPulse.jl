# Package identity (ADR 0002)

NeuroPulse.jl is the single canonical repository and Julia package.

| Role | Repository | Declared `name` | UUID | Disposition |
|------|------------|-----------------|------|-------------|
| **Survivor** | [`rmems/NeuroPulse.jl`](https://github.com/rmems/NeuroPulse.jl) | `TemporalFocus` | `b7e4c3f2-1d2e-4a5b-8c9d-0e1f2a3b4c5e` | Canonical repo and UUID |
| Import source | [`rmems/TemporalFocus.jl`](https://github.com/rmems/TemporalFocus.jl) | `TemporalFocus` | `7f3c9f2a-6b2e-4d91-9c4f-1a2b3c4d5e6f` | Attention surface imported; UUID retired |
| Later, optional | [`rmems/SpikeStream.jl`](https://github.com/rmems/SpikeStream.jl) | `SpikeStream` | `a3c7f1e2-8b4d-5c6e-9f0a-1b2c3d4e5f6a` | Out of scope for this import |

The loadable module name remains `TemporalFocus` (`using TemporalFocus`). A module
rename to `NeuroPulse` is an open question and is **not** part of this change.

## Why two packages named TemporalFocus cannot coexist

Julia identifies a package by `(name, uuid)`. Two distinct UUIDs that both declare
`name = "TemporalFocus"` cannot be resolved in one environment: `Pkg` treats the
name as the user-facing identity. After this import there is one loadable
`TemporalFocus`:

- UUID `b7e4c3f2-1d2e-4a5b-8c9d-0e1f2a3b4c5e` (this repository)
- source of truth: this `Project.toml`

The retired TemporalFocus.jl UUID `7f3c9f2a-…` must not be added to any
environment that already depends on NeuroPulse. The source repository stays
online as provenance (README redirect; no archive in this workstream).

Proof in CI: `test/package_identity.jl` asserts `Base.PkgId(TemporalFocus)` and
`Base.identify_package("TemporalFocus")` both resolve to the survivor UUID.

Source SHA imported: `eb38c70aad9f077e0775312a09e4dabe7b4bc016`.

## Downstream pin (not a gate)

`rmems/Limen-Capital` `brain/Project.toml` already pins
`TemporalFocus = "b7e4c3f2-…"` via a `[sources]` git URL that still points at
the pre-transfer `Limen-Neural/NeuroPulse.jl` location. Updating that URL/`rev`
to `rmems/NeuroPulse.jl` is owned by
[Limen-Capital#9](https://github.com/rmems/Limen-Capital/issues/9). It is a
cross-repo follow-up, not a requirement for this import.

## See also

- [ADR 0002](https://github.com/rmems/TemporalFocus.jl/blob/main/docs/adr/0002-merge-temporalfocus-into-neuropulse.md)
- Tracking: [NeuroPulse.jl#43](https://github.com/rmems/NeuroPulse.jl/issues/43)
