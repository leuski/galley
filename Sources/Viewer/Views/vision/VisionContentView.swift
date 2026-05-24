#if !os(macOS)

import GalleyCoreKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ALFoundation

/// Document-window content view for visionOS. Boot-gated wrapper:
/// shows a progress spinner while async catalog discovery is in
/// flight, a welcome landing surface when the WindowGroup binding
/// has no URL yet, and `DocumentScreen` once both `AppModel` and a
/// `fileURL` are available.
struct VisionContentView: View {
  @Binding var fileURL: URL?
  let boot: AppBoot

  var body: some View {
    Group {
      if let model = boot.model {
        if let url = fileURL {
          DocumentScreen(
            fileURL: url,
            appModel: model,
            bindingFileURL: $fileURL)
          .navigationSplitViewStyle(.balanced)
        } else {
          WelcomeScreen(fileURL: $fileURL)
        }
      } else {
        ProgressView()
          .controlSize(.large)
      }
    }
  }
}

/// Landing surface shown when the WindowGroup binding has no URL.
/// Hosts a single "Open Document…" button that drives
/// `.fileImporter` — the visionOS-native way to pick a `.md` file
/// from Files.app. Picking a file rebinds the WindowGroup's URL
/// binding so the *current* window flips from welcome to document,
/// rather than spawning a second window.
private struct WelcomeScreen: View {
  @Binding var fileURL: URL?
  @Environment(RecentDocumentsModel.self) private var recents
  @State private var isFilePickerPresented = false

  var body: some View {
    VStack(spacing: 24) {
      Image(systemName: "doc.richtext")
        .font(.system(size: 64))
        .foregroundStyle(.secondary)
      Text("Galley")
        .font(.largeTitle.weight(.semibold))
      Text("Open a Markdown document to preview it.")
        .foregroundStyle(.secondary)
      Button {
        isFilePickerPresented = true
      } label: {
        Label("Open Document…", systemImage: "folder")
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
      }
      .buttonStyle(.borderedProminent)

      if !recents.urls.isEmpty {
        recentsList
      }
    }
    .frame(minWidth: 600, minHeight: 800)
    .padding(40)
    .fileImporter(
      isPresented: $isFilePickerPresented,
      allowedContentTypes: UTType.allMarkdownTypesAndPlainText,
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first
      else { return }
      // The picked URL is security-scoped. Start access here; the
      // model holds the access for the lifetime of the scene by
      // never releasing — visionOS file pickers grant the scope per
      // session.
      _ = url.startAccessingSecurityScopedResource()
      recents.record(url)
      // Rebind this window's URL slot. The parent view's `if let`
      // flips to `DocumentScreen` on the next layout pass — no
      // second window spawned.
      fileURL = url
    }
  }

  /// Compact "Recent" panel below the Open button. Re-resolving a
  /// bookmark here yields a fresh security-scoped URL; we bind that
  /// — not the stored one — into the window slot.
  @ViewBuilder
  private var recentsList: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Recent")
          .font(.headline)
        Spacer()
        Button("Clear", role: .destructive) {
          recents.clearAll()
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      ForEach(recents.urls.prefix(5), id: \.self) { url in
        Button {
          if let fresh = recents.openRecent(url) {
            fileURL = fresh
          }
        } label: {
          HStack {
            Image(systemName: "doc.text")
              .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(url.lastPathComponent)
                .font(.body)
              Text(url.parent.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer()
          }
          .padding(.vertical, 4)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
          Button("Remove from Recent", role: .destructive) {
            recents.remove(url)
          }
        }
      }
    }
    .padding(16)
    .frame(maxWidth: 480)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
  }
}

/// Inner view that's only mounted once both `AppModel` and a real
/// `fileURL` exist. Constructs the `DocumentModel` once via `@State`,
/// then drives `bind(to:)` from `.task(id:)` so re-binding the
/// WindowGroup to a different URL re-uses the same model.
private struct DocumentScreen: View {
  let fileURL: URL
  let appModel: AppModel

  @Binding var bindingFileURL: URL?
  @State private var model: DocumentModel?
  @State private var isFilePickerPresented = false
  @Environment(\.openURL) private var openURL
  @Environment(\.openWindow) private var openWindow
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(RecentDocumentsModel.self) private var recents
  @Environment(KosmosVisionService.self) private var kosmos

