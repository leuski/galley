import SwiftUI
import GalleyCoreKit

struct ServerSettingsView: View {
  @State private var serverStatus = ServerStatusModel()

  /// Mirrors `ActiveServerAgent.isEnabled` as @State so SwiftUI
  /// tracks changes. The agents are static enums (not Observable
  /// sources) — without this @State, flipping the toggle wouldn't
  /// re-evaluate the probe key and the `.task(id:)` loop wouldn't
  /// restart, leaving the pill stuck at "Disabled".
  ///
  /// Initialised to `false`; the real value is loaded async in
  /// `body`'s `.task` because `ActiveServerAgent.isEnabled` is async.
  @State private var serverEnabled: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent {
        ServerStatusPill(status: serverStatus.status)
        Toggle("Server", isOn: serverEnabledBinding)
          .toggleStyle(.switch)
          .labelsHidden()
      } label: {
        Text("Server")
      }
      .task(id: serverEnabled) {
        await serverStatus.run(enabled: serverEnabled) {
          ServerPortFile.preferredEndpointURL
        }
      }
      .task {
        // Load the real agent state once on appear. Subsequent
        // changes flow through `serverEnabledBinding` so we don't
        // need to re-poll.
        serverEnabled = await ActiveServerAgent.isEnabled
      }
      Text("""
          When on, the background server makes documents available in any \
          browser. Registered as a login item so it restarts after \
          logout. The server binds to 127.0.0.1 only, so it's only accessible \
          form this computer.
          """).subtitle()
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
}

#Preview {
  ServerSettingsView()
}
