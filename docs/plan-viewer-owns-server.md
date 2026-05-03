# Plan: Viewer owns Server lifecycle and preferences

Status: proposed, awaiting review.

## Goal

The Viewer becomes the single owner of server preferences and lifecycle. The
Server reads its config from the Viewer's defaults file, has no Settings UI of
its own, and is started/stopped by the Viewer via `SMAppService.agent()`.

The four user-facing rules:

1. Port and the launch-server toggle live in Viewer Settings.
2. Server reads `~/Library/Preferences/net.leuski.galley.plist` (Viewer's
   defaults), not its own.
3. Server's "Settings…" menu item activates the Viewer and opens Viewer
   Settings.
4. Server has no `Settings { }` scene at all.

## What's already true (so the plan doesn't reinvent it)

- Server.app is built and embedded inside Galley.app at
  `Contents/Resources/Markdown Preview Server.app`. See
  `MarkdownPreviewer.xcodeproj/project.pbxproj:477` (Resources phase) and the
  Viewer→Server target dependency at `project.pbxproj:609-613`.
- Sandbox is off on both targets, so a process can read another process's
  preferences plist via `UserDefaults(suiteName:)`.
- The Viewer has a `galley://` URL scheme registered in
  `Sources/Viewer/Resources/Info.plist:17-29`, dispatched by
  `ViewerAppDelegate.application(_:open:)`.
- Bundle IDs:
  - Viewer = `net.leuski.galley`
  - Server = `net.leuski.galley.server`
- `keyPrefix` in `Sources/Viewer/PreviewSchemeHandler.swift:8` already equals
  the Viewer bundle ID, so Viewer's existing keys
  (`net.leuski.galley.rendererPersistent` etc.) already live "under the
  Viewer name."

## What changes

### 1. Cross-process defaults contract in `GalleyCoreKit`

The contract between the two apps lives as a `GalleyDefaults` protocol,
not a free-standing helper object. Each `AppModel` *implements* the
protocol directly via `ObservableDefaults`-generated properties, so the
shared surface is part of each model's own settings rather than a
composed sub-object accessed through `model.shared.port`.

Add `Sources/GalleyCoreKit/Utilities/GalleyDefaults.swift`:

```swift
public protocol GalleyDefaults {
  var port: UInt16 { get set }
  var rendererPersistent: String? { get set }
  var templatePersistent: String? { get set }
}

extension GalleyDefaults {
  public static var suiteName: String { "net.leuski.galley" }
  public static var defaults: UserDefaults {
    UserDefaults(suiteName: suiteName)!
  }
  public static var portKey: String { "port" }
  public static var rendererPersistentKey: String { "rendererPersistent" }
  public static var templatePersistentKey: String { "templatePersistent" }
  public static var defaultPort: UInt16 { 8089 }
}
```

The protocol body declares the surface; the extension owns the
storage details (suite name, key strings, default values) so the two
conformers can't desync via typos. Each AppModel re-declares only the
property line itself, e.g.
`@DefaultsKey(GalleyDefaults.portKey) var port: UInt16 = GalleyDefaults.defaultPort`.

Caveat acknowledged: the protocol is a documented contract, not an
enforced storage backend — Swift can't make conformance to
`var port { get set }` mandate a particular suite. In practice we
funnel both AppModels through `@ObservableDefaults(suiteName:
GalleyDefaults.suiteName, ...)` and the static keys, so the only way
to break the link is intentional.

Naming note: keys move from the current
`"net.leuski.galley.rendererPersistent"` (Viewer) and
`"MarkdownPreviewer.rendererPersistent"` (Server) to plain
`"rendererPersistent"` inside the suite. The suite **is** the
namespace — prefixing again is redundant.

### 2. One-time migration

no defaults migration is required

### 3. Viewer changes

`Sources/Viewer/Models/AppModel.swift`:

- Replace `@Observable` with
  `@ObservableDefaults(suiteName: GalleyDefaults.suiteName)` and conform
  the class to `GalleyDefaults`. The macro generates the
  `_$observationRegistrar`, the per-property access/mutation hooks, and
  the UserDefaults persistence — so we drop the hand-rolled equivalents.
