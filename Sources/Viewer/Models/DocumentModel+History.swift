#if os(macOS)
import AppKit
#endif
import Foundation
import KosmosAppKit

extension DocumentModel {
  struct History: Codable, Hashable, Sendable {
    private(set) var urls: [URL]
    private var currentIndex: Int

    var currentURL: URL {
      return urls[currentIndex]
    }

    var isEmpty: Bool { urls.isEmpty }

    var canGoBack: Bool {
      currentIndex > urls.startIndex
    }

    var canGoForward: Bool {
      currentIndex < urls.index(before: urls.endIndex)
    }

    init(url: URL) {
      urls = [url]
      currentIndex = 0
    }

    mutating func navigate(to url: URL) {
      urls.removeSubrange((currentIndex + 1)..<urls.count)
      urls.append(url)
      currentIndex = urls.count - 1
    }

    mutating func goBack() -> Bool {
      guard currentIndex > urls.startIndex else { return false}
      currentIndex = urls.index(before: currentIndex)
      return true
    }

    mutating func goForward() -> Bool {
      guard currentIndex < urls.index(before: urls.endIndex)
      else { return false}
      currentIndex = urls.index(after: currentIndex)
      return true
    }

    mutating func replace(_ old: URL, with new: URL) {
      urls = urls.map { $0 == old ? new : $0 }
    }
  }

  var canGoBack: Bool { history.canGoBack }
  var canGoForward: Bool { history.canGoForward }

  /// Push a new URL onto the history and navigate to it. Truncates
  /// any forward entries (browser-standard new-link behaviour).
  ///
  /// If the target file isn't readable, surfaces an error and leaves
  /// history, bridges, and the visible document untouched — that way
  /// a broken link click doesn't strand the window with a corrupted
  /// base URL the link bridge would resolve subsequent clicks against.
  func navigate(to url: URL) async {
    history.navigate(to: url)
    await rebindCurrent()
  }

  func goBack() async {
    guard history.goBack() else { return }
    await rebindCurrent()
  }

  func goForward() async {
    guard history.goForward() else { return }
    await rebindCurrent()
  }
}
