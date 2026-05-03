import XCTest

/// Helpers for launching the Viewer app under deterministic test
/// conditions. Every test funnels through here so launch arguments,
/// timeouts, and teardown stay consistent.
enum AppLauncher {
  /// Standard ui-test launch: no persisted state, no recent docs, no
  /// login item. Always terminates a previous Galley instance first
  /// (the Viewer's `applicationShouldTerminateAfterLastWindowClosed`
  /// is `false`, so a prior test run can leave a daemon-like process
  /// hanging that would be reused by `app.launch()` and silently
  /// ignore the test's `launchArguments`).
  ///
  /// `XCUIApplication.terminate()` is asynchronous, so we poll until
  /// the state actually flips to `.notRunning` before relaunching.
  /// Without this, `launch()` finds the app still running and either
  /// activates it (state: Running Background) or fails outright.
  ///
  /// Returns the launched application handle.
  @MainActor
  static func launchClean(
    extraArgs: [String] = [],
    file: StaticString = #file,
    line: UInt = #line
  ) -> XCUIApplication {
    let app = XCUIApplication()
    terminateAndWait(app, file: file, line: line)
    app.launchArguments = ["--ui-test-mode"] + extraArgs
    app.launch()
    return app
  }

  @MainActor
  private static func terminateAndWait(
    _ app: XCUIApplication,
    file: StaticString,
    line: UInt
  ) {
    guard app.state != .notRunning else { return }
    app.terminate()
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, app.state != .notRunning {
      Thread.sleep(forTimeInterval: 0.1)
    }
    if app.state != .notRunning {
      // Belt-and-suspenders: SIGKILL the binary if XCUITest's
      // termination is hanging. Lets the next test still run rather
      // than letting one stuck process poison the whole suite.
      let task = Process()
      task.launchPath = "/usr/bin/pkill"
      task.arguments = ["-9", "-f", "Galley.app/Contents/MacOS/Galley"]
      try? task.run()
      task.waitUntilExit()
      Thread.sleep(forTimeInterval: 0.5)
    }
  }

  /// Launch with a seed file so the app comes up bound to a document
  /// without going through LaunchServices. The caller is responsible
  /// for cleaning the temp directory; for one-shot tests, prefer
  /// `XCTestCase.addTeardownBlock` to remove the parent directory.
  @MainActor
  static func launchWithSeed(
    _ markdownContent: String,
    fileName: String = "Test.md",
    file: StaticString = #file,
    line: UInt = #line
  ) throws -> (app: XCUIApplication, fileURL: URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("uitest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent(fileName)
    try markdownContent.write(to: fileURL, atomically: true, encoding: .utf8)
    let app = launchClean(
      extraArgs: ["--seed-file", fileURL.path],
      file: file,
      line: line)
    return (app, fileURL)
  }
}
