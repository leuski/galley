#if os(macOS)
import SwiftUI

/// Restores the app-menu "Settings…" item + ⌘, for the Settings window.
///
/// Settings used to be SwiftUI's special `Settings {}` scene, which
/// provides that item and shortcut automatically — but that scene
/// ignores `handlesExternalEvents`, so it can't be opened by the
/// `galley-settings://` deep link. We moved Settings to a plain
/// `Window(id: MacScene.settings)` (which *does* honor scheme routing);
/// a plain window gets neither the menu item nor ⌘, for free, so we add
/// them here. `openWindow` is available via `@Environment` in `Commands`.
struct SettingsCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .appSettings) {
      Button("Settings…", systemImage: "gearshape") {
        openWindow(id: MacSettingsScene.id)
      }
      .keyboardShortcut(",", modifiers: .command)
    }
  }
}
#endif
