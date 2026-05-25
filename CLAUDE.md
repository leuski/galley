# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Two apps and a Quick Look extension sharing one rendering engine, with the Viewer app shipping on two platforms from a single target:

- **Galley** (bundle id `net.leuski.galley`, target `Viewer`, product `Galley`) — native document viewer. Same target builds for **macOS** (`macosx`) and **visionOS** (`xros` / `xrsimulator`); the project's `SUPPORTED_PLATFORMS` is `"macosx xros xrsimulator"`. Platform-specific code lives under per-platform subfolders (`Sources/Viewer/App/mac/` vs. `Sources/Viewer/App/vision/`, and the same `mac/` / `vision/` split inside `Models/`, `Views/`, `Utilities/`, `Resources/`); cross-platform code sits at the parent level and is compiled into both. macOS surface: `WindowGroup(for: URL.self)` over a `WebPage`-backed `WebView`, Cmd-click → editor, full menu bar, embedded Server, custom URL schemes (`x-galley://local` for template/asset resolution; `galley://<path>?line=N` for the BBEdit `Preview Markdown… → in Galley` script). visionOS surface: a single `WindowGroup(for: URL.self)` with `.fileImporter` for the empty case; no menus, no `WindowDispatcher`, no embedded Server; receives Mac-hosted documents via Kosmos (see Architecture decisions).
- **Galley Server** (bundle id `net.leuski.galley.server`, target `Server`, macOS) — `MenuBarExtra`-only app that runs a loopback HTTP server in-process so any local browser (or BBEdit's preview pane) can view the same documents Galley would render. Owns server lifecycle, port file, launch-at-login, the BBEdit helper-script installer, the Kosmos AVP bridge (`KosmosLink`), and the AVP HTTP tunnel responder (`HTTPTunnelMacHandler`). Galley.app embeds `Galley Server.app` inside its bundle and registers it as a user `LaunchAgent` (see `LaunchctlServerAgent` under `Sources/Viewer/Utilities/mac/`).
- **Quicklook** (target `Quicklook`, product `Quicklook.appex`, macOS) — `QLPreviewingController` extension. Tries the running Galley Server first so the user's chosen processor and template are honored; falls back to an in-process render with the built-in Swift renderer and bundled template when the server is unreachable.

The shared engine ships as two Xcode framework targets — `GalleyCoreKit` (rendering, templates, models, watch, scripts, networking-probe, scheme handler, routing value types, shared Kosmos surface, tunnel wire types) and `GalleyServerKit` (Hummingbird-backed loopback HTTP server). Both apps link `GalleyCoreKit`; `Server` also links `GalleyServerKit`; `Viewer` (macOS slice) links `GalleyServerKit` for the in-process Quicklook fallback path and the server probe types. Viewer's visionOS slice links only `GalleyCoreKit`. Kosmos (the Mac↔AVP bridge) is a sibling Swift package — `KosmosCore` + `KosmosTransport` are linked by `GalleyCoreKit` (so the shared `Sources/GalleyCoreKit/Kosmos/GalleyKosmos.swift` is the one definition of `GalleyKosmosRole`, `RouteToAVP`, `GalleyPeerClassifier`, etc., plus the `ProxyHTTPRequest` / `ProxyHTTPResponse*` tunnel messages). No HTTPS, no cert pinning, no `KosmosBridge` / `KosmosWebView` dependency — AVP renders Mac-hosted documents by tunneling each WebKit fetch back through Kosmos via the `galley://` scheme handler.

Localized strings live in `Localizable.xcstrings` per target. `Sources/Viewer/Resources/Localizable.xcstrings` is shared across the Viewer's macOS and visionOS slices. Server, GalleyCoreKit, GalleyServerKit, and Quicklook each have their own. English and Russian are shipped.

See `README.md` for HTTP routes, template placeholders, and BBEdit integration.

## Layout

```
Galley.xcodeproj              # 7 targets: GalleyCoreKit, GalleyServerKit, Server,
                              #            Quicklook, Viewer (macOS + visionOS),
                              #            Tests, UITests
Sources/
  GalleyCoreKit/              # framework — rendering, templates, watch, networking,
                              # scripts, shared models, routing
    Accessibility/              # ViewerA11yID, ServerA11yID — UI-test identifier catalogs
    Kosmos/                     # GalleyKosmos (shared role/deviceID/client factory,
                                # PeerInfo.galleyRole, GalleyPeerClassifier, RouteToAVP
                                # — public so Server and Viewer share one definition)
    Localizable.xcstrings       # localized strings owned by the kit
    Models/                     # ChoiceModel, ProcessorModel, TemplateModel
    Networking/                 # ServerProbe, ServerStatus
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
  GalleyServerKit/            # framework — Hummingbird loopback HTTP server, SSE
    PreviewServer.swift         # PreviewServerController (lifecycle + state)
    Routes.swift, SSE.swift, HTTPResponses.swift
    Resources/                  # bundled ErrorPage.html
    Localizable.xcstrings
  Viewer/                     # the Galley document app — single target,
                              # macOS + visionOS. Cross-platform code sits at the
                              # parent level; `mac/` and `vision/` subfolders hold
                              # platform-specific code that is itself wrapped in
                              # `#if os(macOS)` / `#if os(visionOS)` guards so the
                              # other platform's compile cleanly skips it.
    App/
      mac/                      # MacViewerApp.swift, ViewerAppDelegate.swift
      vision/                   # VisionViewerApp.swift, KosmosClient.swift
    Bridges/                    # cross-platform: LinkBridge, ScrollBridge,
                                # FindBridge, TOCBridge, StatsBridge,
                                # BackgroundColorBridge, EditorBridge
                                # (cmd-click → editor; AppKit side is macOS-only),
                                # (visionOS slice only adds the tunnel scheme
                                # handler and the HTTPTunnelAVPClient — both
                                # live in Sources/Viewer/App/vision/)
    Models/                     # cross-platform: AppModel, AppBoot, Defaults
                                # (@ObservableDefaults), BindPlan, ColorSchemeModel,
                                # DocumentModel + +History/+Notice/+Scroll/+Zoom/
                                # +Configuration/+Resolution/+Source, DocumentStats,
                                # FindSession, HistorySnapshot+JSON,
                                # PerFileStateStore, RecentDocumentsModel,
                                # SceneColorSchemeModel, SceneProcessorModel,
                                # SceneTemplateModel, SearchFieldModel,
                                # ServerStatusModel, Template+BackgroundColor
      mac/                      # DocumentModel+Print, EditorChoice, EditorPreset,
                                # WindowDispatcher
      vision/                   # DocumentModel+Export
    Utilities/
      mac/                      # ActiveServerAgent (swap point),
                                # LaunchctlServerAgent (active backend),
                                # ServerAgent (SMAppService alternative)
    Views/                      # cross-platform: Actions, Animation,
                                # AssortedViews, FindBar, FocusedValues,
                                # SearchField, StatusBar, TOCSidebar
      mac/                      # MacContentView, DocumentView, WelcomeView,
                                # HelpWindowView, BootstrapModifier,
                                # WindowAccessor, NewTabAction, ServerStatusPill,
                                # SettingsView
        Menus/                  # FileCommands, EditCommands, ViewCommands,
                                # FormatCommands, HelpCommands
        Settings/               # GeneralSettingsView, MarkdownSettingsView,
                                # ServerSettingsView
      vision/                   # VisionContentView, VisionSettingsView
    WebKit/                     # PreviewSchemeHandler — SwiftUI-flavored
                                # URLSchemeHandler for the Viewer's WebPage;
                                # delegates to GalleyCoreKit.PreviewScheme.resolve
    Resources/                  # cross-platform: AppIcon.icon, Assets.xcassets,
                                # Info.plist (shared bundle plist),
                                # Localizable.xcstrings, HelpDocs, Scripts,
                                # en.lproj, ru.lproj
      mac/                      # BBEditScripts.bundle, XCodeScripts.bundle,
                                # net.leuski.galley.server.plist (LaunchAgent template)
    Viewer.entitlements
  ViewerShared/               # (currently dormant — only an empty Resources/
                              # placeholder. The historical shared-source folder
                              # has been dissolved into Sources/Viewer/. Reserved
                              # for resources that may need to live outside the
                              # main bundle in the future.)
  Server/                     # the Galley Server menu-bar app (macOS)
    ServerApp.swift             # @main — single MenuBarExtra scene
    App/                        # AppModel (server-owning; holds TemplateStore /
                                # ProcessorStore choices, PreviewServerController,
                                # and the KosmosLink),
                                # KosmosLink (Kosmos host + AVP bridge,
                                # hosts the HTTPTunnelMacHandler),
                                # HTTPTunnelMacHandler (turns ProxyHTTPRequest
                                # → URLSession → ProxyHTTPResponseHead/Chunk),
                                # ServerAppDelegate (LSHandler — receives Finder
                                # opens + galley-bridge:// URLs)
    Menu/                       # MenuBarContent
    Resources/                  # AppIcon.icon, Assets.xcassets, Info.plist,
                                # Localizable.xcstrings, Server.entitlements
  Quicklook/                  # Quick Look preview extension (.appex, macOS)
    PreviewViewController.swift # QLPreviewingController — server-first, falls back
                                # to built-in render via ClassicPreviewSchemeHandler
    Info.plist, Quicklook.entitlements
    en.lproj, ru.lproj
Tests/                        # Swift Testing — kit + app-logic unit tests
  GalleyCoreKitTests/           # Placeholders, BuiltInTemplate, TemplateAssetRewriter,
                                # URLPathHelpers, SwiftMarkdownRenderer (incl. spec
                                # conformance), ChoiceObservation, ServerProbe,
                                # GalleyNetworkDefaults, GalleyAppHash, ClipboardRoundTrip
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

Pure Xcode project — **no top-level `Package.swift`**. Frameworks build inside the project; Kosmos is consumed as a sibling Swift package referenced from the project. New source files dropped into the per-target source directories (`Sources/Viewer/...`, `Sources/Server/...`, etc.) are picked up automatically — the project uses Xcode 16 filesystem-synchronized groups, so `Galley.xcodeproj/project.pbxproj` has no individual file references and **no manual registration is required** when adding a file. Files under `Sources/Viewer/.../mac/` and `.../vision/` are conditionally compiled — each file in those subfolders is wrapped in `#if os(macOS)` / `#if os(visionOS)` so the project's filesystem-synchronized membership compiles cleanly on both platforms.

Shared schemes:

- **Viewer** — the Galley document app; default destination is macOS, but the same scheme builds for visionOS by switching destination.
- **Server** — the menu-bar previewer
- **Quicklook** — the Quick Look preview extension
- **GalleyCoreKit** / **GalleyServerKit** — framework schemes (mostly for direct iteration / testing)
- Other sibling-package schemes from the Kosmos package may also surface in Galley's scheme list; only `KosmosCore` and `KosmosTransport` are linked by Galley.

There is no separate `Viewer.vision` scheme — the visionOS slice is the same scheme with a different destination.

**For routine macOS work, only build the Viewer scheme.** Galley.app embeds `Galley Server.app` as a bundle resource and `Quicklook.appex` as a foundation extension, so building Viewer builds the kits, the server, and the QuickLook extension in one pass. Building all three macOS schemes separately is pure waste — same compile work, three times the wall-clock cost. The same applies to `test` — the `Viewer` scheme's test action runs the unified `Tests` bundle that covers both kits and the macOS viewer app logic.

```bash
# Build everything macOS (Viewer + Server + Quicklook + both kits)
xcodebuild -project Galley.xcodeproj -scheme Viewer build

# Build the same Viewer target for visionOS
xcodebuild -project Galley.xcodeproj -scheme Viewer \
  -destination "generic/platform=visionOS" build

# Tests — one Xcode test bundle named `Tests` covering both kits + viewer
xcodebuild -project Galley.xcodeproj -scheme Viewer test
# (Or run from Xcode's Test navigator.)
```

Logic tests use **Swift Testing** (`@Test`, `#expect`); UI tests use **XCTest** (XCUITest is XCTest-based). The shared `TestPlan.xctestplan` enrols both targets. Logic coverage includes placeholder substitution, template rewriting, URL path helpers, the swift-markdown renderer (with a CommonMark-spec-conformance suite), the server probe / port file, the SSE encoder, host-header guarding, reload-script injection, template-origin policy, the HTTP-tunnel URL builder, the Kosmos tunnel scheme, and every routing-layer decision (`WindowRegistry`, `OpenURLRouter`, `URLNormalizer`, `LaunchURLBuffer`, `PendingScrollLines`, `LaunchArguments`). UI coverage exercises real product invariants — welcome stays hidden, FTUE Open panel surfaces on cold launch, seeded launches produce visible document windows, File/View menus reachable on a populated doc. See `docs/test-framework.md` for the test pyramid.

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

- **Hummingbird** (`github.com/hummingbird-project/hummingbird`) — loopback HTTP server. `GalleyServerKit` only. (Originally chosen with `HummingbirdTLS` for an HTTPS-to-AVP path; AVP now tunnels via Kosmos instead, so the HTTPS listener and its NIOSSL dependency are gone.)
- **swift-markdown** (`github.com/swiftlang/swift-markdown`) — bundled "Default" renderer.
- **swift-core-kit** (`github.com/leuski/swift-core-kit`, module `ALFoundation`) — **private** repo. CI authenticates via `GH_PACKAGES_PAT`; locally, ensure your git credentials can read it.
- **ObservableDefaults** (`github.com/fatbobman/ObservableDefaults`) — `@ObservableDefaults` macro backing the cross-platform `Sources/Viewer/Models/Defaults.swift`. `MacViewerApp.init` and `VisionViewerApp.init` both call `Defaults.warmCache()` before SwiftUI lays out a single view — see the long comment on `warmCache()` for the WebKit-triggered AttributeGraph reentrancy this defends against.
- **Kosmos** (sibling local package at `../Kosmos`, referenced from the project) — Mac↔AVP bridge. Only `KosmosCore` + `KosmosTransport` are linked, both via `GalleyCoreKit`, so Server and Viewer share one definition of the Galley-specific role enum / device-ID / `RouteToAVP` message and the `ProxyHTTPRequest` / `ProxyHTTPResponse*` tunnel messages. `KosmosBridge` and `KosmosWebView` are intentionally unused — there's no TLS in the data path and Kosmos handles peer identity / trust on its own channel. The trust provider in dev builds is `AlwaysTrustProvider`; `KosmosPairingProvider` (SAS-code pairing) is the planned production replacement.

External Markdown processors (MultiMarkdown, Pandoc, Discount, cmark-gfm, Markdown.pl) are invoked as subprocesses via `ExternalProcessRenderer` (macOS-only — the kit guards `Process` use behind `#if os(macOS)`).

## ALFoundation

`ALFoundation` (module of `swift-core-kit`) is the shared utility layer this project leans on heavily. **Before reimplementing anything filesystem-, URL-, process-, or watcher-related, check `ALFoundation` first.** Source lives at `/Users/leuski/Synced/General/Workbench-dev/swift-core-kit/Sources/ALFoundation/`.

What we actually use today:

| Area | API | In use at |
|---|---|---|
| URL path arithmetic | `url / "subpath"` | `MacViewerApp.swift`, `Template+Loader.swift`, `GalleyConstants.applicationSupportDirectory / filename` (AVPReachabilityFile) |
| URL helpers | `URL.itemExists`, `URL.parent`, `URL.createDirectory()`, `URL.isExecutable` | `MacViewerApp.swift`, `EditorPreset.swift`, `EditorChoice.swift`, `TemplateStore.swift`, `Template+Loader.swift`, `AVPReachabilityFile.swift`, `ExternalProcessRenderer.swift`, `Placeholders.swift` |
| Executable discovery | `try await URL(command: "pandoc")` | `ExternalProcessRenderer.discover` |
| Subprocess execution | `Process.runAndCapture(_:with:at:streams:)`, `Process.runAndReturn(...)`, `Process.run(...)`, `ProcessStreams.inMemory`, `ProcessArgument` | `ExternalProcessRenderer.swift`, `EditorChoice.swift`, `LaunchctlServerAgent.swift` |
| Force-unwrap with message | `expr !! "message"` | `URL+Galley.swift` (`bundleTemplatesDirectoryURL`) |
| File-system watching | `FileSystemObjectWatcher`, `FileSystemEventStream` | (available; `DocumentWatcher` is the kit's wrapper around FSEvents) |

**Rules:**

1. **Never call `Process()` / `process.run()` directly.** Use `Process.runAndCapture` or `Process.run` from ALFoundation. They return a `ProcessResult` with structured stdout/stderr and proper async termination.
2. **Never reach for `FileManager.default.createDirectory` or `FileManager.default.fileExists` when a `URL` is already in hand.** Use `url.createDirectory()` and `url.itemExists`. The expressions are shorter, the call sites stay consistent, and `createDirectory` makes intermediates automatically.
3. **Never build paths with `appendingPathComponent` chains.** Use the `/` operator: `dir / "subfolder" / "file.txt"`. `appendingPathComponent` is reserved for cases where the segment is dynamic and may be empty (rare).
4. **`!!` is preferred over `!` for force-unwraps**, when the unwrap is genuinely impossible-to-fail at runtime and a crash needs a descriptive message.
5. **For cross-process file dispatch between Galley.app and Galley Server.app, route by URL scheme, not by `NSWorkspace.shared.open(_:withApplicationAt:configuration:)`.** That API returns success (completion gets the target app's running PID with `error=nil`) but the URL is never delivered to the target's `application(_:open:)`. Observed live in both directions. Use the dedicated schemes instead:

  | Direction | Scheme | Builder / parser | Registered in |
  |---|---|---|---|
  | Server → Galley.app (e.g., "no AVP, surface file locally") | `galley://<path>` | `URL.galleyAction` | `Sources/Viewer/Resources/Info.plist` |
  | Galley.app → Server (e.g., "Show on Vision Pro") | `galley-bridge://<path>` | `BridgeURL.url(forFile:)` / `BridgeURL.fileURL(from:)` | `Sources/Server/Resources/Info.plist` |

  Server's `ServerAppDelegate.application(_:open:)` normalizes `galley-bridge://` URLs to file URLs before dispatching, so callers only need to construct the URL and invoke `NSWorkspace.shared.open(url)`. Do **not** shell out to `/usr/bin/open`.

## ObservableDefaults

All of Galley's own user preferences flow through **`@ObservableDefaults`** (from the `ObservableDefaults` Swift package, re-exported by `GalleyCoreKit/Utilities/GalleyDefaults.swift`). **Before adding `UserDefaults.standard.set(...)` / `.string(forKey:)` / `.bool(forKey:)` / etc. anywhere, stop and read the existing pattern.** The macro generates an `@Observable`-compatible class whose stored properties are persisted to a `UserDefaults` suite and re-read into a per-property cache on `UserDefaults.didChangeNotification` — that cache, plus the Darwin-notification bridge in `DefaultsBroadcast`, is what makes Viewer ↔ Server preference picks visible across processes in real time.

Where the pattern lives:

| File | Suite | Role |
|---|---|---|
| `Sources/Viewer/Models/Defaults.swift` | `UserDefaults.standard` (Viewer's bundle id `net.leuski.galley` *is* the suite) | Every Viewer-facing pref (renderer, template, `enablePerDocumentOverrides`, `openBehavior`, `perFileStateStore`, `templateBackgroundColors`, `lastTemplateBackgroundColor`, `tintWindowWithPageBackground`, `showsStatusBar`, `readingWordsPerMinute`, `editor` on macOS, `recentEntries` on visionOS, `colorScheme`, `serverGalleyHash`). Cross-platform. |
| `Sources/Server/App/AppModel.swift` (the `Defaults` class) | `UserDefaults(suiteName: "net.leuski.galley")` | The Server-side mirror — same plist as the Viewer; `renderer`, `template`, `serverGalleyHash`. |
| `Sources/GalleyCoreKit/Utilities/GalleyDefaults.swift` | — | `@_exported import ObservableDefaults`, `GalleyDefaults` + `GalleyRenderDefaults` protocols (`@MainActor static var shared: Self`), `GalleyConstants.suiteName`. |
| `Sources/GalleyCoreKit/Utilities/DefaultsBroadcast.swift` | — | Darwin-notification bridge → synthesizes a local `UserDefaults.didChangeNotification` so the other process's `@ObservableDefaults` observer fires. Call `DefaultsBroadcast.startListening()` once per process. |

**Rules:**

1. **Never read or write Galley's own preferences via `UserDefaults.standard` / `UserDefaults(suiteName:)` directly.** Go through `Defaults.shared` (Viewer or Server). New preference? Add a `@DefaultsKey var foo: T = default` on the appropriate `Defaults` class — the macro handles persistence, observation, change notification, and the per-property cache.
2. **Cross-process keys live in both `Defaults` classes.** If a key needs to be observed by both apps (renderer, template, server hash), declare it in both `Sources/Viewer/Models/Defaults.swift` and `Sources/Server/App/AppModel.swift`'s `Defaults`. Same key name, same type. The shared plist makes them one source of truth on disk; the two `Defaults` classes are the in-memory shape.
3. **Persistence wiring uses `bindPersistent`, not manual write-back.** The `ChoiceObservation` layer (`bindPersistent(choice, label:, property:)` in both AppModels) observes the choice envelope and writes back through the typed key path. Don't roll your own `didSet` → `UserDefaults` plumbing.
4. **`warmCache()` must run before any view exists.** Both `MacViewerApp.init` and `VisionViewerApp.init` call `Defaults.warmCache()` — see the long comment on `Defaults.warmCache()` for why (WebKit posts a synchronous `UserDefaults.didChangeNotification` from inside a SwiftUI layout pass on first `WKWebView.init`, which re-enters AttributeGraph if the macro's per-property cache isn't already populated). When adding a new app entry point, replicate the warm-cache call.
5. **Cross-process change propagation goes through `DefaultsBroadcast.startListening()`**, not through CFPreferences notifications. `UserDefaults.didChangeNotification` is process-local; `DefaultsBroadcast` posts a Darwin notification on write and synthesizes the local notification on receive. Call `startListening()` exactly once per process (Viewer's `AppModel.init` and Server's `AppModel.init` both do).
6. **Exceptions — only system-owned domains.** Reading non-Galley defaults that other apps or the OS own is fine: `AppleInterfaceStyle` in `Template+BackgroundColor.swift`, `com.apple.scriptmenu` in `EditorPreset.swift`. Anything under our suite goes through `Defaults`.

## Architecture

### Frameworks — shared engine

**`GalleyCoreKit`** — pure rendering and platform-agnostic primitives. No HTTP-server code:
- `Render/` — `MarkdownRenderer` protocol; `SwiftMarkdownRenderer` (with optional `annotatesSourceLines` that emits `data-source-line="N"` on every block, used by the Viewer for cmd-click→editor); `ExternalProcessRenderer` (shells out via `Process`, macOS-only); `ProcessorStore` exposes the ordered list of `Processor` rows (each with `installHint` and either a live `MarkdownRenderer` or `nil` if unavailable). The Viewer's cmd-click bridge also accepts pandoc's `data-pos` and cmark-gfm's `data-sourcepos` so source-line jumps work across renderers.
- `Templates/` — `Template` protocol; `BuiltInTemplate` and `UserTemplate`; `TemplateStore` watches `~/Library/Application Support/net.leuski.galley/Templates/` and accepts **two shapes** — a folder containing `Template.html`/`template.html` (Galley convention), or a top-level `*.html`/`*.htm` file with sibling assets (BBEdit preview-template convention). Built-in templates (Default, GitHub, HighContrast, LaTeX, Manuscript, Sepia, Solarized, Terminal, Tufte) ship in `Resources/Templates.bundle`. `Placeholders.swift` does `#TOKEN#` substitution (`#TITLE#`, `#DOCUMENT_CONTENT#`, `#BASE#`, `#FILE#`, `#BASENAME#`, `#FILE_EXTENSION#`, `#DATE#`, `#TIME#` — token names match BBEdit's). `UserTemplate.Rewriter` rewrites template-relative paths through `/template/<id>/...` and absolute filesystem paths through `/preview/<absolute-path>` so the resulting URLs resolve in either the HTTP server or the Viewer's scheme handler.
- `Networking/` — `ServerProbe` (async sequence that polls the running server), `ServerStatus` (reachable / unknown / down). Same-machine port discovery rides the shared `net.leuski.galley` defaults plist (`serverHTTPPort` / `serverEndpointURL` on `GalleyNetworkDefaults` in `Utilities/GalleyDefaults.swift`), not a handshake file.
- `WebKit/PreviewSchemeHandler.swift` — `PreviewScheme` enum with the `x-galley` scheme name + origin URL + the shared `resolve(...)` function. `ClassicPreviewSchemeHandler` (the `WKURLSchemeHandler` adapter, no SwiftUI dep) is here; the Viewer-visible SwiftUI-flavored `URLSchemeHandler` is in `Sources/Viewer/WebKit/PreviewSchemeHandler.swift` and delegates to the same resolver. Used by the Viewer's visible `WebPage`, the Viewer's offscreen print/export `WKWebView`, and the QuickLook extension's fallback render.
- `Models/` — `ChoiceValueProtocol` / `ChoiceValueEnvelopeProtocol` plus `ProcessorChoiceValue` and `TemplateChoiceValue`. A small generic layer for "pick one of N" UIs that also persist their selection by stable `persistentID`.
- `Routing/` — pure value types for the Viewer's URL routing. `OpenBehavior` (`.newWindow` / `.newTab` / `.replaceCurrent`); `WindowID` + `WindowIDAllocator` (counter-based opaque identity, intentionally *not* `ObjectIdentifier(NSWindow)`); `WindowRegistry` + `WindowRecord`; `LaunchURLBuffer` (FIFO buffer for URLs that arrive before `openWindow` is captured); `PendingScrollLines` (`galley://...?line=N` scroll-line cache); `URLNormalizer` (turns `galley://path?line=N` into a `(URL, scrollLine)` pair, recognizes `galley://settings` as a separate `Outcome` case); `OpenURLRouter` + `DispatchAction` (pure decision function returning `.queue` / `.openNew` / `.rebind(WindowID)` / `.tabOnto(WindowID)` / `.focusExisting(WindowID)`); `LaunchArguments` parser. The Viewer's `WindowDispatcher` (in `Sources/Viewer/Models/mac/`) is the AppKit interpreter that holds the live `NSWindow` references and applies the router's actions. The visionOS slice of the same Viewer target does not use `WindowDispatcher` and currently only borrows the value-type pieces (`OpenBehavior`, `WindowID`, `WindowRegistry`) for its smaller in-window dispatch.
- `Accessibility/` — `ViewerA11yID` / `ServerA11yID` enum-of-string-constants catalogs.
- `Kosmos/GalleyKosmos.swift` — single source of truth for the Galley-specific Kosmos surface that Server, Viewer, and tests all share: `GalleyKosmosRole` (server / mac-viewer / vision-viewer; published as `kosmos.role` Loom metadata), `loadOrMakeGalleyDeviceID(role:)`, `makeGalleyKosmosClient(role:deviceID:deviceName:)` (Loom-backed factory), `PeerInfo.galleyRole` extension, `GalleyPeerClassifier` (pure `serverPeer` / `avpPeer` helpers, unit-tested), and the `RouteToAVP` request/reply message. Was previously duplicated as `Sources/Server/App/GalleyKosmos.swift` + `Sources/Viewer/Bridges/GalleyKosmos.swift` — consolidated here so the two apps cannot drift in their wire contract.
- `Watch/DocumentWatcher` — file-system watch over a document and its sibling directory; multiplexes events to all subscribers.
- `Routes/PreviewRoute.swift` + `RouteNames.swift` — shared parser for `/template/<id>/<file>` and `/preview/<absolute-path>` paths. Used by both the Server's HTTP routes and the Viewer's `x-galley://` scheme handler.
- `Notifications/DisplacementNotifier` — surfaces a user-facing notice when a previously-persisted processor or template selection no longer exists in the live catalog.
- `Views/DividedSections` — shared SwiftUI helper for settings-style grouped sections.
- `Utilities/` — `MIMETypes`, `Bundle+Resources`, `String+URL`, `String+HTML`.
- `MarkdownFileTypes.swift` — list of recognized Markdown extensions, also used by open-panel UTI lists.

**`GalleyServerKit`** — wraps a `Hummingbird` HTTP server in a `Task`:
- `PreviewServer.swift` / `PreviewServerController` — lifecycle and state. Binds the HTTP listener to `127.0.0.1` on an **OS-assigned port** (no fixed port). The bound URL flows out via `state = .running(url:)`; the Server target's AppModel observes that and writes `Defaults.shared.serverHTTPPort` so other processes can find the port through the shared `net.leuski.galley` defaults plist. Loopback-only — AVP traffic doesn't reach this listener directly; the `HTTPTunnelMacHandler` (in `Sources/Server/App/`) proxies AVP requests through it on the AVP's behalf. Same-machine consumers (Mac Viewer, Quicklook, browsers, BBEdit scripts) hit the listener via `Defaults.shared.serverEndpointURL` (from `GalleyNetworkDefaults`).
- `Routes.swift` — `/preview/<path>` (Markdown→HTML, with placeholders + live-reload script injection; non-Markdown extensions fall through to static asset serving from the document's directory), `/template/<id>/<file>`, `/events/<path>` (SSE stream from `SSE.swift`). Host-header guarded (loopback-only).
- `rendererProvider` and `templateStore` are passed in as `@Sendable` closures so each request reads the current selection without server-side state.

### `Sources/Viewer/` — cross-platform viewer code (one target, two platforms)

The Viewer target builds for both macOS and visionOS. Code that doesn't care about the platform sits at the *parent* level inside `Sources/Viewer/...`; code that does sits inside a `mac/` or `vision/` subfolder *and* is wrapped in `#if os(macOS)` / `#if os(visionOS)` so the other platform's filesystem-synchronized compile cleanly skips it. Don't rely on folder-based membership exclusion — the `#if` guards are what's load-bearing.

Cross-platform pieces (the bulk of the viewer's behavior):

- `Models/DocumentModel.swift` plus `+History`, `+Notice`, `+Scroll`, `+Zoom`, `+Configuration`, `+Resolution`, `+Source` — per-document state, owned by each viewer window. Holds the `WebPage`, the bridges, the back/forward history (persisted via `@SceneStorage` as a `HistorySnapshot`), zoom + scroll persistence, the document-notice channel (banner shown over the WebView for ephemeral and render-bound errors), and the rendered-template box. A `Kind` enum (`.document` / `.help`) distinguishes the singleton Help window from real document windows so the help window skips the routing-registry handshake.
- `Models/AppModel.swift`, `Models/AppBoot.swift`, `Models/Defaults.swift` — app-level state hubs.
- `Models/BindPlan.swift` — pure decision type for "given a fileURL + persisted state, what should the next bind do?"
- `Models/DocumentStats.swift`, `Models/FindSession.swift`, `Models/SearchFieldModel.swift` — drive the StatusBar and FindBar.
- `Models/ColorSchemeModel.swift`, `Models/SceneColorSchemeModel.swift`, `Models/DocumentColorScheme.swift`, `Models/Template+BackgroundColor.swift` — color-scheme + per-template page-bg machinery.
- `Models/HistorySnapshot+JSON.swift`, `Models/PerFileStateStore.swift`, `Models/SceneProcessorModel.swift`, `Models/SceneTemplateModel.swift`, `Models/ServerStatusModel.swift`, `Models/RecentDocumentsModel.swift` — persistence + per-scene overrides + recents wrapping `NSDocumentController`.
- `Bridges/` — `WKScriptMessageHandler`s used by `DocumentModel`. `EditorBridge` (cmd-click → editor; the actual open-in-editor call is `#if os(macOS)`-gated), `LinkBridge` (`.md` family → in-window navigation; external HTTP → default browser/`openURL`; `finder://` → reveal-in-Finder on macOS), `ScrollBridge`, `FindBridge`, `TOCBridge`, `StatsBridge`, `BackgroundColorBridge`. visionOS-specific WebKit plumbing (the `galley://` scheme handler and the tunnel client) lives in `App/vision/`, not here.
- `Views/` — `Actions` (one source of truth for navigation/zoom/find/TOC/status-bar/etc. buttons, used by both menu and toolbar surfaces, with `.menuItem()` and `.toolbarItem(imageOnly:)` view-builders), `FindBar`, `TOCSidebar`, `StatusBar`, `SearchField`, `FocusedValues` (`\.documentModel` focused-scene key), `AssortedViews` (NoticeBanner etc.), `Animation`.
- `WebKit/PreviewSchemeHandler.swift` — SwiftUI-flavored `URLSchemeHandler` for the visible `WebPage`. Resolution delegates to `GalleyCoreKit.PreviewScheme.resolve` so the offscreen print web view and the QuickLook extension hit the same logic via `ClassicPreviewSchemeHandler`.

Platform-specific siblings live next door:

- `App/mac/` — `MacViewerApp` (`@main` for macOS), `ViewerAppDelegate` (one method — see Architecture decisions).
- `App/vision/` — `VisionViewerApp` (`@main` for visionOS), `KosmosClient` (peer-side bridge to the Mac Server).
- `Models/mac/` — `WindowDispatcher`, `DocumentModel+Print`, `EditorChoice`, `EditorPreset`.
- `Models/vision/` — `DocumentModel+Export`.
- `Views/mac/` — `MacContentView`, `DocumentView`, `WelcomeView`, `HelpWindowView`, `BootstrapModifier`, `WindowAccessor`, `NewTabAction`, `ServerStatusPill`, `SettingsView`, plus `Menus/` and `Settings/` subfolders.
- `Views/vision/` — `VisionContentView`, `VisionSettingsView`.
- `Utilities/mac/` — `ActiveServerAgent`, `LaunchctlServerAgent`, `ServerAgent`.
- `Resources/mac/` — BBEdit/Xcode script bundles, `net.leuski.galley.server.plist` (LaunchAgent template).

When adding a file: if it has any platform-specific use of AppKit / UIKit / RealityKit / AppleScript / etc., put it under the appropriate platform subfolder *and* wrap its body in `#if os(macOS)` or `#if os(visionOS)`. Otherwise place it at the parent level.

### Viewer macOS slice — `Sources/Viewer/*/mac/`

The macOS Viewer is **almost** pure SwiftUI. A minimal `ViewerAppDelegate` is reintroduced for a single hook — `applicationSupportsSecureRestorableState` — because without it, macOS 12+ refuses to write the saved-state directory and `WindowGroup<URL>` windows are silently lost on relaunch. SwiftUI provides no scene-level way to opt in. Everything else (routing state, recents, FTUE picker, URL receipt) lives in `@Observable @MainActor` types injected via `.environment()`. If a hook resurfaces that genuinely requires the AppDelegate, reintroduce a minimal one — don't reabsorb the routing state.

- **`App/mac/MacViewerApp`** — `@main` on macOS, four Scenes: `Window("welcome")` (always-spawning bootstrap anchor), `WindowGroup(for: URL.self)` driving `MacContentView`, `Window("help")` (singleton Help window), and `Settings`. The welcome scene has `.defaultLaunchBehavior(.presented)` and `.restorationBehavior(.disabled)`. `MacViewerApp.init` runs `Defaults.warmCache()`, parses `LaunchArguments`, pre-buffers any `--seed-file` URL into the dispatcher, and fires `ActiveServerAgent.validateAndRepair()` as a fire-and-forget Task (to detect and repair a stale absolute-path registration after the user moves Galley.app). Adds `FileCommands` (Open / Open Recent / Rename / Open in Editor / Print / Page Setup / Export as PDF), `EditCommands` (Find / Use Selection for Find / Find Next / Find Previous), `ViewCommands` (TOC / status-bar toggle / zoom / back/forward/reload), `FormatCommands` (renderer + template pickers), and `HelpCommands` (opens bundled help docs). No `MenuBarExtra` — that's the Server app's job.
- **`Models/Defaults`** (cross-platform, `@ObservableDefaults`) — UserDefaults-backed prefs. Persists `renderer`, `template`, `enablePerDocumentOverrides`, `openBehavior`, `editor`, `perFileStateStore`, `templateBackgroundColors`, `lastTemplateBackgroundColor`, `transparentToolbar`, `showsStatusBar`, `readingWordsPerMinute`. Keys without meaning on visionOS (`editor`, `transparentToolbar`) are still present but unused. `Defaults.warmCache()` posts a synchronous `UserDefaults.didChangeNotification` so the macro's per-property cache catches up to disk before the first WebKit-triggered notification arrives — otherwise `WKWebView.init` posts that notification synchronously from inside a SwiftUI layout pass, which re-enters AttributeGraph and crashes. The Server runs in a separate process and reads the same plist via `UserDefaults.standard` (since both apps share `net.leuski.galley` as the suite); `DefaultsBroadcast` translates Darwin notifications into local `didChangeNotification`s so cross-process writes propagate.
- **`Models/AppModel`** (cross-platform) — `@Observable @MainActor`. Single owner of Viewer-wide state: `templates: TemplateChoice`, `processors: ProcessorChoice`, `editors: EditorChoice` (macOS only — `DocumentModel.openInEditor` is `#if os(macOS)`-gated), `selectedSettingsTab` (Settings deep links land on the right pane). Constructed by `AppBoot` after `await ProcessorStore.shared.discover()`.
- **`Models/AppBoot`** (cross-platform) — `@Observable @MainActor`. Holds the `AppModel` once async hydration finishes; views branch on `boot.model` non-nil.
- **`Models/mac/WindowDispatcher`** — `@Observable @MainActor`. Routing state: `LaunchURLBuffer`, `WindowRegistry`, `PendingScrollLines`, `OpenURLRouter`, `WindowIDAllocator`, the `[ObjectIdentifier: WindowID]` map and reverse `[WindowID: NSWindow]` lookup, captured `openHandler`, captured `helpHandler` for the singleton Help window, `currentHelpURL`. Methods: `handleOpenURLs(_:onSettingsRequested:)`, `dispatch(_:)`, `register/unregister/updateCurrentURL`, `consumePendingScrollLine`, `consumePendingTabHost`, `install(_:)` (capture `openWindow` + drain buffer; idempotent — `BootstrapDispatchModifier` calls it from every doc window because macOS 26 sometimes skips mounting `Window("welcome")` when state restoration has already produced doc windows), `enqueueAtLaunch(_:)`, `hasAnyDocumentWindow()`, `openAsTabs(_:onto:)`. The pure routing decisions live in `GalleyCoreKit/Routing/`; this is the AppKit adapter.
- **`Models/RecentDocumentsModel`** — `@Observable @MainActor`. Wraps `NSDocumentController.shared.recentDocumentURLs`, runs `NSOpenPanel` for File > Open. `record(_:)` refuses bundle URLs so help docs never land in recents. Bound by `FileCommands`.
- **`Views/mac/MacContentView`** — boot-gated wrapper. While `AppBoot.model` is `nil` or the WindowGroup URL is `nil`, paints a `Color.clear` with a `BootWindowHider` that pins `window.alphaValue = 0` so the user never sees a pre-render flash. Once both inputs resolve, mounts `DocumentView` with non-optional inputs. Attaches `BootstrapDispatchModifier` so whichever scene mounts (welcome or doc) wires the dispatcher.
- **`Views/mac/DocumentView`** — the viewer surface for a populated doc window. Owns the `DocumentModel`, the rename alert / PDF-export-error alert state, the `@SceneStorage("history")` blob, the `WindowAccessor`-based `NSWindow` adoption with re-attach support (SwiftUI caches scene `@State` for a freshly-closed `WindowGroup<URL>` window and reuses it when the same URL is reopened — a naive nil-guard would turn the reopened tab into a floating, toolbar-less window). `kind: .help` skips dispatcher adoption and registry entry entirely.
- **`Views/mac/WelcomeView`** — content view for the singleton welcome window. Configures the host `NSWindow` to be invisible and non-interactive (`alphaValue = 0`, `ignoresMouseEvents = true`, `isExcludedFromWindowsMenu = true`, `collectionBehavior = [.transient, .ignoresCycle, .stationary]`). The view's `.task` waits on `boot.model`, then runs the FTUE Open panel via `recents.runOpenPanel()` when no doc windows came back from state restoration.
- **`Views/mac/HelpWindowView`** — content view for the singleton `Window("help")` scene. Reads `dispatcher.currentHelpURL` and mounts `DocumentView` in `.help` mode.
- **`Views/mac/BootstrapModifier`** — `BootstrapDispatchModifier`. Attaches to **both** welcome AND every doc window — whichever view actually mounts wires `dispatcher.install(_:)`, drains the buffer, and hosts `.onOpenURL { dispatcher.handleOpenURLs(...) }`. macOS 26 / SwiftUI does not always spawn `Window("welcome")` at launch when state restoration produced doc windows.
- **`Views/mac/NewTabAction`** — the static `NewTabAction.handler` is wired from `MacViewerApp.configureRouting()` to run the Open panel and `dispatcher.openAsTabs(picks, onto: source)` so the tab bar "+" merges picks as tabs onto the source window.
- **`Views/mac/Settings/`** — three panes (`GeneralSettingsView`, `MarkdownSettingsView`, `ServerSettingsView`) selected by `appModel.selectedSettingsTab`. Server pane drives `ActiveServerAgent` + a `ServerStatusPill` powered by `ServerStatusModel`.
- **`Views/mac/Menus/`** — split per command group: `FileCommands`, `EditCommands`, `ViewCommands`, `FormatCommands`, `HelpCommands`. All bind through `@FocusedValue(\.documentModel)` and `Action.*` so behavior stays consistent with the toolbar.
- **`Utilities/mac/ActiveServerAgent`** — single swap point for the server-agent backend. The live backend is `LaunchctlServerAgent` (classic `~/Library/LaunchAgents/net.leuski.galley.server.plist`). The Apple-blessed `SMAppService` alternative (`ServerAgent`) is kept as a sibling for reference but is **not** the active backend on local builds: `SMAppService`-spawned helpers go through AMFI's launch-constraint check, which rejects ad-hoc-signed binaries with `Launch Constraint Violation` and (combined with `KeepAlive`) can respawn-loop. The active backend writes the plist with no `KeepAlive` and runs `validateAndRepair()` at launch to rewrite a stale absolute `Program` path if Galley.app has moved.
- **`Models/mac/DocumentModel+Print`** — three entry points (Print, Page Setup, Export as PDF) share one offscreen `WKWebView` path configured with `ClassicPreviewSchemeHandler`. Two non-obvious bits: `printInfo.horizontalPagination` / `verticalPagination` must be `.automatic` (otherwise the whole document prints onto a single tall page), and the operation must be dispatched via `runModal(for:delegate:didRun:contextInfo:)` — `runOperation()` produces blank pages.
- **Window visibility** — document windows open with `alphaValue = 0` and unhide on first non-nil `documentURL`. Welcome stays at `alphaValue = 0` for its entire lifetime.
- **Sandbox is disabled** on the Viewer target (both platform slices). The Server target is also unsandboxed — it needs to read arbitrary user files to render them.

### Viewer visionOS slice — `Sources/Viewer/*/vision/`

Far smaller surface than the macOS slice. No AppDelegate, no welcome bootstrap scene, no `LaunchArguments` parsing, no `WindowDispatcher` (every URL arrives via `WindowGroup<URL?>`'s value binding, or via Kosmos `OpenDocument`). No menus. No external editor. No hosted server. Shares every cross-platform model (`DocumentModel`, `AppModel`, `AppBoot`, `Defaults`, `PerFileStateStore`, `SceneProcessorModel`, `SceneTemplateModel`, `ServerStatusModel`) and every cross-platform view (`Actions`, `FindBar`, `TOCSidebar`, `StatusBar`) with the macOS slice.

- **`App/vision/VisionViewerApp`** — `@main` on visionOS, single `WindowGroup(for: URL.self)`. `init()` runs `Defaults.warmCache()` for the same WebKit-reentrancy reason as the macOS slice. Wires the `KosmosClient` so AVP can receive `OpenDocument` messages from the Mac-side Server.
- **`App/vision/KosmosVisionService`** — peer-side bridge. Long-lived `KosmosClient` from `KosmosTransport`; receives `OpenURL`, `OpenDocument` (carrying just `documentPath`), `WindowContentChanged`; routes inbound `ProxyHTTPResponseHead` / `ProxyHTTPResponseChunk` to the `HTTPTunnelAVPClient`; sends `CloseWindow` and lifecycle (`AppDidResume` / `AppWillSuspend`). No cert pinning — AVP doesn't dial HTTPS anywhere; document and sub-resource bytes ride Kosmos via the `galley://` scheme handler.
- **`App/vision/HTTPTunnelAVPClient`** + **`KosmosTunnelSchemeHandler`** — every `galley://preview/<path>` URL the WebView fetches becomes a `ProxyHTTPRequest` Kosmos broadcast; response chunks stream back as `ProxyHTTPResponseChunk` messages and are reassembled per-request in the client's `requestID → continuation` map. WebKit cancellation publishes a `ProxyHTTPCancel` so the Mac drops the upstream `URLSession` task.
- **`Models/Defaults`** (shared with macOS) — the keys that have meaning on visionOS are `renderer`, `template`, `enablePerDocumentOverrides`, `perFileStateStore`, `templateBackgroundColors`, `lastTemplateBackgroundColor`, `showsStatusBar`, `readingWordsPerMinute`. macOS-only keys (`editor`, `openBehavior`, `transparentToolbar`) are present in the struct but unused on visionOS. `enablePerDocumentOverrides` is read by the shared `DocumentModel.resolvedRenderer` / `resolvedTemplate`; stays `false` for v1.
- **`Models/AppBoot`** (shared) — on visionOS the `ProcessorStore.shared.discover()` call returns the built-in renderer only, since external CLI processors are unreachable.
- **`Models/vision/DocumentModel+Export`** — visionOS-specific export plumbing.
- **`Views/vision/VisionContentView`** — boot gate. Three states: progress spinner while `boot.model` is nil; a Welcome screen with an "Open Document…" button driving `.fileImporter` (visionOS-native Files.app picker) when the WindowGroup binding has no URL; a document screen with a `NavigationSplitView` (TOC sidebar + WebView with FindBar + StatusBar) and a toolbar of `Action.*` buttons when both are ready.
- **`Views/vision/VisionSettingsView`** — visionOS settings surface.

### `Sources/Server/` — Galley Server menu-bar app (macOS)

- **`ServerApp`** — `@main`, single Scene: `MenuBarExtra` hosting `MenuBarContent`. Label is `Image("MenuBarIcon")`. Uses `@NSApplicationDelegateAdaptor(ServerAppDelegate.self)`. Hydration is gated on `AppBoot` (the menu shows "Starting…" until the model resolves). The Server does not host a SwiftUI `Settings` scene of its own — preferences are surfaced inside `MenuBarContent`.
- **`App/AppModel`** — `@Observable @MainActor`. Owns the `templates: TemplateChoice` and `processors: ProcessorChoice` envelopes, the `PreviewServerController`, and the `KosmosLink`. Renderer + template selection is read at request time via `@Sendable` closures, so switching processor/template in the menu takes effect on the next request without server restart.
- **`App/ServerAppDelegate`** — `NSApplicationDelegate`. Receives Finder file opens and `galley-bridge://` URL opens, dispatches each to AVP via `KosmosLink.dispatchOpenURLToAVP(_:)` first; on `false` (no AVP), falls back to `NSWorkspace.open(galley://path)` to launch Galley.app.
- **`App/KosmosLink`** — `@Observable @MainActor`. Long-lived `KosmosClient` from `KosmosTransport`. Owns the Kosmos AVP session, the per-window open-on-AVP registry (`KosmosCore.WindowID → fileURL + watchTask`), the AVP-reachability flag (peer-connected ∧ app-resumed), and the AVP-doff migration path (peer disconnect → `NSWorkspace.open(galley://path)` per open window). Hosts the `HTTPTunnelMacHandler` that turns inbound `ProxyHTTPRequest` messages into `URLSession` data tasks against the loopback HTTP listener and streams `ProxyHTTPResponseHead` + chunked `ProxyHTTPResponseChunk`s back. The preview server stays loopback-only at all times.
- **`App/HTTPTunnelMacHandler`** — owns the in-flight `requestID → Task` map for tunneled requests. Each `ProxyHTTPRequest` opens a `URLSession.bytes(for:)` against the loopback base URL; bytes accumulate into ~64 KB chunks and broadcast as `ProxyHTTPResponseChunk`s; `ProxyHTTPCancel` cancels the matching task. SSE streams (`/events/<path>`) never produce an `isFinal: true` until the requester cancels — the `URLSession` data task simply stays alive and forwards each newline-delimited event as it arrives.
- **`Menu/MenuBarContent`** — the entirety of the Server's UI: server state, processor + template quick-switchers, BBEdit script installer entry, a Settings entry, and Quit.

## Concurrency conventions

- UI-facing state (`AppModel` in both Viewer and Server, `DocumentModel`, `WindowDispatcher`, `KosmosLink`, `KosmosClient`, `RecentDocumentsModel`, scene/per-file stores, `ServerStatusModel`) is `@MainActor`.
- The HTTP server runs in a background `Task`; route handlers are `async` and capture only `Sendable` collaborators (closures, actors, value types).
- Renderer + template selection is read at request time via `@Sendable` provider closures rather than via shared mutable state — there is no dedicated `CurrentRenderer` actor.
- The routing layer in `GalleyCoreKit/Routing/` is pure value types (`Sendable`); the `WindowDispatcher` adapter is the only place that holds live `NSWindow` references.
- `@ObservationIgnored` is used for collaborators that should not trigger view invalidation (watchers, bridges, server controller, stores keyed by ID, the dispatcher's NSWindow maps).
- Swift 6 strict concurrency is enabled; prefer typed throws, `Sendable` value types, and structured concurrency.

## Reference

- `docs/test-framework.md` — the test pyramid (routing logic / app logic / snapshot / UI / integration), where each kind of test goes, the launch-arg conventions for tests.

## Architecture decisions

### Two apps sharing frameworks; Viewer is one target on two platforms

The codebase tried a single-bundle factoring (Viewer with embedded server, soft-quit, activation-policy switching) and reverted to two macOS apps sharing frameworks. Reasons the split won:
- Viewer wants `.regular` always; Server wants `MenuBarExtra`-only with `LSUIElement`. Reconciling those into one bundle required activation-policy juggling (soft-quit, `applicationWillFinishLaunching` policy restore, `applicationShouldHandleReopen` re-entry) — substantial complexity for the convenience of one bundle.
- Engine sharing is what actually matters, and the framework targets give that without forcing a single process model.

Adding a visionOS Viewer did *not* introduce a third target. The same `Viewer` target builds for `macosx` and `xros/xrsimulator`; platform-specific code lives in `mac/` and `vision/` subfolders and is wrapped in `#if os(macOS)` / `#if os(visionOS)` guards. The visionOS slice links only `GalleyCoreKit`; the macOS slice additionally links `GalleyServerKit` (for the Quicklook-fallback path and the server probe).

### Frameworks not SwiftPM

The shared engine is two **Xcode framework targets** (`GalleyCoreKit`, `GalleyServerKit`), not a Swift Package. The earlier SwiftPM `Kit/` package was abandoned because `xcodebuild` test discovery for embedded local packages was unreliable while Xcode's GUI-driven test runs worked fine — a CI/scriptability liability the framework targets sidestep.

### Single Viewer target, two platforms, `mac/` and `vision/` subfolders

Earlier iterations had a separate `Sources/ViewerShared/` source folder compiled into both a `Viewer` (macOS) and a `Viewer.vision` (visionOS) target. That factoring is gone. There is now one `Viewer` target with `SUPPORTED_PLATFORMS = "macosx xros xrsimulator"`, and platform-specific files live alongside cross-platform ones in `mac/` and `vision/` sibling subfolders (under `App/`, `Models/`, `Views/`, `Utilities/`, `Resources/`).

Reasons for the consolidation:

- A separate target paid for an `Info.plist` membership-exclusion dance and a duplicated entitlements/codesign setup. One target, one Info.plist, one entitlement file is just less moving stuff.
- The `mac/` / `vision/` convention plus `#if os(macOS)` / `#if os(visionOS)` body guards keep the platform fences inside a single file and a single target. The folder name is documentation; the `#if` is what's load-bearing — files in `mac/` still ship to the visionOS slice's compile, they just produce nothing when guarded properly. Don't rely on folder-based membership exclusion.
- Cross-platform code (`DocumentModel`, `AppModel`, `AppBoot`, `Defaults`, `Bridges/`, `Views/Actions.swift`, `FindBar`, `TOCSidebar`, `StatusBar`, etc.) sits at the parent level inside `Sources/Viewer/...` and is shared automatically.
- A vestigial `Sources/ViewerShared/` directory remains (currently holding only an empty `Resources/`); it's not load-bearing today but is kept reserved.

When adding a file: cross-platform → parent directory; platform-specific → `mac/` or `vision/` subfolder *and* `#if` guard the body.

### Hummingbird replaces FlyingFox

The HTTP server was originally FlyingFox. It was swapped for Hummingbird (briefly with `HummingbirdTLS`) so the Server could present a self-signed certificate over HTTPS to AVP. That HTTPS path is gone — AVP now tunnels every WebKit fetch back through Kosmos via `ProxyHTTPRequest`, and the Mac runs a single loopback HTTP listener for every consumer (Mac Viewer, Quicklook, BBEdit, browsers, and the AVP tunnel responder).

### OS-assigned port, not fixed

The loopback HTTP listener binds to `127.0.0.1` on an OS-assigned port; the port is published to the shared `net.leuski.galley` defaults plist under `serverHTTPPort`. Same-machine readers (Quicklook, future Viewer surface) compose the URL via `Defaults.shared.serverEndpointURL` from `GalleyNetworkDefaults`. The user-configurable port setting is gone — fewer footguns when two processes try to listen on the same number.

### `WindowGroup<URL>` not `DocumentGroup`

`DocumentGroup(viewing:)` was the original choice and was abandoned. Two reasons: `DocumentGroup` ties one window to one `FileDocument` (titles, state restoration, revision history all assume "this window represents this file"), but the Viewer is a *navigator* — one window walks through linked Markdown documents (`a.md` → click link → `b.md` rebinds the window's URL). And `DocumentGroup` attaches the title-bar "document menu" hover popover, which is wrong for a read-only viewer.

### Why the `Window("welcome")` scene exists (and is invisible)

`WindowGroup(for: URL.self)` does **not** auto-spawn a window at cold launch when no URL is supplied. The `applicationShouldOpenUntitledFile` AppKit hook isn't bridged to value-driven `WindowGroup`s. With no view alive at launch, nothing captures `@Environment(\.openWindow)`, so URLs that arrive via Finder dispatch can't reach `openWindow(value:)` and never become document windows — the "first document doesn't open, only the second one does" bug.

The fix is a singleton `Window("welcome")` scene that auto-spawns at launch and hosts `WelcomeView`. Welcome's job is to capture `openWindow`, hand it to the `WindowDispatcher` via `install(_:)`, drain the launch buffer, and run the FTUE Open panel when there's nothing else to do. The window itself is invisible (alpha=0 + `ignoresMouseEvents` + `isExcludedFromWindowsMenu` + transient/ignoresCycle/stationary collection behavior).

On macOS 26 the welcome scene does **not** always mount when state restoration produced doc windows — so the `BootstrapDispatchModifier` is also attached to every doc window. Whichever view actually mounts wires the app up; `dispatcher.install(_:)` is idempotent.

### Why a (tiny) `ViewerAppDelegate` again

Through several iterations the Viewer ran with no `NSApplicationDelegateAdaptor` at all. macOS 12+ requires `applicationSupportsSecureRestorableState` to return `true` for AppKit to write the saved-state directory at quit; SwiftUI provides no scene-level way to declare it, and without it `WindowGroup<URL>` windows are silently lost on relaunch. `ViewerAppDelegate` exists for that one method. Routing state stays in `WindowDispatcher`, recents in `RecentDocumentsModel`. Don't reabsorb either into the AppDelegate.

### Server is the AVP routing authority; all three runtimes are Kosmos peers

The Vision Pro path looks like it could live in Galley.app — the Viewer is the user-facing surface, the Viewer already renders Markdown, the Viewer is what you'd guess from the outside. It doesn't. The Server is the AVP routing authority. Three requirements drive that:

1. **Open-document routing has to decide before any Mac window exists.** When Finder opens `foo.md`, the system needs an authority that can answer "is AVP paired right now? If yes, push to AVP. If no, route to Galley.app." Galley.app is `.regular` — Dock icon, document-app semantics, state restoration, heavy launch. Spawning it just to ask "is AVP here?" defeats the whole point. The Server is already `LSUIElement` / `MenuBarExtra` and is the persistent always-on process in this system (typically launch-at-login). So the Server is the `LSHandler` for `.md` and for the routing-aware URL scheme, and decides where the document goes.

2. **Live reload to AVP must come from the peer owner.** Whoever holds the Kosmos peer to AVP has to own the file watch — two processes racing on FSEvents with one pushing reloads the other doesn't know about is a bug factory. The Server already runs `DocumentWatcher` for HTTP SSE live-reload subscribers; AVP is just another subscriber on the same watch.

3. **Take-off-AVP handoff requires the routing authority to launch Galley.app.** When the user removes the headset, the docs currently on AVP should come up in Galley.app. The Server sees the AVP peer disconnect (via Kosmos), knows the set of docs currently displayed on AVP, and launches Galley.app via `NSWorkspace.open(galley://path)` for each. Galley.app being launched-on-demand (not always-on) depends on the Server being the entity that observes the disconnect and triggers the launch.

#### Kosmos carries both planes; HTTP loopback is same-machine only

All three runtimes — Server, Galley.app (Mac Viewer), and the AVP viewer — are **Kosmos peers**. There is no file-based handshake, no Mac-local IPC channel, no "ask the Server whether AVP is paired" RPC. Presence and routing both ride Kosmos. The cost is the Kosmos stack in Galley.app's and AVP's address spaces; the win is one protocol for control on the wire instead of three.

The data plane split, in two cases:

- **Same-machine consumers** (Mac Viewer, Quicklook, browsers, BBEdit scripts) hit the Server's loopback HTTP listener via `Defaults.shared.serverEndpointURL` (`GalleyNetworkDefaults`). The port lives in the shared `net.leuski.galley` defaults plist; Quicklook reads it through its own `Defaults` class plus the suite's `shared-preference.read-only` entitlement; BBEdit scripts read it via `defaults read net.leuski.galley serverHTTPPort`. No TLS, no pinning — `127.0.0.1` is its own trust boundary.
- **AVP** tunnels through Kosmos. The WebView is configured with a `galley://` URL scheme handler (`KosmosTunnelSchemeHandler`); every request — the document, every CSS / JS / image / font, the SSE `/events/<path>` stream — becomes a `ProxyHTTPRequest` Kosmos broadcast, executed against the Mac's loopback listener by `HTTPTunnelMacHandler`, and streamed back as `ProxyHTTPResponseHead` + chunked `ProxyHTTPResponseChunk` messages. No HTTPS over the LAN, no cert pinning, no AWDL ingress concerns.

Same `/preview/<path>` + `/events/<path>` route surface either way; only the data-plane transport differs.

The Mac Viewer's Kosmos role is intentionally narrow: **peer presence** for two UI gates (the Server-status pill and the "Show on Vision Pro" menu item) and a single outbound message — `RouteToAVP { filepath }` — when the user explicitly picks "Show on Vision Pro." It does not construct `OpenDocument` itself; it does not own dispatch state.

The AVP viewer's Kosmos role is similarly narrow: receive `OpenDocument` messages, run the HTTP tunnel client, and react to peer-presence changes (e.g., reflect Server-reachable state in the UI). **AVP is not a thin shell** — it renders its own local files (chosen via the in-window `.fileImporter`) using the same `SwiftMarkdownRenderer` + bundled templates as Mac Viewer's local-file path. Kosmos integration is additive: AVP gains an additional entry point for Mac-hosted documents without giving up its standalone rendering ability.

Routing authority stays with the Server. Dispatch state (`docID` assignment, peer addressing, tunneled-request bookkeeping) stays with the Server. Other peers ask; the Server constructs and sends.

#### URL schemes are directional and survive the unification

External integrations (BBEdit's `Preview Markdown… → in Galley` script, Xcode helper scripts) already produce `galley://` URLs targeting Galley.app. That contract is preserved.

| Scheme | LSHandler | Semantics |
|---|---|---|
| `galley://<path>` | Galley.app (Mac Viewer) | Direct open in Mac Viewer. Forced-Mac. The contract external integrators have today. |
| `galley-bridge://<path>` | Server | Public routing-aware scheme. Server picks AVP-or-Mac. Use this when the caller wants "wherever's best." |

`galley-bridge://` was previously a Viewer→Server back-channel and has been promoted to the public routing scheme. Do not collapse the two — they encode different caller intent. Changing `galley://` to mean "maybe AVP" would silently break BBEdit / Xcode integrations.

#### Transport matrix

| Trigger | Path |
|---|---|
| Finder opens `.md` | Server (LSHandler) → AVP via Kosmos `OpenDocument`, else `NSWorkspace.open(galley://path)` to Mac Viewer |
| External `galley-bridge://path` | Server → routes same as above |
| External `galley://path` | Mac Viewer direct (existing contract) |
| Mac Viewer menu: "Show on Vision Pro" | Mac Viewer → Server via Kosmos `RouteToAVP { filepath }` → Server constructs `OpenDocument` → AVP via Kosmos |
| AVP-local `.fileImporter` open | AVP renders locally via `SwiftMarkdownRenderer` + bundled template. No Kosmos, no Server. |
| AVP take-off handoff | Server observes AVP peer drop → `NSWorkspace.open(galley://path)` per active doc |
| Server status pill in Mac Viewer | Reads Server peer presence via Kosmos (was: HTTP probe) |
| "Show on Vision Pro" menu enabledness | Reads AVP peer presence via Kosmos (was: `AVPReachabilityFile`) |
| Mac-doc HTML / assets / live reload to AVP | Kosmos tunnel. WebKit's `galley://preview/<path>` request → `KosmosTunnelSchemeHandler` → `ProxyHTTPRequest` → `HTTPTunnelMacHandler` → loopback HTTP → response chunks back via `ProxyHTTPResponseHead` + `ProxyHTTPResponseChunk` messages. Same `/preview/<path>` + `/events/<path>` route surface as same-machine HTTP loopback; SSE stays alive until `ProxyHTTPCancel`. |
| Mac-doc HTML / assets / live reload to Mac Viewer / Quicklook | HTTP loopback (`http://127.0.0.1:<port>/`). No pinning. |

#### Kosmos message inventory

Two surfaces — control and the HTTP tunnel data plane.

**Control plane:**

| Message | Sender → Receiver | Purpose |
|---|---|---|
| `OpenDocument { docID, documentPath, displayName, scrollLineHint?, openBehavior }` | Server → AVP | Open or re-target an AVP window for a Server-hosted doc. AVP synthesizes the `galley://preview/<path>` URL itself; bytes ride the tunnel. |
| `RouteToAVP { filepath }` | Mac Viewer → Server | "User chose Show on Vision Pro — please dispatch this file." Server constructs and sends the `OpenDocument`. |
| `WindowContentChanged { windowID }` | Server → AVP | The file behind the named AVP window changed (FSEvents); receiver reloads its WebView. |
| `CloseWindow { windowID }` | AVP → Server | User closed an AVP-side document window; Server drops its tracking entry and cancels the file watcher. |
| `AppWillSuspend` / `AppDidResume` | AVP → Server | `scenePhase` transitions on AVP. Mac gates `isAVPReachable` on the most recent of these so dispatch doesn't land in a suspended process. |

**Data plane (HTTP tunnel):**

| Message | Sender → Receiver | Purpose |
|---|---|---|
| `ProxyHTTPRequest { requestID, method, urlPath, headers, body }` | AVP → Server | A WebKit fetch on `galley://preview/<path>`; the receiver issues a `URLSession` task against the loopback HTTP listener. |
| `ProxyHTTPResponseHead { requestID, status, headers }` | Server → AVP | HTTP status + headers for an in-flight tunneled request. |
| `ProxyHTTPResponseChunk { requestID, sequence, bytes, isFinal }` | Server → AVP | Body bytes; multiple per request. `isFinal: true` ends the stream. SSE never sets `isFinal` until the requester cancels. |
| `ProxyHTTPCancel { requestID }` | AVP → Server | WebKit cancelled or page navigated away; drop the matching upstream task. |

Adding to either list is a smell. `DocumentWatcher` still tracks SSE subscribers and drops files when the last subscriber disconnects — when AVP closes a `WebPage`, the scheme handler cancels its `URLSchemeTask`, the tunnel emits `ProxyHTTPCancel`, the Mac drops the `URLSession` task, and the watcher cleans up.

#### Routing layer reuse on AVP

The pure value types in `GalleyCoreKit/Routing/` (`OpenBehavior`, `WindowID`, `WindowRegistry`, `WindowRecord`, `WindowIDAllocator`) are platform-agnostic and reused by AVP. AVP does not get a full `WindowDispatcher` — there is no `Window("welcome")` bootstrap dance, no `LaunchURLBuffer`, no tab merging, no `replaceCurrent`-onto-an-NSWindow. But AVP does get a much smaller dispatcher that consumes inbound `OpenDocument` messages, looks up `docID` in a `WindowRegistry`, applies the message's `openBehavior` (currently `.newWindow` or `.replaceCurrent`; `.newTab` is not on the visionOS roadmap yet but isn't excluded by the type system), and produces a `WindowGroup<URL?>` value-change for SwiftUI to honor.

#### Why Server→Mac Viewer stays on `NSWorkspace.open(galley://)`, not Kosmos

Kosmos can only message **running** peers — it cannot spawn a process. The Server-to-Mac-Viewer path needs to launch-or-wake Galley.app and deliver the URL atomically; LaunchServices does that in one shot. Using Kosmos would require a separate launch step followed by waiting for the new peer to register before sending, splitting one operation into a race. The URL-scheme path also keeps cold-launch and warm-launch on the same code path.

#### What is intentionally separate from this layer

- **The Server's HTTP listener** is its own surface for browsers and Quicklook. The Server-status pill in Mac Viewer reports peer presence (the better signal); if you ever need to distinguish "process up, HTTP wedged" from "process up, HTTP fine," do it with a Kosmos-level health ping, not by reintroducing an HTTP probe from inside the same machine.

#### Do not undo this

When tempted to:

- move Kosmos into Galley.app and let it be the routing authority — re-read requirements (1) and (3);
- add a second IPC seam (file, RPC, XPC) for "the one signal Mac Viewer needs from Server" — that's how the previous design accreted; Kosmos peer presence already answers it;
- merge `galley://` and `galley-bridge://` into one scheme — you will silently change the semantics of every existing BBEdit / Xcode integration.
