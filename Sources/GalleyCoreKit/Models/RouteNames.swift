import Foundation

/// Path segments shared between the HTTP server (GalleyServerKit) and
/// any in-process URL builder (GalleyCoreKit). Defined here so callers
/// that only need the names don't have to depend on the server layer.
public enum RouteNames {
  public static let preview = "preview"
  public static let template = "template"
  public static let events = "events"
}
