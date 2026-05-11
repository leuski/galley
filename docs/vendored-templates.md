# Vendored Template CSS

Upstream stylesheets vendored into
`Sources/GalleyCoreKit/Resources/Templates.bundle/`.
Re-sync with the per-repo scripts in `Scripts/`.

Each `## ...` section below is owned by one sync script. Scripts rewrite
their own section in-place between the marker comments. Do not edit the
auto-generated lines by hand.

<!-- BEGIN: github-markdown-css -->

## github-markdown-css

- Source: <https://github.com/sindresorhus/github-markdown-css>
- License: MIT (see `Templates.bundle/GitHub/LICENSE`)
- Pinned version: `5.9.0`
- Vendored: `Templates.bundle/GitHub/vendor.css` (SHA-256 `6112686f954db5d3806fb96116d2ab20ad3018469ab1015c587fd8efe7d25cf4`)
- Last sync: 2026-05-11
- Sync command: `./Scripts/sync-github-markdown-css.sh`

Galley-specific overrides (page chrome, print rules, mermaid)
live in `Templates.bundle/GitHub/overrides.css` and load *after*
the vendor file.

<!-- END: github-markdown-css -->

<!-- BEGIN: tufte-css -->

## tufte-css

- Source: <https://github.com/edwardtufte/tufte-css>
- License: MIT (see `Templates.bundle/Tufte/LICENSE`)
- Pinned version: `1.8.0`
- Vendored: `Templates.bundle/Tufte/vendor.css` (SHA-256 `2804171fd09715ce1fdbdb7b45ac0dae161ab2ad29347a707912f9d6b1e17604`)
- Fonts: `Templates.bundle/Tufte/et-book/` (222168 bytes, five faces, woff only — eot/ttf/svg pruned at sync time)
- Last sync: 2026-05-11
- Sync command: `./Scripts/sync-tufte-css.sh`

Galley-specific overrides (mermaid, print) live in
`Templates.bundle/Tufte/overrides.css` and load *after* the
vendor file. Tufte CSS already ships a dark-mode variant.

<!-- END: tufte-css -->

<!-- BEGIN: latex-css -->

## latex-css

- Source: <https://github.com/vincentdoerig/latex-css>
- License: MIT (see `Templates.bundle/LaTeX/LICENSE`)
- Pinned version: `1.13.0`
- Vendored: `Templates.bundle/LaTeX/vendor.css` (SHA-256 `773c8dfd6ac8d602e54b014d01db83ba2cde262646e528577cdbb1508353aba4`)
- Fonts: `Templates.bundle/LaTeX/fonts/` (1246984 bytes, Latin Modern + Libertinus, woff2 only)
- Last sync: 2026-05-11
- Sync command: `./Scripts/sync-latex-css.sh`

Galley-specific overrides (mermaid, print) live in
`Templates.bundle/LaTeX/overrides.css` and load *after* the
vendor file. The vendor's dark mode is an opt-in `.latex-dark`
class; `LaTeX.html` ships a one-line script that toggles it on
`<html>` when the system reports dark, so the vendor palette
stays the single source of truth.

<!-- END: latex-css -->
