#if os(macOS)
import GalleyCoreKit
import SwiftUI

/// Content for the singleton Help window scene. Reads the URL to
/// display from `WindowDispatcher.currentHelpURL` and mounts
/// `DocumentView` in `.help` mode so the window bypasses the routing
/// registry, tab-merging, and recents recording.
struct HelpWindowView: View {
  @Environment(WindowDispatcher.self) private var dispatcher
  @Environment(AppBoot.self) private var boot

  var body: some View {
    @Bindable var dispatcher = dispatcher
    if let urlBinding = Binding($dispatcher.currentHelpURL),
       let appModel = boot.model
    {
      DocumentView(
        fileURL: urlBinding,
        appModel: appModel,
        kind: .help)
    } else {
      // Boot still resolving, or window was brought forward before
      // any help URL was set. Render nothing; the help window only
      // opens via `openWindow(id: "help")` calls that pre-set the
      // URL, so this branch is transient.
      Color.clear
    }
  }
}
#endif
