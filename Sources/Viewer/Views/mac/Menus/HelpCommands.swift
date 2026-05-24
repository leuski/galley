#if os(macOS)
import Foundation
import GalleyCoreKit
import SwiftUI

/// Help menu — opens bundled help docs as ordinary documents through
/// the same dispatcher that handles Finder-opens. The doc is read-only
/// inside the app bundle, but it renders with the user's currently
/// selected template like any other markdown file, so it Just Works.
///
/// Doc sources may contain `{{GALLEY_APP_FINDER_URL}}` for the running
/// app's bundle location, expressed as a `finder://` URL so clicked
/// links reveal in Finder rather than launch — `LinkBridge` intercepts
/// the scheme. Home-rooted paths (`~/…`) are handled by `LinkBridge`
/// itself and need no substitution.
struct HelpCommands: Commands {
  let dispatcher: WindowDispatcher

  var body: some Commands {
    CommandGroup(replacing: .help) {
      let url = Bundle.main.url(
        forResource: "template-authoring",
        withExtension: "md")
      Button("How to Make a Template") {
        guard let url else { return }
        dispatcher.handleOpenURLs([url])
      }
      .disabled(url == nil)
      .accessibilityIdentifier(ViewerA11yID.HelpMenu.templateAuthoring)
    }
  }
}
#endif
