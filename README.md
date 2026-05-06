# Galley

A native macOS Markdown viewer. Open a `.md` file and Galley renders it through
your chosen processor, wraps it in a styleable HTML template, and reloads when
the file changes on disk. Cmd-click any rendered block to jump straight back to
the source line in your editor.

<!-- TODO: screenshot — main viewer window with a document open -->

The same rendering engine also powers a companion menu-bar app, **Markdown
Preview Server**, which serves the preview over HTTP so any browser (or
BBEdit's preview pane) can view it.

## Galley — the viewer

A document app, not a browser. One window walks through linked documents:
click an `.md` link in the rendered output and the same window navigates to
it, back/forward history included. External links open in your default
browser; non-Markdown local files open in the right app.

### Highlights

- **Cmd-click to editor** — any rendered block carries a source-line
  annotation. Cmd-click and Galley opens that line in your editor. Works with
  swift-markdown, Pandoc (`data-pos`), and cmark-gfm (`data-sourcepos`).
- **BBEdit integration** — install the bundled `Preview Markdown… in Galley`
  script and previewing from BBEdit focuses an existing Galley window for
  that document or opens a new one, scrolled to the current line.
- **Editor of choice** — built-in presets for BBEdit, TextMate, VS Code,
  Sublime Text, and Zed; a custom URL template with `{url}`/`{path}`/`{line}`
  placeholders; or any `.app` bundle.
- **Processors and templates** — same picker as the Server (see below).
  Per-document overrides are optional and persist across launches.
- **Print, Page Setup, Export as PDF** — full pipeline through a real
  `WKWebView` so the printed output matches what you see.
- **Per-document state** — zoom, scroll position, and processor/template
  overrides are remembered per file across launches.

<!-- TODO: screenshot — cmd-click jumping back to BBEdit at the right line -->

### `galley://` URL scheme

Galley registers `galley://<absolute-path>?line=N`. Dropping that URL into a
script or `open(1)` focuses Galley on that document at that line. The
bundled BBEdit script uses this to drive previews from the editor.

## Markdown Preview Server — the menu-bar app

A `MenuBarExtra`-only app that runs an HTTP server in-process. Same renderers,
same templates — served at `http://127.0.0.1:<port>/preview/<absolute path>`
so any browser works.

<!-- TODO: screenshot — menu bar dropdown with processor/template pickers -->

### Routes

- `GET /preview/<absolute file path>` — renders a Markdown file as HTML.
  Non-Markdown extensions fall through to static-asset serving from the
  document's directory (images, CSS, fonts).
- `GET /template/<template-id>/<file>` — serves assets bundled with the
  selected template.
- `GET /events/<absolute file path>` — Server-Sent Events for live reload. A
  small client script is injected into every preview and refreshes the page
  on each event.

A file watcher pushes a reload event whenever the document or any sibling
asset changes.

## Markdown processors

Both apps share a BBEdit-style picker of supported processors:

| Processor | Install |
|---|---|
| Default (swift-markdown) | bundled |
| MultiMarkdown | `brew install multimarkdown` |
| Discount | `brew install discount` |
| Pandoc | `brew install pandoc` |
| cmark-gfm | `brew install cmark-gfm` |
| Classic (Markdown.pl) | place `Markdown.pl` on `PATH` |

Unavailable processors stay visible so you can see what would be selectable
after installing the underlying tool. Your preference persists even when the
tool is missing — reinstalling it brings the selection back without further
input.

## Templates

Output is wrapped in an HTML template. A built-in template is always
available; custom templates live in:

```
~/Library/Application Support/MarkdownPreviewer/Templates/
```

Two layouts are recognized:

- a folder containing `Template.html` (or `template.html`) plus its assets
  (Galley convention), or
- a top-level `*.html` / `*.htm` file with sibling assets (BBEdit
  preview-template convention).

The template store watches the directory and picks up additions and edits
without restarting either app.

Templates may use these placeholders, substituted on every render:

| Placeholder | Replaced with |
|---|---|
| `#DOCUMENT_CONTENT#` | The rendered HTML body |
| `#TITLE#` | Document base name |
| `#BASE#` | URL prefix for resolving relative links |
| `#FILE#` | Document filename |
| `#BASENAME#` | Filename without extension |
| `#FILE_EXTENSION#` | Filename extension |
| `#DATE#` | Today's date |
| `#TIME#` | Current time |

Asset references inside the template (e.g. `<link href="style.css">`) are
rewritten to point at `/template/<id>/...` so they resolve in either app —
HTTP for the Server, the `x-galley://local` scheme handler for Galley.

## BBEdit scripts

Both apps install the same family of helper scripts into:

```
~/Library/Application Support/BBEdit/Scripts/
```

- **Galley** — `Preview Markdown… in Galley.sh`. Sends a `galley://` URL with
  the current line.
- **Server** — `Preview Markdown… in Safari.sh`,
  `Preview Markdown… in Google Chrome.sh`. Open the preview URL on the running
  server in the chosen browser.

The installer rewrites the hardcoded server URL in the browser scripts to
match the running server's host and port. Run the script from BBEdit
(Scripts menu, or bind a key) and the previewer focuses an existing tab/window
or opens a new one.

Any other editor that can shell out to a URL works the same way.

## Settings

### Galley

- **Markdown processor** and **Template** pickers (with optional
  per-document overrides).
- **Editor** — preset, custom URL, or `.app` bundle.
- **Open behavior** for incoming URLs — new window, new tab, or replace
  current.

### Markdown Preview Server

- **Port** — TCP port the server binds to (default `8089`). The server
  restarts automatically when changed.
- **Markdown processor** and **Template** pickers.
- **Launch at login** — registered via `SMAppService`.

## Building

Open `MarkdownPreviewer.xcodeproj` in Xcode. Two app schemes:

- **Viewer** — Galley.
- **Server** — Markdown Preview Server.

Two framework schemes (mostly for direct iteration):

- **GalleyCoreKit** — rendering, templates, file watching, routing, scripts.
- **GalleyServerKit** — the FlyingFox-backed HTTP server.

```bash
xcodebuild -project MarkdownPreviewer.xcodeproj -scheme Viewer build
xcodebuild -project MarkdownPreviewer.xcodeproj -scheme Server build

# Tests (Swift Testing for logic, XCUITest for UI)
xcodebuild -project MarkdownPreviewer.xcodeproj -scheme Viewer test
```

The project uses Swift's structured concurrency throughout (`@Observable`,
actors, typed `async`/`await`) with Swift 6 strict concurrency enabled.

## License

[MIT](LICENSE) © Anton Leuski
