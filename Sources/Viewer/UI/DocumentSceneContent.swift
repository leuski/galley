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
import OSLog

private let log = Logger(
  subsystem: bundleIdentifier, category: "DocumentSceneContent")

struct DocumentSceneContent: View {
  let sceneID: DocumentSceneID

  /// `nil` == welcome (no document). Built synchronously in `init` from
  /// the store so a restored window shows its document on the first
  /// frame — no async launchTask, no reveal gate.
  @State private var model: WindowModel?

  @Environment(AppModel.self) var appModel
  @Environment(\.openWindow) private var openWindow

  init(sceneID: DocumentSceneID, appModel: AppModel) {
    self.sceneID = sceneID
    _model = State(
      initialValue: appModel.windowModelManager.forScene(id: sceneID))
  }

  var body: some View {
    documentOrWelcome
    // One window-level routing decision — SwiftUI picks the window, we
    // don't re-dispatch. Tokens come from the active tab (Dot-style);
    // a welcome window falls back to the bare scheme so a freshly
    // spawned window attracts the document fired at it.
      .handlesExternalEvents(
        preferring: preferringTokens,
        allowing: allowingTokens)
      .onOpenURL(perform: handleOpenURL)
    // state-restored scene ID arrives late on macOS
      .onChange(of: sceneID) { old, new in
        log.notice(
          "scene id \(old, privacy: .public) -> \(new, privacy: .public)")
        guard let newModel = appModel.windowModelManager.forScene(id: new)
        else {
          if let model {
            log.notice(
              "relocating existing model")
            appModel.windowModelManager.relocate(model, to: new)
          }
          return
        }

        guard newModel !== model else { return }
        let oldRequests = model?.tabs
          .compactMap { tab in tab.lastRequest } ?? []
        self.model = newModel
        // we are restoring the window. If we have a model assigned, it's
        // the wrong model. Evict it and ask the framework to re-open
        // the document.
        log.notice(
          "need to reopen requests \(oldRequests, privacy: .public)")
        oldRequests.forEach { request in
          GalleyViewerRequestActivity(target: request).open()
        }
      }
      .windowTransparency(model == nil ? 0 : 1)
  }

  @ViewBuilder
  private var documentOrWelcome: some View {
    if let model {
      ZStack {
        ForEach(model.tabs) { tab in
          DocumentView(model: tab)
          // Keep every tab mounted and switch by visibility only, so a
          // tab switch never tears down / reloads a WebView (Dot's
          // VisionBrowserContentView pattern). On macOS there is always
          // exactly one tab, so this is a no-op there.
            .opacity(tab === model.activeTab ? 1 : 0)
            .allowsHitTesting(tab === model.activeTab)
            .accessibilityHidden(tab !== model.activeTab)
#if os(macOS)
            .navigationDocument(tab.documentURL)
#endif
        }
      }
    } else {
      WelcomeView()
#if os(macOS)
        .task {
          Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard model == nil else { return }
            appModel.isOpenFilePresented = true
          }
        }
#endif
    }
  }

  /// Dedup tokens for *every* open tab — a re-open of any tab's document
  /// (not just the active one) routes back to this window, where
  /// `handleOpenURL` activates the matching tab.
  private func openTabTokens(_ model: WindowModel) -> Set<String> {
    model.tabs.reduce(into: Set<String>()) { tokens, tab in
      tokens.formUnion(tab.documentURL.galleyPreferringTokens)
    }
  }

  /// Tokens this window *prefers* — a re-open of any open tab's doc routes
  /// back here (dedup). A welcome window prefers the bare scheme so a
  /// freshly spawned window attracts the document fired at it.
  private var preferringTokens: Set<String> {
    guard let model else {
      return [GalleyViewerRequestActivity.schemeExternalToken]
    }
    return openTabTokens(model)
  }

  /// Tokens this window *accepts*, which is what makes SwiftUI choose
  /// where a URL lands — open-behavior expressed declaratively. In every
  /// case the union of open-tab tokens is accepted so a re-open of any
  /// tab dedups here; foreign docs are additionally accepted only when
  /// the behavior keeps them in this window:
  ///   - welcome window → anything (the adopt/bootstrap target);
  ///   - `.replaceCurrent` → anything (a foreign doc replaces in place);
  ///   - `.newTab` → **visionOS** anything (adopt as an in-window tab);
  ///     **macOS** dedup-only, so a foreign doc is declined and SwiftUI
  ///     spawns a fresh window born-as-tab via the OS tabbing group;
  ///   - `.newWindow` → dedup-only, so a foreign doc spawns a new window.
  private var allowingTokens: Set<String> {
    guard let model else { return DocumentScene.events }
    switch Defaults.shared.openBehavior {
    case .replaceCurrent:
      return DocumentScene.events
    case .newTab:
#if os(visionOS)
      return DocumentScene.events
#else
      return openTabTokens(model)
#endif
    case .newWindow:
      return openTabTokens(model)
    }
  }

  /// Apply an inbound document URL SwiftUI routed to this window.
  private func handleOpenURL(_ url: URL) {
    guard let target = GalleyViewerRequestActivity(from: url)?.target
    else { return }
    appModel.recents.record(target.documentURL)

    // Welcome window adopts the document in place (welcome → document).
    guard let model else {
      log.notice("""
        no existing model. open \(target, privacy: .public) in \
        \(sceneID, privacy: .public)
        """)
      model = appModel.windowModelManager.open(target: target, id: sceneID)
      return
    }

    // Already open in some tab of this window → activate that tab, scroll,
    // focus (dedup across *all* tabs, not just the active one).
    if let existing = model.tabs.first(where: {
      $0.documentURL.standardizedFileURL
      == target.documentURL.standardizedFileURL
    }) {
      log.notice("""
        activate existing model: \(target, privacy: .public) in \
        \(sceneID, privacy: .public)
        """)
      model.activate(tab: existing)
      if let scroll = target.scroll {
        Task { await existing.scroll(to: scroll) }
      }
      focusWindow()
      return
    }

    // A foreign document reached this window because `allowingTokens`
    // accepted it. On visionOS under `.newTab` that means "add an
    // in-window tab"; every other accept path (`.replaceCurrent`, and
    // the macOS OS-tab route — which declines foreign docs so a new
    // window spawns instead and never lands here) replaces the active
    // tab in place.
#if os(visionOS)
    if case .newTab = Defaults.shared.openBehavior {
      model.addTab(appModel.windowModelManager.makeTab(for: target))
      return
    }
#endif
    if Defaults.shared.openBehavior == .replaceCurrent {
      Task { await model.activeTab.bind(to: target) }
      return
    }

    // now we are in the territory that should not have happened --
    // Swiftui fired multiple openurls into the same scene.

    // find an empty tab
    if let existing = model.tabs.first(where: { !$0.hasDocument }) {
      log.notice("""
        filling out empty tab: \(target, privacy: .public) in \
        \(sceneID, privacy: .public)
        """)
      Task { await existing.bind(to: target) }
      return
    }

    log.notice("""
        re-issue open request: \(target, privacy: .public) from \
        \(sceneID, privacy: .public)
        """)
    // re-open it again
    GalleyViewerRequestActivity(target: target).open()
  }

  private func focusWindow() {
#if os(macOS)
    NSApp.activate(ignoringOtherApps: true)
#endif
  }
}
