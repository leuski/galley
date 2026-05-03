import SwiftUI
import GalleyCoreKit

/// Compact status indicator next to the "Run server" toggle. Renders
/// `ServerStatus` as a colored dot + label pair so the user can tell
/// at a glance whether the server is actually reachable.
struct ServerStatusPill: View {
  let status: ServerStatus

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(tintColor)
        .frame(width: 8, height: 8)
      Text(label)
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Server status: \(label)")
  }

  private var label: String {
    switch status {
    case .unknown:        return "Checking…"
    case .disabled:       return "Disabled"
    case .running(let url): return "Running on :\(url.port ?? 0)"
    case .stopped:        return "Not running"
    case .notResponding:  return "Not responding"
    }
  }

  private var tintColor: Color {
    switch status {
    case .unknown:        return .gray
    case .disabled:       return Color.gray.opacity(0.5)
    case .running:        return .green
    case .stopped:        return .red
    case .notResponding:  return .orange
    }
  }
}

#Preview {
  VStack(alignment: .leading, spacing: 8) {
    ServerStatusPill(status: .unknown)
    ServerStatusPill(status: .disabled)
    ServerStatusPill(
      status: .running(URL(string: "http://127.0.0.1:8089")!))
    ServerStatusPill(status: .stopped)
    ServerStatusPill(status: .notResponding)
  }
  .padding()
}
