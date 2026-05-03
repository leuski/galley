import AppKit
import SwiftUI

/// Resolves the host `NSWindow` so a SwiftUI view can drive AppKit-only
/// properties on it (alpha, close, hidden-window settings, tab merge).
///
/// Reports through `viewDidMoveToWindow` so the resolution is
/// synchronous with AppKit attachment — async dispatch raced the
/// `.task` that drives the launch picker, leaving `hostWindow` nil
/// when it was needed.
struct WindowAccessor: NSViewRepresentable {
  let onAttach: (NSWindow?) -> Void
  let onDetach: (NSWindow?) -> Void

  init(
    onAttach: @escaping (NSWindow?) -> Void,
    onDetach: @escaping (NSWindow?) -> Void = { _ in }
  ) {
    self.onAttach = onAttach
    self.onDetach = onDetach
  }

  func makeNSView(context: Context) -> NSView {
    ResolvingView(onAttach: onAttach, onDetach: onDetach)
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ResolvingView: NSView {
  let onAttach: (NSWindow?) -> Void
  let onDetach: (NSWindow?) -> Void

  init(
    onAttach: @escaping (NSWindow?) -> Void,
    onDetach: @escaping (NSWindow?) -> Void
  ) {
    self.onAttach = onAttach
    self.onDetach = onDetach
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil, let current = window {
      onDetach(current)
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onAttach(window)
  }
}
