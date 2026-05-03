# Handoff — `refactor/galleykit` branch

Status as of end-of-session 2026-04-28. Branch builds clean (Server + Viewer + Kit). 28 commits ahead of `main`, none pushed.

## What this branch did

### Phase 1 — Kit extraction (commits `9947686` → `6d2a13f` + `da374a3`)

Pulled the rendering / template / watch / HTTP-server code out of the menu-bar `Server` target and into a **local Swift package** at `Kit/`, with two products:

- **`GalleyCoreKit`** — markdown rendering, templates, file watching, helper utilities. Deps: `swift-markdown`, `swift-core-kit` (`ALFoundation`). No FlyingFox.
- **`GalleyServerKit`** — HTTP plumbing (PreviewServerController, Routes, SSE, HTTPResponses, MIMETypes, ErrorPage.html). Deps: `GalleyCoreKit` + `FlyingFox`.

Target deps:
- **Server** target → both products (gets HTTP layer + everything underneath).
- **Viewer** target → only `GalleyCoreKit` (no FlyingFox in the bundle).

`Kit/Package.swift` declares the two products with their resource bundles. `swift build` and `swift test` work in `Kit/` for the fast TDD loop. Xcode integration is via a single `XCLocalSwiftPackageReference "Kit"` entry in `MarkdownPreviewer.xcodeproj/project.pbxproj`.

`AppModel` was *not* split — once the engine pieces moved to Kit, what's left in `AppModel` is genuinely the Server app's `@Observable` config layer (UserDefaults persistence + UI binding wires).

Side cleanup: dropped the unused `ALCombine` product dependency (`da374a3`).

### Phase 2 — Editor coupling Phase 1 (commits `9e34624`, `fa74dc4`, `1012181`)

`SwiftMarkdownRenderer` gained an `annotatesSourceLines: Bool` option. When on, every block element gets `data-source-line="N"` pointing back at the originating line in markdown source. Tests in `Kit/Tests/GalleyCoreKitTests/SwiftMarkdownRendererTests.swift`.

In the Viewer target:
- **`ViewerModel`** — `@Observable @MainActor` owner of a `WebPage`, the renderer/template via shared `ViewerSettings`, a `DocumentWatcher`, and the bridge classes.
- **`EditorBridge`** — `WKScriptMessageHandler` named `editor`. Cmd-click on any element with a `data-source-line` ancestor opens the source in BBEdit at that line via `x-bbedit://open?url=…&line=…` (with `txmt://` fallback).
- **`ContentView`** uses the SwiftUI `WebView(WebPage)` (macOS 26+).

### Phase 3 — Cross-document navigation (commits `9240107` → `75a3b4e`)

- **`LinkBridge`** — `WKScriptMessageHandler` named `linkclick`. Resolves `<a href>` clicks: `.md` family → in-window navigation; external → default browser; other local → `NSWorkspace`.
- `ViewerModel` history with `bind(to:)`, `navigate(to:)`, `goBack`, `goForward`, `reload`, plus a `bindGeneration` counter to cancel stale watcher loops.
- **`NavigationCommands`** — Back/Forward/Reload menu items with ⌘[ ⌘] ⌘R.
- Toolbar buttons in `ContentView` (back/forward in `.navigation`, reload in `.primaryAction`).
- **`34545a7`** — sandbox disabled on the Viewer to match the Server target. Sandbox was blocking sibling-document opens via every API we tried. The value was low for a developer tool ⇒ dropped.
- **`aad9e80`** — switched `.md` link opens from `NSWorkspace.open` to `NSDocumentController.openDocument` so the user stays inside our app instead of being routed to BBEdit.

### Phase 4 — Window plumbing & WindowGroup switch (commits `485cffb` → `aa0aa21`)

The big architectural shift since the previous handoff: replaced `DocumentGroup(viewing:)` with `WindowGroup(for: URL.self)` and built out the surrounding plumbing.

- **`485cffb`** — `WindowGroup(for: URL.self)` driving `ContentView(fileURL:)`. `ViewerDocument` deleted. Permanently removed AppKit's hover dropdown / rename popover problem that DocumentGroup was forcing on us.
- **`ViewerAppDelegate`** — `NSApplicationDelegateAdaptor`-bridged delegate that:
  - Buffers `application(_:open:)` URLs until SwiftUI installs an `openWindow` handler, then flushes.
  - Tracks `NSDocumentController.shared.recentDocumentURLs` so File > Open Recent has something to bind to (commit `eca8334`).
  - Owns `runOpenPanel()` / `presentOpenPanel()` for ⌘O.
  - `applicationShouldTerminateAfterLastWindowClosed` returns `false` — the user can keep relaunching files from File > Open with no windows up.
