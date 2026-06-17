#if os(macOS)
import KosmosAppKit
import SwiftUI
import GalleyCoreKit

struct ServerSettingsView: View {
  private let agent = ActiveServerAgent.shared

  /// Number of seconds we tolerate "intent on, no Kosmos peer yet"
  /// before flipping the pill from `.starting` to `.notResponding`.
  /// Long enough to cover a normal launchd-bootstrap + HTTP-bind +
  /// Kosmos-advertise round-trip; short enough that a genuine
  /// failure surfaces while the user is still looking at the pane.
  private static let graceSeconds: Duration = .seconds(5)

  /// User-visible toggle position. Drives Toggle directly so a click
  /// takes effect synchronously (no snap-back while Kosmos catches
  /// up). Reconciled with `peerConnected || agentEnabled` via
  /// `.onChange` below.
  @State private var toggleIntent: Bool = false

  /// True after the grace window has elapsed since intent went on
  /// without Kosmos seeing the peer. Reset to false whenever the
  /// inputs change via `.task(id:)`.
  @State private var graceExpired: Bool = false

  var body: some View {
    let peerConnected = AppModel.shared.kosmos.isServerPeerConnected
    let serverURL = AppModel.shared.kosmos.serverPeerHTTPURL
    let agentEnabled = agent.isEnabled
    let status = Self.computeStatus(
      peerConnected: peerConnected,
      serverURL: serverURL,
      agentEnabled: agentEnabled,
      graceExpired: graceExpired)

    VStack(alignment: .leading, spacing: 4) {
      LabeledContent {
        ServerStatusPill(status: status)
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
    .onAppear { toggleIntent = peerConnected || agentEnabled }
    .onChange(of: peerConnected) { _, new in
      toggleIntent = new || agentEnabled
    }
    .onChange(of: agentEnabled) { _, new in
      toggleIntent = peerConnected || new
    }
    // The grace timer keys off the *condition* that should be graced —
    // "intent on, no peer yet". When that's true we sleep the grace
    // window then flip `graceExpired`. Any other transition (peer
    // connects, intent goes off) re-fires `.task(id:)` and cancels
    // the in-flight sleep, resetting `graceExpired` to false. So
    // `graceExpired == true` only ever means "we waited the full
    // window for *this* attempt and Kosmos still hasn't seen the peer."
    .task(id: needsGrace(
      agentEnabled: agentEnabled, peerConnected: peerConnected
    )) {
      graceExpired = false
      guard needsGrace(
        agentEnabled: agentEnabled, peerConnected: peerConnected)
      else { return }
      try? await Task.sleep(for: Self.graceSeconds)
      if !Task.isCancelled {
        graceExpired = true
      }
    }
  }

  /// Pure state-machine: combine the two observable inputs and the
  /// grace-window state into a single pill status. Exposed as a
  /// static func so it's straightforward to unit-test if needed.
  static func computeStatus(
    peerConnected: Bool,
    serverURL: URL?,
    agentEnabled: Bool,
    graceExpired: Bool
  ) -> ServerStatus {
    // Peer presence wins — if Kosmos sees the Server, the Server is
    // up regardless of LaunchAgent state (it might have been launched
    // by Finder, manually, or the user just toggled on and the agent
    // landed before the URL did).
    if peerConnected, let url = serverURL {
      return .running(url)
    }
    if peerConnected {
      // Peer connected but no URL in metadata yet — shouldn't happen
      // with the Server publishing on bind, but treat as still
      // coming up rather than green-with-missing-info.
      return .starting
    }
    if !agentEnabled {
      return .disabled
    }
    return graceExpired ? .notResponding : .starting
  }

  /// True when the grace timer should be running — intent is on but
  /// Kosmos doesn't see the peer yet.
  private func needsGrace(agentEnabled: Bool, peerConnected: Bool) -> Bool {
    agentEnabled && !peerConnected
  }

  /// Toggle reads local intent (immediate visual feedback) and writes
  /// through `agent.setEnabled`, which manages LaunchAgent
  /// registration + terminates the running Server on toggle-off.
  /// Kosmos peer state then catches up asynchronously and the
  /// `.onChange` handlers reconcile.
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
#endif