- Add the three contract properties:
  ```swift
  @DefaultsKey(GalleyDefaults.portKey)
  var port: UInt16 = GalleyDefaults.defaultPort
  @DefaultsKey(GalleyDefaults.rendererPersistentKey)
  var rendererPersistent: String?
  @DefaultsKey(GalleyDefaults.templatePersistentKey)
  var templatePersistent: String?
  ```
- Drop the `Keys` enum (lines 42-47); the three shared keys live on the
  protocol now.
- `enablePerDocumentOverrides` and `openBehavior` stay private to the
  Viewer and don't belong on the contract, but they can become
  `@DefaultsKey` properties on the same class — same suite, distinct
  Viewer-only keys. This deletes their `didSet` blocks (lines 25-30,
  35-40).
- `init(...)` reads from the macro-backed properties instead of
  `UserDefaults.standard.string(forKey: ...)`:
  `TemplateChoice.create(source: store, persistent: self.templatePersistent)`
  and likewise for the processor envelope.
- `startPersistenceObservation()` (lines 128-147) keeps its observation
  loop shape but writes through to `self.templatePersistent` /
  `self.rendererPersistent` (both `@DefaultsKey`-backed) instead of
  `UserDefaults.standard.set(...)`. Purpose narrows to "envelope →
  defaults-backed property"; the macro handles the actual UserDefaults
  write, observation participation, and cross-process notification.
- Add a launch-server wrapper: a small `enum ServerAgent` using
  `SMAppService.agent(plistName: "net.leuski.galley.server.plist")` with
  `isEnabled` / `setEnabled(_:)`. Lives in
  `Sources/Viewer/Utilities/ServerAgent.swift` — only the Viewer needs
  to ask about its state.

`Sources/Viewer/Views/SettingsView.swift`:

- New section "Markdown Preview Server" containing:
  - Toggle "Run Server" — `isOn:` binding wraps
    `ServerAgent.isEnabled` / `ServerAgent.setEnabled(_:)`. Default is
    OFF on a fresh install: `SMAppService.agent(...).status` reads
    `.notRegistered` until the user opts in, which the toggle reflects
    directly without any seeded UserDefaults.
  - Port field — `TextField` bound to `$model.port`. The AppModel is
    already the single source of truth via `@ObservableDefaults`; we
    don't need a separate `@AppStorage` lookup, and binding through the
    model keeps the observation graph consistent.
- Server-side renderer / template settings already exist on this view
  (lines 151-167) and continue to work; they now read/write the suite
  via the modified `AppModel`.

`Sources/Viewer/ViewerApp.swift`:

- Add `.onOpenURL { url in … }` to the `WindowGroup(for: URL.self)` scene
  (or to a thin root view inside it). Inside the closure, branch on
  `url.scheme == "galley"` and `url.host == "settings"`: call
  `@Environment(\.openSettings) private var openSettings` followed by
  `NSApp.activate(ignoringOtherApps: true)`. File URLs continue to flow
  through `ViewerAppDelegate.application(_:open:)` as today — no changes
  there. SwiftUI delivers `galley://settings` straight to `onOpenURL`
  because the URL scheme is already registered in
  `Sources/Viewer/Resources/Info.plist`; we don't need to extend the
  AppDelegate's `normalize(_:)` path or add a `showSettingsWindow:`
  selector dance.

### 4. Server changes

`Sources/Server/App/AppModel.swift`:

- Replace `@Observable` with
  `@ObservableDefaults(suiteName: GalleyDefaults.suiteName, limitToInstance: false)`
  and conform the class to `GalleyDefaults`. The `limitToInstance: false`
  flag is the load-bearing bit: it tells the macro to listen to *all*
  changes on this suite, including cross-process writes delivered via
  `cfprefsd`, so the Server reacts when the Viewer writes a new port.
- Delete the manual `port` accessors (lines 10-22) — replaced by:
  ```swift
  @DefaultsKey(GalleyDefaults.portKey)
  var port: UInt16 = GalleyDefaults.defaultPort
  ```
  The macro-generated property handles `access(keyPath:)` /
  `withMutation(keyPath:)`, the UserDefaults read/write, and observation
  participation.
- Add `@DefaultsKey` properties for `rendererPersistent` and
  `templatePersistent` the same way; these feed the choice envelopes at
  init.
- Delete `launchAtLogin` (lines 24-34) entirely. Lifecycle moves to the
  Viewer's `ServerAgent`.
