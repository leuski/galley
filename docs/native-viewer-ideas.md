# Native Viewer Integration Ideas

Features a built-in `WKWebView`-based previewer could offer that a generic browser cannot. The HTTP server stays; the native window is additive.

Status legend: ✅ done · 🟡 partial · ⬜ not started · 🚫 will not do

## Editor coupling

- ✅ **Cmd-click in preview → editor at source line.** `SwiftMarkdownRenderer.annotatesSourceLines` emits `data-source-line`; pandoc (`+sourcepos`) and cmark-gfm (`--sourcepos`) emit `data-pos` / `data-sourcepos`. `EditorBridge` parses any of the three formats and routes through `DocumentModel.openInEditor(line:)` using the configured `EditorChoice`.
- ✅ **Open at cursor line from BBEdit.** BBEdit's `Preview Markdown… → in Galley` script invokes `galley://<path>?line=<BB_DOC_SELSTART_LINE>`; LaunchServices routes the URL into `ViewerAppDelegate`, which stashes the line and ContentView consumes it on bind / re-bind. Same-URL re-opens scroll without resetting history.
- ✅ **Open-in-editor toolbar/menu action** — `Action.openInEditor` is in the File menu and toolbar. With no explicit line, it queries the WebView for the topmost visible source-tagged block (handles `data-source-line` / `data-pos` / `data-sourcepos`) and opens the editor at that line, so the editor lands where you're reading.

## Multi-renderer / multi-template features

- 🚫 **Side-by-side renderer comparison.**
- 🚫 **Live diff between renderers.**
- ✅ **Per-document state persistence.** Two-tier: `@SceneStorage` per window (survives state restoration of an open window), and `PerFileStateStore` keyed by resolved file path for zoom / scroll / renderer / template overrides — fresh windows opening a previously-seen file hydrate from the store.
- ✅ **Template hot-swap toolbar** — renderer + template menus in both the toolbar (`RenderingCommands`) and the menu bar; `enablePerDocumentOverrides` lets each window override the global pick.

## Output and export

