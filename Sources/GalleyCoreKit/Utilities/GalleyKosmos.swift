import Foundation
import KosmosCore
import KosmosHTTPTunnel
import KosmosTransport

/// Which Galley surface a Kosmos peer represents. Published as the
/// standard `kosmos.role` metadata on the peer's Loom advertisement so
/// other peers can classify each other without an extra Kosmos
/// message.
extension KosmosServiceHost.Config {
  public static let product = "Galley"
  public static let server = Self.server(product: product)
  public static let macViewer = Self.macViewer(product: product)
  public static let visionViewer = Self.visionViewer(product: product)
}

extension PeerInfo.Key where Value == URL {
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
public struct RouteToAVPMarker {}
public typealias RouteToAVP = TargetMessage<RouteToAVPMarker>

public struct TargetMessage<Marker>: KosmosMessageWithReply, Equatable {
  public let target: DocumentTarget

  public init(target: DocumentTarget) {
    self.target = target
  }

  public struct Reply: KosmosMessage, Equatable {
    public let accepted: Bool

    public init(accepted: Bool) {
      self.accepted = accepted
    }
  }
}

public struct OpenInEditorMarker {}
public typealias OpenInEditor = TargetMessage<OpenInEditorMarker>

public typealias RouteToClientMessage = RouteToTunnelClient<DocumentTarget>

// MARK: - DocumentTarget ⇄ tunnel URL

extension DocumentTarget {
  /// The same document, addressed through `server`'s Kosmos tunnel:
  /// `kosmos://<server-id>/preview/<absolute-path>`. The Server builds
  /// this when it routes a file to a tunnel client, stamping its own
  /// id as the host so the client can address follow-ups (open in
  /// editor) straight back to the Mac that owns the file.
  /// `resolvingLocalTunnel(servedBy:)` is the inverse; keep the two
  /// together so the route shape can't drift.
  public func tunneled(via server: PeerID) -> DocumentTarget {
    DocumentTarget(
      url: TunnelScheme.originURL(forPeer: server)
        .appending(.documentAsset(documentURL)),
      scrollLine: scrollLine)
  }

  /// If this is a tunnel URL served by *this* Mac's own Server
  /// (`server` is the id the Server published into the shared
  /// defaults), rebind onto the local `file://` URL it wraps — the
  /// Mac Viewer renders its own machine's files in-process, and the
  /// window's represented document must be the file, not
  /// `kosmos://…/preview/…`. Anything else — a file URL, a tunnel URL
  /// from another Mac, no known local Server — comes back unchanged.
  public func resolvingLocalTunnel(
    servedBy server: DeviceID?) -> DocumentTarget
  {
    guard
      let server,
      documentURL.scheme == TunnelScheme.name,
      documentURL.host()?.lowercased() == server.description,
      case let .documentAsset(file)? = PreviewRoute(path: documentURL.path)
    else { return self }
    return DocumentTarget(url: file, scrollLine: scrollLine)
  }
}
