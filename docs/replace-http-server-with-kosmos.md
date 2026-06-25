# Plan: Replace the loopback HTTP server with a Kosmos-based rendering path

Status: in progress
Author: design session 2026-06-14

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

Land in the `Kosmos` package (+ a small `Loom` public-API addition).

1. **Loom public connect-by-endpoint.** Promote the existing internal path
   to public API: `LoomNode.connect(toHost:port:) async throws -> session`,
   wrapping `LoomEndpointResolver.resolveHostPort` + the internal
   `attemptConnect(to:)`. Bonjour stays untouched; this is an additive
   alternative entry point.
2. **Expose the local direct-transport port.** Add a public accessor so a
   listening node can read the bound port of its direct listener
   (`directListenerPorts[.quic]` / `.udp` / `.tcp`) after start, to publish
   out-of-band. (Today only Bonjour TXT carries it.)
3. **KosmosTransport direct link.** Add
   `KosmosClient.makeLoomDirect(host:port:role:product:deviceType:trustProvider:...)`
   alongside `makeLoomBacked` in `KosmosClientLoomFactory.swift`. It builds
   a `LoomKosmosLink` with Bonjour disabled (`enableBonjour = false`,
   advertise off) that dials the fixed endpoint and runs the normal
   authenticated-session + metadata exchange (role/product), so the peer
   shows up in the host's peer set exactly like a discovered one.
4. **Client-only / no-advertise host mode.** Ensure `KosmosServiceHost` can
   run a client that only dials (QL never advertises). Verify
   `enabledDirectTransports` / Bonjour-off config supports this.
5. **Reconnect.** `ReconnectingSession` should target the fixed endpoint on
   drop rather than waiting for re-discovery, when in direct mode.

Tests (in-package, no Galley): two `LoomKosmosLink` nodes over loopback —
one listening, one dialing `127.0.0.1:<port>` with Bonjour disabled —
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
| 0 | Spike: loopback QUIC/UDP from sandboxed appex | yes | **gates WS5** |
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

1. **Loopback QUIC/UDP from a sandboxed `.appex` (phase 0, blocking).**
   TCP loopback is exempt from local-network privacy; UDP/QUIC loopback to
   `127.0.0.1` *should* be too, but I have not confirmed it for a sandboxed
   preview extension. Spike: minimal sandboxed appex dialing a loopback
   `NWConnection` (QUIC) with `network.client` only, no `NSBonjourServices`
   — confirm no `-65555`/privacy denial and a completed handshake. If it
   fails, fall back to: TCP direct transport (`LoomTransportKind.tcp`), or
   keep QL in-process only (still achieves server removal; QL just loses the
   uniform-API benefit).
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
