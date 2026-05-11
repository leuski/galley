//
//  URL+.swift
//  Galley
//
//  Created by Anton Leuski on 5/3/26.
//

import Foundation

extension URL {
  public var hostAndPort: String {
    host.map { host in
      host + (port.map { port in ":\(port)" } ?? "")
    } ?? ""
  }

  public var safe: URL {
    isFileURL ? standardizedFileURL.resolvingSymlinksInPath() : self
  }

  public var isInMainBundle: Bool {
    safe.path.hasPrefix(Bundle.main.bundleURL.safe.path)
  }

  public var galleyPreview: URL {
    appending(path: RouteNames.preview)
  }

  public func galleyTemplate(id: String) -> URL {
    appending(path: RouteNames.template).appending(path: id)
  }

  /// `<self>/preview` — the route prefix for previewed documents.
  /// Pass `documentPath` to point at a specific document.
  public func appendingPreview(_ documentURL: URL) -> URL {
    galleyPreview.appending(path: documentURL.safe.path)
  }

  /// `<self>/template/<id>` — the route prefix for template assets.
  /// Pass `file` to point at a specific asset.
  public func appendingTemplate(id: String, file documentURL: URL) -> URL {
    galleyTemplate(id: id).appending(path: documentURL.safe.path)
  }
}