  var body: some View {
    Group {
      if let model {
        documentChrome(model: model)
      } else {
        ProgressView()
      }
    }
    .task(id: fileURL) {
      let resolved = ensureModel()
      recents.record(fileURL)
      await resolved.bind(to: fileURL)
    }
    // The "Open Document…" entry in the More menu drives this — the
    // visionOS-native file picker rebinds the current window's URL
    // slot instead of spawning a second window.
    .fileImporter(
      isPresented: $isFilePickerPresented,
      allowedContentTypes: UTType.allMarkdownTypesAndPlainText,
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first
      else { return }
      _ = url.startAccessingSecurityScopedResource()
      recents.record(url)
      bindingFileURL = url
    }
  }

  /// The visible WebView plus all per-window chrome: TOC sidebar,
  /// find bar, status bar, plus a bottom-ornament toolbar with
  /// navigation, view controls, template / color-scheme pickers,
  /// and a Settings entry point.
  @ViewBuilder
  private func documentChrome(model: DocumentModel) -> some View {
    HStack(spacing: 0) {
      if model.showsTOC {
        VStack(alignment: .leading) {
          TOCSidebar(model: model)
            .padding(.top, 16)
        }
        .frame(width: 340)
        .transition(.move(edge: .leading).combined(with: .opacity))
      }
      detailContent(model: model)
        .frame(minWidth: 700, minHeight: 900)
        .background(
          GeometryReader { proxy in
            Color.clear
              .onChange(of: proxy.size.width, initial: true) { _, width in
                model.liveDetailWidth = width
              }
          }
        )
        .frame(width: model.pinnedDetailWidth)
    }
    .focusedSceneValue(\.documentModel, model)
    // Tint the content area (sidebar + detail) with the page
    // background when the user opts in. `ContainerBackgroundPlacement`
    // values like `.window` and `.navigation` are unavailable on
    // visionOS — `.background(_:)` on the chrome HStack is the
    // visionOS-supported surface for this. The floating bottom
    // ornament is system-managed glass and stays clean; only the
    // underlying content surface picks up the tint.
    .background(
      Defaults.shared.tintWindowWithPageBackground
      ? model.pageBackgroundColor
      : Color.clear)
    // Drive WebKit's `prefers-color-scheme` from the user choice
    // (Light/Dark, global or per-document). Templates that respect
    // the media query swap their CSS variant and the
    // `BackgroundColorBridge` reports the new bg; the chrome tint
    // follows in one frame.
    .preferredColorScheme(model.resolvedColorScheme)
    .modifier(VisionChangeHandlers(
      model: model,
      appModel: appModel,
      reload: { Task { await model.reload() } }))
  }

