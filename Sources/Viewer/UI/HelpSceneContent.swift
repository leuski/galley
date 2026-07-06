import GalleyCoreKit
import SwiftUI

/// Content for the singleton Help window scene. The scene claims the
/// `galley-help://` scheme via `handlesExternalEvents` (see
/// `MacViewerApp`), so a `galley-help://<bundle-path>` URL fired at the
/// app opens this window and delivers the URL here through `.onOpenURL`.
/// We parse it back to the bundled file and mount `DocumentView` in
/// `.help` mode (which bypasses dedup, recents, and the tab "+").
struct HelpSceneContent: View {
  @State private var model: DocumentModel?
  @Environment(AppModel.self) var appModel

  var body: some View {
    Group {
      if let model {
        DocumentView(model: model)
      } else {
        // Window brought forward before any help URL arrived.
        // Transient — the scene only opens via a `galley-help://` URL
        // that builds the model on arrival.
        Color.clear
      }
    }
    .onOpenURL { url in
      guard let help = OpenHelpActivity(from: url) else { return }
      model = DocumentModel.help(appModel: appModel, url: help.documentURL)
    }
  }
}
