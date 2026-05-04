import Foundation

extension String {
  public var percentEncodedForPath: String {
    addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
  }

  public var appendingSlash: String {
    self.hasSuffix("/") ? self : (self + "/")
  }
}
