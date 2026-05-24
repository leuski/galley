#if os(visionOS)
import Foundation
import GalleyCoreKit
import KosmosWebView
import Network
import Observation
import OSLog

private let log = Logger(
  subsystem: bundleIdentifier, category: "AVPHTTPProxy")

/// Loopback HTTP proxy that fronts the Mac-hosted preview server so
/// WebKit on visionOS can reach it.
///
/// Why this exists: the Mac Server's LAN HTTPS endpoint is advertised
/// to AVP as `https://[fe80::xxx%25awdl0]:<port>/...` — an IPv6
/// link-local with an AWDL zone identifier. The zone-id is the only
/// host form that reliably resolves over AWDL when Bonjour is
/// unavailable (`fe80::xxx` alone is interface-ambiguous; mDNS doesn't
/// resolve `<name>.local` over AWDL). visionOS WebKit's URL parser
/// rejects URLs containing `%zone` zone identifiers with
/// `WebKitErrorCannotShowURL` — so the URL never reaches the network
/// stack at all.
///
/// We work around it by binding a plain HTTP listener on `127.0.0.1`
/// inside the AVP app, handing WebKit `http://127.0.0.1:<proxyPort>/...`,
/// and proxying each request to the real upstream over an
/// `NWConnection` (which `does` accept AWDL-scoped IPv6 hosts) with TLS
/// and the same SHA-256 cert pin the Kosmos bridge publishes. WebKit
/// only ever sees loopback.
///
/// Single-upstream by design: AVP has at most one paired Mac Server in
/// the v1 product; multi-upstream would need path-prefix keying. The
/// upstream is replaced on each `setUpstream`; existing in-flight
/// connections keep their captured snapshot.
///
/// Concurrency: all public API is `@MainActor`. Per-connection
/// receive/send callbacks hop back to MainActor — fine at AVP's traffic
/// scale (one user, one document tree at a time).
@MainActor
@Observable
final class AVPHTTPProxy {
  /// OS-assigned loopback port the listener is bound to. Nil until the
  /// listener reaches `.ready`. Observed so `KosmosVisionService` can
  /// wait for readiness before handing out a rewritten URL.
  private(set) var port: UInt16?

  @ObservationIgnored private var listener: NWListener?
  @ObservationIgnored private var upstream: Upstream?

  /// Dedicated queue for the listener and all connection callbacks.
  /// Connection handlers hop to MainActor before touching
  /// `self.upstream` so the read is safe.
  @ObservationIgnored
  private let queue = DispatchQueue(label: "net.leuski.galley.avp-proxy")

  struct Upstream: Sendable {
    /// Host as it arrives from `OpenDocument.httpsURL` — for an
    /// AWDL-zoned IPv6 this is the `fe80::xxx%awdl0` form (the `%` is
    /// already URL-decoded by the time `URL.host()` returns it).
    let host: String
    let port: UInt16
    let certSHA256: Data
  }

  init() {}

