import ALFoundation
import SwiftUI
import GalleyCoreKit

struct ServerSettingsView: View {
  @Environment(KosmosViewerService.self) private var kosmos

  private let agent = ActiveServerAgent.shared

  /// User-visible toggle position. Mirrors `kosmos.isServerPeerConnected`
  /// in steady state, but holds the user's intent during the gap
  /// between "user clicked" and "Kosmos sees the new peer state."
  /// Without this, the Binding's `get` would return the old kosmos
  /// value the instant the user clicks, and SwiftUI would snap the
  /// toggle back — making it look unclickable.
  @State private var toggleIntent: Bool = false

  var body: some View {
    // Pill is fed straight from Kosmos. Toggle uses local intent
    // state (see `toggleIntent`), kept in sync with Kosmos via
    // `.onChange` below.
    let peerConnected = kosmos.isServerPeerConnected

    VStack(alignment: .leading, spacing: 4) {
      LabeledContent {
        ServerStatusPill(status: pillStatus(peerConnected: peerConnected))
        Toggle("Server", isOn: toggleBinding)
          .toggleStyle(.switch)
          .labelsHidden()
      } label: {
        Text("Server")
      }
      Text("""
          When on, the background server makes documents available in any \
          browser. Registered as a login item so it restarts after \
          logout. The server binds to 127.0.0.1 only, so it's only accessible \
          form this computer.
          """).subtitle()
    }
    .onAppear { toggleIntent = peerConnected }
    .onChange(of: peerConnected) { _, new in
      // Reconcile the toggle with reality when Kosmos peer state
      // changes for *any* reason — user-driven (toggle just fired
      // `setEnabled`) or external (server crashed, was launched by
      // Finder, etc.). The Binding's `set` updates `toggleIntent`
      // directly, so this assignment is a no-op for user-initiated
      // changes and the source-of-truth update for everything else.
      toggleIntent = new
    }
  }

  /// Pill state is derived from Kosmos peer presence alone:
  /// - peer connected → `.running`
  /// - no peer       → `.stopped`
  ///
  /// If Kosmos can't find the Server peer while the Server process is
  /// running, that's a Kosmos-level bug — fix it in the link, not by
  /// layering in secondary signals here.
  private func pillStatus(peerConnected: Bool) -> ServerStatus {
    guard peerConnected else { return .stopped }
    let fallback = URL(string: "http://127.0.0.1")
      !! "compile-time-constant http://127.0.0.1 should parse"
    let url = ServerPortFile.http.endpointURL ?? fallback
    return .running(url)
  }

  /// Two-way binding for the toggle. Read from local intent (so the
  /// user's click takes immediate visual effect); write updates the
  /// intent *and* kicks off `agent.setEnabled`, which manages
  /// LaunchAgent registration + terminates the running Server on
  /// toggle-off. Kosmos peer state then catches up asynchronously
  /// and `.onChange(of: peerConnected)` reconciles the intent.
  private var toggleBinding: Binding<Bool> {
    Binding(
      get: { toggleIntent },
      set: { newValue in
        toggleIntent = newValue
        Task { await agent.setEnabled(newValue) }
      }
    )
  }
}
