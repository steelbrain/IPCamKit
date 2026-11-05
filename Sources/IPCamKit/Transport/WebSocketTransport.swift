// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// RTSP over WebSocket (ONVIF Streaming Specification), with a minimal RFC 6455
// client over the plain TCP/TLS connection.

import CryptoKit
import Foundation
import Network

// Why not `NWProtocolWebSocket`: its client handshake sends `Upgrade:
// WebSocket`, and mediamtx v1.21.2 (gortsplib) answers that with `400 Bad
// Request` because it compares the token case-sensitively, so the connection
// never opens (NWConnection parks in `.waiting` with ECONNABORTED). Observed on
// macOS 27.0.1; Network's API can't change that header. mediamtx's `101` also
// omits the `Sec-WebSocket-Protocol` echo, which RFC 6455 lets a client treat
// as a failure. And Network gives a WebSocket client no access to a `401`
// response's `WWW-Authenticate` challenge, so HTTP authentication would be
// impossible. The handshake and the framing RTSP needs are small, so this file
// implements them over the same `NWConnection` setup the direct transport uses
// (and so the same TLS options and connect timeout).

// MARK: - Frames

/// RFC 6455 frame opcodes.
enum WebSocketOpcode: UInt8, Sendable {
  case continuation = 0x0
  case text = 0x1
  case binary = 0x2
  case close = 0x8
  case ping = 0x9
  case pong = 0xA

  /// Close, ping and pong are control frames (opcode high bit set).
  var isControl: Bool { rawValue & 0x8 != 0 }
}

/// A violation of RFC 6455 by the server, with the status code to close with.
struct WebSocketProtocolError: Error, Equatable, Sendable {
  /// 1002 (protocol error), 1007 (a text message that isn't UTF-8) or 1009
  /// (message too big).
  let closeCode: UInt16
  let message: String
}

/// RFC 6455 frame encoding.
enum WebSocketFrame {
  /// Encode one frame carrying `payload`.
  ///
  /// Frames a client sends must be masked (RFC 6455 section 5.3), so the
  /// client always passes a fresh random `maskKey`; `nil` (an unmasked frame)
  /// is what a server sends, which tests use to play the server.
  static func encode(
    opcode: WebSocketOpcode, payload: Data, fin: Bool = true, maskKey: UInt32?
  ) -> Data {
    var frame = Data()
    frame.reserveCapacity(payload.count + 14)
    frame.append((fin ? 0x80 : 0) | opcode.rawValue)
    let maskBit: UInt8 = maskKey == nil ? 0 : 0x80
    let length = payload.count
    if length < 126 {
      frame.append(maskBit | UInt8(length))
    } else if length <= 0xFFFF {
      frame.append(maskBit | 126)
      frame.append(UInt8(length >> 8))
      frame.append(UInt8(length & 0xFF))
    } else {
      frame.append(maskBit | 127)
      let wide = UInt64(length)
      for shift in stride(from: 56, through: 0, by: -8) {
        frame.append(UInt8(truncatingIfNeeded: wide >> UInt64(shift)))
      }
    }
    if let maskKey {
      let keyBytes = maskKeyBytes(maskKey)
      frame.append(contentsOf: keyBytes)
      var masked = Data(payload)
      applyMask(keyBytes, to: &masked)
      frame.append(masked)
    } else {
      frame.append(payload)
    }
    return frame
  }

  /// The four key bytes of `maskKey`, most significant first, as they appear
  /// on the wire.
  static func maskKeyBytes(_ maskKey: UInt32) -> [UInt8] {
    [
      UInt8(maskKey >> 24), UInt8((maskKey >> 16) & 0xFF), UInt8((maskKey >> 8) & 0xFF),
      UInt8(maskKey & 0xFF),
    ]
  }

  /// XOR `data` with the repeating 4-byte `key` (masking and unmasking are the
  /// same operation).
  static func applyMask(_ key: [UInt8], to data: inout Data) {
    guard key.count == 4 else { return }
    data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
      for index in 0..<bytes.count {
        bytes[index] ^= key[index & 3]
      }
    }
  }

  /// The payload of a close frame with `code` (no reason text).
  static func closePayload(_ code: UInt16) -> Data {
    Data([UInt8(code >> 8), UInt8(code & 0xFF)])
  }
}

