import SwiftUI
import GalleyCoreKit

struct ServerSettingsView: View {
  @Bindable var defaults = Defaults.shared

  @State private var portString: String = String(Defaults.shared.port)
  @State private var serverStatus = ServerStatusModel()

  /// Mirrors `ServerAgent.isEnabled` as @State so SwiftUI tracks
  /// changes. `ServerAgent.isEnabled` reads `SMAppService.status`,
  /// which is *not* an Observable source — without this @State,
  /// flipping the toggle wouldn't re-evaluate `probeKey` and the
  /// `.task(id:)` loop wouldn't restart, leaving the pill stuck at
  /// "Disabled".
  @State private var serverEnabled: Bool = ServerAgent.isEnabled

  /// Stable id for `.task(id:)` — restarts the probe loop only when
  /// the toggle flips or the port changes.
  private struct ProbeKey: Equatable {
    let enabled: Bool
    let port: UInt16
  }

  private var probeKey: ProbeKey {
    ProbeKey(enabled: serverEnabled, port: defaults.port)
  }

  private var probeHost: URL? {
    serverEnabled ? defaults.host : nil
  }

  var body: some View {
    Section {
      LabeledContent {
        ServerStatusPill(status: serverStatus.status)
        Toggle("Run server", isOn: serverEnabledBinding)
          .toggleStyle(.switch)
          .labelsHidden()
      } label: {
        Text("Run server")
      }
      .task(id: probeKey) {
        await serverStatus.run(host: probeHost)
      }
      Text(
        "When on, a background server makes documents available in any "
        + "browser. Registered as a login item so it restarts after "
        + "logout."
      )
      .subtitle()

      LabeledContent {
        TextField("", text: $portString)
          .labelsHidden()
          .onSubmit { commitPort() }
          .frame(width: 80)
          .onChange(of: Defaults.shared.port) { _, newPort in
            portString = String(newPort)
          }
      } label: {
        Text("Port")
        Text("""
              Default: \(String(GalleyConstants.defaultPort)). \
              The server binds to 127.0.0.1 only.
              """)
        .fixedSize(horizontal: true, vertical: false)
      }
    }
  }

  private var serverEnabledBinding: Binding<Bool> {
    Binding(
      get: { serverEnabled },
      set: { newValue in
        // Optimistic flip so the pill starts probing immediately for
        // the requested state. setEnabled returns the post-call status
        // — if it disagrees (registration failed), reconcile.
        serverEnabled = newValue
        let actual = ServerAgent.setEnabled(newValue)
        if actual != newValue {
          serverEnabled = actual
        }
      }
    )
  }

  private func commitPort() {
    guard let value = UInt16(portString), value > 0 else {
      portString = String(Defaults.shared.port)
      return
    }
    Defaults.shared.port = value
  }
}

#Preview {
  ServerSettingsView()
}
