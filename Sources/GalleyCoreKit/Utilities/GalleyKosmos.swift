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
    case .server: Host.current().localizedName ?? "Galley"
    case .macViewer: Host.current().localizedName ?? "Mac"
#else
    case .server: "Galley"
    case .macViewer: "Mac"
#endif
    case .visionViewer: "Apple Vision Pro"
    }
  }
}

extension PeerInfo.Metadata.Key where Value == URL {
  /// Server's loopback HTTP base URL (`http://127.0.0.1:<port>`),
  /// published in peer metadata once the listener has bound, and read
  /// back as `peer.metadata[.httpURL]`. Lets Kosmos peers learn the
  /// port without dipping into the shared `net.leuski.galley` defaults
  /// — same value, different transport. The wire key is
  /// product-namespaced (`galley.http-url`), so it's safe against
  /// sibling products on the shared mesh.
  public static let httpURL: Self = "galley.http-url"
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

/// Mac Viewer → Server. "Show on Vision Pro". The reply
/// reports whether a reachable AVP peer accepted it, so the Mac Viewer
/// can fall back to local presentation when it didn't.
public struct RouteToTunnelClient: KosmosMessage, Equatable {
  public static let messageType = "net.leuski.galley.route-to-tunnel-client.v1"

  public let target: DocumentTarget
  public let deviceType: DeviceType?

  public init(target: DocumentTarget, deviceType: DeviceType? = nil) {
    self.target = target
    self.deviceType = deviceType
  }

  public struct Reply: KosmosMessage, Equatable {
    public static let messageType
    = "net.leuski.galley.route-to-tunnel-client.reply.v1"

    public let accepted: Bool

    public init(accepted: Bool) {
      self.accepted = accepted
    }
  }
}
