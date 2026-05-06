import Foundation

public struct BuiltInTemplate: TemplateProtocol {
  public static let id = "__builtin__"
  public static let shared = BuiltInTemplate()

  public var id: String { Self.id }
  /// "Default" is a translatable label; the literal
  /// `LocalizedStringResource` init lets Xcode lift it into the
  /// strings catalog on build.
  public var name: LocalizedStringResource { "Default" }

  public func loadHTML() throws -> String { Self.html }

  public func rewriteAssets(in html: String, origin: URL) -> String { html }

  public func resolveAsset(file: String) -> URL? { nil }

  private final class Helper: NSObject {}

  private static let html: String = Bundle(for: Helper.self).requiredString(
    forResource: "DefaultTemplate", withExtension: "html")
}
