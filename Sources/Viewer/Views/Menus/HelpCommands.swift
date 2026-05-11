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
      Button("How to Make a Template") {
        guard let url = stagedTemplateAuthoringDoc() else { return }
        dispatcher.handleOpenURLs([url])
      }
      .accessibilityIdentifier(ViewerA11yID.HelpMenu.templateAuthoring)
    }
  }

  /// Loads the bundled template-authoring doc, substitutes the
  /// install-specific path placeholders, writes the result to a
  /// well-named file in the temp directory, and returns its URL.
  /// Returns nil if the bundle is missing the resource or the temp
  /// write fails — silent failure is acceptable for a help action.
  private func stagedTemplateAuthoringDoc() -> URL? {
    guard
      let source = Bundle.main.url(
        forResource: "template-authoring",
        withExtension: "md"),
      let raw = try? String(contentsOf: source, encoding: .utf8)
    else { return nil }

    // bundleURL has scheme `file://` and a trailing slash for
    // directory URLs. Swap to `finder://` (LinkBridge intercepts it
    // to reveal rather than open) and strip the trailing slash so
    // the doc's literal `/Contents/...` concatenates cleanly.
    var appURL = Bundle.main.bundleURL.absoluteString
    if appURL.hasPrefix("file://") {
      appURL = "finder://" + appURL.dropFirst("file://".count)
    }
    if appURL.hasSuffix("/") { appURL.removeLast() }

    let rendered = raw.replacingOccurrences(
      of: "{{GALLEY_APP_FINDER_URL}}",
      with: appURL)

    let staged = FileManager.default.temporaryDirectory
      .appendingPathComponent("How to Make a Template.md")
    do {
      try rendered.write(to: staged, atomically: true, encoding: .utf8)
    } catch {
      return nil
    }
    return staged
  }
}
