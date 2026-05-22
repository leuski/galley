import ALFoundation
import SwiftUI
import GalleyCoreKit

struct ServerSettingsView: View {
  @Environment(KosmosViewerService.self) private var kosmos

  private let agent = ActiveServerAgent.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent {
        ServerStatusPill(status: pillStatus)
        Toggle("Server", isOn: serverEnabledBinding)
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
  }

  /// Pill is "is the Server actually reachable right now?", not "is
  /// the Login Item registered?". Those are independent — a Server
  /// launched outside launchd (e.g. via the relaunch fallback or a
  /// manual Finder launch) is still running even with the toggle
  /// off. Showing `.disabled` in that case made the toggle look
  /// broken because turning it off didn't grey out the pill.
  ///
  /// Truth table now:
  /// - peer connected → `.running` (regardless of toggle)
  /// - no peer + toggle on → `.notResponding` (concerning — the
  ///   user asked for it to run; it isn't)
  /// - no peer + toggle off → `.stopped` (matches intent)
  private var pillStatus: ServerStatus {
    if kosmos.isServerPeerConnected {
      let fallback = URL(string: "http://127.0.0.1")
        !! "compile-time-constant http://127.0.0.1 should parse"
      let url = ServerPortFile.http.endpointURL ?? fallback
      return .running(url)
    }
    return agent.isEnabled ? .notResponding : .stopped
  }

  private var serverEnabledBinding: Binding<Bool> {
    Binding(
      get: { agent.isEnabled },
      set: { newValue in
        Task { await agent.setEnabled(newValue) }
      }
    )
  }
}
