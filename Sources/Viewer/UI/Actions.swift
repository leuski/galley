//
//  Actions.swift
//  Galley
//
//  Created by Anton Leuski on 4/30/26.
//

import GalleyCoreKit
import KosmosAppKit
import SwiftUI

// MARK: - DocumentModel factories

extension Action {

  /// Status-bar toggle. Flips the global `showsStatusBar` default,
  /// since the bar is a chrome preference rather than per-document
  /// state. Every open window observes the change through SwiftUI's
  /// `@ObservableDefaults` pipeline.
  static func toggleStatusBar() -> Action {
    Action(
      title: {
        Defaults.shared.showsStatusBar
        ? "Hide Status Bar"
        : "Show Status Bar"
      },
      image: "ruler",
      perform: { env in
        withAnimationAsNeeded(env.reduceMotion) {
          Defaults.shared.showsStatusBar.toggle()
        }
      },
      shortcut: .init("2", modifiers: [.command, .control]),
      accessibilityID: ViewerA11yID.ViewMenu.toggleStatusBar
    )
  }

  /// Sidebar / Table-of-Contents toggle. Single source of truth shared
  /// by the View menu (via `menuItem`) and the document toolbar (via
  /// `toolbarButton`). Title flips Show/Hide in the menu; the toolbar
  /// uses the static "Toggle…" label as its tooltip / accessibility
  /// label.
  static func toggleTOC(_ model: DocumentModel?) -> Action {
    Action(
      title: {
        (model?.showsTOC ?? false)
        ? "Hide Table of Contents"
        : "Show Table of Contents"
      },
      image: "sidebar.left",
      perform: { env in
        guard let model else { return }
        model.toggleTOC(reduceMotion: env.reduceMotion)
      },
      shortcut: .init("1", modifiers: [.command, .control]),
      accessibilityID: ViewerA11yID.ViewMenu.toggleTOC
    )
  }

  static func howToMakeTemplate() -> Action {
    let url = Bundle.main.url(
      forResource: "template-authoring",
      withExtension: "md")

    return Action(
      title: "How to Make a Template",
      image: "questionmark.circle",
      perform: { _ in
        guard let url else { return }
        OpenHelpActivity(documentURL: url).open()
      },
      isEnabled: { url != nil },
      accessibilityID: ViewerA11yID.HelpMenu.templateAuthoring
    )
  }

  static func settings() -> Action {
    Action(
      title: "Settings…",
      image: "gearshape",
      perform: { _ in
        OpenSettingsActivity().open()
      },
      shortcut: .init(",", modifiers: [.command]),
      accessibilityID: ViewerA11yID.ToolbarSettings.settings
    )
  }

  /// One Open-Recent entry. Re-resolves the URL through the recents
  /// model (a no-op passthrough on macOS, security-scoped bookmark
  /// resolution on visionOS) and fires it at the app like any other
  /// open. The filename is the menu title and is folded into the
  /// accessibility identifier so each row is individually addressable.
  static func openRecent(
    _ url: URL,
    recents: RecentDocumentsModel
  ) -> Action {
    Action(
      title: { "\(url.lastPathComponent)" },
      help: { "\(url.absoluteString)" },
      image: {
        if url.isFileURL {
#if os(macOS)
          Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
#else
          Image(systemName: "doc.text")
#endif
        } else {
          Image(systemName: "arrow.up.right.square")
        }
      }(),
      perform: { _ in
        guard let fresh = recents.resolveRecentURL(url) else { return }
        GalleyViewerRequestActivity(url: fresh).open()
      },
      accessibilityID:
        "\(ViewerA11yID.FileMenu.openRecentItem).\(url.lastPathComponent)"
    )
  }

  /// "Clear Menu" footer for the Open-Recent list. Disabled when the
  /// list is empty. Carries the `.destructive` role on visionOS to
  /// match the platform's destructive-affordance styling; macOS keeps
  /// the plain File-menu styling it has always used.
  static func clearRecents(_ recents: RecentDocumentsModel) -> Action {
#if os(visionOS)
    let role: ButtonRole? = .destructive
#else
    let role: ButtonRole? = nil
#endif
    return Action(
      title: "Clear Menu",
      image: "trash",
      role: role,
      perform: { _ in recents.clearAll() },
      isEnabled: { !recents.urls.isEmpty },
      accessibilityID: ViewerA11yID.FileMenu.openRecentClear
    )
  }
}

#if os(macOS)
extension Action {
  /// The window the File-menu close/print commands act on. Mirrors
  /// AppKit's own front-to-back precedence: main, then key, then the
  /// first visible window.
  private static var frontWindow: NSWindow? {
    NSApp.mainWindow ?? NSApp.keyWindow ?? visibleWindows.first
  }

  /// Visible windows, used by Close All. The Welcome bootstrap anchor
  /// sits at `alphaValue = 0` and reports not-visible, so it never
  /// shows up here.
  private static var visibleWindows: [NSWindow] {
    NSApp.windows.filter(\.isVisible)
  }

