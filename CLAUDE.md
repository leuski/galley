# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Two macOS apps sharing one rendering engine:

- **Galley** ("Markdown Eye", bundle id `net.leuski.galley`, target `Viewer`, product `Galley`) — native document viewer. `WindowGroup(for: URL.self)` over a `WebPage`-backed `WebView`. Custom URL schemes: `x-galley://local` (internal `WKURLSchemeHandler` for template/document asset resolution) and `galley://<path>?line=N` (LaunchServices entry from BBEdit's `Preview Markdown… → in Galley` script). Cmd-click any rendered block to jump to the source line in the user's chosen editor.
- **Markdown Preview Server** (bundle id `net.leuski.galley.server`, target `Server`) — `MenuBarExtra`-only app that runs an HTTP server in-process so any browser (or BBEdit's preview pane) can view the same documents Galley would render. Owns server lifecycle, port, launch-at-login, and the BBEdit helper-script installer.

The shared engine ships as two Xcode framework targets: `GalleyCoreKit` (rendering / templates / models / watch / scripts) and `GalleyServerKit` (FlyingFox-backed HTTP server). Both apps link the kits; `Viewer` links only `GalleyCoreKit`, `Server` links both.

See `README.md` for HTTP routes, template placeholders, and BBEdit integration.

## Layout

```
MarkdownPreviewer.xcodeproj   # 6 targets: Viewer, Server, GalleyCoreKit, GalleyServerKit, Tests, UITests
Sources/
  GalleyCoreKit/              # framework — rendering, templates, watch, scripts, shared models, routing
    Accessibility/              # ViewerA11yID, ServerA11yID — UI-test identifier catalogs
    Models/                     # ChoiceModel, ProcessorModel, TemplateModel
    Render/                     # MarkdownRenderer, SwiftMarkdownRenderer,
                                # ExternalProcessRenderer, ProcessorStore
    Routing/                    # OpenBehavior, WindowID + WindowIDAllocator, WindowRegistry,
                                # WindowRecord, LaunchURLBuffer, PendingScrollLines,
                                # URLNormalizer, OpenURLRouter + DispatchAction,
                                # LaunchArguments
    Routes/                     # PreviewRoute, RouteNames (shared HTTP/scheme parser)
    Templates/                  # Template, BuiltInTemplate, UserTemplate, TemplateStore,
                                # Placeholders
    Scripts/                    # ScriptInstaller (BBEdit helper installer)
    Watch/                      # DocumentWatcher
    Notifications/              # DisplacementNotifier (catalog-displacement user notice)
    Views/                      # DividedSections (shared SwiftUI helper)
    Utilities/                  # MIMETypes, Bundle+Resources, String+URL/+HTML
    MarkdownFileTypes.swift     # recognized extensions, used by Viewer's open-panel UTIs
    Resources/                  # bundled DefaultTemplate.html, BBEdit helper scripts
  GalleyServerKit/            # framework — HTTP server (FlyingFox), routes, SSE
    PreviewServer.swift         # PreviewServerController (lifecycle + state)
    Routes.swift, SSE.swift, HTTPResponses.swift
  Viewer/                     # the Galley document app — pure SwiftUI, no AppDelegate
    ViewerApp.swift           @main — Window("welcome") + WindowGroup<URL> + Settings
    EditorBridge.swift, LinkBridge.swift, ScrollBridge.swift
    PreviewSchemeHandler.swift
    Models/                     # AppModel (global doc state), DocumentModel (per-window),
                                # WindowDispatcher (routing/registry), RecentDocumentsModel,
                                # PerFileStateStore, SceneProcessorModel,
                                # SceneTemplateModel, EditorChoice
    Views/                      # ContentView, WelcomeView (always-alive bootstrap anchor),
                                # WindowAccessor (NSWindow resolution helper),
                                # SettingsView, AssortedViews, Actions, FocusedValues
    Views/Menus/                # FileCommands, ViewCommands, RenderingCommands,
                                # ProcessorMenu, TemplateMenu
    Resources/                  # AppIcon, Assets.xcassets
  Server/                     # the Markdown Preview Server menu-bar app
    MarkdownPreviewerApp.swift  @main — MenuBarExtra + Settings
    App/                        # AppModel (server-owning), LoginItem
    Menu/                       # MenuBarContent, SettingsView
    Resources/                  # AppIcon, Assets.xcassets, MenuBarIcon
Tests/                        # Swift Testing — kit + app-logic unit tests
  GalleyCoreKitTests/           # PlaceholderContext, BuiltInTemplate, UserTemplateRewriter,
                                # URLPathHelpers, SwiftMarkdownRenderer,
    Routing/                    # WindowRegistry, OpenURLRouter, URLNormalizer,
                                # LaunchURLBuffer, PendingScrollLines, LaunchArguments
  GalleyServerKitTests/
  TestPlan.xctestplan           # enrols both Tests and UITests bundles
UITests/                      # XCUITest bundle — testTargetName: Viewer
                                # UITests.swift, UITestsLaunchTests.swift, AppLauncher.swift
Resources/Scripts/            # bundled BBEdit helper scripts (Galley + browser variants)
Scripts/                      # release.sh
docs/                         # branch handoff notes, native-viewer-ideas, test-framework
```

## Build & test

Pure Xcode project — **no `Package.swift` anywhere**. Frameworks build inside the project. Schemes:

- **Viewer** — the Galley document app
- **Server** — the menu-bar previewer
- **GalleyCoreKit**, **GalleyServerKit** — framework schemes (mostly for direct iteration / testing)

```bash
# Build the apps
xcodebuild -project MarkdownPreviewer.xcodeproj -scheme Viewer build
xcodebuild -project MarkdownPreviewer.xcodeproj -scheme Server build

# Tests — one Xcode test bundle named `Tests` covering both kits
xcodebuild -project MarkdownPreviewer.xcodeproj -scheme Viewer test
# (Or run from Xcode's Test navigator.)
```

Logic tests use **Swift Testing** (`@Test`, `#expect`); UI tests use **XCTest** (XCUITest is XCTest-based). The shared `TestPlan.xctestplan` enrols both targets. Logic coverage includes placeholder substitution, template rewriting, URL path helpers, the swift-markdown renderer, and every routing-layer decision (`WindowRegistry`, `OpenURLRouter`, `URLNormalizer`, `LaunchURLBuffer`, `PendingScrollLines`, `LaunchArguments`). UI coverage exercises real product invariants — welcome stays hidden, FTUE Open panel surfaces on cold launch, seeded launches produce visible document windows, File/View menus reachable on a populated doc. See `docs/test-framework.md` for the test pyramid.

The UITests target launches Galley with a `--seed-file <path>` flag handled by `LaunchArguments` (parsed in `ViewerApp.init`, pre-buffered into `WindowDispatcher`). Test mode also passes `-ApplePersistenceIgnoreState YES` to skip the post-crash "Reopen?" alert that would otherwise hang launches. **Don't pass `--ui-test-mode` as a launch argument** — AppKit's command-line `NSUserDefaults` parser eats `--`-prefixed tokens and pollutes the defaults domain in ways that suppress the welcome scene from spawning. Use `launchEnvironment` for the test-mode marker instead.

## Lint

SwiftLint runs as a `Lint` shell-script build phase (no separate scheme/target). Config is `swiftlint.yml` (custom name — pass `--config swiftlint.yml` if invoking the CLI). Notable rules:
- `force_unwrapping` is opt-in and enabled (warning) — avoid `!`.
- `line_length: 80` — long string literals and URLs need to be split.
- `function_body_length` warns at 65 lines.
- `nesting.type_level: 3`.

## Release

`Scripts/release.sh <vX.Y.Z>` archives the Release config, ad-hoc signs the `.app`, installs it to `/Applications`, zips it, tags the commit, and creates a GitHub release via `gh`. Use `--dry-run` to skip tag + publish. Build number is `git rev-list --count HEAD`; marketing version is the tag minus the leading `v`. Note: `SCHEME=MarkdownPreviewer` in the script is stale — needs updating to whichever scheme (`Viewer` or `Server`) the release targets.

`.github/workflows/release.yml` is the (currently disabled) signed + notarized CI path. Triggered manually (`workflow_dispatch`); requires repo secrets listed in the file header.

## Dependencies

Resolved by Xcode against package references in `MarkdownPreviewer.xcodeproj`:

- **FlyingFox / FlyingSocks** (`github.com/swhitty/FlyingFox`) — HTTP server. `GalleyServerKit` only.
- **swift-markdown** (`github.com/swiftlang/swift-markdown`) — bundled "Default" renderer.
- **swift-core-kit** (`github.com/leuski/swift-core-kit`, module `ALFoundation`) — **private** repo. CI authenticates via `GH_PACKAGES_PAT`; locally, ensure your git credentials can read it.
- **swift-argument-parser** (Leuski fork, `property-metadata` branch) — pulled in transitively.

External Markdown processors (MultiMarkdown, Pandoc, Discount, cmark-gfm, Markdown.pl) are invoked as subprocesses via `ExternalProcessRenderer`.

## Architecture

### Frameworks — shared engine

**`GalleyCoreKit`** — pure rendering and platform-agnostic primitives, no networking:
- `Render/` — `MarkdownRenderer` protocol; `SwiftMarkdownRenderer` (with optional `annotatesSourceLines` that emits `data-source-line="N"` on every block, used by the Viewer for cmd-click→editor); `ExternalProcessRenderer` (shells out via `Process`); `ProcessorStore` exposes the ordered list of `Processor` rows (each with `installHint` and either a live `MarkdownRenderer` or `nil` if unavailable). The Viewer's cmd-click bridge also accepts pandoc's `data-pos` and cmark-gfm's `data-sourcepos` so source-line jumps work across renderers.
- `Templates/` — `Template` protocol; `BuiltInTemplate` (compiled-in `DefaultTemplate.html`) and `UserTemplate`; `TemplateStore` watches `~/Library/Application Support/MarkdownPreviewer/Templates/` and accepts **two shapes** — a folder containing `Template.html`/`template.html` (Galley convention), or a top-level `*.html`/`*.htm` file with sibling assets (BBEdit preview-template convention). `Placeholders.swift` does `#TOKEN#` substitution (`#TITLE#`, `#DOCUMENT_CONTENT#`, `#BASE#`, `#FILE#`, `#BASENAME#`, `#FILE_EXTENSION#`, `#DATE#`, `#TIME#` — token names match BBEdit's). `UserTemplate.Rewriter` rewrites template-relative paths through `/template/<id>/...` and absolute filesystem paths through `/preview/<absolute-path>` (also a BBEdit convention) so the resulting URLs resolve in either the HTTP server or the Viewer's scheme handler.
- `Models/` — `ChoiceValueProtocol` / `ChoiceValueEnvelopeProtocol` plus `ProcessorChoiceValue` and `TemplateChoiceValue`. A small generic layer for "pick one of N" UIs that also persist their selection by stable `persistentID`.
- `Routing/` — pure value types for the Viewer's URL routing. `OpenBehavior` (`.newWindow` / `.newTab` / `.replaceCurrent`); `WindowID` + `WindowIDAllocator` (counter-based opaque identity, intentionally *not* `ObjectIdentifier(NSWindow)` — see comment in source for why); `WindowRegistry` + `WindowRecord` (records of open document windows, keyed by `WindowID`); `LaunchURLBuffer` (FIFO buffer for URLs that arrive before the SwiftUI `openWindow` action is captured); `PendingScrollLines` (`galley://...?line=N` scroll-line cache, keyed by standardized file path); `URLNormalizer` (turns `galley://path?line=N` into a `(URL, scrollLine)` pair, recognizes `galley://settings` as a separate `Outcome` case); `OpenURLRouter` + `DispatchAction` (pure decision function — given the URL, behavior, registry, returns `.queue` / `.openNew` / `.rebind(WindowID)` / `.tabOnto(WindowID)` / `.focusExisting(WindowID)`); `LaunchArguments` parser. The Viewer's `WindowDispatcher` is the AppKit interpreter that holds the live `NSWindow` references and applies the router's actions.
- `Accessibility/` — `ViewerA11yID` and `ServerA11yID` enum-of-string-constants catalogs. Single source of truth for every UITest-visible accessibility identifier; both apps and the UITests target import these. Note: SwiftUI's `.accessibilityIdentifier(...)` does *not* propagate to `NSMenuItem` from `.commands { ... }` blocks (AX dump shows synthetic `menuAction:` placeholders) — menu tests fall back to title-based queries; toolbar / inline-view surfaces use the catalog identifiers.
- `Watch/DocumentWatcher` — file-system watch over a document and its sibling directory; multiplexes events to all subscribers.
- `Routes/PreviewRoute.swift` + `RouteNames.swift` — shared parser for `/template/<id>/<file>` and `/preview/<absolute-path>` paths. Used by both the Server's HTTP routes and the Viewer's `x-galley://` scheme handler.
- `Scripts/ScriptInstaller` — copies bundled BBEdit helper scripts to `~/Library/Application Support/BBEdit/Scripts/`, rewriting the hardcoded port to match the running server. Lives in the kit because both apps want to reuse the same install logic.
- `Notifications/DisplacementNotifier` — surfaces a user-facing notice when a previously-persisted processor or template selection no longer exists in the live catalog (e.g., user uninstalled Pandoc). Used by both apps.
- `Views/DividedSections` — shared SwiftUI helper for settings-style grouped sections.
- `Utilities/` — `MIMETypes`, `Bundle+Resources`, `String+URL`, `String+HTML`.
- `MarkdownFileTypes.swift` — list of recognized Markdown extensions, also used by the Viewer's open-panel UTI list.

**`GalleyServerKit`** — wraps a `FlyingFox.HTTPServer` in a `Task`:
- `PreviewServer.swift` / `PreviewServerController` — lifecycle and state.
- `Routes.swift` — `/preview/<path>` (Markdown→HTML, with placeholders + live-reload script injection; non-Markdown extensions fall through to static asset serving from the document's directory), `/template/<id>/<file>`, `/events/<path>` (SSE stream from `SSE.swift`).
- `rendererProvider` and `templateStore` are passed in as `@Sendable` closures so each request reads the current selection without server-side state.

### `Sources/Server/` — Markdown Preview Server menu-bar app

- **`MarkdownPreviewerApp`** — `@main`, two Scenes: `MenuBarExtra` (with `MenuBarContent`) and `Settings`. The `MenuBarLabel` flips state-tinted icons based on `PreviewServerController.State` (running / stopped / failed). Hydration is gated on `AppBoot` so the menu bar shows "Starting…" until catalog discovery finishes.
- **`App/AppModel`** — `@Observable @MainActor`. Owns the persisted port, the `TemplateStore`, the `ProcessorStore`, the `templates` and `processors` `Choice` envelopes, the `PreviewServerController`, and `launchAtLogin` (via `LoginItem`). Server start/stop reads renderer + template selection at request time via `@Sendable` closures, so switching processor/template in the menu takes effect on the next request without server restart. Port changes restart the server.
- **`App/LoginItem`** — wraps `SMAppService.mainApp` so the rest of the app can ask "is the server set to launch at login?" without importing ServiceManagement.
- **`Menu/MenuBarContent`** — surfaces server state, port, the processor + template quick-switchers, BBEdit script installer entry, Settings, and Quit.
- **`Menu/SettingsView`** — preferences pane for port, launch-at-login, processor/template defaults.

### `Sources/Viewer/` — Galley document app

The Viewer is **pure SwiftUI** — there is no `NSApplicationDelegateAdaptor`. Routing state lives in `WindowDispatcher`, recents in `RecentDocumentsModel`, both `@Observable @MainActor` and injected via `.environment()`. The bootstrap problem (SwiftUI's `WindowGroup(for: URL.self)` doesn't auto-spawn at launch) is solved by an always-alive hidden `Window("welcome")` scene; see "Why the welcome scene" under Architecture decisions.

- **`ViewerApp`** — `@main`, three Scenes: `Window("welcome")` (always-spawning bootstrap anchor, see `WelcomeView`), `WindowGroup(for: URL.self)` driving `ContentView(fileURL:)`, and `Settings`. The welcome scene has `.defaultLaunchBehavior(.presented)` (force re-spawn on every launch) and `.restorationBehavior(.disabled)` (never remembered as closed). `ViewerApp.init` parses `LaunchArguments` and pre-buffers any `--seed-file` URL into the dispatcher before scenes register. Adds `FileCommands` (Open / Open Recent / Rename / Open in Editor / Print / Page Setup / Export as PDF), `ViewCommands` (Back/Forward/Reload, zoom), `RenderingCommands` (processor + template submenus, also surfaced in the toolbar via `ProcessorMenu` / `TemplateMenu`). No `MenuBarExtra` — that's the Server app's job. The Viewer is a pure document app: `.regular` activation policy, normal ⌘Q, no soft-quit, no daemon behavior. The `WindowRoot` private wrapper only exists so `@Environment(\.openSettings)` is in scope for `galley://settings` routing via `.onOpenURL`.
- **`Views/WelcomeView`** — content view for the singleton welcome window. Configures the host `NSWindow` to be invisible and non-interactive (`alphaValue = 0`, `ignoresMouseEvents = true`, `isExcludedFromWindowsMenu = true`, `collectionBehavior = [.transient, .ignoresCycle, .stationary]`, `isReleasedWhenClosed = false`). **Don't** mutate `styleMask` (forces window recreation, detaches the SwiftUI host view, cancels `.task`) and **don't** move the window to extreme offscreen coordinates (AppKit's constraint solver crashes inside `_postWindowNeedsUpdateConstraints`). The view's `.task(id: boot.model != nil)` captures `openWindow`, calls `dispatcher.install(_:)` to hand it over, drains the launch buffer, then — if no doc windows came back from state restoration — runs the FTUE Open panel via `recents.runOpenPanel()`. The view also hosts `.onOpenURL { dispatcher.handleOpenURLs(...) }`, replacing the old `application(_:open:)` AppDelegate hook for Finder / LaunchServices / `galley://` URL dispatches.
- **`Views/WindowAccessor`** — small `NSViewRepresentable` that resolves the host `NSWindow` synchronously via `viewDidMoveToWindow`, used by both `WelcomeView` (to apply hidden-window settings + register tab merges) and `ContentView` (to set `alphaValue` on doc bind, register/unregister with the dispatcher).
- **`Models/WindowDispatcher`** — `@Observable @MainActor`. Holds all routing state: `LaunchURLBuffer`, `WindowRegistry`, `PendingScrollLines`, `OpenURLRouter`, `WindowIDAllocator`, the `[ObjectIdentifier: WindowID]` map and reverse `[WindowID: NSWindow]` lookup, `[WindowID: rebind closure]` map, `pendingTabHosts: [NSWindow]`, captured `openHandler`. Methods: `handleOpenURLs(_:onSettingsRequested:)` (entry point, normalizes + dispatches), `dispatch(_:)` (router decide + apply), `register/unregister/updateCurrentURL` (window lifecycle), `consumePendingScrollLine`, `consumePendingTabHost`, `install(_:)` (capture openWindow + drain buffer), `enqueueAtLaunch(_:)` (test-mode `--seed-file` injection), `hasAnyDocumentWindow()`. The pure routing decisions live in `GalleyCoreKit/Routing/`; this is the AppKit adapter that holds live `NSWindow` references and converts router actions into AppKit calls (`makeKeyAndOrderFront`, `addTabbedWindow`, etc.).
- **`Models/RecentDocumentsModel`** — `@Observable @MainActor`. Wraps `NSDocumentController.shared.recentDocumentURLs` (because `WindowGroup` doesn't get File > Open Recent for free), runs `NSOpenPanel` for File > Open. `record(_:)`, `clearAll()`, `openRecent(_:)` (routes through `dispatcher.handleOpenURLs`), `runOpenPanel()` (async `panel.begin`), `presentOpenPanel()` (panel + dispatch). Bound by `FileCommands` for the menu UI.
- **`Models/AppModel`** — `@Observable @MainActor`, single owner of Viewer-wide preferences. Manages processor-catalog discovery (via `ProcessorStore`), persisted processor + template selection, the `TemplateStore`, the user's `EditorChoice`, `enablePerDocumentOverrides`, and `openBehavior`. UserDefaults keys are namespaced under the Viewer bundle identifier. `AppBoot` is a thin `@Observable` wrapper that holds the `AppModel` once async hydration finishes; `WelcomeView`'s task waits on `boot.model` before installing. `ContentView` always mounts even before hydration completes so `@SceneStorage` and URL restoration work as usual. Note: this `AppModel` does **not** own the HTTP server — that's a separate app.
- **`Models/DocumentModel`** — `@Observable @MainActor`. Per-window state: a `WebPage`, a `DocumentWatcher`, the bridges, and a back/forward `history` of URLs (persisted via `@SceneStorage` as `HistorySnapshot`). `bind(to:)` resets the stack; `navigate(to:)` pushes; `goBack` / `goForward` move `currentIndex`. A `bindGeneration` counter cancels stale watcher loops when the URL changes mid-stream. Re-renders preserve scroll position. Owns the Print / Page Setup / Export-as-PDF entry points (see "Print pipeline" below). Includes `renameCurrentDocument(toName:)` that moves the file and rewrites matching history entries.
- **`Models/SceneProcessorModel`, `Models/SceneTemplateModel`** — per-window override stores. Each holds an optional override that, when `enablePerDocumentOverrides` is on, wins over the global selection. Persisted via `@SceneStorage` so a restored window keeps its override; also propagated through `PerFileStateStore` so a fresh window opening a previously-seen file hydrates from disk.
- **`Models/PerFileStateStore`** — keyed by resolved file path. Persists per-document zoom, scroll position, processor override, and template override across launches. Two-tier with `@SceneStorage`: the scene store survives state restoration of an open window; the file store hydrates a fresh window on first open.
- **`Models/EditorChoice`** — Codable enum with `.preset(EditorPreset)` (BBEdit `x-bbedit://`, TextMate `txmt://`, VS Code `vscode://file{path}:{line}`, Sublime `subl://`, Zed `zed://file{path}:{line}`), `.customURL(template:)` with `{url}`/`{path}`/`{line}` placeholders, and `.appBundle(URL)` (silently drops the line — no portable way to pass it). Persisted as JSON in UserDefaults.
- **`Views/ContentView`** — pure document viewer. Mounts with a non-nil `fileURL` from the `WindowGroup<URL>` binding (the binding type is `Binding<URL?>` because that's what SwiftUI hands us, but the welcome scene's bootstrap guarantees the binding always has a real URL by the time ContentView body fires). The `Group { if fileURL != nil { … } else { Color.clear } }` defensive branch is gone — see commit `195260a`. The `WindowAccessor` sets `alphaValue = 0` initially and flips to `1` once `model.documentURL` becomes non-nil, then registers with the dispatcher and consumes any pending tab host.
- **`PreviewSchemeHandler`** — `WKURLSchemeHandler` for `x-galley://local`. Mirrors the HTTP server's route shapes (`/template/<id>/<file>`, `/preview/<absolute-path>`) using the shared `PreviewRoute` parser, so `Template.rewriteAssets(...)` produces URLs that resolve in the WebView the same way they resolve over HTTP. Reads the active template at request time via a `TemplateBox` reference (defined in `DocumentModel.swift`) so global template switches take effect on the next render. The non-bridged `ClassicPreviewSchemeHandler` (also in this file) is the `WKURLSchemeHandler` adapter used by the offscreen WKWebView during Print/Export — same resolution logic, no SwiftUI dependency.
- **`EditorBridge`** — `WKScriptMessageHandler` named `editor`. A single user script handles cmd-click (→ editor) and plain click (→ `LinkBridge`) in one combined listener; routing both through one `addEventListener` avoids capture-phase ordering issues that drop the editor handler after navigations in macOS 26 WebPage. Parses any of three source-line annotation formats (`data-source-line`, pandoc's `data-pos`, cmark-gfm's `data-sourcepos`). Closure-based — the actual open call is in `DocumentModel.openInEditor(line:)` so every cmd-click reads the current `EditorChoice` from settings.
- **`LinkBridge`** — `WKScriptMessageHandler` named `linkclick`. `.md` family → in-window navigation; external HTTP → default browser; other local files → `NSWorkspace`.
- **`ScrollBridge`** — `WKScriptMessageHandler` named `scroll`. Page injects a scroll listener; the bridge forwards the latest position to `DocumentModel`, which writes it through to `@SceneStorage` and `PerFileStateStore`.
- **Print pipeline** (in `DocumentModel`) — three entry points (Print, Page Setup, Export as PDF) share one path. SwiftUI's `WebPage` doesn't expose `printOperation(with:)`, so the pipeline spins up an offscreen `WKWebView` per operation, configured with `ClassicPreviewSchemeHandler`, awaits `didFinish` via `PrintLoadBridge`, then runs `webView.printOperation(with:)`. Two non-obvious bits: `printInfo.horizontalPagination` / `verticalPagination` must be `.automatic` (otherwise the whole document prints onto a single tall page), and the operation must be dispatched via `runModal(for:delegate:didRun:contextInfo:)` — `runOperation()` produces blank pages. Export-as-PDF uses the same path with `jobDisposition = .save` + `jobSavingURL` and the panel suppressed.
- **Window visibility** — document windows open with `alphaValue = 0` and unhide on first non-nil `documentURL`. Welcome stays at `alphaValue = 0` for its entire lifetime. There is no longer a placeholder concept in the registry/router — every registered window is a document window.
- **Sandbox is disabled** on the Viewer target (it was blocking sibling-document opens; the value was low for a developer tool). The Server target is also unsandboxed — it needs to read arbitrary user files to render them.

## Concurrency conventions

- UI-facing state (`AppModel` in both apps, `DocumentModel`, `WindowDispatcher`, `RecentDocumentsModel`, scene/per-file stores) is `@MainActor`.
- The HTTP server runs in a background `Task`; route handlers are `async` and capture only `Sendable` collaborators (closures, actors, value types).
- Renderer + template selection is read at request time via `@Sendable` provider closures rather than via shared mutable state — there is no dedicated `CurrentRenderer` actor.
- The routing layer in `GalleyCoreKit/Routing/` is pure value types (`Sendable`); the `WindowDispatcher` adapter is the only place that holds live `NSWindow` references.
- `@ObservationIgnored` is used for collaborators that should not trigger view invalidation (watchers, bridges, server controller, stores keyed by ID, the dispatcher's NSWindow maps).
- Swift 6 strict concurrency is enabled; prefer typed throws, `Sendable` value types, and structured concurrency.

## Reference

- `docs/handoff-galleykit.md` — phase-by-phase notes on the `refactor/galleykit` branch (Kit extraction, editor coupling, cross-document navigation, WindowGroup migration, state restoration).
- `docs/native-viewer-ideas.md` — running list of features the native Viewer could offer beyond what a generic browser does, with status (done / partial / not started / will-not-do) and rationale for the rejections.
- `docs/test-framework.md` — the test pyramid (routing logic / app logic / snapshot / UI / integration), where each kind of test goes, the launch-arg conventions for tests.

## Architecture decisions

### Two apps sharing frameworks (not one bundle)

The codebase tried a single-bundle factoring (Viewer with embedded server, soft-quit, activation-policy switching) and reverted to two apps sharing frameworks. Reasons the split won:
- Viewer wants `.regular` always; Server wants `MenuBarExtra`-only with `LSUIElement`. Reconciling those into one bundle required activation-policy juggling (soft-quit, `applicationWillFinishLaunching` policy restore, `applicationShouldHandleReopen` re-entry, suppressed-quit detection for log-out) — substantial complexity for the convenience of one bundle.
- Engine sharing is what actually mattered, and the framework targets give that without forcing a single process model.
- Server can keep running headless without dragging document-window state restoration along with it; Viewer can quit normally without thinking about a daemon.

### Frameworks not SwiftPM

The shared engine is two **Xcode framework targets** (`GalleyCoreKit`, `GalleyServerKit`), not a Swift Package. The earlier SwiftPM `Kit/` package was abandoned because `xcodebuild` test discovery for embedded local packages was unreliable while Xcode's GUI-driven test runs worked fine — a CI/scriptability liability the framework targets sidestep.

### `WindowGroup<URL>` not `DocumentGroup`

`DocumentGroup(viewing:)` was the original choice and was abandoned (commit `485cffb`). Two reasons:
- `DocumentGroup` ties one window to one `FileDocument`; titles, state restoration, and revision history all assume "this window represents this file." The Viewer is a *navigator* — one window walks through linked Markdown documents (`a.md` → click link → `b.md` rebinds the window's URL, title follows the navigation), which conflicts with `DocumentGroup`'s identity model.
- `DocumentGroup` attaches AppKit's "document menu" hover affordance to the title bar (rename / move / version-browse popover). For a read-only viewer this is wrong — there's no in-memory document to rename — and suppressing it via `.documentURL` modifier and similar workarounds wasn't sufficient.

### Why the `Window("welcome")` scene exists (and is invisible)

`WindowGroup(for: URL.self)` does **not** auto-spawn a window at cold launch when no URL is supplied. The `applicationShouldOpenUntitledFile` AppKit hook isn't bridged to value-driven `WindowGroup`s. With no view alive at launch, nothing captures `@Environment(\.openWindow)`, so URLs that arrive via Finder dispatch can't reach `openWindow(value:)` and never become document windows — the "first document doesn't open, only the second one does" bug.

The fix is a singleton `Window("welcome")` scene (commit `a888360`) that auto-spawns at launch and hosts `WelcomeView`. Welcome's job is to capture `openWindow`, hand it to the `WindowDispatcher` via `install(_:)`, drain the launch buffer, and run the FTUE Open panel when there's nothing else to do. The window itself is invisible (alpha=0 + `ignoresMouseEvents` + `isExcludedFromWindowsMenu` + transient/ignoresCycle/stationary collection behavior) — it's a pure adapter scene, not user-facing UI.

### Why no `ViewerAppDelegate` (anymore)

`ViewerAppDelegate` lived through several iterations (window registry, launch buffer, recents, FTUE picker, URL receipt). Once the welcome scene gave SwiftUI a guaranteed-alive view at launch, every AppDelegate hook had a SwiftUI equivalent or was redundant:
- `application(_:open:)` → `.onOpenURL` on `WelcomeView` (commit `c7b1d01`).
- Routing state → `WindowDispatcher` `@Observable @MainActor` (commit `4aa20b0`).
- Recents + Open panel → `RecentDocumentsModel` `@Observable @MainActor` (commit `fccac1b`).
- `applicationShouldTerminateAfterLastWindowClosed` / `applicationShouldOpenUntitledFile` → defaults are correct without overriding.
- `applicationSupportsSecureRestorableState` → modern SwiftUI Apps opt in by default.
- `applicationDidFinishLaunching → didFinishLaunching` → replaced with a fixed 250ms settle in `WelcomeView`'s task after `boot.model` is ready.
- `LaunchArguments` parsing → moved to `ViewerApp.init`.

`ViewerAppDelegate.swift` is gone (commit `d7ac967`). `@NSApplicationDelegateAdaptor` is gone. The Viewer is pure SwiftUI. If a hook resurfaces that genuinely requires an AppDelegate (e.g., `applicationShouldHandleReopen` for dock-icon click semantics), reintroduce a minimal one — don't reabsorb the routing state.
