import Foundation
import KosmosCore
import KosmosTransport

/// Which Galley surface a Kosmos peer represents. Published as the
/// standard `kosmos.role` metadata on the peer's Loom advertisement so
/// other peers can classify each other without an extra Kosmos
/// message.
public enum GalleyKosmosRole: String, Role {
  case server
  case macViewer = "mac-viewer"
  case visionViewer = "vision-viewer"

  public var product: String {
    "galley"
  }

  public var identifier: String {
    rawValue
  }

  public var deviceType: DeviceType {
    switch self {
    case .server, .macViewer: .mac
    case .visionViewer: .vision
    }
  }

  public var defaultDeviceName: String {
    switch self {
#if os(macOS)
    case .server: Host.current().localizedName ?? "Galley Server"
    case .macViewer: Host.current().localizedName ?? "Galley"
#else
    case .server: "Galley Server"
    case .macViewer: "Galley"
#endif
    case .visionViewer: "Apple Vision Pro"
    }
  }
}

/// Galley-specific Kosmos peer-metadata keys. Keep in sync with the
/// accessors on `PeerInfo` below — the keys are the wire shape.
public enum GalleyKosmosMetadataKey {
  /// Server's loopback HTTP base URL (`http://127.0.0.1:<port>`),
  /// published once the listener has bound. Consumers read it via
  /// `PeerInfo.galleyHTTPURL` so Kosmos peers don't need to dip
  /// into the shared `net.leuski.galley` defaults just to learn the
  /// port — same value, different transport.
  public static let httpURL = "galley.http-url"
}

extension PeerInfo {
  /// HTTP base URL the Server published in its advertisement
  /// metadata. `nil` for non-server peers, for servers that haven't
  /// finished binding yet, or when the metadata is malformed. The
  /// metadata key is product-namespaced, so this is safe against
  /// sibling products on the shared mesh.
  public var galleyHTTPURL: URL? {
    metadata[GalleyKosmosMetadataKey.httpURL].flatMap(URL.init(string:))
  }
}

// Peer classification (server-by-host, AVP-by-device-type) and AVP
// reachability now live on `KosmosServiceHost` as product-scoped
// queries (`presentPeer(role:onHost:)`, `reachablePeer(deviceType:)`).
// The old `GalleyPeerClassifier` + `PeerInfo.galleyRole` were product-
// blind — they matched any product's `kosmos.role == "server"` — and
// were removed when reachability moved into the host.

/// Mac Viewer → Server. "User chose Show on Vision Pro — please
/// dispatch this file." Server's `RouteToAVP` handler resolves the
/// filepath to a URL and runs it through the same dispatch path
/// `application(_:open:)` already uses.
public struct RouteToAVP: KosmosMessage, Equatable {
  public static let messageType = "net.leuski.galley.route-to-avp.v1"

  public let target: DocumentTarget

  public init(target: DocumentTarget) {
    self.target = target
  }

  public struct Reply: KosmosMessage, Equatable {
    public static let messageType =
      "net.leuski.galley.route-to-avp.reply.v1"

    public let accepted: Bool

    public init(accepted: Bool) {
      self.accepted = accepted
    }
  }
}
