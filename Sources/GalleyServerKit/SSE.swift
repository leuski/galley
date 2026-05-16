import Foundation

enum SSE {
  static func encode(event: String? = nil, data: String) -> Data {
    var out = ""
    if let event { out += "event: \(event)\n" }
    for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
      out += "data: \(line)\n"
    }
    out += "\n"
    return Data(out.utf8)
  }

  static let keepAlive = Data(": keepalive\n\n".utf8)
}
