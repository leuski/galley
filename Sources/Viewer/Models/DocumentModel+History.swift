import Foundation
import GalleyCoreKit

extension DocumentModel {
  var canGoBack: Bool { history.canGoBack }
  var canGoForward: Bool { history.canGoForward }
  var backList: some RandomAccessCollection<WebPageHistory.Item> {
    history.backList }
  var forwardList: some RandomAccessCollection<WebPageHistory.Item> {
    history.forwardList }

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

  func navigate(to item: WebPageHistory.Item) {
    Task {
      history.navigate(to: item, leavingScrollY: currentScrollY)
      await rebindCurrent(firstScroll: .location(
        history.currentItem?.scrollY ?? 0))
    }
  }

  func goBack() async {
    guard history.goBack(leavingScrollY: currentScrollY)
    else { return }
    await rebindCurrent(firstScroll: .location(
      history.currentItem?.scrollY ?? 0))
  }

  func goForward() async {
    guard history.goForward(leavingScrollY: currentScrollY)
    else { return }
    await rebindCurrent(firstScroll: .location(
      history.currentItem?.scrollY ?? 0))
  }
}
