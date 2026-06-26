# Test framework

This document is the operating manual for tests in this repo. Read it
once; thereafter, the matrix in `docs/test-matrix.md` is the
day-to-day reference.

## Goals

1. **Catch the launch-time bugs we keep shipping.** "First open is
   dropped, second works", "windows don't restore", "open-recent
   re-opens spawn duplicate windows" are all the same class of bug —
   timing between AppKit's `application(_:open:)`, SwiftUI's
   `WindowGroup<URL>` hydration, and our state restoration. The
   framework attacks this with **unit tests on the extracted
   launch-state machine**, not just E2E.
2. **Run on every commit.** Any test that takes more than a few
   seconds belongs in a separate, slower tier.
3. **Stay below the XCUITest flake tax.** XCUITest is the highest tier
   only — most coverage lives in deterministic unit + integration
   tests that don't need an accessibility runner.

## Architecture

Five layers, smallest and fastest first. The Xcode project uses
filesystem-synchronized root groups, so any `.swift` file dropped into
the right subdirectory of `Tests/` is auto-added to the `Tests`
bundle on next build — **no project file edits, no Xcode UI steps**
for layers 1, 2, 3, 5.

| # | Layer | Tool | Where | Status |
|---|---|---|---|---|
| 1 | Routing logic | Swift Testing | `Tests/GalleyCoreKitTests/Routing/` | **landed** (92 tests passing) |
| 2 | App-level logic | Swift Testing | `Tests/ViewerLogicTests/`, `Tests/ServerLogicTests/` | drop in files |
| 3 | View snapshots | swift-snapshot-testing | `Tests/SnapshotTests/` | drop in files + add SwiftPM dep |
| 4 | XCUITest | XCUITest | `UITests/` | **landed** (target wired, 3 of 8 passing) |
| 5 | Integration | Swift Testing + `open(1)` | `Tests/IntegrationTests/` | drop in files |

The current test counts:

- **Tests** (kit + app-logic): 92 / 92 passing
- **UITests**: 3 / 8 passing — the 5 failures all stem from a single
  real product bug surfaced by the framework (see "Discovered bugs"
  below). The framework doing its job; the tests stay failing as a
  regression marker until the bug is fixed.

## Discovered bugs

### `WindowGroup<URL>` placeholder never materializes on launch

**Tests catching it:**
`testCleanLaunchEventuallyShowsOpenPanel`,
`testSeedFileOpensVisibleDocument`,
`testFileMenuOpenItemReachable`,
`testOpenRecentClearItemReachable`,
`testViewMenuNavigationItems`.

**Symptom:** On a fresh launch (whether seeded or empty), no Galley
window ever becomes visible to XCUITest. `app.windows.count == 0`
indefinitely, even though the app is foreground and the menu bar is
populated.

**What we know from diagnostics** (file-based logging, since removed):

- `ViewerAppDelegate.init` runs ✓
- `AppBoot.init` runs ✓
- `ProcessorStore.discover()` completes ✓ (~100ms)
- `AppModel` is constructed and stored on `boot.model` ✓
- `ContentView.body` **never fires** ✗

So the SwiftUI `WindowGroup(for: URL.self)` is never instantiating a
window. The delegate's `applicationShouldOpenUntitledFile` returns
`true`, but SwiftUI's URL-typed window groups don't auto-spawn an
"untitled" window the same way an unparameterized `WindowGroup` does.

**Connection to the user-visible bug:** "first document I try to open
does not open. only second one does." If the placeholder window never
materializes, then `install()` is never called, so the launch buffer
(populated by `application(_:open:)` callbacks for the dispatched
URL) never drains, so the document never opens. A second launch may
restore a previously-bound window from state restoration, which is
why "the second one does."

**Fix direction (not done in this session):** Implement
`applicationOpenUntitledFile(_:)` that explicitly calls
`openWindow(value: …)` with a sentinel/nil URL, OR trigger the
placeholder via state restoration / `OpenWindowAction` from somewhere
that's guaranteed to fire pre-window. Worth confirming this is a
SwiftUI bug vs. a missing handler before patching.

## Test-mode launch

UITests seed a document by firing a `galley://<path>` URL via
`/usr/bin/open` (`AppLauncher.openViaURLScheme`) — the same routing-aware
scheme Finder and BBEdit use — rather than via launch-argument injection.
The test-mode marker is passed through `launchEnvironment`
(`GALLEY_UI_TEST_MODE`), not a `--`-prefixed argument, because AppKit's
`NSUserDefaults` parser eats `--` tokens and pollutes the defaults domain.
Test mode also passes `-ApplePersistenceIgnoreState YES` to skip the
post-crash "Reopen?" alert.

