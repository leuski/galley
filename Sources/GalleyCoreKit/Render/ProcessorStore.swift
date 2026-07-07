import Foundation
import Observation

/// One row in the BBEdit-style processor picker. The `renderer` is `nil`
/// when the underlying tool is not installed; the row is still shown so
/// the user can see what is available and how to install it.
public struct Processor: Sendable, Identifiable,
                         CustomLocalizedStringResourceConvertible,
                         Equatable
{
  public struct ID: RawRepresentable, Sendable, Hashable, Codable, Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
      lhs.rawValue < rhs.rawValue
    }

    public let rawValue: String
    public init(rawValue: String) {
      self.rawValue = rawValue
    }
    public init(from decoder: any Decoder) throws {
      self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(rawValue)
    }
  }

  public static func == (lhs: Processor, rhs: Processor) -> Bool {
    lhs.id == rhs.id
  }

  public let id: ID
  public let name: LocalizedStringResource
  public let installHint: String?
  public let renderer: (any MarkdownRenderer)?
  public var localizedStringResource: LocalizedStringResource { name }

  public init(
    id: ID,
    name: LocalizedStringResource,
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
    id: ID(rawValue: "swift-markdown"),
    name: LocalizedStringResource("Built-in", bundle: .galleyCoreKit),
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
  public static let shared = ProcessorStore()

  public private(set) var processors: [Processor]

  public init() {
    self.processors = [.builtIn]
  }

  public func discover() async {
    self.processors = await Self.discoverAll()
    self.isReady = true
  }

  public func rediscover() {
    Task { await discover() }
  }

  public func existingProcessor(forID id: Processor.ID?) -> Processor? {
    processors.first(where: { $0.id == id })
  }

  public func anyProcessor(forID id: Processor.ID?) -> Processor {
    existingProcessor(forID: id) ?? .builtIn
  }

  private(set) var isReady: Bool = false

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
  ///
  /// On non-macOS platforms (visionOS / iOS) the array is empty:
  /// `Process` is unavailable, so external processors cannot be
  /// discovered or invoked. `discoverAll()` still returns
  /// `[.builtIn]`, and the picker collapses to just the in-process
  /// `SwiftMarkdownRenderer`.
  #if os(macOS)
  private static let specs: [Spec] = [
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
        // `+sourcepos` emits `data-pos` attributes on every block,
        // used by the viewer's cmd-click → editor jump and BBEdit's
        // scroll-to-line on open. Pandoc only supports sourcepos on
        // CommonMark-family readers (`commonmark`, `commonmark_x`,
        // `gfm`); the default `markdown` reader rejects the
        // extension. `commonmark_x` is the closest analogue to
        // pandoc's extended markdown.
        await ExternalProcessRenderer.discover(
          toolName: "pandoc",
          arguments: ["--from=commonmark_x+sourcepos", "--to=html"])
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
  #else
  private static let specs: [Spec] = []
  #endif

  private static func discoverAll() async -> [Processor] {
    var entries: [Processor] = [.builtIn]
    entries.reserveCapacity(specs.count)
    for spec in specs {
      let renderer = await spec.discover()
      entries.append(Processor(
        id: Processor.ID(rawValue: spec.id),
        name: LocalizedStringResource(String.LocalizationValue("\(spec.name)")),
        installHint: spec.installHint,
        renderer: renderer))
    }
    return entries
  }
}
