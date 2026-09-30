# Package identity (ADR 0002)

NeuroPulse.jl is the single canonical repository and Julia package.

| Role | Repository | Declared `name` | UUID | Disposition |
|------|------------|-----------------|------|-------------|
| **Survivor** | [`rmems/NeuroPulse.jl`](https://github.com/rmems/NeuroPulse.jl) | `NeuroPulse` | `b7e4c3f2-1d2e-4a5b-8c9d-0e1f2a3b4c5e` | Canonical repo, package name, and UUID |
| Import source | [`rmems/TemporalFocus.jl`](https://github.com/rmems/TemporalFocus.jl) | `TemporalFocus` | `7f3c9f2a-6b2e-4d91-9c4f-1a2b3c4d5e6f` | Historical source of the imported attention surface; UUID retired from NeuroPulse |
| Later, optional | [`rmems/SpikeStream.jl`](https://github.com/rmems/SpikeStream.jl) | `SpikeStream` | `a3c7f1e2-8b4d-5c6e-9f0a-1b2c3d4e5f6a` | Out of scope for this import |

The loadable package and module name is `NeuroPulse`:

```julia
using NeuroPulse
```

Existing consumers must replace `using TemporalFocus` with `using NeuroPulse`.
The old package import does not continue as an alias. The canonical UUID and all
exported APIs remain unchanged, including the legacy routing aliases
`LobeState`, `NeroOrchestrator`, `update_relevance!`, and
`nero_diagnostics`.

## Why the rename matters

Julia identifies a package by `(name, uuid)`. Before this rename, NeuroPulse.jl
and the sibling TemporalFocus.jl repository both declared
`name = "TemporalFocus"` under distinct UUIDs, so they could not coexist in one
environment by name. NeuroPulse.jl now declares:

- name `NeuroPulse`
- UUID `b7e4c3f2-1d2e-4a5b-8c9d-0e1f2a3b4c5e`
- source of truth: this `Project.toml`

The sibling TemporalFocus.jl name and its source history remain unchanged for
attribution. Its retired UUID `7f3c9f2a-…` is not a substitute for the
canonical NeuroPulse UUID.

Proof in CI: `test/package_identity.jl` asserts that
`Base.PkgId(NeuroPulse)` and `Base.identify_package("NeuroPulse")` resolve to
the canonical UUID and this checkout, while `TemporalFocus` is not exposed by
this package.

Source SHA imported: `eb38c70aad9f077e0775312a09e4dabe7b4bc016`.

## Historical evidence

Published experiment archives retain the package name and environment snapshot
recorded when each run was created. Those bytes are immutable provenance and
are not rewritten for this rename. To produce new evidence, develop this renamed
checkout into the isolated environment; new runs record `NeuroPulse` while
their numerical CSVs remain directly comparable with the archived evidence.

## Downstream migration

Dependency declarations keyed as `TemporalFocus` must be changed to
`NeuroPulse` while retaining the canonical UUID. Source pins should target
`rmems/NeuroPulse.jl`. Cross-repository consumer updates remain separate from
this repository-only rename.

## See also

- [ADR 0002](https://github.com/rmems/TemporalFocus.jl/blob/main/docs/adr/0002-merge-temporalfocus-into-neuropulse.md)
- Tracking: [NeuroPulse.jl#43](https://github.com/rmems/NeuroPulse.jl/issues/43)
