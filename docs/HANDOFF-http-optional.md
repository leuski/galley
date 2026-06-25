# Handoff — Galley render-transport refactor (HTTP-optional)

Date: 2026-06-25. Continues `docs/replace-http-server-with-kosmos.md`.

## TL;DR

The original plan was "delete the HTTP server, render everything over
Kosmos." That's **half-true now**:

- **AVP** renders over the **in-process Kosmos tunnel** (no FlyingFox in its
  data path). ✅ done + committed.
- **Quick Look** **cannot** be a Kosmos client — proven impossible (see
  below) — so it **stays on HTTP** (`WKWebView` loads
  `http://127.0.0.1:<serverHTTPPort>`), falling back to in-process when no
  port is published. ✅ working (user-confirmed).
- **Next goal:** keep the HTTP server but make it an **optional server
  component**, decoupled from the AVP/Kosmos path. ⏳ not started.

## The hard constraint that reshaped everything

A **Quick Look preview appex cannot make in-process network connections.**
Proven empirically (probes inside the running `net.leuski.galley.Quicklook`
appex) and confirmed by Apple:

- Both `NWConnection` AND `URLSession` to `127.0.0.1` from the appex →
  `Operation not permitted` / kernel `Sandbox: deny(1) network-outbound`,
  **despite `com.apple.security.network.client`** being in the (team-signed)
  entitlements. The preview-extension host sandbox refuses outbound network;
  no entitlement overrides it.
- The old HTTP QL works only because `WKWebView` fetches via WebKit's
  **separate** networking process, which isn't bound by the appex sandbox.
- Apple Dev Forums 115299 / 701940; memory
  `quicklook-appex-no-inprocess-network`.

⇒ Loom needs an in-process socket → QL-over-Kosmos is dead. Don't retry it.

## What's done & committed

- **Galley** `8cfc2ef "stages 1-4"`, `d337b11`: `PreviewRequestService`
  (GalleyCoreKit) is the shared renderer; `Routes.swift` is a thin FlyingFox
  adapter delegating to it; `InProcessTunnelBackend` (GalleyServerKit)
  serves the AVP tunnel by rendering in-process.
- **Kosmos** `0a0b7fa` (TunnelBackend abstraction — used by the AVP path),
  `5fd911c`/`589e01a` (direct-connect-by-address/port + `listeningPort()` —
  a general capability, currently **unused** by Galley now that QL is off
  Kosmos).
- Tests: `PreviewRequestServiceTests`, `InProcessTunnelBackendTests`,
  Kosmos `TunnelBackendTests` + direct-connect construction tests — all green.

## Uncommitted right now (commit or decide before continuing)

- **Galley** (the `serverPort` → `serverHTTPPort` rename-back; the
  Kosmos-port-for-QL idea is dead so the HTTP-port key is HTTP-named again):
  `Sources/Quicklook/Defaults.swift`, `Sources/Server/App/AppModel.swift`,
  `Sources/Viewer/Models/Defaults.swift`,
  `Sources/Viewer/Models/mac/EditorPreset.swift`, the two
  `BBEditScripts.bundle/.../in {Safari,Chrome}.sh`, `docs/…`. → commit.
