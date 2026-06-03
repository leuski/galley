#if os(macOS)
import AppKit
#endif
import Foundation
import KosmosAppKit

extension DocumentModel {
  var canGoBack: Bool { currentIndex > 0 }
  var canGoForward: Bool {
    currentIndex >= 0 && currentIndex < history.count - 1 }

  /// Codable view of the back/forward stack for `@SceneStorage`.
  /// Returns nil when there is nothing meaningful to persist.
  var historySnapshot: HistorySnapshot? {
    guard !history.isEmpty,
          currentIndex >= 0,
          currentIndex < history.count
    else { return nil }
    return HistorySnapshot(urls: history, currentIndex: currentIndex)
  }

  /// Push a new URL onto the history and navigate to it. Truncates
  /// any forward entries (browser-standard new-link behaviour).
  ///
  /// If the target file isn't readable, surfaces an error and leaves
  /// history, bridges, and the visible document untouched — that way
  /// a broken link click doesn't strand the window with a corrupted
  /// base URL the link bridge would resolve subsequent clicks against.
  func navigate(to url: URL) async {
    guard reportIfUnreachable(url) else { return }
    if currentIndex >= 0, currentIndex < history.count {
      history.removeSubrange((currentIndex + 1)..<history.count)
    }
    history.append(url)
    currentIndex = history.count - 1
    await rebindCurrent()
  }

  func goBack() async {
    guard canGoBack else { return }
    let target = history[currentIndex - 1]
    guard reportIfUnreachable(target) else { return }
    currentIndex -= 1
    await rebindCurrent()
  }

  func goForward() async {
    guard canGoForward else { return }
    let target = history[currentIndex + 1]
    guard reportIfUnreachable(target) else { return }
    currentIndex += 1
    await rebindCurrent()
  }

  /// Verify a link target is readable before we commit to navigating
  /// to it. Returns `true` when the file exists; otherwise posts an
  /// ephemeral notice + beep and returns `false`. Ephemeral because
  /// the current document's state is unaffected — only the user's
  /// just-clicked link was bad — so a brief receipt is appropriate.
  func reportIfUnreachable(_ url: URL) -> Bool {
    if FileManager.default.isReadableFile(atPath: url.path) {
      return true
    }
    report(
      String(localized:
        "Cannot open \(url.lastPathComponent): file not found."),
      lifetime: .ephemeral)
    #if os(macOS)
    NSSound.beep()
    #endif
    return false
  }
}

/// Serializable form of a window's back/forward stack. Persisted via
/// `@SceneStorage` so each window restores to whichever document the
/// user was viewing when the app last quit.
struct HistorySnapshot: Codable, Sendable, Equatable {
  let urls: [URL]
  let currentIndex: Int

  var nilIfEmpty: HistorySnapshot? {
    urls.isEmpty ? nil : self
  }

  /// The URL the snapshot says the window was last viewing, or `nil`
  /// when `currentIndex` is out of range (corrupted store).
  var currentURL: URL? {
    urls.indices.contains(currentIndex) ? urls[currentIndex] : nil
  }
}
