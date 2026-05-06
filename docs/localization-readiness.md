# Localization readiness

**Status:** English-only. No String Catalog, no `.lproj`, no `InfoPlist.strings`.
`developmentRegion = en`, `knownRegions = (en, Base)`.

## Strategy

Lean on SwiftUI's built-in localization wherever possible. The app already
benefits from it without anyone noticing: `Text("…")`, `Button("…")`,
`Label("…", …)`, `Toggle("…", isOn:)`, `Menu("…")`, `Picker("…", …)`,
`TextField("…", text:)`, `.help("…")`, `.navigationTitle("…")` all take
their first string literal as `LocalizedStringKey` and look it up in the
strings table. So the bulk of the UI is already *latent* — adding a
String Catalog would localize it automatically.

The real gaps are everywhere we step outside SwiftUI's literal-driven
APIs:

1. **AppKit modal UI** (`NSAlert`, `NSOpenPanel`, `NSSavePanel`) takes
   plain `String` and bypasses the strings table. **Fix by porting to
   SwiftUI** (`.alert`, `.confirmationDialog`, `.fileImporter`,
   `.fileExporter` with the `fileDialog*` modifier family — all
   available on macOS 14+).
2. **Dynamic display strings** (`enum displayName: String`,
   `EditorChoice.Element.name`, `ChoiceValueProtocol.name`) return
   `String`, so call sites like `Text(value.name)` hit the verbatim
   `Text(_ String)` overload. **Fix by returning `LocalizedStringResource`
   or wrapping at the call site.**
3. **String-typed APIs** (`accessibilityLabel(_ String)`,
   `UNNotificationContent.title/body`, server HTTP error page strings).
   **Fix by routing through `String(localized:)`** at the boundary.
4. **`Info.plist`** (`UTTypeDescription`). **Fix by adding
   `InfoPlist.strings`.**

After the gaps are closed, add `Localizable.xcstrings` per target and
let Xcode auto-extract.

---

## TODO

### A. AppKit dialogs → SwiftUI

These are the largest cluster and the ones most worth modernizing for
their own sake.

#### A.1 — File ▸ Open (Viewer) — **deferred: no localization win**

[`RecentDocumentsModel.runOpenPanel`][rdm] /
`presentOpenPanel` use `NSOpenPanel` with only system-default
chrome — no `title`, no `prompt`, no `message`. The OS supplies the
localized "Open" / "Cancel" / sidebar labels for free, so converting
to `.fileImporter` is pure code-style cleanup with zero string-table
impact. Defer until there's another reason to touch this code (e.g.
the multi-scene `.fileImporter` host design — Welcome and every
DocumentView would need to coordinate so only one picker presents
per invocation).

#### A.2 — File ▸ Export as PDF (Viewer) — **decided: keep NSSavePanel**

`.fileExporter` is data-first; our pipeline is destination-first
(`runPrintOperation` writes paginated bytes directly to a
`jobSavingURL`, no `Data` payload to hand SwiftUI). Fitting
`.fileExporter` would mean rendering to a tmp file inside an async
`Transferable.DataRepresentation`, reading the bytes back, handing
`Data` to SwiftUI to write to the destination — double disk I/O for
no real benefit. Keep `NSSavePanel`, but route every visible string
through `String(localized:)` so it lands in the catalog.

- [x] [`performExportPDF`](../Sources/Viewer/Views/DocumentView.swift) —
  panel title routed through `String(localized: "Export as PDF")`.
- [x] B.2 (failure alert) — see below.

#### A.3 — Settings ▸ Markdown ▸ "Choose Application…" (EditorChoice)

- [x] [`MarkdownSettingsView`](../Sources/Viewer/Views/Settings/MarkdownSettingsView.swift)
  drives a single `.fileImporter` via `@State showAppPicker`. Both
  the menu row "Other Application…" and the detail "Choose
  Application…" button flip the same flag.
  [`EditorChoice`](../Sources/Viewer/Models/EditorChoice.swift)
  is now pure data — no more `pickAppBundle` injection, no
  `defaultPickAppBundle()` static, no NSOpenPanel.

