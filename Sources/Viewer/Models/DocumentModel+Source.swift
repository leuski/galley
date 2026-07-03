//
//  DocumentModel+Source.swift
//  Galley
//
//  Created by Anton Leuski on 5/16/26.
//

import Foundation

extension DocumentModel {
  /// Load the document source for `url`. File URLs are read
  /// directly; remote URLs are fetched via `URLSession` so the call
  /// doesn't block the main actor for the duration of the request.
  ///
  /// Decoding strategy: UTF-8 first; on failure, fall back to the
  /// response's advertised text encoding (if any). Remote responses
  /// with no advertised encoding default to UTF-8 — the
  /// spec-required default for `text/markdown` and the overwhelming
  /// convention in practice.
  static func readSource(at url: URL) async throws -> String {
    if url.isFileURL {
      let didStart = url.startAccessingSecurityScopedResource()
      defer {
        if didStart {
          url.stopAccessingSecurityScopedResource()
        }
      }
      return try String(contentsOf: url, encoding: .utf8)
    }
    let (data, response) = try await URLSession.shared.data(from: url)
    if let http = response as? HTTPURLResponse,
       (400..<600).contains(http.statusCode)
    {
      throw URLError(
        .badServerResponse,
        userInfo: [
          NSURLErrorFailingURLErrorKey: url,
          NSLocalizedDescriptionKey:
            "HTTP \(http.statusCode) for \(url.absoluteString)"
        ])
    }
    if let text = String(data: data, encoding: .utf8) {
      return text
    }
    if let name = response.textEncodingName,
       let cfName = CFStringConvertIANACharSetNameToEncoding(
         name as CFString) as CFStringEncoding?,
       cfName != kCFStringEncodingInvalidId
    {
      let encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(cfName))
      if let text = String(data: data, encoding: encoding) {
        return text
      }
    }
    throw CocoaError(.fileReadInapplicableStringEncoding)
  }
}
