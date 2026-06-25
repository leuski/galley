# Plan: Replace the loopback HTTP server with a Kosmos-based rendering path

Status: in progress — WS5 (QL-over-Kosmos) ABANDONED; HTTP kept for QL/browsers
Author: design session 2026-06-14

## Decision update (2026-06-25): QL stays on HTTP; HTTP becomes optional

WS5 (Quick Look as a direct Kosmos client) is **abandoned — it's
impossible**, confirmed empirically and by Apple. A Quick Look preview
appex runs in a sandbox that **denies all in-process outbound network**
(`NWConnection` *and* `URLSession` both → `Operation not permitted` /
`deny network-outbound`), regardless of `com.apple.security.network.client`.
The old HTTP QL path works only because `WKWebView` fetches via WebKit's
**separate** network process, not the appex. See memory
`quicklook-appex-no-inprocess-network` and Apple Developer Forums threads
115299 / 701940.

Revised end state:
- **AVP** — in-process tunnel (WS2+WS4), no FlyingFox in its data path. ✅ done.
- **Quick Look / browsers** — keep the **HTTP server**; QL loads
  `http://127.0.0.1:<serverHTTPPort>` in a `WKWebView`, falling back to
  in-process when `serverHTTPPort` is 0/absent. The HTTP-port default is
  named `serverHTTPPort` again (the `serverPort` rename is reverted, since
  the Kosmos-port-for-QL idea is dead).
- **New goal (replaces WS6 deletion):** make the **HTTP transport an
  optional server component** rather than deleting it. Blocker to true
  optionality: `InProcessTunnelBackend` (the AVP path) currently reuses the
  FlyingFox `Response` (`Routes.response` + `drainBody`), so the AVP tunnel
  still pulls in FlyingFox. Decoupling it (map `PreviewResponse` →
  `TunnelResponseEvent` directly, moving reload-injection / CSP / SSE /
  error-page shaping into a neutral layer shared by both transports) is the
  real work to make HTTP optional.

## Progress log

- **2026-06-25 — Plan reviewed against current code.** Still valid; Galley
  changes since the plan are cleanup/unification only. Kosmos gained
  per-peer-id addressing + pending-client/future support (helps WS1/WS5).
- **2026-06-25 — WS2 (Phase 1) done.** `TunnelBackend` protocol +
  `TunnelResponseEvent` and a provided `URLSessionTunnelBackend` landed in
  `KosmosHTTPTunnel`; `Responder` now consumes any backend. A
  `Responder(upstreamBaseProvider:)` convenience init preserves the Galley
  call site verbatim, so behavior is identical. Tunnel tests green (16
  existing + 3 new fake-backend tests for bounded/streaming/throw→502).
  Galley `Viewer` scheme builds clean.
- **2026-06-25 — WS3 (Phase 2) done.** `PreviewRequestService` +
  `PreviewResponse`/`PreviewFailure` landed in
  `GalleyCoreKit/Render/PreviewRequestService.swift` — the single source of
  truth for `/preview` (render or asset), `/template`, `/events`, `/`,
  returning transport-neutral responses (uses `ResolvedBytes`/`CachePolicy`
  from KosmosAppKit; errors are structured so each transport localizes its
  own page). `Routes.swift` is now a thin FlyingFox adapter that delegates
  to the service and maps `PreviewResponse → Response` (localized error
  pages stay in `GalleyServerKit`). Verified: new `PreviewRequestService`
  suite + the live-socket `ServerPreviewEndToEnd` + `PreviewServerController`
  + `AVPCSSPathChain` + `TemplateAssetRewriter` all pass; `Viewer` builds
  clean (no lint warnings). NOTE: the in-process scheme handler
  (`PreviewScheme.resolve`) is deliberately **not** folded in — it is
  asset-only (the Mac Viewer renders separately), so unifying it would
  change Viewer behavior. Left as-is.
