//
//  GalleyBridgeRequest.swift
//  Galley
//
//  Created by Anton Leuski on 5/29/26.
//

import Foundation

/// Pure normalization of inbound URLs from `application(_:open:)` and
/// the custom `galley://` scheme into the canonical file URL the
/// dispatch pipeline expects.
///
/// `galley://settings` is recognized and surfaced separately so the
/// caller can route it to SwiftUI's `openSettings()` instead of
/// trying to open it as a document.

/// URL scheme used by `Galley.app` (Viewer) to hand a file back to
/// `Galley Server.app` for AVP dispatch. The inverse direction of
/// `galley://` (which Server uses to hand a file to the Viewer).
///
/// Why a custom scheme instead of
/// `NSWorkspace.shared.open(_:withApplicationAt:configuration:)`:
/// the workspace API returns success without delivering
/// `kAEOpenDocuments` to the target's `application(_:open:)` —
/// observed live; the completion handler's `app` is the target PID
/// with `error=nil`, but the target never sees the URL. Routing by
/// URL scheme avoids the cross-process AppleEvent delivery
/// altogether: LaunchServices hands the URL to Server's
/// `application(_:open:)` directly.
public struct GalleyBridgeRequest: Sendable, Equatable,
                                   CustomStringConvertible
{
  public static let scheme = "galley-bridge"

  public let target: DocumentTarget

  public var description: String {
    url.absoluteString
  }

  public init(target: DocumentTarget) {
    self.target = target
  }

  public init?(from url: URL) {
    guard url.scheme?.lowercased() == Self.scheme
    else { return nil }
    let components = URLComponents(
      url: url,
      resolvingAgainstBaseURL: false)
    guard let target = DocumentTarget.init(components: components)
    else { return nil }
    self.target = target
  }

  public var url: URL {
    target.url(scheme: Self.scheme)
  }
}
