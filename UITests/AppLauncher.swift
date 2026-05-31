#if os(macOS)
internal import ALFoundation
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
  /// Pass `ignorePersistedState: false` only when the test depends
  /// on state restoration persisting across launches (the
  /// `testWindowsRestoreOnRelaunch` flow). The flag affects both
  /// reading *and* writing of persisted window state, so phase 1 of
  /// such a test must opt out too — otherwise nothing gets saved
  /// for phase 2 to restore.
  ///
  /// Returns the launched application handle.
  @MainActor
  static func launchClean(
    extraArgs: [String] = [],
    ignorePersistedState: Bool = true,
    file: StaticString = #file,
    line: UInt = #line
  ) -> XCUIApplication {
    let app = XCUIApplication()
    terminateAndWait(app, file: file, line: line)
    // `-ApplePersistenceIgnoreState YES` skips the "Reopen the
    // windows that were open before the crash?" alert that AppKit
    // shows after any recent crash. That alert is a modal NSAlert
    // attached to a hidden window — XCUITest can't see it, so the
    // test would hang at launch waiting for a window that's
    // blocked behind the alert. The flag also suppresses state
    // writes — opt out only when persistence behavior is itself
    // under test.
    //
    // We deliberately do NOT pass `--ui-test-mode` as a launch arg.
    // AppKit's command-line `NSUserDefaults` parser eats `--`-prefixed
    // tokens and interprets the next token as the value, which pollutes
    // the defaults domain in ways that can suppress the document
    // `WindowGroup` from spawning its initial window at launch. Inject
    // the test-mode marker via the environment instead —
    // `ProcessInfo.environment` isn't touched by AppKit's arg parser.
    var args: [String] = []
    if ignorePersistedState {
      args.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
    }
    args.append(contentsOf: extraArgs)
    app.launchArguments = args
    app.launchEnvironment["GALLEY_UI_TEST_MODE"] = "1"
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
  ///
  /// Pass `ignorePersistedState: false` for the persistence test —
  /// see `launchClean` for the rationale.
  @MainActor
  static func launchWithSeed(
    _ markdownContent: String,
    fileName: String = "Test.md",
    ignorePersistedState: Bool = true,
    file: StaticString = #file,
    line: UInt = #line
  ) throws -> (app: XCUIApplication, fileURL: URL) {
    let dir = URL.temporaryDirectory / "uitest-\(UUID().uuidString)"
    try dir.createDirectory()
    let fileURL = dir / fileName
    try markdownContent.write(to: fileURL, atomically: true, encoding: .utf8)
    let app = launchClean(
      ignorePersistedState: ignorePersistedState,
      file: file,
      line: line)
    openViaURLScheme(fileURL)
    return (app, fileURL)
  }

  /// Open `fileURL` in the running app via its `galley://` scheme — the
  /// same form BBEdit's preview script and the Server use. Routes
  /// through `onOpenURL`, which SwiftUI delivers to a `WindowGroup`
  /// window (materializing one if needed). Replaces the old
  /// `--seed-file` launch-buffer injection.
  @MainActor
  static func openViaURLScheme(_ fileURL: URL) {
    var components = URLComponents()
    components.scheme = "galley"
    components.path = fileURL.path
    guard let url = components.url else { return }
    let task = Process()
    task.launchPath = "/usr/bin/open"
    task.arguments = [url.absoluteString]
    try? task.run()
    task.waitUntilExit()
  }

  /// Launch *without* `-ApplePersistenceIgnoreState YES`, so AppKit
  /// reads the saved-state directory and SwiftUI restores any
  /// `WindowGroup<URL>` windows that were open at last quit.
  ///
  /// Used only by the state-restoration test, which seeds a window
  /// in a first launch, quits, and then expects this launcher to
  /// bring the window back. Every other test should use
  /// `launchClean` so saved state is ignored.
  ///
  /// Caller is responsible for ensuring no previous Galley instance
  /// is running and that the saved-state directory is in the
  /// expected pre-launch shape.
  @MainActor
  static func launchForRestoration() -> XCUIApplication {
    let app = XCUIApplication()
    terminateAndWait(app, file: #file, line: #line)
    app.launchArguments = []
    app.launchEnvironment["GALLEY_UI_TEST_MODE"] = "1"
    app.launch()
    return app
  }

}
#endif
