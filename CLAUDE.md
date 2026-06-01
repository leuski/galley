# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Two apps and a Quick Look extension sharing one rendering engine, with the Viewer app shipping on two platforms from a single target:

- **Galley** (bundle id `net.leuski.galley`, target `Viewer`, product `Galley`) — native document viewer. Same target builds for **macOS** (`macosx`) and **visionOS** (`xros` / `xrsimulator`); the project's `SUPPORTED_PLATFORMS` is `"macosx xros xrsimulator"`. Platform-specific code lives under per-platform subfolders (`Sources/Viewer/UI/mac/` vs. `Sources/Viewer/UI/vision/`, and the same `mac/` / `vision/` split inside `Models/`, `Utilities/`, `Resources/`; the Viewer's app entry points + scenes live under `UI/mac/Scenes/` and `UI/vision/Scenes/`); cross-platform code sits at the parent level and is compiled into both. macOS surface: `WindowGroup(for: DocumentTarget.self)` over a `WebPage`-backed `WebView`, Cmd-click → editor, full menu bar, embedded Server, custom URL schemes (`x-galley://local` for template/asset resolution; `galley://<path>?line=N` for the BBEdit `Preview Markdown… → in Galley` script; `galley-settings://` / `galley-help://` for the Settings / Help singleton windows). visionOS surface: a single `WindowGroup(for: DocumentTarget.self)` with `.fileImporter` for the empty case; no menus, no embedded Server; receives Mac-hosted documents via Kosmos (see Architecture decisions). **URL dispatch on both platforms is SwiftUI-native** — `handlesExternalEvents` routes inbound `galley://` / `file://` URLs to the right window; there is no `WindowDispatcher` and no `Window("welcome")` (see Architecture decisions → "SwiftUI-native URL dispatch").
- **Galley Server** (bundle id `net.leuski.galley.server`, target `Server`, macOS) — `MenuBarExtra`-only app that runs a loopback HTTP server in-process so any local browser (or BBEdit's preview pane) can view the same documents Galley would render. Owns server lifecycle, port publication (via the shared `net.leuski.galley` defaults plist and via Kosmos peer metadata), launch-at-login, the BBEdit helper-script installer, the Kosmos AVP bridge, and the AVP HTTP tunnel responder (`KosmosHTTPTunnel.Responder`) — the bridge and responder both live in `ServerKosmosService` (`Sources/Server/App/`). Galley.app embeds `Galley Server.app` inside its bundle and registers it as a user `LaunchAgent` (the generic `ActiveServerAgent` / `LaunchctlServerAgent` / `SingleProcessInstance` live in the sibling `KosmosAppKit` package; the Galley-specific `.shared` wiring + `Bundle.serverBundle` helper are under `Sources/Viewer/Utilities/mac/`).
- **Quicklook** (target `Quicklook`, product `Quicklook.appex`, macOS) — `QLPreviewingController` extension. Tries the running Galley Server first so the user's chosen processor and template are honored; falls back to an in-process render with the built-in Swift renderer and bundled template when the server is unreachable.

The shared engine ships as two Xcode framework targets — `GalleyCoreKit` (Galley-specific rendering, templates, choice models, scheme handler, routing value types, shared Kosmos surface, shared defaults protocols) and `GalleyServerKit` (a thin Galley facade — routes, the preview-server controller, localized error pages — over the generic HTTP server). The generic, product-agnostic pieces have been extracted into **sibling Swift packages** alongside `Galley.xcodeproj`:

- **`Kosmos`** (`../Kosmos`) — `KosmosCore` + `KosmosTransport` (peer mesh, roles, `KosmosService`/`KosmosServiceHost`, `WindowID`) and `KosmosHTTPTunnel` (`Responder` / `Client` / `URLBuilder` / `TunnelScheme` — the `galley://local` surface that turns `ProxyHTTPRequest` / `ProxyHTTPResponse*` into `URLSession` calls and back).
- **`KosmosAppKit`** (`../KosmosAppKit`) — shared app-level primitives that used to live in `GalleyCoreKit`: the `ChoiceModel` / `SelectableCollection` base, `DocumentWatcher`, `DefaultsBroadcast`, the `DefaultsProtocol` / `HTTPServerDefaults` / `BroadcastedDefaults` contracts, the launch-agent stack (`ActiveServerAgent` / `LaunchctlServerAgent` / `SingleProcessInstance`), and shared SwiftUI/Foundation helpers (`DividedSections`, `PullDownIconMenu`, `URL+`, `String+URL/+HTML`, `Bundle+Resources`, `AsyncSequence+Debounce`, `Observation`, `UNUserNotificationCenter+`, `URL.computeHash`).
- **`KosmosHTTPServer`** (`../KosmosHTTPServer`) — the FlyingFox-backed loopback HTTP server, fronted by a thin Hummingbird-API-shaped adapter (`Application` / `Router` / `Request` / `Response` / `ByteBuffer`), plus `HTTPServerController`, SSE, and `guardedRequest`. **FlyingFox and swift-http-types are this package's dependencies, not Galley's** (see Architecture decisions). `GalleyServerKit` re-exports it.
- **`MarkdownHTMLKit`** (`../MarkdownHTMLKit`) — wraps `swift-markdown`; backs `GalleyCoreKit`'s `SwiftMarkdownRenderer`.

Link map: `GalleyCoreKit` links `KosmosAppKit`, `MarkdownHTMLKit`, the three Kosmos products, `ALFoundation`, `ObservableDefaults`. `GalleyServerKit` links `GalleyCoreKit` + `KosmosHTTPServer` + `KosmosHTTPTunnel`. The **Viewer** (both slices) and **Quicklook** link `GalleyCoreKit` (+ Kosmos core/transport/tunnel); only **Server** also links `GalleyServerKit`.

The Galley-specific Kosmos surface in this repo is `Sources/GalleyCoreKit/Utilities/GalleyKosmos.swift`: `GalleyKosmosRole` (conforms to Kosmos's `Role`), the `MetadataKey<URL>.httpURL` accessor (wire key `galley.http-url`), and the `RouteToAVP` request/reply messages. Peer classification + AVP-reachability are no longer Galley's — they moved onto `KosmosServiceHost` as product-scoped queries (`presentPeer(role:onHost:)`, `reachablePeer(deviceType:)`); the old product-blind `GalleyPeerClassifier` / `PeerInfo.galleyRole` were removed. No HTTPS, no cert pinning — AVP renders Mac-hosted documents by tunneling each WebKit fetch back through Kosmos via the `galley://local` scheme handler.

Localized strings live in `Localizable.xcstrings` per target. `Sources/Viewer/Resources/Localizable.xcstrings` is shared across the Viewer's macOS and visionOS slices. Server, GalleyCoreKit, GalleyServerKit, and Quicklook each have their own. English and Russian are shipped.

See `README.md` for HTTP routes, template placeholders, and BBEdit integration.

## Layout

```
Galley.xcodeproj              # 7 targets: GalleyCoreKit, GalleyServerKit, Server,
                              #            Quicklook, Viewer (macOS + visionOS),
                              #            Tests, UITests
Sources/
  GalleyCoreKit/              # framework — Galley-specific rendering, templates,
                              # choice values, routing, scheme handler. Generic
                              # primitives live in KosmosAppKit (sibling package).
    Accessibility/              # ViewerAccessibilityIdentifiers (ViewerA11yID),
                                # ServerAccessibilityIdentifiers (ServerA11yID)
    Models/                     # ChoiceModel+Localization (the ChoiceModel /
                                # SelectableCollection BASE is in KosmosAppKit;
                                # this adds Galley's localized labels),
                                # ProcessorModel, TemplateModel, TOCEntry,
                                # MarkdownFileTypes, PreviewRoute + RouteNames
                                # (shared HTTP/scheme parser), ServerStatus
                                # (.disabled / .starting / .running(URL) /
                                # .notResponding; the .running URL is what the
                                # Server peer-published — no HTTP probe, truth
                                # comes from Kosmos peer presence).
    Render/                     # MarkdownRenderer, SwiftMarkdownRenderer (over
                                # MarkdownHTMLKit), ExternalProcessRenderer,
                                # ProcessorStore, HTMLHeadings
    Routing/                    # LaunchArguments, OpenBehavior+DisplayName.
                                # (OpenBehavior, WindowID + WindowIDAllocator come
                                # from KosmosCore. The old central routing types —
                                # OpenURLRouter / DispatchAction / WindowRegistry /
                                # WindowRecord / LaunchURLBuffer / PendingScrollLines —
                                # were removed when dispatch moved to SwiftUI's
                                # handlesExternalEvents. URL→activity parsing is now
                                # OpenDocumentActivity/OpenSettingsActivity/OpenHelp-
                                # Activity in Utilities/Activities.swift.)
    Templates/                  # Template (+ built-in / user shapes), Template+Loader,
                                # TemplateStore, TemplateAssetRewriter, Placeholders
    Views/                      # ColorSchemeMenu, ProcessorMenu, TemplateMenu
                                # (Galley-specific SwiftUI menus; DividedSections /
                                # PullDownIconMenu are in KosmosAppKit)
    Utilities/                  # GalleyDefaults (GalleyDefaults / GalleyRenderDefaults
                                # protocols over KosmosAppKit's DefaultsProtocol;
                                # GalleyConstants — suiteName, defaultHost,
                                # applicationSupportDirectory; bundleIdentifier),
                                # GalleyKosmos (GalleyKosmosRole, MetadataKey.httpURL,
                                # RouteToAVP), DisplacementNotifier,
                                # Activities (OpenDocumentActivity galley:// +
                                # OpenSettingsActivity galley-settings:// +
                                # OpenHelpActivity galley-help:// — each a
                                # URLSerializable that .open()s itself at the app;
                                # SettingsTab enum), URL+Galley
                                # (withoutQueryOrFragment, galleyPreferringTokens
                                # dedup tokens, galleyPreview*/template helpers,
                                # bundleTemplatesDirectoryURL).
                                # (DocumentTarget + URLSerializable moved to
                                # KosmosAppKit.)
                                # (DocumentWatcher, DefaultsBroadcast, GalleyAppHash,
                                # MIMETypes, and the generic URL/String/Bundle/
                                # AsyncSequence/Observation helpers moved to KosmosAppKit.)
    WebKit/                     # PreviewScheme (x-galley://local — shared in-process
                                # resolver for Quicklook + offscreen print web view)
                                # + ClassicPreviewSchemeHandler (WKURLSchemeHandler).
    Resources/                  # Localizable.xcstrings, Templates.bundle (Default,
                                # GitHub, HighContrast, LaTeX, Manuscript, Sepia,
                                # Solarized, Terminal, Tufte)
  GalleyServerKit/            # framework — thin Galley facade over KosmosHTTPServer
                              # (the generic FlyingFox server lives in that package)
    GalleyServerKit.swift       # @_exported import KosmosHTTPServer; Bundle accessor
    Galley/
      PreviewServerController.swift  # Galley facade — owns the template/renderer
                                # provider closures + the shared DocumentWatcher,
                                # delegates lifecycle (state, bound-URL, start/stop)
                                # to KosmosHTTPServer's HTTPServerController.
                                # State = HTTPServerState (re-exported).
      Routes.swift              # /preview, /template/<id>/<file>, /events (SSE), /
                                # handlers, built on KosmosHTTPServer's Router /
                                # Request / Response and host-guarding (guardedRequest)
      Response+Localization.swift  # localized .errorPage / .ok / .badRequest / etc.
                                # over the generic Response, using .galleyServerKit bundle
    Resources/                  # ErrorPage.html, Localizable.xcstrings
  Viewer/                     # the Galley document app — single target,
                              # macOS + visionOS. Cross-platform code sits at the
                              # parent level; `mac/` and `vision/` subfolders hold
                              # platform-specific code that is itself wrapped in
                              # `#if os(macOS)` / `#if os(visionOS)` guards so the
                              # other platform's compile cleanly skips it.
    UI/                         # cross-platform views: Actions, Animation,
                                # AssortedViews, FindBar, FocusedValues,
                                # SearchField, StatusBar, TOCSidebar
      mac/                      # MacContentView (bootstrap/empty member of the
                                # document WindowGroup — captures openWindow, hosts
                                # URL receipt, runs the FTUE Open panel; replaces
                                # WelcomeView), DocumentView, HelpWindowView,
                                # InboundURLHandler (handlesInboundURLs modifier:
                                # handlesExternalEvents(preferring:allowing:) +
                                # onOpenURL → per-window document receipt + dedup),
                                # MacSettingsView, ServerStatusPill, NewTabAction,
                                # WindowAccessor
        Scenes/                 # MacViewerApp (@main; three scenes), MacDocumentScene
                                # (WindowGroup(for: DocumentTarget.self), claims
                                # file:/galley:), MacHelpScene (Window claiming
                                # galley-help://), MacSettingsScene (Window claiming
                                # galley-settings://)
        Menus/                  # FileCommands, EditCommands, ViewCommands,
                                # FormatCommands, HelpCommands (fires galley-help://),
                                # SettingsCommands (restores ⌘, → openWindow)
        Settings/               # GeneralSettingsView, MarkdownSettingsView,
                                # ServerSettingsView
      vision/                   # VisionContentView, VisionDocumentScreen,
                                # VisionWelcomeScreen, VisionSettingsView
        Scenes/                 # VisionViewerApp (@main), VisionDocumentScene
                                # (WindowGroup(for: DocumentTarget.self)),
                                # VisionSettingsScene (Window claiming
                                # galley-settings://)
    Bridges/                    # cross-platform: LinkBridge, ScrollBridge,
                                # FindBridge, TOCBridge, StatsBridge,
                                # BackgroundColorBridge, EditorBridge
                                # (cmd-click → editor; AppKit side is macOS-only).
                                # visionOS-specific WebKit plumbing lives under
                                # Utilities/vision/ (VisionKosmosService +
                                # KosmosTunnelSchemeHandler), not here.
    Models/                     # cross-platform: AppModel, AppBoot, Defaults
                                # (@ObservableDefaults; conforms to
                                # GalleyRenderDefaults + HTTPServerDefaults),
                                # BindPlan, ColorSchemeModel,
                                # DocumentModel + +History/+Notice/+Scroll/+Zoom/
                                # +Configuration/+Resolution/+Source, DocumentStats,
                                # FindSession, HistorySnapshot+JSON,
                                # PerFileStateStore, RecentDocumentsModel,
                                # SceneColorSchemeModel, SceneProcessorModel,
                                # SceneTemplateModel, SearchFieldModel,
                                # ServerStatusModel, Template+BackgroundColor
      mac/                      # DocumentModel+Print, DocumentModel+AVP
                                # ("Show on Vision Pro" → RouteToAVP),
                                # EditorChoice, EditorPreset
      vision/                   # DocumentModel+Export
    Utilities/
      mac/                      # ActiveServerAgent (typealias / swap point),
                                # LaunchctlServerAgent (the active backend —
                                # classic ~/Library/LaunchAgents plist; the
                                # SMAppService alternative was removed — AMFI's
                                # launch-constraint check rejects the ad-hoc-signed
                                # helper), ViewerKosmosService (Mac Viewer's narrow
                                # Kosmos surface — peer presence for the
                                # ServerStatusPill and the "Show on Vision Pro"
                                # menu, plus a single outbound RouteToAVP request)
      vision/                   # VisionKosmosService (AVP-side Kosmos client +
                                # lifecycle + OpenDocument/OpenURL receiver; owns
                                # the AVP end of the HTTP tunnel — the
                                # KosmosHTTPTunnel.Client — and turns inbound
                                # OpenDocument into a galley:// URL it .open()s),
                                # KosmosTunnelSchemeHandler (WebKit URLSchemeHandler
                                # for galley://local that forwards every request to
                                # that Client)
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
  Server/                     # the Galley Server menu-bar app (macOS)
    ServerApp.swift             # @main — single MenuBarExtra scene
    App/                        # AppModel + AppBoot (server-owning; holds
                                # TemplateStore / ProcessorStore choices,
                                # PreviewServerController, the ServerKosmosService,
                                # and the Server's @ObservableDefaults Defaults class
                                # — conforms to GalleyRenderDefaults + HTTPServerDefaults
                                # + BroadcastedDefaults, publishes serverHTTPPort to
                                # the shared net.leuski.galley plist on every state
                                # change),
                                # ServerKosmosService (subclass of
                                # KosmosService<GalleyKosmosRole>; Kosmos host + AVP
                                # bridge; hosts a KosmosHTTPTunnel.Responder that
                                # turns inbound ProxyHTTPRequest messages into
                                # URLSession calls against the loopback HTTP listener
                                # and streams ProxyHTTPResponseHead + chunked
                                # ProxyHTTPResponseChunk back; advertises the loopback
                                # HTTP URL in peer metadata via MetadataKey.httpURL),
                                # GalleyBridgeRequest (the galley-bridge:// scheme
                                # value type), ServerAppDelegate (LSHandler —
                                # receives Finder opens + galley-bridge:// URLs)
    Menu/                       # MenuBarContent
    Resources/                  # AppIcon.icon, Assets.xcassets, Info.plist,
                                # Localizable.xcstrings, Server.entitlements
  Quicklook/                  # Quick Look preview extension (.appex, macOS)
    PreviewViewController.swift # QLPreviewingController — server-first, falls back
                                # to built-in render via ClassicPreviewSchemeHandler
    Defaults.swift              # @ObservableDefaults Defaults class — minimal
                                # HTTPServerDefaults conformer that reads
                                # serverHTTPPort from the shared
                                # net.leuski.galley suite via QL's
                                # shared-preference.read-only entitlement
    Info.plist, Quicklook.entitlements
    en.lproj, ru.lproj
Tests/                        # Swift Testing — kit + app-logic unit tests
  GalleyCoreKitTests/           # PlaceholderContext, TemplateAssetRewriter,
                                # TemplateStoreObservation, URLPathHelpers,
                                # SwiftMarkdownRenderer + SwiftMarkdownSpecConformance,
                                # ClipboardRoundTrip, AVPCSSPathChain
                                # (URL→tunnel→base-href round-trip),
                                # HTTPTunnelURLBuilder, KosmosTunnelScheme
    Routing/                    # GalleyAction (URL → DocumentTarget via
                                # OpenDocumentActivity, incl. ?line=N), LaunchArguments
  GalleyServerKitTests/         # PreviewServerController, HTTPServerController
                                # (generic lifecycle pins)
    Integration/                # ServerPreviewEndToEnd (binds a real socket)
                                # (the route-decoding / host-guard / SSE / template-
                                # origin tests moved to the KosmosHTTPServer package)
  ViewerTests/                  # ViewerTests (app-logic, sparse), KosmosTests,
                                # ColorSchemeChoiceTests, HTTPTunnelAVPClientTests,
                                # WebKitZoneIDRejectionTests
  TestPlan.xctestplan           # enrols Tests + UITests
UITests/                      # XCUITest bundle — testTargetName: Viewer
                                # UITests.swift, UITestsLaunchTests.swift, AppLauncher.swift
Resources/Scripts/            # bundled BBEdit helper scripts (Galley + browser variants)
Scripts/                      # release.sh
docs/                         # test-framework
```

## Build & test

Pure Xcode project — **no top-level `Package.swift`**. The two framework targets (`GalleyCoreKit`, `GalleyServerKit`) build inside the project; the four local sibling Swift packages (`../Kosmos`, `../KosmosAppKit`, `../KosmosHTTPServer`, `../MarkdownHTMLKit`) are referenced from the project. New source files dropped into the per-target source directories (`Sources/Viewer/...`, `Sources/Server/...`, etc.) are picked up automatically — the project uses Xcode 16 filesystem-synchronized groups, so `Galley.xcodeproj/project.pbxproj` has no individual file references and **no manual registration is required** when adding a file. Files under `Sources/Viewer/.../mac/` and `.../vision/` are conditionally compiled — each file in those subfolders is wrapped in `#if os(macOS)` / `#if os(visionOS)` so the project's filesystem-synchronized membership compiles cleanly on both platforms.

Shared schemes:

- **Viewer** — the Galley document app; default destination is macOS, but the same scheme builds for visionOS by switching destination.
- **Server** — the menu-bar previewer
- **Quicklook** — the Quick Look preview extension
- **GalleyCoreKit** / **GalleyServerKit** — framework schemes (mostly for direct iteration / testing)
- Sibling-package schemes (`KosmosCore`, `KosmosTransport`, `KosmosHTTPTunnel`, `KosmosAppKit`, `KosmosHTTPServer`, `MarkdownHTMLKit`, and their transitive deps) may also surface in Galley's scheme list. The link map: `GalleyCoreKit` pulls `KosmosAppKit` + `MarkdownHTMLKit` + the three Kosmos products; `GalleyServerKit` adds `KosmosHTTPServer`.

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

Logic tests use **Swift Testing** (`@Test`, `#expect`); UI tests use **XCTest** (XCUITest is XCTest-based). The shared `TestPlan.xctestplan` enrols both targets. Logic coverage in this repo includes placeholder substitution, template rewriting, `TemplateStore` observation, URL path helpers, the swift-markdown renderer (with a CommonMark-spec-conformance suite), the AVP CSS path chain (galley://local URL → tunnel `urlPath` → Mac `<base href>` → sub-resource URL), the HTTP-tunnel URL builder, the Kosmos tunnel scheme, the HTTP tunnel AVP client (per-request buffering vs SSE streaming), the WebKit Zone.Identifier-suffix rejection, the `PreviewServerController` / `HTTPServerController` lifecycle + an end-to-end socket round-trip, color-scheme choice, and the surviving routing-layer decisions (`GalleyAction` (URL → `DocumentTarget` via `OpenDocumentActivity`), `LaunchArguments`). (The central-dispatcher tests — `WindowRegistry`, `OpenURLRouter`, `LaunchURLBuffer`, `PendingScrollLines` — were removed along with those types when dispatch moved to SwiftUI's `handlesExternalEvents`.) (The generic server internals — SSE encoding, host-header guarding, reload-script injection, template-origin policy, `serverEndpointURL` composition — are now tested in the `KosmosHTTPServer` / `KosmosAppKit` packages, not here.) UI coverage exercises real product invariants — the empty bootstrap window stays hidden, FTUE Open panel surfaces on cold launch, seeded launches produce visible document windows, File/View menus reachable on a populated doc. See `docs/test-framework.md` for the test pyramid.

The UITests target seeds a document by firing the app's own `galley://<path>` scheme at the running app (`AppLauncher.openViaURLScheme` → `/usr/bin/open`), which SwiftUI delivers through `handlesExternalEvents` / `onOpenURL` to a document window — the same path BBEdit's preview script and the Server use. (This replaced the old `--seed-file` launch-buffer injection; `LaunchArguments` still exists and is unit-tested but is no longer wired into app launch.) Test mode also passes `-ApplePersistenceIgnoreState YES` to skip the post-crash "Reopen?" alert that would otherwise hang launches. **Don't pass `--ui-test-mode` as a launch argument** — AppKit's command-line `NSUserDefaults` parser eats `--`-prefixed tokens and pollutes the defaults domain. Use `launchEnvironment` (`GALLEY_UI_TEST_MODE`) for the test-mode marker instead.

## Lint

SwiftLint runs as a `Lint` shell-script build phase (no separate scheme/target). The phase invokes `Scripts/lint.sh`, which calls `swiftlint --config swiftlint.yml Sources` (and warns rather than fails if SwiftLint isn't installed on the build machine). Config is `swiftlint.yml` (custom name — pass `--config swiftlint.yml` if invoking the CLI). Notable rules:
- `force_unwrapping` is opt-in and enabled (warning) — avoid `!`.
- `line_length: 80` — long string literals and URLs need to be split.
- `function_body_length` warns at 65 lines.
- `nesting.type_level: 3`.

## Release

`Scripts/release.sh <vX.Y.Z>` archives the Release config, ad-hoc signs the `.app`, installs it to `/Applications`, zips it, tags the commit, and creates a GitHub release via `gh`. Use `--dry-run` to skip tag + publish. Build number is `git rev-list --count HEAD`; marketing version is the tag minus the leading `v`. Confirm the script's `SCHEME` matches whichever scheme (`Viewer` or `Server`) the release targets before tagging.

`.github/workflows/release.yml` is the (currently disabled) signed + notarized CI path. Triggered manually (`workflow_dispatch`); requires repo secrets listed in the file header.

## Dependencies

Resolved by Xcode against package references in `Galley.xcodeproj`. The project references **four local sibling packages** (`../Kosmos`, `../KosmosAppKit`, `../KosmosHTTPServer`, `../MarkdownHTMLKit`) and **two remote packages** (`swift-core-kit`, `ObservableDefaults`). FlyingFox, swift-http-types, and swift-markdown are **transitive** — pulled in by the sibling packages, not referenced by Galley directly.

- **Kosmos** (`../Kosmos`, local) — Mac↔AVP bridge. `KosmosCore` + `KosmosTransport` (peer mesh, `Role`, `KosmosService` / `KosmosServiceHost`, `WindowID`) are linked via `GalleyCoreKit`, so Server and Viewer share one definition of `GalleyKosmosRole` / `RouteToAVP` and the `ProxyHTTPRequest` / `ProxyHTTPResponse*` tunnel messages. `KosmosHTTPTunnel` carries the `Responder` (used by `Server`), the `Client` (used by the Viewer's visionOS slice), `TunnelScheme`, and the pure `URLBuilder` helpers (path splicing, header extraction, body chunking, SSE streaming detection). No TLS in the data path; Kosmos handles peer identity / trust on its own channel (dev builds use `AlwaysTrustProvider`; SAS-code pairing is the planned production replacement). `Kosmos` depends on a local `../Loom` fork (BonjourAdvertiser self-recovery patch).
- **KosmosAppKit** (`../KosmosAppKit`, local) — product-agnostic app primitives extracted from `GalleyCoreKit`: `ChoiceModel` / `SelectableCollection`, `DocumentWatcher`, `DefaultsBroadcast`, the `DefaultsProtocol` / `HTTPServerDefaults` / `BroadcastedDefaults` contracts (incl. `serverEndpointURL` / `serverHTTPPort`), the launch-agent stack (`ActiveServerAgent` / `LaunchctlServerAgent` / `SingleProcessInstance`), and shared helpers/views. Depends on `ALFoundation`. Linked by `GalleyCoreKit`.
- **KosmosHTTPServer** (`../KosmosHTTPServer`, local) — generic FlyingFox-backed loopback HTTP server + Hummingbird-shaped adapter + `HTTPServerController` + SSE + `guardedRequest`. **This package owns the FlyingFox and swift-http-types dependencies.** Linked by `GalleyServerKit` (which `@_exported`s it). FlyingFox is dependency-free (FlyingFox + FlyingSocks, no NIO), which is the point — the whole NIO/Hummingbird cluster is gone from the graph (see Architecture decisions).
- **MarkdownHTMLKit** (`../MarkdownHTMLKit`, local) — wraps `swift-markdown` (pinned 0.8.0) for the bundled "Default" renderer. Linked by `GalleyCoreKit`, used by `SwiftMarkdownRenderer`.
- **swift-core-kit** (`github.com/leuski/swift-core-kit`, module `ALFoundation`) — **private** repo. CI authenticates via `GH_PACKAGES_PAT`; locally, ensure your git credentials can read it. Pulled directly by Galley and transitively by `KosmosAppKit`.
- **ObservableDefaults** (`github.com/fatbobman/ObservableDefaults`) — `@ObservableDefaults` macro backing the cross-platform `Sources/Viewer/Models/Defaults.swift`. `MacViewerApp.init` and `VisionViewerApp.init` both call `Defaults.warmCache()` before SwiftUI lays out a single view — see the long comment on `warmCache()` for the WebKit-triggered AttributeGraph reentrancy this defends against.

External Markdown processors (MultiMarkdown, Pandoc, Discount, cmark-gfm, Markdown.pl) are invoked as subprocesses via `ExternalProcessRenderer` (macOS-only — the kit guards `Process` use behind `#if os(macOS)`).

## ALFoundation

`ALFoundation` (module of `swift-core-kit`) is the shared utility layer this project leans on heavily. **Before reimplementing anything filesystem-, URL-, process-, or watcher-related, check `ALFoundation` first.** Source lives at `/Users/leuski/Synced/General/Workbench-dev/swift-core-kit/Sources/ALFoundation/`.

What we actually use today:

| Area | API | In use at |
|---|---|---|
| URL path arithmetic | `url / "subpath"` | `MacViewerApp.swift`, `Template+Loader.swift`, `GalleyDefaults.swift` (`GalleyConstants.applicationSupportDirectory`) |
| URL helpers | `URL.itemExists`, `URL.parent`, `URL.createDirectory()`, `URL.isExecutable` | `MacViewerApp.swift`, `EditorPreset.swift`, `EditorChoice.swift`, `TemplateStore.swift`, `Template+Loader.swift`, `ExternalProcessRenderer.swift`, `Placeholders.swift` |
| Executable discovery | `try await URL(command: "pandoc")` | `ExternalProcessRenderer.discover` |
| Subprocess execution | `Process.runAndCapture(_:with:at:streams:)`, `Process.runAndReturn(...)`, `Process.run(...)`, `ProcessStreams.inMemory`, `ProcessArgument` | `ExternalProcessRenderer.swift`, `EditorChoice.swift`, `LaunchctlServerAgent.swift` |
| Force-unwrap with message | `expr !! "message"` | `URL+Galley.swift` (`bundleTemplatesDirectoryURL`) |
| File-system watching | `FileSystemObjectWatcher`, `FileSystemEventStream` | (available; `DocumentWatcher` — now in KosmosAppKit — is the wrapper around FSEvents) |

**Rules:**

1. **Never call `Process()` / `process.run()` directly.** Use `Process.runAndCapture` or `Process.run` from ALFoundation. They return a `ProcessResult` with structured stdout/stderr and proper async termination.
2. **Never reach for `FileManager.default.createDirectory` or `FileManager.default.fileExists` when a `URL` is already in hand.** Use `url.createDirectory()` and `url.itemExists`. The expressions are shorter, the call sites stay consistent, and `createDirectory` makes intermediates automatically.
3. **Never build paths with `appendingPathComponent` chains.** Use the `/` operator: `dir / "subfolder" / "file.txt"`. `appendingPathComponent` is reserved for cases where the segment is dynamic and may be empty (rare).
4. **`!!` is preferred over `!` for force-unwraps**, when the unwrap is genuinely impossible-to-fail at runtime and a crash needs a descriptive message.
5. **For cross-process file dispatch between Galley.app and Galley Server.app, route by URL scheme, not by `NSWorkspace.shared.open(_:withApplicationAt:configuration:)`.** That API returns success (completion gets the target app's running PID with `error=nil`) but the URL is never delivered to the target's `application(_:open:)`. Observed live in both directions. Use the dedicated schemes instead:

  | Direction | Scheme | Builder / parser | Registered in |
  |---|---|---|---|
  | Server → Galley.app (e.g., "no AVP, surface file locally") | `galley://<path>` | `OpenDocumentActivity(target:).url` / `OpenDocumentActivity(from:)` (or just `.open()`) | `Sources/Viewer/Resources/Info.plist` |
  | Galley.app → Server (e.g., "Show on Vision Pro") | `galley-bridge://<path>` | `GalleyBridgeRequest(target:).url` / `GalleyBridgeRequest(from:)` | `Sources/Server/Resources/Info.plist` |

  Server's `ServerAppDelegate.application(_:open:)` normalizes `galley-bridge://` URLs to `GalleyBridgeRequest` (and `file://` URLs to a `DocumentTarget`) before dispatching, so callers only need to construct the URL and invoke `NSWorkspace.shared.open(url)`. Do **not** shell out to `/usr/bin/open`. Today the more common Galley.app→AVP path is `RouteToAVP` over Kosmos rather than `galley-bridge://`; the URL-scheme path is still wired for callers outside Galley.app's own process.

## ObservableDefaults

All of Galley's own user preferences flow through **`@ObservableDefaults`** (from the `ObservableDefaults` Swift package, re-exported by `GalleyCoreKit/Utilities/GalleyDefaults.swift`). **Before adding `UserDefaults.standard.set(...)` / `.string(forKey:)` / `.bool(forKey:)` / etc. anywhere, stop and read the existing pattern.** The macro generates an `@Observable`-compatible class whose stored properties are persisted to a `UserDefaults` suite and re-read into a per-property cache on `UserDefaults.didChangeNotification` — that cache, plus the Darwin-notification bridge in `DefaultsBroadcast`, is what makes Viewer ↔ Server preference picks visible across processes in real time.

Where the pattern lives:

| File | Suite | Role |
|---|---|---|
| `Sources/Viewer/Models/Defaults.swift` | `UserDefaults.standard` (Viewer's bundle id `net.leuski.galley` *is* the suite) | Every Viewer-facing pref (renderer, template, `enablePerDocumentOverrides`, `openBehavior`, `perFileStateStore`, `templateBackgroundColors`, `lastTemplateBackgroundColor`, `tintWindowWithPageBackground`, `showsStatusBar`, `readingWordsPerMinute`, `editor` on macOS, `recentEntries` on visionOS, `colorScheme`, `serverGalleyHash`, `serverHTTPPort`). Conforms to `GalleyRenderDefaults` + `HTTPServerDefaults`. Cross-platform. |
| `Sources/Server/App/AppModel.swift` (the `Defaults` class) | `UserDefaults(suiteName: "net.leuski.galley")` | The Server-side mirror — same plist as the Viewer; `renderer`, `template`, `serverGalleyHash`, `serverHTTPPort`. Conforms to `GalleyRenderDefaults` + `HTTPServerDefaults`; the Server is the sole writer of `serverHTTPPort`. |
| `Sources/Quicklook/Defaults.swift` | `UserDefaults(suiteName: "net.leuski.galley")` (QL has its own bundle id and reads via `temporary-exception.shared-preference.read-only`) | Minimal QL-facing reader — only `serverHTTPPort`. Conforms to `HTTPServerDefaults`. Used to compose `serverEndpointURL` for the server-first preview path. |
| `Sources/GalleyCoreKit/Utilities/GalleyDefaults.swift` | — | `@_exported import ObservableDefaults`, `GalleyDefaults` + `GalleyRenderDefaults` + `HTTPServerDefaults` protocols (`@MainActor static var shared: Self`), `GalleyConstants.suiteName`, `GalleyConstants.applicationSupportDirectory`. |
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
- `Render/` — `MarkdownRenderer` protocol; `SwiftMarkdownRenderer` (with optional `annotatesSourceLines` that emits `data-source-line="N"` on every block, used by the Viewer for cmd-click→editor); `ExternalProcessRenderer` (shells out via `Process.runAndCapture` from ALFoundation, macOS-only); `ProcessorStore` exposes the ordered list of `Processor` rows (each with `installHint` and either a live `MarkdownRenderer` or `nil` if unavailable); `HTMLHeadings` parses headings out of rendered HTML for the TOC sidebar. The Viewer's cmd-click bridge also accepts pandoc's `data-pos` and cmark-gfm's `data-sourcepos` so source-line jumps work across renderers.
- `Templates/` — `Template` (a single `Sendable` value `struct`, conforms to `ChoiceValueProtocol`; `Template.bundledDefault` / `.default` for the built-in) + `Template+Loader`; `TemplateStore` watches `~/Library/Application Support/net.leuski.galley.localized/Templates/` and accepts **two shapes** — a folder containing `Template.html`/`template.html` (Galley convention), or a top-level `*.html`/`*.htm` file with sibling assets (BBEdit preview-template convention). Built-in templates (Default, GitHub, HighContrast, LaTeX, Manuscript, Sepia, Solarized, Terminal, Tufte) ship in `Resources/Templates.bundle`. `Placeholders.swift` does `#TOKEN#` substitution (`#TITLE#`, `#DOCUMENT_CONTENT#`, `#BASE#`, `#FILE#`, `#BASENAME#`, `#FILE_EXTENSION#`, `#DATE#`, `#TIME#` — token names match BBEdit's). `TemplateAssetRewriter` rewrites template-relative paths through `/template/<id>/...` and absolute filesystem paths through `/preview/<absolute-path>` so the resulting URLs resolve in either the HTTP server, the in-process `x-galley://local` resolver (Quicklook + print web view), or the AVP `galley://local` tunnel.
- `Models/ServerStatus.swift` — `ServerStatus` only (`.disabled` / `.starting` / `.running(URL)` / `.notResponding`). The Mac Viewer's status pill is driven by Kosmos peer presence (truth-of-running) + `ActiveServerAgent.isEnabled` (truth-of-intent); the `.running` case's URL is what the Server published in its Kosmos peer metadata (`MetadataKey.httpURL`). There is **no** HTTP probe — the previous `ServerProbe` poll loop is gone.
- `WebKit/PreviewSchemeHandler.swift` — `PreviewScheme` enum with the `x-galley` scheme name + `x-galley://local` origin URL + the shared `resolve(...)` function. `ClassicPreviewSchemeHandler` (the `WKURLSchemeHandler` adapter, no SwiftUI dep) is here; the Viewer-visible SwiftUI-flavored `URLSchemeHandler` is in `Sources/Viewer/WebKit/PreviewSchemeHandler.swift` and delegates to the same resolver. Used by the Viewer's visible `WebPage`, the Viewer's offscreen print/export `WKWebView`, and the QuickLook extension's fallback render. AVP does **not** use this scheme — it has its own `galley://local` tunnel-backed scheme (`KosmosHTTPTunnel.TunnelScheme`, from the Kosmos package).
- `Models/` — the Galley choice values `ProcessorModel` / `TemplateModel` plus `ChoiceModel+Localization` (the generic `ChoiceModel` / `SelectableCollection` "pick one of N + persist by `persistentID`" base now lives in KosmosAppKit), `TOCEntry`, `MarkdownFileTypes` (recognized extensions, also used by open-panel UTI lists), `PreviewRoute` + `RouteNames` (the shared `/template/<id>/<file>` + `/preview/<absolute-path>` + `/events/<absolute-path>` parser used by both the Server's HTTP routes and the Viewer/Quicklook scheme handlers), and `ServerStatus` (see above).
- `Routing/` — what remains of the Viewer's URL routing after dispatch moved to SwiftUI: `OpenBehavior+DisplayName` (display names for `OpenBehavior`, the `.newWindow` / `.newTab` / `.replaceCurrent` enum that itself comes from `KosmosCore`) and the `LaunchArguments` parser (still unit-tested; no longer wired into app launch). The old central-dispatcher value types — `OpenURLRouter` + `DispatchAction`, `WindowRegistry` + `WindowRecord`, `LaunchURLBuffer`, `PendingScrollLines`, plus the Viewer's `WindowDispatcher` AppKit interpreter — were **removed**; SwiftUI's `handlesExternalEvents` now does the window selection (see Architecture decisions → "SwiftUI-native URL dispatch"). URL → activity parsing lives in `Utilities/Activities.swift`: `OpenDocumentActivity` (scheme `galley`, wraps a `DocumentTarget`, also accepts plain `file://`), `OpenSettingsActivity` (scheme `galley-settings`, optional `?tab=<id>` → `SettingsTab`), `OpenHelpActivity` (scheme `galley-help`, bundle file path). Each conforms to `URLSerializable` (KosmosAppKit) and exposes `.open()` (→ `NSWorkspace.shared.open` on macOS, `UIApplication.shared.open` on visionOS), so any peer/process fires its intent at the app by opening a URL. `DocumentTarget` (`documentURL` + optional `scrollLine`; `Codable`/`Hashable`) is the **WindowGroup value type** — `WindowGroup(for: DocumentTarget.self)` on both platforms — and moved to KosmosAppKit so the routing layer and the Kosmos wire (`OpenDocument` / `CloseWindow` / `WindowContentChanged`, keyed by `KosmosCore.WindowID`) share it. `WindowID` + `WindowIDAllocator` still come from `KosmosCore`.
- `Accessibility/` — `ViewerAccessibilityIdentifiers` (`ViewerA11yID`) and `ServerAccessibilityIdentifiers` (`ServerA11yID`) enum-of-string-constants catalogs.
- Tunnel scheme + HTTP-tunnel implementation — **not here**. `KosmosHTTPTunnel.TunnelScheme` (declares the AVP-facing `galley://local` scheme + `originURL` sent as `X-Galley-Origin` on every tunneled request so the Mac's `<base href>` stays on this scheme, plus a `previewURL(forFile:)` builder) and the matching pure URL/header helpers (`buildURLRequest`, `extractHeaders`, `chunks(of:requestID:chunkSize:)`, `requiresStreaming(urlPath:)`) both live in the sibling Kosmos package's `KosmosHTTPTunnel` product so the `Responder` and `Client` can share them without a Galley-side dependency.
- `Utilities/GalleyKosmos.swift` — the Galley-specific Kosmos surface that Server, Viewer, and tests share: `GalleyKosmosRole` (server / mac-viewer / vision-viewer; conforms to Kosmos's `Role`, published as `kosmos.role` metadata), the `MetadataKey<URL>.httpURL` accessor (wire key `galley.http-url`, the metadata key the Server uses to advertise its loopback HTTP URL inline), and the `RouteToAVP` request/reply message. Peer classification + AVP-reachability are **not** here — they moved onto `KosmosServiceHost` (sibling package) as product-scoped queries (`presentPeer(role:onHost:)`, `reachablePeer(deviceType:)`); the old product-blind `GalleyPeerClassifier` / `PeerInfo.galleyRole` were removed. Host bootstrap (`KosmosService` / `KosmosServiceHost`) also lives in the Kosmos package, not here.
- `Utilities/GalleyDefaults.swift` — Galley's defaults contract over KosmosAppKit's `DefaultsProtocol`: `GalleyDefaults` (adds the `net.leuski.galley` `suiteName`) and `GalleyRenderDefaults` (adds `renderer` + `template`). The `HTTPServerDefaults` protocol (`serverHTTPPort: UInt16`, `serverEndpointURL: URL?` — composes `http://127.0.0.1:<port>/`, nil when port is 0) and `BroadcastedDefaults` live in **KosmosAppKit**. Also defines `GalleyConstants` (`suiteName` = `"net.leuski.galley"`, `defaultHost` = `"127.0.0.1"`, `applicationSupportDirectory`) and the `bundleIdentifier` global. The Server, Viewer, and Quicklook each have their own `Defaults` class conforming to a subset of these protocols — they all back the same on-disk plist.
- `Utilities/Activities.swift` — the three inbound-URL value types (`OpenDocumentActivity` / `OpenSettingsActivity` / `OpenHelpActivity`, each `URLSerializable` + `.open()`) and the `SettingsTab` enum. See the `Routing/` bullet above.
- `Utilities/URL+Galley.swift` — `withoutQueryOrFragment`, `galleyPreferringTokens` (the `handlesExternalEvents(preferring:)` dedup token set — strips query/fragment, adds the standardized-file and `galley://` forms so a repeat-open routes back to the window already showing the doc), `galleyPreview` / `galleyPreviewURL(forFile:)` / `galleyTemplate(id:)` / `appendingPreview` / `appendingTemplate` route builders, `URL.bundleTemplatesDirectoryURL`. (`DocumentTarget` + `URLSerializable` moved to KosmosAppKit.)
- `Utilities/DisplacementNotifier` — surfaces a user-facing notice when a previously-persisted processor or template selection no longer exists in the live catalog.
- `Views/` — Galley-specific SwiftUI menus: `ColorSchemeMenu`, `ProcessorMenu`, `TemplateMenu`. (The generic `DividedSections` / `PullDownIconMenu` moved to KosmosAppKit.)
- **Moved to KosmosAppKit** (sibling package), formerly here: `DocumentWatcher`, `DefaultsBroadcast`, the `GalleyAppHash` SHA-256 logic (now `URL.computeHash`), `MIMETypes`, `Bundle+Resources`, `String+URL` / `String+HTML`, `URL+`, `AsyncSequence+Debounce`, `Observation`, and the `ChoiceModel` / `SelectableCollection` base (GalleyCoreKit keeps only `ChoiceModel+Localization` and the Galley choice values `ProcessorModel` / `TemplateModel`).

**`GalleyServerKit`** — a thin Galley facade over the generic `KosmosHTTPServer` package (which it `@_exported`s). The FlyingFox server, the Hummingbird-shaped adapter, `HTTPServerController`, SSE, and `guardedRequest` all live in `KosmosHTTPServer` now; what's left here is Galley's route table and localized error pages:
- `Galley/PreviewServerController.swift` — Galley facade. Owns the `selectedTemplateProvider` / `rendererProvider` `@Sendable` closures and the shared `DocumentWatcher` the SSE route subscribes against; delegates lifecycle to `KosmosHTTPServer`'s `HTTPServerController` (binds `127.0.0.1` on an **OS-assigned port**; `State` is `HTTPServerState`, re-exported). The bound URL flows out via `state = .running(url:)`; the Server's AppModel observes that and (a) writes `Defaults.shared.serverHTTPPort` to the shared `net.leuski.galley` plist, and (b) starts Kosmos with the URL as advertise-time `MetadataKey.httpURL`. Loopback-only — AVP traffic doesn't reach this listener directly; the `KosmosHTTPTunnel.Responder` (hosted by `ServerKosmosService`) proxies AVP requests through it. Same-machine consumers reach the listener via `Defaults.shared.serverEndpointURL`.
- `Galley/Routes.swift` — builds the `Router<BasicRequestContext>`: `/preview/<path>` (Markdown→HTML with placeholders + live-reload injection; non-Markdown extensions fall through to static asset serving), `/template/<id>/<file>`, `/events/<path>` (SSE via the shared `DocumentWatcher`), `/`. Every route is host-guarded (`Response.guarded(...)` → `guardedRequest` in KosmosHTTPServer; loopback-only, DNS-rebinding-safe). The `/preview` handler computes the template `origin` from the request's own `Host` header (not the listener's `127.0.0.1` URL) so the rendered `<base href>` works for AVP-tunneled callers too. `rendererProvider` / `selectedTemplateProvider` are read at request time, so menu picks take effect on the next request with no restart.
- `Galley/Response+Localization.swift` — localized `Response.errorPage` / `.ok` / `.badRequest` / `.notFound` / `.forbidden` / `.unavailable` over KosmosHTTPServer's generic `Response`, pulling strings from `Bundle.galleyServerKit` (`ErrorPage.html`, `Localizable.xcstrings`), plus the `guarded(...)` host-check wrapper that maps thrown guard errors to responses.

### `Sources/Viewer/` — cross-platform viewer code (one target, two platforms)

The Viewer target builds for both macOS and visionOS. Code that doesn't care about the platform sits at the *parent* level inside `Sources/Viewer/...`; code that does sits inside a `mac/` or `vision/` subfolder *and* is wrapped in `#if os(macOS)` / `#if os(visionOS)` so the other platform's filesystem-synchronized compile cleanly skips it. Don't rely on folder-based membership exclusion — the `#if` guards are what's load-bearing.

Cross-platform pieces (the bulk of the viewer's behavior):

- `Models/DocumentModel.swift` plus `+History`, `+Notice`, `+Scroll`, `+Zoom`, `+Configuration`, `+Resolution`, `+Source` — per-document state, owned by each viewer window. Holds the `WebPage`, the bridges, the back/forward history (persisted via `@SceneStorage` as a `HistorySnapshot`), zoom + scroll persistence, the document-notice channel (banner shown over the WebView for ephemeral and render-bound errors), and the rendered-template box. A `Kind` enum (`.document` / `.help`) distinguishes the singleton Help window from real document windows so the help window opts out of inbound-URL receipt and dedup (`handlesInboundURLs(enabled: false)`).
- `Models/AppModel.swift`, `Models/AppBoot.swift`, `Models/Defaults.swift` — app-level state hubs.
- `Models/BindPlan.swift` — pure decision type for "given a fileURL + persisted state, what should the next bind do?"
- `Models/DocumentStats.swift`, `Models/FindSession.swift`, `Models/SearchFieldModel.swift` — drive the StatusBar and FindBar.
- `Models/ColorSchemeModel.swift`, `Models/SceneColorSchemeModel.swift`, `Models/DocumentColorScheme.swift`, `Models/Template+BackgroundColor.swift` — color-scheme + per-template page-bg machinery.
- `Models/HistorySnapshot+JSON.swift`, `Models/PerFileStateStore.swift`, `Models/SceneProcessorModel.swift`, `Models/SceneTemplateModel.swift`, `Models/ServerStatusModel.swift`, `Models/RecentDocumentsModel.swift` — persistence + per-scene overrides + recents wrapping `NSDocumentController`.
- `Bridges/` — `WKScriptMessageHandler`s used by `DocumentModel`. `EditorBridge` (cmd-click → editor; the actual open-in-editor call is `#if os(macOS)`-gated), `LinkBridge` (`.md` family → in-window navigation; external HTTP → default browser/`openURL`; `finder://` → reveal-in-Finder on macOS), `ScrollBridge`, `FindBridge`, `TOCBridge`, `StatsBridge`, `BackgroundColorBridge`. visionOS-specific WebKit plumbing (the `galley://local` scheme handler and the tunnel client) lives in `Utilities/vision/`, not here.
- `UI/` — `Actions` (one source of truth for navigation/zoom/find/TOC/status-bar/etc. buttons, used by both menu and toolbar surfaces, with `.menuItem()` and `.toolbarItem(imageOnly:)` view-builders), `FindBar`, `TOCSidebar`, `StatusBar`, `SearchField`, `FocusedValues` (`\.documentModel` focused-scene key), `AssortedViews` (NoticeBanner etc.), `Animation`.
- `WebKit/PreviewSchemeHandler.swift` — SwiftUI-flavored `URLSchemeHandler` for the visible `WebPage`. Resolution delegates to `GalleyCoreKit.PreviewScheme.resolve` so the offscreen print web view and the QuickLook extension hit the same logic via `ClassicPreviewSchemeHandler`.

Platform-specific siblings live next door:

- `UI/mac/Scenes/` — `MacViewerApp` (`@main` for macOS — no `NSApplicationDelegateAdaptor`), `MacDocumentScene` / `MacHelpScene` / `MacSettingsScene` (the three scenes; see "SwiftUI-native URL dispatch"). `Utilities/mac/ViewerKosmosService` is the Mac Viewer's narrow Kosmos surface (peer presence + outbound `RouteToAVP`).
- `UI/vision/Scenes/` — `VisionViewerApp` (`@main` for visionOS), `VisionDocumentScene` / `VisionSettingsScene`. `Utilities/vision/VisionKosmosService` (AVP-side Kosmos client + lifecycle + `OpenDocument` receiver, owns the `KosmosHTTPTunnel.Client` that drives the AVP end of the tunnel) and `Utilities/vision/KosmosTunnelSchemeHandler` (WebKit URLSchemeHandler for `galley://local` that forwards every request to that Client).
- `Models/mac/` — `DocumentModel+Print`, `DocumentModel+AVP` ("Show on Vision Pro" → sends `RouteToAVP` via `ViewerKosmosService`), `EditorChoice`, `EditorPreset`.
- `Models/vision/` — `DocumentModel+Export`.
- `UI/mac/` — `MacContentView` (the bootstrap/empty WindowGroup member), `DocumentView`, `HelpWindowView`, `InboundURLHandler` (the `handlesInboundURLs` modifier), `WindowAccessor`, `NewTabAction`, `ServerStatusPill`, `MacSettingsView`, plus `Scenes/`, `Menus/`, and `Settings/` subfolders.
- `UI/vision/` — `VisionContentView`, `VisionDocumentScreen`, `VisionWelcomeScreen`, `VisionSettingsView`, plus `Scenes/`.
- `Utilities/mac/` — `ActiveServerAgent`, `LaunchctlServerAgent`, `ViewerKosmosService`.
- `Resources/mac/` — BBEdit/Xcode script bundles, `net.leuski.galley.server.plist` (LaunchAgent template).

When adding a file: if it has any platform-specific use of AppKit / UIKit / RealityKit / AppleScript / etc., put it under the appropriate platform subfolder *and* wrap its body in `#if os(macOS)` or `#if os(visionOS)`. Otherwise place it at the parent level.

### Viewer macOS slice — `Sources/Viewer/*/mac/`

The macOS Viewer is pure SwiftUI — there is **no** `NSApplicationDelegateAdaptor`. URL dispatch is done by SwiftUI's `handlesExternalEvents` (see "SwiftUI-native URL dispatch" under Architecture decisions); everything else (recents, FTUE picker, per-window URL receipt) lives in `@Observable @MainActor` types injected via `.environment()` or in per-window view state. If a hook resurfaces that genuinely requires an AppDelegate, reintroduce a minimal one — don't reabsorb the per-window receipt logic into it.

- **`UI/mac/Scenes/MacViewerApp`** — `@main` on macOS, three Scenes: `MacDocumentScene` (`WindowGroup(id: "document", for: DocumentTarget.self)` driving `MacContentView`; claims `file:` + `galley:` via `handlesExternalEvents(matching:)`), `MacHelpScene` (`Window("Help", id: "help")` claiming `galley-help://`), and `MacSettingsScene` (`Window("Settings", id: "settings")` claiming `galley-settings://` — **not** SwiftUI's `Settings {}` scene, because that scene ignores `handlesExternalEvents`). No separate `Window("welcome")` — SwiftUI materializes one `nil`-target member of the document `WindowGroup` at cold launch, and `MacContentView` uses that as the invisible bootstrap anchor. `MacViewerApp.init` runs `URL.createLocalizedApplicationSupportDirectory()`, pins per-process window tabbing (`pinWindowTabbingPreference()` — volatile `AppleWindowTabbingMode = always`, the substrate for born-as-tab opens), starts `ViewerKosmosService`, and fires `ActiveServerAgent.validateAndRepair()` as a fire-and-forget Task. `Defaults.warmCache()` still runs at init. The document scene hosts all the commands: `FileCommands`, `EditCommands`, `ToolbarCommands`, `ViewCommands`, `FormatCommands`, `WindowCommands`, `HelpCommands` (fires `galley-help://`), `SettingsCommands` (re-adds the ⌘, "Settings…" item that the plain `Window` scene doesn't get for free → `openWindow(id:)`). No `MenuBarExtra` — that's the Server app's job.
- **`Activities` + `InboundURLHandler` (the dispatch core)** — inbound URLs are value types in `GalleyCoreKit/Utilities/Activities.swift` (`OpenDocumentActivity` / `OpenSettingsActivity` / `OpenHelpActivity`). Settings and Help each claim their own scheme on their singleton scene, so SwiftUI routes those straight to the right window; a document window only ever sees `galley://<path>` / `file://`. `UI/mac/InboundURLHandler` (the `handlesInboundURLs` modifier) attaches `handlesExternalEvents(preferring:allowing:)` + `onOpenURL` to each document window: every window `allowing: ["file:", "galley:"]` (so a brand-new URL lands on the key window — the tie-breaker), and a live document window additionally `preferring: model.documentURL.galleyPreferringTokens` (so a repeat-open of the same doc routes back to its window — dedup — regardless of focus). `DocumentView.handleInbound(_:)` then applies the user's `openBehavior`: same-doc → scroll + focus; `replaceCurrent` → rebind in place; `newWindow`/`newTab` → `openWindow(id:value:)` (born-as-tab when `NSWindow.allowsAutomaticWindowTabbing` is set).
- **`Models/Defaults`** (cross-platform, `@ObservableDefaults`) — UserDefaults-backed prefs. Persists `renderer`, `template`, `enablePerDocumentOverrides`, `openBehavior`, `editor`, `perFileStateStore`, `templateBackgroundColors`, `lastTemplateBackgroundColor`, `transparentToolbar`, `showsStatusBar`, `readingWordsPerMinute`. Keys without meaning on visionOS (`editor`, `transparentToolbar`) are still present but unused. `Defaults.warmCache()` posts a synchronous `UserDefaults.didChangeNotification` so the macro's per-property cache catches up to disk before the first WebKit-triggered notification arrives — otherwise `WKWebView.init` posts that notification synchronously from inside a SwiftUI layout pass, which re-enters AttributeGraph and crashes. The Server runs in a separate process and reads the same plist via `UserDefaults.standard` (since both apps share `net.leuski.galley` as the suite); `DefaultsBroadcast` translates Darwin notifications into local `didChangeNotification`s so cross-process writes propagate.
- **`Models/AppModel`** (cross-platform) — `@Observable @MainActor`. Single owner of Viewer-wide state: `templates: TemplateChoice`, `processors: ProcessorChoice`, `editors: EditorChoice` (macOS only — `DocumentModel.openInEditor` is `#if os(macOS)`-gated), `selectedSettingsTab` (Settings deep links land on the right pane). Constructed by `AppBoot` after `await ProcessorStore.shared.discover()`.
- **`Models/AppBoot`** (cross-platform) — `@Observable @MainActor`. Holds the `AppModel` once async hydration finishes; views branch on `boot.model` non-nil.
- **`Models/RecentDocumentsModel`** — `@Observable @MainActor`. Wraps `NSDocumentController.shared.recentDocumentURLs`, runs `NSOpenPanel` for File > Open. `record(_:)` refuses bundle URLs so help docs never land in recents. Bound by `FileCommands`.
- **`UI/mac/MacContentView`** — boot-gated wrapper for one document window. When the `Binding<DocumentTarget?>` is non-nil and `AppBoot.model` is ready, mounts `DocumentView`. While either is unresolved, this is the **invisible bootstrap member** (the `nil`-target `WindowGroup` instance SwiftUI materializes at cold launch — replaces the old `Window("welcome")`): it paints `Color.clear` + `BootWindowHider` (pins `window.alphaValue = 0`), hosts URL receipt via `handlesInboundURLs { self.target = $0 }`, captures `openWindow` for `NewTabAction.handler`, and runs the FTUE Open panel (`runFTUEIfNeeded()` — waits briefly, bows out via `dismissWindow()` if state restoration already produced a visible window).
- **`UI/mac/DocumentView`** — the viewer surface for a populated doc window. Owns the `DocumentModel`, the rename / PDF-export-error alerts, the `@SceneStorage("history")` blob, and the `windowAccessor`-based `NSWindow` adoption with re-attach support (SwiftUI caches scene `@State` for a freshly-closed `WindowGroup` window and reuses it when the same `DocumentTarget` reopens — a naive nil-guard would leave the reopened tab toolbar-less). Carries the per-window `handlesInboundURLs(enabled: model.kind == .document, preferring: model.documentURL.galleyPreferringTokens, onDocument: handleInbound)` — the dedup tokens track `model.documentURL` reactively, so in-window navigation updates the window's claim with no registry. `kind: .help` opts out of URL receipt entirely.
- **`UI/mac/HelpWindowView`** — content view for the singleton `Window("help")` scene; hosts `.onOpenURL` for `galley-help://` and mounts `DocumentView` in `.help` mode.
- **`UI/mac/NewTabAction`** — the static `NewTabAction.handler` (captured in `MacContentView`) runs the Open panel and `openWindow(id:value:)` with `NSWindow.allowsAutomaticWindowTabbing = true` so the tab bar "+" opens picks born-as-tab. `NewTabAction.install(on:)` patches the AppKit tab-bar "+" of each document window.
- **`UI/mac/Settings/`** — three panes (`GeneralSettingsView`, `MarkdownSettingsView`, `ServerSettingsView`) hosted by `MacSettingsView`'s `TabView`, selected by `appModel.selectedSettingsTab` (a deep-linked `galley-settings://?tab=<id>` lands here via `.onOpenURL`). Server pane drives `ActiveServerAgent` + a `ServerStatusPill` powered by `ServerStatusModel`.
- **`UI/mac/Menus/`** — split per command group: `FileCommands`, `EditCommands`, `ViewCommands`, `FormatCommands`, `HelpCommands`, `SettingsCommands`. All bind through `@FocusedValue(\.documentModel)` and `Action.*` so behavior stays consistent with the toolbar.
- **`Utilities/mac/ActiveServerAgent`** — typealias / swap point for the server-agent backend. The live backend is `LaunchctlServerAgent` (classic `~/Library/LaunchAgents/net.leuski.galley.server.plist`). The `SMAppService` alternative was removed: `SMAppService`-spawned helpers go through AMFI's launch-constraint check, which rejects ad-hoc-signed binaries with `Launch Constraint Violation` and (combined with `KeepAlive`) can respawn-loop. The active backend writes the plist with no `KeepAlive` and runs `validateAndRepair()` at launch to rewrite a stale absolute `Program` path if Galley.app has moved.
- **`Models/mac/DocumentModel+Print`** — three entry points (Print, Page Setup, Export as PDF) share one offscreen `WKWebView` path configured with `ClassicPreviewSchemeHandler`. Two non-obvious bits: `printInfo.horizontalPagination` / `verticalPagination` must be `.automatic` (otherwise the whole document prints onto a single tall page), and the operation must be dispatched via `runModal(for:delegate:didRun:contextInfo:)` — `runOperation()` produces blank pages.
- **Window visibility** — document windows open with `alphaValue = 0` and unhide on first non-nil `documentURL`. The invisible bootstrap member (`nil`-target `WindowGroup` instance) stays at `alphaValue = 0` until it adopts a document (or is dismissed by the FTUE flow).
- **Sandbox is disabled** on the Viewer target (both platform slices). The Server target is also unsandboxed — it needs to read arbitrary user files to render them.

### Viewer visionOS slice — `Sources/Viewer/*/vision/`

Far smaller surface than the macOS slice. No AppDelegate, no separate welcome bootstrap scene, no `WindowDispatcher`. URL dispatch is the same SwiftUI-native mechanism as macOS: a `nil`-target `WindowGroup(for: DocumentTarget.self)` member is the welcome surface; document URLs arrive via `handlesExternalEvents` + `onOpenURL` (or, for Mac-hosted docs, via Kosmos `OpenDocument` → `VisionKosmosService` synthesizing a `galley://` URL it `.open()`s). No menus. No external editor. No hosted server. Shares every cross-platform model (`DocumentModel`, `AppModel`, `AppBoot`, `Defaults`, `PerFileStateStore`, `SceneProcessorModel`, `SceneTemplateModel`, `ServerStatusModel`) and every cross-platform view (`Actions`, `FindBar`, `TOCSidebar`, `StatusBar`) with the macOS slice.

- **`UI/vision/Scenes/VisionViewerApp`** — `@main` on visionOS, two scenes: `VisionDocumentScene` (`WindowGroup(id: "document", for: DocumentTarget.self)` claiming `file:` + `galley:`) and `VisionSettingsScene` (`Window("Settings", id: "settings")` claiming `galley-settings://` — visionOS has no `Settings {}` scene). `init()` runs `Defaults.warmCache()` for the same WebKit-reentrancy reason as macOS and starts `VisionKosmosService`. Observes the **app-level** (aggregate) `scenePhase` to drive Kosmos `publishSuspend()` / `publishResume()` and `boot.model?.didChangePhase(...)` — keeping at least one window alive matters because visionOS suspends zero-scene apps, which would kill Kosmos and break Mac → AVP routing.
- **`Utilities/vision/VisionKosmosService`** — AVP-side Kosmos surface (subclass of `KosmosService<GalleyKosmosRole>`). Receives `OpenURL`, `OpenDocument` (carrying just `documentPath`), `WindowContentChanged`; routes inbound `ProxyHTTPResponseHead` / `ProxyHTTPResponseChunk` to a `KosmosHTTPTunnel.Client` it owns; sends `CloseWindow` and lifecycle (`publishSuspend` / `publishResume`). `handleOpenDocument` builds a `galley://local/preview/<path>` tunnel URL via `TunnelScheme.originURL.galleyPreviewURL(forFile:)` and fires it through `OpenDocumentActivity(...).open()` — so a Mac-routed open lands on the **same** `handlesExternalEvents` path as any local open. No cert pinning — document and sub-resource bytes ride Kosmos via the `galley://local` scheme handler.
- **`KosmosHTTPTunnel.Client`** (from the Kosmos package, owned by `VisionKosmosService`) + **`Utilities/vision/KosmosTunnelSchemeHandler`** — every `galley://local/<route>/<path>` URL the WebView fetches becomes a `ProxyHTTPRequest` Kosmos broadcast; response chunks are routed back through the client's `requestID → entry` map (`AsyncThrowingStream` continuation, accumulating buffer, optional streaming flag based on the response's `Content-Type`). Bounded responses are buffered and yielded to WebKit as a single `.data(buffer)` once `isFinal: true` arrives — `URLSchemeTask` doesn't reliably deliver multi-event `.data(...)` payloads, so PNG/JS decoders see truncation otherwise. SSE event-streams (`text/event-stream`) bypass the buffer and yield each chunk immediately for line-level latency. WebKit cancellation (`AsyncThrowingStream.onTermination`) publishes a `ProxyHTTPCancel` so the Mac drops the upstream `URLSession` task. The `Client` is product-neutral; the scheme handler is what stamps `X-Galley-Origin: galley://local` on every outbound request so the Mac's `templateOriginURL` composes `<base href="galley://local/preview/<docparent>/">` and every sub-resource fetch stays on this scheme handler.
- **`Models/Defaults`** (shared with macOS) — the keys that have meaning on visionOS are `renderer`, `template`, `enablePerDocumentOverrides`, `perFileStateStore`, `templateBackgroundColors`, `lastTemplateBackgroundColor`, `showsStatusBar`, `readingWordsPerMinute`. macOS-only keys (`editor`, `openBehavior`, `transparentToolbar`) are present in the struct but unused on visionOS. `enablePerDocumentOverrides` is read by the shared `DocumentModel.resolvedRenderer` / `resolvedTemplate`; stays `false` for v1.
- **`Models/AppBoot`** (shared) — on visionOS the `ProcessorStore.shared.discover()` call returns the built-in renderer only, since external CLI processors are unreachable.
- **`Models/vision/DocumentModel+Export`** — visionOS-specific export plumbing.
- **`UI/vision/VisionContentView`** — boot gate / per-window identity. Progress spinner while `boot.model` is nil; otherwise branches on the `Binding<DocumentTarget?>`: `nil` → `VisionWelcomeScreen`, non-nil → `VisionDocumentScreen`. Watches per-scene `scenePhase` so the last-window dismiss path fires `boot.model?.didDismissWindow(...)` + `dismissWindow()`.
- **`UI/vision/VisionWelcomeScreen`** — landing surface when the WindowGroup binding has no URL. "Open Document…" button + a Recent list drive `.fileImporter` (visionOS-native Files.app picker); picking a file **rebinds this window's `target`** (flips welcome → document in place, no second window). Also carries `handlesExternalEvents(preferring: ["*"], allowing: VisionDocumentScene.events)` + `.onOpenURL` so an inbound `galley://` URL flips an empty window into a document.
- **`UI/vision/VisionDocumentScreen`** — the document chrome (NavigationSplitView TOC + WebView with FindBar/StatusBar + bottom-ornament toolbar). Carries `handlesExternalEvents(preferring: target.documentURL.galleyPreferringTokens, allowing: openBehavior == .replaceCurrent ? VisionDocumentScene.events : [])` + `.onOpenURL` — same per-window dedup/route pattern as the macOS `DocumentView`, with `replaceCurrent` reusing this window and other behaviors spawning a new one.
- **`UI/vision/VisionSettingsView`** — visionOS settings surface, reached via the toolbar gear (`openWindow(id:)`) or a `galley-settings://` deep link.

### `Sources/Server/` — Galley Server menu-bar app (macOS)

- **`ServerApp`** — `@main`, single Scene: `MenuBarExtra` hosting `MenuBarContent`. Label is `Image("MenuBarIcon")`. Uses `@NSApplicationDelegateAdaptor(ServerAppDelegate.self)`. Hydration is gated on `AppBoot` (the menu shows "Starting…" until the model resolves). The Server does not host a SwiftUI `Settings` scene of its own — preferences are surfaced inside `MenuBarContent`.
- **`App/AppModel`** — `@Observable @MainActor`. Owns the `templates: TemplateChoice` and `processors: ProcessorChoice` envelopes, the `PreviewServerController`, the `ServerKosmosService`, and the Server's own `@ObservableDefaults Defaults` class (conforms to `GalleyRenderDefaults` + `HTTPServerDefaults` + `BroadcastedDefaults`). On each `PreviewServerController` state change, writes `Defaults.shared.serverHTTPPort` (the OS-assigned port from `state = .running(url:)`, or `0` on stop/failure) and posts `Defaults.shared.post()` so Viewer/Quicklook see the update. The first `.running` / `.failed` also starts the `ServerKosmosService` with the URL as advertise-time `MetadataKey.httpURL` metadata. Renderer + template selection is read at request time via `@Sendable` closures, so switching processor/template in the menu takes effect on the next request without server restart. (`App/AppBoot` runs `ProcessorStore.discover()` + single-instance enforcement before constructing the model.)
- **`App/ServerAppDelegate`** — `NSApplicationDelegate`. Receives Finder file opens and `galley-bridge://` URL opens, dispatches each through `ServerKosmosService` — if a reachable AVP peer is available, publishes `OpenDocument` via Kosmos; otherwise falls back to `NSWorkspace.open(galley://path)` to launch Galley.app.
- **`App/ServerKosmosService`** — `@Observable @MainActor`, a subclass of `KosmosService<GalleyKosmosRole>` (from `KosmosTransport`). The generic boilerplate — host bootstrap, peer-watch, subscription bookkeeping, stop, the peer-role mirror, and suspend/resume reachability gating — lives in the shared `KosmosServiceHost` + `PeerReachabilityTracker`; `isAVPReachable` is just `host.reachablePeer(deviceType: .vision) != nil`. What's left here is purely Galley's: the per-window open-on-AVP registry (`KosmosCore.WindowID → fileURL + peerID + watchTask`), the AVP-doff migration path (last vision peer leaves → `NSWorkspace.open(galley://path)` per open window), and the `RouteToAVP` handler (routed through the same dispatch path Finder-opens take). It also hosts a `KosmosHTTPTunnel.Responder` (constructed with `upstreamBaseProvider: { Defaults.shared.serverEndpointURL }`) that turns inbound `ProxyHTTPRequest` messages into `URLSession` data tasks against the loopback HTTP listener and streams `ProxyHTTPResponseHead` + chunked `ProxyHTTPResponseChunk`s back. The `Responder` (in the Kosmos package) owns the in-flight `requestID → Task` map and picks per request between a **buffered fast path** for bounded responses (`URLSession.data(for:)` → `URLBuilder.chunks(of:requestID:chunkSize:)` slicing into 64 KB chunks, final carrying `isFinal: true`) and a **streaming path** for SSE event-streams (`URLBuilder.requiresStreaming(urlPath:)` matches `/events/*`; drains `URLSession.AsyncBytes`, flushing on each newline or 64 KB safety valve). `ProxyHTTPCancel` tears down the matching task. The `galley-bridge://` scheme value type is `App/GalleyBridgeRequest.swift` (its own file). The preview server stays loopback-only at all times.
- **`Menu/MenuBarContent`** — the entirety of the Server's UI: server state, processor + template quick-switchers, BBEdit script installer entry, a Settings entry, and Quit.

## Concurrency conventions

- UI-facing state (`AppModel` in both Viewer and Server, `DocumentModel`, `ViewerKosmosService` / `VisionKosmosService` / `ServerKosmosService`, `KosmosClient`, `RecentDocumentsModel`, scene/per-file stores, `ServerStatusModel`) is `@MainActor`.
- The HTTP server runs in a background `Task`; route handlers are `async` and capture only `Sendable` collaborators (closures, actors, value types).
- Renderer + template selection is read at request time via `@Sendable` provider closures rather than via shared mutable state — there is no dedicated `CurrentRenderer` actor.
- The routing value types in `GalleyCoreKit/Routing/` + `Utilities/Activities.swift` are `Sendable`; window selection is SwiftUI's `handlesExternalEvents`, and the only live `NSWindow` references are the per-window `hostWindow` captured inside each `DocumentView` via `windowAccessor`.
- `@ObservationIgnored` is used for collaborators that should not trigger view invalidation (watchers, bridges, server controller, stores keyed by ID).
- Swift 6 strict concurrency is enabled; prefer typed throws, `Sendable` value types, and structured concurrency.

## Reference

- `docs/test-framework.md` — the test pyramid (routing logic / app logic / snapshot / UI / integration), where each kind of test goes, the launch-arg conventions for tests.

## Architecture decisions

### Two apps sharing frameworks; Viewer is one target on two platforms

The codebase tried a single-bundle factoring (Viewer with embedded server, soft-quit, activation-policy switching) and reverted to two macOS apps sharing frameworks. Reasons the split won:
- Viewer wants `.regular` always; Server wants `MenuBarExtra`-only with `LSUIElement`. Reconciling those into one bundle required activation-policy juggling (soft-quit, `applicationWillFinishLaunching` policy restore, `applicationShouldHandleReopen` re-entry) — substantial complexity for the convenience of one bundle.
- Engine sharing is what actually matters, and the framework targets give that without forcing a single process model.

Adding a visionOS Viewer did *not* introduce a third target. The same `Viewer` target builds for `macosx` and `xros/xrsimulator`; platform-specific code lives in `mac/` and `vision/` subfolders and is wrapped in `#if os(macOS)` / `#if os(visionOS)` guards. Both platform slices link only `GalleyCoreKit`. The Quicklook extension is a separate target and links `GalleyCoreKit` directly for its in-process render fallback.

### Frameworks not SwiftPM

The shared engine is two **Xcode framework targets** (`GalleyCoreKit`, `GalleyServerKit`), not a Swift Package. The earlier SwiftPM `Kit/` package was abandoned because `xcodebuild` test discovery for embedded local packages was unreliable while Xcode's GUI-driven test runs worked fine — a CI/scriptability liability the framework targets sidestep.

### Single Viewer target, two platforms, `mac/` and `vision/` subfolders

Earlier iterations had a separate `Sources/ViewerShared/` source folder compiled into both a `Viewer` (macOS) and a `Viewer.vision` (visionOS) target. That factoring is gone. There is now one `Viewer` target with `SUPPORTED_PLATFORMS = "macosx xros xrsimulator"`, and platform-specific files live alongside cross-platform ones in `mac/` and `vision/` sibling subfolders (under `App/`, `Models/`, `Views/`, `Utilities/`, `Resources/`).

Reasons for the consolidation:

- A separate target paid for an `Info.plist` membership-exclusion dance and a duplicated entitlements/codesign setup. One target, one Info.plist, one entitlement file is just less moving stuff.
- The `mac/` / `vision/` convention plus `#if os(macOS)` / `#if os(visionOS)` body guards keep the platform fences inside a single file and a single target. The folder name is documentation; the `#if` is what's load-bearing — files in `mac/` still ship to the visionOS slice's compile, they just produce nothing when guarded properly. Don't rely on folder-based membership exclusion.
- Cross-platform code (`DocumentModel`, `AppModel`, `AppBoot`, `Defaults`, `Bridges/`, `Views/Actions.swift`, `FindBar`, `TOCSidebar`, `StatusBar`, etc.) sits at the parent level inside `Sources/Viewer/...` and is shared automatically.
- The earlier `Sources/ViewerShared/` source folder is gone entirely — its contents migrated into `Sources/Viewer/` when the targets merged. If you need a place for resources that must live outside the Viewer bundle, reintroduce it deliberately rather than discovering a leftover stub.

When adding a file: cross-platform → parent directory; platform-specific → `mac/` or `vision/` subfolder *and* `#if` guard the body.

### FlyingFox replaces Hummingbird (with an adapter so call sites didn't change)

The HTTP server was originally FlyingFox. It was swapped for Hummingbird (briefly with `HummingbirdTLS`) so the Server could present a self-signed certificate over HTTPS to AVP. That HTTPS path is gone — AVP now tunnels every WebKit fetch back through Kosmos via `ProxyHTTPRequest`, and the Mac runs a single loopback HTTP listener for every consumer (Quicklook, BBEdit, browsers, and the AVP tunnel responder).

With HTTPS gone, Hummingbird's reason to exist disappeared. The graph cleanup was: Loom split its SSH bootstrap into its own target so `Loom` core no longer pulls `swift-nio` / `swift-nio-ssh`; Kosmos (which links only `Loom` core) then carries zero NIO. That left Hummingbird as the only NIO consumer in the project. Swapping it for FlyingFox (zero-dep on Apple platforms — just FlyingFox + FlyingSocks) collapses the entire NIO/server-infra cluster: `swift-nio`, `-ssh`, `-ssl`, `-http2`, `-extras`, `-transport-services`, `async-http-client`, `swift-distributed-tracing`, `swift-service-context`, `swift-metrics`, `swift-service-lifecycle`, `swift-http-structured-headers`, `swift-configuration`, `swift-atomics` — all gone.

To keep the route bodies reading like Hummingbird code, FlyingFox sits behind a Hummingbird-API-shaped shim (`Application`, `Router<BasicRequestContext>`, `Request`, `Response`, `ResponseBody`, `ByteBuffer`, plus a `PushBufferedSequence` that bridges Hummingbird's push-based `ResponseBody { writer in ... }` to FlyingFox's pull-based `AsyncBufferedSequence<UInt8>` for SSE). The route bodies read like Hummingbird code; only the imports changed. `swift-http-types` is kept (small, no NIO) so `HTTPField.Name.contentType` etc. work verbatim — `Routes.swift` uses ~10 well-known header names plus a handful of custom ones (`Sec-Fetch-Site`, `X-Frame-Options`, etc.) that would otherwise need a sweep too.

This adapter — together with `HTTPServerController`, SSE, `HTTPResponses`, and `guardedRequest` — has since been **extracted into the standalone `KosmosHTTPServer` sibling package** (`../KosmosHTTPServer`), which owns the FlyingFox and swift-http-types dependencies. `GalleyServerKit` `@_exported`s it and now contains only Galley's route table (`Routes.swift`), the `PreviewServerController` facade, and localized error pages. If you ever need to swap FlyingFox out for something else, `KosmosHTTPServer`'s `Adapter/` is the only file set that touches the underlying server library — and it's product-agnostic, so the change lands once for every consumer.

### OS-assigned port, not fixed

The loopback HTTP listener binds to `127.0.0.1` on an OS-assigned port; the port is published to the shared `net.leuski.galley` defaults plist under `serverHTTPPort`. Same-machine readers (Quicklook, future Viewer surface) compose the URL via `Defaults.shared.serverEndpointURL` from `HTTPServerDefaults`. The user-configurable port setting is gone — fewer footguns when two processes try to listen on the same number.

### `WindowGroup(for: DocumentTarget.self)` not `DocumentGroup`

`DocumentGroup(viewing:)` was the original choice and was abandoned. Two reasons: `DocumentGroup` ties one window to one `FileDocument` (titles, state restoration, revision history all assume "this window represents this file"), but the Viewer is a *navigator* — one window walks through linked Markdown documents (`a.md` → click link → `b.md` rebinds the window's URL). And `DocumentGroup` attaches the title-bar "document menu" hover popover, which is wrong for a read-only viewer. The WindowGroup's value type is `DocumentTarget` (a `Codable`/`Hashable` `documentURL` + optional `scrollLine`), not a bare `URL`, so a `?line=N` scroll hint survives state restoration and the Kosmos wire.

### SwiftUI-native URL dispatch (replaces `WindowDispatcher` + `Window("welcome")`)

URL → window routing on **both** platforms is done by SwiftUI's `handlesExternalEvents`, not a hand-rolled dispatcher. This replaced an earlier design built around a central `WindowDispatcher` + `WindowRegistry` + `OpenURLRouter` + a `Window("welcome")` bootstrap scene; all of that was removed. (This reverses the earlier "no `handlesExternalEvents`" stance — see the matrix below for how it covers `newTab` / `replaceCurrent` / dedup, which were the original objections.)

How it works:

- **Three inbound schemes, three scene owners.** `OpenDocumentActivity` (`galley://` + `file://`) routes to the document `WindowGroup`; `OpenSettingsActivity` (`galley-settings://`, optional `?tab=<id>`) and `OpenHelpActivity` (`galley-help://`) each claim their scheme on a singleton `Window` scene (`handlesExternalEvents(matching:)`), so SwiftUI delivers settings/help URLs straight to those windows and a document window only ever sees document URLs. Each activity is `URLSerializable` and `.open()`s itself — that's how the Server, the menu bar, the Help/Settings menu items, and the AVP Kosmos receiver all dispatch: build the URL, open it.
- **Per-window claim = catch-all + dedup.** Each document window attaches `handlesExternalEvents(preferring: documentURL.galleyPreferringTokens, allowing: ["file:", "galley:"])`. The `allowing` catch-all means a brand-new URL lands on the key window; the `preferring:` tokens (raw URL, standardized file URL, `galley://` form, query stripped) mean a repeat-open of a doc routes back to the window already showing it (dedup) regardless of focus. `onOpenURL` then runs the window's `handleInbound`, which applies the user's `openBehavior` (`replaceCurrent` rebinds in place; `newWindow`/`newTab` calls `openWindow(id:value:)`, born-as-tab when `NSWindow.allowsAutomaticWindowTabbing` is set — tabbing is pinned per-process in `MacViewerApp.pinWindowTabbingPreference()`).
- **No welcome scene.** `WindowGroup(for: DocumentTarget.self)` does not auto-spawn a window at cold launch, but SwiftUI materializes one `nil`-target *member* of the group; `MacContentView` uses that member as the invisible bootstrap anchor (captures `openWindow`, hosts URL receipt, runs the FTUE Open panel, stays `alphaValue = 0` until it adopts a document). The old separate `Window("welcome")` scene + `BootstrapDispatchModifier` are gone.
- **No `ViewerAppDelegate`.** The macOS Viewer no longer installs an `NSApplicationDelegateAdaptor` at all.

visionOS uses the identical pattern (a `nil`-target member is the welcome surface; `VisionDocumentScreen` carries the same `preferring:` dedup), minus tabs and minus the AppKit window-tabbing substrate.

### Server is the AVP routing authority; all three runtimes are Kosmos peers

The Vision Pro path looks like it could live in Galley.app — the Viewer is the user-facing surface, the Viewer already renders Markdown, the Viewer is what you'd guess from the outside. It doesn't. The Server is the AVP routing authority. Three requirements drive that:

1. **Open-document routing has to decide before any Mac window exists.** When Finder opens `foo.md`, the system needs an authority that can answer "is AVP paired right now? If yes, push to AVP. If no, route to Galley.app." Galley.app is `.regular` — Dock icon, document-app semantics, state restoration, heavy launch. Spawning it just to ask "is AVP here?" defeats the whole point. The Server is already `LSUIElement` / `MenuBarExtra` and is the persistent always-on process in this system (typically launch-at-login). So the Server is the `LSHandler` for `.md` and for the routing-aware URL scheme, and decides where the document goes.

2. **Live reload to AVP must come from the peer owner.** Whoever holds the Kosmos peer to AVP has to own the file watch — two processes racing on FSEvents with one pushing reloads the other doesn't know about is a bug factory. The Server already runs `DocumentWatcher` for HTTP SSE live-reload subscribers; AVP is just another subscriber on the same watch.

3. **Take-off-AVP handoff requires the routing authority to launch Galley.app.** When the user removes the headset, the docs currently on AVP should come up in Galley.app. The Server sees the AVP peer disconnect (via Kosmos), knows the set of docs currently displayed on AVP, and launches Galley.app via `NSWorkspace.open(galley://path)` for each. Galley.app being launched-on-demand (not always-on) depends on the Server being the entity that observes the disconnect and triggers the launch.

#### Kosmos carries both planes; HTTP loopback is same-machine only

All three runtimes — Server, Galley.app (Mac Viewer), and the AVP viewer — are **Kosmos peers**. There is no file-based handshake, no Mac-local IPC channel, no "ask the Server whether AVP is paired" RPC. Presence and routing both ride Kosmos. The cost is the Kosmos stack in Galley.app's and AVP's address spaces; the win is one protocol for control on the wire instead of three.

The data plane split, in two cases:

- **Same-machine consumers** (Quicklook, browsers, BBEdit scripts) hit the Server's loopback HTTP listener via `Defaults.shared.serverEndpointURL` (`HTTPServerDefaults`). The port lives in the shared `net.leuski.galley` defaults plist (`serverHTTPPort`); Quicklook reads it through its own `Defaults` class plus the suite's `temporary-exception.shared-preference.read-only` entitlement; BBEdit scripts read it via `defaults read net.leuski.galley serverHTTPPort`. No TLS, no pinning — `127.0.0.1` is its own trust boundary. The Mac Viewer doesn't currently dial the loopback listener itself — its `Defaults` class still conforms to `HTTPServerDefaults` to keep the shared-suite contract honest, but it isn't a reader.
- **AVP** tunnels through Kosmos. The WebView is configured with a `galley://local` URL scheme handler (`KosmosTunnelSchemeHandler`); every request — the document, every CSS / JS / image / font, the SSE `/events/<path>` stream — becomes a `ProxyHTTPRequest` Kosmos broadcast, executed against the Mac's loopback listener by `KosmosHTTPTunnel.Responder` (hosted by `ServerKosmosService`), and streamed back as `ProxyHTTPResponseHead` + chunked `ProxyHTTPResponseChunk` messages. The literal scheme host is the sentinel `local` (so `URLComponents` parsing is unambiguous), and every tunneled request carries `X-Galley-Origin: galley://local` so the Mac's `templateOriginURL` composes a `<base href="galley://local/preview/<docparent>/">` and every sub-resource fetch stays on the scheme handler. No HTTPS over the LAN, no cert pinning, no AWDL ingress concerns.

Same `/preview/<path>` + `/template/<id>/<file>` + `/events/<path>` route surface either way; only the data-plane transport differs.

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
| Mac Viewer menu: "Show on Vision Pro" | Mac Viewer → Server via Kosmos `RouteToAVP { target: DocumentTarget }` → Server constructs `OpenDocument` → AVP via Kosmos |
| AVP-local `.fileImporter` open | AVP renders locally via `SwiftMarkdownRenderer` + bundled template. No Kosmos, no Server. |
| AVP take-off handoff | Server observes AVP peer drop → `NSWorkspace.open(galley://path)` per active doc |
| Server status pill in Mac Viewer | Reads Server peer presence via Kosmos (was: HTTP probe) |
| "Show on Vision Pro" menu enabledness | Reads AVP peer presence via Kosmos (was: `AVPReachabilityFile`) |
| Mac-doc HTML / assets / live reload to AVP | Kosmos tunnel. WebKit's `galley://local/preview/<path>` request → `KosmosTunnelSchemeHandler` → `KosmosHTTPTunnel.Client` → `ProxyHTTPRequest` → `KosmosHTTPTunnel.Responder` (hosted by `ServerKosmosService`) → loopback HTTP → response chunks back via `ProxyHTTPResponseHead` + `ProxyHTTPResponseChunk` messages. Same `/preview/<path>` + `/template/<id>/<file>` + `/events/<path>` route surface as same-machine HTTP loopback; SSE flushes line-by-line, bounded responses are buffered on AVP and yielded as a single `.data` to WebKit. |
| Mac-doc HTML / assets / live reload to Quicklook | HTTP loopback (`http://127.0.0.1:<port>/`) via `Defaults.shared.serverEndpointURL`. No pinning. Falls back to in-process render when the port is 0. |

#### Kosmos message inventory

Two surfaces — control and the HTTP tunnel data plane.

**Control plane:**

| Message | Sender → Receiver | Purpose |
|---|---|---|
| `OpenDocument { docID, documentPath, displayName, scrollLineHint?, openBehavior }` | Server → AVP | Open or re-target an AVP window for a Server-hosted doc. AVP synthesizes the `galley://local/preview/<path>` URL via `KosmosTunnelScheme.previewURL(forFile:)`; bytes ride the tunnel. |
| `RouteToAVP { target: DocumentTarget }` | Mac Viewer → Server | "User chose Show on Vision Pro — please dispatch this file." Server constructs and sends the `OpenDocument`. The reply carries `accepted: Bool` so the Mac Viewer can log whether AVP took it. |
| `WindowContentChanged { windowID }` | Server → AVP | The file behind the named AVP window changed (FSEvents); receiver reloads its WebView. |
| `CloseWindow { windowID }` | AVP → Server | User closed an AVP-side document window; Server drops its tracking entry and cancels the file watcher. |
| `AppWillSuspend` / `AppDidResume` | AVP → Server | `scenePhase` transitions on AVP. Mac gates `isAVPReachable` on the most recent of these so dispatch doesn't land in a suspended process. |

**Data plane (HTTP tunnel):**

| Message | Sender → Receiver | Purpose |
|---|---|---|
| `ProxyHTTPRequest { requestID, method, urlPath, headers, body }` | AVP → Server | A WebKit fetch on `galley://local/<route>/<path>`; the receiver issues a `URLSession` task against the loopback HTTP listener. `urlPath` is `URLComponents.percentEncodedPath` verbatim (the sentinel host `local` is discarded). Every request carries `X-Galley-Origin: galley://local` so the Server's `templateOriginURL` uses that as the `<base href>`. |
| `ProxyHTTPResponseHead { requestID, status, headers }` | Server → AVP | HTTP status + headers for an in-flight tunneled request. AVP inspects `Content-Type`: `text/event-stream` → streaming mode (yield each chunk immediately); anything else → buffering mode (accumulate and yield once on `isFinal`). |
| `ProxyHTTPResponseChunk { requestID, sequence, bytes, isFinal }` | Server → AVP | Body bytes; multiple per request. Bounded responses use the Mac's buffered fast path (`URLSession.data(for:)` → 64 KB chunks); SSE uses the streaming path (`URLSession.bytes(for:)` → flush per newline / 64 KB). |
| `ProxyHTTPCancel { requestID }` | AVP → Server | WebKit cancelled or page navigated away; drop the matching upstream task. Also published by AVP on `AsyncThrowingStream.onTermination`. |

Adding to either list is a smell. `DocumentWatcher` still tracks SSE subscribers and drops files when the last subscriber disconnects — when AVP closes a `WebPage`, the scheme handler cancels its `URLSchemeTask`, the tunnel emits `ProxyHTTPCancel`, the Mac drops the `URLSession` task, and the watcher cleans up.

#### Routing layer reuse on AVP

`OpenBehavior` (from `KosmosCore`) and `DocumentTarget` (from `KosmosAppKit`) are platform-agnostic and shared by AVP; `WindowID` + `WindowIDAllocator` (also `KosmosCore`) are the one identifier type for both the local windowing and the Mac↔AVP wire. AVP has no central dispatcher at all — like macOS, it relies on SwiftUI's `handlesExternalEvents`. Inbound `OpenDocument` is handled by `VisionKosmosService`, which synthesizes a `galley://local/preview/<path>` URL and `.open()`s it; SwiftUI routes that to a `WindowGroup(for: DocumentTarget.self)` window (`replaceCurrent` reuses the current window via the `preferring:`/`allowing:` claim in `VisionDocumentScreen`, otherwise a new one spawns). `VisionKosmosService` keeps its own `WindowID → WindowInfo` map for reload callbacks and close notifications; there is no `WindowRegistry` value type anymore.

#### Why Server→Mac Viewer stays on `NSWorkspace.open(galley://)`, not Kosmos

Kosmos can only message **running** peers — it cannot spawn a process. The Server-to-Mac-Viewer path needs to launch-or-wake Galley.app and deliver the URL atomically; LaunchServices does that in one shot. Using Kosmos would require a separate launch step followed by waiting for the new peer to register before sending, splitting one operation into a race. The URL-scheme path also keeps cold-launch and warm-launch on the same code path.

#### What is intentionally separate from this layer

- **The Server's HTTP listener** is its own surface for browsers and Quicklook. The Server-status pill in Mac Viewer reports peer presence (the better signal); if you ever need to distinguish "process up, HTTP wedged" from "process up, HTTP fine," do it with a Kosmos-level health ping, not by reintroducing an HTTP probe from inside the same machine.

#### Do not undo this

When tempted to:

- move Kosmos into Galley.app and let it be the routing authority — re-read requirements (1) and (3);
- add a second IPC seam (file, RPC, XPC) for "the one signal Mac Viewer needs from Server" — that's how the previous design accreted; Kosmos peer presence already answers it;
- merge `galley://` and `galley-bridge://` into one scheme — you will silently change the semantics of every existing BBEdit / Xcode integration.