/// Splits the bytes a WebSocket server sends into frames.
///
/// Data frames (binary, text, and continuations of either) are delivered as
/// they complete, so a fragmented message arrives as its fragments' payloads
/// in order. For a byte-stream consumer like RTSP that is the reassembled
/// message without buffering it whole. The fragment sequence is still checked.
/// Only one frame is buffered at a time, up to `maxPayloadBytes`.
struct WebSocketFrameDecoder: Sendable {
  /// What one complete frame means to the client.
  enum Event: Equatable, Sendable {
    /// Payload of a data frame (possibly one fragment of a message).
    case data(Data)
    case ping(Data)
    case pong(Data)
    /// The server is closing; `code` is nil when the frame had no payload.
    case close(code: UInt16?, reason: String)
  }

  /// Largest frame payload accepted. A frame announcing more is a protocol
  /// error (1009) instead of an unbounded buffer.
  let maxPayloadBytes: Int
  private var buffer = Data()
  /// Whether a data message with FIN clear is waiting for continuations.
  private var inFragmentedMessage = false
  /// Whether the message being received is text, which must be UTF-8 (RFC
  /// 6455 section 8.1). The RTSP stream reads it as bytes like binary.
  private var inTextMessage = false
  /// The start of a UTF-8 sequence that the last text fragment ended inside.
  private var partialUTF8 = Data()

  init(maxPayloadBytes: Int = RTSPTransportConnection.maxReadBufferBytes) {
    self.maxPayloadBytes = maxPayloadBytes
  }

  /// Bytes received but not yet decoded into a frame.
  var bufferedByteCount: Int { buffer.count }

  /// Add bytes received from the server.
  mutating func append(_ data: Data) {
    buffer.append(data)
  }

  /// Decode the next frame, or return `nil` until enough bytes have arrived.
  mutating func next() throws(WebSocketProtocolError) -> Event? {
    guard buffer.count >= 2 else { return nil }
    let start = buffer.startIndex
    let first = buffer[start]
    let second = buffer[start + 1]
    let fin = first & 0x80 != 0
    guard first & 0x70 == 0 else {
      throw protocolError("reserved bits set without a negotiated extension")
    }
    guard let opcode = WebSocketOpcode(rawValue: first & 0x0F) else {
      throw protocolError("unknown opcode \(first & 0x0F)")
    }
    guard second & 0x80 == 0 else {
      throw protocolError("server sent a masked frame")
    }

    var length = UInt64(second & 0x7F)
    var headerLength = 2
    if length == 126 {
      guard buffer.count >= 4 else { return nil }
      length = UInt64(buffer[start + 2]) << 8 | UInt64(buffer[start + 3])
      headerLength = 4
      // RFC 6455 section 5.2: the minimal number of bytes MUST be used.
      guard length >= 126 else { throw protocolError("16-bit length \(length) under 126") }
    } else if length == 127 {
      guard buffer.count >= 10 else { return nil }
      length = 0
      for offset in 2..<10 {
        length = length << 8 | UInt64(buffer[start + offset])
      }
      headerLength = 10
      guard length >> 63 == 0 else { throw protocolError("64-bit length with the top bit set") }
      guard length > 0xFFFF else { throw protocolError("64-bit length \(length) under 65536") }
    }
    if opcode.isControl {
      guard fin else { throw protocolError("fragmented control frame") }
      guard length <= 125 else { throw protocolError("control frame payload over 125 bytes") }
    }
    guard length <= UInt64(maxPayloadBytes) else {
      throw WebSocketProtocolError(
        closeCode: 1009,
        message: "frame payload of \(length) bytes exceeds \(maxPayloadBytes) bytes")
    }
    let frameLength = headerLength + Int(length)
    guard buffer.count >= frameLength else { return nil }
    let payload = Data(buffer[(start + headerLength)..<(start + frameLength)])
    buffer.removeSubrange(start..<(start + frameLength))

    switch opcode {
    case .continuation:
      guard inFragmentedMessage else {
        throw protocolError("continuation frame without a message to continue")
      }
      inFragmentedMessage = !fin
      if inTextMessage { try checkUTF8(payload, final: fin) }
      return .data(payload)
    case .text, .binary:
      guard !inFragmentedMessage else {
        throw protocolError("new data message before the fragmented one finished")
      }
      inFragmentedMessage = !fin
      inTextMessage = opcode == .text
      if inTextMessage { try checkUTF8(payload, final: fin) }
      return .data(payload)
    case .ping:
      return .ping(payload)
    case .pong:
      return .pong(payload)
    case .close:
      guard !payload.isEmpty else { return .close(code: nil, reason: "") }
      guard payload.count >= 2 else { throw protocolError("close frame with a 1-byte payload") }
      let code = UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1])
      // Codes that may appear in a close frame (RFC 6455 section 7.4); 1005,
      // 1006 and 1015 are for local use only, and the rest are unassigned.
      guard
        (1000...1003).contains(code) || (1007...1014).contains(code)
          || (3000...4999).contains(code)
      else { throw protocolError("close frame with status code \(code)") }
      guard let reason = String(bytes: payload.dropFirst(2), encoding: .utf8) else {
        throw protocolError("close frame reason isn't UTF-8")
      }
      return .close(code: code, reason: reason)
    }
  }

  private func protocolError(_ message: String) -> WebSocketProtocolError {
    WebSocketProtocolError(closeCode: 1002, message: message)
  }

  /// Check that a text fragment continues valid UTF-8. A sequence the
  /// fragment ends inside is kept for the next one; the final fragment must
  /// end on a character boundary.
  private mutating func checkUTF8(_ payload: Data, final: Bool) throws(WebSocketProtocolError) {
    let bytes = partialUTF8 + payload
    var cut = bytes.endIndex
    if !final {
      // Walk back over at most 3 continuation bytes to the sequence's lead
      // byte; keep the sequence back if it needs more bytes than are here.
      var index = bytes.endIndex
      while index > bytes.startIndex, bytes.endIndex - index < 3 {
        index -= 1
        let byte = bytes[index]
        if byte & 0xC0 == 0x80 { continue }
        if byte >= 0xC0 {
          let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
          if bytes.endIndex - index < length { cut = index }
        }
        break
      }
    }
    let complete = bytes[bytes.startIndex..<cut]
    guard String(decoding: complete, as: UTF8.self).utf8.elementsEqual(complete) else {
      throw WebSocketProtocolError(closeCode: 1007, message: "text message isn't UTF-8")
    }
    partialUTF8 = Data(bytes[cut...])
    if final { inTextMessage = false }
  }
}

