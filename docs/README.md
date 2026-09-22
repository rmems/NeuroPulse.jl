# TemporalFocus documentation index

Documenter builds from `docs/src/` via `docs/make.jl` and deploys to GitHub Pages.

- Published: [dev](https://limen-neural.github.io/NeuroPulse.jl/dev) (from `main`); `/stable` only after first version tag
- `src/index.md` — Documenter home
- `src/overview.md` — scope, architecture, and intended usage
- `src/api.md` — exported API notes and current limitations (preferred API docs)
- `src/interop.md` — frozen data-shape / interop contract (LIM-228 / GH#14)
- `src/experiments.md` — controlled characterization gallery and reproduction contract
- `src/roadmap.md` — candid status and next cleanup targets

```bash
julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia --project=docs docs/make.jl
```
