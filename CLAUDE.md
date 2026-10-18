@AGENTS.md

# CLAUDE.md

Claude-specific notes only. Boundaries, toolchain policy, and session handoff rules are in `AGENTS.md`
(imported above); do not duplicate them here.

## Commands

Run from the repo root. "Verified" means it ran successfully on Julia 1.12.7 (installed with juliaup, Linux, CPU only).
`AGENTS.md` limits local work to Julia 1.12; CI (`ci.yml`) tests 1.12 on `ubuntu-latest` only.

| Command | Status |
|---|---|
| `julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'` | verified (245 + 2081 + 10 + 5 tests passed) |
| `julia --project=. examples/three_region.jl` (also `six_region.jl`, `reservoir_integration.jl`) | verified (each exits 0) |
| `julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'` then `julia --project=docs docs/make.jl` | verified (build succeeds; `docs/Manifest.toml` is tracked and already points at `..`, and this run rewrote it. Check `git diff docs/Manifest.toml` and revert only the generated change, not any edits you made yourself) |
| `julia --project=experiments -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'` | not run (instantiate did not finish here; the CairoMakie tree filled the disk) |
| `julia --project=experiments experiments/test/runtests.jl`, `experiments/run_all.jl [--list]` | not run (need the experiments environment above; `experiments/README.md` shows `+1.12.7` channel syntax) |
| JuliaFormatter 2 check on `src/` and `test/` (`format.yml`) | not run (JuliaFormatter not installed; no `.JuliaFormatter.toml`, so defaults apply) |

- `julia-actions/julia-runtest` in `ci.yml` is followed by `julia-processcoverage` and a Codecov upload that needs a secret. That upload is not a local gate.
- `documentation.yml` builds docs on PRs and deploys from `main` and tags; `Pkg.develop` of the repo is part of its install step.

## Architecture map

- `src/NeuroPulse.jl`: module definition and exports. Includes `activity_region.jl`, `region_router.jl`, and `attention/Attention.jl`.
- `src/activity_region.jl`, `src/region_router.jl`: generic routing API (`ActivityRegion`, `RegionRouter`, `update_routing!`). `LobeState`, `NeroOrchestrator`, `update_relevance!` are legacy aliases.
- `src/attention/`: `NeuroPulse.Attention` (`types.jl`, `discrete.jl`, `temporal.jl`, `continuous.jl`, `normalization.jl`), imported from TemporalFocus.jl.
- `test/runtests.jl`: includes `test_nero.jl`, `attention.jl`, `package_identity.jl`, `experiment_harness.jl`.
- `experiments/`: isolated Julia environment (own `Project.toml`) with `src/` helpers, scripts, and `experiments/test/`. The root `Project.toml` stays dependency-free of it.
- `docs/`: Documenter project (`make.jl`, pages under `docs/src/`); root `docs/*.md` are GitHub-browsing copies.
- `memory/`: dated session notes (`YYYY-MM-DD.md`) per `AGENTS.md`.

## Invariants and non-goals

- Package name is `NeuroPulse` with the UUID in `Project.toml`; see `docs/src/package-identity.md` before touching identity.
- Not a full SNN runtime, training system, or hardware layer (docstring in `src/NeuroPulse.jl`).
- Do not edit `.github/workflows`, `Project.toml`, `Manifest.toml`, or registry metadata without owner approval (`AGENTS.md`). Do not push to `main`; work on feature branches and open PRs.
- Root `Project.toml` runtime deps are only `LinearAlgebra` and `Printf`; test-only deps go in `[extras]`/`[targets]`, and plotting deps belong in `experiments/Project.toml`.
- SPDX header `# SPDX-License-Identifier: MIT OR Apache-2.0`: present on `src/`, `examples/`, `docs/make.jl`, and the experiment scripts and helpers, so keep it on new files there. `test/runtests.jl`, `test/test_nero.jl`, `test/experiment_harness.jl`, and everything in `experiments/test/` lack it.
- Most workflow actions are pinned to commit SHAs with version comments; a few in `ci.yml` use tags. Prefer SHA pins in any approved workflow change.

## Gotchas

- `Project.toml` has no `exclude`/`files` publish list, so adding this file needs no manifest change. Never run registry or publish commands.
- `.claude/` is not in `.gitignore` (`.codex/`, `.cursor/*`, `.kilo/`, `.mimocode/` are); do not commit local agent state there.
- `Manifest.toml` and `experiments/Manifest.toml` are gitignored; `docs/Manifest.toml` is tracked.
- `README.md` uses HTML for its centered header, so there is no pure-markdown rule here.
- `Project.toml` declares `julia = "1.9"` but agent and CI practice is 1.12 only.
- Edit only what the task needs.
