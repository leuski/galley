import Foundation

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