- **`24e509b`** — on launch with no documents queued, show the open panel directly instead of a placeholder welcome window. If the user picks a file, it loads into the placeholder window; cancel quits.
- **`aa0aa21`** — FTUE: hide the placeholder window via `dismissWindow` until a real document binds. Keeps the hack surface minimal.
- **`2379c1f`** — back/forward stack persisted via `@SceneStorage` (`HistorySnapshot` Codable). Each window restores to where the user left off.
- **`739c5f2`** — `PreviewSchemeHandler` (`WKURLSchemeHandler`) registers a custom scheme so template-bundled assets (CSS, fonts, images) resolve from disk through the WebView. Replaces `baseURL = about:blank`. The handler reads the active template via a `TemplateBox` reference so global template switches take effect on next render.
- **`8629431` / `1c327e3`** — File > Rename… with an `NSAlert` accessory text field. Renames on disk via `FileManager.moveItem`, rewrites matching history entries, rebinds the watcher. Surfaced through the menu, not a title-bar binding (the macOS 26 title popover route was unreliable).
- **`8c823b0`** — guard against unreachable link targets in `navigate / goBack / goForward`. Sets `lastError`, beeps, leaves history untouched so a broken click doesn't strand the window.
- **`fc26189`** — single user-script handles cmd-click and plain-click in one listener. Two separate listeners caused the editor handler to drop after the first in-window navigation in macOS 26 WebPage — the unified script side-steps the ordering issue.
- **`04c2b68`** — centralized `/template` and `/preview` route parsing (Server-side cleanup that landed on this branch).

### Phase 5 — Renderer & template pickers in Viewer (`ViewerSettings`, `RenderingCommands`)

- **`ViewerSettings`** — `@Observable @MainActor` shared across all viewer windows. Owns `MarkdownRendererCatalog` discovery, persisted `selectedRendererID`, and the `TemplateStore`. Mirrors the Server's `AppModel` shape (deliberate — same UX semantics, separate UserDefaults keys).
- **`RenderingCommands`** — Format menu with "Markdown Processor" and "Template" submenus. Toggles bound to `ViewerSettings.rendererBinding(_:)` / `templateBinding(_:)`.
- **Toolbar pickers** — `RendererToolbarPicker` and `TemplateToolbarPicker` in `ContentView`'s `.primaryAction` toolbar group, so users can switch without opening the menu.
- Switching renderer or template re-renders every open window because each `ViewerModel.renderCurrent()` reads `settings?.activeRenderer` / `activeTemplate` at render time.

### Phase 6 — Configurable editor (commits `e69613b`)

- **`EditorChoice`** — Codable enum with three cases:
  - `.preset(EditorPreset)` for the five built-in URL-scheme editors: BBEdit (`x-bbedit://`), TextMate (`txmt://`), VS Code (`vscode://file{path}:{line}`), Sublime Text (`subl://`), Zed (`zed://file{path}:{line}`).
  - `.customURL(template: String)` — user-typed template with `{url}`/`{path}`/`{line}` placeholders, percent-encoded for URL-query position.
  - `.appBundle(URL)` — fallback for editors with no URL scheme. Routes through `NSWorkspace.open(_:withApplicationAt:configuration:)`. Line is silently dropped (no portable way to pass it).
- **`EditorSettingsView`** — single popup picker listing every preset + "Custom URL scheme…" + "Other application…", with conditional secondary fields (URL template TextField / app-bundle Choose… button) under the picker. Hosted in a SwiftUI `Settings { … }` scene → standard "Markdown Eye > Settings…" menu item with ⌘,.
- **`EditorBridge`** is now closure-based (`onEditorClick`); the actual open call lives in `ViewerModel.openInEditor(line:)` so every cmd-click reads the current `EditorChoice` from `ViewerSettings`.
- **File > Open in Editor** (⌘E) — same code path as cmd-click but with `line=nil`, so the editor opens the current document at the top with no specific line.

### Phase 7 — Window state-restoration & visibility (commit `65ba9e6`)

Three converging launch bugs were chasing each other:

1. **Bind-clobber after restore** — SwiftUI fires `.task(id: fileURL)` more than once for the same id (the modifier is recreated on body re-eval). The second fire's `bind(to: fileURL)` was clobbering an already-restored back/forward stack and overwriting the saved `@SceneStorage` snapshot on disk. Every relaunch from then on lost the back-stack permanently.
2. **Empty-window flash for restored windows** — restored windows briefly mount with `fileURL=nil` because SwiftUI applies the persisted `WindowGroup` value ~half a second after a view appears. The placeholder logic ran a launch picker for every restored window in transit.
3. **Hidden-content** — a 500 ms-sleep workaround flashed an empty window before the FTUE panel and could leave restored windows hidden if the bail path didn't restore `alphaValue=1`.

