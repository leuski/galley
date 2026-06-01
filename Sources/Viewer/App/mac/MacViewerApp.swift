#if os(macOS)
import AppKit
import GalleyCoreKit
import SwiftUI
import UniformTypeIdentifiers
import KosmosAppKit

@main
struct MacViewerApp: App {
  @NSApplicationDelegateAdaptor(ViewerAppDelegate.self) var appDelegate
  @State private var boot = AppBoot()
  @State private var recents = RecentDocumentsModel()
  @State private var kosmos: ViewerKosmosService

  init() {
    URL.createLocalizedApplicationSupportDirectory()
    Self.pinWindowTabbingPreference()
    // If the active server-agent backend persists an absolute path
    // to the helper, the user moving `Galley.app` would leave that
    // record pointing at a stale location. Detect and repair before
    // any UI reflects stale state. No-op when nothing is installed.
    // Fire-and-forget: scenes don't need to wait on it.
    Task { await ActiveServerAgent.shared.validateAndRepair() }
    // Start the Kosmos surface so the peer set populates by the
    // time the menu / pill consult it. Independent of `AppBoot`.
    let kosmos = ViewerKosmosService()
    kosmos.start()
    _kosmos = State(wrappedValue: kosmos)
  }

  /// Force `NSWindow.userTabbingPreference == .always` for this process
  /// via the volatile argument domain (outranks the user's global
  /// "Prefer tabs" setting, but only for us — WindowProbe FINDINGS §8).
  /// That's the substrate the per-open `allowsAutomaticWindowTabbing`
  /// toggle needs so `newTab` opens are born-as-tab without a flash;
  /// `newWindow`/`replaceCurrent` still open standalone because the
  /// toggle is flipped off for them.
  private static func pinWindowTabbingPreference() {
    var domain = UserDefaults.standard
      .volatileDomain(forName: UserDefaults.argumentDomain)
    domain["AppleWindowTabbingMode"] = "always"
    UserDefaults.standard
      .setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
  }

  var body: some Scene {
    DocumentScene()
      .environment(boot)
      .environment(recents)
      .environment(kosmos)

    HelpScene()
      .environment(boot)
      .environment(recents)

    SettingsScene()
      .environment(boot)
      .environment(kosmos)
  }
}
#endif
