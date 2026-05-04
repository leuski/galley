import Foundation

/// Parsed view of the command-line arguments / environment overrides
/// the test infrastructure uses to drive both apps deterministically.
///
/// Production launches pass none of these and `LaunchArguments()` is
/// the no-op default. The presence of `--ui-test-mode` tells the apps
/// to suppress state restoration, login items, recent-document
/// hydration, and any other behavior that would leak across test runs.
///
/// Pure value type so unit tests cover every flag combination without
/// touching `ProcessInfo` or `UserDefaults`.
public struct LaunchArguments: Sendable, Equatable {
  /// Master switch — when true the app shapes itself into a
  /// deterministic, ephemeral test mode. Implies several other flags
  /// at the call site (suppress login items, suppress restoration,
  /// disable recent docs).
  public var uiTestMode: Bool

  /// Wipe `UserDefaults` and the app's Application Support tree on
  /// startup. Implied by `uiTestMode` unless explicitly disabled.
  public var resetState: Bool

  /// Override the app's Application Support root. When set, every
  /// piece of persisted on-disk state (templates, bookmarks, helper
  /// scripts) lives under this directory. Tests pass a fresh temp dir.
  public var scratchDirectory: URL?

  /// Pre-seed a file path the Viewer should treat as if it had been
  /// opened via Finder. Used by integration tests to avoid driving the
  /// real `application(_:open:)` callback. The path is enqueued in the
  /// AppDelegate's launch buffer before `openHandler` installs.
  public var seedFile: URL?

  /// Override the editor invocation so cmd-click-to-editor is observable
  /// in tests. The path points at a script the test will read after
  /// the click, with `{path}` and `{line}` placeholders.
  public var mockEditorTemplate: String?

  /// Force a specific server port (Server app) so tests can hit it
  /// without scraping the menu bar. Ignored when not in ui-test mode.
  public var fixedPort: UInt16?

  public init(
    uiTestMode: Bool = false,
    resetState: Bool = false,
    scratchDirectory: URL? = nil,
    seedFile: URL? = nil,
    mockEditorTemplate: String? = nil,
    fixedPort: UInt16? = nil
  ) {
    self.uiTestMode = uiTestMode
    self.resetState = resetState
    self.scratchDirectory = scratchDirectory
    self.seedFile = seedFile
    self.mockEditorTemplate = mockEditorTemplate
    self.fixedPort = fixedPort
  }

  /// Parse from the live process. Production callers invoke this from
  /// `applicationWillFinishLaunching` (or earlier) so the returned
  /// struct is consulted before any persistent state is read.
  public static func fromProcess() -> LaunchArguments {
    parse(arguments: CommandLine.arguments)
  }

  /// Parse from an explicit argv. Pure — tests call this directly to
  /// exercise every flag combination.
  ///
  /// Recognized forms:
  ///   `--ui-test-mode`
  ///   `--reset-state`
  ///   `--scratch-dir=<path>`     or `--scratch-dir <path>`
  ///   `--seed-file=<path>`       or `--seed-file <path>`
  ///   `--mock-editor=<template>` or `--mock-editor <template>`
  ///   `--fixed-port=<n>`         or `--fixed-port <n>`
  ///
  /// `--ui-test-mode` implies `resetState = true` unless the caller
  /// explicitly passes `--no-reset-state` (escape hatch for tests
  /// that want to preload state into the scratch directory).
  public static func parse(arguments: [String]) -> LaunchArguments {
    var args = LaunchArguments()
    var iterator = arguments.dropFirst().makeIterator()
    var disableResetState = false
    while let token = iterator.next() {
      switch parseToken(token, iterator: &iterator) {
      case .uiTestMode:
        args.uiTestMode = true
      case .resetState:
        args.resetState = true
      case .noResetState:
        disableResetState = true
      case .scratchDirectory(let path):
        args.scratchDirectory = URL(fileURLWithPath: path)
      case .seedFile(let path):
        args.seedFile = URL(fileURLWithPath: path)
      case .mockEditor(let template):
        args.mockEditorTemplate = template
      case .fixedPort(let port):
        args.fixedPort = port
      case .unknown:
        continue
      }
    }
    if args.uiTestMode, !disableResetState {
      args.resetState = true
    }
    return args
  }

  private enum Token {
    case uiTestMode
    case resetState
    case noResetState
    case scratchDirectory(String)
    case seedFile(String)
    case mockEditor(String)
    case fixedPort(UInt16)
    case unknown
  }

  private static func parseToken(
    _ token: String,
    iterator: inout IndexingIterator<ArraySlice<String>>
  ) -> Token {
    let (name, inlineValue) = splitFlag(token)
    func take() -> String? { inlineValue ?? iterator.next() }
    switch name {
    case "--ui-test-mode":     return .uiTestMode
    case "--reset-state":      return .resetState
    case "--no-reset-state":   return .noResetState
    case "--scratch-dir":      return take().map(Token.scratchDirectory)
                                 ?? .unknown
    case "--seed-file":        return take().map(Token.seedFile) ?? .unknown
    case "--mock-editor":      return take().map(Token.mockEditor) ?? .unknown
    case "--fixed-port":
      return take().flatMap(UInt16.init).map(Token.fixedPort) ?? .unknown
    default:                   return .unknown
    }
  }

  private static func splitFlag(_ token: String) -> (String, String?) {
    guard let equals = token.firstIndex(of: "=") else { return (token, nil) }
    return (
      String(token[..<equals]),
      String(token[token.index(after: equals)...]))
  }
}
