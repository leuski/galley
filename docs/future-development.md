# Future Development — Ideas Drawn From Competitive Gaps

> Sibling document: `competitive-analysis.md`. Each idea here corresponds to a
> gap identified in §5 of that survey. Items are sequenced by ratio of user
> value to implementation cost, not by alphabetical order.

The shape of these notes: each item states the gap, the user it's for, what
"done" looks like, where in the codebase it would live, the implementation
sketch, the realistic cost in engineering weeks, and the risks. This is a
backlog, not a roadmap — pick from it, don't burn through it.

---

## Tier 1 — High value, low cost (do these first)

### 1.1 Built-in CSS theme picker on top of the template engine

**Gap.** A first-time user opening Galley sees one default rendering and a
template menu that's empty until they install something. Marked 2 ships nine
themes; MacMD Viewer ships light/dark; QLMarkdown ships several. The bar for
"feels finished out of the box" is set by them.

**Audience.** Every new user. This is the single biggest first-impression
gap.

**What "done" looks like.**

- The bundled default template grows a `--theme` query parameter or a
  template-relative CSS variable set.
- Five to seven hand-tuned themes ship in the bundle: GitHub-style light,
  GitHub-style dark, sepia/reading, high-contrast, terminal-mono,
  manuscript/serif, and a Tufte-style sidenote layout.
- A "Theme" submenu under "View" — separate from "Template" — switches them.
- Selection persists per-document via `PerFileStateStore`, with a global
  default in `AppModel`.
- A scene-level override is honored when `enablePerDocumentOverrides` is on.

**Where it lives.**

- New `Sources/GalleyCoreKit/Templates/BuiltInThemes.swift` enumerating themes.
- Bundled CSS lives next to `DefaultTemplate.html` in
  `GalleyCoreKit/Resources/`.
- New `SceneThemeModel` mirroring `SceneTemplateModel`.
- New `ThemeMenu` view in `Sources/Viewer/Views/Menus/`.
- `Placeholders.swift` grows a `#THEME_CSS_HREF#` placeholder so user
  templates that opt in get the same dropdown for free.

**Cost.** ~1 engineering week for the framework and menu plumbing, then
ongoing design time for each new theme. Themes are content, not code.

**Risks.** Low. The only architectural risk is double-coupling: themes
need to be expressible *both* through the placeholder system (so user
templates can use them) and as a standalone fallback that works when no user
template is installed. Designing the contract once, up front, avoids a
migration later.

### 1.2 First-class Mermaid in the bundled default template

**Gap.** MacMD Viewer's headline feature; QLMarkdown supports it; Marked 2
reaches it via custom processor. Galley reaches it only if the user picks a
processor + template combination that includes the Mermaid runtime — and
the bundled default template does not.

**Audience.** Anyone reading AI-generated `.md` files (which routinely
include Mermaid blocks), engineering teams documenting architecture,
academics drawing flowcharts.

**What "done" looks like.**

- The bundled default template embeds the Mermaid runtime and initializes
  it on `<pre><code class="language-mermaid">` blocks regardless of which
  processor produced them.
- A "Mermaid" toggle in Settings (default on) so users can opt out for
  bandwidth/security reasons.
- Mermaid runs in the Galley scheme handler as well as the HTTP server, and
  works in the Quick Look extension.

**Where it lives.**

- `Sources/GalleyCoreKit/Resources/DefaultTemplate.html` gains the
  Mermaid loader (vendored, not CDN — see risks).
- `Sources/GalleyCoreKit/Resources/mermaid.min.js` vendored at a pinned
  version.
- Optional setting in the Viewer's `AppModel`.

**Cost.** ~1 week. Most of the work is template surgery and verifying
behavior across processors (Pandoc, cmark-gfm, and swift-markdown all emit
the language class slightly differently — the template needs to be tolerant
of each).

**Risks.** Mermaid is ~2 MB minified. Inlining it inflates every preview
load. Mitigation: serve it via the scheme handler / HTTP server as a static
asset (`/runtime/mermaid.js`) so it caches once. **Don't** load it from a
public CDN — Galley's audience expects offline-friendly behavior, and CDN
loads conflict with the security posture of macOS WebView's default CSP.

### 1.3 Auto-generated table of contents sidebar

**Gap.** Marked 2 and MacMD Viewer both ship a TOC sidebar with typeahead
search that follows the active heading as you scroll. Galley relies on the
template to provide one, which means in practice most users don't get one.