Replaced with a deterministic visibility model:

- Every window opens with `alphaValue = 0` in `WindowAccessor`. The accessor consults `model.documentURL` at resolve time so a window opened via `openWindow(value:)` (Open Recent, multi-pick) — where the bind already ran before the NSView attached — reveals immediately.
- The window is unhidden when `model.documentURL` first goes non-nil, via `.onChange`. That covers initial bind, restore, and in-window navigation through one path.
- The placeholder window stays hidden through the FTUE picker; cancel dismisses it without ever showing.
- The FTUE picker is gated on `appDelegate.didFinishLaunching` (set in `applicationDidFinishLaunching`) instead of a fixed timeout — by that point state restoration is complete, so a still-empty placeholder is genuinely empty rather than a restored window in transit.
- An early `if model.documentURL != nil { return }` at the top of `launchTask` makes re-fires no-ops, defending against the bind-clobber regardless of timing.

## Current state

### Working

- Native viewer renders markdown via GalleyCoreKit, displayed in `WebView(WebPage)`.
- `DocumentWatcher` reloads on file change (Kit-side, shared with the Server).
- **Cmd-click** any block in the rendered preview → BBEdit opens at the source line.
- **Click** an `.md` link → navigates the same window to that document; broken links beep + surface error.
- **Click** an external link → default browser. Other local files → `NSWorkspace`.
- **Back / Forward / Reload** as toolbar buttons, View-menu items, and ⌘[ ⌘] ⌘R shortcuts.
- **File > Open** (⌘O), **Open Recent** with Clear, **Rename…**, **Open in Editor** (⌘E).
- **Finder double-click** opens in our viewer (Info.plist registers `net.daringfireball.markdown`).
- **Per-window state restoration** — back/forward stack survives quit/relaunch. Multi-window restoration is reliable; windows stay hidden until content is bound, so no empty-window flash.
- **Template assets** (CSS, fonts, images bundled with the template) load through the custom URL scheme handler.
- **Renderer & template switching** via the Format menu and toolbar pickers — global, applies to all open windows.
- **Configurable editor target** — five presets + custom URL template + arbitrary `.app` fallback. Cmd-click and ⌘E both honor the current selection.
- Window title text follows navigation. No hover dropdown, no rename popover, no proxy icon.
- Native macOS window tabbing via system "Prefer Tabs" setting.

### Open

None of the original blockers remain. The DocumentGroup → WindowGroup switch closed the title-bar dropdown chapter; logging is already at `.debug` in `ViewerModel` / bridges; phantom Xcode artefacts have been groomed.

## Repository layout (current)

```
MarkdownPreviewer/
├── Kit/                                # local Swift package (unchanged shape)
│   ├── Package.swift
│   ├── Sources/
│   │   ├── GalleyCoreKit/              # Render, Templates, Watch, Utilities, Routes, MarkdownFileTypes
│   │   └── GalleyServerKit/            # FlyingFox plumbing
│   └── Tests/
├── Sources/
│   ├── Server/                         # menu-bar app (unchanged from main except imports)
│   └── Viewer/
│       ├── ViewerApp.swift             # @main, WindowGroup + Settings scene, File/Format commands
│       ├── ViewerAppDelegate.swift     # URL routing, Open Recent, open panel, didFinishLaunching
│       ├── ViewerModel.swift           # bind/navigate/back/forward/reload/rename/restore/openInEditor
│       ├── ViewerSettings.swift        # renderer catalog + template store + EditorChoice persistence
│       ├── EditorBridge.swift          # cmd-click → onEditorClick closure (unified user script)
│       ├── EditorChoice.swift          # presets / custom URL / app-bundle + opener helper
│       ├── LinkBridge.swift            # link click → navigate or external open
│       ├── PreviewSchemeHandler.swift  # WKURLSchemeHandler for template assets
│       ├── Views/
│       │   ├── ContentView.swift       # WebView + toolbar + state restoration + visibility
│       │   ├── EditorSettingsView.swift # popup-picker Settings tab for EditorChoice
│       │   ├── NavigationCommands.swift
│       │   ├── RenderingCommands.swift # Format menu (renderer + template)
│       │   └── AssortedViews.swift     # ProcessorMenu / TemplateMenu helpers
│       └── Resources/
│           ├── Info.plist              # markdown UTI registration
│           └── Assets.xcassets
└── Tests/
```

