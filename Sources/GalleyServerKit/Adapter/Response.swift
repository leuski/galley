import Foundation
import HTTPTypes

// Hummingbird-shaped Response + ResponseBody for the kit's call sites.
// Body is either a buffered payload (the common case — HTML strings,
// asset bytes, plain-text error envelopes) or a streaming producer
// closure for SSE (`/events/<path>`). The dispatcher in `Application`
// translates either shape into a FlyingFox `HTTPResponse`.
//
// `ResponseBody.init { writer in ... }` is the Hummingbird streaming
// shape: the producer is handed a writer that pushes chunks until it
// returns (or throws), at which point the bridge finishes the underlying
// chunked-transfer stream.

struct Response: Sendable {
  let status: HTTPResponse.Status
  let headers: HTTPFields
  let body: ResponseBody

  init(
    status: HTTPResponse.Status,
    headers: HTTPFields = HTTPFields(),
    body: ResponseBody = .empty
  ) {
    self.status = status
    self.headers = headers
    self.body = body
  }
}

struct ResponseBody: Sendable {
  enum Payload: Sendable {
    case empty
    case buffer(ByteBuffer)
    case stream(@Sendable (ResponseBodyWriter) async throws -> Void)
  }

  let payload: Payload

  init(byteBuffer: ByteBuffer) {
    self.payload = .buffer(byteBuffer)
  }

  /// Streaming body. The producer is invoked once the response head has
  /// been emitted; each `writer.write(_:)` queues a chunk for transfer
  /// to the client. `writer.finish(_:)` is optional — returning from the
  /// closure flushes and closes the stream just as well.
  init(
    _ producer: @escaping @Sendable (ResponseBodyWriter) async throws -> Void
  ) {
    self.payload = .stream(producer)
  }

  static let empty = ResponseBody(payload: .empty)

  private init(payload: Payload) {
    self.payload = payload
  }
}

/// Writer surface handed to the streaming producer closure. Mirrors
/// Hummingbird's `ResponseBodyWriter` shape: `write(_:)` pushes a chunk,
/// `finish(_:)` ends the stream (the trailer parameter is accepted for
/// signature parity but ignored — FlyingFox's chunked encoder doesn't
/// surface HTTP trailers and the kit's only streaming caller, the SSE
/// `/events/<path>` route, passes `nil`).
protocol ResponseBodyWriter: Sendable {
  func write(_ buffer: ByteBuffer) async throws
  func finish(_ trailers: HTTPFields?) async throws
}