**Audience.** Anyone reading documents longer than one screen.

**What "done" looks like.**

- A toggleable left sidebar (View → Show Outline, ⌥⌘O).
- Built from `<h1>`–`<h6>` tags in the rendered DOM, not from the source —
  this way it works regardless of processor.
- Active-heading highlight follows scroll position (uses the existing
  `ScrollBridge`).
- Click jumps to the heading; ⌘F-style typeahead search filters the list.

**Where it lives.**

- New `Sources/Viewer/Views/OutlineSidebar.swift`.
- Template grows a `#OUTLINE_HOOK#` no-op placeholder for templates that
  want to opt out (replaced with empty string), defaults to extracting from
  the rendered DOM via a small WebView script bridge.
- Existing `ScrollBridge` extended to include the active-heading element ID.

**Cost.** ~2 weeks. The visual design is the longest part, not the
plumbing. Consider whether the sidebar should be a SwiftUI overlay on the
WebView or part of the rendered HTML — overlay is more consistent across
templates, HTML is more flexible per-template.

**Risks.** Heading IDs need to be stable. Pandoc and cmark-gfm both have
auto-ID behavior; the swift-markdown renderer doesn't generate IDs by
default. Galley would need to inject IDs at render time for templates that
don't.

### 1.4 Word count and reading-time HUD

**Gap.** Marked 2's "writer" framing leans hard on these. They're not the
full grammar/grade-level pitch, but the cheap parts of that pitch.

**Audience.** Anyone using Galley for documents they care about the length
of. Also Markoff users who already expect this.

**What "done" looks like.**

- A status-bar strip at the bottom of the document window (toggleable):
  word count, character count, reading time (configurable WPM), heading
  count.
- Computed in `DocumentModel` after each render, not on every keystroke
  (Galley isn't an editor — keystrokes don't happen here).
- Quick toggle in the View menu.

**Where it lives.**

- New `Sources/Viewer/Models/DocumentStats.swift`.
- New `Sources/Viewer/Views/StatusBar.swift`.
- Stats computed from the rendered text content (via WebView script
  bridge — the source `.md` may contain transclusion or other directives
  that make raw-source counts misleading).

**Cost.** ~3 days. Genuinely small.

**Risks.** None significant. This is the cheapest user-visible win in the
backlog.

### 1.5 Re-enable the notarized release pipeline + ship a stable DMG channel

**Gap.** Marked 2, Markoff, MacMD Viewer, PreviewMarkdown all ship through
MAS. Galley ships GitHub releases only. The `release.yml` workflow for
signed + notarized CI is in the repo but disabled. Users see "the
developer cannot be verified" on first launch.

**Audience.** Every potential user beyond the technical audience that knows
how to right-click → Open.

**What "done" looks like.**

- `release.yml` re-enabled with the secrets it needs (Apple Developer ID,
  signing certificate, app-specific password, team ID).
- Each tag produces a notarized, stapled DMG attached to the GitHub
  release.
- A homebrew-cask formula (`brew install --cask galley`) for distribution
  symmetry with QLMarkdown.

**Cost.** ~1 week including the Apple Developer enrollment and CI debugging
overhead. The tricky parts are entirely in the Apple side, not the code.

**Risks.** Apple Developer Program enrollment is $99/yr and has a
non-trivial onboarding time. The notarization workflow occasionally fails
for opaque reasons — budget time for first-build debugging.

---

## Tier 2 — Medium value, medium cost

### 2.1 In-document search (⌘F)

**Gap.** Marked 2 has typeahead search across both the TOC and the body;
MacMD Viewer has both.

**Audience.** Same as the TOC item — anyone reading long documents.

**What "done" looks like.**

- ⌘F invokes the WebView's built-in find bar (`WKWebView` exposes
  `findString(_:)` via a private-but-stable API; SwiftUI `WebPage` may need
  a small bridge).
- ⌘G / ⇧⌘G next/previous.
- The find bar surfaces match counts and supports case-sensitive +
  whole-word toggles.

**Cost.** ~1 week.

**Risks.** SwiftUI's `WebPage` doesn't expose the underlying find API
cleanly. The fallback is a small JS-side find implementation — slower, less
polished, but works everywhere. Pick one and commit.

### 2.2 Export as self-contained HTML

**Gap.** Marked 2 exports HTML with self-contained inlined images; Galley
exports PDF only. For users handing rendered output to colleagues or to a
CMS, the gap is real.

**Audience.** Documentation writers, blog authors, anyone doing handoff.

