import Foundation

extension Template {
  /// Build a `Template` from a filesystem entry inside one of
  /// `TemplateStore`'s source directories. `entryURL` is either a
  /// directory or an HTML file. Returns `nil` if the entry doesn't
  /// match a supported shape.
  ///
  /// Two shapes are supported:
  ///
  /// - **Folder shape**: `entryURL` is a directory containing
  ///   `Template.html` (or `template.html`). The directory is the
  ///   asset root. This is Galley's native convention and how the
  ///   bundled `Default` template ships.
  /// - **File shape**: `entryURL` is a top-level `*.html` or `*.htm`
  ///   file. The parent directory (= the source root) is the asset
  ///   root, so sibling assets in the source root are reachable.
  ///   BBEdit preview-template convention.
  ///
  /// `sourceIndex` becomes part of the resulting template's `id`
  /// (`<index>.<name>`), so two templates with the same on-disk name
  /// in different sources keep distinct IDs.
  ///
  /// `nameResource`, when supplied, overrides the runtime
  /// `LocalizationValue` derivation. Bundled templates pass a literal
  /// `LocalizedStringResource` so Xcode picks the label up for
  /// translation; user templates leave it nil so filenames stay out of
  /// the strings catalog.
  init?(
    entryURL: URL,
    sourceIndex: Int,
    nameResource: String? = nil
  ) {
    let resolved = entryURL.safe

    if resolved.directoryExists {
      for fileName in ["Template.html", "template.html"] {
        let html = resolved / fileName
        if html.itemExists {
          let name = entryURL.lastPathComponent
          self.init(
            id: ID(sourceIndex: sourceIndex, name: name),
            name: nameResource ?? Self.runtimeName(for: name),
            directoryURL: resolved,
            htmlURL: html,
            sourceIndex: sourceIndex)
          return
        }
      }
      return nil
    }

    guard resolved.itemExists else { return nil }
    let pathExt = resolved.pathExtension.lowercased()
    guard pathExt == "html" || pathExt == "htm" else { return nil }

    let name = entryURL.fileName
    self.init(
      id: ID(sourceIndex: sourceIndex, name: name),
      name: nameResource ?? Self.runtimeName(for: name),
      directoryURL: resolved.parent,
      htmlURL: resolved,
      sourceIndex: sourceIndex)
  }

  /// Lookup-by-name convenience used by the bundled-default static.
  /// Treats `sourceURL` as a source directory and tries to construct a
  /// template named `name` inside it (folder shape only — file shape
  /// uses the enumerator path).
  init?(
    sourceURL: URL,
    sourceIndex: Int,
    name: String,
    nameResource: String? = nil
  ) {
    self.init(
      entryURL: sourceURL / name,
      sourceIndex: sourceIndex,
      nameResource: nameResource)
  }

  /// Wraps a runtime filename in a `LocalizationValue` so the strings
  /// catalog skips it; lookup falls back to the raw name, which is
  /// what the user sees.
  static func runtimeName(for raw: String) -> String {
    raw
  }
}
