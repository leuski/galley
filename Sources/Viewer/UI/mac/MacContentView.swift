#if os(macOS)
import AppKit
import GalleyCoreKit
import SwiftUI

/// Thin parent for a document window's root scene. Splits the
/// optional `Binding<URL?>` SwiftUI hands us from `WindowGroup<URL>`
/// from the actual rendering surface: when both the URL and `AppBoot`
/// are ready, mount `DocumentView` with non-optional inputs;
/// otherwise show an invisible placeholder while the boot resolves
/// (or as a soft-fail if SwiftUI ever delivers a nil URL — the
/// `WindowGroup<URL>` API is typed `URL?` even though every spawn
/// path in this app supplies a real URL).
struct MacContentView: View {
  @Binding var target: DocumentTarget?
  @Environment(AppBoot.self) private var boot
  @Environment(RecentDocumentsModel.self) private var recents
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    Group {
      if let target = Binding($target),
         let appModel = boot.model
      {
        // A live document window owns its own URL receipt + dedup —
        // see `DocumentView`.
        DocumentView(target: target, appModel: appModel)
      } else {
        // The empty bootstrap window: SwiftUI materializes one
        // `url == nil` `WindowGroup` member at cold launch (WindowProbe
        // FINDINGS §3). It captures `openWindow`, hosts URL receipt,
        // and runs the FTUE Open panel — staying invisible until it
        // adopts a document. Replaces the old `Window("welcome")`.
        Color.clear
          .background(BootWindowHider())
          .handlesInboundURLs { self.target = $0 }
          .task(id: boot.model != nil) {
            guard boot.model != nil else { return }
            await runFTUEIfNeeded()
          }
      }
    }
    // Capture `openWindow` for the non-view callers (tab-bar "+",
    // menu / recents opens). Idempotent across windows.
    .task {
      NewTabAction.handler = { _ in
        Task { @MainActor in
          let picks = await recents.runOpenPanel()
          for url in picks {
            // Born-as-tab into the key window's group (the "+" source is
            // key). No host argument needed — see `ViewerOpenModel`.
            NSWindow.allowsAutomaticWindowTabbing = true
            openWindow(id: MacDocumentScene.id, value: DocumentTarget(url: url))
          }
        }
      }
    }
  }

  /// First-run / empty-launch Open panel. State restoration brings
  /// back `WindowGroup<URL>` windows during launch, so wait briefly
  /// and bow out if a document window already exists (or one bound
  /// while we waited). Adopts the first pick in place; opens the rest
  /// as separate windows.
  private func runFTUEIfNeeded() async {
    try? await Task.sleep(for: .milliseconds(250))
    if Task.isCancelled || target != nil { return }

    if hasOtherVisibleWindow() {
      dismissWindow()
      return
    }

    let picks = await recents.runOpenPanel()
    if Task.isCancelled || target != nil { return }

    guard let first = picks.first else {
      dismissWindow()
      return
    }
    target = DocumentTarget(url: first)

    for url in picks.dropFirst() {
      openWindow(id: MacDocumentScene.id, value: DocumentTarget(url: url))
    }
  }

  /// True when a visible, focusable window other than this invisible
  /// bootstrap window exists (e.g. state restoration produced one).
  private func hasOtherVisibleWindow() -> Bool {
    NSApp.windows.contains { window in
      window.isVisible && window.alphaValue > 0.01 && window.canBecomeKey
    }
  }
}

/// Pins `window.alphaValue = 0` while the `AppModel` is still booting
/// or the `WindowGroup` URL has yet to resolve. Once `ContentView`
/// swaps to `DocumentView`, the regular `WindowAccessor` takes over
/// alpha control based on `documentURL`.
private struct BootWindowHider: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { Hider() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class Hider: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.alphaValue = 0
    }
  }
}
#endif
