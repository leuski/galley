import SwiftUI
import GalleyCoreKit
import ALFoundation

/// Compact status indicator next to the "Run server" toggle. Renders
/// `ServerStatus` as a colored dot + label pair so the user can tell
/// at a glance whether the server is actually reachable.
struct ServerStatusPill: View {
  let status: ServerStatus

  var body: some View {
    HStack(spacing: 6) {
      labelText
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      Circle()
        .fill(tintColor)
        .frame(width: 8, height: 8)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Server status: \(labelText)")
  }

  /// Per-case localized label. Returning `Text` (rather than a
  /// `String`) keeps the strings in the catalog without forcing a
  /// boundary `String(localized:)` resolution. The visible body
  /// renders this directly; the accessibility label concatenates it
  /// with a "Server status: " prefix using `Text`'s `+` operator,
  /// which gives translators two separate strings to work with.
  private var labelText: Text {
    switch status {
    case .disabled:       return Text("Disabled")
    case .starting:       return Text("Starting…")
    case .running(let url):
      // `.grouping(.never)` defeats the locale-default thousands
      // separator; port numbers are identifiers, not quantities.
      return Text(
        "Running on :\(url.port ?? 0, format: .number.grouping(.never))")
    case .notResponding:  return Text("Not responding")
    }
  }

  private var tintColor: Color {
    switch status {
    case .disabled:       return Color.gray.opacity(0.5)
    case .starting:       return .yellow
    case .running:        return .green
    case .notResponding:  return .orange
    }
  }
}

#Preview {
  VStack(alignment: .leading, spacing: 8) {
    let url: URL = "http://127.0.0.1:8089"
    ServerStatusPill(status: .disabled)
    ServerStatusPill(status: .starting)
    ServerStatusPill(status: .running(url))
    ServerStatusPill(status: .notResponding)
  }
  .padding()
}
