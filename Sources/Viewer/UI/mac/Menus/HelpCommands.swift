#if os(macOS)
import GalleyCoreKit
import SwiftUI

/// Help menu — opens bundled help docs in the singleton Help window by
/// firing a `galley-help://<bundle-path>` URL at the app; the Help scene
/// claims that scheme via `handlesExternalEvents` and renders the doc
/// with the user's current template like any other markdown file.
///
/// Doc sources may contain `{{GALLEY_APP_FINDER_URL}}` for the running
/// app's bundle location, expressed as a `finder://` URL so clicked
/// links reveal in Finder rather than launch — `LinkBridge` intercepts
/// the scheme. Home-rooted paths (`~/…`) are handled by `LinkBridge`
/// itself and need no substitution.
struct HelpCommands: Commands {
  var body: some Commands {
    CommandGroup(replacing: .help) {
      Action.howToMakeTemplate().menuItem()
    }
  }
}
#endif