## Open decisions

1. **Per-window vs shared history** — settled per-window. Two windows on the same `.md` have independent histories. Persisted per scene via `@SceneStorage`.
2. **AppModel split** — left intentionally undone. Server `AppModel` and Viewer `ViewerSettings` share a shape but don't share an instance (different UserDefaults keys, different lifecycles).
3. **Toolbar pickers vs menus for renderer/template** — menus only, for now. Add toolbar pickers if the menu round-trip turns out to be friction.

## Remaining tasks (priority-ordered)

### 1. Restore scroll position across watcher reloads

When `DocumentWatcher` fires and we re-render, the WebView snaps to top. Snapshot `window.scrollY` (or the topmost visible `[data-source-line]`) before reload, restore after. Significantly nicer when editing.

### 2. Quick Look provider

Finder spacebar uses our renderer via a Quick Look extension target. Nice-to-have.

### 3. Per-document overrides

Right now renderer/template selection is global. If users want to pin a specific template to a specific document, add a `@SceneStorage` per-window override that wins over `ViewerSettings.activeTemplate` when set.

### 4. Outline / TOC sidebar

Generate from heading structure (swift-markdown gives a clean AST), render in a SwiftUI sidebar, click-to-scroll via `webView.callJavaScript("…scrollIntoView()")`. Toggle via View menu + a toolbar button.

## Useful pointers

- Branch: `refactor/galleykit`. 30 commits ahead of `main`, none pushed. Don't push without code review — big surface area.
- Smoke-test markdown bundle at `/tmp/galley-link-test/{index,chapter-1,chapter-2}.md`.
- Single-file smoke test at `/tmp/galley-smoke.md`.
- WebPage: iterate `for try await _ in page.load(html:baseURL:) {}` to actually drive the load — discarding the AsyncSequence is a no-op (bit us in early debug, see `fa74dc4`).
- Sandbox is OFF on the Viewer (matches Server). Don't re-enable without thinking through cross-doc navigation, file-rename, and the open panel paths.
- BBEdit registers `x-bbedit://`, `txmt://`, `editor://`, `x-bbedit-license://` — bare `bbedit://` is NOT registered.
- FTUE / state-restoration debugging: launch with `-ApplePersistenceIgnoreState YES` to skip the system's saved-state restore. `~/Library/Saved Application State/<bundle-id>.savedState/` is where macOS keeps it.
- `PreviewSchemeHandler.originURL` is the synthetic base URL every render uses; relative asset paths are rewritten to `<scheme>://template/<id>/…` by `Template.rewriteAssets(in:origin:)`.

## Commits in chronological order

```
da374a3 Remove unused ALCombine product dependency
9947686 Add empty GalleyKit local Swift package
a7154a5 Split Kit into GalleyCoreKit + GalleyServerKit, move Render/ to Core
4eec60e Move Templates/, Utilities/, Watch/ into GalleyCoreKit
14564f3 Move HTTP plumbing into GalleyServerKit
6d2a13f Update tests to import from GalleyCoreKit
9e34624 Editor coupling Phase 1: native viewer with cmd-click → BBEdit
fa74dc4 Fix blank Viewer windows: add network.client entitlement
1012181 Use x-bbedit:// instead of bbedit:// (with txmt:// fallback)
9240107 Add LinkBridge for cross-document navigation
34545a7 Disable sandbox on the Viewer; match Server target
aad9e80 Open .md links via NSDocumentController, not LaunchServices
2abe09d Browser-style in-window nav with back/forward/reload toolbar
3e68678 Add View-menu nav commands; window title follows navigation
6a02f9a Update window title bar on in-window navigation
d997414 Wrap window-title plumbing as .documentURL view modifier
75a3b4e Suppress AppKit document menu / rename popover on title click
485cffb replacing DocumentGroup with WindowGroup
eca8334 Add Open Recent menu for the Viewer's WindowGroup
739c5f2 Resolve template assets in the Viewer via custom URL scheme
2379c1f Persist per-window navigation history across app launches
24e509b Show open panel on launch instead of a placeholder welcome window
04c2b68 Centralize /template and /preview route parsing
8c823b0 Refuse navigation to unreachable markdown links
fc26189 Fix cmd-click breaking after the first in-window navigation
8629431 Support macOS document rename via the title popover
1c327e3 Provide rename via File > Rename… instead of a title binding
aa0aa21 FTUE: hide the window
e69613b Editor coupling Phase 2: configurable editor + Settings window
65ba9e6 Hide windows until content is bound
```
