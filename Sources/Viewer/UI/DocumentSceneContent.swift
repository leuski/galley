//
//  DocumentSceneContent.swift
//  Galley
//
//  Shared (macOS + visionOS) root content for one document window.
//  Replaces MacContentView + VisionContentView. The window's identity
//  is its `DocumentSceneID`; the document it shows is resolved from
//  `DocumentStore` by that id (restored window) or arrives via
//  `onOpenURL` (remote-opened window). A window with neither shows the
//  welcome surface. See docs/rebuild-document-windowing.md.
//

import GalleyCoreKit
import SwiftUI

struct DocumentSceneContent: View {
  let sceneID: DocumentSceneID

  /// `nil` == welcome (no document). Built synchronously in `init` from
  /// the store so a restored window shows its document on the first
  /// frame — no async launchTask, no reveal gate.
  @State private var model: DocumentModel?
  /// this stores the last open target
  @State private var lastTarget: DocumentTarget?

  @Environment(\.openWindow) private var openWindow

  init(sceneID: DocumentSceneID) {
    self.sceneID = sceneID
    _model = State(
      initialValue: WindowModelManager.shared.forScene(id: sceneID))
  }

  var body: some View {
    documentOrWelcome
      // Window selection IS the open-behavior decision (directive 8):
      // SwiftUI routes the URL — we don't re-dispatch. See
      // `preferringTokens` / `allowingTokens`.
      .handlesExternalEvents(
        preferring: preferringTokens,
        allowing: allowingTokens)
      .onOpenURL(perform: handleOpenURL)
    // state-restored scene ID arrives late on macOS
      .onChange(of: sceneID) { _, new in
        guard let newModel = WindowModelManager.shared.forScene(id: new)
        else {
          if let model {
            WindowModelManager.shared.relocate(model, to: new)
          }
          return
        }

        guard newModel !== model else { return }
        self.model = newModel
        // we are restoring the window. If we have a model assigned, it's
        // the wrong model. Evict it and ask the framework to re-open
        // the document.
        if let lastTarget {
          self.lastTarget = nil
          GalleyViewerRequestActivity(target: lastTarget).open()
        }
      }
      .windowTransparency(model == nil ? 0 : 1)
  }

  /// Tokens this window *prefers* — a re-open of the doc it already shows
  /// routes back here (dedup). A blank window prefers the bare scheme so
  /// a freshly-spawned window attracts the document fired at it.
  private var preferringTokens: Set<String> {
    model?.documentURL.galleyPreferringTokens
      ?? [GalleyViewerRequestActivity.schemeExternalToken]
  }

  /// Tokens this window *accepts*, which is what makes SwiftUI choose
  /// where a URL lands — i.e. open-behavior expressed declaratively:
  ///   - empty window → anything (it's the adopt/bootstrap target);
  ///   - `.replaceCurrent` → anything (a foreign doc replaces in place);
  ///   - `.newWindow` / `.newTab` → only its *own* doc, so same-doc
  ///     re-opens still dedup here while a foreign doc is declined and
  ///     SwiftUI spawns a fresh window (born-as-tab per
  ///     `syncWindowTabbing`).
  private var allowingTokens: Set<String> {
    guard let model else { return DocumentScene.events }
    switch Defaults.shared.openBehavior {
    case .replaceCurrent:
      return DocumentScene.events
    case .newWindow, .newTab:
      return model.documentURL.galleyPreferringTokens
    }
  }

  @ViewBuilder
  private var documentOrWelcome: some View {
    if let model {
      DocumentView(model: model)
#if os(macOS)
        .navigationDocument(model.documentURL)
#endif
    } else {
      WelcomeView()
#if os(macOS)
        .task {
          Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard model == nil else { return }
            AppModel.shared.isOpenFilePresented = true
          }
        }
#endif
    }
  }

  /// Apply an inbound document URL SwiftUI routed to this window.
  private func handleOpenURL(_ url: URL) {
    guard let target = GalleyViewerRequestActivity(from: url)?.target
    else { return }

    AppModel.shared.recents.record(target.documentURL)

    guard let live = model else {
      lastTarget = target
      // Empty window adopts the document in place (welcome → document).
      model = WindowModelManager.shared.open(target: target, id: sceneID)
      return
    }
    // Same document → just scroll + focus (dedup).
    if live.documentURL.standardizedFileURL
      == target.documentURL.standardizedFileURL
    {
      if let scroll = target.scroll {
        Task { await live.scroll(to: scroll) }
      }
      focusWindow()
      return
    }
    // A live window only receives a *foreign* document when its
    // `allowingTokens` accepted it — i.e. under `.replaceCurrent`. Under
    // new-window / new-tab the window declines foreign docs, so SwiftUI
    // spawns a fresh window instead and this line is never reached for
    // them. So: replace in place.
    Task { await live.bind(to: target) }
  }

  private func focusWindow() {
#if os(macOS)
    NSApp.activate(ignoringOtherApps: true)
#endif
  }
}
