#if os(macOS)
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

/// Fires `onWillDraw` immediately before each AppKit draw pass of the
/// host view — the earliest hook available before the first pixel of
/// the surrounding SwiftUI hierarchy hits the screen. Caller guards
/// against re-firing (e.g. with a one-shot model flag).
///
/// `.onAppear` / `.task` fire *after* the first render, so they can't
/// configure SwiftUI state that needs to be correct on the initial
/// paint without a visible flash. `viewWillDraw` runs inside AppKit's
/// display cycle on the same runloop turn that's about to paint, so
/// any state mutation here applies before anything is composited —
/// works on a new tab the same way it works on a fresh window, with
/// no `alphaValue` reveal needed.
struct BeforeFirstDrawAccessor: NSViewRepresentable {
  let onWillDraw: () -> Void

  func makeNSView(context: Context) -> NSView {
    PreDrawView(onWillDraw: onWillDraw)
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class PreDrawView: NSView {
  let onWillDraw: () -> Void

  init(onWillDraw: @escaping () -> Void) {
    self.onWillDraw = onWillDraw
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewWillDraw() {
    super.viewWillDraw()
    onWillDraw()
  }
}
#endif
