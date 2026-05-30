#if os(macOS)
import Foundation
import KosmosAppKit

extension Bundle {
  public var serverBundle: Bundle? {
    url(forResource: "Galley Server", withExtension: "app")
      .flatMap { url in Bundle(url: url) }
  }
}
#endif
