#if os(macOS)
import AppKit
import GalleyCoreKit
import SwiftUI
import WebKit
import KosmosAppKit

/// The viewer surface for a single document window. Mounted by
/// `DocumentSceneContent` once the window has a `DocumentModel` (built from a
/// restored snapshot or an inbound URL) — so this view always has a
/// concrete document and a hydrated `AppModel` to work with.
struct DocumentView: View {
  /// The window's document model — built and cached by `DocumentSceneContent`
  /// (`DocumentModel.forScene` / `.open`), already populated and
  /// rendering. The view never constructs it, never owns persistence,
  /// and never observes it to mutate another model.
  @Bindable var model: DocumentModel

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hostWindow: NSWindow?

  var body: some View {
    splitView
      .modifier(NoticeModifier(model: model))
      .modifier(WindowAttachedModifier(
          hostWindow: $hostWindow,
          installNewTabAction: model.kind == .document))
      .modifier(RenameModifier(model: model))
      .modifier(ExportModifier(model: model))
      .navigationDocument(model.documentURL, when: model.kind == .document)
      .navigationSubtitle(model.page.title)
    // Flip the view's color scheme so AppKit-rendered chrome text
    // (window title, toolbar labels) inverts when the page bg is
    // dark — otherwise the system black title disappears against a
    // black body. While re-rendering after a template change,
    // pin the scheme to the user's system pref instead so WebKit's
    // `prefers-color-scheme` media queries on the new template pick
    // the user's preferred variant — not whichever variant was
    // current under the previous template's bg-luminance scheme.
      .preferredColorScheme(model.resolvedColorScheme)
  }

  /// The window's main split: TOC sidebar (column-visibility bound to
  /// `model.showsTOC`) and the rendered preview. Hoisted to a
  /// `NavigationSplitView` so AppKit's tab bar spans only the detail
  /// column — a sidebar nested inside an `HStack` would render with
  /// the tab bar bisecting it.
  @ViewBuilder
  private var splitView: some View {
    NavigationSplitView(
      columnVisibility: model.tocColumnVisibility(reduceMotion: reduceMotion))
    {
      TOCSidebar(model: model)
        .navigationSplitViewColumnWidth(
          min: 180, ideal: 220, max: 320)
      // SwiftUI auto-injects a sidebar toggle item into NavigationSplitView's
      // toolbar under the identifier `com.apple.SwiftUI.navigationSplitView.
      // toggleSidebar`. Combined with `.toolbar(id: "viewer.main")`'s
      // customization persistence, that identifier ends up both auto-injected
      // and restored from defaults on the next launch — NSToolbar then
      // throws because the same identifier appears twice. Suppress the
      // auto-injected one and provide our own non-customizable toggle in
      // `navigationToolbarItems` instead.
    } detail: {
      DocumentMainContent(model: model)
        // Collapse the TOC sidebar just before the very first paint
        // of this split view if the user wanted it closed. `showsTOC`
        // starts `true` so NavigationSplitView is born with a sidebar
        // and AppKit wires the column as `.behavior = .sidebar` (so
        // it extends up under the tab bar). `savedShowsTOC` holds the
        // user's actual preference; we apply it inside `viewWillDraw`
        // — same runloop turn as the first paint, so the visible
        // state never includes the open-sidebar frame. One-shot via
        // the `savedShowsTOC` flag flip.
        .willPresent {
          if !model.savedShowsTOC {
            model.savedShowsTOC = true
            model.showsTOC = false
          }
        }
    }
    .navigationSplitViewStyle(.balanced)
    // Paint the page's own background color into the window's
    // container background so the translucent toolbar / sidebar
    // chrome samples it as the surface behind their glass material.
    // `.containerBackground(_:for: .window)` — unlike `.background`
    // — paints behind the entire window container, which is what
    // chrome reads through. `nil` while loading or when the page
    // declared no opaque bg; we then paint nothing and fall back to
    // the system default (glass over wallpaper).
    .toolbarBackgroundVisibility(
      Defaults.shared.tintWindowWithPageBackground ? .hidden : .visible,
      for: .windowToolbar)
    // `model.pageBackgroundColor` already resolves through the
    // template state → last-seen → system-bg fallback chain, so
    // it's always a real color; no second `??` needed here.
    .background(
      Defaults.shared.tintWindowWithPageBackground
      ? model.pageBackgroundColor : .userSystemWindowBackground)
    .containerBackground(
      Defaults.shared.tintWindowWithPageBackground
      ? model.pageBackgroundColor : .userSystemWindowBackground, for: .window)
  }
}

private extension View {
  /// Gates `.navigationDocument(_:)` on a condition. The Help window's
  /// `DocumentView` opts out so AppKit doesn't attach a proxy icon or
  /// the title-bar document menu (rename / move / version) to what is
  /// really a read-only resource inside the app bundle.
  @ViewBuilder
  func navigationDocument(_ url: URL, when condition: Bool) -> some View {
    if condition { navigationDocument(url) } else { self }
  }
}

/// Bottom-overlay banner for `DocumentModel.notice`. Owns no state —
/// the close button calls `onDismiss` so the model can cancel any
/// pending auto-clear timer alongside clearing the notice.
private struct NoticeBanner: View {
  let message: String
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Text(message)
        .textSelection(.enabled)
      Button(action: onDismiss) {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss")
    }
    .padding(8)
    .background(.regularMaterial, in: .rect(cornerRadius: 8))
  }
}

struct NoticeModifier: ViewModifier {
  @Bindable var model: DocumentModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        if let notice = model.notice {
          NoticeBanner(message: notice.message) {
            model.dismissNotice()
          }
          .padding()
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(reduceMotion ? nil : .default, value: model.notice)
  }
}


#endif
