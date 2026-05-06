//
//  ChoiceModel.swift
//  GalleyKit
//
//  Created by Anton Leuski on 4/29/26.
//

import SwiftUI
import ALFoundation
import os

private let log = Logger(
  subsystem: bundleIdentifier, category: "Defaults")

public protocol ChoiceValueProtocol: CustomStringConvertible, Sendable {
  associatedtype PersistentID: Hashable, Codable
  var persistentID: PersistentID { get }
}

struct PersistentChoiceValue<Value>: Codable
where Value: ChoiceValueProtocol
{
  internal init(id: Value.PersistentID, name: String) {
    self.id = id
    self.name = name
  }

  let id: Value.PersistentID
  let name: String

  init(from string: String) throws {
    let decoder = JSONDecoder()
    self = try decoder.decode(Self.self, from: string.utf8Data)
  }

  /// Deterministic encoding — `.sortedKeys` matters because the
  /// encoded string is the on-disk identity used by `bindPersistent`
  /// to dedupe writes. Without sorted keys, a re-encode in another
  /// process can produce a string with the same semantic content but
  /// different field order, which `bindPersistent`'s string-equality
  /// dedup mistakes for "the other side disagrees" and writes back —
  /// and once the cross-process Darwin bridge is in place, the two
  /// sides ping-pong forever.
  var encoded: String {
    get throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return try encoder.encode(self).utf8String
    }
  }
}

extension ChoiceValueProtocol {
  var persisted: String {
    get throws {
      try PersistentChoiceValue<Self>(
        id: persistentID, name: description).encoded
    }
  }
}

public protocol ChoiceValueProtocolDecodingContext<Value>
where Value: ChoiceValueProtocol
{
  associatedtype Value
  func findValue(forID id: Value.PersistentID) -> Value?
}

enum AnyChoiceValueDecodingError: LocalizedError {
  case noContext
  case missingValue(String)
}

@MainActor
public protocol ChoiceValue: Hashable {
  /// User-visible label for menus / pickers / toggles. Returning
  /// `LocalizedStringResource` (Apple's recommended pattern for
  /// domain types — see `CustomLocalizedStringResourceConvertible`)
  /// lets the catalog pick up translatable phrases via the literal
  /// init, while data values (filenames, processor binary names)
  /// flow through `LocalizationValue("\(runtimeString)")` so they
  /// resolve verbatim without becoming spurious translator entries.
  ///
  /// View call sites: `Text(value.name)`.
  /// Diagnostic / displacement call sites: `String(localized: value.name)`.
  var name: LocalizedStringResource { get }
}

@MainActor
public protocol SectionedChoiceValue {
  var section: Int { get }
  var isAvailable: Bool { get }
}

public protocol ChoiceValueEnvelopeProtocol<Value>: ChoiceValue
{
  associatedtype Value: ChoiceValueProtocol
  nonisolated var value: Value { get }
  init (_ value: Value)
}

extension ChoiceValueEnvelopeProtocol {
  /// Default: wrap the inner value's `description` (which is data —
  /// processor binary name, template filename) as a runtime
  /// `LocalizationValue` so it resolves verbatim and isn't extracted
  /// into the translator catalog. Concrete envelopes whose inner type
  /// has a localizable name (e.g. `TemplateChoiceValue`, where
  /// `BuiltInTemplate` carries "Default") override this to delegate
  /// to the inner type's `LocalizedStringResource`.
  public var name: LocalizedStringResource {
    LocalizedStringResource(String.LocalizationValue("\(value.description)"))
  }
  nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.value.persistentID == rhs.value.persistentID
  }

  nonisolated public func hash(into hasher: inout Hasher) {
    hasher.combine(value.persistentID)
  }
}

@MainActor
public protocol ChoiceModel<Element> {
  associatedtype Element: ChoiceValue
  var values: [Element] { get }
  var selected: Element { get nonmutating set }
  /// The serialized form of the current selection. Read returns the
  /// pending hydration string (if one is buffered and not yet
  /// consumed) or the current selection's serialized form.
  /// Assigning hydrates: the model attempts to decode the new value
  /// and update `selected`. If the source's catalog isn't ready
  /// yet, the assignment is buffered and retried on the next
  /// observed source change. Assigning `nil` clears any pending
  /// hydration and snaps `selected` to the default.
  var persistent: String? { get nonmutating set }
}

