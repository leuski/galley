import Foundation

public protocol TemplateProtocol: Identifiable, Sendable {
  var id: String { get }
  var name: String { get }
  func loadHTML() throws -> String
  func rewriteAssets(in html: String, origin: URL) -> String
  func resolveAsset(file: String) -> URL?
}

public enum Template: TemplateProtocol, CustomStringConvertible {
  case builtIn(BuiltInTemplate)
  case userDefined(UserTemplate)

  public var description: String { name }

  public var id: String {
    switch self {
    case .builtIn(let value): value.id
    case .userDefined(let value): value.id
    }
  }

  public var name: String {
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