  /// Bring up the loopback listener if not already running. Idempotent.
  /// `port` becomes non-nil when the listener reaches `.ready`.
  func start() {
    guard listener == nil else { return }
    do {
      let params = NWParameters.tcp
      params.allowLocalEndpointReuse = true
      // Bind to loopback only — this socket must never be reachable
      // from the LAN. The proxy speaks plain HTTP inbound; TLS
      // terminates on the upstream connection.
      params.requiredLocalEndpoint = .hostPort(
        host: .ipv4(.loopback), port: .any)

      let listener = try NWListener(using: params)
      listener.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in
          self?.handleListenerState(state)
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in
          self?.accept(inbound: connection)
        }
      }
      listener.start(queue: queue)
      self.listener = listener
    } catch {
      log.error("""
        Listener init failed: \
        \(error.localizedDescription, privacy: .public)
        """)
    }
  }

  /// Tear the listener down. Existing in-flight connections cancel via
  /// their own state handlers when the listener cancels.
  func stop() {
    listener?.cancel()
    listener = nil
    port = nil
  }

  /// Replace the current upstream. Subsequent inbound connections use
  /// the new snapshot; existing connections keep their captured one.
  func setUpstream(host: String, port: UInt16, certSHA256: Data) {
    upstream = Upstream(host: host, port: port, certSHA256: certSHA256)
  }

  /// Rewrite an upstream URL (`https://[fe80::xxx%25awdl0]:N/path?q#f`)
  /// into a loopback URL (`http://127.0.0.1:<proxyPort>/path?q#f`).
  /// Returns nil if the listener isn't ready yet.
  ///
  /// Path, query, and fragment are preserved verbatim in their
  /// percent-encoded form. Scheme/host/port are replaced. The rewritten
  /// URL is what we hand to WebKit; the original URL's host/port travel
  /// separately as the `Upstream` snapshot.
  func rewrittenURL(for original: URL) -> URL? {
    guard let port else { return nil }
    return Self.composeLoopbackURL(port: port, from: original)
  }

  /// Async variant. Waits up to ~2 s for the listener to bind, then
  /// returns the rewritten URL. Returns nil only if the bind never
  /// succeeds in that window — fall back to surfacing an error rather
  /// than handing WebKit a URL we already know it rejects.
  ///
  /// Callers: `KosmosVisionService` on `OpenDocument` receipt. The
  /// proxy is started in `start()` (in `.onAppear` of the first
  /// scene), so in practice the listener is already ready by the time
  /// any Mac dispatches an open. The wait is here for the cold-launch
  /// race where the AVP app boots straight into an OpenDocument.
  func awaitRewrittenURL(for original: URL) async -> URL? {
    if let url = rewrittenURL(for: original) {
      return url
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(25))
      if let url = rewrittenURL(for: original) {
        return url
      }
    }
    return nil
  }

  /// Pure URL composition — extracted so the test suite can pin it
  /// without bringing up a real listener.
  nonisolated static func composeLoopbackURL(
    port: UInt16, from original: URL
  ) -> URL? {
    var components = URLComponents()
    components.scheme = "http"
    components.host = "127.0.0.1"
    components.port = Int(port)
    components.percentEncodedPath = original.path(percentEncoded: true)
    components.percentEncodedQuery = original.query(percentEncoded: true)
    components.percentEncodedFragment =
      original.fragment(percentEncoded: true)
    return components.url
  }

  // MARK: - Listener state

  private func handleListenerState(_ state: NWListener.State) {
    switch state {
    case .ready:
      if let rawPort = listener?.port?.rawValue {
        port = rawPort
        log.notice(
          "Proxy listening on 127.0.0.1:\(rawPort, privacy: .public)")
      }
    case .failed(let error):
      log.error("""
        Listener failed: \(error.localizedDescription, privacy: .public)
        """)
      port = nil
    case .cancelled:
      port = nil
    default:
      break
    }
  }

  // MARK: - Inbound

  private func accept(inbound: NWConnection) {
    guard let upstream else {
      // Server hasn't published a bridge yet, or we haven't received an
      // OpenDocument. Drop the connection — WebKit will retry on its
      // own page-load schedule.
      log.notice("Inbound connection dropped: no upstream configured.")
      inbound.cancel()
      return
    }
    let snapshot = upstream
    inbound.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        self?.handleInboundState(
          state, inbound: inbound, upstream: snapshot)
      }
    }
    inbound.start(queue: queue)
  }

  private func handleInboundState(
    _ state: NWConnection.State,
    inbound: NWConnection,
    upstream: Upstream
  ) {
    switch state {
    case .ready:
      readHeaders(inbound: inbound, upstream: upstream, accumulated: Data())
    case .failed, .cancelled:
      inbound.cancel()
    default:
      break
    }
  }

  /// Read inbound bytes until the HTTP/1.1 request header block is
  /// complete (`\r\n\r\n`). Then rewrite Host + Connection and open
  /// the upstream.
  private func readHeaders(
    inbound: NWConnection, upstream: Upstream, accumulated: Data
  ) {
    inbound.receive(
      minimumIncompleteLength: 1, maximumLength: 32 * 1024
    ) { [weak self] data, _, isComplete, error in
      Task { @MainActor in
        guard let self else { return }
        if let error {
          log.error("""
            Inbound recv error: \
            \(error.localizedDescription, privacy: .public)
            """)
          inbound.cancel()
          return
        }
        var buffer = accumulated
        if let data { buffer.append(data) }
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
          if isComplete {
            inbound.cancel()
          } else {
            self.readHeaders(
              inbound: inbound, upstream: upstream, accumulated: buffer)
          }
          return
        }
        let headerBytes = buffer.prefix(upTo: end.upperBound)
        let bodyOverflow = buffer.suffix(from: end.upperBound)
        let rewritten = Self.rewriteRequestHeaders(
          headerBytes, upstream: upstream)
        var outboundInitial = rewritten
        outboundInitial.append(bodyOverflow)
        self.openUpstream(
          inbound: inbound, upstream: upstream,
          initial: outboundInitial)
      }
    }
  }

  // MARK: - Outbound

  private func openUpstream(
    inbound: NWConnection, upstream: Upstream, initial: Data
  ) {
    let outbound = Self.makeOutboundConnection(to: upstream)
    outbound.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        self?.handleOutboundState(
          state, inbound: inbound, outbound: outbound, initial: initial)
      }
    }
    outbound.start(queue: queue)
  }

  private func handleOutboundState(
    _ state: NWConnection.State,
    inbound: NWConnection,
    outbound: NWConnection,
    initial: Data
  ) {
    switch state {
    case .ready:
      outbound.send(
        content: initial,
        completion: .contentProcessed { error in
          if let error {
            log.error("""
              Outbound initial send failed: \
              \(error.localizedDescription, privacy: .public)
              """)
            inbound.cancel()
            outbound.cancel()
            return
          }
          Task { @MainActor [weak self] in
            self?.pump(from: inbound, to: outbound)
            self?.pump(from: outbound, to: inbound)
          }
        })
    case .failed(let error):
      log.error("""
        Outbound failed: \(error.localizedDescription, privacy: .public)
        """)
      inbound.cancel()
    case .cancelled:
      inbound.cancel()
    default:
      break
    }
  }

  /// Bidirectional byte pump. Recurses on its own queue until EOF.
  /// Streaming-friendly — no buffering between reads — so SSE on
  /// `/events/<path>` flows through naturally.
  private func pump(from src: NWConnection, to dst: NWConnection) {
    src.receive(
      minimumIncompleteLength: 1, maximumLength: 32 * 1024
    ) { [weak self] data, _, isComplete, error in
      if let error {
        log.error("""
          Pump recv error: \(error.localizedDescription, privacy: .public)
          """)
        src.cancel()
        dst.cancel()
        return
      }
      if let data, !data.isEmpty {
        dst.send(
          content: data,
          completion: .contentProcessed { sendError in
            if let sendError {
              log.error("""
                Pump send error: \
                \(sendError.localizedDescription, privacy: .public)
                """)
              src.cancel()
              dst.cancel()
            }
          })
      }
      if isComplete {
        // Forward EOF so the other side closes cleanly. `isComplete`
        // on send signals FIN on the underlying TCP socket.
        dst.send(
          content: nil,
          contentContext: .finalMessage,
          isComplete: true,
          completion: .contentProcessed { _ in
            dst.cancel()
          })
        src.cancel()
      } else {
        Task { @MainActor in
          self?.pump(from: src, to: dst)
        }
      }
    }
  }

  // MARK: - Header rewriting (pure)

  /// Rewrite an HTTP/1.1 request header block:
  ///   - Replace the `Host:` header with the upstream's authority
  ///     (with the AWDL zone re-encoded as `%25` per RFC 6874).
  ///   - Force `Connection: close` so each upstream request is a
  ///     one-shot — keeps the inbound→outbound HTTP framing trivial.
  ///
  /// All other request lines pass through verbatim. The trailing
  /// `\r\n\r\n` is preserved.
  nonisolated static func rewriteRequestHeaders(
    _ bytes: Data, upstream: Upstream
  ) -> Data {
    guard let text = String(data: bytes, encoding: .utf8) else {
      // Non-UTF8 in the header block is malformed HTTP. Pass through
      // and let the upstream reject it.
      return bytes
    }
    let lines = text.components(separatedBy: "\r\n")
    var rewritten: [String] = []
    var sawHost = false
    var sawConnection = false
    for (index, line) in lines.enumerated() {
      if index == 0 {
        // Request line (e.g. "GET /preview/foo HTTP/1.1") — verbatim.
        rewritten.append(line)
        continue
      }
      let lower = line.lowercased()
      if lower.hasPrefix("host:") {
        rewritten.append("Host: \(formatHostHeader(upstream))")
        sawHost = true
      } else if lower.hasPrefix("connection:") {
        rewritten.append("Connection: close")
        sawConnection = true
      } else {
        rewritten.append(line)
      }
    }
    // Inject if missing. The body marker (empty line pair) is the last
    // two entries from the split — insert just before them.
    let insertIndex = max(rewritten.count - 2, 1)
    if !sawHost {
      rewritten.insert(
        "Host: \(formatHostHeader(upstream))", at: insertIndex)
    }
    if !sawConnection {
      rewritten.insert("Connection: close", at: insertIndex)
    }
    return Data(rewritten.joined(separator: "\r\n").utf8)
  }

  /// `Host` header value for the upstream. IPv6 hosts get bracketed
  /// with the zone-id `%25`-encoded per RFC 6874 — the Server's
  /// `isHostAllowed` parses the value via `URL(string:)` which expects
  /// that encoding.
  nonisolated static func formatHostHeader(_ upstream: Upstream) -> String {
    let host = upstream.host
    if host.contains(":") {
      if let sep = host.firstIndex(of: "%") {
        let addr = host[..<sep]
        let zone = host[host.index(after: sep)...]
        return "[\(addr)%25\(zone)]:\(upstream.port)"
      }
      return "[\(host)]:\(upstream.port)"
    }
    return "\(host):\(upstream.port)"
  }

  // MARK: - Upstream NWConnection

  nonisolated static func makeOutboundConnection(
    to upstream: Upstream
  ) -> NWConnection {
    let endpoint = NWEndpoint.hostPort(
      host: parseHost(upstream.host),
      port: NWEndpoint.Port(rawValue: upstream.port) ?? .https)

    let tls = NWProtocolTLS.Options()
    let pinned = upstream.certSHA256
    sec_protocol_options_set_verify_block(
      tls.securityProtocolOptions,
      { _, secTrust, complete in
        let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
        let outcome = PinnedCertPolicy.validate(
          serverTrust: trust, pinnedCertSHA256: pinned)
        complete(outcome == .accept)
      },
      DispatchQueue.global(qos: .userInitiated))

    let params = NWParameters(tls: tls)
    return NWConnection(to: endpoint, using: params)
  }

  /// Parse a host string into `NWEndpoint.Host`. AWDL-zoned IPv6 like
  /// `fe80::xxx%awdl0` is handled by `IPv6Address`'s native zone-id
  /// parsing — the resulting address carries the scope index forward
  /// to `NWConnection`'s dial.
  nonisolated static func parseHost(_ raw: String) -> NWEndpoint.Host {
    if raw.contains(":"), let ipv6 = IPv6Address(raw) {
      return .ipv6(ipv6)
    }
    if let ipv4 = IPv4Address(raw) {
      return .ipv4(ipv4)
    }
    return .name(raw, nil)
  }
}
#endif
