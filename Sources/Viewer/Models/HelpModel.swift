import Foundation
import Observation

/// Holds the URL the singleton Help window should display.
///
/// The Help scene is a SwiftUI `Window(id: "help")` — singular, not a
/// `WindowGroup<URL>`, so SwiftUI cannot persist a URL binding for us.
/// We store the current help URL here and the help scene reads it.
/// Setting `currentURL` and then calling `openWindow(id: "help")`
/// either spawns the help window or brings the existing one forward;
/// the content view follows the observed URL.
@MainActor
@Observable
final class HelpModel {
  var currentURL: URL?

  init() {}
}