- **2026-06-25 — `serverHTTPPort` → `serverPort` (hard cut).** Renamed in
  KosmosAppKit `HTTPServerDefaults` (+ `serverEndpointURL`), all three
  Galley `Defaults` classes (Viewer/Server/Quicklook), the BBEdit
  Safari/Chrome scripts, and the KosmosAppKit test. `Viewer` builds clean;
  KosmosAppKit `HTTPServerDefaults` tests pass.
- **2026-06-25 — WS5 (Phase 5) implemented; functional validation pending.**
  Quick Look now renders via a **direct loopback Kosmos tunnel** to the
  Server, falling back to in-process. Pieces:
  - `GalleyKosmosRole.quicklook` added (so the Server doesn't mistake a
    preview for Galley.app).
  - KosmosTransport: `KosmosLink.listeningPort()` (default nil; LoomKosmosLink
    returns its bound `.tcp` port) + `KosmosClient.listeningPort()`.
  - Server publishes the **Kosmos** port as `serverPort` from
    `ServerKosmosService.linkDidStart` (reset to 0 in `stop()`); `AppModel`
    no longer publishes the HTTP port. `serverPort` is now the Kosmos
    direct-connect port, not HTTP.
  - **`PreviewTunnelConnection`** (in `GalleyCoreKit/WebKit/`) encapsulates
    `makeLoomDirect` + tunnel `Client` wiring + a classic
    `WKURLSchemeHandler` bridge, exposing a Kosmos-free facade. It lives in
    GalleyCoreKit (which already links the Kosmos products) so the Quick
    Look target imports only GalleyCoreKit — **no pbxproj/link changes to
    the appex** (the naive approach failed at link: QL doesn't link the
    Kosmos products directly).
  - QL `PreviewViewController`: try `PreviewTunnelConnection.connect`
    (2s timeout) → load `kosmos://local/preview/<path>`; on any failure →
    in-process render (its prior behavior). Graceful fallback means QL
    always shows something.
  Builds clean (Viewer); full Tests bundle green (189). **NOT functionally
  validated** — needs a running Server + `qlmanage -p` against the real
  `.appex` + an entitled Loom handshake (can't run headless). This run also
  serves as WS1's end-to-end proof once exercised.
- **2026-06-25 — WS5 debugging (two fixes after "QL broken, no render").**
  1. **"No render at all" — fixed.** Regression I introduced: `webView`
     became an optional built *late* (after the up-to-2s tunnel attempt),
     so `loadView()` handed Quick Look a throwaway empty WebView while
     content loaded into a different instance → blank on every path
     (including the in-process fallback). Fixed by making the controller's
     view a **stable container** and installing the chosen WebView into it
     (`install(_:)`) — restores the original single-displayed-view
     invariant. In-process fallback renders regardless of the Kosmos path.
  2. **Keychain — confirmed the blocker + added the entitlement.** Loom
     stores its P256 identity in the Keychain (`SecItemAdd` /
     `SecItemCopyMatching`). AVP is sandboxed (visionOS) yet works because
     the **Viewer entitlements grant `keychain-access-groups` =
     `$(AppIdentifierPrefix)net.leuski.galley`** (Server has it too). QL
     was sandboxed *without* that group → handshake failed → fell back.
     Added the same `keychain-access-groups` to `Quicklook.entitlements`.
     Still needs validation under real signing (ad-hoc `$(AppIdentifierPrefix)`
     + appex keychain group). Correction to the prior note: this entitlement
     IS needed — a sandboxed Loom peer requires it (AVP is the proof); it's
     not a CLI-only artifact.
- **2026-06-25 — WS1 (Phase 4) capability done; round-trip validation
  deferred to WS5.** Confirmed **no Loom change needed** — `LoomNode`
  already exposes `connect(to:using:hello:)`, `startAuthenticatedAdvertising`
  already returns the bound `[LoomTransportKind: UInt16]`, and
  `LoomNetworkConfiguration.enableBonjour` already gates discovery. All
  changes landed in **KosmosTransport**:
  - `ReconnectingSession` gained a `.peerIdentified(deviceID:metadata:)`
    event, emitted from the handshake `session.context` right after
    `.connected` — so a direct dialer learns the peer it didn't discover.
  - `LoomKosmosLink.Configuration` gained `enableBonjour` +
    `directEndpoint`; `start()` branches to a no-advertise/no-browse
    direct-dial path (`startDirectConnect` + `pumpDirect`) that registers
    the peer on `.peerIdentified` and reuses the existing session/framing/
    peer-set machinery. `startAdvertising` now captures the bound `.tcp`
    port, exposed via `listeningPort()` for the Server to publish.
  - `KosmosClient.makeLoomDirect(host:port:…)` factory (Bonjour off),
    returning the same `KosmosClient` so the tunnel rides it unchanged.
  - The discovery/AVP path is untouched (direct mode is a separate
    branch). `ReconnectingSession` dials `.tcp`, and the `.tcp` listener
    accepts loopback, so direct connect reuses the proven TCP path.
  Tested: new direct-connect construction/config suite + all 38
  KosmosTransport tests pass; full Kosmos package + Galley `Viewer` build
  clean. **NOT headless-testable:** the real loopback handshake needs
  Keychain entitlements (documented in `LoomKosmosLinkTests` — SwiftPM CLI
  hits `keychainWriteFailed(-34018)`), so the two-node round-trip is
  validated in the entitled Galley Server↔QL path alongside WS5, not in
  `swift test`. Galley wiring (Server publishes `listeningPort()` →
  `serverPort`; QL calls `makeLoomDirect`) is WS5.
- **2026-06-25 — WS4 (Phase 3) done.** `InProcessTunnelBackend`
  (`GalleyServerKit/Galley/InProcessTunnelBackend.swift`) renders via the
  shared `PreviewRequestService`, maps to the *same* FlyingFox `Response`
  the HTTP routes build (`Routes.response(from:watcher:)`, now internal),
  and serializes it into `TunnelResponseEvent`s. To serialize without
  re-deriving anything, added a generic read-only surface to
  KosmosHTTPServer (`Response.statusCode` / `.headerPairs` /
  `drainBody(_:)`) — so reload-script injection, CSP, SSE framing, and
  localized error pages all come from one place. `ServerKosmosService` now
  builds `Responder(backend: InProcessTunnelBackend(service:
  server.previewService, watcher: server.watcher))` instead of the
  URLSession-to-loopback backend. **The AVP data path no longer touches
  FlyingFox.** The loopback HTTP listener still runs, now used only by
  Quick Look / browsers. Verified: new `InProcessTunnelBackend` suite
  (markdown→HTML with reload script injected; asset bytes) + full `Tests`
  bundle green (189 tests); `Viewer` builds clean. NOT yet validated
  against a live Vision Pro — the render path is unit-proven, but
  real-device AVP rendering + live-reload should be smoke-tested before
  WS6 deletes the server.
- **2026-06-25 — incidental fix.** `Tests/ViewerTests/RecentDocumentsModelTests.swift`
  referenced a removed public `entries` accessor (broken on `main` since the
  recents-unification refactor; the file never compiled, so the whole `Tests`
  target couldn't build). Fixed line 49 to read the public
  `Defaults.shared.recentEntries` store. Suite passes in isolation; under
  full-bundle parallelism it can flake on the shared `recentEntries` global
  (pre-existing isolation weakness, now newly exposed). Unrelated to this
  plan — flagged for a separate fix.

## 1. Goal

Remove the FlyingFox loopback HTTP server and its supporting stack
(`KosmosHTTPServer` package + `GalleyServerKit` route table), and route
**every** rendered-preview consumer through one uniform path: a Kosmos
HTTP tunnel whose backend renders **in-process** inside the Server.

Two transports, one API:

- **AVP** (different device) reaches the Server over Loom/QUIC across the
  LAN — exactly as today.
- **Same-machine consumers** (Quick Look now; potentially the Mac Viewer
  later) reach the Server over a **direct loopback Kosmos connection** to a
  known `127.0.0.1:<port>` — no Bonjour, no FlyingFox.

The motivation is **connection flexibility and a single rendering
authority**, not third-party-processor support. Quick Look talking to the
Server through the same tunnel API as AVP is the point; processor fidelity
is a side effect.

### Secondary goal — a reusable Kosmos capability

Extend Kosmos so any peer can establish a session by **address/port pair**,
bypassing Bonjour discovery. This is a general `KosmosTransport`/`Loom`
feature, not Galley-specific.

## 2. Non-goals

- Keeping browser access (`http://localhost:<port>/preview/...`). The
  BBEdit→Safari / BBEdit→Chrome scripts are dropped. BBEdit→Galley
  (`galley://`) stays.
- HTTPS / TLS / cert pinning. Loopback and Kosmos remain the trust
  boundaries.
- Changing the `galley://` / `galley-bridge://` LS-claim contracts.

## 3. Current coupling (what we're undoing)

- The AVP tunnel renders by **round-tripping to the loopback HTTP server**.
  `Sources/Server/App/ServerKosmosService.swift` constructs the responder
  with `upstreamBaseProvider: { Defaults.shared.serverEndpointURL }`, and
  `Kosmos/Sources/KosmosHTTPTunnel/Responder.swift` issues a real
  `URLSession.dataTask` against `http://127.0.0.1:<port>`. Kosmos is the
  wire; FlyingFox is the renderer-of-record.
- The route logic lives in `Sources/GalleyServerKit/Galley/Routes.swift`
  (`/preview/<path>`, `/template/<id>/<file>`, `/events/<path>` SSE, `/`).
- The **same rendering already runs in-process** elsewhere via
  `Sources/GalleyCoreKit/WebKit/PreviewSchemeHandler.swift`
  (`PreviewScheme.resolve` + `ClassicPreviewSchemeHandler`): Mac Viewer's
  visible `WebPage`, the print/PDF offscreen web view, and Quick Look's
  fallback. So in-process rendering is proven; it is simply not yet the
  tunnel's backend.
- Quick Look (`Sources/Quicklook/PreviewViewController.swift`) is
  server-first over loopback HTTP, falling back to in-process
  (`SwiftMarkdownRenderer` + `.bundledDefault`).
- The Server publishes `serverHTTPPort` to the shared `net.leuski.galley`
  defaults; `serverEndpointURL` is composed in
  `KosmosAppKit/.../DefaultsProtocol.swift` (`HTTPServerDefaults`).
- Loom's data plane is QUIC/UDP via `NWConnection`; Bonjour is discovery
  only. Loom already has the direct-connect primitives —
  `LoomNode.attemptConnect(to: NWEndpoint)`,
  `LoomEndpointResolver.resolveHostPort` (raw IPs pass through unchanged, so
  `127.0.0.1:<port>` is valid), `LoomDirectListener` /
  `LoomNativeQUICDirectListener` binding OS-assigned direct-transport ports
  (`directListenerPorts`). Those ports are currently only announced in the
  Bonjour TXT record. `KosmosLink` is already an abstraction
  (`LoomKosmosLink` + `InMemoryKosmosLink`), so the tunnel `Client` /
  `Responder` are transport-agnostic by construction.

## 4. Target architecture

```
            ┌────────────────────────── Server process (unsandboxed) ──────────────────────────┐
            │                                                                                    │
 AVP  ──QUIC/LAN──▶  Kosmos host  ─▶  Responder ─▶  TunnelBackend(inProcess) ─▶ PreviewRequestService
  (galley://local)        ▲                                                          │  (renderer + template
                          │                                                          │   + DocumentWatcher)
 QL  ──QUIC/loopback──────┘                                                          ▼
  (galley://local)   direct connect to 127.0.0.1:<kosmosPort>                  response events
                                                                              (head + body chunks / SSE)
            └────────────────────────────────────────────────────────────────────────────────┘

 Mac Viewer / print  ─▶  x-galley://local scheme handler ─▶ PreviewRequestService   (same service, no tunnel)
```

Single source of truth for "turn a preview request into response bytes" is
`PreviewRequestService`. It is reached three ways: the in-process scheme
handler (Mac Viewer, print), and the tunnel backend (AVP + QL). FlyingFox
and the route table are gone.

## 5. Workstreams

### WS1 — Kosmos: direct peer connection by address/port

Land entirely in the **`Kosmos` package** (KosmosTransport) + Galley wiring.
**No Loom modification needed** — verified 2026-06-25 that Loom already
exposes everything: `LoomNode.connect(to: NWEndpoint, using:, hello:, …)`
is public (raw IPs pass straight through `LoomEndpointResolver`),
`startAuthenticatedAdvertising(...)` already *returns* the bound
`[LoomTransportKind: UInt16]` listener ports (today `LoomKosmosLink`
discards them), and `LoomNetworkConfiguration.enableBonjour` already gates
discovery/advertising. The work is one layer up, in the `LoomKosmosLink`
bridge, which is currently 100% Bonjour-discovery-driven.

1. **Expose the bound port (Server side).** `LoomKosmosLink.startAdvertising`
   captures the ports `startAuthenticatedAdvertising` returns (instead of
   `_ = try await …`) into a stored property, surfaced as a plain `UInt16`
   (no `LoomTransportKind` leak — pick one transport, e.g. QUIC, as the
   direct-connect transport). `KosmosServiceHost`/`KosmosService` forward it
   so Galley can publish it.
2. **Dial-only mode (Client side).** Add a direct entry to `LoomKosmosLink`:
   Bonjour off (`enableBonjour = false`), no discovery/advertise, open one
   outbound session to a fixed `127.0.0.1:<port>` endpoint via `LoomNode`,
   and register the peer once the handshake `session.context` yields its
   `deviceID` (the way `acceptInbound` already learns the inbound PeerID) —
   since direct dial doesn't know the peer's PeerID up front.
3. **`makeLoomDirect(...)` factory** alongside `makeLoomBacked` in
   `KosmosClientLoomFactory.swift`. Returns the same `KosmosClient`, so the
   tunnel `Client`/`Responder` ride it unchanged.
4. **Direct-client host.** A `KosmosServiceHost`/`KosmosService` mode that
   dials a fixed endpoint instead of advertising/browsing (QL never
   advertises).
5. **Reconnect.** Direct mode re-dials the fixed endpoint on drop rather
   than waiting for re-discovery.

The one genuinely new bit is the dial-only path in `LoomKosmosLink`; the
per-peer session machinery (framing, pump, peer-set publishing) is reused.

Tests (in-package, no Galley): two `LoomKosmosLink` nodes over loopback —
one advertising, one dialing `127.0.0.1:<port>` with Bonjour disabled —
exchange a round-trip Kosmos message and confirm peer metadata
(role/product) is present. Confirms direct connect end-to-end without mDNS.

### WS2 — Kosmos: transport-agnostic tunnel backend

Land in `KosmosHTTPTunnel`. Pure refactor; no behavior change.

1. Define the seam:
   ```swift
   public enum TunnelResponseEvent: Sendable {
     case head(status: Int, headers: [String: String])
     case body(Data)            // one batch; final is implicit on stream finish
   }
   public protocol TunnelBackend: Sendable {
     func resolve(_ request: ProxyHTTPRequest)
       -> AsyncThrowingStream<TunnelResponseEvent, any Error>
   }
   ```
2. Change `Responder.init(backend: TunnelBackend)` (replacing
   `upstreamBaseProvider`). Everything generic stays in `Responder`: the
   buffer-vs-stream decision keyed off the head's `Content-Type`
   (`URLBuilder.isEventStream`), 640 KB chunking, SHA/timing logs, the
   `requestID → Task` map, `ProxyHTTPCancel` teardown, same-product
   guarding, 503/502 synthesis.
3. Ship the **current behavior verbatim** as a provided
   `URLSessionTunnelBackend(upstreamBaseProvider:)` — `TunnelDataDelegate`
   + `URLBuilder.buildURLRequest` move inside it.
4. Keep `Responder` off forced `@MainActor` for the backend call; the
   backend is `Sendable` and may run off-main (the URLSession delegate
   already does).

Tests: backend protocol conformance + a fake backend driving the Responder
through bounded and streaming responses. Existing tunnel tests keep passing
via `URLSessionTunnelBackend`.

### WS3 — Galley: unified `PreviewRequestService` (retire `Routes.swift`)

Land in `GalleyCoreKit`. This is the DRY consolidation.

1. Extract the request-handling logic from
   `GalleyServerKit/Galley/Routes.swift` into a transport-agnostic
   `PreviewRequestService` in `GalleyCoreKit`, built on the existing shared
   `PreviewRoute` / `RouteNames` parser. Given a parsed route + providers
   (`rendererProvider`, `selectedTemplateProvider`, `DocumentWatcher`) and
   an `origin` URL, it returns a stream of `(status, headers, body…)`:
   - `/preview/<path>` — render Markdown (placeholders + live-reload script
     injection) or serve a sibling asset.
   - `/template/<id>/<file>` — template asset with caching headers.
   - `/events/<path>` — SSE stream from `DocumentWatcher.subscribe`.
   - `/` — health/index.
   `origin` comes from the caller (the request's `X-Galley-Origin` for
   tunneled callers; the scheme origin for in-process), preserving the
   `<base href>` behavior the routes compute from the `Host` header today.
2. Repoint the in-process scheme handler
   (`GalleyCoreKit/WebKit/PreviewSchemeHandler.swift` —
   `PreviewScheme.resolve` / `ClassicPreviewSchemeHandler`) at
   `PreviewRequestService` so Mac Viewer + print share the one
   implementation. **No behavior change** — verify against existing
   snapshot/render tests.
3. Drop host-guarding from the service (it was a loopback-HTTP / DNS-rebind
   concern; in-process and Kosmos have their own trust boundaries).

### WS4 — Server: in-process tunnel backend, FlyingFox removed from the data path

Land in Galley (`GalleyServerKit` shrinks to glue, or fold into
`GalleyCoreKit`).

1. Implement `InProcessTunnelBackend: TunnelBackend` that parses the
   `ProxyHTTPRequest` via `RouteNames`/`PreviewRoute`, calls
   `PreviewRequestService`, and maps the result to `TunnelResponseEvent`s
   (head, then body batches; `/events` yields head + per-change frames until
   cancelled).
2. In `ServerKosmosService.swift`, construct
   `Responder(backend: InProcessTunnelBackend(...))` instead of the
   URLSession backend. The Server is the render authority (unsandboxed → can
   run external processors), so request-time `rendererProvider` /
   `selectedTemplateProvider` keep honoring menu picks with no restart.
3. **Publish the Kosmos direct-transport port** to the shared
   `net.leuski.galley` defaults (WS5 reader). The Server already runs the
   Kosmos host; its direct listener accepts loopback (binds all
   interfaces). Add `serverKosmosPort` next to / replacing
   `serverHTTPPort`. Update `KosmosAppKit` `HTTPServerDefaults` →
   `KosmosEndpointDefaults` accordingly.
4. AVP now renders with **no FlyingFox involvement**. Validate the full AVP
   path (document + CSS/JS/images + live reload) before removing the server.

At this point FlyingFox is still present only for Quick Look / browsers.

### WS5 — Quick Look: direct loopback Kosmos client

Land in `Sources/Quicklook/`. Loom is **already linked** via
`GalleyCoreKit → KosmosTransport → Loom`; no new dependency.

1. QL reads `serverKosmosPort` from the shared suite (it already has
   `temporary-exception.shared-preference.read-only`).
2. If present, QL builds a `KosmosClient.makeLoomDirect(host: "127.0.0.1",
   port: serverKosmosPort, ...)` (client-only, Bonjour off), attaches a
   `KosmosHTTPTunnel.Client` + a `galley://local` URL scheme handler (the
   same `KosmosTunnelSchemeHandler` AVP uses), and loads
   `galley://local/preview/<path>` in its `WKWebView`. Identical API to AVP.
3. **Fallback preserved.** If the port is absent or the connect fails
   (Server not running), QL renders in-process (`SwiftMarkdownRenderer` +
   `.bundledDefault`) exactly as today. QL must paint fast and is
   short-lived, so the direct-connect attempt needs a tight timeout before
   bailing to in-process.
4. Bonjour stays disabled for QL: no `NSBonjourServices`, no
   `network.server`, no advertise — only `network.client` (already present)
   for the outbound loopback dial.

### WS6 — Delete the HTTP server and clean up

Only after WS4 + WS5 validate.

- Remove the `KosmosHTTPServer` package and its reference from
  `Galley.xcodeproj` → **FlyingFox + swift-http-types leave the graph**.
- Remove `GalleyServerKit/Galley/Routes.swift`, `PreviewServerController`,
  the FlyingFox-facing parts of `Response+Localization.swift`; collapse
  whatever remains into `GalleyCoreKit` or delete the framework target.
- Remove the Server's HTTP lifecycle (`startServer` HTTP bits in
  `AppModel.swift`); keep Kosmos host + Responder + render service. The
  Server remains the always-on `LSUIElement` routing authority + render
  host (per the "Server is the AVP routing authority" decision) — it does
  **not** disappear.
- Delete `BBEditScripts.bundle/Preview Markdown…/in Safari.sh` and
  `in Google Chrome.sh`. Keep `in Galley.sh`.
- Remove `serverHTTPPort` / `serverEndpointURL` and the
  `HTTPServerDefaults` conformances from Viewer/Server/QL `Defaults`
  (replaced by `serverKosmosPort`).
- Delete `Tests/GalleyServerKitTests/` and the `KosmosHTTPServer` test
  suite; move any still-relevant render assertions onto
  `PreviewRequestService` tests.

## 6. Phasing (each phase leaves a working system)

| Phase | Workstream | Server present? | Risk gate |
|------|------------|-----------------|-----------|
| 0 | Spike: loopback QUIC/UDP from sandboxed appex | yes | ✅ **PASS** (gate cleared) |
| 1 | WS2 tunnel backend abstraction (default = URLSession) | yes | pure refactor |
| 2 | WS3 `PreviewRequestService`; Mac Viewer/print repointed | yes | no behavior change |
| 3 | WS4 in-process backend; AVP off FlyingFox | yes (QL/browser only) | validate AVP |
| 4 | WS1 Kosmos direct connect + publish port | yes | in-package tests |
| 5 | WS5 QL direct loopback client + fallback | yes | validate QL |
| 6 | WS6 delete FlyingFox / server / scripts | **no** | final |

Phases 1–2 are safe refactors that pay off immediately (one render path).
The server is only deleted in phase 6, after both AVP and QL are proven on
the new path.

## 7. Risks, unknowns, and spikes

1. **Loopback QUIC/UDP from a sandboxed `.appex` (phase 0) — RESOLVED: PASS
   (2026-06-25).** Built an ad-hoc-signed sandboxed `.app` with QL's exact
   entitlements (`app-sandbox` + `network.client`, `NSAllowsLocalNetworking`,
   no `NSBonjourServices`) that dials a loopback UDP `NWConnection` to a
   127.0.0.1 echo listener. Result: `ROUND-TRIP-OK`, no local-network-privacy
   prompt, no denial. Negative control (same sandbox, *no* `network.client`)
   was blocked with `Operation not permitted` — proving the sandbox actually
   engaged, so the pass is real. QUIC rides UDP and the permission gate
   (sandbox `network.client` + TCC local-network) is transport-agnostic and
   destination-based (loopback exempt), so QUIC loopback is covered.
   Independent of QL, plain `NWConnection` UDP loopback round-trips on this
   macOS 26. Remaining (low-risk) confirmation: a `qlmanage` smoke test of
   the *actual* `.appex` once WS5 lands — the sandbox/TCC gates are identical
   between a signed `.app` and `.appex`, so this is verification, not a gate.
   Fallbacks (TCP direct transport / QL in-process only) are **not needed**.
2. **Direct-connect handshake latency vs QL's budget.** No Bonjour wait, but
   QUIC + Loom authenticated-session setup is non-zero on the preview hot
   path. Measure; enforce a tight timeout → in-process fallback.
3. **Trust on a direct (non-discovered) peer.** Dev uses
   `AlwaysTrustProvider`; confirm the authenticated session establishes for
   a dialed endpoint with no prior discovery. Production SAS pairing is out
   of scope here (loopback same-machine = same trust boundary).
4. **`/events` SSE over the in-process backend.** The backend must support a
   long-lived streaming response (head + per-change frames) and honor
   `ProxyHTTPCancel`. `AsyncThrowingStream<TunnelResponseEvent>` covers it;
   verify cancellation tears down the `DocumentWatcher` subscription.
   (Alternative considered: drop SSE-over-tunnel and drive AVP/QL reload via
   the existing `WindowContentChanged` control message. Rejected for now —
   SSE keeps one mechanism and reuses the page's existing EventSource JS.)
5. **State-restoration / cold-launch ordering** for QL's direct client (the
   tunnel `Client` already parks pre-attach requests via `resolvedClient()`;
   confirm that path works when the link is a direct dial rather than a
   discovered peer).
6. **`origin` / `<base href>` parity** between the tunneled callers and the
   in-process scheme handler when both go through `PreviewRequestService`.
   Covered by the existing `AVPCSSPathChain` / `TemplateOriginURL` tests —
   port them onto the service.

## 8. Testing

- **WS1:** loopback two-node direct-connect round-trip (Kosmos package).
- **WS2:** Responder driven by a fake `TunnelBackend` (bounded + streaming);
  existing tunnel tests via `URLSessionTunnelBackend`.
- **WS3:** `PreviewRequestService` unit tests absorbing the current
  `Routes.swift` coverage (route decode, render, template asset, SSE,
  origin/base-href). Mac Viewer/print snapshot tests unchanged.
- **WS4:** in-process backend maps service output to tunnel events; AVP
  end-to-end (manual + the `HTTPTunnelAVPClient` tests adapted).
- **WS5:** QL direct-connect happy path + fallback-on-no-server.
- **WS6:** build green with FlyingFox/`KosmosHTTPServer` removed; dependency
  graph confirmed clean.

## 9. Net effect

- FlyingFox + swift-http-types + the `KosmosHTTPServer` package removed.
- One rendering implementation (`PreviewRequestService`) for Mac Viewer,
  print, AVP, and Quick Look.
- One reachability API (Kosmos) for both same-machine and cross-device, with
  a new general-purpose direct address/port connect in Kosmos.
- A network-reachable arbitrary-file-read endpoint (`/preview/<abs-path>` on
  a loopback socket) is eliminated; file reads happen only inside the
  Server's in-process service, reachable only over Kosmos.
- Lost: browser preview (`in Safari` / `in Chrome` BBEdit scripts).

## 10. Open decisions

- **RESOLVED — port key.** `serverHTTPPort` → **`serverPort`**, hard cut
  (no transitional alias). Done 2026-06-25 across KosmosAppKit
  `HTTPServerDefaults` + all three Galley `Defaults` classes + BBEdit
  scripts. The persisted key changes name; the Server rewrites it on every
  state change, so no migration needed.
- **RESOLVED — GalleyServerKit fate.** After WS6 only ~40 lines survive
  (the `PreviewFailure → localized HTML error page` rendering) + the two
  resources — too thin for a target. **Fold** that into GalleyCoreKit
  (`Render/PreviewErrorPage.swift` + move `ErrorPage.html` and merge its
  `Localizable.xcstrings`) and **delete the GalleyServerKit target** in
  WS6. The Server then imports only GalleyCoreKit.
- Whether the **Mac Viewer** also moves to the tunnel for same-machine
  rendering later, or stays on the in-process scheme handler (current plan:
  stays — it already renders in-process with zero transport).
