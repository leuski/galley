#if os(macOS)
import Foundation
import Testing
@testable import GalleyServerKit

/// `PathPattern` replaces Hummingbird's `/**` matching so the call sites
/// in `Routes.swift` keep their existing patterns (`/preview/**`,
/// `/template/**`, `/events/**`, `/`). FlyingFox's own `*` only matches a
/// single path segment, so we cannot defer this to its router and the
/// matching contract is the whole reason this type exists.
@Suite("Adapter/PathPattern")
struct AdapterPathPatternTests {
  @Test("Exact `/` matches only `/`")
  func rootExact() {
    let pattern = PathPattern("/")
    #expect(pattern.matches("/"))
    #expect(!pattern.matches(""))
    #expect(!pattern.matches("/x"))
  }

  @Test("`/preview/**` matches the bare prefix")
  func multiWildcardBare() {
    let pattern = PathPattern("/preview/**")
    #expect(pattern.matches("/preview"))
  }

  @Test("`/preview/**` matches a single-segment tail")
  func multiWildcardSingleSegment() {
    let pattern = PathPattern("/preview/**")
    #expect(pattern.matches("/preview/foo.md"))
  }

  @Test("`/preview/**` matches a multi-segment tail")
  func multiWildcardMultiSegment() {
    let pattern = PathPattern("/preview/**")
    // The whole reason we cannot use FlyingFox's `*` — its trailing
    // wildcard is single-segment.
    #expect(pattern.matches("/preview/a/b/c.md"))
  }

  @Test("`/preview/**` does not match a path that merely starts with the prefix")
  func multiWildcardRejectsPrefixCollision() {
    let pattern = PathPattern("/preview/**")
    // "/previewother" shares a string prefix with "/preview" but is a
    // different first segment — must not match.
    #expect(!pattern.matches("/previewother"))
    #expect(!pattern.matches("/previewother/x"))
  }

  @Test("`/preview/**` does not match unrelated paths")
  func multiWildcardRejectsUnrelated() {
    let pattern = PathPattern("/preview/**")
    #expect(!pattern.matches("/"))
    #expect(!pattern.matches("/other"))
    #expect(!pattern.matches("/events/foo.md"))
  }

  @Test("Exact pattern matches verbatim only")
  func exactPattern() {
    let pattern = PathPattern("/health")
    #expect(pattern.matches("/health"))
    #expect(!pattern.matches("/health/"))
    #expect(!pattern.matches("/health/x"))
  }
}
#endif
