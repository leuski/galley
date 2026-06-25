//
//  DcoumentTarget.swift
//  GalleyCoreKit
//
//  Created by Anton Leuski on 5/31/26.
//

import Foundation

public struct DocumentTarget: Sendable, Hashable, Codable,
                              CustomStringConvertible
{
  private static let lineArgument = "line"
  private static let urlArgument = "url"

  public let documentURL: URL
  public let scrollLine: Int?

  public var description: String {
    "\(documentURL)\(scrollLine.map(\.description) ?? "")"
  }

  public init(url: URL, scrollLine: Int? = nil) {
    self.documentURL = url
    self.scrollLine = scrollLine
  }

  public init?(from url: URL, scheme: String) {
    if url.isFileURL {
      self.init(url: url, scrollLine: nil)
      return
    }

    guard
      let components = URLComponents(
        url: url, resolvingAgainstBaseURL: false),
      components.scheme == scheme
    else
    {
      return nil
    }

    func parseURL() -> URL? {
      let urlString = components.queryItems?
        .first(where: { $0.name == Self.urlArgument })
        .flatMap { $0.value }

      if let urlString {
        return URL(string: urlString)
      }
      // A document scheme with no path carries no document — reject it
      // rather than fabricating a file URL from an empty path.
      guard !components.path.isEmpty else { return nil }
      return URL(fileURLWithPath: components.path)
    }

    guard let documentURL = parseURL() else { return nil }

    let line = components.queryItems?
      .first(where: { $0.name == Self.lineArgument })
      .flatMap { $0.value }
      .flatMap(Int.init)
      .flatMap { $0 > 0 ? $0 : nil }

    self.init(url: documentURL, scrollLine: line)
  }

  public func url(scheme: String) -> URL? {
    var components = URLComponents()
    components.scheme = scheme.lowercased()
    var queryItems = [URLQueryItem]()
    if documentURL.isFileURL {
      components.path = documentURL.path
    } else {
      queryItems.append(
        URLQueryItem(
          name: Self.urlArgument,
          value: documentURL.absoluteString
        )
      )
    }
    if let line = scrollLine {
      queryItems.append(URLQueryItem(name: Self.lineArgument, value: "\(line)"))
    }
    if !queryItems.isEmpty {
      components.queryItems = queryItems
    }
    return components.url
  }
}
