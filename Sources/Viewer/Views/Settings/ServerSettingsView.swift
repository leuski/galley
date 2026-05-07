import SwiftUI
import GalleyCoreKit

struct ServerSettingsView: View {
  @Bindable var defaults = Defaults.shared

  @State private var portString: String = String(Defaults.shared.port)
  @State private var serverStatus = ServerStatusModel()

  /// Mirrors `ActiveServerAgent.isEnabled` as @State so SwiftUI
  /// tracks changes. The agents are static enums (not Observable
  /// sources) — without this @State, flipping the toggle wouldn't
  /// re-evaluate `probeKey` and the `.task(id:)` loop wouldn't
  /// restart, leaving the pill stuck at "Disabled".
  ///
  /// Initialised to `false`; the real value is loaded async in
  /// `body`'s `.task` because `ActiveServerAgent.isEnabled` is async.
  @State private var serverEnabled: Bool = false

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
        Toggle("Server", isOn: serverEnabledBinding)
          .toggleStyle(.switch)
          .labelsHidden()
      } label: {
        Text("Server")
      }
      .task(id: probeKey) {
        await serverStatus.run(host: probeHost)
      }
      .task {
        // Load the real agent state once on appear. Subsequent
        // changes flow through `serverEnabledBinding` so we don't
        // need to re-poll.
        serverEnabled = await ActiveServerAgent.isEnabled
      }

      LabeledContent {
        TextField("Port", text: $portString)
          .labelsHidden()
          .onSubmit { commitPort() }
          .frame(width: 80)
          .onChange(of: Defaults.shared.port) { _, newPort in
            portString = String(newPort)
          }
      } label: {
        Text("Port")
      }
    } footer: {
      Text("""
          When on, the background server makes documents available in any \
          browser. Registered as a login item so it restarts after \
          logout. The server binds to 127.0.0.1 only.
          """)
    }
  }

  private var serverEnabledBinding: Binding<Bool> {
    Binding(
      get: { serverEnabled },
      set: { newValue in
        // Optimistic flip so the pill starts probing immediately for
        // the requested state. setEnabled is async; reconcile when
        // it returns. If the registration failed the post-call state
        // disagrees and we revert the toggle.
        serverEnabled = newValue
        Task {
          let actual = await ActiveServerAgent.setEnabled(newValue)
          if actual != newValue {
            serverEnabled = actual
          }
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
