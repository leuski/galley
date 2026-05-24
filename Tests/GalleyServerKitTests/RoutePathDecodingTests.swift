#if os(macOS)
import Foundation
import Testing
@testable import GalleyServerKit

@Suite("RoutePathDecoding")
struct RoutePathDecodingTests {
  @Test("Strips the prefix and returns the absolute file URL")
  func happyPath() {
    let url = Routes.decodeFilePath(
      from: "/preview/tmp/note.md", prefix: "/preview")
    #expect(url?.path == "/tmp/note.md")
  }

  @Test("Percent-encoded path components are decoded")
  func percentDecoded() {
    let url = Routes.decodeFilePath(
      from: "/preview/tmp/foo%20bar.md", prefix: "/preview")
    #expect(url?.lastPathComponent == "foo bar.md")
  }

  @Test("Returns nil when the request path does not start with the prefix")
  func wrongPrefix() {
    let url = Routes.decodeFilePath(
      from: "/events/tmp/note.md", prefix: "/preview")
    #expect(url == nil)
  }

  @Test("Returns nil when the tail is not absolute")
  func nonAbsoluteTail() {
    let url = Routes.decodeFilePath(
      from: "/previewtmp/note.md", prefix: "/preview")
    #expect(url == nil)
  }

  @Test("Rejects dotfiles in the last path component")
  func rejectsDotfile() {
    let url = Routes.decodeFilePath(
      from: "/preview/tmp/.secret.md", prefix: "/preview")
    #expect(url == nil)
  }

  @Test("Standardizes parent-traversal segments")
  func standardizesTraversal() {
    let url = Routes.decodeFilePath(
      from: "/preview/tmp/sub/../note.md", prefix: "/preview")
    #expect(url?.path == "/tmp/note.md")
  }

  @Test("Events prefix variant strips '/events' the same way")
  func eventsPrefix() {
    let url = Routes.decodeFilePath(
      from: "/events/tmp/note.md", prefix: "/events")
    #expect(url?.path == "/tmp/note.md")
  }
}
#endif