// MARK: - Handshake

/// RTSP over WebSocket as the ONVIF Streaming Specification defines it: an
/// RFC 6455 connection with subprotocol `rtsp.onvif.org` whose binary messages
/// carry the RTSP byte stream (requests, responses and `$` interleaved data).
enum WebSocketTransport {
  /// The ONVIF RTSP-over-WebSocket subprotocol.
  static let subprotocol = "rtsp.onvif.org"
  /// RFC 6455 section 1.3 GUID for `Sec-WebSocket-Accept`.
  static let acceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  /// A fresh `Sec-WebSocket-Key`: 16 random bytes, base64.
  static func makeKey() -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }
    return Data(bytes).base64EncodedString()
  }

  /// The `Sec-WebSocket-Accept` a server must answer `key` with.
  static func acceptValue(forKey key: String) -> String {
    Data(Insecure.SHA1.hash(data: Data((key + acceptGUID).utf8))).base64EncodedString()
  }

  /// The upgrade request head.
  static func upgradeRequest(
    endpoint: HTTPEndpoint, key: String, userAgent: String?, authorization: RTSPHeaderValue?
  ) -> Data {
    var headers: [(String, String)] = [
      ("Host", endpoint.hostHeader),
      ("Upgrade", "websocket"),
      ("Connection", "Upgrade"),
      ("Sec-WebSocket-Key", key),
      ("Sec-WebSocket-Version", "13"),
      ("Sec-WebSocket-Protocol", subprotocol),
    ]
    if let userAgent { headers.append(("User-Agent", userAgent)) }
    return httpRequestHead(
      method: "GET", target: endpoint.target, version: "HTTP/1.1", headers: headers,
      authorization: authorization)
  }

  /// Check a `101` response against RFC 6455 section 4.1. The subprotocol
  /// echo is optional because mediamtx omits it; a different subprotocol, an
  /// extension, or a wrong `Sec-WebSocket-Accept` is rejected.
  static func validateUpgrade(_ head: HTTPResponseHead, key: String) throws {
    func fail(_ reason: String) -> RTSPError {
      .connectionFailed("WebSocket upgrade rejected: \(reason)")
    }
    // Every line of a header counts: repeated lines are one comma-separated
    // list (RFC 9110 section 5.3), so a second line can't slip past a check.
    func tokens(_ name: String) -> [String] {
      head.headers(named: name).flatMap { $0.split(separator: ",") }.map {
        $0.trimmingCharacters(in: .whitespaces).lowercased()
      }.filter { !$0.isEmpty }
    }
    let upgrade = tokens("Upgrade")
    guard upgrade.contains("websocket") else {
      throw fail("missing \"Upgrade: websocket\"")
    }
    guard upgrade.allSatisfy({ $0 == "websocket" }) else {
      throw fail(
        "Upgrade names more than websocket: \(quotedForMessage(upgrade.joined(separator: ", ")))")
    }
    guard tokens("Connection").contains("upgrade") else {
      throw fail("missing \"Connection: Upgrade\"")
    }
    let accepts = head.headers(named: "Sec-WebSocket-Accept")
    guard accepts.count <= 1 else { throw fail("more than one Sec-WebSocket-Accept") }
    guard accepts.first == acceptValue(forKey: key) else {
      throw fail("Sec-WebSocket-Accept does not match the key")
    }
    // An empty line chooses no subprotocol, as an absent one does.
    let protocols = head.headers(named: "Sec-WebSocket-Protocol").filter {
      !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }
    if !protocols.isEmpty, protocols != [subprotocol] {
      let chosen = quotedForMessage(protocols.joined(separator: ", "))
      throw fail("server chose subprotocol \(chosen), not \(subprotocol)")
    }
    let extensions = head.headers(named: "Sec-WebSocket-Extensions").filter {
      !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }
    if !extensions.isEmpty {
      throw fail(
        "server enabled extensions that were not offered: "
          + cutForMessage(extensions.joined(separator: ", ")))
    }
  }

  /// Open the WebSocket for `url` (`ws://` or `wss://`).
  static func connect(
    url: URL, tls: TLSOptions, credentials: Credentials?, userAgent: String?,
    opener: ConnectionOpener
  ) async throws -> EstablishedStream {
    let endpoint = try HTTPEndpoint(url: url, plainScheme: "ws", tlsScheme: "wss")
    let agent = userAgent.map(sanitizedHeaderValue).flatMap { $0.isEmpty ? nil : $0 }
    // A fresh key per request (the 401 retry is a new connection).
    var key = ""
    let upgrade = try await exchangeHTTPWithAuthRetry(
      endpoint: endpoint, tls: tls, opener: opener, credentials: credentials, method: "GET",
      what: "WebSocket upgrade \(endpoint.shownTarget)"
    ) { authorization in
      key = makeKey()
      return upgradeRequest(
        endpoint: endpoint, key: key, userAgent: agent, authorization: authorization)
    }
    do {
      guard upgrade.head.statusCode == 101 else {
        throw RTSPError.connectionFailed(
          "WebSocket upgrade \(endpoint.shownTarget) failed: \(upgrade.head.statusDescription)")
      }
      try validateUpgrade(upgrade.head, key: key)
    } catch {
      upgrade.connection.cancel()
      throw error
    }
    // Bytes after the 101 head are already WebSocket frames.
    let stream = WebSocketByteStream(connection: upgrade.connection, initialFrames: upgrade.rest)
    return EstablishedStream(
      stream: stream, initialBytes: Data(), primary: upgrade.connection.nwConnection)
  }
}