  static func close() -> Action {
    Action(
      title: "Close",
      image: "xmark",
      perform: { _ in frontWindow?.performClose(nil) },
      isEnabled: { frontWindow != nil },
      shortcut: .init("w", modifiers: .command),
      accessibilityID: ViewerA11yID.FileMenu.close
    )
  }

  static func closeAll() -> Action {
    Action(
      title: "Close All",
      image: "xmark.rectangle",
      perform: { _ in
        // Iterate over a snapshot; `performClose(_:)` mutates
        // `NSApp.windows` as the close animation completes.
        for window in visibleWindows {
          window.performClose(nil)
        }
      },
      isEnabled: { !visibleWindows.isEmpty },
      shortcut: .init("w", modifiers: [.command, .option]),
      accessibilityID: ViewerA11yID.FileMenu.closeAll
    )
  }

  static func rename(_ model: DocumentModel?) -> Action {
    Action(
      title: "Rename…",
      image: "pencil",
      perform: { _ in model?.requestRename() },
      isEnabled: {
        model?.isRegular == true && model?.documentURL.isFileURL == true
      },
      accessibilityID: ViewerA11yID.FileMenu.rename
    )
  }

  static func openInEditor(_ model: DocumentModel?) -> Action {
    Action(
      title: "Open in Editor",
      image: "arrow.up.forward.app",
      perform: { _ in
        guard let model else { return }
        Task { await model.openInEditor(line: nil) }
      },
      isEnabled: { model?.documentURL.isFileURL == true },
      shortcut: .init("e", modifiers: [.command, .option]),
      accessibilityID: ViewerA11yID.FileMenu.openInEditor
    )
  }

  static func exportPDF(_ model: DocumentModel?) -> Action {
    Action(
      title: "Export as PDF…",
      image: "arrow.up.document",
      perform: { _ in model?.requestExportPDF() },
      isEnabled: { model != nil },
      shortcut: .init("e", modifiers: [.command, .shift]),
      accessibilityID: ViewerA11yID.FileMenu.exportPDF
    )
  }

  static func pageSetup(_ model: DocumentModel?) -> Action {
    Action(
      title: "Page Setup…",
      image: "text.page",
      perform: { _ in model?.runPageSetup(on: NSApp.keyWindow) },
      isEnabled: { model != nil },
      shortcut: .init("p", modifiers: [.command, .shift]),
      accessibilityID: ViewerA11yID.FileMenu.pageSetup
    )
  }

  static func print(_ model: DocumentModel?) -> Action {
    Action(
      title: "Print…",
      image: "printer",
      perform: { _ in
        guard let model else { return }
        let window = NSApp.keyWindow
        Task { await model.runPrintPanel(on: window) }
      },
      isEnabled: { model != nil },
      shortcut: .init("p", modifiers: .command),
      accessibilityID: ViewerA11yID.FileMenu.print
    )
  }

  static func showOnVisionPro(_ model: DocumentModel?) -> Action
  {
    Action(
      title: { "Show on Vision Pro" },
      help: {
        AppModel.shared.kosmos.isAVPReachable
        ? "Open this document on the connected Vision Pro."
        : "No Vision Pro is currently paired with the bridge."
      },
      image: "visionpro",
      perform: { _ in
        model?.showOnVisionPro(kosmos: AppModel.shared.kosmos)
      },
      isEnabled: {
        AppModel.shared.kosmos.isAVPReachable
        && model?.documentURL.isFileURL == true
      },
      shortcut: .init("3", modifiers: [.command, .control]),
      accessibilityID: ViewerA11yID.WindowMenu.showOnVisionPro
    )
  }
}
#endif

extension Action {

  @ViewBuilder
  static func openRecentMenu() -> some View {
    @Bindable var recents = AppModel.shared.recents
    Menu("Open Recent", systemImage: "clock") {
      if !recents.urls.isEmpty {
        ForEach(recents.urls, id: \.self) { url in
          Action.openRecent(url, recents: recents).menuItem()
        }
        Divider()
      }
      Action.clearRecents(recents).menuItem()
    }
    .accessibilityIdentifier(ViewerA11yID.FileMenu.openRecentMenu)
  }

}

extension Action {
  static func open() -> Action {
    Action(
      title: "Open…",
      image: "arrow.up.forward",
      perform: { AppModel.shared.isOpenFilePresented = true },
      shortcut: .init("o", modifiers: [.command]),
      accessibilityID: ViewerA11yID.FileMenu.open
    )
  }
}

struct OpenFileModifier: ViewModifier {
  @Bindable var appModel = AppModel.shared

  func body(content: Content) -> some View {
    content
      .fileDialogCustomizationID("open-file")
      .fileImporter(
        isPresented: $appModel.isOpenFilePresented,
        allowedContentTypes: MarkdownFileTypes.allTypesAndPlainText,
        allowsMultipleSelection: false
      ) { result in
        guard case .success(let urls) = result, let url = urls.first
        else { return }
        _ = url.startAccessingSecurityScopedResource()
        GalleyViewerRequestActivity(url: url).open()
      }
  }
}
