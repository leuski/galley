import Foundation
import Observation
import Testing

@testable import GalleyCoreKit
internal import ALFoundation

// MARK: - Test fixtures

/// Minimal `ChoiceValueProtocol` that doesn't depend on the real
/// catalogs so we can drive the source's values directly.
private struct TestValue: ChoiceValueProtocol,
                          CustomLocalizedStringResourceConvertible
{
  let id: String
  let label: String
  var persistentID: String { id }
  var description: String { label }
  var localizedStringResource: LocalizedStringResource {
    LocalizedStringResource(String.LocalizationValue("\(label)"))
  }
}

/// Envelope around `TestValue`. Picks up the default `persist`,
/// `decode`, `values`, `defaultElement`, `isResident` impls from the
/// `ChoiceValueEnvelopeProtocol` constrained extension.
private struct TestEnvelope: ChoiceValueEnvelopeProtocol,
                             RestorableChoiceValue, Sendable
{
  typealias Source = FakeSource
  let value: TestValue
  init(_ value: TestValue) { self.value = value }
}

/// Observable source whose catalog can be mutated mid-test to
/// simulate async catalog discovery, removals, and additions.
@Observable @MainActor
private final class FakeSource: ChoiceModelSource<TestValue> {
  var values: [TestValue]
  var defaultValue: TestValue

  init(values: [TestValue], defaultValue: TestValue) {
    self.values = values
    self.defaultValue = defaultValue
  }
}

private typealias TestChoice = ConcreteChoiceModel<TestEnvelope, FakeSource>
private typealias TestSceneChoice = SceneChoice<TestChoice>

private let dflt = TestValue(id: "default", label: "Default")
private let alpha = TestValue(id: "alpha", label: "Alpha")
private let beta = TestValue(id: "beta", label: "Beta")
private let gamma = TestValue(id: "gamma", label: "Gamma")

// MARK: - Helpers

/// Poll a condition with a deadline. Auto-tracking, file watchers,
/// and `bindPersistent` all reconcile asynchronously, so most tests
/// can't assert immediately after a mutation.
@MainActor
private func waitFor(
  timeout: Duration = .seconds(2),
  description: String = "condition",
  _ condition: @MainActor () -> Bool
) async {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return }
    try? await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("waitFor timed out: \(description)")
}

@MainActor
private func makeTempDir() -> URL {
  let tmp = URL.temporaryDirectory
  / "ChoiceObservationTests-\(UUID().uuidString)"
  try? tmp.createDirectory()
  return tmp
}

@MainActor
private func writeFolderTemplate(at root: URL, name: String) throws {
  let folder = root / name
  try folder.createDirectory()
  try "<html></html>".write(
    to: folder / "Template.html",
    atomically: true, encoding: .utf8)
}

// MARK: - 1. Folder → TemplateStore

@Suite("TemplateStore observes its folder")
@MainActor
struct TemplateStoreObservationTests {

  @Test("reload() picks up a newly added folder template")
  func reloadPicksUpNewTemplate() throws {
    let tmp = makeTempDir()
    defer { try? tmp.remove() }
    let store = TemplateStore(directoryURLs: [tmp])

    #expect(store.templates.isEmpty)

    try writeFolderTemplate(at: tmp, name: "MyTheme")
    store.reload()

    #expect(store.templates.count == 1)
    #expect(store.templates.contains(where: { $0.id == "0.MyTheme" }))
  }

  @Test("reload() drops a deleted folder template")
  func reloadDropsDeletedTemplate() throws {
    let tmp = makeTempDir()
    defer { try? tmp.remove() }
    try writeFolderTemplate(at: tmp, name: "Doomed")
    let store = TemplateStore(directoryURLs: [tmp])
    #expect(store.templates.count == 1)

    try tmp.appending(path: "Doomed").remove()
    store.reload()

    #expect(store.templates.isEmpty)
  }

  @Test("multi-source: bundled and user templates with same name coexist")
  func multiSourceNoCollision() throws {
    let bundleSim = makeTempDir()
    let userSim = makeTempDir()
    defer {
      try? bundleSim.remove()
      try? userSim.remove()
    }
    try writeFolderTemplate(at: bundleSim, name: "Default")
    try writeFolderTemplate(at: userSim, name: "Default")
    let store = TemplateStore(directoryURLs: [bundleSim, userSim])

    let ids = store.templates.map(\.id).sorted()
    #expect(ids == ["0.Default", "1.Default"])
  }

  // Note: an FSEvents-driven watcher integration test is intentionally
  // omitted. FSEvents is unreliable for short-lived tmp directories
  // under `/var/folders/...` (latency, coalescing, exclusion lists),
  // and the observation chain it feeds — `reload()` mutating
  // `store.templates`, which propagates to `Choice.values` — is
  // already covered above by calling `reload()` directly.
}

// MARK: - 2. Store → Choice

@Suite("Choice observes its source")
@MainActor
struct ChoiceObservationTests {

