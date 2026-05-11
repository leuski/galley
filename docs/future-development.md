# Future Development — Ideas Drawn From Competitive Gaps

> Sibling document: `competitive-analysis.md`. Each idea here corresponds to a
> gap identified in §5 of that survey. Items are sequenced by ratio of user
> value to implementation cost, not by alphabetical order.

The shape of these notes: each item states the gap, the user it's for, what
"done" looks like, where in the codebase it would live, the implementation
sketch, the realistic cost in engineering weeks, and the risks. This is a
backlog, not a roadmap — pick from it, don't burn through it.

---

## Shipped since the last revision

Tracked here so the original Tier-1/Tier-2 numbering keeps its meaning when
cross-referenced from elsewhere. None of the items below are candidates for
new work — only follow-ups call them out.

- **1.2 Mermaid in the bundled default template.** Shipped as part of the
  template-collapse refactor (`742775e`). `mermaid.min.js` lives next to
  the bundled HTML in `Sources/GalleyCoreKit/Resources/Templates.bundle/`
  and the default template initializes it on `language-mermaid` blocks.
  The opt-out toggle envisioned in the original spec was not added — if a
  user complaint surfaces, that's where the follow-up would land.
- **1.3 Auto-generated table-of-contents sidebar.** `TOCSidebar.swift`
  ships a toggleable left rail; `697b5dd` added active-section highlighting
  driven by the existing `ScrollBridge`. Built from the rendered DOM, so it
  works regardless of processor.
- **2.1 In-document search (⌘F).** Shipped as a focus-aware sliding find
  bar (`511c83d`), with later refactors splitting the model
  (`SearchFieldModel`, `FindSession`) from the view (`FindBar`,
  `ToolbarSearchField`, `AppKitSearchField`, `SearchField`). Lives under
  the Edit menu (`EditCommands.swift`).

Partially shipped:

- **1.1 Built-in themes.** Five hand-tuned bundled templates ship in
  `Templates.bundle` (`Default`, `GitHub`, `HighContrast`, `Sepia`,
  `Terminal`) per `0940f98`. They're surfaced through the existing Template
  menu rather than as a separate "Theme" submenu — i.e. the
  template-and-theme axes were collapsed rather than split. The
  manuscript/serif and Tufte-style sidenote layouts envisioned in the
  original spec are still missing; treat those as follow-ups to 1.1 if the
  audience asks for them.

Adjacent work that doesn't map onto a tier in this list but is worth knowing
about when scoping the remaining items:

- Server liveness probe + "stale server detected" UX
  (`Sources/GalleyCoreKit/Networking/ServerProbe.swift`,
  `ServerStatus.swift`, plus `ServerStatusModel` / `ServerStatusPill` in
  the Viewer).
- Page-background-color resolution + window-chrome tinting (`e463081`,
  `0c2417e`, `803fde6`, `cd683fe`) — relevant if a future export feature
  needs to honor the rendered background.
- "Transparent toolbar" Settings toggle (`0cc5af3`).
- PDF export migrated to SwiftUI's `fileExporter` (`ee41fa6`).

---

## Tier 1 — High value, low cost (do these first)

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
  that make raw-source counts misleading). The TOC sidebar already
  evaluates JS against the rendered DOM; reuse the same plumbing.

**Cost.** ~3 days. Genuinely small.

**Risks.** None significant. This is the cheapest user-visible win still
on the backlog.

### 1.5 Re-enable the notarized release pipeline + ship a stable DMG channel

**Gap.** Marked 2, Markoff, MacMD Viewer, PreviewMarkdown all ship through
MAS. Galley ships GitHub releases only. The `release.yml` workflow for
signed + notarized CI is in the repo but disabled. Users see "the
developer cannot be verified" on first launch.

**Audience.** Every potential user beyond the technical audience that knows
how to right-click → Open.

**What "done" looks like.**