#### A.4 — Settings ▸ Markdown ▸ "Install scripts…" (BBEdit)

- [x] `.fileImporter(allowedContentTypes: [.folder])` +
  `.fileDialogConfirmationLabel("Install")` +
  `.fileDialogMessage("Choose the destination folder…")` +
  `.fileDialogDefaultDirectory(...)` on the "Install scripts…" button.
  [`ScriptInstaller`](../Sources/GalleyCoreKit/Utilities/ScriptInstaller.swift)
  no longer runs UI — it just exposes the data function
  `install(to:context:)` plus the helper `nearestExistingDirectory(for:)`
  the view uses to seed the dialog.

#### A.5 — Server menu bar ▸ "Open File…" — **deferred: no localization win**

Same shape as A.1: [`MenuBarContent.openFile`][mbc] presents an
`NSOpenPanel` with system-default chrome only. No localizable
strings to recover. Defer until there's a code-style reason to
revisit; presentation from `MenuBarExtra` will need verification at
that point.

[rdm]: ../Sources/Viewer/Models/RecentDocumentsModel.swift
[mbc]: ../Sources/Server/Menu/MenuBarContent.swift

### B. AppKit alerts → SwiftUI

- [x] **B.1 — Rename document alert.** SwiftUI
  `.alert("Rename Document", isPresented:)` on `DocumentView` with an
  inline `TextField` and `Button("Rename")` / `Button("Cancel",
  role: .cancel)`. Menu fires through a focused
  [`RenameContext.request`](../Sources/Viewer/Views/FocusedValues.swift)
  closure; window owns the input state and the post-rename
  recents/`fileURL` updates.
- [x] **B.2 — "Couldn't export PDF" alert.** SwiftUI
  `.alert(... presenting: exportPDFError)` on `DocumentView`, set by
  `performExportPDF` on failure.
- [x] **B.3 — "Could not install scripts" alert.** SwiftUI
  `.alert(... presenting: scriptInstallError)` on
  `MarkdownSettingsView`, set by `handlePickedScriptDestination`.

### C. Enum display strings