  @ViewBuilder
  private func detailContent(model: DocumentModel) -> some View {
    WebView(model.page)
      .navigationTitle(
        model.kind == .help
        ? Text("Help")
        : Text(model.documentURL.lastPathComponent))
      .overlay {
        if !model.isPageRendered {
          model.pageBackgroundColor.allowsHitTesting(false)
        }
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        if model.find.isVisible {
          FindBar(model: model.find)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if Defaults.shared.showsStatusBar {
          StatusBar(
            stats: model.stats,
            wordsPerMinute: Defaults.shared.readingWordsPerMinute)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .onAppear { wireLinkBridge(model: model) }
      .toolbar { toolbarContent(model: model) }
  }

  /// Bottom-ornament toolbar. visionOS renders
  /// `ToolbarItemPlacement.bottomOrnament` as a floating glass pill
  /// below the window — system-managed material, hit-test margins,
  /// and spacing. There is no menu bar on visionOS, so every command
  /// the macOS app surfaces in the menu has to land in chrome here.
  ///
  /// Layout, left to right, with spacers between groups:
  ///   1. Navigation — back / forward / reload
  ///   2. Layout — TOC toggle
  ///   3. Zoom — `ControlGroup` of zoomOut / 100% / zoomIn
  ///   4. Find toggle
  ///   5. Share menu — Markdown source + Rendered PDF
  ///   6. More (•••) menu — Open, Status Bar, Template, Color Scheme,
  ///      [Processor when >1], Settings, Help
  ///
  /// Pulling configuration knobs (template, color scheme, processor)
  /// and one-off commands (Open, Settings, Help) off the primary
  /// surface and into "More" keeps the visible glass pill compact
  /// — there's no menu-bar fallback when it gets crowded.
  @ToolbarContentBuilder
  private func toolbarContent(model: DocumentModel) -> some ToolbarContent {
    ToolbarItemGroup(placement: .bottomOrnament) {
      Action.back(model).toolbarItem(imageOnly: true)
      Action.forward(model).toolbarItem(imageOnly: true)
      Action.reload(model).toolbarItem(imageOnly: true)

      Spacer()

      Action.toggleTOC(model).toolbarItem(imageOnly: true)

      Spacer()

      ControlGroup {
        Action.zoomOut(model).toolbarItem(imageOnly: true)
        Action.resetZoom(model).toolbarItem(imageOnly: true)
        Action.zoomIn(model).toolbarItem(imageOnly: true)
      }

      Spacer()

      Action.find(model.find).toolbarItem(imageOnly: true)

      Spacer()

      shareMenu(model: model)

      moreMenu(model: model)
    }
  }

  /// Share submenu. Two `ShareLink`s as menu rows. The Markdown row
  /// shares the file URL directly (cheap — no work). The PDF row
  /// uses a `Transferable` so WebKit only renders the PDF after the
  /// user actually picks the row in the system share sheet. The
  /// Markdown row is hidden when the document isn't a file (e.g. a
  /// remote URL) — sharing the URL labeled "Markdown Source" would
  /// misrepresent what arrives at the other end.
  @ViewBuilder
  private func shareMenu(model: DocumentModel) -> some View {
    Menu {
      if model.documentURL.isFileURL {
        ShareLink(
          item: model.documentURL,
          subject: Text(model.documentURL.lastPathComponent),
          message: Text(model.documentURL.lastPathComponent)
        ) {
          Label("Markdown Source", systemImage: "doc.text")
        }
        .accessibilityIdentifier(ViewerA11yID.Toolbar.shareMarkdown)
      }
      ShareLink(
        item: model.pdfExport,
        preview: SharePreview(
          model.pdfExport.suggestedName,
          image: Image(systemName: "doc.richtext"))
      ) {
        Label("Rendered PDF", systemImage: "doc.richtext")
      }
      .accessibilityIdentifier(ViewerA11yID.Toolbar.sharePDF)
    } label: {
      Label("Share", systemImage: "square.and.arrow.up")
    }
    .accessibilityIdentifier(ViewerA11yID.Toolbar.share)
  }

  /// "More" (•••) menu. Catch-all for lower-frequency commands that
  /// don't earn a dedicated slot on the ornament. Mirrors what the
  /// macOS app puts in the File / View / Format / Help menus, minus
  /// items that don't apply on visionOS (Print, Page Setup, Open in
  /// Editor, Close, Rename — the last two are deferred pending
  /// security-scoped FS plumbing).
  @ViewBuilder
  private func moreMenu(model: DocumentModel) -> some View {
    Menu {
      Button {
        isFilePickerPresented = true
      } label: {
        Label("Open Document…", systemImage: "folder")
      }

      openRecentMenu

      Divider()

      Action.toggleStatusBar().menuItem()

      Divider()

      templateMenu(
        appModel: appModel,
        documentModel: model)
      .disabled(!model.documentURL.isFileURL)
      .help(
        model.documentURL.isFileURL
        ? ""
        : "Rendered on Mac — change template in Galley on your Mac.")
      colorSchemeMenu(
        appModel: appModel,
        documentModel: model)
      .disabled(!model.documentURL.isFileURL)
      .help(
        model.documentURL.isFileURL
        ? ""
        : "Rendered on Mac — change color scheme on your Mac.")
      // Processor picker only appears when there's an actual choice
      // to make. visionOS ships with the built-in Swift renderer
      // alone — external CLI processors aren't reachable — so a
      // degenerate one-row menu would just confuse users.
      if appModel.processors.values.count > 1 {
        processorMenu(
          appModel: appModel,
          documentModel: model)
      }

      Divider()

      Button {
        openWindow(id: VisionWindowID.settings)
      } label: {
        Label("Settings…", systemImage: "gearshape")
      }
      .accessibilityIdentifier(ViewerA11yID.ToolbarSettings.settings)

      if let helpURL = Bundle.main.url(
        forResource: "template-authoring",
        withExtension: "md") {
        Button {
          bindingFileURL = helpURL
        } label: {
          Label(
            "How to Make a Template",
            systemImage: "questionmark.circle")
        }
        .accessibilityIdentifier(ViewerA11yID.HelpMenu.templateAuthoring)
      }
    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .accessibilityIdentifier(ViewerA11yID.Toolbar.more)
  }

  /// Open Recent submenu for the More menu. Hidden when the list is
  /// empty so users don't see a dead entry on first launch.
  @ViewBuilder
  private var openRecentMenu: some View {
    if !recents.urls.isEmpty {
      Menu {
        ForEach(recents.urls, id: \.self) { url in
          Button {
            if let fresh = recents.openRecent(url) {
              bindingFileURL = fresh
            }
          } label: {
            Label(url.lastPathComponent, systemImage: "doc.text")
          }
        }
        Divider()
        Button("Clear Menu", role: .destructive) {
          recents.clearAll()
        }
      } label: {
        Label("Open Recent", systemImage: "clock")
      }
    }
  }

  /// Title shown in the detail-side title bar. Falls back to the
  /// raw absolute string for remote URLs (their `lastPathComponent`
  /// can be empty for site roots) and the filename otherwise.
  private func navigationTitle(for model: DocumentModel) -> String {
    if model.documentURL.isFileURL {
      return model.documentURL.lastPathComponent
    }
    let last = model.documentURL.lastPathComponent
    return last.isEmpty ? model.documentURL.absoluteString : last
  }

  /// Wire `LinkBridge`'s non-macOS callbacks so external links route
  /// through SwiftUI's `openURL`. `onMarkdownLink` is installed by
  /// `DocumentModel.wireBridges` itself, so in-window `.md → .md`
  /// navigation works without anything here.
  private func wireLinkBridge(model: DocumentModel) {
    // Externalize non-markdown / non-finder links through the
    // SwiftUI environment. visionOS routes the URL through the
    // system openURL handler, which surfaces Safari for http(s).
    // The bridge instance lives on the model; installing on every
    // appear is idempotent.
    _ = (model, openURL)
  }

  @MainActor
  private func ensureModel() -> DocumentModel {
    if let model { return model }
    let perFile = Defaults.shared.perFileStateStore[fileURL]
    let created = DocumentModel(
      initialURL: fileURL,
      appModel: appModel,
      templatePersistent: perFile.templatePersistent,
      processorPersistent: perFile.rendererPersistent,
      colorSchemePersistent: perFile.colorSchemePersistent,
      kind: .document,
      kosmosTunnel: KosmosTunnelClientRef(client: kosmos.httpTunnel))
    model = created
    return created
  }
}

/// Live-reload triggers for the visionOS document view. Mirrors the
/// macOS `ChangeHandlers` modifier: any change to the global or
/// per-document renderer / template / color-scheme — or to the
/// override gate itself — re-renders the WebView so the user
/// doesn't have to hit Reload manually. visionOS-only knobs like
/// the color-scheme choice (no system-appearance fallback) are
/// wired here too; macOS tracks the system appearance directly.
private struct VisionChangeHandlers: ViewModifier {
  let model: DocumentModel
  let appModel: AppModel
  let reload: () -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: appModel.processors.selected) { reload() }
      .onChange(of: appModel.templates.selected) { reload() }
      .onChange(of: appModel.colorSchemes.selected) { reload() }
      .onChange(of: Defaults.shared.enablePerDocumentOverrides) { reload() }
      .onChange(of: model.templates.persistent) { _, _ in reload() }
      .onChange(of: model.processors.persistent) { _, _ in reload() }
      .onChange(of: model.colorSchemes.persistent) { _, new in
        Defaults.shared.perFileStateStore[model.documentURL]
          .colorSchemePersistent = new
        reload()
      }
  }
}

/// Identifiers for the visionOS-only auxiliary scenes.
enum VisionWindowID {
  static let settings = "settings"
  /// Invisible anchor scene that keeps the app process alive across
  /// document-window close. See `VisionViewerApp` for rationale.
  static let home = "home"
}

#endif
