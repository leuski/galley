//
//  TemmlMathRenderer.swift
//  GalleyCoreKit
//
//  TeX → MathML via Temml (https://github.com/ronkok/Temml) running
//  inside JavaScriptCore. The vendored `Temml.bundle/temml.min.js`
//  (see `Scripts/sync-temml.sh`) is evaluated once per renderer into a
//  private `JSContext`; each span is one `temml.renderToString` call.
//
//  Running the converter in-process — rather than shipping KaTeX /
//  MathJax inside the templates — means the emitted HTML already
//  contains `<math>` elements that WebKit renders natively. Nothing
//  page-side has to execute, so equations come out the same in the
//  Viewer, Quick Look, print / PDF export, and over the Vision Pro
//  tunnel, and templates (including users' own) need no changes.
//
//  Temml is called with `throwOnError: false`, so a TeX parse error
//  comes back as Temml's own styled error span (`class="temml-error"`,
//  holding the source and the message) instead of being thrown; only
//  engine-level failures (bundle missing, script won't evaluate) throw.
//  Such a failure is remembered, so later spans don't retry the load
//  and re-log it.
//

import Foundation
import JavaScriptCore

public enum TeXMathError: Error, CustomStringConvertible, Sendable {
  case bundleMissing
  case scriptUnreadable(URL, String)
  case engineFailed(String)
  case renderFailed(String)

  public var description: String {
    switch self {
    case .bundleMissing:
      "GalleyCoreKit is missing Temml.bundle"
    case .scriptUnreadable(let url, let reason):
      "cannot read \(url.path): \(reason)"
    case .engineFailed(let reason):
      "Temml failed to load: \(reason)"
    case .renderFailed(let reason):
      "Temml render failed: \(reason)"
    }
  }
}

public actor TemmlMathRenderer: TeXMathRenderer {
  public static let shared = TemmlMathRenderer()

  private static let bundleName = "Temml"
  private static let scriptName = "temml.min.js"

  /// `temml.renderToString`, resolved on first use. Its `context` keeps
  /// the `JSContext` alive.
  private var renderToString: JSValue?
  /// Set once loading has failed; rethrown by every later render.
  private var loadFailure: TeXMathError?

  public init() {
  }

  public func render(_ span: MathSpan) throws(TeXMathError) -> String {
    let function = try loadedRenderToString()
    let options: [String: Any] = [
      "displayMode": span.isDisplay,
      "annotate": true,
      "throwOnError": false
    ]
    let result = function.call(withArguments: [span.tex, options])
    if let exception = function.context.exception {
      function.context.exception = nil
      throw .renderFailed(exception.toString() ?? "unknown exception")
    }
    guard let result, result.isString, let markup = result.toString() else {
      throw .renderFailed("renderToString returned a non-string")
    }
    return markup
  }

  private func loadedRenderToString() throws(TeXMathError) -> JSValue {
    if let renderToString { return renderToString }
    if let loadFailure { throw loadFailure }
    do {
      let function = try Self.loadRenderToString()
      renderToString = function
      return function
    } catch {
      loadFailure = error
      throw error
    }
  }

  private static func loadRenderToString() throws(TeXMathError) -> JSValue {
    guard let bundleURL = Bundle.galleyCoreKit.url(
      forResource: Self.bundleName, withExtension: "bundle")
    else { throw .bundleMissing }
    let scriptURL = bundleURL / Self.scriptName
    let script: String
    do {
      script = try String(contentsOf: scriptURL, encoding: .utf8)
    } catch {
      throw .scriptUnreadable(scriptURL, String(describing: error))
    }

    guard let context = JSContext() else {
      throw .engineFailed("JSContext could not be created")
    }
    context.evaluateScript(script, withSourceURL: scriptURL)
    if let exception = context.exception {
      throw .engineFailed(exception.toString() ?? "unknown exception")
    }
    guard let temml = context.objectForKeyedSubscript("temml"),
          temml.isObject,
          let function = temml.objectForKeyedSubscript("renderToString"),
          function.isObject
    else {
      throw .engineFailed("temml.renderToString is not defined")
    }
    return function
  }
}
