import GalleyCoreKit
import SwiftUI
import WebKit

/// Document-window content view for visionOS. Owns a `DocumentModel`
/// for the bound URL and presents its `WebPage` via SwiftUI's
/// `WebView`. The macOS Viewer's `ContentView` / `DocumentView` carry
/// a lot of platform-specific chrome (sidebar, find bar, status bar,
/// toolbar, scene-storage hydration via `BindPlan`) — this is the
/// minimum-viable visionOS counterpart.
///
/// State restoration is `@SceneStorage`-driven on macOS through
/// `BindPlan.decide(...)`. For visionOS v1 we skip restoration and
/// always do an initial bind to `fileURL`. Add `BindPlan` integration
/// once the visionOS scene model is stable enough to warrant it.
struct ContentView: View {
  let fileURL: URL?
  let boot: AppBoot

  var body: some View {
    if let model = boot.model, let fileURL {
      DocumentScreen(fileURL: fileURL, appModel: model)
    } else {
      // Either boot hasn't completed (the async processor discovery
      // is still in flight) or the WindowGroup binding has no URL
      // yet (e.g. the user launched the app directly without opening
      // a document). Both are transient — replace this with an
      // intentional welcome surface when the visionOS design lands.
      ProgressView()
    }
  }
}

/// Inner view that's only mounted once both `AppModel` and a real
/// `fileURL` exist. Constructs the `DocumentModel` once via
/// `@State`, then drives `bind(to:)` from `.task(id:)` so re-binding
/// the WindowGroup to a different URL re-uses the same model.
private struct DocumentScreen: View {
  let fileURL: URL
  let appModel: AppModel

  @State private var model: DocumentModel?

  var body: some View {
    Group {
      if let model {
        WebView(model.page)
          .overlay {
            if !model.isPageRendered {
              model.pageBackgroundColor.allowsHitTesting(false)
            }
          }
      } else {
        ProgressView()
      }
    }
    .task(id: fileURL) {
      let resolved = ensureModel()
      await resolved.bind(to: fileURL)
    }
  }

  /// Lazy-create the per-window `DocumentModel`. `@State` means a
  /// single instance survives view-identity-preserving re-renders;
  /// the first `.task(id: fileURL)` constructs it, every subsequent
  /// fire re-binds the existing model.
  @MainActor
  private func ensureModel() -> DocumentModel {
    if let model { return model }
    let perFile = Defaults.shared.perFileStateStore[fileURL]
    let created = DocumentModel(
      initialURL: fileURL,
      appModel: appModel,
      templatePersistent: perFile.templatePersistent,
      processorPersistent: perFile.rendererPersistent,
      kind: .document)
    model = created
    return created
  }
}