// MARK: - Byte stream

/// The byte stream of an open WebSocket: each `send` is one masked binary
/// message; incoming data frame payloads are concatenated into the RTSP byte
/// stream. Pings are answered with pongs; a close frame is echoed and ends the
/// stream.
actor WebSocketByteStream: RTSPByteStream {
  nonisolated let connection: WatchedConnection
  /// Whether a close frame has been queued or written: RFC 6455 allows one
  /// per side, and no frame after it.
  private nonisolated let closeState = WebSocketCloseState()
  private var decoder = WebSocketFrameDecoder()
  /// Set once the stream has ended (close frame, protocol error, or EOF);
  /// later calls throw it.
  private var terminalError: RTSPError?

  init(connection: WatchedConnection, initialFrames: Data) {
    self.connection = connection
    decoder.append(initialFrames)
  }

  func send(_ data: Data) async throws {
    if let terminalError { throw terminalError }
    let frame = WebSocketFrame.encode(
      opcode: .binary, payload: data, maskKey: UInt32.random(in: .min ... .max))
    try await connection.send(
      frame, gate: closeState.ifOpen, refused: .unexpectedDisconnection)
  }

  func receive() async throws -> Data {
    while true {
      if let terminalError { throw terminalError }
      let event: WebSocketFrameDecoder.Event?
      do {
        event = try decoder.next()
      } catch {
        // Fail the WebSocket connection (RFC 6455 section 7.1.7): send the
        // close frame, then close the TCP connection.
        sendClose(WebSocketFrame.closePayload(error.closeCode), thenCancel: true)
        terminalError = .connectionFailed("WebSocket protocol error: \(error.message)")
        continue
      }
      switch event {
      case nil:
        guard let chunk = try await connection.receive() else {
          terminalError = .unexpectedDisconnection
          continue
        }
        decoder.append(chunk)
      case .data(let payload):
        if !payload.isEmpty { return payload }
      case .ping(let payload):
        // Wait for the pong to be written before reading on. A server that
        // floods pings without reading would otherwise make the client queue
        // pongs without limit.
        try await connection.send(
          WebSocketFrame.encode(
            opcode: .pong, payload: payload, maskKey: UInt32.random(in: .min ... .max)),
          gate: closeState.ifOpen, refused: .unexpectedDisconnection)
      case .pong:
        break
      case .close(let code, _):
        // Echo the status code (RFC 6455 section 5.5.1), then end the stream
        // as a TCP close would.
        sendClose(code.map(WebSocketFrame.closePayload) ?? Data(), thenCancel: false)
        terminalError = .unexpectedDisconnection
      }
    }
  }

  /// Queue a close frame without waiting for it to be written, unless one
  /// was queued already. Network keeps sends in call order, so it can't land
  /// inside another message. With `thenCancel`, the TCP connection is closed
  /// once the close frame (this one or the earlier one) is written:
  /// cancelling sooner would drop it. A server that isn't reading gets a
  /// second before the connection is closed anyway.
  private nonisolated func sendClose(_ payload: Data, thenCancel: Bool) {
    let connection = connection
    let state = closeState
    let frame = WebSocketFrame.encode(
      opcode: .close, payload: payload, maskKey: UInt32.random(in: .min ... .max))
    let queued = state.beginClose {
      connection.nwConnection.send(
        content: frame,
        completion: .contentProcessed { _ in
          if state.closeWritten(cancel: thenCancel) { connection.cancel() }
        })
    }
    guard thenCancel else { return }
    if !queued, state.cancelOnceWritten() {
      connection.cancel()
      return
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { connection.cancel() }
  }

  nonisolated func cancel() {
    // A normal closure, then the TCP teardown.
    sendClose(WebSocketFrame.closePayload(1000), thenCancel: true)
  }
}

/// Where a WebSocket connection is in closing, from any thread. Sends are
/// queued under its lock, so no frame can be queued after the close frame.
final class WebSocketCloseState: @unchecked Sendable {
  private enum Phase { case open, closeQueued, closeWritten }
  private let lock = NSLock()
  private var phase = Phase.open
  /// Whether a cancel arrived while the close frame was being written.
  private var cancelRequested = false

  /// Run `enqueue` (which only queues a send) unless a close frame was
  /// queued; false if one was.
  func ifOpen(_ enqueue: () -> Void) -> Bool {
    lock.withLock {
      guard phase == .open else { return false }
      enqueue()
      return true
    }
  }

  /// Queue the close frame with `enqueue` unless one was queued; false if
  /// one was.
  func beginClose(_ enqueue: () -> Void) -> Bool {
    lock.withLock {
      guard phase == .open else { return false }
      phase = .closeQueued
      enqueue()
      return true
    }
  }

  /// Record that the close frame was written; whether to cancel the
  /// connection now (`cancel`, or a cancel that arrived meanwhile).
  func closeWritten(cancel: Bool) -> Bool {
    lock.withLock {
      phase = .closeWritten
      return cancel || cancelRequested
    }
  }

  /// A cancel after the close frame was queued: true to cancel now (the
  /// frame is written), false when the frame's write will.
  func cancelOnceWritten() -> Bool {
    lock.withLock {
      if phase == .closeWritten { return true }
      cancelRequested = true
      return false
    }
  }
}