- Delete the `Keys` enum (lines 51-55). Three of those keys live on the
  protocol; the fourth is gone with `launchAtLogin`.
- Delete `startPersistenceObservation()` (lines 114-133). The Server
  doesn't write to these keys — it only reads them. The Viewer writes;
  cross-process delivery handles the rest.
- Replace what would have been a manual KVO observer with a small
  `withObservationTracking` loop in init that watches `self.port` and
  calls `restartServerIfRunning()` on change. The macro makes `port`
  participate in the Observable system, so the Viewer's cross-process
  write surfaces through the same mechanism we'd use for an in-process
  change — no `DistributedNotificationCenter`, no manual `addObserver`.
- The `startServer()` / `restartServerIfRunning()` pair stays. `hostURL`
  reads `self.port` directly. Processor / template selections do not
  require an observer: the renderer + template are read at request time
  via the existing `@Sendable` provider closures, which pull from the
  in-memory envelopes that were initialized from the shared keys.

`Sources/Server/App/LoginItem.swift`:

- Delete. Replaced by `ServerAgent` in `Viewer`.

`Sources/Server/Menu/SettingsView.swift`:

- Delete.

`Sources/Server/MarkdownPreviewerApp.swift`:

- Delete the `Settings { … }` scene (lines 32-41).
- Drop the `import` of the deleted `SettingsView`.

`Sources/Server/Menu/MenuBarContent.swift`:

- Replace the "Settings…" button (lines 31-34) with one that calls
  `NSWorkspace.shared.open(URL(string: "galley://settings")!)`.
- Drop the `@Environment(\.openSettings)` lookup (line 14).
- Delete the `Quit` button (line 36). The server is now slaved to the
  Viewer's "Run Server" toggle; a Quit item would terminate the process
  while leaving `SMAppService` in the enabled state, so launchd would
  bring it back at next login and the on-disk toggle would lie. Users
  who want the server off use the Viewer's toggle, which is the single
  source of truth.
- Drop the BBEdit "Install scripts…" entry from this menu (and any
  related code paths). The installer already lives in Viewer Settings;
  the Server's "Settings…" item now opens the Viewer's Settings, so a
  duplicate Server-side entry would be redundant.

### 5. Launch agent plist

Add `Sources/Viewer/Resources/net.leuski.galley.server.plist` with:

