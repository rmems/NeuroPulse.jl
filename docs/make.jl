# SPDX-License-Identifier: MIT OR Apache-2.0
using Documenter
using TemporalFocus

makedocs(;
    modules = [TemporalFocus],
    authors = "Limen Neural and contributors",
    sitename = "NeuroPulse.jl",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://rmems.github.io/NeuroPulse.jl",
        edit_link = "main",
        assets = String[],
        repolink = "https://github.com/rmems/NeuroPulse.jl",
    ),
    pages = [
        "Home" => "index.md",
        "Overview" => "overview.md",
        "API" => "api.md",
        "Interop" => "interop.md",
        "Package identity" => "package-identity.md",
        "Roadmap" => "roadmap.md",
    ],
    # Early-stage package: allow missing docstrings without failing the build.
    warnonly = [:missing_docs],
)

# Deploy from CI push (main/tags). Documenter accepts either:
# - GITHUB_TOKEN (same-repo Pages; workflow already has contents: write), or
# - DOCUMENTER_KEY (optional SSH deploy key for fork/private setups).
# PR job clears both tokens so only makedocs runs.
const _has_github_token = !isempty(get(ENV, "GITHUB_TOKEN", ""))
const _has_documenter_key = !isempty(get(ENV, "DOCUMENTER_KEY", ""))
const _is_pr = get(ENV, "GITHUB_EVENT_NAME", "") == "pull_request"
if get(ENV, "CI", "false") == "true" && !_is_pr && (_has_github_token || _has_documenter_key)
    deploydocs(;
        repo = "github.com/rmems/NeuroPulse.jl.git",
        devbranch = "main",
        push_preview = true,
    )
end
