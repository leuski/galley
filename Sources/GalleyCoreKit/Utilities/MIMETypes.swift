import Foundation
import UniformTypeIdentifiers

public enum MIMETypes {
  public static func mimeType(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    // Source maps aren't registered as a UTType.
    if ext == "map" { return "application/javascript; charset=utf-8" }

    guard let type = UTType(filenameExtension: ext)?.preferredMIMEType else {
      return "application/octet-stream"
    }
    if needsCharset(type) {
      return "\(type); charset=utf-8"
    }
    return type
  }

  private static func needsCharset(_ type: String) -> Bool {
    type.hasPrefix("text/")
      || type == "application/json"
      || type == "application/javascript"
  }
}
