//
//  Activities.swift
//  Galley
//
//  Created by Anton Leuski on 5/31/26.
//

import Foundation
@_exported import KosmosAppKit

public struct OpenDocumentActivity: URLSerializable, Hashable {
  /// Document scheme — `galley://<path>`, routed to the document
  /// `WindowGroup` (plain `file://` documents route there too).
  public static let scheme = "galley"

  public let target: DocumentTarget
  public var documentURL: URL { target.documentURL }
  public var scrollLine: Int? { target.scrollLine }

  public init(target: DocumentTarget) {
    self.target = target
  }

  public init(url: URL, scrollLine: Int? = nil) {
    self.target = .init(url: url, scrollLine: scrollLine)
  }

  public init?(from url: URL) {
    guard let target = DocumentTarget(from: url, scheme: Self.scheme) else {
      return nil
    }
    self.target = target
  }

  public var url: URL {
    if let url = target.url(scheme: Self.scheme) {
      return url
    }
    preconditionFailure("GalleyDocumentTarget produced no url")
  }
}

/// Tabs of the Viewer's Settings scene. Carried on inbound
/// `galley://settings?tab=<id>` URLs so external callers (e.g. the
/// Server app's menu bar) can deep-link into a specific pane.
public enum SettingsTab: String, Sendable, CaseIterable {
  case general
  case markdown
  case server
}

public struct OpenSettingsActivity: URLSerializable, Hashable {
  public static let scheme = "galley-settings"
  public let tab: SettingsTab?
  public init(_ tab: SettingsTab? = nil) {
    self.tab = tab
  }
  public init?(from url: URL) {
    guard
      let components = URLComponents(
        url: url, resolvingAgainstBaseURL: false),
      components.scheme == Self.scheme
    else
    {
      return nil
    }
    self.tab = components.queryItems?
      .first(where: { $0.name == "tab" })
      .flatMap { $0.value }
      .flatMap { SettingsTab(rawValue: $0.lowercased()) }
  }
  public var url: URL {
    var components = URLComponents()
    components.scheme = Self.scheme
    components.host = ""
    if let tab {
      components.queryItems = [URLQueryItem(name: "tab", value: tab.rawValue)]
    }
    guard let url = components.url else {
      preconditionFailure("settingsURL components produced no URL")
    }
    return url
  }
}

public struct OpenHelpActivity: URLSerializable, Hashable {
  public static let scheme = "galley-help"
  public let documentURL: URL

  public init(documentURL: URL) {
    self.documentURL = documentURL
  }

  public init?(from url: URL) {
    guard
      let components = URLComponents(
        url: url, resolvingAgainstBaseURL: false),
      components.scheme == Self.scheme
    else
    {
      return nil
    }
    self.documentURL = URL(fileURLWithPath: components.path)
  }

  public var url: URL {
    var components = URLComponents()
    components.scheme = Self.scheme
    components.path = documentURL.path
    guard let url = components.url else {
      preconditionFailure("OpenHelpActivity components produced no URL")
    }
    return url
  }
}
