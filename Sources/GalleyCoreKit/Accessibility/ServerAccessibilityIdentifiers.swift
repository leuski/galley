import Foundation

/// Single source of truth for every UITest-visible accessibility
/// identifier in the Server (Markdown Preview Server) menu-bar app.
/// Mirrors `ViewerA11yID` for the Viewer side. Tests import this
/// catalog rather than hardcoding strings.
///
/// Convention: `server.<surface>.<element>`.
public enum ServerA11yID {
  public enum MenuBar {
    public static let statusItem = "server.menubar.status"
    public static let openFile = "server.menubar.openFile"
    public static let settings = "server.menubar.settings"
    public static let processorMenu = "server.menubar.processor.menu"
    public static let processorItem = "server.menubar.processor.item"
    public static let templateMenu = "server.menubar.template.menu"
    public static let templateItem = "server.menubar.template.item"
  }

  public enum Settings {
    public static let portField = "server.settings.port"
    public static let launchAtLoginToggle = "server.settings.launchAtLogin"
    public static let processorPicker = "server.settings.processorPicker"
    public static let templatePicker = "server.settings.templatePicker"
  }
}