public extension ChoiceModel {
  /// A `Toggle`-friendly binding that reports whether `value` is the
  /// current selection and selects it when toggled on.
  ///
  /// Works for both reference-type conformers (e.g. `TemplateChoice`)
  /// and value-type conformers whose `selected` setter is
  /// `nonmutating` and writes through external storage (e.g.
  /// `SceneTemplateChoice` writing through a `Binding`). A
  /// value-type conformer with a mutating setter cannot satisfy the
  /// closure capture, and won't compile here.
  func isSelectedBinding(_ value: Element) -> Binding<Bool> {
    Binding(
      get: { self.selected == value },
      set: { newValue in if newValue { self.selected = value } }
    )
  }
}

public protocol ChoiceModelEnvelope<Element>: ChoiceModel
where Element: ChoiceValueEnvelopeProtocol
{
  func findValue(forID id: Element.Value.PersistentID) -> Element.Value?
}

extension ChoiceModelEnvelope {
  func decode(_ persistent: String) throws -> Element {
    let persistent = try PersistentChoiceValue<Element.Value>(from: persistent)
    guard let value = findValue(forID: persistent.id)
    else {
      throw AnyChoiceValueDecodingError.missingValue(persistent.name)
    }
    return Element(value)
  }
}

@MainActor
public protocol ChoiceModelSource<Value>
{
  associatedtype Value: ChoiceValueProtocol
  var values: [Value] { get }
  var defaultValue: Value { get }
}

public protocol ChoiceModelObject: ChoiceModel, Hashable, AnyObject {
}

public extension ChoiceModelObject {
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
  }

  nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}

// MARK: - Restorable element

/// Element-level protocol that bundles all flavor-specific behavior
/// (option list, default, persistence, decoding, residency check).
/// One conforming element type per flavor; `Choice<Element>` is the
/// single class body that drives any flavor.
@MainActor
public protocol RestorableChoiceValue<Source>: ChoiceValue {
  associatedtype Source

  func persist() -> String?
  func isResident(in source: Source) -> Bool
  static func decode(_ persistent: String, from source: Source) throws -> Self
  static func values(from source: Source) -> [Self]
  static func defaultElement(from source: Source) -> Self

  /// Whether the source's underlying catalog has loaded enough data
  /// to make a real decision. Returning `false` defers hydration and
  /// healing until the next observed change. Default checks whether
  /// `values(from:)` is non-empty, which is right for the envelope
  /// flavor; the scene flavor overrides this to bypass its `.global`
  /// sentinel that would otherwise mask emptiness.
  static func isCatalogReady(_ source: Source) -> Bool
}

extension RestorableChoiceValue {
  public static func isCatalogReady(_ source: Source) -> Bool {
    !values(from: source).isEmpty
  }
}

/// Default behavior for envelope-style elements (one element per
/// catalog entry, persisted by the underlying value's persistentID).
extension RestorableChoiceValue
where Self: ChoiceValueEnvelopeProtocol,
      Source: ChoiceModelSource,
      Source.Value == Self.Value
{
  public func persist() -> String? { try? value.persisted }

  public func isResident(in source: Source) -> Bool {
    source.values.contains { $0.persistentID == value.persistentID }
  }

  public static func decode(
    _ persistent: String, from source: Source
  ) throws -> Self {
    let parsed = try PersistentChoiceValue<Value>(from: persistent)
    guard let value = source.values.first(
      where: { $0.persistentID == parsed.id })
    else {
      throw AnyChoiceValueDecodingError.missingValue(parsed.name)
    }
    return Self(value)
  }

  public static func values(from source: Source) -> [Self] {
    source.values.map { Self($0) }
  }

  public static func defaultElement(from source: Source) -> Self {
    Self(source.defaultValue)
  }
}

// MARK: - Unified Choice

