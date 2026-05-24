#if os(macOS)
import Testing
@testable import GalleyServerKit

@Test("GalleyServerKit module loads")
func galleyServerKitModuleLoads() {
  #expect(Bool(true))
}
#endif