  @Test("Choice.values reflects source mutations")
  func valuesFollowSource() {
    let source = FakeSource(values: [dflt, alpha], defaultValue: dflt)
    let choice = TestChoice(source: source, persistent: nil) { _ in }

    #expect(choice.values.map(\.value.id) == ["default", "alpha"])

    source.values = [dflt, alpha, beta]

    #expect(choice.values.map(\.value.id) == ["default", "alpha", "beta"])
  }

  @Test("removing the selected value heals to default and notifies")
  func autoHealOnRemoval() async {
    let source = FakeSource(values: [dflt, alpha], defaultValue: dflt)
    var notified: [String] = []
    let choice = TestChoice(
      source: source, persistent: nil) { notified.append($0) }

    let alphaEnv = choice.values.first { $0.value.id == "alpha" }!
    choice.selected = alphaEnv

    source.values = [dflt]  // remove alpha

    await waitFor(description: "selection heals to default") {
      choice.selected.value.id == "default"
    }
    #expect(notified == ["Alpha"])  // notifier receives the display name
  }

  @Test("notifier does not fire on unrelated catalog mutations")
  func noNotifyOnUnrelatedChanges() async {
    let source = FakeSource(
      values: [dflt, alpha, beta], defaultValue: dflt)
    var notified: [String] = []
    let choice = TestChoice(
      source: source, persistent: nil) { notified.append($0) }

    let alphaEnv = choice.values.first { $0.value.id == "alpha" }!
    choice.selected = alphaEnv

    // Add a new value; alpha stays present.
    source.values = [dflt, alpha, beta, gamma]

    try? await Task.sleep(for: .milliseconds(50))
    #expect(notified.isEmpty)
    #expect(choice.selected.value.id == "alpha")
  }
}

// MARK: - 3 + 4. Selection round-trip and persistence

@Suite("Choice persistence")
@MainActor
struct ChoicePersistenceTests {

  @Test("selection round-trips through `persistent`")
  func selectionPersists() {
    let source = FakeSource(
      values: [dflt, alpha, beta], defaultValue: dflt)
    let choice = TestChoice(source: source, persistent: nil) { _ in }

    let betaEnv = choice.values.first { $0.value.id == "beta" }!
    choice.selected = betaEnv
    let serialized = choice.persistent
    #expect(serialized != nil)

    let restored = TestChoice(
      source: source, persistent: serialized) { _ in }
    #expect(restored.selected.value.id == "beta")
  }

  @Test("assigning `persistent` decodes and updates `selected`")
  func setPersistentUpdatesSelected() {
    let source = FakeSource(
      values: [dflt, alpha, beta], defaultValue: dflt)
    let choice = TestChoice(source: source, persistent: nil) { _ in }

    let alphaSerialized = try? alpha.persisted
    choice.persistent = alphaSerialized
    #expect(choice.selected.value.id == "alpha")
  }

  @Test("assigning `persistent = nil` snaps to default")
  func setPersistentToNilResets() {
    let source = FakeSource(values: [dflt, alpha], defaultValue: dflt)
    let choice = TestChoice(source: source, persistent: nil) { _ in }
    let alphaEnv = choice.values.first { $0.value.id == "alpha" }!
    choice.selected = alphaEnv

    choice.persistent = nil

    #expect(choice.selected.value.id == "default")
  }

  @Test("assigning `persistent` to an unknown id fires the notifier")
  func setPersistentUnknownNotifies() {
    let source = FakeSource(values: [dflt, alpha], defaultValue: dflt)
    var notified: [String] = []
    let choice = TestChoice(
      source: source, persistent: nil) { notified.append($0) }

    let unknown = TestValue(id: "unknown", label: "Unknown")
    choice.persistent = try? unknown.persisted

    #expect(notified == ["Unknown"])
    #expect(choice.selected.value.id == "default")
  }

  @Test("assigning `persistent` to the settled value doesn't churn")
  func assignPersistentDedupe() async {
    let source = FakeSource(values: [dflt, alpha], defaultValue: dflt)
    let choice = TestChoice(source: source, persistent: nil) { _ in }
    let alphaEnv = choice.values.first { $0.value.id == "alpha" }!
    choice.selected = alphaEnv

    // Track changes to selected from this point forward.
    var changeCount = 0
    let token = onObservedChange(
      track: { _ = choice.selected },
      onChange: { changeCount += 1 })
    defer { token.cancel() }

    choice.persistent = choice.persistent  // round-trip

    try? await Task.sleep(for: .milliseconds(50))
    #expect(changeCount == 0)
    #expect(choice.selected.value.id == "alpha")
  }
}

// MARK: - In-flight hydration

@Suite("Choice hydrates in flight")
@MainActor
struct ChoiceHydrationTests {

  @Test("pending hydration consumes when the catalog populates")
  func pendingHydrationLandsLater() async {
    let source = FakeSource(values: [], defaultValue: dflt)
    var notified: [String] = []
    let choice = TestChoice(
      source: source,
      persistent: try? alpha.persisted) { notified.append($0) }

    // Catalog wasn't ready at init: pending stayed buffered.
    #expect(choice.selected.value.id == "default")
    #expect(notified.isEmpty)

    source.values = [dflt, alpha]

    await waitFor(description: "pending consumed") {
      choice.selected.value.id == "alpha"
    }
    #expect(notified.isEmpty)  // success, no displacement
  }

