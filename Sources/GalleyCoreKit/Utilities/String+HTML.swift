import Foundation
import ALFoundation

extension String {
  public var htmlEscaped: String {
    var out = ""
    out.reserveCapacity(count)
    for char in self {
      switch char {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      default: out.append(char)
      }
    }
    return out
  }

  public var htmlAttributeEscaped: String {
    var out = ""
    out.reserveCapacity(count)
    for char in self {
      switch char {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      case "\"": out += "&quot;"
      case "'": out += "&#39;"
      default: out.append(char)
      }
    }
    return out
  }
}

extension StringProtocol {
  public func substituting(
    substitutions: KeyValuePairs<String, String>) -> String
  {
    var string = asString()
    for (key, value) in substitutions {
      string = string.replacingOccurrences(of: key, with: value)
    }
    return string
  }
}