- `Label` = `net.leuski.galley.server`
- `BundleProgram` =
  `Contents/Resources/Markdown Preview Server.app/Contents/MacOS/Markdown Preview Server`
  (path is relative to the *Viewer's* bundle root, since `SMAppService.agent`
  resolves `BundleProgram` from the calling app's bundle)
- `RunAtLoad` = `false` (let `SMAppService.register` control activation)
- `KeepAlive` = `false` (we don't want launchd to bring it back if the user
  toggled the switch off)
- `AssociatedBundleIdentifiers` = `[net.leuski.galley.server]` so System
  Settings → General → Login Items shows it under "Galley".

### 6. Project file (`project.pbxproj`) edits

Three edits, all surgical:

a. Add an `XCRemoteSwiftPackageReference` for ObservableDefaults
   (alongside the existing FlyingFox / swift-markdown / ALFoundation
   refs) plus an `XCSwiftPackageProductDependency` for the
   `ObservableDefaults` product. Link the product to the
   `GalleyCoreKit` framework target so both apps inherit it.

b. Add a new `PBXCopyFilesBuildPhase` to the Viewer target with
   `dstSubfolderSpec = 1` (Wrapper) and
   `dstPath = "Contents/Library/LaunchAgents"`. Its only file is
   `net.leuski.galley.server.plist`. Insert this phase after the
   existing "Embed Frameworks" phase (line 328) so it runs after the
   framework copy.

c. Add `net.leuski.galley.server.plist` as a `PBXFileReference` and a
   `PBXBuildFile` entry referenced from the new copy phase.

No other project changes. `Server.app` stays where it is (Resources).
The target dependency Viewer→Server already exists.

## Behavior contract

- User toggles "Run Markdown Preview Server" ON in Viewer Settings →
  `SMAppService.agent(...).register()` → launchd starts Server.app via
  the `BundleProgram` path. Server's AppModel hydrates `port`,
  `rendererPersistent`, `templatePersistent` from the shared suite via
  `@DefaultsKey` and starts listening. Subsequent logins relaunch it
  automatically (that's what "agent" means).
- User toggles OFF → `unregister()` → launchd stops the process. Toggle
  state is persistent across logins via `SMAppService` itself, not
  UserDefaults.
- User changes port in Viewer Settings → assignment to `model.port`
  writes through the macro to the shared suite → `cfprefsd` notifies
  the Server process → ObservableDefaults (with `limitToInstance: false`)
  emits an Observable change on the Server's `port` property → the
  Server's `withObservationTracking` loop fires
  `restartServerIfRunning()`. If the Server isn't running, nothing
  happens.
- User picks a different Processor in either app's menu → choice
  envelope updates → the AppModel's persistence loop writes the new ID
  to `self.rendererPersistent` (a `@DefaultsKey` property), which the
  macro persists to the shared suite. The Server reads its renderer at
  request time via the existing `@Sendable` provider closure, so the
  next HTTP request uses the new pick — no observer needed, no server
  restart.
- User clicks Server menu → Settings… → `galley://settings` opens →
  Viewer's scene-level `.onOpenURL` activates the app and calls
  `openSettings()`.
- User wants the server off → toggles "Run Server" off in Viewer
  Settings. There is no Quit item in the Server's menu; the toggle is
  the sole control surface for the process's lifetime.

## Decisions

- "Run Markdown Preview Server" defaults to OFF on a fresh install.
  `SMAppService.agent(...).status` is the source of truth, so no seeded
  default is needed; the toggle simply reads `.notRegistered` until the
  user flips it.
- BBEdit "Install scripts…" is removed from the Server menu and lives
  only in Viewer Settings. Server's "Settings…" already opens the
  Viewer's Settings window.

## Dependencies

Adds **ObservableDefaults**
(`https://github.com/fatbobman/ObservableDefaults`) as a SwiftPM
package reference resolved by Xcode against
`MarkdownPreviewer.xcodeproj` — same wiring as FlyingFox /
swift-markdown / ALFoundation. Linked into `GalleyCoreKit` so both
apps inherit it transitively (the protocol lives in the kit; the
macros are imported once at the kit boundary).

Why this dependency earns its keep:

- The Server's `port` accessor today is ~13 lines of manual
  `access(keyPath:)` / `withMutation(keyPath:)` + UserDefaults
  read/write. With `@DefaultsKey` it's two lines.
- Cross-process change observation (`limitToInstance: false`) replaces
  the manual KVO + `cfprefsd` plumbing this plan would otherwise
  introduce in the Server.
- The persistence-observation loop duplicated across both AppModels
  shrinks (Server's disappears; Viewer's narrows to "envelope →
  defaults-backed property" without the manual `UserDefaults.standard`
  write).
- It plays nicely with the protocol: each AppModel is a clean
  `@ObservableDefaults` conformer to `GalleyDefaults`, with app-private
  `@DefaultsKey` properties sitting alongside the contract properties
  on the same class.

Constraint to remember: `@DefaultsBacked` properties don't support
`willSet` / `didSet`. The Server reacts to `port` changes via
`withObservationTracking` instead, which is what the refactor is
moving toward anyway. The Viewer's existing `didSet` blocks for
`enablePerDocumentOverrides` / `openBehavior` go away when those
become `@DefaultsKey` — the macro persists them automatically, which
is all those `didSet` blocks were doing.

Versions: ObservableDefaults requires Swift 6 / macOS 14+, both
already required by this project.

## File-touch summary

New:
- `Sources/GalleyCoreKit/Utilities/GalleyDefaults.swift`
- `Sources/Viewer/Utilities/ServerAgent.swift`
- `Sources/Viewer/Resources/net.leuski.galley.server.plist`

Modified:
- `Sources/Viewer/Models/AppModel.swift`
- `Sources/Viewer/Views/SettingsView.swift`
- `Sources/Viewer/ViewerApp.swift`
- `Sources/Server/App/AppModel.swift`
- `Sources/Server/Menu/MenuBarContent.swift`
- `Sources/Server/MarkdownPreviewerApp.swift`
- `MarkdownPreviewer.xcodeproj/project.pbxproj` (adds
  ObservableDefaults package reference + the LaunchAgents copy phase)

Deleted:
- `Sources/Server/App/LoginItem.swift`
- `Sources/Server/Menu/SettingsView.swift`
