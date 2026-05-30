#if os(macOS)
import Foundation
import KosmosAppKit

extension ActiveServerAgent {
  static let shared = ActiveServerAgent(
    agent: LaunchctlServerAgent(bundle: Bundle.main.serverBundle))
}
#endif