**What "done" looks like.**

- File → Export → HTML (Single File).
- Images, CSS, fonts inlined (`data:` URLs for images, embedded `<style>`
  for CSS).
- A "linked assets" alternative that emits an `index.html` + `assets/`
  folder for users who want to host the output.

**Where it lives.**

- New `Sources/Viewer/Models/DocumentModel+Export.swift` parallel to
  `DocumentModel+Print.swift`.
- Reuses the existing offscreen `WKWebView` pipeline; instead of calling
  `printOperation`, snapshots the rendered DOM via
  `evaluateJavaScript("document.documentElement.outerHTML")`, then
  post-processes to inline assets.

**Cost.** ~1.5 weeks. The asset-inlining pass is the bulk of the work
because it has to chase every URL the template might emit (background
images in CSS, `srcset` attributes, fonts, etc.).

**Risks.** "Self-contained" has soft edges — fonts loaded by `@font-face`
need their bytes; remote URLs have to be downloaded; some templates pull
runtime libraries (Mermaid, KaTeX). Be explicit about what is and isn't
inlined.

### 2.3 Multi-file / book mode (Tier-2 scope, not full Marked 2 parity)

**Gap.** Marked 2 can stitch a multi-chapter book together via
Leanpub/GitBook/mmd_merge indexes or `<<[file]` transclusion. Galley's
same-folder document watcher only watches sibling assets, not transcluded
chapters.

**Audience.** Technical book authors, manual writers, academics.

**Scope choice.** Going for full parity is multi-month. The tractable scope
is *honoring transclusion that the active processor already performs* —
Pandoc and MultiMarkdown both transclude internally; Galley's job is to
watch the resulting set of files.

**What "done" looks like.**

- After a render, the processor reports (or Galley parses out) the set of
  transcluded files.
- `DocumentWatcher` is extended to watch a *set* of files, not just a
  single file plus its sibling directory.
- Saving any transcluded file triggers a re-render of the parent.
- Optional: detect Leanpub/GitBook index conventions and treat them as the
  effective document for rendering.

**Where it lives.**

- `Sources/GalleyCoreKit/Watch/DocumentWatcher.swift` grows a
  `watchAdditional(paths:)` API.
- New `Sources/GalleyCoreKit/Render/TranscludedFiles.swift` —
  processor-by-processor logic for asking "what files contributed to this
  render?"
- Pandoc: `pandoc --trace` or pre-pass with `--print-default-data-file` is
  awkward; cleaner to grep the source for the include syntaxes the
  processors document.
- MultiMarkdown: same approach.

**Cost.** ~2–3 weeks for the watch-set extension and processor-by-processor
include detection. **Full Marked 2 parity** (rendering an index file as a
concatenated document with TOC, chapter numbering, export to a single
PDF/HTML) is several months — out of scope for now.

