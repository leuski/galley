# Making a Template for Galley

A Galley template is an HTML file with placeholders that Galley fills in
before showing your document. You can author your own template to control
fonts, colors, layout, page chrome — anything HTML and CSS can express.

## Where templates live

Templates live in
[`~/Library/Application Support/Galley/Templates/`](~/Library/Application%20Support/net.leuski.galley.localized/).
Drop your templates into the folder.

Galley watches this folder. New templates appear in the **View → Template**
menu as soon as you save them, and edits to a live template re-render any
open document instantly.

You can also reach the folder from **Settings → Templates → Reveal
Templates Folder**.

## Two shapes

### Folder shape (Galley convention)

A directory with `Template.html` inside, plus any sibling assets you need.
The folder's name is the template's user-facing label.

```
Templates/
└── MyTheme/
      ├── Template.html
      ├── style.css
      ├── fonts/
      │   └── MyFont.woff2
      └── LICENSE
```

References from `Template.html` are relative to the folder —
`<link rel="stylesheet" href="style.css">` resolves inside `MyTheme/`.

### File shape (BBEdit convention)

A single top-level `*.html` or `*.htm` file. The filename without
extension becomes the template label.

```
Templates/
├── MyTheme.html
├── shared-style.css
└── shared-font.woff2
```

Sibling assets in the same Templates folder are reachable, so file-shape
templates can share resources. This makes Galley compatible with BBEdit's
preview templates — drop a BBEdit template into Galley's folder unchanged
and it works. Alternatively, you can place the resources into a subfolder,
while keeping the main template file in the root.

```
Templates/
├── MyTheme.html
└── MyTheme/
      ├── shared-style.css
      └── shared-font.woff2
```

## Placeholders

Galley substitutes these tokens into your template before rendering.
Token names match BBEdit's conventions.

| Token                  | Expands to                                                                   |
| ---------------------- | ---------------------------------------------------------------------------- |
| `#DOCUMENT_CONTENT#`   | The rendered HTML body of the markdown document. **Required.**               |
| `#TITLE#`              | The document's title (first heading if present; otherwise the filename).     |
| `#BASE#`               | The URL that relative paths resolve under. Put in `<base href="#BASE#">`.    |
| `#FILE#`               | Absolute filesystem path of the source document.                             |
| `#BASENAME#`           | The filename without extension.                                              |
| `#FILE_EXTENSION#`     | The extension (e.g. `md`).                                                   |
| `#DATE#`               | Today's date.                                                                |
| `#TIME#`               | The current time.                                                            |

## The minimum template

Everything you need is six lines plus a doctype:

```html
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>#TITLE#</title>
    <base href="#BASE#">
</head>
<body>
#DOCUMENT_CONTENT#
</body>
</html>
```

Save as `Templates/Minimal.html` (file shape) or
`Templates/Minimal/Template.html` (folder shape).

## A practical example

A folder-shape template with its own stylesheet and a dark variant:

```
Notes/
├── Template.html
└── style.css
```

`Template.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title>#TITLE#</title>
    <base href="#BASE#">
    <link rel="stylesheet" href="style.css">
</head>
<body>
<article>
#DOCUMENT_CONTENT#
</article>
</body>
</html>
```

`style.css`:

```css
:root {
    color-scheme: light dark;
    --bg: #fafafa;
    --fg: #222;
}

@media (prefers-color-scheme: dark) {
    :root {
        --bg: #1c1c1e;
        --fg: #e7e7e9;
    }
}

body {
    background: var(--bg);
    color: var(--fg);
    font: 16px/1.6 -apple-system, system-ui, sans-serif;
    margin: 2rem auto;
    max-width: 38rem;
    padding: 0 1.5rem;
}
```

## Tips

- **Hot reload.** Save `Template.html` or any CSS file in the template's
  folder and the watcher picks it up immediately. No restart, no document
  reopen.
- **`<base href="#BASE#">` matters.** Without it, `<img src="diagram.png">`
  references inside your markdown can't resolve to files next to the
  source document. With it, they do.
- **Use relative paths for your assets.** Galley rewrites `style.css` into
  `/template/<id>/style.css` and serves it from your folder. Absolute
  paths defeat the rewrite.
- **Light and dark.** Use `@media (prefers-color-scheme: dark)` so your
  template follows the system. Galley does not force a mode.
- **Print.** Add `@media print { … }` rules so the template looks right
  in **File → Export as PDF** and **File → Print**.

## Mermaid diagrams

If your markdown includes ` ```mermaid ` blocks, Galley auto-initializes
mermaid for you — no script needed in your template if you load
`mermaid.min.js` from the bundle:

```html
<script src="Common.js"></script>
<script src="mermaid.min.js"></script>
<script>
  if (window.mermaid) {
    window.mermaid.initialize({
      startOnLoad: true,
      theme: matchMedia('(prefers-color-scheme: dark)').matches
        ? 'dark' : 'default'
    });
  }
</script>
```

`Common.js` and `mermaid.min.js` are siblings of your template inside
Galley's built-in `Templates.bundle/`. For user templates, copy them in
yourself or omit if you don't need diagrams.

Style the `.mermaid` class in your CSS to size and center diagrams.

## Per-document overrides

In **Settings → Templates**, the *Enable per-document overrides* toggle
lets each document remember its own template choice. Useful when one
folder of notes should always render in Sepia while another always
renders in Tufte.

## Look at the built-in templates

Galley ships nine built-in templates. They aren't editable in place, but
their source CSS is a good reference. Two especially worth peeking at:

- **Default** — the simplest complete example. Sans body, light/dark,
  print rules.
- **Tufte** — vendored upstream CSS plus a tiny Galley-side overrides
  file. Shows how to layer your own rules on top of an external
  stylesheet without forking it.

You can find the [built-ins inside the app bundle]({{GALLEY_APP_FINDER_URL}}/Contents/Frameworks/GalleyCoreKit.framework/Resources/Templates.bundle/Default.html).