/// Single class implementing every flavor of `ChoiceModel`. All
/// flavor-specific behavior lives on `Element: RestorableChoiceValue`.
///
/// Lifecycle:
/// - `init` records the persisted string as *pending* and runs one
///   reconcile pass. If the source's catalog is already loaded, the
///   pending string is consumed at init time. Otherwise it stays
///   pending and gets retried on each observed source change.
/// - `startTracking()` (auto-called by `init`) subscribes to the
///   source's observable surface. Each change triggers a reconcile:
///   first we try to consume any pending hydration, then we heal the
///   current selection if it's no longer resident in the source.
/// - `stopTracking()` cancels the subscription. The deinit cancels
///   too, so manual stops are only needed for early teardown.
@Observable @MainActor
final public class Choice<Element>: ChoiceModelObject
where Element: RestorableChoiceValue
{
  @ObservationIgnored private let source: Element.Source
  @ObservationIgnored private var pendingPersistent: String?
  @ObservationIgnored private let notifier: @MainActor (String) -> Void
  @ObservationIgnored private var observation: Cancelable?

  public var values: [Element] { Element.values(from: source) }
  public var selected: Element {
    didSet {
      logSelectedChange(from: oldValue.name, next: self.selected.name)
    }
  }
  /// See the protocol doc on `ChoiceModel.persistent`. The getter
  /// prefers a still-pending hydration string over the current
  /// selection's persisted form so an external observer that mirrors
  /// this property to storage doesn't clobber the user's pick during
  /// async catalog discovery (during which `selected` is still the
  /// default).
  public var persistent: String? {
    get { pendingPersistent ?? selected.persist() }
    set {
      logPersistentSet(incoming: newValue, current: self.selected.name)
      guard let newValue else {
        pendingPersistent = nil
        let dflt = Element.defaultElement(from: source)
        if selected != dflt { selected = dflt }
        return
      }
      // Already settled at this value? Skip the round-trip so a
      // bidirectional sync (e.g. defaults ↔ choice) doesn't churn.
      if pendingPersistent == nil, selected.persist() == newValue { return }
      pendingPersistent = newValue
      reconcile()
    }
  }

  public init(
    source: Element.Source,
    persistent: String?,
    notifier: @escaping @MainActor (String) -> Void
  ) {
    self.source = source
    self.notifier = notifier
    self.selected = Element.defaultElement(from: source)
    self.pendingPersistent = persistent
    reconcile()
    startTracking()
  }

  deinit { observation?.cancel() }

  /// Subscribe to the source's observable surface. Idempotent —
  /// calling again replaces the prior subscription. Auto-called by
  /// `init`; explicit invocation is only needed if you stopped
  /// tracking and want to resume.
  public func startTracking() {
    stopTracking()
    observation = onObservedChange(
      track: { [weak self] in
        guard let self else { return }
        // Touch the observable surface that determines residency
        // and hydration. Both flavors funnel through `values(from:)`.
        _ = Element.values(from: self.source)
      },
      onChange: { [weak self] in self?.reconcile() })
  }

  public func stopTracking() {
    observation?.cancel()
    observation = nil
  }

  /// One pass of (a) try to consume `pendingPersistent`, then (b)
  /// heal the current selection if displaced. Both steps require
  /// the catalog to be ready; if it isn't, we defer until the next
  /// observed change. Idempotent.
  private func reconcile() {
    guard Element.isCatalogReady(source) else { return }

    if let pending = pendingPersistent {
      pendingPersistent = nil
      do {
        let decoded = try Element.decode(pending, from: source)
        if decoded != selected { selected = decoded }
        return
      } catch AnyChoiceValueDecodingError.missingValue(let name) {
        notifier(name)
      } catch {
        // ignore the rest
      }
    }

    if !selected.isResident(in: source) {
      let displaced = String(localized: selected.name)
      selected = Element.defaultElement(from: source)
      notifier(displaced)
    }
  }

  /// Manual heal entry point for callers that don't track or want to
  /// force a check. Returns the displaced display name (resolved
  /// through the current locale), or nil when the current selection
  /// is still resident.
  @discardableResult
  public func healIfDisplaced() -> String? {
    if selected.isResident(in: source) { return nil }
    let displaced = String(localized: selected.name)
    selected = Element.defaultElement(from: source)
    return displaced
  }

  /// Logging helpers take `LocalizedStringResource` and resolve to
  /// `String` internally — the os_log substitution machinery only
  /// understands `String`, but every caller in `Choice` already has
  /// the resource in hand. Keeping the boundary inside the helper
  /// means call sites stay one line and don't repeat
  /// `String(localized:)` in a hot path.
  private func logSelectedChange(
    from: LocalizedStringResource, next: LocalizedStringResource
  ) {
    let pid = ProcessInfo.processInfo.processIdentifier
    let fromString = String(localized: from)
    let nextString = String(localized: next)
    log.debug("""
      Choice.selected pid=\(pid) \
      \(fromString, privacy: .public) → \(nextString, privacy: .public)
      """)
  }

  private func logPersistentSet(
    incoming: String?, current: LocalizedStringResource
  ) {
    let pid = ProcessInfo.processInfo.processIdentifier
    let currentString = String(localized: current)
    log.debug("""
      Choice.persistent set pid=\(pid) \
      incoming=\(incoming ?? "nil", privacy: .public) \
      current=\(currentString, privacy: .public)
      """)
  }
}

