import SwiftUI

/// Wrap `withAnimation` in an accessibility-aware shim so callers can
/// pass the live `reduceMotion` env value and have it short-circuit
/// the animation when the user has enabled "Reduce Motion." Threading
/// the env through call sites lets every animated mutation in the
/// Viewer honor the setting without each call site re-implementing
/// the check.
public func withAnimationAsNeeded<Result>(
  _ reduceMotion: Bool,
  _ animation: Animation? = .default,
  _ body: () throws -> Result) rethrows -> Result
{
  if reduceMotion {
    try body()
  } else {
    try withAnimation(animation, body)
  }
}