  @Test("pending hydration of a missing value notifies on populate")
  func pendingHydrationMissNotifies() async {
    let source = FakeSource(values: [], defaultValue: dflt)
    let unknown = TestValue(id: "unknown", label: "Unknown")
    var notified: [String] = []
    let choice = TestChoice(
      source: source,
      persistent: try? unknown.persisted) { notified.append($0) }

    #expect(notified.isEmpty)

    source.values = [dflt, alpha]  // catalog ready, "unknown" missing

    await waitFor(description: "missing-value notifier fires") {
      !notified.isEmpty
    }
    #expect(notified == ["Unknown"])
    #expect(choice.selected.value.id == "default")
  }
}

// MARK: - SceneChoice cascading from parent

@Suite("SceneChoice cascades from parent")
@MainActor
struct SceneChoiceCascadingTests {

  @Test(".local heals to .global when the value leaves parent catalog")
  func localHealsToGlobalOnRemoval() async {
    let source = FakeSource(
      values: [dflt, alpha, beta], defaultValue: dflt)
    let parent = TestChoice(source: source, persistent: nil) { _ in }
    var notified: [String] = []
    let scene = TestSceneChoice(
      source: parent, persistent: nil) { notified.append($0) }

    let localBeta = scene.values.first {
      if case .local(let env) = $0 { return env.value.id == "beta" }
      return false
    }!
    scene.selected = localBeta

    source.values = [dflt, alpha]  // beta gone

    await waitFor(description: "scene snaps to .global") {
      if case .global = scene.selected { return true }
      return false
    }
    #expect(notified == ["Beta"])  // display name
  }

  @Test(".local stays put when the parent's catalog gains a new value")
  func localStaysOnUnrelatedMutation() async {
    let source = FakeSource(values: [dflt, alpha], defaultValue: dflt)
    let parent = TestChoice(source: source, persistent: nil) { _ in }
    var notified: [String] = []
    let scene = TestSceneChoice(
      source: parent, persistent: nil) { notified.append($0) }

    let localAlpha = scene.values.first {
      if case .local(let env) = $0 { return env.value.id == "alpha" }
      return false
    }!
    scene.selected = localAlpha

    source.values = [dflt, alpha, beta]  // unrelated addition

    try? await Task.sleep(for: .milliseconds(50))
    if case .local(let env) = scene.selected {
      #expect(env.value.id == "alpha")
    } else {
      Issue.record("scene should still be .local(alpha)")
    }
    #expect(notified.isEmpty)
  }
}

// MARK: - bindPersistent (defaults sync)

@Suite("bindPersistent")
@MainActor
struct BindPersistentTests {

  @Observable @MainActor
  final class FakeDefaults {
    var slot: String?
  }

  @Test("choice change writes through to defaults")
  func outboundSync() async {
    let source = FakeSource(values: [dflt, alpha], defaultValue: dflt)
    let choice = TestChoice(source: source, persistent: nil) { _ in }
    let defaults = FakeDefaults()
    let tokens = bindPersistent(
      choice,
      read: { defaults.slot },
      write: { defaults.slot = $0 })
    defer { tokens.forEach { $0.cancel() } }

    let alphaEnv = choice.values.first { $0.value.id == "alpha" }!
    choice.selected = alphaEnv

    await waitFor(description: "defaults mirrors choice") {
      defaults.slot != nil && defaults.slot == choice.persistent
    }
  }

  @Test("defaults change writes through to choice")
  func inboundSync() async {
    let source = FakeSource(
      values: [dflt, alpha, beta], defaultValue: dflt)
    let choice = TestChoice(source: source, persistent: nil) { _ in }
    let defaults = FakeDefaults()
    let tokens = bindPersistent(
      choice,
      read: { defaults.slot },
      write: { defaults.slot = $0 })
    defer { tokens.forEach { $0.cancel() } }

    defaults.slot = try? beta.persisted

    await waitFor(description: "choice mirrors defaults") {
      choice.selected.value.id == "beta"
    }
  }

  @Test("missing-value heal cleans the stale defaults entry")
  func missingValueCleansDefaults() async {
    let source = FakeSource(values: [dflt, alpha], defaultValue: dflt)
    let choice = TestChoice(source: source, persistent: nil) { _ in }
    let defaults = FakeDefaults()
    let tokens = bindPersistent(
      choice,
      read: { defaults.slot },
      write: { defaults.slot = $0 })
    defer { tokens.forEach { $0.cancel() } }

    // Cross-process push of a stale id (peer process had this template,
    // we don't).
    let unknown = TestValue(id: "unknown", label: "Unknown")
    defaults.slot = try? unknown.persisted

    // Inbound observer pushes into the model, which heals to default.
    // Outbound observer (or the inbound's own settled-mirror) writes
    // the settled value back into defaults.
    await waitFor(description: "defaults gets cleaned") {
      defaults.slot == choice.persistent
    }
    #expect(choice.selected.value.id == "default")
  }
}
