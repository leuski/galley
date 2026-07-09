# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Two apps and a Quick Look extension sharing one rendering engine, with the Viewer app shipping on two platforms from a single target. **There is no longer an HTTP server** — the preview engine renders in-process; AVP receives rendered bytes over the Kosmos tunnel, and Quick Look renders in-process. (See Architecture decisions → "The HTTP server was removed" for the full history — `GalleyServerKit`, FlyingFox, and the whole loopback-HTTP path are gone.)

- **Galley** (bundle id `net.leuski.galley`, target `Viewer`, product `Galley`) — native document viewer. Same target builds for **macOS** (`macosx`) and **visionOS** (`xros` / `xrsimulator`); the project's `SUPPORTED_PLATFORMS` is `"macosx xros xrsimulator"`. Platform-specific code lives under per-platform subfolders (`Sources/Viewer/UI/mac/` vs. `Sources/Viewer/UI/vision/`, and the same `mac/` / `vision/` split inside `Models/`); cross-platform code — including the SwiftUI `App` entry point (`UI/ViewerApp.swift`) and all three scenes (`DocumentScene` / `HelpScene` / `SettingsScene`) — sits at the parent level and is compiled into both, branching internally on `#if os(macOS)` / `#if os(visionOS)`. macOS surface: `WindowGroup(id: "document", for: DocumentSceneID.self)` over a `WebPage`-backed `WebView`, Cmd-click → editor, full menu bar, embedded Server, custom URL schemes (`x-galley://local` for template/asset resolution; `galley-viewer://<path>?line=N` for direct opens into Galley.app; `galley-settings://` / `galley-help://` for the Settings / Help singleton windows). A window is a **`WindowModel`** holding one or more **`DocumentModel` tabs** (`AbstractWindowModel<DocumentModel>`). visionOS surface: the same `WindowGroup` with `.fileImporter` for the empty case; no menus, no embedded Server; receives Mac-hosted documents via Kosmos (see Architecture decisions). **URL dispatch on both platforms is SwiftUI-native** — `handlesExternalEvents` routes inbound `galley-viewer://` / `file://` URLs to the right window; there is no `WindowDispatcher` and no `Window("welcome")` (see Architecture decisions → "SwiftUI-native URL dispatch"). The window's value is a minted-UUID `DocumentSceneID`, not the document URL (see Architecture decisions → "UUID window identity").
- **Galley Server** (bundle id `net.leuski.galley.server`, target `Server`, macOS) — **faceless** background app that is the routing authority for inbound document opens (`galley://` is the Server's LSHandler — it decides AVP-or-Mac) **and** the in-process render host for the AVP tunnel. **Release is faceless** — `Settings { EmptyView() }` + `LSUIElement`, no Dock icon and no menu-bar item; LaunchServices cold-launches it on demand. **DEBUG** shows a minimal `MenuBarExtra` with only a "Quit" item. There is **no `MenuBarContent`**, no processor/template quick-switcher UI, and no `AppBoot`. It owns the Kosmos host + AVP bridge and hosts the `KosmosHTTPTunnel.Responder` (backed by an **in-process** `InProcessTunnelBackend`, not a loopback HTTP round-trip) — all in `ServerKosmosService` (`Sources/Server/App/`). Galley.app embeds `Galley Server.app` inside its bundle; the launch-agent stack (`ActiveServerAgent` / `LaunchctlServerAgent` / `SingleProcessInstance`, in the sibling `KosmosAppKit` package) is still wired from the Viewer's `Models/AppModel.swift` (`ActiveServerAgent.shared` + `Bundle.serverBundle`), which validates/repairs a stale helper at boot — but there is **no user-facing enable toggle** anymore (the Server settings pane was removed).
- **Quicklook** (target `Quicklook`, product `Quicklook.appex`, macOS) — `QLPreviewingController` extension. The code path is still "prefer the running Server over HTTP, else in-process," but with no HTTP listener shipping (`serverHTTPPort` is always 0 → `serverEndpointURL` is nil), it **always renders in-process** with the built-in Swift renderer, honoring the user's selected template. A QL preview appex **cannot** make in-process network connections (sandbox denies outbound network even with `network.client`), so QL-over-Kosmos is impossible; in-process is the only viable path. See memory `quicklook-appex-no-inprocess-network`.

The shared engine ships as **one** Xcode framework target — `GalleyCoreKit` (Galley-specific rendering, templates, choice values, scheme handler, routing value types, shared Kosmos surface, shared defaults protocols, the transport-neutral preview service, and the in-process tunnel backend). There is **no `GalleyServerKit`** (deleted). The generic, product-agnostic pieces live in **sibling Swift packages** alongside `Galley.xcodeproj`:

- **`Kosmos`** (`../Kosmos`) — `KosmosCore` + `KosmosTransport` (peer mesh, roles, `KosmosService`/`KosmosServiceHost`, `WindowID`) and `KosmosHTTPTunnel` (`Responder` / `Client` / `URLBuilder` / `TunnelScheme` / `TunnelBackend` / `TunnelResponseEvent` — the `kosmos://local` surface that turns `ProxyHTTPRequest` / `ProxyHTTPResponse*` into `TunnelBackend` calls and streams the result back). The three products are re-exported by one dynamic library, `Kosmos`.
- **`KosmosAppKit`** (`../KosmosAppKit`) — shared app-level primitives: the `SelectableModel` / `SelectablePolicy` choice base and its `PersistentSelectionRepresentation`, the `PersistentModelManager` / `PersistentModelCache` / `AbstractWindowModel` window/tab base, the `Property(...).bind(toAndFrom:)` persistence binder, `DocumentWatcher`, `DefaultsBroadcast`, the `DefaultsProtocol` / `HTTPServerDefaults` / `BroadcastedDefaults` contracts, the launch-agent stack (`ActiveServerAgent` / `LaunchctlServerAgent` / `SingleProcessInstance`), `URL.computeHash`, `onObservedChange`/`Cancellable`, and shared SwiftUI/Foundation helpers. **This package still depends on `swift-core-kit`/`ALFoundation`** — that is how ALFoundation's `Process.runAndCapture` / `URL.itemExists` / `.parent` / `/`-operator helpers reach Galley now that Galley itself no longer references `swift-core-kit` directly (see the ALFoundation section).
- **`MarkdownHTMLKit`** (`../MarkdownHTMLKit`) — wraps `swift-markdown` (pinned 0.8.0); backs `GalleyCoreKit`'s `SwiftMarkdownRenderer`.
- **`KosmosHTTPServer`** (`../KosmosHTTPServer`) — the old FlyingFox-backed loopback HTTP server. **Now an orphan on disk — not referenced by `Galley.xcodeproj` at all.** FlyingFox and swift-http-types left the dependency graph with it. Kept on disk only in case the HTTP transport is ever reinstated behind the `PreviewHTTPListener` seam.

Link map: `GalleyCoreKit` links `KosmosAppKit`, `MarkdownHTMLKit`, the three Kosmos products, and `ObservableDefaults` (and `@_exported`s `KosmosAppKit`, `ObservableDefaults`, and `KosmosCore`). The **Viewer** (both slices), **Server**, and **Quicklook** all link `GalleyCoreKit` (which pulls the rest transitively). No target links a server kit.

The Galley-specific Kosmos surface in this repo is `Sources/GalleyCoreKit/Utilities/GalleyKosmos.swift`: `GalleyKosmosRole` (`.server` / `.macViewer` / `.visionViewer`; conforms to Kosmos's `Role`), the `MetadataKey<URL>.httpURL` accessor (wire key `galley.http-url`), and the Galley request/reply messages — `RouteToAVP` (Mac Viewer → Server: "Show on Vision Pro"), `RouteToTunnelClient` (Server → AVP: open this document on the tunnel client, carries `target` + optional `deviceType`), and `OpenInEditor` (open a document in the resolved editor on the Mac). Generic peer/window/lifecycle messages (`OpenURL`, suspend/resume) come from the Kosmos package. Peer classification + AVP-reachability live on `KosmosServiceHost` as product-scoped queries (`presentPeer(role:onHost:)`, `reachablePeer(deviceType:)`). No HTTPS, no cert pinning — AVP renders Mac-hosted documents by tunneling each WebKit fetch back through Kosmos via the `kosmos://local` scheme handler, which the Server answers by rendering in-process.

Localized strings live in `Localizable.xcstrings` per target. `Sources/Viewer/Resources/Localizable.xcstrings` is shared across the Viewer's macOS and visionOS slices. Server, GalleyCoreKit (which now also carries the moved error-page strings), and Quicklook each have their own. English and Russian are shipped.

`README.md` is **stale** — it still documents an HTTP server, HTTP routes, and `GalleyServerKit`. Trust this file over the README until the README is updated. Template placeholders and BBEdit integration in the README are still broadly accurate.

## Layout

```
Galley.xcodeproj              # 6 targets: GalleyCoreKit, Server, Quicklook,
                              #            Viewer (macOS + visionOS), Tests, UITests
Sources/
  GalleyCoreKit/              # the ONE framework — Galley-specific rendering,
                              # templates, choice values, routing, scheme handler,
                              # transport-neutral preview service, in-process tunnel
                              # backend. Generic primitives live in KosmosAppKit.
    Accessibility/              # ViewerAccessibilityIdentifiers (ViewerA11yID),
                                # ServerAccessibilityIdentifiers (ServerA11yID)
    Models/                     # ProcessorModel (ProcessorPolicy + ProcessorChoice),
                                # TemplateModel (TemplatePolicy + TemplateChoice),
                                # Editor (Editor / InvocationStyle / EditorPolicy /
                                # EditorStore / EditorChoice — external-editor choice,
                                # macOS), TOCEntry, MarkdownFileTypes,
                                # PreviewRoute (the shared /template/<id>/<file> +
                                # /preview/<abs-path> + /events/<abs-path> parser/
                                # builder), DocumentTarget (documentURL + optional
                                # scrollLine; the value carried over schemes/Kosmos —
                                # NOT the window-identity type, see DocumentSceneID),
                                # ServerStatus (.disabled / .starting / .running(URL) /
                                # .notResponding).
    Render/                     # MarkdownRenderer, SwiftMarkdownRenderer (over
                                # MarkdownHTMLKit), ExternalProcessRenderer (macOS),
                                # ProcessorStore (singleton .shared), HTMLHeadings,
                                # PreviewRequestService (transport-neutral single
                                # source of truth for /preview, /template, /events, /
                                # → PreviewResponse), PreviewResponseShaper
                                # (PreviewResponse → ShapedResponse: reload-script
                                # injection, nonce CSP + security headers, SSE
                                # headers/frames via PreviewSSE, localized error page),
                                # InProcessTunnelBackend (TunnelBackend that renders
                                # in-process and maps ShapedResponse →
                                # TunnelResponseEvent), PreviewHTTPListener (a
                                # VESTIGIAL ObjC-discovery protocol seam — NO
                                # implementer ships, so discoverPreviewHTTPListener()
                                # always returns nil).
    Routing/                    # OpenBehavior+DisplayName. (OpenBehavior, WindowID +
                                # WindowIDAllocator come from KosmosCore. URL→activity
                                # parsing is the GenerilizedDocumentActivity<Scheme>
                                # family in Utilities/Activities.swift.)
    Templates/                  # Template (+ built-in / user shapes), Template+Loader,
                                # TemplateStore (singleton .shared), TemplateAssetRewriter,
                                # Placeholders
    Views/                      # ColorSchemeMenu, ProcessorMenu, TemplateMenu
    Utilities/                  # GalleyDefaults (GalleyDefaults / GalleyRenderDefaults /
                                # GalleyEditorDefaults protocols over KosmosAppKit's
                                # DefaultsProtocol; GalleyConstants — suiteName,
                                # defaultHost, applicationSupportDirectory; bundleIdentifier),
                                # GalleyKosmos (GalleyKosmosRole, MetadataKey.httpURL,
                                # RouteToAVP, RouteToTunnelClient, OpenInEditor),
                                # DisplacementNotifier, Activities
                                # (GenerilizedDocumentActivity<Scheme>: GalleyRequestActivity
                                # galley:// (Server-routed) + GalleyViewerRequestActivity
                                # galley-viewer:// (Viewer direct, also accepts file://) +
                                # OpenSettingsActivity galley-settings:// + OpenHelpActivity
                                # galley-help:// — each a URLSerializable that .open()s
                                # itself; SettingsTab enum), URL+Galley.
    WebKit/                     # PreviewScheme (x-galley://local — shared in-process
                                # resolver for Quicklook + offscreen print web view)
                                # + ClassicPreviewSchemeHandler (WKURLSchemeHandler).
    Resources/                  # Localizable.xcstrings (incl. the moved error-page
                                # strings), ErrorPage.html, Templates.bundle (Default,
                                # GitHub, HighContrast, LaTeX, Manuscript, Sepia,
                                # Solarized, Terminal, Tufte)
  Viewer/                     # the Galley document app — single target, macOS +
                              # visionOS. Cross-platform code at the parent level;
                              # mac/ and vision/ subfolders hold platform-specific code
                              # wrapped in #if os(macOS) / #if os(visionOS) guards.
    UI/                         # cross-platform — app entry + scenes + views:
                                # ViewerApp (single @main, both platforms),
                                # DocumentScene (WindowGroup(id:"document",
                                # for: DocumentSceneID.self, defaultValue: .next())),
                                # DocumentSceneContent (per-window: resolves the
                                # WindowModel by sceneID via WindowModelManager, hosts
                                # handlesExternalEvents(preferring:allowing:) + onOpenURL,
                                # welcome↔doc, tab routing), DocumentMainContent,
                                # DocumentView, WelcomeView (empty-window surface +
                                # FTUE open panel), HelpScene + HelpSceneContent (Window
                                # claiming galley-help://), SettingsScene (Window
                                # claiming galley-settings://), plus Actions,
                                # AssortedViews, FindBar, FocusedValues, SearchField,
                                # StatusBar, TOCSidebar
      mac/                      # MacModifiers (platform view modifiers), MacSettingsView
        Menus/                  # FileCommands, EditCommands, ViewCommands,
                                # FormatCommands, HelpCommands (fires galley-help://),
                                # SettingsCommands (restores ⌘, → openWindow)
        Settings/               # GeneralSettingsView, MarkdownSettingsView
                                # (NO ServerSettingsView — removed; NO ServerStatusPill)
      vision/                   # VisionModifiers, VisionSettingsView
        Menus/                  # MoreMenu, ShareMenu (ornament/toolbar menus)
    Bridges/                    # cross-platform: LinkBridge, ScrollBridge, TOCBridge,
                                # StatsBridge, BackgroundColorBridge, EditorBridge
                                # (cmd-click → editor; AppKit side macOS-only). No
                                # FindBridge — find is WebKit's WebPageFindController.
    Models/                     # cross-platform: AppModel (the boot singleton,
                                # AppModel.shared), Defaults (@ObservableDefaults;
                                # GalleyRenderDefaults + HTTPServerDefaults +
                                # BroadcastedDefaults + GalleyEditorDefaults),
                                # DocumentSceneID (minted-UUID window identity),
                                # WindowModelManager (PersistentModelManager<
                                # DocumentSceneID, WindowModel>; WindowModel =
                                # AbstractWindowModel<DocumentModel>), DocumentModel +
                                # +Configuration/+History/+Notice/+PDFShared/+Resolution/
                                # +Scroll/+Snapshot/+Source/+Zoom, DocumentStats,
                                # ColorSchemeModel, DocumentColorScheme,
                                # SceneColorSchemeModel, SceneProcessorModel,
                                # SceneTemplateModel, Template+BackgroundColor,
                                # RecentDocumentsModel
      mac/                      # DocumentModel+Print, DocumentModel+AVP ("Show on
                                # Vision Pro" → RouteToAVP), EditorStore+viewer
                                # (EditorStore.shared + Defaults.resolvedEditor)
      vision/                   # DocumentModel+Export
    Utilities/                  # ViewerKosmosService (ONE cross-platform Kosmos
                                # surface — #if os(macOS): peer presence for
                                # "Show on Vision Pro" + outbound RouteToAVP/OpenInEditor;
                                # #else: AVP-side lifecycle + tunnel Client + inbound
                                # RouteToTunnelClient → opens galley-viewer://),
                                # KosmosTunnelSchemeHandler (WebKit URLSchemeHandler for
                                # kosmos://local, forwards to the Client). Both the
                                # tunnel Client and this handler are behind #if ENABLE_TUNNEL.
    WebKit/                     # PreviewSchemeHandler — SwiftUI-flavored URLSchemeHandler
                                # for the Viewer's WebPage; delegates to
                                # GalleyCoreKit.PreviewScheme.resolve
    Resources/                  # cross-platform: AppIcon.icon, Assets.xcassets,
                                # Info.plist (registers galley-viewer:// / galley-settings://
                                # / galley-help://), Localizable.xcstrings, HelpDocs,
                                # Scripts, en.lproj, ru.lproj
      mac/                      # BBEditScripts.bundle, XCodeScripts.bundle,
                                # net.leuski.galley.server.plist (LaunchAgent template)
    Viewer.entitlements
  Server/                     # the faceless Galley Server (macOS)
    ServerApp.swift             # @main — Release: Settings { EmptyView() } + LSUIElement
                                # (faceless); DEBUG: minimal MenuBarExtra w/ Quit only.
                                # @NSApplicationDelegateAdaptor(ServerAppDelegate);
                                # init just touches AppModel.shared.
    App/                        # AppModel (owns kosmos: ServerKosmosService; builds a
                                # PreviewRequestService whose template/renderer providers
                                # read TemplateStore.shared / ProcessorStore.shared by
                                # semantic ID from the shared Defaults; owns the shared
                                # DocumentWatcher; SingleProcessInstance.enforceSingleInstance();
                                # startServer() calls discoverPreviewHTTPListener() → nil →
                                # kosmos.start(); publishGalleyAppHash() writes serverGalleyHash;
                                # holds the Server's @ObservableDefaults Defaults class —
                                # GalleyRenderDefaults + HTTPServerDefaults + BroadcastedDefaults
                                # + GalleyEditorDefaults; EditorStore.shared wired here),
                                # ServerKosmosService (subclass of KosmosService<GalleyKosmosRole>;
                                # Kosmos host + AVP bridge; hosts a KosmosHTTPTunnel.Responder
                                # backed by InProcessTunnelBackend — renders in-process, no
                                # loopback HTTP; dispatch = AVP → Mac → launch Galley.app via
                                # galley-viewer://; handles RouteToAVP + OpenInEditor),
                                # GalleyHelperRequestActivity (the galley-helper:// scheme
                                # value type), ServerAppDelegate (LSHandler — receives Finder
                                # opens + galley:// + galley-helper:// URLs)
    Resources/                  # AppIcon.icon, Assets.xcassets, Info.plist (LSUIElement,
                                # NSBonjourServices _kosmos._tcp), Localizable.xcstrings,
                                # Server.entitlements
  Quicklook/                  # Quick Look preview extension (.appex, macOS)
    PreviewViewController.swift # QLPreviewingController — server-first code path that
                                # always falls through to the in-process render via
                                # ClassicPreviewSchemeHandler (no HTTP listener ships)
    Defaults.swift              # @ObservableDefaults — minimal HTTPServerDefaults reader
                                # (serverHTTPPort, template) over the shared net.leuski.galley
                                # suite via QL's shared-preference.read-only entitlement
    Info.plist, Quicklook.entitlements
    en.lproj, ru.lproj
Tests/                        # Swift Testing — kit + app-logic unit tests
  GalleyCoreKitTests/           # PlaceholderContext, TemplateAssetRewriter,
                                # TemplateResolution, TemplateStoreObservation,
                                # URLPathHelpers, URLPreferringTokens, SwiftMarkdownRenderer
                                # + SwiftMarkdownSpecConformance, ClipboardRoundTrip,
                                # AVPCSSPathChain, KosmosTunnelScheme, PreviewRequestService,
                                # PreviewResponseShaper, InProcessTunnelBackend,
                                # PreviewHTTPListener
    Routing/                    # GalleyAction (URL → DocumentTarget via the activity
                                # types, incl. ?line=N)
  ViewerTests/                  # ViewerTests (app-logic), KosmosTests, ColorSchemeChoice,
                                # DocumentSnapshot, RecentDocumentsModel, PDFExport,
                                # HTTPTunnelAVPClient, WebKitZoneIDRejection, WindowModelTabs
  TestPlan.xctestplan           # enrols Tests + UITests
UITests/                      # XCUITest bundle — testTargetName: Viewer
                                # UITests.swift, UITestsLaunchTests.swift, AppLauncher.swift
Scripts/                      # release.sh, lint.sh, embed-server-as-galley.sh,
                              # compile-applescripts.sh, sync-{github,tufte,latex}-markdown-css.sh,
                              # generate-dev-certificate.sh, capture-kosmos-logs.sh,
                              # ExportOptions.plist
docs/                         # test-framework, replace-http-server-with-kosmos,
                              # HANDOFF-http-optional, competitive-analysis,
                              # future-development, find-toolbar-sdk-issues, vendored-templates
```

## Build & test

Pure Xcode project — **no top-level `Package.swift`**. The one framework target (`GalleyCoreKit`) builds inside the project; three local sibling Swift packages (`../Kosmos`, `../KosmosAppKit`, `../MarkdownHTMLKit`) are referenced from the project. (`../KosmosHTTPServer` exists on disk but is **not** referenced.) New source files dropped into the per-target source directories are picked up automatically — the project uses Xcode 16 filesystem-synchronized groups, so `project.pbxproj` has no individual file references and **no manual registration is required** when adding a file. Files under `Sources/Viewer/.../mac/` and `.../vision/` are conditionally compiled — each file in those subfolders is wrapped in `#if os(macOS)` / `#if os(visionOS)` so the filesystem-synchronized membership compiles cleanly on both platforms.

Shared schemes:

- **Viewer** — the Galley document app; default destination is macOS, but the same scheme builds for visionOS by switching destination. This scheme's build settings carry `OTHER_SWIFT_FLAGS = -DENABLE_TUNNEL` (both configs), so the Kosmos tunnel Client + scheme handler compile into the Viewer on **both** platforms.
- **Server** — the faceless render host / routing authority
- **Quicklook** — the Quick Look preview extension
- **GalleyCoreKit** — the framework scheme (mostly for direct iteration / testing)
- Sibling-package schemes (`KosmosCore`, `KosmosTransport`, `KosmosHTTPTunnel`, `KosmosAppKit`, `MarkdownHTMLKit`, and their transitive deps) may also surface in Galley's scheme list. There is **no `GalleyServerKit` scheme** (framework deleted).

There is no separate `Viewer.vision` scheme — the visionOS slice is the same scheme with a different destination.

**For routine macOS work, only build the Viewer scheme.** Galley.app embeds `Galley Server.app` as a bundle resource (via `Scripts/embed-server-as-galley.sh`) and `Quicklook.appex` as a foundation extension, so building Viewer builds the kit, the server, and the QuickLook extension in one pass. Building the macOS schemes separately is pure waste — same compile work, several times the wall-clock cost. The same applies to `test` — the `Viewer` scheme's test action runs the unified `Tests` bundle that covers the kit and the viewer app logic.

```bash
# Build everything macOS (Viewer + Server + Quicklook + the kit)
xcodebuild -project Galley.xcodeproj -scheme Viewer build

# Build the same Viewer target for visionOS
xcodebuild -project Galley.xcodeproj -scheme Viewer \
  -destination "generic/platform=visionOS" build

# Tests — one Xcode test bundle named `Tests` covering the kit + viewer
xcodebuild -project Galley.xcodeproj -scheme Viewer test
# (Or run from Xcode's Test navigator.)
```

Logic tests use **Swift Testing** (`@Test`, `#expect`); UI tests use **XCTest** (XCUITest is XCTest-based). The shared `TestPlan.xctestplan` enrols both targets. Logic coverage includes placeholder substitution, template rewriting + resolution, `TemplateStore` observation, URL path helpers, the swift-markdown renderer (with a CommonMark-spec-conformance suite), the AVP CSS path chain (`kosmos://local` URL → tunnel `urlPath` → Mac `<base href>` → sub-resource URL), the Kosmos tunnel scheme, the transport-neutral `PreviewRequestService`, the `PreviewResponseShaper` output shaping, the `InProcessTunnelBackend` (tunnel render path), the `PreviewHTTPListener` discovery seam, the HTTP-tunnel AVP client (per-request buffering vs SSE streaming), the WebKit Zone.Identifier-suffix rejection, color-scheme choice, the `DocumentModel.Snapshot` round-trip, the `WindowModel` tab persistence (`WindowModelTabsTests`), the `RecentDocumentsModel`, PDF export, and the routing-layer decisions (`GalleyAction` — URL → `DocumentTarget` via the activity types). UI coverage exercises real product invariants — empty windows show the welcome surface (transparent until a doc loads), FTUE Open panel surfaces on cold launch, seeded launches produce visible document windows, File/View menus reachable on a populated doc. See `docs/test-framework.md` for the test pyramid.

The UITests target seeds a document by firing a `galley://<path>` URL via `/usr/bin/open` (`AppLauncher.openViaURLScheme`) — the same routing-aware scheme BBEdit's preview script and Finder use, so it lands on the Server's LSHandler, which routes to the Viewer (`galley-viewer://`) and SwiftUI delivers it through `handlesExternalEvents` / `onOpenURL` to a document window. Test mode also passes `-ApplePersistenceIgnoreState YES` to skip the post-crash "Reopen?" alert. **Don't pass `--ui-test-mode` as a launch argument** — AppKit's command-line `NSUserDefaults` parser eats `--`-prefixed tokens and pollutes the defaults domain. Use `launchEnvironment` (`GALLEY_UI_TEST_MODE`) for the test-mode marker instead.

## Lint

SwiftLint runs as a `Lint` shell-script build phase (no separate scheme/target). The phase invokes `Scripts/lint.sh`, which calls `swiftlint --config swiftlint.yml Sources` (and warns rather than fails if SwiftLint isn't installed). Config is `swiftlint.yml` (custom name — pass `--config swiftlint.yml` if invoking the CLI). Notable rules:
- `force_unwrapping` is opt-in and enabled (warning) — avoid `!`.
- `line_length: 80` — long string literals and URLs need to be split.
- `function_body_length` warns at 65 lines.
- `type_body_length` warns at 700 / errors at 1200; `file_length` warns at 800 / errors at 2000.
- `nesting.type_level: 3`.

## Release

`Scripts/release.sh <vX.Y.Z>` archives the Release config, ad-hoc signs the `.app`, installs it to `/Applications`, zips it, tags the commit, and creates a GitHub release via `gh`. Use `--dry-run` to skip tag + publish. Build number is `git rev-list --count HEAD`; marketing version is the tag minus the leading `v`. Confirm the script's `SCHEME` matches whichever scheme the release targets before tagging.

`.github/workflows/release.yml` is the (currently disabled) signed + notarized CI path. Triggered manually (`workflow_dispatch`); requires repo secrets listed in the file header.

## Dependencies

Resolved by Xcode against package references in `Galley.xcodeproj`. The project references **three local sibling packages** (`../Kosmos`, `../KosmosAppKit`, `../MarkdownHTMLKit`) and **one remote package** (`ObservableDefaults`). `swift-markdown` is transitive (via MarkdownHTMLKit); `swift-core-kit`/`ALFoundation` is transitive (via KosmosAppKit) — **Galley no longer references it directly**. FlyingFox and swift-http-types are **gone from the graph** (they lived in the now-orphaned `KosmosHTTPServer`).

- **Kosmos** (`../Kosmos`, local) — Mac↔AVP bridge. `KosmosCore` + `KosmosTransport` (peer mesh, `Role`, `KosmosService` / `KosmosServiceHost`, `WindowID`) are linked via `GalleyCoreKit`, so Server and Viewer share one definition of `GalleyKosmosRole` / `RouteToAVP` and the `ProxyHTTPRequest` / `ProxyHTTPResponse*` tunnel messages. `KosmosHTTPTunnel` carries the `Responder` (used by the Server), the `Client` (used by the Viewer under `ENABLE_TUNNEL`), `TunnelScheme` (name `kosmos`), the `TunnelBackend` protocol + `TunnelResponseEvent` (the abstraction that lets the Server render in-process instead of proxying to HTTP), and the pure `URLBuilder` helpers. It also carries a direct-connect-by-address/port capability (currently unused by Galley — discovery is Bonjour). No TLS in the data path; Kosmos handles peer identity / trust on its own channel (dev builds use `AlwaysTrustProvider`; SAS-code pairing is the planned production replacement). `Kosmos` depends on a local `../Loom` fork (BonjourAdvertiser self-recovery patch).
- **KosmosAppKit** (`../KosmosAppKit`, local) — product-agnostic app primitives: `SelectableModel` / `SelectablePolicy` / `PersistentSelectionRepresentation`, `PersistentModelManager` / `PersistentModelCache` / `AbstractWindowModel`, the `Property(...).bind(toAndFrom:)` binder, `DocumentWatcher`, `DefaultsBroadcast`, the `DefaultsProtocol` / `HTTPServerDefaults` / `BroadcastedDefaults` contracts (incl. `serverEndpointURL` / `serverHTTPPort`), the launch-agent stack, `URL.computeHash`, and shared helpers/views. **Depends on `swift-core-kit` (`ALFoundation`)** — that dependency is how ALFoundation reaches Galley now. Linked by `GalleyCoreKit`.
- **MarkdownHTMLKit** (`../MarkdownHTMLKit`, local) — wraps `swift-markdown` (pinned 0.8.0) for the bundled "Default" renderer. Linked by `GalleyCoreKit`, used by `SwiftMarkdownRenderer`.
- **ObservableDefaults** (`github.com/fatbobman/ObservableDefaults`) — `@ObservableDefaults` macro backing every `Defaults` class. `AppModel.warmCache()` runs first thing in `AppModel.init()` (the single boot point, touched from `ViewerApp.init`) before SwiftUI lays out a single view — see the long comment on `warmCache()` for the WebKit-triggered AttributeGraph reentrancy this defends against.

External Markdown processors (MultiMarkdown, Pandoc, Discount, cmark-gfm, Markdown.pl) are invoked as subprocesses via `ExternalProcessRenderer` (macOS-only — the kit guards `Process` use behind `#if os(macOS)`).

## ALFoundation

`ALFoundation` (module of `swift-core-kit`) is the shared utility layer this project leans on. **Galley no longer references `swift-core-kit` directly** — it arrives transitively through `KosmosAppKit` (which depends on it), and `GalleyCoreKit`'s `@_exported import KosmosAppKit` surfaces the symbols module-wide, so files like `ExternalProcessRenderer.swift` and `Template+Loader.swift` use `Process.runAndCapture` / `URL.itemExists` / `.parent` with only `import Foundation`. **The helpers are still in active use** — the removal was of the *direct package reference*, not of the API. Before reimplementing anything filesystem-, URL-, process-, or watcher-related, check `ALFoundation` first.

What we actually use today:

| Area | API | In use at |
|---|---|---|
| URL path arithmetic | `url / "subpath"` | `Template+Loader.swift`, `GalleyDefaults.swift` (`GalleyConstants.applicationSupportDirectory`) |
| URL helpers | `URL.itemExists`, `URL.parent`, `URL.createDirectory()`, `URL.isExecutable` | `Template+Loader.swift`, `TemplateStore.swift`, `Editor.swift`, `ExternalProcessRenderer.swift`, `Placeholders.swift` |
| Executable discovery | `try await URL(command: "pandoc")` | `ExternalProcessRenderer.discover` |
| Subprocess execution | `Process.runAndCapture(_:with:at:streams:)`, `Process.run(...)`, `ProcessStreams.inMemory`, `ProcessArgument` | `ExternalProcessRenderer.swift`, `Editor.swift`, and `LaunchctlServerAgent.swift` (in KosmosAppKit) |
| Force-unwrap with message | `expr !! "message"` | `URL+Galley.swift` (`bundleTemplatesDirectoryURL`) |
| File-system watching | `FileSystemObjectWatcher`, `FileSystemEventStream` | `DocumentWatcher` (in KosmosAppKit) is the wrapper around FSEvents |

**Rules:**

1. **Never call `Process()` / `process.run()` directly.** Use `Process.runAndCapture` or `Process.run`. They return a `ProcessResult` with structured stdout/stderr and proper async termination.
2. **Never reach for `FileManager.default.createDirectory` / `.fileExists` when a `URL` is already in hand.** Use `url.createDirectory()` and `url.itemExists`. `createDirectory` makes intermediates automatically.
3. **Never build paths with `appendingPathComponent` chains.** Use the `/` operator: `dir / "subfolder" / "file.txt"`. `appendingPathComponent` is reserved for cases where the segment is dynamic and may be empty (rare).
4. **`!!` is preferred over `!` for force-unwraps**, when the unwrap is genuinely impossible-to-fail at runtime and a crash needs a descriptive message.
5. **For cross-process file dispatch between Galley.app and Galley Server.app, route by URL scheme, not by `NSWorkspace.shared.open(_:withApplicationAt:configuration:)`.** That API returns success (completion gets the target app's running PID with `error=nil`) but the URL is never delivered to the target's `application(_:open:)`. Observed live in both directions. Use the dedicated schemes instead:

  | Direction | Scheme | Builder / parser | Registered in |
  |---|---|---|---|
  | Server → Galley.app (e.g., "no AVP, surface file locally") | `galley-viewer://<path>` | `GalleyViewerRequestActivity(target:).url` / `(from:)` (or just `.open()`) | `Sources/Viewer/Resources/Info.plist` |
  | Galley.app → Server (e.g., "Show on Vision Pro" fallback) | `galley-helper://<path>` | `GalleyHelperRequestActivity(target:).url` / `(from:)` | `Sources/Server/Resources/Info.plist` |
  | Public routing-aware (Finder / BBEdit) → Server | `galley://<path>` | `GalleyRequestActivity(target:).url` / `(from:)` | `Sources/Server/Resources/Info.plist` |

  Server's `ServerAppDelegate.application(_:open:)` normalizes `galley://` (`GalleyRequestActivity`) and `galley-helper://` (`GalleyHelperRequestActivity`) URLs — plus `file://` URLs — to a `DocumentTarget` before dispatching, so callers only need to construct the URL and invoke `NSWorkspace.shared.open(url)`. Do **not** shell out to `/usr/bin/open`. Today the more common Galley.app→AVP path is `RouteToAVP` over Kosmos rather than `galley-helper://`; the URL-scheme path is still wired for callers outside Galley.app's own process. **`galley://` is the Server's, not the Viewer's** — sending `galley://` to surface a doc in Galley.app would loop back to the Server's router; use `galley-viewer://` for forced-Mac opens.

## ObservableDefaults

All of Galley's own user preferences flow through **`@ObservableDefaults`** (from the `ObservableDefaults` Swift package, re-exported by `GalleyCoreKit`). **Before adding `UserDefaults.standard.set(...)` / `.string(forKey:)` / etc. anywhere, stop and read the existing pattern.** The macro generates an `@Observable`-compatible class whose stored properties are persisted to a `UserDefaults` suite and re-read into a per-property cache on `UserDefaults.didChangeNotification` — that cache, plus the Darwin-notification bridge in `DefaultsBroadcast`, is what makes Viewer ↔ Server preference picks visible across processes in real time. All `Defaults` classes are declared `@ObservableDefaults(limitToInstance: false)` so the local observer reacts to any `UserDefaults` change in the process.

Where the pattern lives:

| File | Suite | Role |
|---|---|---|
| `Sources/Viewer/Models/Defaults.swift` | `UserDefaults.standard` (Viewer's bundle id `net.leuski.galley` *is* the suite) | Every Viewer-facing pref (`renderer`, `template`, `colorScheme`, `enablePerDocumentOverrides`, `openBehavior`, `tintWindowWithPageBackground`, `templateBackgroundColors`, `lastTemplateBackgroundColor`, `showsStatusBar`, `readingWordsPerMinute`, `recentEntries`, `editor`/`editorOtherApplicationPath`/`editorCustomURL` on macOS, `serverGalleyHash`, `serverHTTPPort`) **plus** the per-window/per-file snapshot store — `windowSnapshots` (keyed by `DocumentSceneID.description`, holding a `WindowModel` snapshot: its tab list + active tab) and `fileSnapshots` (keyed by file path, holding `DocumentModel.Snapshot`), accessed via the `[snapshot: DocumentSceneID]` / `[snapshot: URL]` subscripts; stale window snapshots are pruned ~15s after launch. Conforms to `GalleyRenderDefaults` + `HTTPServerDefaults` + `BroadcastedDefaults` + `GalleyEditorDefaults`. Cross-platform. |
| `Sources/Server/App/AppModel.swift` (the `Defaults` class) | `UserDefaults(suiteName: "net.leuski.galley")` | The Server-side mirror — same plist as the Viewer; `renderer`, `template`, `editor`/`editorOtherApplicationPath`/`editorCustomURL` (macOS), `serverGalleyHash`, `serverHTTPPort`. Conforms to `GalleyRenderDefaults` + `HTTPServerDefaults` + `BroadcastedDefaults` + `GalleyEditorDefaults`. |
| `Sources/Quicklook/Defaults.swift` | `UserDefaults(suiteName: "net.leuski.galley")` (QL reads via `temporary-exception.shared-preference.read-only`) | Minimal QL-facing reader — `serverHTTPPort` (always 0 today) and `template`. Conforms to `HTTPServerDefaults`. |
| `Sources/GalleyCoreKit/Utilities/GalleyDefaults.swift` | — | `@_exported import ObservableDefaults`, the `GalleyDefaults` / `GalleyRenderDefaults` / `GalleyEditorDefaults` protocols, `GalleyConstants` (`suiteName`, `defaultHost`, `applicationSupportDirectory`), the `bundleIdentifier` global. |
| KosmosAppKit `DefaultsBroadcast` | — | Darwin-notification bridge → synthesizes a local `UserDefaults.didChangeNotification` so the other process's `@ObservableDefaults` observer fires. Call `startListening()` once per process. |

**Rules:**

1. **Never read or write Galley's own preferences via `UserDefaults.standard` / `UserDefaults(suiteName:)` directly.** Go through `Defaults.shared` (Viewer or Server). New preference? Add a stored property on the appropriate `Defaults` class — the macro handles persistence, observation, change notification, and the per-property cache.
2. **Cross-process keys live in both `Defaults` classes.** If a key must be observed by both apps (renderer, template, editor, server hash), declare it in both `Sources/Viewer/Models/Defaults.swift` and `Sources/Server/App/AppModel.swift`'s `Defaults`. Same key name, same type. The shared plist makes them one source of truth on disk; the two classes are the in-memory shape.
3. **Persistence wiring uses `Property(...).bind(toAndFrom:)`, not manual write-back.** Bind a choice model's `selectionRepresentation` to a defaults key path: `Property(model, \.selectionRepresentation, label: "…").bind(toAndFrom: Defaults.shared.property(\.key), checkSettled: true)`. It returns `Cancellable`s (both directions); `checkSettled` feeds a settled/healed selection back to the source. Don't roll your own `didSet` → `UserDefaults` plumbing, and don't reach for the old `bindPersistent` — it's gone.
4. **`warmCache()` must run before any view exists.** `AppModel.init()` (the single boot point, touched from `ViewerApp.init` on both platforms) calls `AppModel.warmCache()` first thing — see the long comment for why (WebKit posts a synchronous `UserDefaults.didChangeNotification` from inside a SwiftUI layout pass on first `WKWebView.init`, which re-enters AttributeGraph if the macro's per-property cache isn't already populated). When adding a new app entry point, replicate the warm-cache call.
5. **Cross-process change propagation goes through `DefaultsBroadcast.startListening()`**, not CFPreferences notifications. `UserDefaults.didChangeNotification` is process-local; `DefaultsBroadcast` posts a Darwin notification on write (`post()`) and synthesizes the local notification on receive. Call `startListening()` exactly once per process (both AppModels do).
6. **Exceptions — only system-owned domains.** Reading non-Galley defaults that the OS owns is fine (e.g. `AppleInterfaceStyle` in `Template+BackgroundColor.swift`). Anything under our suite goes through `Defaults`.

## Choice models — `SelectableModel`

Processor / template / color-scheme / editor pickers are all **`SelectableModel<Policy>`** instances (from KosmosAppKit), the successor to the old `ChoiceModel`. A `SelectablePolicy` supplies the element list, default selection, readiness, and encode/decode; the model exposes `selected`, `elements`, and a `selectionRepresentation` that persists as a **`PersistentSelectionRepresentation`** — a semantic-ID wrapper (typically `NamedPair<ID>`) rather than a raw index, so a stored pick survives catalog reordering and heals to a sensible default when the referenced item vanishes. Galley's concrete policies live in `GalleyCoreKit/Models/`:

- `ProcessorPolicy` → `ProcessorChoice = SelectableModel<ProcessorPolicy>` (ID: `NamedPair<Processor.ID>`; `Processor` is sectioned built-in vs. discovered).
- `TemplatePolicy` → `TemplateChoice` (ID: `NamedPair<Template.ID>`; template IDs are `<sourceIndex>.<name>`).
- `EditorPolicy` → `EditorChoice` (macOS; ID: `NamedPair<Editor.ID>`).
- `ColorSchemePolicy` → `ColorSchemeChoice` (static `light`/`dark`).

Catalogs come from singleton stores — **`ProcessorStore.shared`**, **`TemplateStore.shared`**, **`EditorStore.shared`**. The Viewer's `AppModel` holds the global `templates` / `processors` / `colorSchemes` / `editors` choices and binds each to its defaults key via `Property(...).bind(toAndFrom:)`. Per-scene overrides use the `Scene…Choice` variants (`SceneTemplateModel` etc.), which overlay a window-local selection on the global one and are only consulted when `Defaults.enablePerDocumentOverrides` is true. `DisplacementNotifier` posts a user-facing notice when a persisted processor/template/editor pick no longer exists in the live catalog.

## Architecture

### `GalleyCoreKit` — the shared engine (one framework)

`GalleyCoreKit` is pure rendering, templating, routing, the shared Kosmos surface, and the transport-neutral preview pipeline. There is no HTTP-server code.

- `Render/` —
  - `MarkdownRenderer` protocol; `SwiftMarkdownRenderer` (over MarkdownHTMLKit, with optional `annotatesSourceLines` emitting `data-source-line="N"` for cmd-click→editor); `ExternalProcessRenderer` (shells out via `Process.runAndCapture`, macOS-only); `ProcessorStore.shared` exposes the ordered `Processor` rows (each with an install hint and a live renderer or `nil`), seeded with the built-in so consumers always see ≥1 entry before async `discover()`; `HTMLHeadings` parses headings out of rendered HTML for the TOC. The cmd-click bridge also accepts pandoc's `data-pos` and cmark-gfm's `data-sourcepos`.
  - **`PreviewRequestService`** — the single source of truth for turning a preview request path into a response, shared by every consumer. Owns `/preview/<path>` (render Markdown → HTML, or serve a document-relative asset), `/template/<id>/<file>`, `/events/<path>` (live-reload stream), and `/`. Reads `selectedTemplate()` + `renderer()` `@Sendable` closures at request time and returns a transport-neutral **`PreviewResponse`** (`.html` / `.bytes` / `.events` / `.plainText` / `.badRequest` / `.notFound` / `.failure`). Errors are *structured* (`PreviewFailure`), so each caller localizes its own page.
  - **`PreviewResponseShaper`** — maps `PreviewResponse` → **`ShapedResponse`** (status, headers, body: bytes or event-stream). The single source of truth for response *shaping*: live-reload `<script>` injection, the nonce CSP + security headers, SSE headers + the exact `PreviewSSE` frame bytes, and the localized error page (`Resources/ErrorPage.html` + the error strings, both moved here).
  - **`InProcessTunnelBackend`** — a `TunnelBackend` (from KosmosHTTPTunnel) that serves the Kosmos tunnel by running `PreviewRequestService` + `PreviewResponseShaper` **in-process** and mapping the result onto `TunnelResponseEvent`s. This is the seam that keeps the AVP path free of any HTTP-server library. Depends only on `GalleyCoreKit` + `KosmosHTTPTunnel` + `KosmosAppKit` (`DocumentWatcher`).
  - **`PreviewHTTPListener`** — a **vestigial** optional-component protocol seam: a `@MainActor` protocol + an `@objc PreviewHTTPListenerFactory` and a `discoverPreviewHTTPListener()` that resolves a factory class by name at runtime. **No implementer ships in the repo** (its concrete FlyingFox impl was `GalleyServerKit`, now deleted), so discovery always returns nil. The Server calls it, gets nil, and starts Kosmos with no HTTP listener. Kept only so an HTTP transport could be reinstated without touching call sites.
- `Templates/` — `Template` (a `Sendable` value `struct` conforming to a `SelectablePolicy` element contract; `Template.bundledDefault`) + `Template+Loader`; **`TemplateStore.shared`** watches `~/Library/Application Support/net.leuski.galley.localized/Templates/` and accepts **two shapes** — a folder containing `Template.html`/`template.html` (Galley convention), or a top-level `*.html`/`*.htm` file with sibling assets (BBEdit preview-template convention). Built-ins ship in `Resources/Templates.bundle`. `Placeholders` does `#TOKEN#` substitution (`#TITLE#`, `#DOCUMENT_CONTENT#`, `#BASE#`, `#FILE#`, `#BASENAME#`, `#FILE_EXTENSION#`, `#DATE#`, `#TIME#` — token names match BBEdit's). `TemplateAssetRewriter` rewrites template-relative paths through `/template/<id>/…` and absolute filesystem paths through `/preview/<absolute-path>` so URLs resolve in the in-process `x-galley://local` resolver (Quicklook + print web view) or the AVP `kosmos://local` tunnel.
- `Models/` — the choice policies/values (`ProcessorModel`, `TemplateModel`), the **`Editor`** stack (see below), `TOCEntry`, `MarkdownFileTypes`, `PreviewRoute` (the shared `/template/<id>/<file>` + `/preview/<absolute-path>` + `/events/<absolute-path>` parser/builder with cache policy), `DocumentTarget` (`documentURL` + optional `scrollLine`), and `ServerStatus`.
- `Models/Editor.swift` — the external-editor selection (macOS-facing), moved into the kit. `Editor` (id, url, `InvocationStyle`, localized name, script-install support), `InvocationStyle` (`.urlTemplate` / `.command` / `.open`), `EditorPolicy` (`SelectablePolicy`), `EditorStore` (`@Observable` catalog of discovered editors + synthetic custom-URL / other-app entries), and `EditorChoice = SelectableModel<EditorPolicy>`. The `GalleyEditorDefaults` protocol (below) supplies `editor` / `editorOtherApplicationPath` / `editorCustomURL`.
- `WebKit/PreviewSchemeHandler.swift` — `PreviewScheme` (scheme name `x-galley`, origin `x-galley://local`, the shared `resolve(...)`). `ClassicPreviewSchemeHandler` (the `WKURLSchemeHandler` adapter, no SwiftUI dep) is here; the Viewer's SwiftUI-flavored handler delegates to the same resolver. Used by the Viewer's visible `WebPage`, the offscreen print/export `WKWebView`, and the QuickLook fallback render. AVP does **not** use this scheme — it uses the `kosmos://local` tunnel scheme.
- `Routing/` — `OpenBehavior+DisplayName` only (`OpenBehavior`, `WindowID`, `WindowIDAllocator` come from `KosmosCore`). URL → activity parsing lives in `Utilities/Activities.swift`, built on `GenerilizedDocumentActivity<Scheme>`: `GalleyRequestActivity` (`galley`, Server-routed), `GalleyViewerRequestActivity` (`galley-viewer`, Viewer direct — also accepts `file://`), `OpenSettingsActivity` (`galley-settings`, optional `?tab=<id>` → `SettingsTab`), `OpenHelpActivity` (`galley-help`). Each is `URLSerializable` and `.open()`s itself (→ `NSWorkspace.shared.open` on macOS, `UIApplication.shared.open` on visionOS).
- `Utilities/GalleyKosmos.swift` — `GalleyKosmosRole` (`.server` / `.macViewer` / `.visionViewer`), `MetadataKey<URL>.httpURL` (wire key `galley.http-url`), and the Galley messages `RouteToAVP` (Mac Viewer → Server), `RouteToTunnelClient` (Server → AVP), and `OpenInEditor`. Peer classification + AVP-reachability are on `KosmosServiceHost`, not here.
- `Utilities/GalleyDefaults.swift` — `GalleyDefaults` (adds the `net.leuski.galley` `suiteName`), `GalleyRenderDefaults` (adds `renderer` + `template` as `PersistentSelectionRepresentation?`, plus computed `resolvedTemplate` / `resolvedRenderer` via the singleton stores), and `GalleyEditorDefaults` (macOS: `editor` + `editorOtherApplicationPath` + `editorCustomURL`, plus computed `resolvedEditor`). `HTTPServerDefaults` (`serverHTTPPort`, `serverEndpointURL`) and `BroadcastedDefaults` live in KosmosAppKit. `GalleyConstants` = `suiteName` / `defaultHost` / `applicationSupportDirectory`.
- `Views/` — `ColorSchemeMenu`, `ProcessorMenu`, `TemplateMenu`.
- `Accessibility/` — `ViewerA11yID` / `ServerA11yID` string-constant catalogs.

### `Sources/Viewer/` — cross-platform viewer code (one target, two platforms)

The Viewer target builds for both macOS and visionOS. Cross-platform code sits at the *parent* level; platform-specific code sits inside a `mac/` or `vision/` subfolder *and* is wrapped in `#if os(macOS)` / `#if os(visionOS)`. Don't rely on folder-based membership exclusion — the `#if` guards are what's load-bearing. The app entry and all three scenes are cross-platform (`UI/ViewerApp.swift`, `DocumentScene`, `HelpScene`, `SettingsScene`), branching internally on `#if`.

Cross-platform pieces:

- `UI/ViewerApp.swift` — the single `@main` `App`. Declares `DocumentScene`, `HelpScene`, `SettingsScene`; touches `AppModel.shared` in `init` (which runs `warmCache()` synchronously); on visionOS observes the app-level `scenePhase` to drive Kosmos suspend/resume. macOS-only `.commands { … }` + toolbar style are `#if`-gated.
- `UI/DocumentScene.swift` + `UI/DocumentSceneContent.swift` — `WindowGroup(id: "document", for: DocumentSceneID.self) { … } defaultValue: { .next() }`. `DocumentScene` claims `file:` + `galley-viewer://` via `handlesExternalEvents(matching:)` and hosts the macOS command set. `DocumentSceneContent` is the per-window body: in `init` it resolves the window's **`WindowModel`** synchronously from `WindowModelManager.forScene(id:)` (nil → welcome), holds it in `@State`, and attaches the per-window `handlesExternalEvents(preferring: …galleyPreferringTokens, allowing: …)` + `onOpenURL` claim that implements dedup + tab routing + `openBehavior`. Empty windows render `WelcomeView` and stay transparent (`.windowTransparency`) until a doc loads.
- **Windows hold tabs.** `WindowModel = AbstractWindowModel<DocumentModel>` (from KosmosAppKit) — a `tabs` list + `activeTab`, enforcing ≥1 tab. `WindowModelManager` is a `PersistentModelManager<DocumentSceneID, WindowModel>` keyed by the scene id; `open(target:id:)` builds-or-finds a window (welcome→document in place), and `makeTab(for:)` seeds a `DocumentModel` from the per-file snapshot so reopening a known file restores its scroll/zoom/TOC/choices. On visionOS a window can carry multiple in-window tabs (`WindowModel.addTab`); on macOS new-tab opens use AppKit's native window tabbing (`NSWindow.allowsAutomaticWindowTabbing` pinned when `openBehavior == .newTab`, plus `UserDefaults.forceTabs()`). Snapshots: a `WindowModel` snapshot (tabs + active) is stored under `[snapshot: DocumentSceneID]`; each tab's `DocumentModel.Snapshot` is stored under `[snapshot: URL]`.
- `UI/DocumentView.swift` + `UI/DocumentMainContent.swift` — the document chrome (TOC sidebar + `WebView` + FindBar/StatusBar) for a populated tab.
- `UI/WelcomeView.swift` — the empty-window surface: app icon, Open button, recents list; on macOS auto-runs the FTUE Open panel after a short delay if the window stays empty. Opening a file fires a `galley-viewer://` URL.
- `UI/HelpScene.swift` + `UI/HelpSceneContent.swift` — singleton `Window` claiming `galley-help://`, restoration disabled; builds a non-persisted help `DocumentModel`.
- `UI/SettingsScene.swift` — singleton `Window` claiming `galley-settings://` (optional `?tab=<id>`), hosting `MacSettingsView` / `VisionSettingsView`. **Not** SwiftUI's `Settings {}` scene (which ignores `handlesExternalEvents`).
- `Models/DocumentModel.swift` + `+Configuration`/`+History`/`+Notice`/`+PDFShared`/`+Resolution`/`+Scroll`/`+Snapshot`/`+Source`/`+Zoom` — per-document state, one per tab. Holds the `WebPage`, the bridges, the back/forward `History` (≥1 URL), the `WebPageFindController`, zoom + scroll, the notice channel, and the rendered-template box. Init is **synchronous**; first render is a fire-and-forget `Task`. `+Snapshot` defines `DocumentModel.Snapshot` (Codable: history, scrollY, showsTOC, pageZoom, the persistent choice IDs, security-scoped bookmark) and the model's own `onObservedChange` observers (save on change; re-render when global/per-doc choices change). Model→model wiring is explicit — views never mediate.
- `Models/AppModel.swift` — `@Observable @MainActor`, the single boot point (`AppModel.shared`). Built synchronously: choices decode from defaults; `ProcessorStore.shared.discover()` and the launch-agent validation run as background `Task`s after. Owns `templates` / `processors` / `colorSchemes` / `editors` (macOS) choices, `recents`, `kosmos` (the `ViewerKosmosService`), `windowModelManager`, `selectedSettingsTab`, and `warmCache()`. Carries the `ActiveServerAgent.shared` wiring + `Bundle.serverBundle` helper (macOS).
- `Models/Defaults.swift`, `Models/DocumentSceneID.swift`, `Models/RecentDocumentsModel.swift` — see other sections; `DocumentSceneID` is the minted-UUID `WindowGroup(for:)` value type. `RecentDocumentsModel.record(_:)` refuses bundle URLs so help docs never land in recents.
- `Models/DocumentStats.swift`, `ColorSchemeModel.swift`, `DocumentColorScheme.swift`, `SceneColorSchemeModel.swift`, `SceneProcessorModel.swift`, `SceneTemplateModel.swift`, `Template+BackgroundColor.swift` — stats/find drivers, color-scheme + per-template page-bg machinery, per-scene choice overrides.
- `Bridges/` — `WKScriptMessageHandler`s owned by `DocumentModel`: `EditorBridge` (cmd-click → editor, macOS-gated open), `LinkBridge` (`.md` family → in-window nav; external HTTP → default browser; `finder://` → reveal on macOS), `ScrollBridge`, `TOCBridge`, `StatsBridge`, `BackgroundColorBridge`. Find is WebKit's own `WebPageFindController`, not a bridge.
- `UI/` shared views — `Actions` (one source of truth for navigation/zoom/find/TOC/status-bar buttons, used by both menu and toolbar), `FindBar`, `TOCSidebar`, `StatusBar`, `SearchField`, `FocusedValues` (`\.documentModel`), `AssortedViews` (NoticeBanner etc.).
- `Utilities/ViewerKosmosService.swift` — **one** cross-platform Kosmos surface (macOS / visionOS branches below); `Utilities/KosmosTunnelSchemeHandler.swift` — the AVP `kosmos://local` scheme handler (behind `#if ENABLE_TUNNEL`).
- `WebKit/PreviewSchemeHandler.swift` — SwiftUI-flavored `URLSchemeHandler` for the visible `WebPage`; delegates to `GalleyCoreKit.PreviewScheme.resolve`.

Platform-specific siblings (all `#if`-guarded):

- `UI/mac/` — `MacModifiers`, `MacSettingsView`, plus `Menus/` (`FileCommands`, `EditCommands`, `ViewCommands`, `FormatCommands`, `HelpCommands`, `SettingsCommands`) and `Settings/` (`GeneralSettingsView`, `MarkdownSettingsView` — **there is no `ServerSettingsView` or `ServerStatusPill` anymore**; the BBEdit/Xcode script installer lives in `MarkdownSettingsView` via `Editor.installScripts(to:)`).
- `UI/vision/` — `VisionModifiers`, `VisionSettingsView`, plus `Menus/` (`MoreMenu`, `ShareMenu`).
- `Models/mac/` — `DocumentModel+Print`, `DocumentModel+AVP` ("Show on Vision Pro" → `RouteToAVP`), `EditorStore+viewer` (`EditorStore.shared` + `Defaults.resolvedEditor`).
- `Models/vision/` — `DocumentModel+Export`.
- `Resources/mac/` — BBEdit/Xcode script bundles, `net.leuski.galley.server.plist` (LaunchAgent template).

When adding a file: cross-platform → parent directory; platform-specific → `mac/` or `vision/` subfolder *and* `#if`-guard the body.

### Viewer macOS slice — `Sources/Viewer/*/mac/`

Pure SwiftUI — **no `NSApplicationDelegateAdaptor`**. URL dispatch is SwiftUI's `handlesExternalEvents`; recents, FTUE picker, and per-window URL receipt live in `@Observable @MainActor` types or per-window view state.

- **Window identity & dispatch** — `DocumentScene` is `WindowGroup(id: "document", for: DocumentSceneID.self, defaultValue: { .next() })`, so every window is born with a non-nil minted-UUID id; SwiftUI persists/restores it, and `DocumentSceneContent` resolves the `WindowModel` synchronously from `WindowModelManager`. The scene claims `file:` + `galley-viewer://`; each window's `DocumentSceneContent` adds `handlesExternalEvents(preferring: …galleyPreferringTokens, allowing: …)` so a repeat-open routes back to the window already showing the doc (dedup) while a fresh URL lands on the key/empty window. `onOpenURL` applies `openBehavior` (same-doc → scroll + focus; `replaceCurrent` → rebind in place; `newWindow`/`newTab` → `openWindow(id:)` for a fresh window, born-as-tab when tabbing is pinned).
- **Boot** — `ViewerApp.init` only touches `AppModel.shared`; the boot work is in `AppModel.init`: `warmCache()`, `URL.createLocalizedApplicationSupportDirectory()`, `UserDefaults.forceTabs()`, constructing + `start()`ing the `ViewerKosmosService`, and (background `Task`s) `ProcessorStore.shared.discover()` + `ActiveServerAgent` validation (`restartHelperIfStale` / `validateAndRepair`). The document scene hosts the commands. No `MenuBarExtra` — that's the Server's job (and it has none in Release).
- **`UI/mac/Settings/`** — two panes (`GeneralSettingsView`, `MarkdownSettingsView`) in `MacSettingsView`'s `TabView`, selected by `AppModel.shared.selectedSettingsTab` (a `galley-settings://?tab=<id>` deep link lands here). `MarkdownSettingsView` drives the editor/template/processor pickers, the per-document-overrides toggle, and the BBEdit/Xcode script installer. **No Server pane, no status pill** — the Server has no user-facing settings.
- **`ActiveServerAgent`** (in KosmosAppKit; `.shared` wired in `Models/AppModel.swift`) — backend is `LaunchctlServerAgent` (classic `~/Library/LaunchAgents/net.leuski.galley.server.plist`; no `KeepAlive`). `SMAppService` was rejected (AMFI launch-constraint violation for the ad-hoc-signed helper). At Viewer boot it `restartHelperIfStale` / `validateAndRepair` (rewrites a stale absolute `Program` path if Galley.app moved) — but there is **no UI to enable/disable it**; the Server is normally cold-launched on demand by LaunchServices as the LSHandler. `Bundle.serverBundle` locates the embedded `Galley Server.app`.
- **`Models/mac/DocumentModel+Print`** — Print / Page Setup / Export-as-PDF share one offscreen `WKWebView` (`DocumentModel+PDFShared`) with `ClassicPreviewSchemeHandler`. Non-obvious bits: `printInfo.horizontalPagination` / `verticalPagination` must be `.automatic` (else one tall page), and the operation must dispatch via `runModal(for:delegate:didRun:contextInfo:)` (`runOperation()` produces blank pages).
- **Window visibility** — empty windows stay transparent until they adopt a document; no `alphaValue = 0` hider, no nil-target bootstrap.
- **Sandbox is disabled** on the Viewer target (both slices) and on the Server target — both need to read arbitrary user files.

### Viewer visionOS slice — `Sources/Viewer/*/vision/`

Far smaller. No AppDelegate, no separate welcome scene, no dispatcher. Same `ViewerApp` / scenes as macOS; document URLs arrive via `handlesExternalEvents` + `onOpenURL` (or, for Mac-hosted docs, via Kosmos `RouteToTunnelClient` → `ViewerKosmosService` opening a `galley-viewer://` URL). No menus, no external editor, no hosted server.

- **`ViewerApp.init` (visionOS)** — runs `AppModel.shared` (discovery returns only the built-in renderer — external CLI processors are unreachable) and starts `ViewerKosmosService`. Observes the app-level (aggregate) `scenePhase` to drive `publishSuspend()` / `publishResume()` — keeping ≥1 window alive matters because visionOS suspends zero-scene apps, which would kill Kosmos.
- **`ViewerKosmosService` (visionOS branch)** — subscribes to `RouteToTunnelClient`; on receipt it builds a `DocumentTarget` and fires `GalleyViewerRequestActivity(target:).open()`, so a Mac-routed open lands on the same `handlesExternalEvents` path as any local open. Owns the `KosmosHTTPTunnel.Client` (under `ENABLE_TUNNEL`) and emits suspend/resume on `scenePhase`. Document bytes ride Kosmos via the `kosmos://local` scheme handler.
- **`KosmosHTTPTunnel.Client`** + **`KosmosTunnelSchemeHandler`** — every `kosmos://local/<route>/<path>` URL the WebView fetches becomes a `ProxyHTTPRequest` Kosmos broadcast; response chunks route back through the client's `requestID → entry` map (accumulating buffer, streaming flag by `Content-Type`). Bounded responses are buffered and yielded to WebKit as a single `.data(buffer)` once `isFinal: true` (WebKit's `URLSchemeTask` doesn't reliably deliver multi-event `.data(...)`); SSE (`text/event-stream`) bypasses the buffer and yields each chunk. WebKit cancellation publishes `ProxyHTTPCancel`. The handler stamps `X-Kosmos-Origin: kosmos://local` on every request so the Mac's `templateOriginURL` composes `<base href="kosmos://local/preview/<docparent>/">` and every sub-resource fetch stays on this handler.
- **`Defaults` keys with meaning on visionOS** — `renderer`, `template`, `colorScheme`, `enablePerDocumentOverrides`, `templateBackgroundColors`, `lastTemplateBackgroundColor`, `showsStatusBar`, `readingWordsPerMinute`, `recentEntries`, plus the snapshot store. macOS-only keys (`editor`, `openBehavior`) are present but unused. `enablePerDocumentOverrides` stays `false` for v1.
- **`Models/vision/DocumentModel+Export`**, **`UI/vision/VisionModifiers` / `VisionSettingsView` / `Menus/`** — the visionOS-specific export, view modifiers, settings, and ornament/toolbar menus. The welcome surface and document chrome are the cross-platform `WelcomeView` / `DocumentView`; an empty window's `.fileImporter` pick rebinds the same window in place.

### `Sources/Server/` — faceless Galley Server (macOS)

- **`ServerApp`** — `@main`. **Release: faceless** — `Settings { EmptyView() }` + `LSUIElement` (no Dock icon, no menu-bar item). **DEBUG:** a minimal `MenuBarExtra` with a single "Quit" button. Uses `@NSApplicationDelegateAdaptor(ServerAppDelegate.self)`; `init` just touches `AppModel.shared`. There is **no `MenuBarContent`** and no SwiftUI settings.
- **`App/AppModel`** — `@Observable @MainActor`. Owns `kosmos: ServerKosmosService`. In `init`: `SingleProcessInstance.enforceSingleInstance()`; kicks `ProcessorStore.shared.discover()`; builds a `PreviewRequestService` whose `selectedTemplate` / `renderer` providers read `TemplateStore.shared` / `ProcessorStore.shared` by the semantic IDs in `Defaults.shared`; constructs the shared `DocumentWatcher`; `Defaults.shared.startListening()`; `startServer(...)`; `publishGalleyAppHash()`. It also declares the Server's `@ObservableDefaults Defaults` class (`GalleyRenderDefaults` + `HTTPServerDefaults` + `BroadcastedDefaults` + `GalleyEditorDefaults`) and wires `EditorStore.shared`. `startServer` calls `discoverPreviewHTTPListener()` — which returns nil (no implementer) — so it just calls `kosmos.start()`; `serverHTTPPort` stays 0. (If an HTTP listener ever ships, the observer branch publishes its port and advertises `MetadataKey.httpURL`.) Because renderer/template are read at request time, switching either in the Viewer takes effect on the next tunnel request with no restart.
- **`publishGalleyAppHash()`** — computes the SHA-256 of the containing `Galley.app` (`Server.app` lives at `<Galley.app>/Contents/Resources/Galley Server.app`) and writes it to `serverGalleyHash`. The Viewer compares this against its own hash on launch and, on mismatch, terminates/relaunches the Server so a stale Server doesn't clobber the Viewer's choices through the persistence round-trip.
- **`App/ServerAppDelegate`** — `NSApplicationDelegate`, the LSHandler. Receives Finder `file://` opens and `galley://` / `galley-helper://` URL opens (normalizing each to a `DocumentTarget` via `GalleyRequestActivity` / `GalleyHelperRequestActivity`), and dispatches each through the `ServerKosmosService` dispatch path.
- **`App/ServerKosmosService`** — `@Observable @MainActor`, a subclass of `KosmosService<GalleyKosmosRole>`. The generic boilerplate (host bootstrap, peer-watch, subscriptions, suspend/resume reachability) lives in the shared `KosmosServiceHost`; `isAVPReachable` is `host.reachablePeer(deviceType: .vision) != nil`. Galley-specific parts: **dispatch** (`dispatchToClient` → route to a reachable peer via `RouteToTunnelClient`, trying AVP (`.vision`) then Mac (`.mac`), else launch Galley.app via `GalleyViewerRequestActivity(target:).open()`), the **AVP-doff handoff** (last vision peer leaves → `galley-viewer://` per active doc), the `RouteToAVP` handler (same dispatch path as Finder opens), and the `OpenInEditor` handler (`Defaults.shared.resolvedEditor` opens the file at a line). It **hosts a `KosmosHTTPTunnel.Responder` backed by `InProcessTunnelBackend`** — inbound `ProxyHTTPRequest`s are answered by rendering **in-process** (via `PreviewRequestService` + `PreviewResponseShaper`) and streaming `ProxyHTTPResponseHead` + chunked `ProxyHTTPResponseChunk`s back; there is no loopback HTTP round-trip. `ProxyHTTPCancel` tears down the matching task. Peer discovery is **Bonjour** (`_kosmos._tcp`, in Info.plist); the direct-connect-by-port capability in Kosmos is currently unused.

## Concurrency conventions

- UI-facing state (`AppModel` in both apps, `DocumentModel`, `WindowModel` / `WindowModelManager`, `ViewerKosmosService` / `ServerKosmosService`, `RecentDocumentsModel`, the singleton stores) is `@MainActor`.
- The Kosmos tunnel `Responder` runs its per-request work in `Task`s; `InProcessTunnelBackend.resolve` is `@MainActor` and streams `TunnelResponseEvent`s.
- Renderer + template selection is read at request time via `@Sendable` provider closures rather than shared mutable state.
- The routing value types in `GalleyCoreKit/Routing/` + `Utilities/Activities.swift` are `Sendable`; window selection is SwiftUI's `handlesExternalEvents`, keyed by the per-window `DocumentSceneID`. Per-window/per-tab state lives in `WindowModel` / `DocumentModel`, resolved via `WindowModelManager`'s `PersistentModelCache`.
- `@ObservationIgnored` is used for collaborators that should not trigger view invalidation (watchers, bridges, the Kosmos service, stores keyed by ID).
- Swift 6 strict concurrency is enabled; prefer typed throws, `Sendable` value types, and structured concurrency.

## Reference

- `docs/test-framework.md` — the test pyramid (routing logic / app logic / snapshot / UI / integration), where each kind of test goes, the launch-arg conventions for tests.
- `docs/replace-http-server-with-kosmos.md` + `docs/HANDOFF-http-optional.md` — the design and progress log for the HTTP-server removal (historical; the end state described here — full removal, in-process render — is what shipped).

## Architecture decisions

### Two apps sharing a framework; Viewer is one target on two platforms

The codebase tried a single-bundle factoring (Viewer with embedded server, soft-quit, activation-policy switching) and reverted to two macOS apps sharing a framework. Reasons the split won:
- Viewer wants `.regular` always; Server wants faceless / `LSUIElement`. Reconciling those into one bundle required activation-policy juggling — substantial complexity for the convenience of one bundle.
- Engine sharing is what actually matters, and the `GalleyCoreKit` framework target gives that without forcing a single process model.

Adding a visionOS Viewer did *not* introduce a third target. The same `Viewer` target builds for `macosx` and `xros/xrsimulator`; platform-specific code lives in `mac/` and `vision/` subfolders guarded by `#if os(macOS)` / `#if os(visionOS)`. Both slices link only `GalleyCoreKit`. The Quicklook extension is a separate target and links `GalleyCoreKit` directly for its in-process render.

### Frameworks not SwiftPM; and only one framework now

The shared engine is an **Xcode framework target** (`GalleyCoreKit`), not a Swift Package. The earlier SwiftPM `Kit/` package was abandoned because `xcodebuild` test discovery for embedded local packages was unreliable while Xcode's GUI-driven runs worked fine. There used to be a second framework, `GalleyServerKit` (the FlyingFox route table + preview-server controller + localized error pages). It was **deleted** when the HTTP server was removed (below); its route logic collapsed into `GalleyCoreKit`'s transport-neutral `PreviewRequestService` + `PreviewResponseShaper`, and its error-page resources moved into `GalleyCoreKit/Resources`.

### Single Viewer target, two platforms, `mac/` and `vision/` subfolders

Earlier iterations had a separate `Sources/ViewerShared/` folder compiled into both a `Viewer` (macOS) and a `Viewer.vision` (visionOS) target. That is gone. There is now one `Viewer` target with `SUPPORTED_PLATFORMS = "macosx xros xrsimulator"`, and platform-specific files live alongside cross-platform ones in `mac/` and `vision/` subfolders.

Reasons: one Info.plist / entitlements / codesign setup instead of a membership-exclusion dance; the `mac/` / `vision/` convention plus `#if` body guards keep the platform fences inside a single file and target (the folder name is documentation; the `#if` is load-bearing — files in `mac/` still ship to the visionOS compile, they just produce nothing when guarded). Cross-platform code sits at the parent level and is shared automatically.

When adding a file: cross-platform → parent directory; platform-specific → `mac/` or `vision/` subfolder *and* `#if`-guard the body.

### The HTTP server was removed; rendering is in-process

The preview server has a long history: **FlyingFox** originally, swapped to **Hummingbird** (briefly `HummingbirdTLS`) to present HTTPS to AVP, then back to FlyingFox behind a Hummingbird-API-shaped adapter (which was extracted into the `KosmosHTTPServer` sibling package) once the HTTPS path was replaced by the Kosmos tunnel. That whole cluster is now **gone**:

- **AVP** renders over the **in-process Kosmos tunnel** — `ServerKosmosService` hosts a `KosmosHTTPTunnel.Responder` backed by `InProcessTunnelBackend`, which runs `PreviewRequestService` + `PreviewResponseShaper` in-process. No FlyingFox in the data path.
- **Quick Look** **cannot** be a Kosmos client (a preview appex sandbox denies all in-process outbound network, even with `network.client`) and there is no HTTP listener to fetch from either, so it **renders in-process** via `ClassicPreviewSchemeHandler`. The old `WKWebView`-loads-`http://127.0.0.1` path is still coded but dormant (`serverHTTPPort` is 0).
- **Browsers / BBEdit-over-HTTP** — dropped. The Server is no longer a browser-reachable HTTP surface.

Consequences for the graph: with no HTTP server, `GalleyServerKit` and `KosmosHTTPServer` are out (the latter is an orphan on disk); **FlyingFox, swift-http-types, and the entire NIO/server-infra cluster are gone**. The `PreviewHTTPListener` protocol seam in `GalleyCoreKit` is the only vestige — a runtime-discovery hook (`discoverPreviewHTTPListener()`) with no implementer, kept so HTTP could be reinstated as an optional component without touching call sites. If it ever is, `KosmosHTTPServer`'s `Adapter/` is the only file set that touches the underlying server library.

`serverHTTPPort` / `serverEndpointURL` remain in the `HTTPServerDefaults` contract and in every `Defaults` class for shared-suite consistency, but the port is always 0 today. Do not build new behavior that depends on the loopback HTTP listener existing.

### `WindowGroup` not `DocumentGroup`; windows hold tabs

`DocumentGroup(viewing:)` ties one window to one `FileDocument` (titles, restoration, revision history all assume "this window represents this file"), but the Viewer is a *navigator* — one window/tab walks through linked Markdown documents — and `DocumentGroup` attaches a title-bar document-menu popover that's wrong for a read-only viewer. So the Viewer uses a plain `WindowGroup` on both platforms, and a window is a `WindowModel` (`AbstractWindowModel<DocumentModel>`) that can hold multiple `DocumentModel` tabs.

### UUID window identity (`DocumentSceneID`), not the document URL

The `WindowGroup`'s value type is **`DocumentSceneID`** — a Viewer-local minted-UUID wrapper (`Hashable`/`Codable`/`Sendable`, `.next()`), with `defaultValue: { .next() }` — *not* the document URL or `DocumentTarget`. This was a deliberate rebuild (the windowing layer was copied from the sibling `../Dot` app) to fix a class of bugs around the old nil-target-bootstrap + deferred-async-bind + alpha-reveal design.

Why a minted id beats a URL-valued group:

- `defaultValue:` means SwiftUI **never hands a `nil` value**, so there is no nil-bootstrap window, no binding-write-back, and no alpha-0 hider. Every window is born with a stable id.
- The per-window `WindowModel` is resolved **synchronously** from `WindowModelManager` (a `PersistentModelManager` keyed by the id, deduped through a `PersistentModelCache`) — render is fire-and-forget. State restoration restores the id, and the window rehydrates from its snapshot.
- The document still travels as a `DocumentTarget` over schemes/Kosmos (so `?line=N` survives), but it is the *payload*, not the window's identity. Per-window persistence lives in `Defaults` (`windowSnapshots` keyed by the id — tabs + active tab; `fileSnapshots` keyed by file), pruned ~15s after launch.

### SwiftUI-native URL dispatch (replaces `WindowDispatcher` + `Window("welcome")`)

URL → window routing on **both** platforms is done by SwiftUI's `handlesExternalEvents`, not a hand-rolled dispatcher. This replaced an earlier design built around a central `WindowDispatcher` + `WindowRegistry` + `OpenURLRouter` + a `Window("welcome")` bootstrap scene; all of that was removed.

- **Four inbound schemes, scene owners.** `GalleyViewerRequestActivity` (`galley-viewer://`) + `file://` route to the document `WindowGroup`; `OpenSettingsActivity` (`galley-settings://`, optional `?tab=<id>`) and `OpenHelpActivity` (`galley-help://`) each claim their scheme on a singleton `Window` scene, so a document window only ever sees document URLs. (`galley://` is the **Server's** routing scheme — it never reaches the Viewer directly.) Each activity is `URLSerializable` and `.open()`s itself.
- **Per-window claim = catch-all + dedup.** `DocumentScene` claims `handlesExternalEvents(matching: ["file:", galley-viewer token])`; each window's `DocumentSceneContent` adds `handlesExternalEvents(preferring: …galleyPreferringTokens, allowing: …)`. An empty/`replaceCurrent` window allows the full set; a `newWindow`/`newTab` window with a doc allows only its own tokens (so a foreign doc spawns a fresh window). The `preferring:` tokens (standardized file URL + `galley-viewer://` form, query stripped) route a repeat-open back to the window already showing the doc regardless of focus. `onOpenURL` then applies `openBehavior`.
- **No welcome scene.** There is no `nil`-target bootstrap member (the `defaultValue:` id removes it) and no `Window("welcome")` scene. An empty window renders `WelcomeView` and stays transparent until it adopts a document.
- **No `ViewerAppDelegate`.** The macOS Viewer installs no `NSApplicationDelegateAdaptor`.

visionOS uses the identical pattern (minus AppKit window tabbing).

### Server is the AVP routing authority AND the in-process render host; all three runtimes are Kosmos peers

The Vision Pro path looks like it could live in Galley.app, but it doesn't — the Server is the AVP routing authority. Three requirements drive that:

1. **Open-document routing has to decide before any Mac window exists.** When Finder opens `foo.md`, an authority must answer "is AVP paired right now? push to AVP, else route to Galley.app." Galley.app is `.regular` (heavy launch). The Server is faceless / on-demand and is the persistent process in this system, so it is the `LSHandler` for `.md` and for `galley://` and decides where the document goes.
2. **Live reload to AVP must come from the peer owner.** Whoever holds the Kosmos peer to AVP owns the file watch. The Server runs the `DocumentWatcher`; AVP is a subscriber over the tunnel's `/events/<path>` stream.
3. **Take-off-AVP handoff requires the routing authority to launch Galley.app.** When the headset comes off, docs on AVP should come up in Galley.app. The Server sees the AVP peer disconnect via Kosmos, knows the docs on AVP, and launches Galley.app via `galley-viewer://` per doc.

#### Kosmos carries control + the render tunnel; there is no HTTP loopback anymore

All three runtimes — Server, Galley.app (Mac Viewer), and the AVP viewer — are **Kosmos peers**. No file-based handshake, no Mac-local IPC, no "ask the Server whether AVP is paired" RPC. Presence and routing both ride Kosmos.

Two data-plane cases:

- **Quick Look (same machine)** renders **in-process** — there is no HTTP loopback listener to dial. (It reads `template` from the shared suite so the in-process render honors the user's pick.)
- **AVP** tunnels through Kosmos. Its WebView is configured with a `kosmos://local` scheme handler (`KosmosTunnelSchemeHandler`); every request — the document, every CSS / JS / image / font, the SSE `/events/<path>` stream — becomes a `ProxyHTTPRequest`, answered by `InProcessTunnelBackend` (hosted by `ServerKosmosService`) rendering **in-process**, and streamed back as `ProxyHTTPResponseHead` + chunked `ProxyHTTPResponseChunk`. The literal scheme host is the sentinel `local`, and every request carries `X-Kosmos-Origin: kosmos://local` so the Mac's `templateOriginURL` composes `<base href="kosmos://local/preview/<docparent>/">` and every sub-resource fetch stays on the handler.

Same `/preview/<path>` + `/template/<id>/<file>` + `/events/<path>` route surface either way (they are `PreviewRoute` cases parsed by `PreviewRequestService`); only the transport differs — in-process scheme handler for Quicklook/print, in-process tunnel backend for AVP.

The Mac Viewer's Kosmos role is intentionally narrow: **peer presence** to gate the "Show on Vision Pro" menu item, and outbound `RouteToAVP` / `OpenInEditor`. It does not own dispatch state. The AVP viewer's role: receive `RouteToTunnelClient`, run the tunnel client, and react to peer presence. **AVP is not a thin shell** — it renders its own local files (via `.fileImporter`) using the same `SwiftMarkdownRenderer` + bundled templates as the Mac's local path; Kosmos is additive.

Routing authority + dispatch state stay with the Server. Other peers ask; the Server decides and sends.

#### URL schemes are directional

| Scheme | LSHandler | Semantics |
|---|---|---|
| `galley://<path>` | Server | Public routing-aware scheme. Server picks AVP-or-Mac. What Finder / BBEdit / Xcode produce. |
| `galley-viewer://<path>` | Galley.app (Viewer) | Direct open in the Viewer (forced-Mac on macOS; the local-open scheme on AVP too). The `WindowGroup`'s scheme. |
| `galley-helper://<path>` | Server | Viewer → Server back-channel (e.g. "Show on Vision Pro" URL-scheme fallback). Routes the same as `galley://`. |

Do not collapse `galley://` and `galley-viewer://` — they encode different caller intent (route-me-anywhere vs. open-in-the-Viewer). Sending `galley://` to force a Mac open would loop back into the Server's router.

#### Transport matrix

| Trigger | Path |
|---|---|
| Finder opens `.md` | Server (LSHandler) → AVP via Kosmos `RouteToTunnelClient`, else `galley-viewer://` to Mac Viewer |
| External `galley://path` (Finder / BBEdit) | Server (LSHandler) → routes same as above |
| External `galley-viewer://path` | Mac Viewer direct (forced-Mac) |
| Mac Viewer menu: "Show on Vision Pro" | Mac Viewer → Server via Kosmos `RouteToAVP { target }` → Server sends `RouteToTunnelClient` → AVP |
| AVP-local `.fileImporter` open | AVP renders locally via `SwiftMarkdownRenderer` + bundled template. No Kosmos, no Server. |
| AVP take-off handoff | Server observes AVP peer drop → `galley-viewer://` per active doc |
| "Show on Vision Pro" menu enabledness | Reads AVP peer presence via Kosmos |
| Mac-doc HTML / assets / live reload to AVP | Kosmos tunnel. WebKit's `kosmos://local/preview/<path>` → `KosmosTunnelSchemeHandler` → `KosmosHTTPTunnel.Client` → `ProxyHTTPRequest` → `KosmosHTTPTunnel.Responder` (hosted by `ServerKosmosService`, backed by `InProcessTunnelBackend`) → **in-process render** → `ProxyHTTPResponseHead` + `ProxyHTTPResponseChunk` back. SSE flushes line-by-line; bounded responses are buffered on AVP and yielded as a single `.data` to WebKit. |
| Quick Look / print / export | In-process render via `ClassicPreviewSchemeHandler` (`x-galley://local`). No HTTP. |

#### Kosmos message inventory

Two surfaces — control and the render tunnel data plane.

**Control plane.** Three messages are Galley-specific (in `GalleyKosmos.swift`); the rest — generic `OpenURL`, window-lifecycle, suspend/resume — come from the Kosmos package via `KosmosServiceHost`.

| Message | Sender → Receiver | Purpose |
|---|---|---|
| `RouteToAVP { target: DocumentTarget }` → `Reply { accepted }` | Mac Viewer → Server | "User chose Show on Vision Pro — dispatch this file." Server runs its dispatch path. |
| `RouteToTunnelClient { target: DocumentTarget, deviceType: DeviceType? }` → `Reply { accepted }` | Server → AVP (or Mac) | Open/re-target a document on the tunnel client. The receiver fires `GalleyViewerRequestActivity(target:).open()`, so the open lands on the same `handlesExternalEvents` path as any local open; bytes then ride the tunnel via `kosmos://local`. |
| `OpenInEditor { target: DocumentTarget }` → `Reply { accepted }` | Mac Viewer → Server (or Server-side) | Open a document in the resolved external editor at a line. |
| generic `OpenURL` / suspend / resume | per Kosmos | AVP `scenePhase` transitions drive suspend/resume so the Mac gates `isAVPReachable`; `OpenURL` carries plain URL opens. |

**Data plane (render tunnel):**

| Message | Sender → Receiver | Purpose |
|---|---|---|
| `ProxyHTTPRequest { requestID, method, urlPath, headers, body }` | AVP → Server | A WebKit fetch on `kosmos://local/<route>/<path>`; the Responder answers via `InProcessTunnelBackend` (in-process render). `urlPath` is the percent-encoded path (the sentinel host `local` is discarded). Carries `X-Kosmos-Origin: kosmos://local` for the `<base href>`. |
| `ProxyHTTPResponseHead { requestID, status, headers }` | Server → AVP | Status + headers. AVP inspects `Content-Type`: `text/event-stream` → streaming; else buffering. |
| `ProxyHTTPResponseChunk { requestID, sequence, bytes, isFinal }` | Server → AVP | Body bytes; multiple per request. Bounded → buffered fast path; SSE → line-by-line streaming. |
| `ProxyHTTPCancel { requestID }` | AVP → Server | WebKit cancelled/navigated away; drop the matching task. Also published on `AsyncThrowingStream.onTermination`. |

Adding to either list is a smell. `DocumentWatcher` tracks SSE subscribers and drops files when the last disconnects — when AVP closes a `WebPage`, the scheme handler cancels its `URLSchemeTask`, the tunnel emits `ProxyHTTPCancel`, the backend drops its work, and the watcher cleans up.

#### Why Server→Mac Viewer stays on `NSWorkspace.open(galley-viewer://)`, not Kosmos

Kosmos can only message **running** peers — it cannot spawn a process. The Server→Mac-Viewer path needs to launch-or-wake Galley.app and deliver the URL atomically; LaunchServices does that in one shot. Kosmos would split one operation into a launch + wait-for-registration race. (The Server uses `galley-viewer://` here, not `galley://` — `galley://` is its own routing scheme and would loop back.)

#### Do not undo this

When tempted to:
- move Kosmos into Galley.app and let it be the routing authority — re-read requirements (1) and (3);
- reintroduce a loopback HTTP listener / probe as "the signal Mac Viewer needs from the Server" — Kosmos peer presence already answers it, and the HTTP server was deliberately removed;
- merge `galley://` and `galley-viewer://` into one scheme — they encode different caller intent and collapsing them silently changes the semantics of every BBEdit / Xcode integration and risks routing loops.
