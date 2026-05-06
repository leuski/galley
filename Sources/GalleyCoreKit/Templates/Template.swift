import Foundation

public protocol TemplateProtocol: Identifiable, Sendable {
  var id: String { get }
  /// User-visible label for menus / pickers. Returning
  /// `LocalizedStringResource` follows Apple's pattern for
  /// domain types (see `CustomLocalizedStringResourceConvertible`)
  /// and decouples the kit from SwiftUI. Translatable cases
  /// (`BuiltInTemplate`'s "Default") use a literal init so the
  /// catalog picks them up; user-defined templates use a runtime
  /// `LocalizationValue` so their filenames don't pollute the
  /// strings catalog.
  var name: LocalizedStringResource { get }
  func loadHTML() throws -> String
  func rewriteAssets(in html: String, origin: URL) -> String
  func resolveAsset(file: String) -> URL?
}

public enum Template: TemplateProtocol,
                      CustomLocalizedStringResourceConvertible
{
  case builtIn(BuiltInTemplate)
  case userDefined(UserTemplate)

  /// `CustomStringConvertible` resolves the localizable name through
  /// the current locale. Used for diagnostic logs and the
  /// `PersistentChoiceValue` envelope's `name` field — neither cares
  /// which locale won.
  public var localizedStringResource: LocalizedStringResource {
    name
  }

  public var id: String {
    switch self {
    case .builtIn(let value): value.id
    case .userDefined(let value): value.id
    }
  }

  public var name: LocalizedStringResource {
    switch self {
    case .builtIn(let value): value.name
    case .userDefined(let value): value.name
    }
  }

  public func loadHTML() throws -> String {
    switch self {
    case .builtIn(let value): try value.loadHTML()
    case .userDefined(let value): try value.loadHTML()
    }
  }

  public func rewriteAssets(in html: String, origin: URL) -> String {
    switch self {
    case .builtIn(let value): value.rewriteAssets(in: html, origin: origin)
    case .userDefined(let value): value.rewriteAssets(in: html, origin: origin)
    }
  }

  public func resolveAsset(file: String) -> URL? {
    switch self {
    case .builtIn(let value): value.resolveAsset(file: file)
    case .userDefined(let value): value.resolveAsset(file: file)
    }
  }
}

public extension Template {
  static var `default`: Template { .builtIn(.shared) }
}
