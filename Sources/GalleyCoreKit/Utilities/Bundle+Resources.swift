import Foundation

extension Bundle {
  public func requiredString(
    forResource name: String, withExtension ext: String
  ) -> String {
    guard
      let url = url(forResource: name, withExtension: ext),
      let string = try? String(contentsOf: url, encoding: .utf8)
    else {
      fatalError("\(name).\(ext) missing from bundle")
    }
    return string
  }
}
