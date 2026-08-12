// Note: `Sources/Quicklook/` belongs only to the `Quicklook` appex
// target, which the test plan does not enrol — nothing under Tests/ can
// reach `PreviewViewController`. Changes confined to the Quick Look
// extension are verified by build plus a manual preview, not by a unit
// test. Move logic into GalleyCoreKit if it needs coverage.

import Testing
@testable import GalleyCoreKit

@Test("GalleyCoreKit module loads")
func galleyCoreKitModuleLoads() {
  #expect(Bool(true))
}
