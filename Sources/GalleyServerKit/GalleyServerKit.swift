// GalleyServerKit — embeddable HTTP preview server built on top of
// GalleyCoreKit. Public surface is the PreviewServerController in
// PreviewServer.swift; everything else (Routes, SSE, MIMETypes,
// HTTPResponses) is internal to this module.
import Foundation
@_exported import KosmosHTTPServer

private final class Helper: NSObject {}

public extension Bundle {
  static let galleyServerKit = Bundle(for: Helper.self)
}
