import Foundation
import Observation

/// One row in the BBEdit-style processor picker. The `renderer` is `nil`
/// when the underlying tool is not installed; the row is still shown so
/// the user can see what is available and how to install it.
public struct Processor: Sendable, Identifiable, CustomStringConvertible {
  public let id: String
  public let name: String
  public let installHint: String?
  public let renderer: (any MarkdownRenderer)?
  public var description: String { name }

  public init(
    id: String,
    name: String,
    installHint: String?,
    renderer: (any MarkdownRenderer)?
  ) {
    self.id = id
    self.name = name
    self.installHint = installHint
    self.renderer = renderer
  }

  public var isBuiltIn: Bool { installHint == nil }
  public var isAvailable: Bool { renderer != nil }

  /// Synchronous baseline matching the swift-markdown spec in
  /// `ProcessorStore.specs`. Used to seed `ProcessorStore` so the
  /// list is non-empty before async discovery completes — keeps
  /// `ProcessorChoice.selected` non-optional.
  public static let builtIn = Processor(
    id: "swift-markdown",
    name: "Built-in",
    installHint: nil,
    renderer: SwiftMarkdownRenderer())
}

/// Holds the discovered list of markdown processors. Owns both the
/// compile-time spec table and the async discovery work that
/// produces `[Processor]`. Initial state contains only
/// `Processor.builtIn` so consumers like `ProcessorChoice` always
/// see at least one entry — no optional fallback needed before the
/// first discovery completes.
@Observable
@MainActor
public final class ProcessorStore {
  public private(set) var processors: [Processor]

  public init() {
    self.processors = [.builtIn]
  }

  public func discover() async {
    self.processors = await Self.discoverAll()
  }

  // MARK: - Catalog

  private struct Spec: Sendable {
    let id: String
    let name: String
    let installHint: String?
    let discover: @Sendable () async -> (any MarkdownRenderer)?
  }

  /// Order is preserved in the picker. The built-in renderer comes
  /// first so the app has a working default before any external tool
  /// is found.
  private static let specs: [Spec] = [
    Spec(
      id: "swift-markdown",
      name: "Built-in",
      installHint: nil,
      discover: { SwiftMarkdownRenderer() }),
    Spec(
      id: "multimarkdown",
      name: "MultiMarkdown",
      installHint: "brew install multimarkdown",
      discover: {
        await ExternalProcessRenderer.discover(
          toolName: "multimarkdown")
      }),
    Spec(
      id: "discount",
      name: "Discount",
      installHint: "brew install discount",
      discover: {
        await ExternalProcessRenderer.discover(
          toolName: "markdown")
      }),
    Spec(
      id: "pandoc",
      name: "Pandoc",
      installHint: "brew install pandoc",
      discover: {
        // `+sourcepos` is a reader extension that emits `data-pos`
        // attributes on every block, used by the viewer's cmd-click
        // → editor jump and BBEdit's scroll-to-line on open.
        await ExternalProcessRenderer.discover(
          toolName: "pandoc",
          arguments: ["--from=markdown+sourcepos", "--to=html"])
      }),
    Spec(
      id: "cmark-gfm",
      name: "cmark-gfm",
      installHint: "brew install cmark-gfm",
      discover: {
        // `--sourcepos` emits `data-sourcepos` attributes — same
        // purpose as pandoc's `+sourcepos`.
        await ExternalProcessRenderer.discover(
          toolName: "cmark-gfm",
          arguments: [
            "--unsafe",
            "--sourcepos",
            "--extension", "table",
            "--extension", "strikethrough",
            "--extension", "tasklist",
            "--extension", "autolink"
          ])
      }),
    Spec(
      id: "classic",
      name: "Classic",
      installHint: "Place Markdown.pl on your PATH",
      discover: {
        await ExternalProcessRenderer.discover(
          toolName: "Markdown.pl")
      })
  ]

  private static func discoverAll() async -> [Processor] {
    var entries: [Processor] = []
    entries.reserveCapacity(specs.count)
    for spec in specs {
      let renderer = await spec.discover()
      entries.append(Processor(
        id: spec.id,
        name: spec.name,
        installHint: spec.installHint,
        renderer: renderer))
    }
    return entries
  }
}