Domain types now follow Apple's recommended pattern (see
[`LocalizedStringResource`](https://developer.apple.com/documentation/foundation/localizedstringresource)
and [`CustomLocalizedStringResourceConvertible`](https://developer.apple.com/documentation/foundation/customlocalizedstringresourceconvertible)):
expose `LocalizedStringResource`, let the consumer resolve via
`Text(_:)` (SwiftUI) or `String(localized:)` (everywhere else). No
SwiftUI in the kit's domain or routing layer.

The mixed translatable / data cases are handled by combining two
inits of `LocalizedStringResource`:
- Literal `LocalizedStringResource("Default")` — extracted by Xcode
  into the strings catalog.
- Runtime
  `LocalizedStringResource(String.LocalizationValue("\(name)"))` —
  *not* extracted, falls back to the runtime value at lookup, so
  filenames and brand names don't pollute the translator's table.

- [x] **C.1 —
  [`OpenBehavior.displayName`](../Sources/GalleyCoreKit/Routing/OpenBehavior.swift)**
  → `LocalizedStringResource`. `import SwiftUI` removed from routing.
- [x] **C.2 — `EditorPreset.displayName`** stays `String` (brand
  names, used internally to construct the runtime
  `LocalizationValue` wrapper).
- [x] **C.3 —
  [`EditorChoice.Element.name`](../Sources/Viewer/Models/EditorChoice.swift)**
  → `LocalizedStringResource`. Mix of literal and runtime inits per
  case.
- [x] **C.4 —
  [`ChoiceValue.name`](../Sources/GalleyCoreKit/Models/ChoiceModel.swift)
  / `TemplateProtocol.name`** → `LocalizedStringResource`.
  `BuiltInTemplate.name = "Default"` (literal),
  `UserTemplate.name = LocalizedStringResource(LocalizationValue("\(nameString)"))`
  (runtime), `TemplateChoiceValue.name` forwards to the inner
  `Template.name` so the literal "Default" doesn't get re-wrapped as
  runtime.
  [`SceneChoiceValueEnvelope.name`](../Sources/GalleyCoreKit/Models/ChoiceModel.swift)
  for `.global(…)` builds `LocalizedStringResource("Global (\(inner))")`
  with the inner display resolved upfront, so the catalog gets a
  single `"Global (%@)"` key.
  Logging / displacement sites resolve via `String(localized:)` at
  the boundary.

### D. String-typed APIs

- [x] **D.1 — `ServerStatusPill.labelText`** — `label: String`
  replaced with `labelText: Text`, all six cases now go through
  `LocalizedStringKey` (the `.running` case interpolates the port
  number into the localized format).
- [x] **D.2 — accessibility label** — `Text("Server status: \(labelText)")`
  composes the prefix with the per-case `Text` via SwiftUI's
  `LocalizedStringKey` interpolation (the `Text + Text` form is
  deprecated on macOS 26).

### E. User notifications

- [x] **E.1 —
  [`DisplacementNotifier`](../Sources/GalleyCoreKit/Utilities/DisplacementNotifier.swift)**.
  `UNMutableNotificationContent.title` / `.body` resolve through
  `String(localized:)` inside `_post`. Body interpolation produces a
  single `"%@ is no longer available — switched to the default."`
  catalog key with the displaced name as the runtime substitution.
- [x] **E.2 — `Kind.title: LocalizedStringResource`.** Cases are
  identifier-only; the `title` accessor returns the full per-case
  resource ("Markdown processor unavailable", "Template
  unavailable") so translators can re-arrange word order. The
  notifier holds the `String(localized:)` boundary internally for
  symmetry with the rest of the kit.

### F. HTTP error pages (server → browser)

The server binds to 127.0.0.1 only (see
[`ServerSettingsView`](../Sources/Viewer/Views/Settings/ServerSettingsView.swift)
and `PreviewServer.swift`), so the user viewing pages in the browser
*is* the server owner — process locale is the right locale, no
`Accept-Language` parsing needed.

- [x] **F.1** — Every user-visible string in
  [`Routes.swift`](../Sources/GalleyServerKit/Routes.swift) and
  [`PreviewServer.swift`](../Sources/GalleyServerKit/PreviewServer.swift)
  now wraps through `String(localized:)`. Covers the error-page
  titles ("No markdown processor configured", "Render error",
  "Template error"), all `notFound` / `badRequest` / `forbidden`
  responses, the asset / event / template-asset paths, and the three
  server-lifecycle failure messages ("Cannot resolve url:", "Cannot
  create loopback address:").

### G. Info.plist

- [x] **G.1 — `UTTypeDescription`** in
  [`Sources/Viewer/Resources/en.lproj/InfoPlist.strings`](../Sources/Viewer/Resources/en.lproj/InfoPlist.strings).
  Keyed by the UTI (`"net.daringfireball.markdown" = "Markdown Document";`).
  Auto-included via `PBXFileSystemSynchronizedRootGroup` — no
  project-file edits needed.
- [x] **G.2 — Quicklook appex** has
  `INFOPLIST_KEY_CFBundleDisplayName = Quicklook` (user-visible in
  System Settings ▸ Privacy & Security ▸ Quick Look). Localized via
  [`Sources/Quicklook/en.lproj/InfoPlist.strings`](../Sources/Quicklook/en.lproj/InfoPlist.strings).
- [x] **G.3 — Server** has no user-visible Info.plist strings
  apart from `NSHumanReadableCopyright`. The Server uses
  `GENERATE_INFOPLIST_FILE = YES` with no `.lproj`, so the
  copyright is supplied by the build setting only. If the
  Server ever needs to localize anything else, add an
  `InfoPlist.strings` and override `NSHumanReadableCopyright`
  there too.
- [x] **G.4 — `NSHumanReadableCopyright`** is set on every
  shipping target (`Viewer`, `Server`, `Quicklook`,
  `GalleyCoreKit`, `GalleyServerKit`) via
  `INFOPLIST_KEY_NSHumanReadableCopyright`. Viewer and
  Quicklook also expose it as a localizable key in their
  `en.lproj/InfoPlist.strings` so translators can override
  the wording per locale.

### H. String Catalog (when ready to translate)

- [x] **H.1** — Empty `Localizable.xcstrings` added to each of the
  four shipping targets:
  [Viewer](../Sources/Viewer/Localizable.xcstrings),
  [Server](../Sources/Server/Localizable.xcstrings),
  [GalleyCoreKit](../Sources/GalleyCoreKit/Localizable.xcstrings),
  [GalleyServerKit](../Sources/GalleyServerKit/Localizable.xcstrings).
  Auto-included via `PBXFileSystemSynchronizedRootGroup`; the build
  runs `xcstringstool compile` + `GenerateStringSymbols` on each.
- [ ] **H.2** — Open the project in Xcode and build once. The IDE
  merges the `.stringsdata` emitted by `SWIFT_EMIT_LOC_STRINGS = YES`
  into each catalog. Sanity-check the catalogs don't pick up data
  strings (filenames, brand names, template / processor names from
  disk). Confirm that interpolated keys land as `%@`-style
  placeholders (e.g. `"Global (%@)"`,
  `"%@ is no longer available — switched to the default."`).
- [ ] **H.3** — Pseudo-localize (e.g. add `en-XA`) to surface
  truncation and missing-key bugs in layout.

---

## Out of scope / deliberate non-goals

- **Right-to-left review.** Defer until at least one RTL language is
  on the roadmap. Most of the UI uses `.leading` / `.trailing` so it
  should be reasonably mirror-friendly already.
- **Locale-aware date / number / port formatting.** Nothing currently
  formats numbers or dates for end users (template placeholders
  `#DATE#` / `#TIME#` go through user-controlled templates and aren't
  app chrome).
- **Plurals.** No counts surface in the UI — "Open Recent" is a list
  of filenames, "Listening on …" embeds a port number, neither needs
  pluralization.

## Already done

Code-side preparation is complete. Sections A–F all have boxes
checked except A.1 / A.5 (deferred — no localization win) and G
(deferred to H). Adding `Localizable.xcstrings` (H) is the next
shippable step.

Quick summary of the prep pass:

- [x] Cyrillic `Е` → Latin `E` typo fix.
- [x] `Text("a" + "b" + "c")` collapsed to single multi-line literals
  in `MarkdownSettingsView` and `ServerSettingsView`.
- [x] **A.2 / A.3 / A.4** — picker conversions. Editor and BBEdit
  scripts use SwiftUI `.fileImporter`; Export-as-PDF stays
  `NSSavePanel` with `String(localized:)` title.
- [x] **B.1 / B.2 / B.3** — all three `NSAlert`s ported to SwiftUI
  `.alert`.
- [x] **C.1 / C.3 / C.4** — `displayText: Text` accessors added
  alongside `name: String` so SwiftUI display call sites stop hitting
  the verbatim overload.
- [x] **D.1 / D.2** — `ServerStatusPill` cases return `Text` directly;
  accessibility label uses `LocalizedStringKey` interpolation.
- [x] **E.1 / E.2** — `DisplacementNotifier` resolves through
  `String(localized:)`; `Kind` no longer carries UI text in its raw
  value.
- [x] **F.1** — every user-visible HTTP error string in
  `GalleyServerKit` resolves through `String(localized:)`.
