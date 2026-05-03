import Foundation
import Testing
@testable import GalleyCoreKit

@Suite("LaunchArguments")
struct LaunchArgumentsTests {
  @Test("Empty arg list yields all defaults")
  func emptyDefaults() {
    let args = LaunchArguments.parse(arguments: ["/path/to/Galley"])
    #expect(args == LaunchArguments())
    #expect(!args.uiTestMode)
    #expect(!args.resetState)
    #expect(args.scratchDirectory == nil)
    #expect(args.seedFile == nil)
    #expect(args.mockEditorTemplate == nil)
    #expect(args.fixedPort == nil)
  }

  @Test("--ui-test-mode implies --reset-state")
  func uiTestModeImpliesReset() {
    let args = LaunchArguments.parse(arguments: ["app", "--ui-test-mode"])
    #expect(args.uiTestMode)
    #expect(args.resetState)
  }

  @Test("--no-reset-state suppresses the implication")
  func noResetState() {
    let args = LaunchArguments.parse(arguments: [
      "app", "--ui-test-mode", "--no-reset-state"
    ])
    #expect(args.uiTestMode)
    #expect(!args.resetState)
  }

  @Test("Equals form: --scratch-dir=/tmp/x")
  func scratchEqualsForm() {
    let args = LaunchArguments.parse(arguments: [
      "app", "--scratch-dir=/tmp/scratch-xyz"
    ])
    #expect(args.scratchDirectory == URL(fileURLWithPath: "/tmp/scratch-xyz"))
  }

  @Test("Space-separated form: --scratch-dir /tmp/x")
  func scratchSpaceForm() {
    let args = LaunchArguments.parse(arguments: [
      "app", "--scratch-dir", "/tmp/scratch-xyz"
    ])
    #expect(args.scratchDirectory == URL(fileURLWithPath: "/tmp/scratch-xyz"))
  }

  @Test("--seed-file with path containing spaces")
  func seedFileWithSpaces() {
    let args = LaunchArguments.parse(arguments: [
      "app", "--seed-file", "/tmp/foo bar.md"
    ])
    #expect(args.seedFile?.path == "/tmp/foo bar.md")
  }

  @Test("--mock-editor template with placeholders")
  func mockEditorTemplate() {
    let args = LaunchArguments.parse(arguments: [
      "app", "--mock-editor=/tmp/log.txt:{path}:{line}"
    ])
    #expect(args.mockEditorTemplate == "/tmp/log.txt:{path}:{line}")
  }

  @Test("--fixed-port parses valid uint16")
  func fixedPortValid() {
    let args = LaunchArguments.parse(arguments: ["app", "--fixed-port=8080"])
    #expect(args.fixedPort == 8080)
  }

  @Test("--fixed-port with non-numeric value is dropped")
  func fixedPortInvalid() {
    let args = LaunchArguments.parse(arguments: ["app", "--fixed-port=lol"])
    #expect(args.fixedPort == nil)
  }

  @Test("--fixed-port with out-of-range value is dropped")
  func fixedPortOutOfRange() {
    let args = LaunchArguments.parse(arguments: ["app", "--fixed-port=99999"])
    #expect(args.fixedPort == nil)
  }

  @Test("Unknown flags are ignored, known flags still parse")
  func unknownFlagsTolerated() {
    let args = LaunchArguments.parse(arguments: [
      "app",
      "--ui-test-mode",
      "--unknown-flag",
      "--something-else=value",
      "--reset-state"
    ])
    #expect(args.uiTestMode)
    #expect(args.resetState)
  }

  @Test("Trailing flag without value is dropped")
  func trailingFlagWithoutValue() {
    let args = LaunchArguments.parse(arguments: ["app", "--scratch-dir"])
    #expect(args.scratchDirectory == nil)
  }

  @Test("All flags together")
  func fullCombo() {
    let args = LaunchArguments.parse(arguments: [
      "app",
      "--ui-test-mode",
      "--scratch-dir=/tmp/s",
      "--seed-file=/tmp/note.md",
      "--mock-editor=/tmp/log.txt",
      "--fixed-port=12345"
    ])
    #expect(args.uiTestMode)
    #expect(args.resetState)
    #expect(args.scratchDirectory == URL(fileURLWithPath: "/tmp/s"))
    #expect(args.seedFile == URL(fileURLWithPath: "/tmp/note.md"))
    #expect(args.mockEditorTemplate == "/tmp/log.txt")
    #expect(args.fixedPort == 12345)
  }
}
