# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Three apps and a Quick Look extension sharing one rendering engine plus one chunk of cross-platform viewer code:

- **Galley** (bundle id `net.leuski.galley`, target `Viewer`, product `Galley`, macOS) — native document viewer. `WindowGroup(for: URL.self)` over a `WebPage`-backed `WebView`. Custom URL schemes: `x-galley://local` (internal `URLSchemeHandler` for template/document asset resolution) and `galley://<path>?line=N` (LaunchServices entry from BBEdit's `Preview Markdown… → in Galley` script). Cmd-click any rendered block to jump to the source line in the user's chosen editor.
- **Galley Server** (bundle id `net.leuski.galley.server`, target `Server`, macOS) — `MenuBarExtra`-only app that runs an HTTP (+ optional HTTPS) server in-process so any browser (or BBEdit's preview pane) can view the same documents Galley would render. Owns server lifecycle, port file, launch-at-login, and the BBEdit helper-script installer. Galley embeds `Galley Server.app` inside its bundle and registers it as a user `LaunchAgent` (see `LaunchctlServerAgent` under `Sources/Viewer/Utilities/`).
- **Galley (visionOS)** (bundle id `net.leuski.galley`, target `Viewer.vision`, SDK `xros`) — minimal visionOS viewer reusing every shared viewer surface (DocumentModel, bridges, FindBar, TOC sidebar, StatusBar, etc.). No menus, no AppDelegate, no `LaunchArguments`, no `WindowDispatcher`; one `WindowGroup<URL?>` with an in-window "Open Document…" picker via `.fileImporter` for the empty case. No server is hosted here.
- **Quicklook** (target `Quicklook`, product `Quicklook.appex`, macOS) — `QLPreviewingController` extension. Tries the running Galley Server first so the user's chosen processor and template are honored; falls back to an in-process render with the built-in Swift renderer and bundled template when the server is unreachable.

The shared engine ships as two Xcode framework targets — `GalleyCoreKit` (rendering, templates, models, watch, scripts, networking-probe/pin, scheme handler) and `GalleyServerKit` (Hummingbird-backed HTTP/HTTPS server) — plus a non-framework shared source folder, `Sources/ViewerShared/`, that contains the per-window viewer code (DocumentModel, bridges, find/TOC/status views, Actions, the Viewer-side scheme handler) compiled directly into both `Viewer` (macOS) and `Viewer.vision`. Both macOS apps link `GalleyCoreKit`; `Server` also links `GalleyServerKit`; `Viewer` links `GalleyServerKit` for the in-process Quicklook fallback path and the server probe types. `Viewer.vision` links only `GalleyCoreKit`.

Localized strings live in `Localizable.xcstrings` per target (Viewer/Viewer.vision share `Sources/ViewerShared/Resources/Localizable.xcstrings`; Server, GalleyCoreKit, GalleyServerKit, and Quicklook each have their own). English and Russian are shipped.

See `README.md` for HTTP routes, template placeholders, and BBEdit integration.

## Layout

```
Galley.xcodeproj              # 8 targets: Viewer, Viewer.vision, Server, Quicklook,
                              #            GalleyCoreKit, GalleyServerKit, Tests, UITests
Sources/
  GalleyCoreKit/              # framework — rendering, templates, watch, networking,
                              # scripts, shared models, routing
    Accessibility/              # ViewerA11yID, ServerA11yID — UI-test identifier catalogs
    Localizable.xcstrings       # localized strings owned by the kit
    Models/                     # ChoiceModel, ProcessorModel, TemplateModel
    Networking/                 # ServerProbe, ServerStatus, ServerPortFile,
                                # PinnedCertificate
    Render/                     # MarkdownRenderer, SwiftMarkdownRenderer,
                                # ExternalProcessRenderer, ProcessorStore
    Routing/                    # OpenBehavior, WindowID + WindowIDAllocator,
                                # WindowRegistry, WindowRecord, LaunchURLBuffer,
                                # PendingScrollLines, URLNormalizer,
                                # OpenURLRouter + DispatchAction, LaunchArguments
    Routes/                     # PreviewRoute, RouteNames (shared HTTP/scheme parser)
    Templates/                  # Template, BuiltInTemplate, UserTemplate,
                                # TemplateStore, Placeholders
    Watch/                      # DocumentWatcher
    Notifications/              # DisplacementNotifier
    Views/                      # DividedSections (shared SwiftUI helper)
    Utilities/                  # MIMETypes, Bundle+Resources, String+URL/+HTML
    WebKit/                     # PreviewScheme (shared resolver) +
                                # ClassicPreviewSchemeHandler (WKURLSchemeHandler
                                # for QuickLook + offscreen print web view)
    MarkdownFileTypes.swift     # recognized extensions, used by open-panel UTIs
    Resources/                  # bundled DefaultTemplate.html, BBEdit helper scripts,
                                # Templates.bundle (Default, GitHub, HighContrast,
                                # LaTeX, Manuscript, Sepia, Solarized, Terminal, Tufte)
  GalleyServerKit/            # framework — Hummingbird HTTP/HTTPS server, SSE
    PreviewServer.swift         # PreviewServerController (lifecycle + state)
    Routes.swift, SSE.swift, HTTPResponses.swift
    Resources/                  # bundled ErrorPage.html
    Localizable.xcstrings
  ViewerShared/               # NOT a framework — shared sources compiled into both
                              # Viewer (macOS) and Viewer.vision (visionOS).
                              # `Resources/Info.plist` is the bundle Info.plist for
                              # BOTH apps (via INFOPLIST_FILE), excluded from the
                              # sources list via membershipExceptions.
    Bridges/                    # EditorBridge (cmd-click → editor; macOS-only sink),
                                # LinkBridge, ScrollBridge, FindBridge, TOCBridge,
                                # StatsBridge, BackgroundColorBridge,
                                # ServerCertificatePinner (WebPage.NavigationDeciding)
    Models/                     # DocumentModel + +History / +Notice / +Scroll / +Zoom,
                                # DocumentStats, FindSession, SearchFieldModel,
                                # BindPlan, HistorySnapshot+JSON, PerFileStateStore,
                                # SceneProcessorModel, SceneTemplateModel,
                                # ServerStatusModel, Template+BackgroundColor (portable)
    Resources/                  # Info.plist (shared bundle plist),
                                # Assets.xcassets (AppIcon/AccentColor),
                                # Localizable.xcstrings
    Views/                      # Actions, Animation, AssortedViews, FindBar,
                                # FocusedValues, SearchField, StatusBar, TOCSidebar
    WebKit/                     # PreviewSchemeHandler — SwiftUI-flavored
                                # URLSchemeHandler for the Viewer's WebPage;
                                # delegates to GalleyCoreKit.PreviewScheme.resolve
  Viewer/                     # the Galley document app (macOS)
    ViewerApp.swift           @main — Window("welcome") + WindowGroup<URL> +
                              # Window("help") + Settings; @NSApplicationDelegateAdaptor
                              # for the secure-state-restoration hook
    ViewerAppDelegate.swift   # minimal — only declares
                              # `applicationSupportsSecureRestorableState`
    Models/                     # AppModel + Defaults (@ObservableDefaults),
                                # AppBoot, WindowDispatcher, RecentDocumentsModel,
                                # DocumentModel+Print, EditorChoice, EditorPreset,
                                # Template+BackgroundColor+macOS
    Utilities/                  # ActiveServerAgent (swap point),
                                # LaunchctlServerAgent (active backend),
                                # ServerAgent (SMAppService alternative)
    Resources/                  # AppIcon, en.lproj, ru.lproj,
                                # net.leuski.galley.server.plist (LaunchAgent template)
    Views/                      # ContentView, DocumentView, WelcomeView,
                                # HelpWindowView, BootstrapModifier,
                                # WindowAccessor, NewTabAction, ServerStatusPill,
                                # SettingsView
    Views/Menus/                # FileCommands, EditCommands, ViewCommands,
                                # FormatCommands, HelpCommands
    Views/Settings/             # GeneralSettingsView, MarkdownSettingsView,
                                # ServerSettingsView
  ViewerVisionOS/             # the Galley document app (visionOS)
    ViewerApp.swift             # @main — one WindowGroup<URL?> + Defaults.warmCache
    Models/                     # AppModel (minimal — templates/processors only),
                                # AppBoot, Defaults (@ObservableDefaults, subset),
                                # Template+BackgroundColor+visionOS
    Views/                      # ContentView (boot gate + WelcomeScreen +
                                # DocumentScreen w/ NavigationSplitView)
  Server/                     # the Galley Server menu-bar app (macOS)
    ServerApp.swift             @main — MenuBarExtra + Settings
    App/                        # AppModel (server-owning), LoginItem
    Menu/                       # MenuBarContent, SettingsView
    Localizable.xcstrings
    Resources/                  # AppIcon, Assets.xcassets, MenuBarIcon
  Quicklook/                  # Quick Look preview extension (.appex, macOS)
    PreviewViewController.swift # QLPreviewingController — server-first,
                                # fallback to built-in render via ClassicPreviewSchemeHandler
    Info.plist, Quicklook.entitlements
    en.lproj, ru.lproj
Tests/                        # Swift Testing — kit + app-logic unit tests
  GalleyCoreKitTests/           # Placeholders, BuiltInTemplate, TemplateAssetRewriter,
                                # URLPathHelpers, SwiftMarkdownRenderer (incl. spec
                                # conformance), ChoiceObservation, ServerProbe,
                                # ServerPortFile, PinnedCertificate, GalleyAppHash,
                                # ClipboardRoundTrip
    Routing/                    # WindowRegistry, OpenURLRouter, URLNormalizer
                                # (GalleyActionTests), LaunchURLBuffer,
                                # PendingScrollLines, LaunchArguments
  GalleyServerKitTests/         # PreviewServerController, RoutePathDecoding,
                                # HostHeaderGuard, ReloadScriptInjection, SSEEncoder
    Integration/                # ServerPreviewEndToEnd
  ViewerTests/                  # ViewerTests (app-logic, currently sparse)
  TestPlan.xctestplan           # enrols Tests + UITests
UITests/                      # XCUITest bundle — testTargetName: Viewer
                                # UITests.swift, UITestsLaunchTests.swift, AppLauncher.swift
Resources/Scripts/            # bundled BBEdit helper scripts (Galley + browser variants)
Scripts/                      # release.sh
docs/                         # test-framework
```

## Build & test

Pure Xcode project — **no `Package.swift` anywhere**. Frameworks build inside the project. New source files dropped into the per-target source directories (`Sources/Viewer/...`, `Sources/ViewerShared/...`, `Sources/ViewerVisionOS/...`, `Sources/Server/...`, etc.) are picked up automatically — the project uses Xcode 16 filesystem-synchronized groups, so `Galley.xcodeproj/project.pbxproj` has no individual file references and **no manual registration is required** when adding a file. The `ViewerShared` root group is a member of both `Viewer` and `Viewer.vision` (with `Resources/Info.plist` excluded from the sources lists via `membershipExceptions`); files added under `Sources/ViewerShared/` get built into both apps automatically.

Shared schemes:

- **Viewer** — the Galley macOS document app
- **Server** — the menu-bar previewer
- **Quicklook** — the Quick Look preview extension
- **GalleyCoreKit** — framework scheme (mostly for direct iteration / testing)

The visionOS target (`Viewer.vision`) has no shared `.xcscheme` checked in — Xcode auto-generates one on first build.

**For routine macOS work, only build the Viewer scheme.** Galley.app embeds `Galley Server.app` as a bundle resource and `Quicklook.appex` as a foundation extension, so building Viewer builds the kits, the server, and the QuickLook extension in one pass. Building all three macOS schemes separately is pure waste — same compile work, three times the wall-clock cost. The same applies to `test` — the `Viewer` scheme's test action runs the unified `Tests` bundle that covers both kits and the macOS viewer app logic.

```bash
# Build everything macOS (Viewer + Server + Quicklook + both kits + ViewerShared)
xcodebuild -project Galley.xcodeproj -scheme Viewer build

# Build the visionOS viewer (separate SDK)
xcodebuild -project Galley.xcodeproj -scheme Viewer.vision \
  -destination "generic/platform=visionOS" build

# Tests — one Xcode test bundle named `Tests` covering both kits + viewer
xcodebuild -project Galley.xcodeproj -scheme Viewer test
# (Or run from Xcode's Test navigator.)
```

Logic tests use **Swift Testing** (`@Test`, `#expect`); UI tests use **XCTest** (XCUITest is XCTest-based). The shared `TestPlan.xctestplan` enrols both targets. Logic coverage includes placeholder substitution, template rewriting, URL path helpers, the swift-markdown renderer (with a CommonMark-spec-conformance suite), pinned-certificate verification, the server probe / port file, the SSE encoder, host-header guarding, reload-script injection, and every routing-layer decision (`WindowRegistry`, `OpenURLRouter`, `URLNormalizer`, `LaunchURLBuffer`, `PendingScrollLines`, `LaunchArguments`). UI coverage exercises real product invariants — welcome stays hidden, FTUE Open panel surfaces on cold launch, seeded launches produce visible document windows, File/View menus reachable on a populated doc. See `docs/test-framework.md` for the test pyramid.

The UITests target launches Galley with a `--seed-file <path>` flag handled by `LaunchArguments` (parsed in `ViewerApp.init`, pre-buffered into `WindowDispatcher`). Test mode also passes `-ApplePersistenceIgnoreState YES` to skip the post-crash "Reopen?" alert that would otherwise hang launches. **Don't pass `--ui-test-mode` as a launch argument** — AppKit's command-line `NSUserDefaults` parser eats `--`-prefixed tokens and pollutes the defaults domain in ways that suppress the welcome scene from spawning. Use `launchEnvironment` for the test-mode marker instead.

## Lint

SwiftLint runs as a `Lint` shell-script build phase (no separate scheme/target). Config is `swiftlint.yml` (custom name — pass `--config swiftlint.yml` if invoking the CLI). Notable rules:
- `force_unwrapping` is opt-in and enabled (warning) — avoid `!`.
- `line_length: 80` — long string literals and URLs need to be split.
- `function_body_length` warns at 65 lines.
- `nesting.type_level: 3`.

## Release

`Scripts/release.sh <vX.Y.Z>` archives the Release config, ad-hoc signs the `.app`, installs it to `/Applications`, zips it, tags the commit, and creates a GitHub release via `gh`. Use `--dry-run` to skip tag + publish. Build number is `git rev-list --count HEAD`; marketing version is the tag minus the leading `v`. Confirm the script's `SCHEME` matches whichever scheme (`Viewer` or `Server`) the release targets before tagging.

`.github/workflows/release.yml` is the (currently disabled) signed + notarized CI path. Triggered manually (`workflow_dispatch`); requires repo secrets listed in the file header.

## Dependencies

Resolved by Xcode against package references in `Galley.xcodeproj`:

- **Hummingbird / HummingbirdTLS** (`github.com/hummingbird-project/hummingbird`) — HTTP + HTTPS server. `GalleyServerKit` only. (Replaced FlyingFox because Hummingbird supports TLS, which lets the Server present a self-signed cert that the Viewer pins via `PinnedCertificate` / `ServerCertificatePinner`.)
- **swift-markdown** (`github.com/swiftlang/swift-markdown`) — bundled "Default" renderer.
- **swift-core-kit** (`github.com/leuski/swift-core-kit`, module `ALFoundation`) — **private** repo. CI authenticates via `GH_PACKAGES_PAT`; locally, ensure your git credentials can read it.
- **ObservableDefaults** (`github.com/fatbobman/ObservableDefaults`) — `@ObservableDefaults` macro backing `Sources/Viewer/Models/AppModel.swift` (`Defaults`) and `Sources/ViewerVisionOS/Models/Defaults.swift`. Both call `Defaults.warmCache()` from `ViewerApp.init` before SwiftUI lays out a single view — see the long comment on `warmCache()` for the WebKit-triggered AttributeGraph reentrancy this defends against.

External Markdown processors (MultiMarkdown, Pandoc, Discount, cmark-gfm, Markdown.pl) are invoked as subprocesses via `ExternalProcessRenderer` (macOS-only — the kit guards `Process` use behind `#if os(macOS)`).

## Architecture

### Frameworks — shared engine

**`GalleyCoreKit`** — pure rendering and platform-agnostic primitives. No HTTP-server code:
- `Render/` — `MarkdownRenderer` protocol; `SwiftMarkdownRenderer` (with optional `annotatesSourceLines` that emits `data-source-line="N"` on every block, used by the Viewer for cmd-click→editor); `ExternalProcessRenderer` (shells out via `Process`, macOS-only); `ProcessorStore` exposes the ordered list of `Processor` rows (each with `installHint` and either a live `MarkdownRenderer` or `nil` if unavailable). The Viewer's cmd-click bridge also accepts pandoc's `data-pos` and cmark-gfm's `data-sourcepos` so source-line jumps work across renderers.
- `Templates/` — `Template` protocol; `BuiltInTemplate` and `UserTemplate`; `TemplateStore` watches `~/Library/Application Support/net.leuski.galley/Templates/` and accepts **two shapes** — a folder containing `Template.html`/`template.html` (Galley convention), or a top-level `*.html`/`*.htm` file with sibling assets (BBEdit preview-template convention). Built-in templates (Default, GitHub, HighContrast, LaTeX, Manuscript, Sepia, Solarized, Terminal, Tufte) ship in `Resources/Templates.bundle`. `Placeholders.swift` does `#TOKEN#` substitution (`#TITLE#`, `#DOCUMENT_CONTENT#`, `#BASE#`, `#FILE#`, `#BASENAME#`, `#FILE_EXTENSION#`, `#DATE#`, `#TIME#` — token names match BBEdit's). `UserTemplate.Rewriter` rewrites template-relative paths through `/template/<id>/...` and absolute filesystem paths through `/preview/<absolute-path>` so the resulting URLs resolve in either the HTTP server or the Viewer's scheme handler.
- `Networking/` — `ServerProbe` (async sequence that polls the running server), `ServerStatus` (reachable / unknown / down), `ServerPortFile` (reads the port + preferred endpoint URL from `~/Library/Application Support/net.leuski.galley.localized/server-port.json` so the Viewer / QuickLook can find a server bound to an OS-assigned port), `PinnedCertificate` (loads `server-cert.pem` from Application Support and compares against an inbound `serverTrust`).
- `WebKit/PreviewSchemeHandler.swift` — `PreviewScheme` enum with the `x-galley` scheme name + origin URL + the shared `resolve(...)` function. `ClassicPreviewSchemeHandler` (the `WKURLSchemeHandler` adapter, no SwiftUI dep) is here; the Viewer-visible SwiftUI-flavored `URLSchemeHandler` is in `Sources/ViewerShared/WebKit/PreviewSchemeHandler.swift` and delegates to the same resolver. Used by the Viewer's visible `WebPage`, the Viewer's offscreen print/export `WKWebView`, and the QuickLook extension's fallback render.
- `Models/` — `ChoiceValueProtocol` / `ChoiceValueEnvelopeProtocol` plus `ProcessorChoiceValue` and `TemplateChoiceValue`. A small generic layer for "pick one of N" UIs that also persist their selection by stable `persistentID`.
- `Routing/` — pure value types for the Viewer's URL routing. `OpenBehavior` (`.newWindow` / `.newTab` / `.replaceCurrent`); `WindowID` + `WindowIDAllocator` (counter-based opaque identity, intentionally *not* `ObjectIdentifier(NSWindow)`); `WindowRegistry` + `WindowRecord`; `LaunchURLBuffer` (FIFO buffer for URLs that arrive before `openWindow` is captured); `PendingScrollLines` (`galley://...?line=N` scroll-line cache); `URLNormalizer` (turns `galley://path?line=N` into a `(URL, scrollLine)` pair, recognizes `galley://settings` as a separate `Outcome` case); `OpenURLRouter` + `DispatchAction` (pure decision function returning `.queue` / `.openNew` / `.rebind(WindowID)` / `.tabOnto(WindowID)` / `.focusExisting(WindowID)`); `LaunchArguments` parser. The Viewer's `WindowDispatcher` is the AppKit interpreter that holds the live `NSWindow` references and applies the router's actions. (visionOS does not use this layer — `Viewer.vision` has no `WindowDispatcher`.)
- `Accessibility/` — `ViewerA11yID` / `ServerA11yID` enum-of-string-constants catalogs.
- `Watch/DocumentWatcher` — file-system watch over a document and its sibling directory; multiplexes events to all subscribers.
- `Routes/PreviewRoute.swift` + `RouteNames.swift` — shared parser for `/template/<id>/<file>` and `/preview/<absolute-path>` paths. Used by both the Server's HTTP routes and the Viewer's `x-galley://` scheme handler.
- `Notifications/DisplacementNotifier` — surfaces a user-facing notice when a previously-persisted processor or template selection no longer exists in the live catalog.
- `Views/DividedSections` — shared SwiftUI helper for settings-style grouped sections.
- `Utilities/` — `MIMETypes`, `Bundle+Resources`, `String+URL`, `String+HTML`.
- `MarkdownFileTypes.swift` — list of recognized Markdown extensions, also used by open-panel UTI lists.

**`GalleyServerKit`** — wraps a `Hummingbird` HTTP server (with optional `HummingbirdTLS` HTTPS listener) in a `Task`:
- `PreviewServer.swift` / `PreviewServerController` — lifecycle and state. Binds to `127.0.0.1` on an **OS-assigned port** (no fixed port; the chosen port is written to `ServerPortFile` so consumers can find it). When `server-cert.pem` + `server-key.pem` are present in Application Support, an HTTPS listener is spun up alongside the HTTP one — HTTPS failure is intentionally non-fatal, the HTTP listener keeps running. `state.running(url:)` always reports the HTTP URL; consumers that want HTTPS read `ServerPortFile.preferredEndpointURL`.
- `Routes.swift` — `/preview/<path>` (Markdown→HTML, with placeholders + live-reload script injection; non-Markdown extensions fall through to static asset serving from the document's directory), `/template/<id>/<file>`, `/events/<path>` (SSE stream from `SSE.swift`). Host-header guarded (loopback-only).
- `rendererProvider` and `templateStore` are passed in as `@Sendable` closures so each request reads the current selection without server-side state.

### `Sources/ViewerShared/` — cross-platform viewer code

Not a framework. Compiled directly into both `Viewer` (macOS) and `Viewer.vision` (visionOS) via the project's `PBXFileSystemSynchronizedRootGroup` mechanism (with `Resources/Info.plist` excluded from the sources lists — both apps use it as their `INFOPLIST_FILE`).

- `Models/DocumentModel.swift` plus `+History`, `+Notice`, `+Scroll`, `+Zoom` — per-document state, owned by each viewer window. Holds the `WebPage`, the bridges, the back/forward history (persisted via `@SceneStorage` as a `HistorySnapshot`), zoom + scroll persistence, the document-notice channel (banner shown over the WebView for ephemeral and render-bound errors), and the rendered-template box. A `Kind` enum (`.document` / `.help`) distinguishes the singleton Help window from real document windows so the help window skips the routing-registry handshake.
- `Models/BindPlan.swift` — pure decision type for "given a fileURL + persisted state, what should the next bind do?"
- `Models/DocumentStats.swift`, `Models/FindSession.swift`, `Models/SearchFieldModel.swift` — drive the StatusBar and FindBar.
- `Models/Template+BackgroundColor.swift` — portable storage layer for the per-template page-bg cache (the platform-specific color machinery lives in `Sources/Viewer/Models/Template+BackgroundColor+macOS.swift` and `Sources/ViewerVisionOS/Models/Template+BackgroundColor+visionOS.swift`).
- `Models/HistorySnapshot+JSON.swift`, `Models/PerFileStateStore.swift`, `Models/SceneProcessorModel.swift`, `Models/SceneTemplateModel.swift`, `Models/ServerStatusModel.swift` — persistence + per-scene overrides.
- `Bridges/` — `WKScriptMessageHandler`s used by `DocumentModel`. `EditorBridge` (cmd-click → editor; the actual open-in-editor call is `#if os(macOS)`-gated), `LinkBridge` (`.md` family → in-window navigation; external HTTP → default browser/`openURL`; `finder://` → reveal-in-Finder on macOS), `ScrollBridge`, `FindBridge`, `TOCBridge`, `StatsBridge`, `BackgroundColorBridge`. Plus `ServerCertificatePinner` (`WebPage.NavigationDeciding`) that pins the Server's HTTPS cert via `PinnedCertificate`.
- `Views/` — `Actions` (one source of truth for navigation/zoom/find/TOC/status-bar/etc. buttons, used by both menu and toolbar surfaces, with `.menuItem()` and `.toolbarItem(imageOnly:)` view-builders), `FindBar`, `TOCSidebar`, `StatusBar`, `SearchField`, `FocusedValues` (`\.documentModel` focused-scene key), `AssortedViews` (NoticeBanner etc.), `Animation`.
- `WebKit/PreviewSchemeHandler.swift` — SwiftUI-flavored `URLSchemeHandler` for the visible `WebPage`. Resolution delegates to `GalleyCoreKit.PreviewScheme.resolve` so the offscreen print web view and the QuickLook extension hit the same logic via `ClassicPreviewSchemeHandler`.

When sharing a file across both apps, prefer it lives here over duplicating between `Sources/Viewer/` and `Sources/ViewerVisionOS/`. Platform-specific extensions go behind `#if os(macOS)` / `#if !os(macOS)` either inside the shared file (for small surface differences) or in a sibling file in the platform-specific directory (e.g. `Template+BackgroundColor+macOS.swift` / `Template+BackgroundColor+visionOS.swift`).

### `Sources/Viewer/` — Galley macOS document app

The Viewer is **almost** pure SwiftUI. A minimal `ViewerAppDelegate` is reintroduced for a single hook — `applicationSupportsSecureRestorableState` — because without it, macOS 12+ refuses to write the saved-state directory and `WindowGroup<URL>` windows are silently lost on relaunch. SwiftUI provides no scene-level way to opt in. Everything else (routing state, recents, FTUE picker, URL receipt) lives in `@Observable @MainActor` types injected via `.environment()`. If a hook resurfaces that genuinely requires the AppDelegate, reintroduce a minimal one — don't reabsorb the routing state.

- **`ViewerApp`** — `@main`, four Scenes: `Window("welcome")` (always-spawning bootstrap anchor), `WindowGroup(for: URL.self)` driving `ContentView`, `Window("help")` (singleton Help window), and `Settings`. The welcome scene has `.defaultLaunchBehavior(.presented)` and `.restorationBehavior(.disabled)`. `ViewerApp.init` runs `Defaults.warmCache()`, parses `LaunchArguments`, pre-buffers any `--seed-file` URL into the dispatcher, and fires `ActiveServerAgent.validateAndRepair()` as a fire-and-forget Task (to detect and repair a stale absolute-path registration after the user moves Galley.app). Adds `FileCommands` (Open / Open Recent / Rename / Open in Editor / Print / Page Setup / Export as PDF), `EditCommands` (Find / Use Selection for Find / Find Next / Find Previous), `ViewCommands` (TOC / status-bar toggle / zoom / back/forward/reload), `FormatCommands` (renderer + template pickers), and `HelpCommands` (opens bundled help docs). No `MenuBarExtra` — that's the Server app's job.
- **`Models/Defaults`** (`@ObservableDefaults`) — UserDefaults-backed prefs. Persists `renderer`, `template`, `enablePerDocumentOverrides`, `openBehavior`, `editor`, `perFileStateStore`, `templateBackgroundColors`, `lastTemplateBackgroundColor`, `transparentToolbar`, `showsStatusBar`, `readingWordsPerMinute`. `Defaults.warmCache()` posts a synchronous `UserDefaults.didChangeNotification` so the macro's per-property cache catches up to disk before the first WebKit-triggered notification arrives — otherwise `WKWebView.init` posts that notification synchronously from inside a SwiftUI layout pass, which re-enters AttributeGraph and crashes. The Server runs in a separate process and reads the same plist via `UserDefaults.standard` (since both apps share `net.leuski.galley` as the suite); `DefaultsBroadcast` translates Darwin notifications into local `didChangeNotification`s so cross-process writes propagate.
- **`Models/AppModel`** — `@Observable @MainActor`. Single owner of Viewer-wide state: `templates: TemplateChoice`, `processors: ProcessorChoice`, `editors: EditorChoice`, `selectedSettingsTab` (Settings deep links land on the right pane). Constructed by `AppBoot` after `await ProcessorStore.shared.discover()`.
- **`Models/AppBoot`** — `@Observable @MainActor`. Holds the `AppModel` once async hydration finishes; views branch on `boot.model` non-nil.
- **`Models/WindowDispatcher`** — `@Observable @MainActor`. Routing state: `LaunchURLBuffer`, `WindowRegistry`, `PendingScrollLines`, `OpenURLRouter`, `WindowIDAllocator`, the `[ObjectIdentifier: WindowID]` map and reverse `[WindowID: NSWindow]` lookup, captured `openHandler`, captured `helpHandler` for the singleton Help window, `currentHelpURL`. Methods: `handleOpenURLs(_:onSettingsRequested:)`, `dispatch(_:)`, `register/unregister/updateCurrentURL`, `consumePendingScrollLine`, `consumePendingTabHost`, `install(_:)` (capture `openWindow` + drain buffer; idempotent — `BootstrapDispatchModifier` calls it from every doc window because macOS 26 sometimes skips mounting `Window("welcome")` when state restoration has already produced doc windows), `enqueueAtLaunch(_:)`, `hasAnyDocumentWindow()`, `openAsTabs(_:onto:)`. The pure routing decisions live in `GalleyCoreKit/Routing/`; this is the AppKit adapter.
- **`Models/RecentDocumentsModel`** — `@Observable @MainActor`. Wraps `NSDocumentController.shared.recentDocumentURLs`, runs `NSOpenPanel` for File > Open. `record(_:)` refuses bundle URLs so help docs never land in recents. Bound by `FileCommands`.
- **`Views/ContentView`** — boot-gated wrapper. While `AppBoot.model` is `nil` or the WindowGroup URL is `nil`, paints a `Color.clear` with a `BootWindowHider` that pins `window.alphaValue = 0` so the user never sees a pre-render flash. Once both inputs resolve, mounts `DocumentView` with non-optional inputs. Attaches `BootstrapDispatchModifier` so whichever scene mounts (welcome or doc) wires the dispatcher.
- **`Views/DocumentView`** — the viewer surface for a populated doc window. Owns the `DocumentModel`, the rename alert / PDF-export-error alert state, the `@SceneStorage("history")` blob, the `WindowAccessor`-based `NSWindow` adoption with re-attach support (SwiftUI caches scene `@State` for a freshly-closed `WindowGroup<URL>` window and reuses it when the same URL is reopened — a naive nil-guard would turn the reopened tab into a floating, toolbar-less window). `kind: .help` skips dispatcher adoption and registry entry entirely.
- **`Views/WelcomeView`** — content view for the singleton welcome window. Configures the host `NSWindow` to be invisible and non-interactive (`alphaValue = 0`, `ignoresMouseEvents = true`, `isExcludedFromWindowsMenu = true`, `collectionBehavior = [.transient, .ignoresCycle, .stationary]`). The view's `.task` waits on `boot.model`, then runs the FTUE Open panel via `recents.runOpenPanel()` when no doc windows came back from state restoration.
- **`Views/HelpWindowView`** — content view for the singleton `Window("help")` scene. Reads `dispatcher.currentHelpURL` and mounts `DocumentView` in `.help` mode.
- **`Views/BootstrapModifier`** — `BootstrapDispatchModifier`. Attaches to **both** welcome AND every doc window — whichever view actually mounts wires `dispatcher.install(_:)`, drains the buffer, and hosts `.onOpenURL { dispatcher.handleOpenURLs(...) }`. macOS 26 / SwiftUI does not always spawn `Window("welcome")` at launch when state restoration produced doc windows.
- **`Views/NewTabAction`** — the static `NewTabAction.handler` is wired from `ViewerApp.configureRouting()` to run the Open panel and `dispatcher.openAsTabs(picks, onto: source)` so the tab bar "+" merges picks as tabs onto the source window.
- **`Views/Settings/`** — three panes (`GeneralSettingsView`, `MarkdownSettingsView`, `ServerSettingsView`) selected by `appModel.selectedSettingsTab`. Server pane drives `ActiveServerAgent` + a `ServerStatusPill` powered by `ServerStatusModel`.
- **`Views/Menus/`** — split per command group: `FileCommands`, `EditCommands`, `ViewCommands`, `FormatCommands`, `HelpCommands`. All bind through `@FocusedValue(\.documentModel)` and `Action.*` so behavior stays consistent with the toolbar.
- **`Utilities/ActiveServerAgent`** — single swap point for the server-agent backend. The live backend is `LaunchctlServerAgent` (classic `~/Library/LaunchAgents/net.leuski.galley.server.plist`). The Apple-blessed `SMAppService` alternative (`ServerAgent`) is kept as a sibling for reference but is **not** the active backend on local builds: `SMAppService`-spawned helpers go through AMFI's launch-constraint check, which rejects ad-hoc-signed binaries with `Launch Constraint Violation` and (combined with `KeepAlive`) can respawn-loop. The active backend writes the plist with no `KeepAlive` and runs `validateAndRepair()` at launch to rewrite a stale absolute `Program` path if Galley.app has moved.
- **`Models/DocumentModel+Print`** — three entry points (Print, Page Setup, Export as PDF) share one offscreen `WKWebView` path configured with `ClassicPreviewSchemeHandler`. Two non-obvious bits: `printInfo.horizontalPagination` / `verticalPagination` must be `.automatic` (otherwise the whole document prints onto a single tall page), and the operation must be dispatched via `runModal(for:delegate:didRun:contextInfo:)` — `runOperation()` produces blank pages.
- **Window visibility** — document windows open with `alphaValue = 0` and unhide on first non-nil `documentURL`. Welcome stays at `alphaValue = 0` for its entire lifetime.
- **Sandbox is disabled** on the Viewer target. The Server target is also unsandboxed — it needs to read arbitrary user files to render them.

### `Sources/ViewerVisionOS/` — Galley visionOS document app

Far smaller than the macOS counterpart. No AppDelegate, no welcome bootstrap scene, no `LaunchArguments` parsing, no `WindowDispatcher` (every URL arrives via `WindowGroup<URL?>`'s value binding). No menus. No external editor. No hosted server. Reuses every shared view (`DocumentView`-style chrome wired inline in `ContentView`, `FindBar`, `TOCSidebar`, `StatusBar`, `Actions.*`) and every shared model (`DocumentModel`, `PerFileStateStore`, `SceneProcessorModel`, `SceneTemplateModel`).

- **`ViewerApp`** — `@main`, single `WindowGroup(for: URL.self)`. `init()` runs `Defaults.warmCache()` for the same WebKit-reentrancy reason as macOS.
- **`Models/Defaults`** — subset of the macOS keys. Includes `renderer`, `template`, `enablePerDocumentOverrides` (read by shared `DocumentModel.resolvedRenderer` / `resolvedTemplate`; stays `false` for v1), `perFileStateStore`, `templateBackgroundColors`, `lastTemplateBackgroundColor`, `showsStatusBar`, `readingWordsPerMinute`. macOS-only keys (`editor`, `openBehavior`, `transparentToolbar`) are intentionally absent.
- **`Models/AppModel`** — `templates: TemplateChoice` + `processors: ProcessorChoice`. No `editors` (`DocumentModel.openInEditor` is `#if os(macOS)`-gated), no server restart. Cross-process suite signaling is also dropped (no second process).
- **`Models/AppBoot`** — same shape as macOS: await `ProcessorStore.shared.discover()` then construct `AppModel`. On visionOS the processor discovery returns the built-in renderer only, since external CLI processors are unreachable.
- **`Views/ContentView`** — boot gate. Three states: progress spinner while `boot.model` is nil; `WelcomeScreen` with an "Open Document…" button driving `.fileImporter` (visionOS-native Files.app picker) when the WindowGroup binding has no URL; `DocumentScreen` with a `NavigationSplitView` (TOC sidebar + WebView with FindBar + StatusBar) and a toolbar of `Action.*` buttons when both are ready.

### `Sources/Server/` — Galley Server menu-bar app (macOS)

- **`ServerApp`** — `@main`, two Scenes: `MenuBarExtra` (with `MenuBarContent`) and `Settings`. The `MenuBarLabel` flips state-tinted icons based on `PreviewServerController.State`. Hydration is gated on `AppBoot`.
- **`App/AppModel`** — `@Observable @MainActor`. Owns the `TemplateStore`, the `ProcessorStore`, the `templates` and `processors` `Choice` envelopes, the `PreviewServerController`, and `launchAtLogin` (via `LoginItem`). Renderer + template selection is read at request time via `@Sendable` closures, so switching processor/template in the menu takes effect on the next request without server restart.
- **`Menu/MenuBarContent`** — surfaces server state, the processor + template quick-switchers, BBEdit script installer entry, Settings, and Quit.
- **`Menu/SettingsView`** — preferences pane for launch-at-login + processor/template defaults. (Port is no longer user-configurable — the server binds to an OS-assigned port and writes it to `ServerPortFile`.)

## Concurrency conventions

- UI-facing state (`AppModel` in all three apps, `DocumentModel`, `WindowDispatcher`, `RecentDocumentsModel`, scene/per-file stores, `ServerStatusModel`) is `@MainActor`.
- The HTTP server runs in a background `Task`; route handlers are `async` and capture only `Sendable` collaborators (closures, actors, value types).
- Renderer + template selection is read at request time via `@Sendable` provider closures rather than via shared mutable state — there is no dedicated `CurrentRenderer` actor.
- The routing layer in `GalleyCoreKit/Routing/` is pure value types (`Sendable`); the `WindowDispatcher` adapter is the only place that holds live `NSWindow` references.
- `@ObservationIgnored` is used for collaborators that should not trigger view invalidation (watchers, bridges, server controller, stores keyed by ID, the dispatcher's NSWindow maps).
- Swift 6 strict concurrency is enabled; prefer typed throws, `Sendable` value types, and structured concurrency.

## Reference

- `docs/test-framework.md` — the test pyramid (routing logic / app logic / snapshot / UI / integration), where each kind of test goes, the launch-arg conventions for tests.

## Architecture decisions

### Three apps (incl. visionOS) sharing frameworks + shared sources

The codebase tried a single-bundle factoring (Viewer with embedded server, soft-quit, activation-policy switching) and reverted to two macOS apps sharing frameworks. Reasons the split won:
- Viewer wants `.regular` always; Server wants `MenuBarExtra`-only with `LSUIElement`. Reconciling those into one bundle required activation-policy juggling (soft-quit, `applicationWillFinishLaunching` policy restore, `applicationShouldHandleReopen` re-entry) — substantial complexity for the convenience of one bundle.
- Engine sharing is what actually matters, and the framework targets give that without forcing a single process model.

Adding a visionOS viewer (`Viewer.vision`) reused the same boundary: the platform-agnostic engine in `GalleyCoreKit`, the cross-platform per-window viewer code in `Sources/ViewerShared/`, and platform-specific bootstrap + chrome in the per-app directories. visionOS does not host the server, so it links only `GalleyCoreKit`.

### Frameworks not SwiftPM

The shared engine is two **Xcode framework targets** (`GalleyCoreKit`, `GalleyServerKit`), not a Swift Package. The earlier SwiftPM `Kit/` package was abandoned because `xcodebuild` test discovery for embedded local packages was unreliable while Xcode's GUI-driven test runs worked fine — a CI/scriptability liability the framework targets sidestep.

### ViewerShared is a source folder, not a framework

`Sources/ViewerShared/` is **not** a framework target. It's a `PBXFileSystemSynchronizedRootGroup` whose files are compiled directly into both `Viewer` and `Viewer.vision`. Reason: the shared code is platform-specific where it needs to be (`#if os(macOS)` for AppKit, editor opening, etc.) and gains nothing from being a separate binary. A framework would force a single platform deployment target per binary, which would force splitting visionOS-/macOS-specific bits into per-app stubs anyway. Doing it as a shared source folder keeps the `#if` boundaries inside one file.

### Hummingbird replaces FlyingFox

The HTTP server was originally FlyingFox. It was swapped for Hummingbird + HummingbirdTLS so the Server could present a self-signed certificate over HTTPS to local clients (Quicklook, the Viewer's WebPage, browsers). The Viewer pins the certificate via `PinnedCertificate` + `ServerCertificatePinner` so a MitM swap doesn't quietly succeed.

### OS-assigned port, not fixed

The server binds to `127.0.0.1` on an OS-assigned port; consumers find it via `ServerPortFile` (`~/Library/Application Support/net.leuski.galley.localized/server-port.json`). The user-configurable port setting is gone — fewer footguns when two processes try to listen on the same number.

### `WindowGroup<URL>` not `DocumentGroup`

`DocumentGroup(viewing:)` was the original choice and was abandoned. Two reasons: `DocumentGroup` ties one window to one `FileDocument` (titles, state restoration, revision history all assume "this window represents this file"), but the Viewer is a *navigator* — one window walks through linked Markdown documents (`a.md` → click link → `b.md` rebinds the window's URL). And `DocumentGroup` attaches the title-bar "document menu" hover popover, which is wrong for a read-only viewer.

### Why the `Window("welcome")` scene exists (and is invisible)

`WindowGroup(for: URL.self)` does **not** auto-spawn a window at cold launch when no URL is supplied. The `applicationShouldOpenUntitledFile` AppKit hook isn't bridged to value-driven `WindowGroup`s. With no view alive at launch, nothing captures `@Environment(\.openWindow)`, so URLs that arrive via Finder dispatch can't reach `openWindow(value:)` and never become document windows — the "first document doesn't open, only the second one does" bug.

The fix is a singleton `Window("welcome")` scene that auto-spawns at launch and hosts `WelcomeView`. Welcome's job is to capture `openWindow`, hand it to the `WindowDispatcher` via `install(_:)`, drain the launch buffer, and run the FTUE Open panel when there's nothing else to do. The window itself is invisible (alpha=0 + `ignoresMouseEvents` + `isExcludedFromWindowsMenu` + transient/ignoresCycle/stationary collection behavior).

On macOS 26 the welcome scene does **not** always mount when state restoration produced doc windows — so the `BootstrapDispatchModifier` is also attached to every doc window. Whichever view actually mounts wires the app up; `dispatcher.install(_:)` is idempotent.

### Why a (tiny) `ViewerAppDelegate` again

Through several iterations the Viewer ran with no `NSApplicationDelegateAdaptor` at all. macOS 12+ requires `applicationSupportsSecureRestorableState` to return `true` for AppKit to write the saved-state directory at quit; SwiftUI provides no scene-level way to declare it, and without it `WindowGroup<URL>` windows are silently lost on relaunch. `ViewerAppDelegate` exists for that one method. Routing state stays in `WindowDispatcher`, recents in `RecentDocumentsModel`. Don't reabsorb either into the AppDelegate.
