import Foundation
import OSLog

/// User-facing notice surfaced by `DocumentModel.notice`. The
/// `lifetime` discriminates two clear-rules:
///
/// - `.renderBound` — describes the current bind's state. Cleared at
///   the start of the next render (or by manual dismiss). Used for
///   render and load failures whose validity is tied to which file
///   the model is currently bound to.
/// - `.ephemeral` — describes a just-completed action. Auto-clears
///   after a few seconds (or by manual dismiss). Used for broken-link
///   clicks, rename failures, print failures — receipts the user has
///   already taken in but shouldn't see indefinitely.
struct DocumentNotice: Sendable, Equatable {
  enum Lifetime: Sendable, Equatable {
    case renderBound
    case ephemeral
  }

  let message: String
  let lifetime: Lifetime
}

extension DocumentModel {
  /// How long an ephemeral notice sits before fading. Long enough to
  /// read a short sentence, short enough not to outlive context.
  fileprivate static let ephemeralDuration: Duration = .seconds(6)

  /// Surface a user-visible notice. Single entry point for the banner
  /// overlay — replaces the prior scattered `lastError = …` writes.
  /// Cancels any pending auto-clear and schedules a new one for
  /// `.ephemeral` notices so action receipts fade on their own.
  func report(_ message: String, lifetime: DocumentNotice.Lifetime) {
    notice = DocumentNotice(message: message, lifetime: lifetime)
    ephemeralClearTask?.cancel()
    ephemeralClearTask = nil
    guard lifetime == .ephemeral else { return }
    ephemeralClearTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.ephemeralDuration)
      guard !Task.isCancelled, let self else { return }
      // A render-bound notice may have replaced ours while we slept;
      // only clear if the current notice is still the ephemeral one
      // this timer was scheduled for.
      if notice?.lifetime == .ephemeral {
        notice = nil
      }
      ephemeralClearTask = nil
    }
  }

  /// Convenience for failure paths. Logs at `.error` level under a
  /// consistent shape (`<context> failed: <localized>`) and surfaces
  /// the caller's user-facing message. The two are kept separate
  /// because the log line wants a grep-friendly prefix while the
  /// banner shows the localized description (or a caller-chosen
  /// message when the bare description reads as gibberish — e.g.
  /// FileManager's "The file couldn't be moved." for rename).
  func report(
    failure error: any Error,
    context: String,
    message: String? = nil,
    lifetime: DocumentNotice.Lifetime
  ) {
    let description = error.localizedDescription
    // Include the underlying NSError code + domain on the log line.
    // `localizedDescription` alone hides the discriminating data when
    // the error is a typed Swift enum that wraps an NSError — e.g.
    // `WebKit.WebPage.NavigationError error 0` prints the case index
    // rather than the actual `NSURLErrorDomain` code we need to tell
    // host-not-found from cert-pin-rejected.
    let nsError = error as NSError
    let typeName = String(reflecting: type(of: error))
    let reflected = String(reflecting: error)
    let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
    let underlyingPart = underlying.map {
      " underlyingDomain=\($0.domain) underlyingCode=\($0.code)"
    } ?? ""
    logger.error("""
      \(context, privacy: .public) failed: \
      \(description, privacy: .public) \
      type=\(typeName, privacy: .public) \
      domain=\(nsError.domain, privacy: .public) \
      code=\(nsError.code, privacy: .public)\
      \(underlyingPart, privacy: .public) \
      reflected=\(reflected, privacy: .public)
      """)
    report(message ?? description, lifetime: lifetime)
  }

  /// Dismiss the current notice. Banner close button calls this.
  func dismissNotice() {
    ephemeralClearTask?.cancel()
    ephemeralClearTask = nil
    notice = nil
  }

  /// Clear `notice` if (and only if) it is render-bound. Called at
  /// the start of every render. Ephemeral notices — broken-link banner,
  /// print/rename receipts — are left in place: those describe
  /// completed actions whose validity is unrelated to the bind.
  func clearRenderBoundNotice() {
    guard notice?.lifetime == .renderBound else { return }
    ephemeralClearTask?.cancel()
    ephemeralClearTask = nil
    notice = nil
  }
}
