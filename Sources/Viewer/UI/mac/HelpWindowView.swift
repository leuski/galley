#if os(macOS)
import GalleyCoreKit
import SwiftUI

/// Content for the singleton Help window scene. The scene claims the
/// `galley-help://` scheme via `handlesExternalEvents` (see
/// `MacViewerApp`), so a `galley-help://<bundle-path>` URL fired at the
/// app opens this window and delivers the URL here through `.onOpenURL`.
/// We parse it back to the bundled file and mount `DocumentView` in
/// `.help` mode (which bypasses dedup, recents, and the tab "+").
struct HelpWindowView: View {
  @State private var target: DocumentTarget?

  var body: some View {
    Group {
      if let targetBinding = Binding($target),
         let appModel = AppBoot.shared.model
      {
        DocumentView(
          target: targetBinding,
          appModel: appModel,
          kind: .help)
      } else {
        // Window brought forward before any help URL arrived, or boot
        // still resolving. Transient — the scene only opens via a
        // `galley-help://` URL that sets `helpURL` on arrival.
        Color.clear
      }
    }
    .onOpenURL { url in
      guard let help = OpenHelpActivity(from: url) else {
        return
      }
      target = DocumentTarget(url: help.documentURL)
    }
  }
}
#endif