extension Choice: ChoiceModelEnvelope
where Element: ChoiceValueEnvelopeProtocol
{
  public func findValue(
    forID id: Element.Value.PersistentID
  ) -> Element.Value? {
    values.first(where: { $0.value.persistentID == id })?.value
  }
}

// MARK: - Persistence sync

/// Bidirectional bridge between a `ChoiceModel`'s `persistent` and an
/// external string-valued slot (typically a `@DefaultsKey` on a
/// `GalleyDefaults`-conforming class). Two observation loops:
///
/// - **Outbound**: when the choice's persistent string changes
///   (driven by `selected` mutating), write it through if it differs
///   from what's already stored.
/// - **Inbound**: when the external slot changes, push it into
///   `choice.persistent`. After any settling (in-flight hydration or
///   missing-value heal), mirror the settled value back if the choice
///   ended up at something different — this also cleans stale entries
///   out of storage when the persisted value wasn't found in the
///   catalog.
///
/// Returns the cancelable observation tokens; retain them for the
/// lifetime you want the binding active. Both sides dedupe writes so
/// the loop converges in one round-trip.
@MainActor
@discardableResult
public func bindPersistent<Choice>(
  _ choice: Choice,
  label: String = "",
  read: @escaping @MainActor () -> String?,
  write: @escaping @MainActor (String?) -> Void
) -> [Cancelable]
where Choice: ChoiceModel & AnyObject
{
  logBindInstall(
    label: label,
    initial: choice.persistent,
    stored: read())
  let outbound = onObservedChange(
    track: { [weak choice] in _ = choice?.persistent },
    onChange: { [weak choice] in
      guard let value = choice?.persistent else { return }
      let stored = read()
      if stored != value {
        logBindOutboundWrite(label: label, stored: stored, value: value)
        write(value)
      } else {
        logBindOutboundSkip(label: label, value: value)
      }
    })
  let inbound = onObservedChange(
    track: { _ = read() },
    onChange: { [weak choice] in
      guard let choice else { return }
      let incoming = read()
      logBindInboundIncoming(
        label: label,
        incoming: incoming,
        current: choice.persistent)
      if choice.persistent != incoming { choice.persistent = incoming }
      let settled = choice.persistent
      if settled != incoming {
        logBindInboundSettled(
          label: label, incoming: incoming, settled: settled)
        write(settled)
      }
    })
  return [outbound, inbound]
}

private var currentPID: Int32 {
  ProcessInfo.processInfo.processIdentifier
}

private func logBindInstall(
  label: String, initial: String?, stored: String?
) {
  log.debug("""
    bindPersistent[\(label, privacy: .public)] install pid=\(currentPID) \
    initial=\(initial ?? "nil", privacy: .public) \
    stored=\(stored ?? "nil", privacy: .public)
    """)
}

private func logBindOutboundWrite(
  label: String, stored: String?, value: String
) {
  log.debug("""
    bindPersistent[\(label, privacy: .public)] OUT pid=\(currentPID) \
    write \(stored ?? "nil", privacy: .public) \
    → \(value, privacy: .public)
    """)
}

private func logBindOutboundSkip(label: String, value: String) {
  log.debug("""
    bindPersistent[\(label, privacy: .public)] OUT pid=\(currentPID) \
    skip (\(value, privacy: .public))
    """)
}