- **KosmosHTTPServer**: `Adapter/Response+Serialization.swift` (new) +
  `HTTPResponses.swift`. ⚠️ **These are load-bearing — committed Galley's
  `InProcessTunnelBackend` depends on `Response.drainBody` / `.statusCode` /
  `.headerPairs`. Commit them, or the repos are inconsistent (committed
  Galley won't build against committed KosmosHTTPServer).**
- **Kosmos**: `KosmosClientLoomFactory.swift` (made `makeLoomDirect`
  public), `LoomKosmosLink.swift` (`enablePeerToPeer = directEndpoint == nil`
  for direct links). Both belong to the now-unused direct-connect capability
  — harmless. Commit as-is, or revert the whole direct-connect feature if you
  want Kosmos lean (it's not used by Galley anymore).

## Current QL behavior (working, user-confirmed)

`Sources/Quicklook/PreviewViewController.swift` (reverted to the original
HTTP path): `if let endpoint = Defaults.shared.serverEndpointURL { webView
loads endpoint/preview/<path> } else { in-process render }`.
`serverEndpointURL` is nil when `serverHTTPPort == 0`, so missing/no-server →
in-process. The Server publishes `serverHTTPPort` from
`AppModel.startServer` on each `PreviewServerController` state change.

## Make HTTP an optional component — ✅ DONE (2026-06-25)

The Kosmos/AVP tunnel path no longer links FlyingFox. `grep -rn "import
KosmosHTTPServer\|FlyingFox" Sources/GalleyCoreKit` is empty, and
`KosmosHTTPServer` appears in exactly one frameworks build phase
(GalleyServerKit's). What landed, against the original 4 steps:

1. **Neutral shaping layer** — `GalleyCoreKit/Render/PreviewResponseShaper.swift`:
   `ShapedResponse { status, headers: [String:String], body: .bytes | .eventStream }`,
   `PreviewSSE` (the exact `connectPrelude` / `reloadFrame` bytes), and
   `PreviewResponseShaper.shape(_:)` — the single source of truth for
   reload-`<script>` injection, the nonce CSP + security headers, asset
   headers, SSE headers, plain-text, and the localized error page. The
   error page resources moved here too: `Resources/ErrorPage.html` +
   the 5 error strings (en/ru) added to GalleyCoreKit's
   `Localizable.xcstrings`.
2. **`InProcessTunnelBackend` moved to GalleyCoreKit** (`Render/`), rewritten
   to map `ShapedResponse → TunnelResponseEvent` directly — no FlyingFox
   `Response`, no `drainBody`. Depends only on GalleyCoreKit +
   KosmosHTTPTunnel + KosmosAppKit (`DocumentWatcher`).
3. **FlyingFox path is now a thin adapter** — `GalleyServerKit/Routes.swift`
   `response(from:watcher:)` copies the shaped status/headers/bytes onto a
   FlyingFox `Response` (via a new generic `Response(status:headerPairs:body:)`
   in `KosmosHTTPServer/Adapter/Response+HeaderPairs.swift`) and wires the
   SSE `DocumentWatcher` subscription using `PreviewSSE` frames. The dead
   `Response.errorPage/.ok/.badRequest/.notFound` localized factories +
   `GalleyServerKit/Resources/ErrorPage.html` were removed;
   `Response+Localization.swift` keeps only the host-guard mappings.
4. **Verified at unit/integration level:** `xcodebuild -scheme Viewer build`
   + `test -skip-testing:UITests` → 195/195 logic tests pass, including new
   `PreviewResponseShaperTests` (6), the moved `InProcessTunnelBackendTests`
   (tunnel path), and the existing `ServerPreviewEndToEnd` real-socket test
   (HTTP path through the rewritten `Routes.response`). **Still needs a
   human runtime check:** AVP tunnel render on a paired device, and QL +
   browser preview, to confirm byte-parity in the wild.

### Loose ends for whoever commits this

- **`KosmosHTTPServer/Adapter/Response+Serialization.swift`** (`drainBody` /
  `statusCode` / `headerPairs`) is now **unused by Galley** — it existed only
  for the old "drain a FlyingFox Response onto the tunnel" approach this
  refactor eliminates. Revert it, or keep it as a general capability.
  `Response+HeaderPairs.swift` (new) is the one that's now load-bearing.
- `GalleyServerKit/Resources/Localizable.xcstrings` still carries the 5
  moved error strings (now authoritative in GalleyCoreKit) — harmless stale
  translation data; clean up if you care.
- Nothing was committed (per repo convention). Galley + KosmosHTTPServer +
  Kosmos all have uncommitted working trees.

## Environment gotchas (these cost real time — read them)

- **Reading logs: ALWAYS `/usr/bin/log`, never bare `log`** — `log` is a
  shell builtin that shadows the binary; bare `log show` errors "too many
  arguments" and returns nothing. Memory: `use-absolute-usr-bin-log`.
- **Testing QL:** `qlmanage -p` does NOT drive a `QLPreviewingController`
  appex. Trigger the real path: reveal a file in Finder + spacebar
  (`osascript` `key code 49`). Quick Look **caches** by file — use a fresh
  filename each test or it won't re-invoke the appex. Read results with
  `/usr/bin/log show --last … --predicate 'process == "Quicklook" …'`.
  Note QL `log.debug` lines are NOT persisted — use `.notice` to see them.
- **Build only the `Viewer` scheme** — it builds Server + Quicklook + both
  kits. After a build, `lsregister -f <Galley.app>` and relaunch the
  embedded `Galley Server.app` to pick up changes; the running Server is
  otherwise stale.
- **Don't add a `keychain-access-groups` entitlement to QL** thinking it
  helps networking — it doesn't (and `$(AppIdentifierPrefix)` is invalid
  under ad-hoc signing). The QL network denial is the sandbox, not keychain.

## Pointers

- Full plan + progress log: `docs/replace-http-server-with-kosmos.md`.
- Memories: `project_replace_http_server_with_kosmos`,
  `quicklook-appex-no-inprocess-network`, `use-absolute-usr-bin-log`.
