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
  @Binding var fileURL: URL?
  @Environment(AppBoot.self) private var boot

  var body: some View {
    Group {
      if let urlBinding = Binding($fileURL),
         let appModel = boot.model
      {
        DocumentView(fileURL: urlBinding, appModel: appModel)
      } else {
        // Boot in flight (processor discovery) or — defensively —
        // a stray nil URL from SwiftUI. Keep the window hidden so
        // the user never sees a pre-render flash.
        Color.clear.background(BootWindowHider())
      }
    }
    // Wire the launch-time dispatcher install + URL receipt. We
    // attach this to every doc window because macOS 26 does not
    // reliably mount the `Window("welcome")` scene when state
    // restoration produces doc windows; whichever scene mounts
    // wires the app up. Idempotent — see modifier docs.
    .bootstrapDispatch()
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
