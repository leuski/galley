import Foundation

/// Pure builders for the URLs the Server publishes to peers over
/// Kosmos. Lives here instead of inside `KosmosLink` so the policy
/// decisions are independent of `LANHostDiscovery`, `ServerPortFile`,
/// and any disk / network side-effects — callers inject the parts.
///
/// The two builders intentionally encode *different* policies for the
/// HTTPS-missing case:
///
/// - `avpDocumentURL` is for a Kosmos `OpenDocument` message addressed
///   to an AVP peer. HTTPS-only. **Never falls back to HTTP**, because
///   the Server's HTTP listener is loopback-only by design — a URL
///   like `http://<lan-host>:<loopback-port>/...` points at a closed
///   port from any LAN peer. The right behavior when HTTPS isn't up
///   is to refuse to dispatch, not to produce a URL that looks
///   plausible and silently doesn't work.
///
/// - `advertisementURL` is for a `BridgeAdvertisement` payload, which
///   is informational. HTTPS preferred; HTTP is accepted so a
///   loopback-only Server can still advertise its presence to peers
///   that won't use the URL for data-plane traffic.
public enum BridgeURLBuilder {
  /// Composes a final URL from `(scheme, host, port)`. Injected so
  /// callers can plug in their own IPv6-bracketing / zone-id handling
  /// (e.g. `LANHostDiscovery.composeURL`) without this type having to
  /// depend on it.
  public typealias Composer = (
    _ scheme: String, _ host: String, _ port: UInt16
  ) -> URL?

  /// URL to send to an AVP peer in an `OpenDocument` message. Returns
  /// nil if HTTPS isn't bound on the LAN or no reachable host is
  /// known. Never returns an HTTP URL — see type-level comment.
  public static func avpDocumentURL(
    host: String?,
    httpsPort: UInt16?,
    compose: Composer
  ) -> URL? {
    guard let host, let httpsPort else { return nil }
    return compose("https", host, httpsPort)
  }

  /// Picks the host most likely to be reachable from an AVP Kosmos
  /// peer, given the candidate list typically produced by
  /// `LANHostDiscovery.reachableHosts()`.
  ///
  /// Rationale: an AVP that's a Kosmos peer is always on the AWDL
  /// peer-to-peer Wi-Fi link with this Mac. AWDL is independent of
  /// any infrastructure Wi-Fi association. A Bonjour hostname like
  /// `<name>.local` only resolves on AVP when AVP and Mac are also
  /// on the same AP — AVP's `mDNSResponder` can't resolve hostname
  /// records carried over AWDL. Using the AWDL-scoped IPv6 link-local
  /// host directly bypasses the mDNS dependency and works in both
  /// states.
  ///
  /// Selection rule, in order:
  /// 1. First IPv6 link-local host whose zone-id is `awdl0` (or any
  ///    `awdl*` interface — match is case-insensitive on `%awdl`).
  /// 2. Otherwise, the first candidate. On a shared AP that's the
  ///    Bonjour hostname; AVP can resolve it via standard mDNS.
  ///
  /// Returns nil only when the candidate list is empty.
  public static func preferredAVPHost(
    from candidates: [String]
  ) -> String? {
    candidates.first { isAWDLZonedHost($0) } ?? candidates.first
  }

  private static func isAWDLZonedHost(_ host: String) -> Bool {
    host.lowercased().contains("%awdl")
  }

  /// URL for a `BridgeAdvertisement` payload. HTTPS preferred,
  /// HTTP accepted. Returns nil only when there is no host, or no
  /// port at all.
  public static func advertisementURL(
    host: String?,
    httpPort: UInt16?,
    httpsPort: UInt16?,
    compose: Composer
  ) -> URL? {
    guard let host else { return nil }
    if let httpsPort { return compose("https", host, httpsPort) }
    if let httpPort { return compose("http", host, httpPort) }
    return nil
  }
}