(The old `LaunchArguments` parser — `--ui-test-mode` / `--seed-file` /
`--scratch-dir` / `--fixed-port` etc. — was removed once it was no longer
wired into app launch.)

## Accessibility identifiers

Both apps publish accessibility identifiers via centralized catalogs:

- `Sources/Viewer/Views/AccessibilityIdentifiers.swift` → `ViewerA11yID`
- `Sources/Server/Menu/AccessibilityIdentifiers.swift` → `ServerA11yID`

Tests **must** import these catalogs rather than hardcoding strings.
Renaming an identifier should fail the test target's compile, not
silently break a UI test at runtime.

When adding a new interactive surface, add an identifier to the
catalog and apply it via `.accessibilityIdentifier(...)`.

## Adding tests

For layers 1, 2, 3, 5: just create the file under the right
subdirectory of `Tests/` and Xcode will add it to the `Tests` bundle
on next build. No project file edits required. The existing
`Tests/GalleyCoreKitTests/` and `Tests/GalleyServerKitTests/`
subdirectories are already wired this way — new sibling subdirectories
work the same.

For layer 3 (snapshot tests), the one-time prep is adding a SwiftPM
dependency:

1. **File → Add Package Dependencies…**
2. URL: `https://github.com/pointfreeco/swift-snapshot-testing`
3. Version: latest 1.x.
4. Add to the `Tests` target.

For layer 4 (XCUITest), XCUITest requires a "UI Testing Bundle"
target type, which is the one place an Xcode UI step is unavoidable.
Defer this until layers 1–3 + 5 are saturated and we have a real need
for accessibility-driven UI automation. By then, much of what XCUITest
would cover is already handled by snapshot + integration layers.

## CI

Once the new targets exist, GitHub Actions matrix runs them in tiers:

```yaml
# .github/workflows/test.yml (sketch — not yet committed)
jobs:
  fast:
    # layers 1 + 2 — every push, fail-fast
    run: xcodebuild test -scheme Viewer -testPlan tests-fast
  snapshot:
    # layer 3 — every push
    run: xcodebuild test -scheme Viewer -testPlan tests-snapshot
  ui:
    # layer 4 — every PR, with retry
    run: xcodebuild test -scheme Viewer -testPlan tests-ui
  integration:
    # layer 5 — every PR
    run: xcodebuild test -scheme Viewer -testPlan tests-integration
```

## Flake quarantine

XCUITest tests will flake. Policy:

- Any test that fails 3 times in 7 days moves to a `quarantined/`
  subdirectory of its target.
- Quarantine size > 5 blocks merges until cleared.
- Each quarantined test has an issue tracking the reason.

## What's deliberately not here

- **No mocking the file system.** Tests use `--scratch-dir <tmp>` plus
  real temp directories. Mocks of `FileManager` rot.
- **No mocking `WKWebView`.** Snapshot tests check the rendered HTML
  string at the renderer boundary; the WebView itself is integration-
  tested via XCUITest.
- **No mocking `Process` for external renderers.** Tests stub via
  `PATH` override pointing at a fake binary script. This is what
  caught the cmark-gfm `data-sourcepos` regression historically.
- **No protocol-everything refactor.** Inject only at the seams the
  next test layer demands.

## Adding a test

| Want to test… | Use layer | Where it goes |
|---|---|---|
| Pure URL routing decision | 1 | `Tests/GalleyCoreKitTests/Routing/` |
| URL normalization edge case | 1 | `Tests/GalleyCoreKitTests/Routing/URLNormalizerTests.swift` |
| Window registry behavior | 1 | `Tests/GalleyCoreKitTests/Routing/WindowRegistryTests.swift` |
| `AppModel` discovery / persistence | 2 | `Tests/ViewerLogicTests/` |
| `Defaults` round-trip | 2 | `Tests/ViewerLogicTests/` |
| Settings pane visual regression | 3 | `Tests/SnapshotTests/` |
| Cmd-click → editor invocation | 4 | `Tests/ViewerUITests/` (uses `--mock-editor`) |
| Cold launch with N persisted scenes | 5 | `Tests/IntegrationTests/` (uses `open(1)`) |
| First-open-after-launch routing | 5 | `Tests/IntegrationTests/` |