- ✅ **Print-to-PDF with proper page breaks.** Three entry points, all sharing one path:
  - **File > Print…** (⌘P) — standard system print panel, including the "PDF ▾" submenu.
  - **File > Page Setup…** (⇧⌘P) — standard system page-layout sheet; mutates `NSPrintInfo.shared` so subsequent prints pick up the change.
  - **File > Export as PDF…** (⇧⌘E) — runs the same print pipeline with `jobDisposition = .save` + `jobSavingURL` set on a per-op `NSPrintInfo`, panel suppressed.

  The SwiftUI `WebPage` we adopted does not expose `printOperation(with:)` (only `WKWebView` does), and `WebPage.exported(as: .pdf())` is screenshot-style: a single tall PDF page with no `@page` / `@media print` honoring and no pagination. So the Print/Export path spins up an offscreen `WKWebView` per operation, configured with a `ClassicPreviewSchemeHandler` (a `WKURLSchemeHandler` adapter that shares resolution logic with the visible `WebPage`'s SwiftUI `URLSchemeHandler`), loads the same rendered HTML the visible window shows, awaits `didFinish` via `PrintLoadBridge`, then runs `webView.printOperation(with:)`. Two non-obvious bits live in `runPrintOperation`:

  1. `printInfo.horizontalPagination` and `verticalPagination` must be `.automatic`; without them the operation prints the entire document onto one tall page (same failure mode as `exported(as:)`).
  2. We dispatch via `runModal(for:delegate:didRun:contextInfo:)`, not `runOperation()` — the latter produces blank pages because WebKit's print machinery only runs when scheduled the modal way. Documented in current Apple-forums threads; confirmed by an older CLI port of mine (yahtml2pdf, 2023).

  Template `@page { margin: 0.75in; }` and the `@media print` overrides now actually apply.
- 🚫 **Export to .docx** via pandoc.
- ✅ **Copy as rich text.** Stock WKWebView behavior: ⌘A selects the rendered document, ⌘C writes both HTML and plain-text flavors to the pasteboard as one item. Mail / Pages / Word get formatting; Terminal / Xcode get plain. No app-side code needed.
- 🚫 **Drag rendered output** out of the window as RTF/PDF.
- 🚫 **Export to standalone HTML** with template assets inlined.

## OS integration

- ✅ **Quick Look provider** for `.md`. Thin `WKWebView`-based extension fetches `http://127.0.0.1:<port>/preview/<path>` from the always-running Server; sandboxed (no filesystem, no subprocess renderers) but gets full template/processor coverage by routing through the existing engine.
- ✅ **Custom URL schemes.** `galley://<path>?line=N` is the LaunchServices entry point for cross-app launching (BBEdit script, future deep links). `x-galley://local/...` is the internal `WKURLSchemeHandler` for template/document asset resolution inside the WebView. Two layers, two names — keeps the dispatch unambiguous.
- ✅ **Native window tabs** — `OpenBehavior` includes `.newTab` (`addTabbedWindow`); also `.replaceCurrent` and `.newWindow`, settable in preferences.
- ✅ **Activation-policy switching** — gated on `AppModel.serverEnabled`. With the server **disabled** (the FTUE / pure-doc-viewer mode), the app stays `.regular` always — it's a normal doc app, like Preview.app, with conventional ⌘Q-exits semantics. With the server **enabled**, `ViewerAppDelegate.updateActivationPolicy()` flips the running app between `.regular` (Dock icon + Cmd+Tab + full menu) when any document window is bound and `.accessory` (menu-bar only, no Dock icon) when none is. The HTTP server runs across both. The last applied policy is persisted (`lastActivationPolicy` default) and re-applied in `applicationWillFinishLaunching` before state restoration runs, so a session that quit in `.accessory` mode resumes without flashing a Dock icon. With no windows up, `applicationShouldHandleReopen` presents the open panel — the only "give me UI" path while in accessory mode.
- ✅ **Soft quit** — while the server is running, ⌘Q closes all windows and drops to `.accessory` instead of terminating, so the user keeps the always-on preview behavior Server.app used to provide. The menu-bar "Quit Galley" item is the real exit (bypasses the soft-quit via `reallyQuit()`). System shutdown / restart / log-out also bypasses, detected by the Apple Event quit-reason. With the server disabled, ⌘Q exits normally.
- ⬜ **Outline/TOC sidebar.**
- ✅ **System dark/light mode follow-through.** Handled entirely by WebKit: with no app-side `NSAppearance` / `backgroundColor` / `underPageBackgroundColor` overrides, the WebView inherits `effectiveAppearance` from window → app → system, and templates that declare `:root { color-scheme: light dark; }` (built-in, github-markdown.css, etc.) pick up the dark UA palette and `prefers-color-scheme` updates live. Print/Export forces light via `@media print { :root { color-scheme: light; } }` in the template. Out of scope: auto-selecting different template *files* per appearance — covered by templates that opt into dark mode in CSS.
- ✅ **Recent files menu and document-app behaviors** — `NSDocumentController.recentDocumentURLs`, File > Open Recent, ⌘O open panel, window state restoration via `@SceneStorage` (zoom, history, scroll, overrides).

## Will not do

Decisions worth recording so future-us doesn't re-litigate them.

- 🚫 **Editor → preview live cursor tracking.** Real-time follow-the-cursor is more distracting than useful; on-open scroll-to-cursor (BBEdit script `?line=N`) covers the actual workflow. Avoids the ongoing cost of polling AppleScript / a BBEdit-side helper.
- 🚫 **ODB Editor Suite participation.** The save-notification half is already covered by `DocumentWatcher` (fsevents); the close-notification half doesn't fit our model — the previewer has no "session" tied to an editor handing it a file. The BBEdit→Galley direction is the only one we want, and a URL-scheme launch handles it more cleanly than an Apple-Event channel.
- 🚫 **Services menu entry.** The whole app is built around a real file URL — `WindowGroup<URL>`, `DocumentWatcher`, recent files, cmd-click → editor, navigation history. Services hands us a text snippet, which forces either a temp-file kludge (with broken file-watcher and useless source-line jumps) or a parallel "untitled buffer" code path that has to disable half the features. The target user always has a file.
- 🚫 **Share extension.** Same shape as the Services entry, same architectural mismatch. Sharing ad-hoc markdown text from another app isn't the workflow this previewer is built around.

## Architecture

### Decision: one app, mode-switching (not XPC)

The current shape — Server.app (menu-bar HTTP server) and Viewer.app (document windows) as separate bundles — is a duplication problem disguised as a process-count problem. Each host re-implements its own `AppModel`, `TemplateStore`, processor-catalog discovery, and UserDefaults schema. Adding a Quick Look extension would be a fourth disconnected mirror.

The chosen unification is **collapse to a single app with multiple scenes and a mode-switching activation policy**:

- Single bundle. One `AppModel`, one `TemplateStore`, one `ProcessorStore`. Server.app is retired (or kept for one release as a stub that launches the new app).
- `WindowGroup<URL>` for document windows, `MenuBarExtra` for the menu-bar control, both binding to the same `AppModel`.
- Embedded HTTP server, owned by `AppModel`, runs while the process is alive. Toggleable in settings; default on so existing menu-bar users see no behavior change.
- Registered via `SMAppService.agent` (or a `LaunchAgent` plist) so the process is always running for the logged-in user.
- `NSApplication.setActivationPolicy(.accessory)` when no windows are open (no Dock icon, menu-bar item only); flips to `.regular` when a window opens; flips back when the last window closes. Server keeps running across both states.
- ⌘Q closes all windows and drops back to `.accessory` rather than terminating. Real exit is an explicit "Quit Galley" item in the menu-bar menu.
- Quick Look extension lives in the same bundle, talks HTTP-to-localhost. Port discovery via App Group `UserDefaults` keyed shared between host and extension.

### Why not XPC service + thin clients

The architecturally pure factoring (engine in its own XPC service or LaunchAgent helper, with HTTP server, doc app, and QL extension as thin clients) was considered and rejected. Each justification for that pattern requires a project property Galley doesn't have:

- **Crash isolation** — engine isn't crashy.
- **Differential sandbox profiles** — Viewer already runs with sandbox disabled; the GUI is *not* the constrained surface.
- **Many independent clients** — three (menu bar, windows, QL).
- **Heavy engine, costly to load per-UI** — `ProcessorStore` + `TemplateStore` + a renderer, tens of MB.

The cost would be a fourth target, an `NSXPCInterface` design with `NSSecureCoding` adapters for every value type that crosses the boundary, connection lifecycle handling, and (for the always-running variant) a signed `LaunchAgent` daemon with its own install/uninstall/update flow. Not worth paying that for in-process state Galley already has.

### When to revisit

Switch to the XPC/daemon factoring if the client count grows past three meaningful surfaces. Concrete triggers, in rough order of likelihood:

- A CLI (`galley render foo.md > foo.html`) that needs to invoke the engine without spinning up the GUI app.
- A Spotlight importer for `.md` content.
- Third-party integrations that want programmatic access to the renderer.
- A genuine sandbox split (e.g. preparing for the Mac App Store, or wanting the engine in a tighter jail than the GUI).

Until then, in-process is the right default.
