import Foundation
import GalleyCoreKit

extension DocumentModel {
  struct History: Codable, Hashable, Sendable {
    /// One visited document plus the reader's last resting scroll
    /// position in it. `scrollY` is stamped when the reader navigates
    /// *away* from an entry (so Back/Forward can return them to where
    /// they were); it stays at the top (0) until the first such leave.
    struct Entry: Codable, Hashable, Sendable {
      let url: URL
      var scrollY: Double

      init(url: URL, scrollY: Double = 0) {
        self.url = url
        self.scrollY = scrollY
      }
    }

    private(set) var entries: [Entry]
    private var currentIndex: Int

    var currentURL: URL {
      return entries[currentIndex].url
    }

    /// Resting scroll position recorded for the current entry — the
    /// value Back/Forward hands to the next render so the page comes
    /// back where the reader left it.
    var currentScrollY: Double {
      return entries[currentIndex].scrollY
    }

    var isEmpty: Bool { entries.isEmpty }

    var canGoBack: Bool {
      currentIndex > entries.startIndex
    }

    var canGoForward: Bool {
      currentIndex < entries.index(before: entries.endIndex)
    }

    init(url: URL) {
      entries = [Entry(url: url)]
      currentIndex = 0
    }

    /// Push `url` as a new entry, first stamping `leavingScrollY` onto
    /// the entry being left so a later Back restores it. Truncates any
    /// forward history (browser-standard new-link behaviour); the new
    /// entry starts at the top.
    mutating func navigate(to url: URL, leavingScrollY: Double) {
      entries[currentIndex].scrollY = leavingScrollY
      entries.removeSubrange((currentIndex + 1)..<entries.count)
      entries.append(Entry(url: url))
      currentIndex = entries.count - 1
    }

    mutating func goBack(leavingScrollY: Double) -> Bool {
      guard currentIndex > entries.startIndex else { return false }
      entries[currentIndex].scrollY = leavingScrollY
      currentIndex = entries.index(before: currentIndex)
      return true
    }

    mutating func goForward(leavingScrollY: Double) -> Bool {
      guard currentIndex < entries.index(before: entries.endIndex)
      else { return false }
      entries[currentIndex].scrollY = leavingScrollY
      currentIndex = entries.index(after: currentIndex)
      return true
    }

    mutating func replace(_ old: URL, with new: URL) {
      entries = entries.map {
        $0.url == old ? Entry(url: new, scrollY: $0.scrollY) : $0
      }
    }

    // Custom Codable so snapshots persisted before per-entry scroll
    // (a bare `urls: [URL]`) still rehydrate — legacy entries land at
    // the top. The extra `urls` key blocks synthesis, so spell both
    // sides out.
    private enum CodingKeys: String, CodingKey {
      case entries, urls, currentIndex
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      currentIndex = try container.decode(Int.self, forKey: .currentIndex)
      if let entries = try container.decodeIfPresent(
        [Entry].self, forKey: .entries) {
        self.entries = entries
      } else {
        let urls = try container.decode([URL].self, forKey: .urls)
        self.entries = urls.map { Entry(url: $0) }
      }
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(entries, forKey: .entries)
      try container.encode(currentIndex, forKey: .currentIndex)
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
    history.navigate(to: url, leavingScrollY: currentScrollY)
    await rebindCurrent(firstScroll: .top)
  }

  func goBack() async {
    guard history.goBack(leavingScrollY: currentScrollY)
    else { return }
    await rebindCurrent(firstScroll: .location(history.currentScrollY))
  }

  func goForward() async {
    guard history.goForward(leavingScrollY: currentScrollY)
    else { return }
    await rebindCurrent(firstScroll: .location(history.currentScrollY))
  }
}
