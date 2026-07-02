//
//  WindowModelTabsTests.swift
//  Galley
//

import Testing
import Foundation
import GalleyCoreKit

/// Exercises the tab-container behavior the visionOS `.newTab` open path
/// relies on: `AbstractWindowModel.addTab` appends and activates the new
/// tab, and a window always keeps at least one tab.
@MainActor
struct WindowModelTabsTests {
  /// A minimal `Persistent` tab stub — no `WebPage`, so these stay light.
  final class StubTab: Persistent {
    struct Snapshot: Codable, Equatable, Sendable { var name: String }
    let name: String
    init(_ name: String) { self.name = name }
    var snapshot: Snapshot { Snapshot(name: name) }
    init?(snapshot: Snapshot) { self.name = snapshot.name }
    func trackPersistentState() {}
  }

  @Test("addTab appends and activates the new tab")
  func addTabActivates() {
    let window = AbstractWindowModel(StubTab("a"))
    let b = StubTab("b")
    window.addTab(b)
    #expect(window.tabs.count == 2)
    #expect(window.activeTab === b)
  }

  @Test("activate switches to an existing tab without adding one")
  func activateExisting() {
    let a = StubTab("a")
    let window = AbstractWindowModel(a)
    let b = StubTab("b")
    window.addTab(b)             // active == b
    window.activate(tab: a)      // dedup: switch to the already-open tab
    #expect(window.activeTab === a)
    #expect(window.tabs.count == 2)
  }

  @Test("closing the active tab activates a neighbor; the last tab is kept")
  func closeKeepsAtLeastOne() {
    let a = StubTab("a")
    let window = AbstractWindowModel(a)
    let b = StubTab("b")
    window.addTab(b)            // active == b
    window.close(tab: b)
    #expect(window.tabs.count == 1)
    #expect(window.activeTab === a)
    window.close(tab: a)        // refused — a window always keeps ≥1 tab
    #expect(window.tabs.count == 1)
  }
}
