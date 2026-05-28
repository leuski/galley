import Foundation

// Hummingbird/NIO-shaped value mirror for the kit's call sites. Backed by
// `Data` rather than NIO's `ByteBuffer` so removing the Hummingbird/NIO
// dependency does not force a sweep through `Routes.swift` /
// `HTTPResponses.swift`. The two initializers exposed below
// (`init(string:)`, `init(bytes:)`) are the only ones the call sites use.
struct ByteBuffer: Sendable {
  let data: Data

  init(string: String) {
    self.data = Data(string.utf8)
  }

  init<Bytes: Sequence>(bytes: Bytes) where Bytes.Element == UInt8 {
    self.data = Data(bytes)
  }

  // Convenience for callers that already hold raw bytes. Not used by the
  // current call sites; kept so the shim mirrors NIO's surface closely
  // enough that future routes can use `ByteBuffer(...)` without surprise.
  init(bytes: Data) {
    self.data = bytes
  }
}
