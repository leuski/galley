import Foundation
import KosmosCore
import KosmosTransport
import Loom

/// Which Galley surface a Kosmos peer represents. Published as the
/// standard `kosmos.role` metadata on the peer's Loom advertisement so
/// other peers can classify each other without an extra Kosmos
/// message.
public enum GalleyKosmosRole: String, Sendable {
  case server
  case macViewer = "mac-viewer"
  case visionViewer = "vision-viewer"

  fileprivate var loomDeviceType: DeviceType {
    switch self {
    case .server, .macViewer: .mac
    case .visionViewer: .vision
    }
  }

  fileprivate var defaultDeviceName: String {
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

  /// UserDefaults key used to persist this surface's Kosmos deviceID.
  /// Each surface gets its own UUID — colliding would have two surfaces
  /// share an identity on the wire, which the link doesn't expect.
  fileprivate var deviceIDKey: String {
    "net.leuski.galley.\(rawValue).kosmos.deviceID"
  }
}

/// Per-app persisted device identifier — thin wrapper around the
/// generic `KosmosClient.persistentDeviceID(forKey:)` to keep the
/// `role`-typed call site here.
public func loadOrMakeGalleyDeviceID(role: GalleyKosmosRole) -> UUID {
  KosmosClient.persistentDeviceID(forKey: role.deviceIDKey)
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

/// Construct a Loom-backed `KosmosClient` for the given Galley
/// surface. Pump is already running on return so registrations land
/// before any peer connects. Caller registers handlers and then
/// `try await link.start()`.
public func makeGalleyKosmosClient(
  role: GalleyKosmosRole,
  deviceID: UUID,
  deviceName: String? = nil,
  extraMetadata: [String: String] = [:]
) async -> (client: KosmosClient, link: LoomKosmosLink) {
  await KosmosClient.makeLoomBacked(
    role: role.rawValue,
    product: "galley",
    deviceID: deviceID,
    deviceName: deviceName ?? role.defaultDeviceName,
    deviceType: role.loomDeviceType,
    extraMetadata: extraMetadata)
}

extension PeerInfo {
  /// `kosmos.role` metadata mapped back to the typed enum.
  public var galleyRole: GalleyKosmosRole? {
    role.flatMap(GalleyKosmosRole.init)
  }

  /// HTTP base URL the Server published in its advertisement
  /// metadata. `nil` for non-server peers, for servers that haven't
  /// finished binding yet, or when the metadata is malformed.
  public var galleyHTTPURL: URL? {
    metadata[GalleyKosmosMetadataKey.httpURL].flatMap(URL.init(string:))
  }
}

/// Pure peer-classification helpers, kept out of the live Kosmos
/// services so they're unit-testable without spinning up a real
/// Kosmos client. The instance accessors on each surface delegate
/// here.
public enum GalleyPeerClassifier {
  /// First reachable Server whose `kosmos.host` matches `localHostUUID`.
  /// Peers with the same role on other Macs are visible in the peer
  /// set but ignored — the Mac Viewer should only pair with *its own*
  /// local Server. When `localHostUUID` is nil (the visionOS slice
  /// has no `gethostuuid`) any Server peer is acceptable.
  public static func serverPeer(
    in peers: [PeerID: PeerInfo],
    localHostUUID: String?
  ) -> PeerID? {
    peers.values.first { info in
      guard info.galleyRole == .server else { return false }
      guard let local = localHostUUID, let theirs = info.hostUUID
      else { return true }
      return local == theirs
    }?.id
  }

  /// First visionViewer peer in the snapshot. Multi-AVP picker UX is
  /// out of scope for v1; "first reachable wins" matches the plan's
  /// default. Reachability is peer-set membership alone — Kosmos
  /// session liveness is the truth signal.
  public static func avpPeer(in peers: [PeerID: PeerInfo]) -> PeerID? {
    peers.values.first { $0.galleyRole == .visionViewer }?.id
  }
}

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
