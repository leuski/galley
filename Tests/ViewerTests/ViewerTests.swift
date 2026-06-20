#if os(macOS)
//
//  ViewerTests.swift
//  Galley
//
//  Logic tests for the Viewer app. Uses `@testable import Galley` so
//  internal types (`EditorPreset`, etc.) are reachable from here.
//  Pure-routing tests for the kit live in
//  `Tests/GalleyCoreKitTests/Routing/`.
//

import AppKit
import Foundation
import GalleyCoreKit
import Testing
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

// MARK: - EditorPreset / substituteEditorTemplate

@Suite("EditorPreset")
struct EditorPresetTests {
  /// Every preset's URL template must produce a parseable URL after
  /// substitution — otherwise cmd-click silently fails.
  @Test("Every preset produces a parseable URL with line",
        arguments: EditorPreset.urlTemplatePresets)
  func everyPresetParsesWithLine(preset: EditorPreset) {
    let url = URL(fileURLWithPath: "/tmp/note.md")
    let result = substituteEditorTemplate(
      preset.urlTemplate ?? "", fileURL: url, line: 42)
    #expect(URL(string: result) != nil, "\(preset) → \(result)")
    #expect(result.contains("42"), "\(preset) line missing: \(result)")
  }

  @Test("Every preset still parses when line is nil",
        arguments: EditorPreset.urlTemplatePresets)
  func everyPresetParsesWithoutLine(preset: EditorPreset) {
    let url = URL(fileURLWithPath: "/tmp/note.md")
    let result = substituteEditorTemplate(
      preset.urlTemplate ?? "", fileURL: url, line: nil)
    #expect(URL(string: result) != nil, "\(preset) → \(result)")
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
  @Test("Spaces in path produce a parseable URL for every preset",
        arguments: EditorPreset.urlTemplatePresets)
  func spacesArePercentEncoded(preset: EditorPreset) {
    let url = URL(fileURLWithPath: "/tmp/foo bar/baz.md")
    let result = substituteEditorTemplate(
      preset.urlTemplate ?? "", fileURL: url, line: 1)
    #expect(URL(string: result) != nil, "\(preset) → \(result)")
    // The space MUST be encoded somehow — a literal space here means
    // the URL fails to parse on macOS 26 (older macOS versions were
    // lenient and accepted unencoded spaces, masking the bug).
    #expect(!result.contains("foo bar"), "\(preset) → \(result)")
    // Either single (%20) or double (%2520) encoding is acceptable
    // depending on placeholder; both decode back to a real space at
    // the receiving editor.
    #expect(
      result.contains("foo%20bar") || result.contains("foo%2520bar"),
      "\(preset) → \(result)")
  }

  /// Command-style presets (Xcode's `xed`) substitute `{path}` and
  /// `{line}` raw — no URL encoding — and `{line}` falls back to `"1"`
  /// so `--line {line}` always sees a valid integer.
  @Test("Every command preset substitutes path and line",
        arguments: EditorPreset.commandPresets)
  func everyCommandPresetSubstitutes(preset: EditorPreset) {
    guard case .command(_, let args) = preset.invocation else {
      Issue.record("\(preset) is not command-style")
      return
    }
    let url = URL(fileURLWithPath: "/tmp/foo bar/baz.md")
    let resolved = args.map {
      substituteCommandArg($0, fileURL: url, line: 42)
    }
    #expect(resolved.contains("/tmp/foo bar/baz.md"))
    #expect(resolved.contains("42"))
    #expect(!resolved.contains("{path}"))
    #expect(!resolved.contains("{line}"))
  }

  @Test("Command preset {line} defaults to 1 when caller passes nil")
  func commandLineDefault() {
    let url = URL(fileURLWithPath: "/tmp/note.md")
    #expect(
      substituteCommandArg("{line}", fileURL: url, line: nil) == "1")
  }

  @Test("Custom URL template substitutes all three placeholders")
  func customTemplateSubstitution() {
    let url = URL(fileURLWithPath: "/tmp/note.md")
    let template = "myeditor:url={url}|path={path}|line={line}"
    let result = substituteEditorTemplate(
      template, fileURL: url, line: 7)
    #expect(result.contains("url=file:///tmp/note.md"))
    #expect(result.contains("path=/tmp/note.md"))
    #expect(result.contains("line=7"))
  }

  @Test("Empty line substitutes to empty string, not the literal")
  func emptyLine() {
    let url = URL(fileURLWithPath: "/tmp/note.md")
    let result = substituteEditorTemplate(
      "x://open?line={line}", fileURL: url, line: nil)
    #expect(result == "x://open?line=")
    #expect(!result.contains("{line}"))
  }
}

#endif
