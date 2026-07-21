#if os(macOS)
//
//  ViewerTests.swift
//  Galley
//
//  Logic tests for the Viewer app. Uses `@testable import Galley` so
//  internal types (`Editor`, `EditorStore`, etc.) are reachable from
//  here. Pure-routing tests for the kit live in
//  `Tests/GalleyCoreKitTests/Routing/`.
//
//  Note: WelcomeView's recents list (inline Picker driving
//  `Action.openRecent`) is view-only wiring over the already-tested
//  open path; its visionOS row hover / sizing is verified in the
//  visionOS simulator, not in a unit test.
//

import AppKit
import Foundation
import KosmosTransport
import Testing
// `substituteEditorTemplate` / `substituteCommandArg` are internal to
// GalleyCoreKit (they back the live editor-open path; the tests share
// the same rules), so reach them via `@testable`.
@testable import GalleyCoreKit
@testable import Galley

@Test("Galley module loads")
func galleyModuleLoads() {
  #expect(Bool(true))
}

// No-op marker: the visionOS VisionWelcomeScreen icon swap is an asset/view
// change (Image asset + sizing) with no testable logic.

// No-op marker: DocumentModel.scrollToHeading's settle-until-stable JS body
// (keeps isScrollingTOC true across the smooth-scroll animation so the
// tocController's activeId posts are suppressed) is a JS string executed
// inside WebKit with no Swift-side seam to unit-test.

// No-op marker: replacing DocumentModel's one-shot `pendingScroll` field
// with a `ScrollIntent` argument threaded through rebindCurrent/renderCurrent
// is a behavior-preserving refactor — same target resolution per call path,
// no new logic to unit-test.

// No-op marker: moving the menu commands out of inline `Button`s and into
// `Action` factories rendered via `.menuItem()` is a behavior-preserving
// refactor — identical titles, SF Symbols, shortcuts, disabled conditions, and
// accessibility identifiers. Covers the mac File-menu commands (Close, Close
// All, Rename, Open in Editor, Export as PDF, Page Setup, Print) and the
// Open-Recent list + Clear Menu on both macOS and visionOS (the unified
// `Action.openRecent` uses `resolveRecentURL`, a no-op passthrough on macOS;
// the now-dead `RecentDocumentsModel.openRecent` was removed). `Action`'s
// stored metadata is internal to KosmosAppKit, so there is no Viewer-visible
// seam to assert against; the menu/toolbar rendering path is exercised by the
// UITests.

// MARK: - substituteEditorTemplate / substituteCommandArg

/// The substitution rules that back URL-scheme and command-style
/// editor opens. These are the "cmd-click silently fails" bug class:
/// a template that produces an unparseable URL, an unencoded space,
/// or a leftover placeholder means the open never reaches the editor.
/// The rules live in `Editor.swift` and are shared by the live open
/// path (`openURL(template:…)` / `runEditorCommand`) and these tests.
@Suite("Editor substitution")
struct EditorSubstitutionTests {
  private static let note = URL(fileURLWithPath: "/tmp/note.md")
  private static let spaced =
    URL(fileURLWithPath: "/tmp/foo bar/baz.md")

  /// A representative `{url}`-style template (BBEdit/TextMate/Sublime
  /// shape) and a `{path}`-style template (VSCode/Zed shape). Covers
  /// both percent-encoding paths without coupling to the live roster,
  /// which only lists apps installed on the test machine.
  static let urlTemplates = [
    "x-bbedit://open?url={url}&line={line}",
    "txmt://open?url={url}&line={line}",
    "subl://open?url={url}&line={line}",
    "vscode://file{path}:{line}",
    "zed://file{path}:{line}"
  ]

  @Test("Every template produces a parseable URL with line",
        arguments: urlTemplates)
  func templateParsesWithLine(template: String) {
    let result = substituteEditorTemplate(
      template, fileURL: Self.note, line: 42)
    #expect(URL(string: result) != nil, "\(template) → \(result)")
    #expect(result.contains("42"), "line missing: \(result)")
  }

  @Test("Every template still parses when line is nil",
        arguments: urlTemplates)
  func templateParsesWithoutLine(template: String) {
    let result = substituteEditorTemplate(
      template, fileURL: Self.note, line: nil)
    #expect(URL(string: result) != nil, "\(template) → \(result)")
  }

