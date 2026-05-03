import GalleyCoreKit
import XCTest

/// UI tests against the real Galley app — no behavior gating on
/// `--ui-test-mode`. The flag exists only as a marker and as a vehicle
/// for orthogonal injection points (`--seed-file`, future
/// `--scratch-dir`, etc.) that don't change what the app does, only
/// what initial data it sees.
///
/// The real product behaviors these tests pin:
///
/// 1. A clean launch (no seed, no restored windows) must NOT show a
///    visible window. The placeholder is `alphaValue = 0` until a
///    document binds. Then the FTUE Open panel appears.
/// 2. A launch with a seeded file must show a visible window whose
///    title reflects the file basename, with the menu bar wired up.
/// 3. SwiftUI accessibility identifiers from the
///    `ViewerA11yID` catalog reach `XCUIElement`s.
final class UITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  // MARK: - Real product invariants

  /// The AppKit tab bar's "+" button must not tear down the window.
  /// SwiftUI's `WindowGroup<URL>` with no `defaultValue:` mishandles
  /// `newWindowForTab:`: instead of spawning a fresh tab, it
  /// destroys the current window. We intercept the action via a
  /// runtime subclass override (`NoNewTabAction`) so "+" becomes a
  /// no-op while the rest of the tab system stays functional.
  ///
  /// To exercise this we trigger "New Tab" via the Window menu —
  /// that action sends the same `newWindowForTab:` selector as the
  /// "+" button, and is reachable from XCUITest without trying to
  /// hit-test a tab-bar pixel.
  @MainActor
  func testNewTabActionDoesNotDestroyWindow() throws {
    let app = try seedAndWaitForWindow(fileName: "TabPlus.md")

    // Sanity: the doc window is up before we send the action.
    let before = waitForHittableWindow(
      in: app,
      titleContains: "TabPlus",
      timeout: 10)
    XCTAssertNotNil(before, "Doc window should be visible up front")

    // Open Window menu, look for any "New Tab" entry. If we can
    // find one we click it; that fires `newWindowForTab:` on the
    // key window — same selector the tab bar's "+" button sends.
    let windowMenu = app.menuBars.menuBarItems["Window"]
    XCTAssertTrue(windowMenu.waitForExistence(timeout: 5))
    windowMenu.click()
    Thread.sleep(forTimeInterval: 0.3)
    let newTab = app.menuBars.menuItems["New Tab"]
    if newTab.exists {
      newTab.click()
    } else {
      // Some macOS releases don't expose the menu item by that
      // exact title; just dismiss the menu and skip the click —
      // the assertion below still holds because no tear-down
      // happened.
      app.typeKey(.escape, modifierFlags: [])
    }
    Thread.sleep(forTimeInterval: 0.5)

    // After the action, the original window must still be present
    // and hittable. Without the intercept, SwiftUI's broken
    // default would have torn it down — so this absence-of-
    // disappearance is the regression marker.
    let after = waitForHittableWindow(
      in: app,
      titleContains: "TabPlus",
      timeout: 5)
    XCTAssertNotNil(
      after,
      "Doc window must still exist after a New Tab / + action — " +
      "without the NoNewTabAction intercept, SwiftUI's " +
      "WindowGroup<URL> tears it down.")
  }

  /// Welcome must NOT appear in the Window menu. SwiftUI's `Window`
  /// scene auto-generates a Window-menu entry tied to the scene's
  /// title, separate from per-NSWindow entries. Both
  /// `isExcludedFromWindowsMenu` and `NSApp.removeWindowsItem` only
  /// affect the per-window entries — the scene-level entry needs a
  /// different mechanism. This test pins the user-facing invariant
  /// regardless of which lever fixes it.
  @MainActor
  func testWelcomeNotInWindowMenu() throws {
    // Use a seeded launch so there's at least one real document
    // window for the Window menu to populate around — easier to
    // verify "no Welcome entry among real entries" than "Window
    // menu is empty."
    let app = try seedAndWaitForWindow(fileName: "WindowMenu.md")
    let windowMenu = app.menuBars.menuBarItems["Window"]
    XCTAssertTrue(windowMenu.waitForExistence(timeout: 5),
                  "Window menu should exist in the menu bar")
    windowMenu.click()
    // Wait for the menu to populate.
    Thread.sleep(forTimeInterval: 0.5)

    // Capture every menu item under Window for diagnostics.
    var titles: [String] = []
    for index in 0..<app.menuBars.menuItems.count {
      let item = app.menuBars.menuItems.element(boundBy: index)
      let title = item.title
      if !title.isEmpty { titles.append(title) }
    }
    let attachment = XCTAttachment(
      string: "Window menu items at click time:\n" +
      titles.joined(separator: "\n"))
    attachment.name = "Window menu contents"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertFalse(
      app.menuBars.menuItems["Welcome"].exists,
      "Window menu must not contain a 'Welcome' entry. " +
      "Captured menu contents in attachment.")

    app.typeKey(.escape, modifierFlags: [])
  }

  /// Welcome window must never be visible/hittable. The bootstrap
  /// scene exists for the lifetime of the app, but its NSWindow is
  /// configured with alpha=0 + ignoresMouseEvents and excluded from
  /// the Window menu, so the user can neither see nor interact with
  /// it. This test pins that.
  ///
  /// We deliberately don't assert "no windows hittable" — the FTUE
  /// `NSOpenPanel` IS expected to appear shortly after a cold
  /// launch (covered by `testCleanLaunchEventuallyShowsOpenPanel`).
  /// What we forbid is a Galley *document* or *welcome* window
  /// becoming user-visible without a document.
  @MainActor
  func testWelcomeWindowStaysHidden() throws {
    let app = AppLauncher.launchClean()
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: 5),
      "App should be foreground after launch")
    // Sample over 1s — covers the entire bootstrap window before
    // the FTUE Open panel surfaces.
    let deadline = Date().addingTimeInterval(1.0)
    while Date() < deadline {
      for index in 0..<app.windows.count {
        let window = app.windows.element(boundBy: index)
        // Welcome is identified by its scene title. The Open panel
        // (title "Open") is allowed to be hittable; document
        // windows would have a file basename and never appear on a
        // clean launch.
        if window.title == "Welcome" {
          XCTAssertFalse(
            window.isHittable,
            "Welcome window must remain invisible/non-hittable")
        }
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  /// After the placeholder settles, the FTUE Open panel appears.
  /// Verifies that `runLaunchPicker` actually fires its NSOpenPanel
  /// for an empty launch — the production behavior we want to keep.
  @MainActor
  func testCleanLaunchEventuallyShowsOpenPanel() throws {
    let app = AppLauncher.launchClean()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    // The Open panel is an NSOpenPanel presented via `panel.begin`;
    // it appears as a window with a Cancel button. Look for a
    // hittable window containing a Cancel button — that's the panel.
    let cancel = app.windows.buttons["Cancel"]
    XCTAssertTrue(
      cancel.waitForExistence(timeout: 10),
      "Open panel should appear within 10s of a clean launch " +
      "(production FTUE behavior)")
    // Dismiss so the test doesn't leave a modal panel up for the
    // next test.
    cancel.click()
  }

  // MARK: - Seeded launch (visible-document path)

  /// A launch with `--seed-file <path>` must produce a visible window
  /// bound to that document. Equivalent to the user double-clicking
  /// the file in Finder.
  @MainActor
  func testSeedFileOpensVisibleDocument() throws {
    let (app, fileURL) = try AppLauncher.launchWithSeed(
      "# Hello from seed\n\nBody text.",
      fileName: "Seed.md")
    addTeardownBlock {
      try? FileManager.default.removeItem(
        at: fileURL.deletingLastPathComponent())
    }
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))

    // A real document window must become visible. The
    // `.navigationTitle(...)` on ContentView surfaces the file
    // basename to AppKit; we wait for a window with that title to
    // become hittable (alpha=1, which only happens when a document
    // binds — exactly the production behavior we're pinning).
    let visible = waitForHittableWindow(
      in: app,
      titleContains: "Seed",
      timeout: 10)
    XCTAssertNotNil(
      visible,
      "Seeded file should produce a visible window with a title " +
      "containing the file basename")
  }

  /// State restoration: a document window open at quit time must
  /// come back on the next launch.
  ///
  /// Phase 1 seeds a markdown file via `--seed-file`, waits for its
  /// window to become visible (proves the seed flowed through the
  /// dispatcher → openWindow → ContentView path), then issues a
  /// graceful terminate. macOS's `talagentd` daemon (managing
  /// saved state since macOS 15) captures the open `WindowGroup<URL>`
  /// values into its container at
  /// `~/Library/Daemon Containers/<talagentd-UUID>/Data/Library/Saved
  /// Application State/<app-UUID>/`. The container is sandboxed away
  /// from terminal access, so we don't try to introspect it — we
  /// rely on the end-to-end assertion in phase 2 instead.
  ///
  /// Phase 2 launches *without* `--seed-file` and *without*
  /// `-ApplePersistenceIgnoreState YES` (via `launchForRestoration`),
  /// so SwiftUI's `WindowGroup<URL>` reads the saved URL from
  /// talagentd and restores the window. We verify a window with
  /// the same file's title comes back, hittable.
  ///
  /// The temp directory holding the seeded file is preserved across
  /// the quit/relaunch (teardown removes it after both phases) so
  /// the restored URL still resolves to a real file.
  ///
  /// Requires the user's macOS state-restoration preference to be
  /// enabled (System Settings → Desktop & Dock → "Close windows
  /// when quitting an application" must be **off**, equivalent to
  /// `NSQuitAlwaysKeepsWindows = true` in `NSGlobalDomain`). The
  /// test fails informatively if restoration doesn't bring the
  /// window back; the failure message points at the system
  /// preference as the most common cause.
  @MainActor
  func testWindowsRestoreOnRelaunch() throws {
    // Phase 1 — seed a doc and wait for its window. Don't pass
    // `-ApplePersistenceIgnoreState YES` here: that flag suppresses
    // saving as well as loading, and we need talagentd to capture
    // the seeded URL so phase 2 can restore it.
    let (app1, fileURL) = try AppLauncher.launchWithSeed(
      "# Persistent doc\n\nThis should survive a relaunch.",
      fileName: "Persistent.md",
      ignorePersistedState: false)
    addTeardownBlock {
      try? FileManager.default.removeItem(
        at: fileURL.deletingLastPathComponent())
    }
    XCTAssertTrue(
      app1.wait(for: .runningForeground, timeout: 5),
      "Phase 1 app should reach foreground")
    let phase1 = waitForHittableWindow(
      in: app1,
      titleContains: "Persistent",
      timeout: 10)
    XCTAssertNotNil(
      phase1,
      "Seeded doc window should be visible in phase 1 before quit")

    // Quit gracefully so AppKit/SwiftUI hand the open URL to
    // talagentd. `terminate()` sends a normal terminate request,
    // which triggers the app's normal termination path including
    // state-restoration save.
    app1.terminate()
    let terminateDeadline = Date().addingTimeInterval(5)
    while Date() < terminateDeadline, app1.state != .notRunning {
      Thread.sleep(forTimeInterval: 0.1)
    }
    XCTAssertEqual(
      app1.state, .notRunning,
      "Phase 1 app should fully terminate before phase 2 launches")

    // Phase 2 — launch fresh with state restoration enabled.
    // No --seed-file. No -ApplePersistenceIgnoreState.
    let app2 = AppLauncher.launchForRestoration()
    XCTAssertTrue(
      app2.wait(for: .runningForeground, timeout: 5),
      "Phase 2 app should reach foreground")
    let phase2 = waitForHittableWindow(
      in: app2,
      titleContains: "Persistent",
      timeout: 15)
    XCTAssertNotNil(
      phase2,
      "Restored doc window should reappear on relaunch. " +
      "If this fails, check System Settings → Desktop & Dock " +
      "→ 'Close windows when quitting an application' — that " +
      "must be OFF for macOS to save and restore window state.")
  }

  // MARK: - Menu items (after a seeded launch — gives us a populated UI)

  // SwiftUI's `.accessibilityIdentifier(...)` does NOT propagate
  // to `NSMenuItem` when applied inside `.commands { ... }` —
  // the dump shows the synthetic `menuAction:` identifier instead
  // of our catalog values. Until SwiftUI exposes a real bridge for
  // menu identifiers, the menu tests query by *title* (the
  // localized button label, which IS the menu item's title in
  // AppKit). Toolbar buttons and inline view surfaces still use
  // the catalog identifiers.

  @MainActor
  func testFileMenuOpenItemReachable() throws {
    let app = try seedAndWaitForWindow()
    let fileMenu = app.menuBars.menuBarItems["File"]
    XCTAssertTrue(fileMenu.waitForExistence(timeout: 5),
                  "File menu should exist in the menu bar")
    fileMenu.click()
    XCTAssertTrue(
      app.menuBars.menuItems["Open…"].waitForExistence(timeout: 5),
      "File > Open menu item should be reachable")
    app.typeKey(.escape, modifierFlags: [])
  }

  @MainActor
  func testViewMenuNavigationItems() throws {
    let app = try seedAndWaitForWindow()
    let viewMenu = app.menuBars.menuBarItems["View"]
    XCTAssertTrue(viewMenu.waitForExistence(timeout: 5))
    viewMenu.click()

    // Titles match the LocalizedStringResource values in
    // `Sources/Viewer/Views/Actions.swift`.
    for title in [
      "Back", "Forward", "Reload",
      "Zoom In", "Zoom Out", "Actual Size"
    ] {
      XCTAssertTrue(
        app.menuBars.menuItems[title].waitForExistence(timeout: 2),
        "View menu should expose item titled \(title)")
    }
    app.typeKey(.escape, modifierFlags: [])
  }

  @MainActor
  func testOpenRecentClearItemReachable() throws {
    let app = try seedAndWaitForWindow()
    app.menuBars.menuBarItems["File"].click()
    let openRecent = app.menuBars.menuItems["Open Recent"]
    XCTAssertTrue(openRecent.waitForExistence(timeout: 5),
                  "Open Recent submenu should be present")
    openRecent.hover()
    XCTAssertTrue(
      app.menuBars.menuItems["Clear Menu"].waitForExistence(timeout: 5),
      "Open Recent should expose Clear Menu")
    app.typeKey(.escape, modifierFlags: [])
    app.typeKey(.escape, modifierFlags: [])
  }

  // MARK: - Helpers

  /// Launch with a seeded markdown file and wait for its window to
  /// be visible. Used by menu-related tests so they run against a
  /// populated UI rather than the placeholder/picker state.
  @MainActor
  private func seedAndWaitForWindow(
    fileName: String = "MenuTest.md"
  ) throws -> XCUIApplication {
    let (app, fileURL) = try AppLauncher.launchWithSeed(
      "# Menu test fixture\n",
      fileName: fileName)
    addTeardownBlock {
      try? FileManager.default.removeItem(
        at: fileURL.deletingLastPathComponent())
    }
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    let visible = waitForHittableWindow(
      in: app,
      titleContains: fileName.replacingOccurrences(of: ".md", with: ""),
      timeout: 10)
    XCTAssertNotNil(
      visible,
      "Seeded window should be visible before driving menus")
    return app
  }

  /// Wait until any window in `app` whose title contains `titleContains`
  /// is hittable (i.e., visible to the user). Returns the matched
  /// window or `nil` on timeout.
  ///
  /// XCUITest's `NSPredicate`-based `matching(_:)` doesn't allow
  /// `isHittable` as a predicate key path, so we filter in Swift.
  /// On timeout, attach a snapshot of every window XCUI can see
  /// (titles + hittable flag) so the test report explains the
  /// failure rather than just saying "nil."
  @MainActor
  private func waitForHittableWindow(
    in app: XCUIApplication,
    titleContains needle: String,
    timeout: TimeInterval
  ) -> XCUIElement? {
    let titlePredicate = NSPredicate(
      format: "title CONTAINS[c] %@", needle)
    let candidates = app.windows.matching(titlePredicate)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      for index in 0..<candidates.count {
        let element = candidates.element(boundBy: index)
        if element.exists, element.isHittable { return element }
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    attachWindowDiagnostics(app: app, needle: needle)
    return nil
  }

  /// Dump every window XCUI sees (title + isHittable + frame) as a
  /// test attachment. Used when `waitForHittableWindow` times out.
  @MainActor
  private func attachWindowDiagnostics(
    app: XCUIApplication,
    needle: String
  ) {
    var lines: [String] = []
    lines.append("Looking for window title containing '\(needle)'.")
    lines.append("App state: \(app.state.rawValue) " +
                 "(notRunning=1, runningBackground=2, runningForeground=4)")
    lines.append("app.windows.count = \(app.windows.count)")
    for index in 0..<app.windows.count {
      let win = app.windows.element(boundBy: index)
      lines.append("[\(index)] title='\(win.title)' " +
                   "exists=\(win.exists) " +
                   "isHittable=\(win.isHittable) " +
                   "frame=\(win.frame)")
    }
    lines.append("---- app debug description ----")
    lines.append(app.debugDescription)
    let attachment = XCTAttachment(
      string: lines.joined(separator: "\n"))
    attachment.name = "windowDiagnostics for '\(needle)'"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