- `release.yml` re-enabled with the secrets it needs (Apple Developer ID,
  signing certificate, app-specific password, team ID — already
  enumerated in the workflow's header comment).
- Each tag produces a notarized, stapled DMG attached to the GitHub
  release.
- A homebrew-cask formula (`brew install --cask galley`) for distribution
  symmetry with QLMarkdown.

**Cost.** ~1 week including the Apple Developer enrollment and CI debugging
overhead. The tricky parts are entirely in the Apple side, not the code.

**Risks.** Apple Developer Program enrollment is $99/yr and has a
non-trivial onboarding time. The notarization workflow occasionally fails
for opaque reasons — budget time for first-build debugging.

### 1.1-followup Two more bundled themes (manuscript / Tufte)

The five-template set covers GitHub-style, sepia, high-contrast, and
terminal-mono. The original spec called out a manuscript/serif layout and
a Tufte-style sidenote layout as Tier-1 wins; both are still missing. Each
is a single hand-tuned CSS pass against the existing template engine — the
plumbing is done, only the design work is left.

**Cost.** ~1 day each, gated on design time.

---

## Tier 2 — Medium value, medium cost

### 2.2 Export as self-contained HTML — **skip as a user-facing feature**

The Marked-2-parity pitch ("export HTML for colleagues / CMSs / blogs")
is a 2011 workflow that modern Markdown tooling has mostly retired.
After an honest audience audit:

- **CMSs ingest Markdown directly.** WordPress, Ghost, Notion, Sanity
  all take `.md` (first-class or via plugin). Nobody pastes
  hand-exported HTML into a CMS field anymore.
- **Static site generators ingest Markdown directly.** Hugo, Jekyll,
  11ty, Astro, Docusaurus, MkDocs, mdBook, VitePress — every one of
  these takes `.md` and produces HTML *themselves*, with the site's
  theme, navigation, and asset pipeline applied. Galley's HTML is
  wrong-shaped for any of these targets: wrong CSS, no chrome, no nav.
- **Email handoff prefers PDF.** `.html` attachments trip security
  warnings; inline-HTML email rendering is unreliable. PDF (already
  shipped) is what people actually send.
- **"Send to a colleague to edit"** wants the `.md`, not the HTML.

The one defensible case is **archival / portability** — a self-contained
HTML file as a future-proof artifact. Real, small audience, and PDF
already covers most of the same intent.

The original justification for shipping ("Marked 2 has it") is
competitive parity, not user demand. Parity without demand is a
perpetual maintenance line item: every new template, every new
processor attribute, every WebKit behavior change becomes a bug surface
that has to stay green.

**Verdict.** Don't ship a File → Export → HTML menu. If a future
capability needs the rendered-HTML snapshot path (Foundation Models
summarization in 4.6, programmatic export via App Intents, anything
else), build the snapshot infrastructure when its real consumer exists
— don't build it speculatively against a menu nobody clicks.

#### What to ship instead: an automated paste-round-trip test

The user need 2.2 and 2.4 were trying to address ("get formatted output
from Galley into another app") is largely covered for free by the
clipboard. `WKWebView` puts both `public.html` and `public.rtf` on the
pasteboard on Edit → Copy by default, so select-all → copy → paste-into-
Pages / Word / Mail / Notes already works. No new menu command — the
single Edit → Copy is the surface, and it stays that way.

What is missing is **confidence that it stays working** when templates
or processors change. That's testable:

When a paste target on macOS receives `public.html`, it ultimately calls
`NSAttributedString(html:options:)` on the bytes (Mail, Notes, Pages,
TextEdit all do; Word's HTML importer is its own black box). So the
realistic regression surface — "did a template tweak break the paste
path?" — collapses to one deterministic operation that the existing
Swift Testing harness can drive.

**Test shape**, lives in `Tests/GalleyCoreKitTests/`:

- Fixture Markdown that exercises the structurally-interesting elements:
  headings H1–H6, paragraph, bold, italic, inline code, fenced code
  block, ordered/unordered list, table, blockquote, link, image.
- For each bundled template, render the fixture through
  `SwiftMarkdownRenderer` + the template's HTML, producing the same
  bytes that the WebView would write to `public.html` on Copy.
- Pipe the HTML through `NSAttributedString(documentSource: .html)`.
- Re-export the attributed string as `.rtf` data via
  `data(from:documentAttributes:)` to also exercise the `public.rtf`
  path that Pages/Word often prefer.
- Assert structural invariants on the attributed string:
  - Bold runs carry `.traitBold`; italic runs carry `.traitItalic`.
  - `<code>` and `<pre>` runs use a monospaced font.
  - `<a>` runs carry `.link` with the expected URL.
  - Headings 1–6 each produce at least one run with elevated point size
    relative to body copy.
  - Tables produce text containing every cell's content in row-major
    order (NSAttributedString flattens tables to text — verify the
    content survives even if structure doesn't).
  - Lists preserve item text and an order/bullet marker.
  - Total length is within a sane range of the input text length
    (catches catastrophic stripping).
- Snapshot-assert the RTF byte length and a small content prefix per
  template, so an unexplained format collapse trips the test.

**What this catches.** Silent regressions where a CSS or template tweak
breaks the HTML → NSAttributedString → RTF round-trip across the four
native macOS paste targets. That's the realistic failure mode and the
one worth automating.

**What this does not catch.** Word's HTML importer quirks (different
code path; would need UI automation against Word, not worth it),
Mermaid-as-image clipboard behavior (involves the WebView's image
serialization, not the HTML alone), and visual subtleties (does the
code block background color look right in Mail's specific CSS subset?).
Manual spot-check across the four targets once, document the result,
move on. The automated test owns regression coverage thereafter.

**Cost.** ~1 day, including fixture authoring and per-template
snapshots. The test runs in the existing `Tests` bundle the Viewer
scheme already executes; no new target.

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

### 2.4 Rich Text export — **skip entirely**

Even weaker than 2.2. Two facts kill it:

1. **The clipboard already does this.** Select text in Galley's
   rendered view → Edit → Copy → paste into Pages, Word, or Mail. The
   WebView puts rich text on the pasteboard for free. The "I want
   formatted text in Word" use case is already solved with zero
   engineering. See the paste-round-trip test under 2.2 for the
   automated regression coverage that protects this path.
2. **The `.rtf` file format is dead.** Word users want `.docx`. Pages
   users want `.pages` or PDF. RTF is an interchange format from
   before everyone settled on PDF + clipboard rich text. The audience
   for an `.rtf` file in 2026 is approximately zero.

The earlier draft conceded "RTF fidelity is mediocre — Word and Pages
render the result unevenly. Document the limitation rather than fight
it." That is the strongest possible tell. If the format is mediocre,
the use case is covered elsewhere, and the audience is hypothetical,
the answer is don't ship it.

**Verdict.** Drop from the backlog. If clipboard rich-text isn't
working in some target, fix the clipboard path (see 2.2) — it's
~1 day, not a perpetual export surface.

### 2.5 Localization — at least one Western European language

**Gap.** EN + RU only.

**Audience.** Half the global user base.

**What "done" looks like.**

- German + French as a starting pair (both have active Mac developer
  audiences, both are tractable to QA).
- All four `Localizable.xcstrings` files (Viewer, Server, GalleyCoreKit,
  GalleyServerKit) and the Quicklook `lproj` directories updated.
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
- Bookmarks panel in the existing TOC sidebar (alongside or below the
  heading list — `TOCSidebar.swift` already shipped).
- Persisted in `PerFileStateStore`.

**Cost.** ~1 week, mostly UX design.

### 3.3 OPML export

**Gap.** Marked 2 has it; useful for outlining tools and mind-mappers.

**Audience.** Tiny but loud — OmniOutliner / iThoughts users.

**Cost.** ~3 days. Convert the heading tree into OPML; the data structure
the TOC sidebar already builds is the source.

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
  BBEdit-pane-to-Galley-server pairing. The find bar and TOC sidebar are
  worth screen time too — they shipped after the original draft of this
  list and aren't reflected anywhere user-facing yet.
- A blog post on "BBEdit + Galley" for the BBEdit power-user audience.
- A blog post on "Pandoc previewing on macOS" for the academic audience.
- Listings on alternativeto.net, MacUpdate, Setapp (if it fits), and the
  Markdown-tooling roundups linked in `competitive-analysis.md`'s sources.

**Cost.** Each of these is a half-day to a day of writing/recording, plus
a few weeks of compounding inbound interest.

**Risk.** None. This is upside-only.

---

## Tier 4 — macOS 26 platform integration

These items are scoped to a macOS 26 deployment-target bump. They are not
new product features so much as taking advantage of system surfaces
(Spotlight, Shortcuts, Siri, widgets, Liquid Glass) that 26 either
introduces or substantially upgrades. They are listed here so the bump
is a planned event with a known payoff, not just a chore.

The hard constraint that shapes every item below: **Galley's URL routing
cannot be moved into the SwiftUI scene system.** `OpenURLRouter` returns
one of `.openNew`, `.tabOnto(WindowID)`, `.rebind(WindowID)`,
`.focusExisting(WindowID)` based on `OpenBehavior` and the live
`WindowRegistry`. SwiftUI's `WindowGroup<URL>.handlesExternalEvents(matching:)`
and scene-bound `OpenIntent` activation are both *scene-spawn primitives*
— they can only create new windows. They cannot call
`NSWindow.addTabbedWindow(_:ordered:)` against the current key window
(`.newTab`), they cannot rebind an existing window's URL via the
dispatcher's `[WindowID: rebind closure]` map (`.replaceCurrent`), and
they cannot detect a duplicate URL already open and focus it
(`.focusExisting`). The central `WindowDispatcher` stays load-bearing
for every intent or system-surface entry point. The intent body calls
`WindowDispatcher.handleOpenURLs(...)` directly, the same way
`WelcomeView.onOpenURL` does. The cost is losing automatic scene
activation; the benefit is preserving correct routing semantics.

The second constraint, separate from routing: **the `galley://` URL
scheme is load-bearing and intents cannot replace it.** The URL scheme
serves BBEdit's bundled helper script (a `do shell script "open
galley://..."` from the preview-template button), `open(1)` from
arbitrary shell scripts, AppleScript `open location`,
`NSWorkspace.open(_:)` handoffs from other apps, hyperlinks in
email/chat, cross-document `<a href="galley://...">` navigation inside
the rendered HTML, and the WebView's `x-galley://local` asset resolver.
None of those callers can invoke an App Intent directly — the closest
is `shortcuts run`, which requires the user to have pre-built a wrapping
Shortcut. So intents are strictly **additive**: they open new surfaces
(Shortcuts, Siri, Spotlight, Action Button) without taking work away
from the URL scheme. The bar for shipping an intent is therefore "does
this do something URLs can't, or expose a surface URLs don't reach?"
Anything that fails that test is duplication with a maintenance tax.

Useful framing for the rest of the tier: an App Intents surface is the
modern, Shortcuts-facing successor to an AppleScript scripting
dictionary. Same idea — declare a typed vocabulary of verbs (intents),
nouns (entities), parameters, and return values that external automation
can drive — different audience (Shortcuts users dragging boxes, not
script authors writing AppleScript), and different reach (Spotlight,
Siri, Action Button, widgets, focus filters, not just `osascript`). The
practical design pressure that follows: keep the action surface small
and user-meaningful, not a full object algebra over Galley's internals.
A thorough AppleScript dictionary would expose `documents`, `windows`,
`document.processor`, `set template of document 1 to ...`. An idiomatic
App Intents surface exposes a handful of named actions and stops.

### 4.1 App Intents — narrow scope: headless PDF export

Earlier drafts of this section listed five intents (Open, Switch
Processor, Switch Template, Export, Open in Editor). Four of those
duplicate the `galley://` URL scheme — same routing, same effect, plus
the cost of keeping a second entry path in sync with `WindowDispatcher`
and a second parameter surface in sync with `ProcessorStore` /
`TemplateStore`. After the URL-scheme analysis, only **headless PDF
export** survives the "does this do something URLs can't?" bar.

**Gap.** `open galley://...` always activates the app and produces a
visible document window. The print pipeline
(`DocumentModel+Print.swift`) is wired to SwiftUI window state. There
is no way today to ask Galley "render this Markdown file as a PDF and
write it to that path" without a window appearing. That's the one
capability an intent unlocks that URLs structurally cannot.

**Audience.** Anyone scripting batch PDF generation — academic / book
authors regenerating chapters, doc-pipeline users producing per-commit
PDFs, Shortcuts users wiring "export this Markdown as PDF" into a
larger automation.

**What "done" looks like.**

- `ExportAsPDFIntent(file: IntentFile, destination: IntentFile)` —
  Shortcuts-callable, runs in the background. Declared
  `supportedModes = [.background]` so the app does not yank forward
  when the intent fires.
- Output respects the active processor and template (read at intent
  time via the same `@Sendable` provider pattern the HTTP server
  uses), and honors the resolved page background color
  (`Template+BackgroundColor`) so the PDF matches what the Viewer
  would print.

**Where it lives.**

- New `Sources/GalleyCoreKit/Intents/` directory (intent + entity
  types).
- A standalone `PDFExportService` in `GalleyCoreKit` that takes a
  source URL + processor + template + destination and produces a PDF
  without any live `DocumentModel`. The existing
  `DocumentModel+Print.swift` becomes a thin caller of that service so
  Print / Page Setup / Export-as-PDF and the intent share one pipeline.
- The intent ships through `AppIntentsPackage` (see 4.3). The natural
  host is `Server` — it already runs headless and has the same
  `ProcessorStore` / `TemplateStore` references the intent body needs,
  with no SwiftUI scene lifecycle to negotiate. `Viewer` can also
  expose it if a "right-click → Export as PDF via Shortcuts" surface
  emerges, but the headless host is the priority.

**Cost.** ~1 week. The intent shell is a day; the bulk is extracting
the print pipeline into a SwiftUI-free service that can run from an
intent body. The current implementation reaches into window state in
subtle ways (offscreen `WKWebView` ownership, `alphaValue` gating, the
`runModal(for:delegate:didRun:contextInfo:)` dispatch quirk documented
in CLAUDE.md's "Print pipeline" note); service-ification has to
preserve all of that.

**Risks.** Print-pipeline factoring is the only real risk. The
offscreen-WebView behavior is finicky — `runOperation()` produces
blank pages, automatic pagination must be set explicitly, etc. — and
those invariants need test coverage before the refactor.

#### Considered and dropped

These intents appeared in earlier drafts and were removed after the
URL-scheme analysis. Each fails the "does this do something URLs
can't?" test:

- **`OpenMarkdownDocumentIntent(file:, line:)`.** Pure duplication of
  `galley://path?line=N`. Marginally nicer UX inside Shortcuts;
  identical routing, identical effect, plus the cost of a parallel
  entry path. If 4.2 (Spotlight recents) ships, a minimal version of
  this intent may need to come back purely as the `IndexedEntity`'s
  default-action bridge — but scoped to that role, not as a general
  Shortcuts entry point.
- **`SwitchProcessorIntent` / `SwitchTemplateIntent`.** Audience
  overlap between "Markdown previewer user" and "user who scripts
  processor switching" is vanishingly small. Easy to add later if a
  real ask surfaces; speculative to ship now.
- **`OpenInEditorIntent(file:, line:)`.** Editors already expose their
  own URL schemes (`x-bbedit://`, `vscode://`, `zed://`, etc.).
  Routing through Galley adds a hop without adding capability.
  Cmd-click in the rendered document already covers the in-app use
  case.

The shipping bar going forward: intents earn their place by reaching a
surface URLs don't reach (Spotlight, Siri, Action Button, widgets,
background execution), not by re-presenting URL capabilities in
Shortcuts.

### 4.2 Spotlight recents via `IndexedEntity`

**Gap.** Galley's recent documents live in
`NSDocumentController.shared.recentDocumentURLs` and surface only in
File → Open Recent and the Welcome view. They are not in Spotlight.
Users who know a document by name have to round-trip through Galley's
File menu to reopen it.

**Audience.** Anyone who keeps Spotlight open as their primary
launcher. Particularly valuable for users with hundreds of Markdown
files where remembering paths is hopeless.

**What "done" looks like.**

- `MarkdownDocumentEntity: IndexedEntity` with
  `@Property(indexingKey: \.displayRepresentation.title)` on the file
  name and `@Property(indexingKey: \.displayRepresentation.subtitle)`
  on the path. The system handles CoreSpotlight indexing without us
  writing any CSSearchableItem code.
- `RecentDocumentsModel.record(_:)` calls `CSSearchableIndex.donate(...)`
  via the App Intents helper after persisting the URL. Items are
  removed on `clearAll()`.
- Spotlight hits the entity and offers "Open in Galley" as its default
  action. 4.1 dropped the general-purpose `OpenMarkdownDocumentIntent`
  (URL-scheme duplication), so 4.2 has to ship a **minimal scoped
  version** — an intent whose only job is to be the entity's default
  action, calling `WindowDispatcher.handleOpenURLs([url], ...)` from
  the intent body. It is not advertised as a general Shortcuts entry
  point (the `galley://` URL scheme stays the documented path for
  scripting); it exists purely to bridge the Spotlight surface to the
  dispatcher. Budget ~1 extra day on top of the 4.2 estimate for this.

**Where it lives.**

- `Sources/GalleyCoreKit/Intents/MarkdownDocumentEntity.swift`.
- A thin extension on `RecentDocumentsModel` in the Viewer to call
  donate/withdraw.

**Cost.** ~3 days. The indexing pass and donate/withdraw wiring is ~2
days; the scoped open-intent bridge (see "What 'done' looks like"
above) is the ~1 extra day. Gated on 4.3 for cross-bundle intent
discovery, not on 4.1.

**Risks.** Spotlight indexes are user-facing — bad metadata is
visible. Test displacement (renamed file, deleted file) before
shipping. There is no PII risk: file paths the user has already
opened are already in their LaunchServices recents.

### 4.3 `AppIntentsPackage` for cross-bundle intent sharing

**Gap.** App Intents only scans the main bundle by default. The
ideal factoring puts the intent definitions in `GalleyCoreKit` (so
`Server`, `Viewer`, and potentially `Quicklook` all see the same
`OpenMarkdownDocumentIntent`), but the framework target's intents
won't be discovered without help.

**What "done" looks like.**

- Each app target declares
  `static let package: any AppIntentsPackage.Type = GalleyCoreKitIntents.self`
  in an `AppIntentsPackage` conformance.
- `GalleyCoreKit` exports the package type.

**Cost.** A few hours. Tied to 4.1 — there's no value in doing 4.3
without intents to share.

**Risks.** None substantive.

### 4.4 Liquid Glass audit on hand-rolled chrome

**Gap.** macOS 26's Liquid Glass material is automatic for stock
toolbars, sidebars, MenuBarExtra menus, and Settings panes. Anywhere
Galley has hand-rolled backgrounds or inline custom chrome, the rest
of the OS will adopt the new material visibly while Galley's
hand-rolled regions will look stranded.

**Audience.** Anyone running macOS 26. This is a "ship to keep
up" item, not a feature.

**What "done" looks like.**

- Audit `Sources/Viewer/Views/Actions.swift`,
  `Sources/Viewer/Views/FindBar.swift`,
  `Sources/Viewer/Views/StatusBar.swift` (the toolbar / find / status
  surfaces that have already been touched recently) for hand-rolled
  backgrounds. Convert to `.glassEffect()` / `.glassBackgroundEffect()`
  where the visual goal was "translucent over the document."
- `ServerStatusPill` in the Viewer + `MenuBarContent` in the Server —
  spot-check.
- Confirm `ToolbarSpacer` is used in place of stretchy `Spacer()`s in
  toolbar item groups (the new layout primitive).
- Confirm the bundled `DefaultTemplate.html` is untouched. Liquid
  Glass is AppKit-only; the WebView contents are web CSS and unrelated.

**Cost.** ~2 days. Mostly visual QA across the two app targets at
both light/dark + accent-color combinations.

**Risks.** Liquid Glass behaves differently with the user's
accessibility "Reduce Transparency" setting. Test both states.

### 4.5 Recent documents widget

**Gap.** macOS 26 puts widgets on the desktop with full Liquid Glass
rendering. A "Recent Galley Documents" widget is a one-click reopener
that lives outside the app.

**Audience.** Users who keep their desktop visible while working.
Smaller cohort than 4.1/4.2 because it requires a deliberate
configuration step, but the per-user value is high once configured.

**What "done" looks like.**

- New `Widget` target. `StaticConfiguration` with a
  `TimelineProvider` that reads `RecentDocumentsModel`'s persistent
  store at provider-refresh time (no live model access — widgets run
  out-of-process).
- Each row is a `Button(intent: OpenMarkdownDocumentIntent(file: …))`,
  so the widget's open action goes through the dispatcher (4.1).
- Three sizes: `.systemSmall` (top-1 recent), `.systemMedium` (top-3
  recents with paths), `.systemLarge` (top-7 recents).
- No `WidgetPushHandler`, no `RelevanceKit`. Recency is already the
  ordering; nothing to learn.

**Where it lives.**

- New `Sources/RecentsWidget/` target.
- Shares `RecentDocumentsModel`'s on-disk format with the Viewer via
  an App Group container (new entitlement on both targets).

**Cost.** ~3 days, gated on 4.1 (widget action requires the intent).

**Risks.** App Group entitlement is the only non-trivial bit — it
changes the sandbox profile of both the Viewer and the new widget.
Viewer is currently unsandboxed (see CLAUDE.md); the widget target
must be sandboxed (extension requirement), so the shared store has
to live somewhere readable from a sandboxed peer.

### 4.6 Foundation Models for on-device summarization

**Gap.** Galley renders documents; it doesn't help users understand
them. The `FoundationModels` framework gives Swift access to the
on-device LLM (Apple Silicon only) with guided generation and tool
calling — the natural fit is "summarize this", "generate a TOC",
"rewrite this section in plain language."

**Audience.** Speculative. Probably valuable to academic / long-doc
users; probably noise to short-doc users.

**What "done" looks like.**

- `SummarizeMarkdownIntent(file: IntentFile, length: SummaryLength)`
  — Shortcuts-callable, runs on-device. Streamed output rendered into
  a `SnippetIntent` for live preview.
- A right-click menu entry inside the rendered WebView ("Summarize
  selection", "Explain selection") that talks to the same intent
  with `selection` as the input.
- No model fallback. If the device can't run the model
  (`SystemLanguageModel.default.availability != .available`), the
  intent throws a typed error and the menu items are hidden.

**Where it lives.**

- `Sources/GalleyCoreKit/Intelligence/SummarizationService.swift`.
- Right-click menu plumbing via a new `EditorBridge`-style
  `WKScriptMessageHandler` for selection events.

**Cost.** ~1 week for the basic intent, plus an open-ended amount of
prompt-tuning time. Reasonable as a "let's try it" item; not worth
prioritizing over 4.1.

**Risks.** Apple Silicon only — Intel Macs see the menu items
hidden. Output quality is variable on long documents; budget time to
decide the chunking strategy or accept that very long docs are
out-of-scope. Privacy story is clean (on-device), which is the main
reason to use it over a hosted model.

### Explicitly out of scope

- **`WindowGroup<URL>.handlesExternalEvents(matching:)` / scene-bound
  `OpenIntent` for routing.** See the constraint at the top of this
  tier. Intent bodies call into `WindowDispatcher` directly.
- **`WidgetPushHandler` / `RelevanceKit`.** Galley has no
  server-pushed state and no relevance signal beyond recency.
- **Quick Look API changes.** macOS 26 ships no developer-visible
  changes to `QLPreviewingController`. Galley's server-first
  fallback-to-in-process pattern is still correct.
- **WebPage public API growth.** macOS 26 did not add
  `printOperation` or `findInPage` to the SwiftUI `WebPage` type.
  The offscreen-`WKWebView` print pipeline in
  `DocumentModel+Print.swift` is still required. Watch the WebKit
  release notes — when these land, that pipeline can be deleted.
- **Finder Actions / Services menu.** No 2025-specific surface
  changes. App Intents (4.1) covers the same need with better UX.

---

## Sequencing recommendation

If I had four engineering weeks to spend now:

1. **Week 1.** Tier 1.4 (word count / reading time HUD — fastest visible
   win still on the list) + the paste-round-trip test under 2.2 (~1 day;
   automates regression coverage for the rich-text clipboard path that
   replaces the old HTML/RTF export plans).
2. **Weeks 2–3.** Tier 1.5 (notarized DMG pipeline) properly resourced.
   The original ~1 week estimate is optimistic given Apple Developer
   enrollment friction and first-build notarization debugging. Two
   weeks here buys a durable trust improvement and unblocks Homebrew
   distribution. The Marked-2-parity export work that used to live in
   these slots (2.2 + 2.4) was demoted after audience analysis — see
   those sections.
3. **Week 4.** Tier 1.1 follow-up (manuscript + Tufte themes) and Tier 3.5
   (marketing) — both unlock audience growth without heavy engineering.

After that, Tier 2.3 (multi-file / book mode) is the next-best individual
item if there's signal that the academic / book-author audience matters,
and Tier 2.5 (DE/FR localization) is the lever that opens the Western
European market.

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