**Risks.** Watch-set churn (a render adds a file to the watch set; the
file's save triggers a re-render that may change the watch set again) is
subtle but tractable with the existing `bindGeneration` pattern in
`DocumentModel`.

### 2.4 Rich Text export

**Gap.** Marked 2 exports RTF; useful for pasting into Pages, Word, email.

**Audience.** Office users, email writers.

**What "done" looks like.**

- File → Export → Rich Text Format.
- Done via `NSAttributedString(html:options:)` over the rendered HTML.

**Cost.** ~3 days. `NSAttributedString` does most of the work.

**Risks.** RTF fidelity is mediocre — Word and Pages render the result
unevenly. Document the limitation rather than fight it.

### 2.5 Localization — at least one Western European language

**Gap.** EN + RU only.

**Audience.** Half the global user base.

**What "done" looks like.**

- German + French as a starting pair (both have active Mac developer
  audiences, both are tractable to QA).
- All four `Localizable.xcstrings` files (Viewer, Server, GalleyCoreKit,
  GalleyServerKit) and the Quicklook lproj directories updated.
- Spanish, Italian, Japanese, Simplified Chinese as Tier-3 follow-ups.

**Cost.** ~1 week per language, but most of the cost is translation
effort, not engineering. The xcstrings format already supports it.

**Risks.** Maintenance — every new string in every release needs translating
in N locales. Budget for a translation service or community contributors
before opening this Pandora's box.

---

## Tier 3 — Lower value or higher cost

### 3.1 Writing-analysis features (Marked 2's signature)

**Gap.** Word/sentence count beyond the basics — reading time is in Tier
1.4, but grade-level scoring, sentence complexity, "tips for simplifying
your sentences," spelling/grammar.

**Audience strategy decision.** Doing this means competing with Marked 2 on
its own ground. Galley's audience is currently *readers and developers*, not
*writers*. Pick one. If the audience strategy stays "BBEdit-friendly
previewer for developers," skip this.

**If pursued.**

- Flesch–Kincaid grade level: ~2 days.
- Sentence-complexity scoring: ~1 week.
- "Simplify this sentence" hints: dramatically more — needs an opinion on
  what counts as "complex" (passive voice, nominalization, sentence
  length, subordinate clause depth). Out of scope without a writing-tools
  consultant.
- Spelling: free via NSSpellChecker.
- Grammar: not free — needs LanguageTool or similar (open source, Java,
  ships its own server) or Apple's on-device grammar APIs in macOS 26+.

**Cost.** Months, depending on scope.

**Risks.** Writing-analysis features have *high feedback risk* — bad
heuristics produce bad recommendations and users notice. Start with the
defensible quantitative metrics (counts, reading time, grade level) and
stop there unless there's a real product reason to push deeper.

### 3.2 Bookmarks within a document

**Gap.** Marked 2 has them; nobody else does. Genuinely useful for long
documents.

**Audience.** Power readers of long technical documents.

**What "done" looks like.**

- ⌘D adds a bookmark at the current scroll position with the active
  heading as the title.
- Bookmarks panel in a left-rail sidebar (alongside or below the TOC from
  Tier 1.3).
- Persisted in `PerFileStateStore`.

**Cost.** ~1 week, mostly UX design.

### 3.3 OPML export

**Gap.** Marked 2 has it; useful for outlining tools and mind-mappers.

**Audience.** Tiny but loud — OmniOutliner / iThoughts users.

**Cost.** ~3 days. Convert the heading tree into OPML; the data structure
is identical.

### 3.4 Mac App Store distribution

**Gap.** Discoverability.

**Cost.** Substantial — App Store sandboxing forbids the unsandboxed file
access that the Viewer currently relies on, the helper-script installer is
a sandbox violation, and external-process renderers (Pandoc etc.) cannot
be launched from a sandboxed app. The way Marked 2 handles this is two
binaries — an MAS build with reduced features and a DMG build with the
full feature set. Galley would need the same.

**Recommendation.** Notarized DMG (Tier 1.5) plus Homebrew is sufficient
for the audience Galley is targeting. Defer MAS until there's a clear
audience-strategy reason to invest in maintaining two product surfaces.

### 3.5 Marketing surface — content, not engineering

Not strictly a development item, but the highest-leverage non-code work
available:

- A short demo video showing cmd-click → editor jump and the
  BBEdit-pane-to-Galley-server pairing.
- A blog post on "BBEdit + Galley" for the BBEdit power-user audience.
- A blog post on "Pandoc previewing on macOS" for the academic audience.
- Listings on alternativeto.net, MacUpdate, Setapp (if it fits), and the
  Markdown-tooling roundups linked in `competitive-analysis.md`'s sources.

**Cost.** Each of these is a half-day to a day of writing/recording, plus
a few weeks of compounding inbound interest.

**Risk.** None. This is upside-only.

---

## Sequencing recommendation

If I had four engineering weeks to spend:

1. **Week 1.** Tier 1.4 (word count / reading time HUD — fastest visible
   win) + Tier 1.5 (notarized DMG pipeline — biggest trust improvement).
2. **Week 2.** Tier 1.2 (Mermaid in the bundled template).
3. **Weeks 3–4.** Tier 1.1 (built-in themes) + Tier 1.3 (TOC sidebar) — the
   two together close the "first impression" gap completely.

After that, Tier 2.2 (HTML export) is the next-best individual item, and
Tier 3.5 (marketing) is the lever that converts engineering investment into
audience.

What *not* to do first:

- Don't build writing-analysis features before deciding the audience
  strategy.
- Don't tackle full Marked 2 book-mode parity — too long, too small an
  audience inside Galley's current target.
- Don't pursue MAS distribution before the notarized DMG is solid.

---

## Cross-references

- Each item references files and modules from the existing codebase as
  documented in `CLAUDE.md` (architecture decisions, layout, concurrency
  conventions). Read that first if any of the file paths above feel
  unfamiliar.
- The competitive context for each gap lives in `competitive-analysis.md`
  §5 and §3 (the feature matrix). Read those for the "why this gap
  matters" framing.