  /// Paths with spaces must percent-encode in the resulting URL.
  /// Without encoding, `URL(string:)` returns nil and the editor
  /// open silently fails — exactly the bug class the tests exist to
  /// catch. The encoding form differs by placeholder:
  ///   - `{path}`: encodes the raw path → `foo%20bar`
  ///   - `{url}`:  encodes `absoluteString` (already has `%20`)
  ///              with query-allowed → `foo%2520bar`. The double
  ///              encoding is correct for URLs embedded as a query
  ///              parameter — the receiver decodes once for the
  ///              query and once for the URL.
  @Test("Spaces in path produce a parseable URL for every template",
        arguments: urlTemplates)
  func spacesArePercentEncoded(template: String) {
    let result = substituteEditorTemplate(
      template, fileURL: Self.spaced, line: 1)
    #expect(URL(string: result) != nil, "\(template) → \(result)")
    // The space MUST be encoded somehow — a literal space here means
    // the URL fails to parse on macOS 26 (older macOS versions were
    // lenient and accepted unencoded spaces, masking the bug).
    #expect(!result.contains("foo bar"), "\(template) → \(result)")
    // Either single (%20) or double (%2520) encoding is acceptable
    // depending on placeholder; both decode back to a real space at
    // the receiving editor.
    #expect(
      result.contains("foo%20bar") || result.contains("foo%2520bar"),
      "\(template) → \(result)")
  }

  @Test("Custom URL template substitutes all three placeholders")
  func customTemplateSubstitution() {
    let template = "myeditor:url={url}|path={path}|line={line}"
    let result = substituteEditorTemplate(
      template, fileURL: Self.note, line: 7)
    #expect(result.contains("url=file:///tmp/note.md"))
    #expect(result.contains("path=/tmp/note.md"))
    #expect(result.contains("line=7"))
  }

  @Test("Empty line substitutes to empty string, not the literal")
  func emptyLine() {
    let result = substituteEditorTemplate(
      "x://open?line={line}", fileURL: Self.note, line: nil)
    #expect(result == "x://open?line=")
    #expect(!result.contains("{line}"))
  }

  /// Command-style editors (Xcode's `xed`) substitute `{path}` and
  /// `{line}` raw — no URL encoding — and `{line}` falls back to `"1"`
  /// so `--line {line}` always sees a valid integer.
  @Test("Command args substitute path and line raw")
  func commandArgsSubstitute() {
    let args = ["--line", "{line}", "{path}"]
    let resolved = args.map {
      substituteCommandArg($0, fileURL: Self.spaced, line: 42)
    }
    #expect(resolved.contains("/tmp/foo bar/baz.md"))
    #expect(resolved.contains("42"))
    #expect(!resolved.contains("{path}"))
    #expect(!resolved.contains("{line}"))
  }

  @Test("Command {line} defaults to 1 when caller passes nil")
  func commandLineDefault() {
    #expect(
      substituteCommandArg("{line}", fileURL: Self.note, line: nil)
        == "1")
  }
}

// MARK: - EditorStore roster

/// `EditorStore.values` is the live picker roster: the built-in
/// editors whose app LaunchServices can resolve on this machine, plus
/// the two always-present static rows (Custom URL Scheme, Other
/// Application…). The per-editor invariants below guard the picker and
/// the persistence layer (`RestorableChoiceValue` keys off
/// `persistentID`, the menu row shows `name`).
@Suite("EditorStore roster")
@MainActor
struct EditorStoreTests {
  @Test("Roster always includes the two static editors")
  func rosterHasStaticEditors() {
    let store = EditorStore.shared
    let ids = store.values.map(\.id)
    #expect(ids.contains(store.customURLScheme.id))
    #expect(ids.contains(store.otherApplication.id))
  }

  /// Every roster entry must carry a non-empty `persistentID` — it is
  /// the key the choice layer persists and restores by. A blank id
  /// would collide across editors and corrupt the saved selection.
  @Test("Every editor has a non-empty persistent id")
  func everyEditorHasPersistentID() {
    for editor in EditorStore.shared.values {
      #expect(!editor.id.isEmpty)
    }
  }

  /// The menu row shows `description`; an empty title would be a silent
  /// regression. The value itself is environment-dependent (built-in
  /// editors resolve the installed app's display name), so we only
  /// pin the non-empty invariant.
  @Test("Every editor resolves a non-empty menu title")
  func everyEditorHasName() {
    for editor in EditorStore.shared.values {
      #expect(!editor.description.isEmpty)
    }
  }

  /// A resolved built-in editor's `persistentID` is its bundle
  /// identifier (reverse-DNS). The two static editors use plain
  /// slugs, so they are exempt. Guards against a malformed id that
  /// would fail to resolve the app URL, icon, and availability.
  @Test("Resolved built-in editors key off a reverse-DNS bundle id")
  func builtInEditorsUseBundleIDs() {
    let staticIDs: Set = [
      EditorStore.shared.customURLScheme.id,
      EditorStore.shared.otherApplication.id
    ]
    for editor in EditorStore.shared.values
    where !staticIDs.contains(editor.id) {
      #expect(
        editor.id.contains("."),
        "\(editor.id) is not a bundle id")
    }
  }

  /// Every URL-template editor currently in the roster must produce a
  /// parseable URL — this is the roster-level companion to the
  /// substitution-rule tests above, catching a bad template string on
  /// any editor installed on the test machine.
  @Test("Every URL-template roster editor produces a parseable URL")
  func rosterTemplatesParse() {
    let url = URL(fileURLWithPath: "/tmp/note.md")
    for editor in EditorStore.shared.values {
      guard case .urlTemplate(let template) = editor.invocation,
            !template.isEmpty
      else { continue }
      let result = substituteEditorTemplate(
        template, fileURL: url, line: 42)
      #expect(
        URL(string: result) != nil,
        "\(editor.id) → \(result)")
    }
  }
}

#endif
