import XCTest

/// Captures a screenshot of the Viewer's initial state for visual
/// reference. Useful baseline for spotting regressions in the
/// placeholder window or menu chrome — the screenshot is uploaded as
/// a test attachment regardless of whether windows are visible.
final class UITestsLaunchTests: XCTestCase {
  // Deliberately *not* overriding
  // `runsForEachTargetApplicationUIConfiguration` to `true` — that
  // Xcode boilerplate makes Xcode flip the system appearance to Dark
  // and re-run every test in this class, then often fails to restore
  // Light. We don't need light/dark launch screenshots; one run
  // per session in whatever appearance the user has set is fine.

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testLaunchScreenshot() throws {
    let app = AppLauncher.launchClean()
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: 5),
      "App must reach foreground before screenshotting")
    // No window-visibility assertion here — clean launch placeholder
    // is alpha=0 by design. We just want a baseline screenshot of
    // whatever is on screen.
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Clean launch (placeholder hidden)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