private func logBindInboundIncoming(
  label: String, incoming: String?, current: String?
) {
  log.debug("""
    bindPersistent[\(label, privacy: .public)] IN pid=\(currentPID) \
    incoming=\(incoming ?? "nil", privacy: .public) \
    current=\(current ?? "nil", privacy: .public)
    """)
}

private func logBindInboundSettled(
  label: String, incoming: String?, settled: String?
) {
  log.debug("""
    bindPersistent[\(label, privacy: .public)] IN pid=\(currentPID) \
    settled→stored \(incoming ?? "nil", privacy: .public) \
    → \(settled ?? "nil", privacy: .public)
    """)
}

// MARK: - Concrete flavor

public typealias ConcreteChoiceModel<Element, Source>
  = Choice<Element>
where Element: ChoiceValueEnvelopeProtocol & RestorableChoiceValue & Sendable,
      Source: ChoiceModelSource<Element.Value>,
      Element.Source == Source

// MARK: - Scene flavor

public enum SceneChoiceValueEnvelope<Choice>: ChoiceValue
where Choice: ChoiceModel & Equatable & Hashable
{
  case local(Choice.Element)
  case global(Choice)

  nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.local(let lhs), .local(let rhs)):
      return lhs == rhs
    case (.global(let lhs), .global(let rhs)):
      return lhs == rhs
    default:
      return false
    }
  }

  nonisolated public func hash(into hasher: inout Hasher) {
    switch self {
    case .local(let value):
      0.hash(into: &hasher)
      value.hash(into: &hasher)
    case .global(let value):
      1.hash(into: &hasher)
      value.hash(into: &hasher)
    }
  }

  public var name: LocalizedStringResource {
    switch self {
    case .local(let value):
      value.name
    case .global(let value):
      // The "Global (…)" wrapper is a localizable phrase; the inner
      // selection name is data (resolve it now and substitute in via
      // `String.LocalizationValue` interpolation, which the catalog
      // captures as a single "Global (%@)" key).
      LocalizedStringResource(
        "Global (\(String(localized: value.selected.name)))",
        bundle: .galleyCoreKit)
    }
  }
}

extension SceneChoiceValueEnvelope where Choice: ChoiceModelEnvelope {
  /// The underlying domain value (e.g. `Processor`, `Template`),
  /// resolved through the scene-local pick or — when set to
  /// `.global(source)` — through the source's current selection.
  public var value: Choice.Element.Value {
    switch self {
    case .local(let element):
      return element.value
    case .global(let choice):
      return choice.selected.value
    }
  }
}

extension SceneChoiceValueEnvelope: SectionedChoiceValue
where Choice.Element: SectionedChoiceValue
{
  public var section: Int {
    switch self {
    case .local(let value):
      return value.section
    case .global:
      return -1
    }
  }

  public var isAvailable: Bool {
    switch self {
    case .local(let value):
      return value.isAvailable
    case .global:
      return true
    }
  }
}

extension SceneChoiceValueEnvelope: RestorableChoiceValue
where Choice: ChoiceModelEnvelope
{
  public typealias Source = Choice

  public func persist() -> String? {
    switch self {
    case .global:
      return nil
    case .local(let value):
      return try? value.value.persisted
    }
  }

  public func isResident(in source: Choice) -> Bool {
    switch self {
    case .global:
      return true
    case .local(let value):
      return source.findValue(forID: value.value.persistentID) != nil
    }
  }

  public static func decode(
    _ persistent: String, from source: Choice
  ) throws -> Self {
    .local(try source.decode(persistent))
  }

  public static func values(from source: Choice) -> [Self] {
    [.global(source)] + source.values.map { .local($0) }
  }

  public static func defaultElement(from source: Choice) -> Self {
    .global(source)
  }

  /// Bypass the `.global` sentinel — readiness is about the parent's
  /// underlying catalog, not the augmented option list (which is
  /// never empty thanks to `.global`).
  public static func isCatalogReady(_ source: Choice) -> Bool {
    !source.values.isEmpty
  }
}

public typealias SceneChoice<Source>
  = Choice<SceneChoiceValueEnvelope<Source>>
where Source: ChoiceModelEnvelope & Hashable
