import Foundation

extension String {
  public var percentEncodedForPath: String {
    addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
  }

  public var appendingSlash: String {
    self.hasSuffix("/") ? self : (self + "/")
  }
}

extension URL {
  public var hostAndPort: String {
    host.map { host in
      host + (port.map { port in ":\(port)" } ?? "")
    } ?? ""
  }

  public var safe: URL {
    standardizedFileURL.resolvingSymlinksInPath()
  }

  /// `<self>/preview` — the route prefix for previewed documents.
  /// Pass `documentPath` to point at a specific document.
  public func appendingPreviewPath(_ documentPath: String? = nil) -> URL {
    let base = appending(path: RouteNames.preview)
    return documentPath.map { base.appending(path: $0) } ?? base
  }

  /// `<self>/template/<id>` — the route prefix for template assets.
  /// Pass `file` to point at a specific asset.
  public func appendingTemplatePath(id: String, file: String? = nil) -> URL {
    let base = appending(path: RouteNames.template).appending(path: id)
    return file.map { base.appending(path: $0) } ?? base
  }
}
