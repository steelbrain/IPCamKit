// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Unit tests for RTSP over HTTP tunneling and RTSP over WebSocket, against
// in-process fake servers built on NWListener.

import CryptoKit
import Foundation
import Network
import Testing

@testable import IPCamKit

// MARK: - Fake server

private struct FakeServerError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// A loopback TCP listener for one test. Accepted connections are handed out
/// in arrival order by `accept()`.
private final class FakeServer: @unchecked Sendable {
  let port: UInt16
  private let listener: NWListener
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var pending: [NWConnection] = []
  private var waiters: [CheckedContinuation<NWConnection, Error>] = []
  private var accepted: [NWConnection] = []
  private var stopped = false

  private init(listener: NWListener, port: UInt16, queue: DispatchQueue) {
    self.listener = listener
    self.port = port
    self.queue = queue
  }

  /// Start listening on an ephemeral 127.0.0.1 port.
  static func start() async throws -> FakeServer {
    let queue = DispatchQueue(label: "ipcamkit.tests.fake-server")
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      let settled = OnceFlag()
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if settled.claim() {
            if let port = listener.port?.rawValue {
              continuation.resume(returning: port)
            } else {
              continuation.resume(throwing: FakeServerError("listener has no port"))
            }
          }
        case .failed(let error):
          if settled.claim() { continuation.resume(throwing: error) }
        case .cancelled:
          if settled.claim() { continuation.resume(throwing: FakeServerError("cancelled")) }
        default:
          break
        }
      }
      listener.newConnectionHandler = { _ in }
      listener.start(queue: queue)
    }
    let server = FakeServer(listener: listener, port: port, queue: queue)
    listener.newConnectionHandler = { [server] connection in server.add(connection) }
    return server
  }

  private func add(_ connection: NWConnection) {
    connection.start(queue: queue)
    lock.lock()
    guard !stopped else {
      lock.unlock()
      connection.cancel()
      return
    }
    accepted.append(connection)
    if waiters.isEmpty {
      pending.append(connection)
      lock.unlock()
    } else {
      let waiter = waiters.removeFirst()
      lock.unlock()
      waiter.resume(returning: connection)
    }
  }

  /// The next accepted connection (waits for one).
  func accept() async throws -> FakePeer {
    let connection: NWConnection = try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if stopped {
        lock.unlock()
        continuation.resume(throwing: FakeServerError("server stopped"))
      } else if pending.isEmpty {
        waiters.append(continuation)
        lock.unlock()
      } else {
        let connection = pending.removeFirst()
        lock.unlock()
        continuation.resume(returning: connection)
      }
    }
    return FakePeer(connection)
  }

  /// Number of connections accepted so far.
  var acceptedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return accepted.count
  }

  /// Stop listening and drop every connection; pending `accept()`s fail.
  func stop() {
    lock.lock()
    stopped = true
    let toCancel = accepted
    let toFail = waiters
    accepted.removeAll()
    pending.removeAll()
    waiters.removeAll()
    lock.unlock()
    listener.cancel()
    for connection in toCancel { connection.cancel() }
    for waiter in toFail { waiter.resume(throwing: FakeServerError("server stopped")) }
  }
}

/// A one-shot flag (first `claim()` wins), safe across threads.
private final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false
  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if claimed { return false }
    claimed = true
    return true
  }
}

/// An HTTP request head as the fake server received it.
private struct ReceivedRequest {
  let requestLine: String
  let headers: [(String, String)]

  init(_ text: String) {
    var lines = text.components(separatedBy: "\r\n")
    requestLine = lines.removeFirst()
    headers = lines.compactMap { line in
      guard let colon = line.firstIndex(of: ":") else { return nil }
      return (
        String(line[..<colon]),
        line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      )
    }
  }

  func header(_ name: String) -> String? {
    headers.first { $0.0.lowercased() == name.lowercased() }?.1
  }
}

/// A client frame as the fake WebSocket server received it.
private struct ReceivedFrame {
  let fin: Bool
  let opcode: UInt8
  let masked: Bool
  let payload: Data
}

/// The server side of one accepted connection.
private actor FakePeer {
  let connection: NWConnection
  private var buffer = Data()

  init(_ connection: NWConnection) {
    self.connection = connection
  }

  private func fill() async throws {
    guard let chunk = try await receiveChunk(from: connection) else {
      throw FakeServerError("client closed the connection")
    }
    buffer.append(chunk)
  }

  /// Read an HTTP request head; bytes after it stay buffered.
  func readRequest() async throws -> ReceivedRequest {
    let terminator = Data("\r\n\r\n".utf8)
    while true {
      if let range = buffer.range(of: terminator) {
        let head = buffer[buffer.startIndex..<range.lowerBound]
        buffer = Data(buffer[range.upperBound...])
        return ReceivedRequest(String(decoding: head, as: UTF8.self))
      }
      try await fill()
    }
  }

  /// Read exactly `count` bytes.
  func read(count: Int) async throws -> Data {
    while buffer.count < count {
      try await fill()
    }
    let data = Data(buffer.prefix(count))
    buffer = Data(buffer.dropFirst(count))
    return data
  }

  /// Read one WebSocket frame from the client, unmasking its payload.
  func readFrame() async throws -> ReceivedFrame {
    let header = try await read(count: 2)
    let first = header[header.startIndex]
    let second = header[header.startIndex + 1]
    var length = Int(second & 0x7F)
    if length == 126 {
      let extended = try await read(count: 2)
      length = extended.reduce(0) { $0 << 8 | Int($1) }
    } else if length == 127 {
      let extended = try await read(count: 8)
      length = extended.reduce(0) { $0 << 8 | Int($1) }
    }
    let masked = second & 0x80 != 0
    let key = masked ? Array(try await read(count: 4)) : []
    var payload = try await read(count: length)
    if masked {
      WebSocketFrame.applyMask(key, to: &payload)
    }
    return ReceivedFrame(
      fin: first & 0x80 != 0, opcode: first & 0x0F, masked: masked, payload: payload)
  }

  func send(_ data: Data) async throws {
    try await sendData(data, on: connection)
  }

  func send(_ text: String) async throws {
    try await send(Data(text.utf8))
  }

  /// Send a server (unmasked) WebSocket frame.
  func sendFrame(_ opcode: WebSocketOpcode, _ payload: Data, fin: Bool = true) async throws {
    try await send(WebSocketFrame.encode(opcode: opcode, payload: payload, fin: fin, maskKey: nil))
  }

  /// Close the server's sending side (TCP FIN); the client can still send.
  func finishSending() {
    connection.send(
      content: nil, contentContext: .finalMessage, isComplete: true,
      completion: .idempotent)
  }

  func close() {
    connection.cancel()
  }

  func forceClose() {
    connection.forceCancel()
  }
}

/// After `seconds`, run `cleanup` (stop the fake server, close the client) so
/// a hung await fails the test instead of hanging the run. Cancel on success.
private func watchdog(
  _ seconds: Double = 10, _ cleanup: @escaping @Sendable () async -> Void
) -> Task<Void, Never> {
  Task.detached {
    try? await Task.sleep(for: .seconds(seconds))
    guard !Task.isCancelled else { return }
    Issue.record("test watchdog fired after \(seconds)s")
    await cleanup()
  }
}

// MARK: - Helpers

private let tunnelResponseHead =
  "HTTP/1.0 200 OK\r\nCache-Control: no-cache\r\nConnection: close\r\n"
  + "Content-Type: application/x-rtsp-tunnelled\r\nPragma: no-cache\r\n\r\n"

private let optionsRequest = Data(
  "OPTIONS rtsp://camera.test/stream RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: test\r\n\r\n".utf8)

private let optionsResponse =
  "RTSP/1.0 200 OK\r\nCSeq: 1\r\nPublic: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN\r\n\r\n"

/// A `$`-framed interleaved packet on `channel` carrying `payload`.
private func interleaved(channel: UInt8, _ payload: Data) -> Data {
  var frame = Data([0x24, channel, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
  frame.append(payload)
  return frame
}

/// An RTP-looking payload (version 2) of `count` bytes with varied content.
private func rtpPayload(count: Int) -> Data {
  var data = Data([0x80, 0x60])
  data.append(contentsOf: (2..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
  return data
}

private func expectResponse(
  _ message: RTSPMessage, status: UInt16, cseq: UInt32,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  guard case .response(let response) = message else {
    Issue.record("expected an RTSP response, got \(message)", sourceLocation: sourceLocation)
    return
  }
  #expect(response.statusCode == status, sourceLocation: sourceLocation)
  #expect(response.cseq == cseq, sourceLocation: sourceLocation)
}

private func expectInterleaved(
  _ message: RTSPMessage, channel: UInt8, payload: Data,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  guard case .data(let data) = message else {
    Issue.record("expected interleaved data, got \(message)", sourceLocation: sourceLocation)
    return
  }
  #expect(data.channelId == channel, sourceLocation: sourceLocation)
  #expect(data.data == payload, sourceLocation: sourceLocation)
}

/// A quoted or bare parameter of a Digest `Authorization` header.
private func digestParameter(_ header: String, _ name: String) -> String? {
  for part in header.dropFirst("Digest ".count).components(separatedBy: ", ") {
    let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
    guard pieces.count == 2, pieces[0] == name else { continue }
    return pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
  }
  return nil
}

private func md5Hex(_ text: String) -> String {
  Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Check a Digest (MD5, qop=auth) `Authorization` header against the
/// credentials, method and URI it should have been computed for.
private func expectDigest(
  _ header: String?, method: String, uri: String, nc: String,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  guard let header, header.hasPrefix("Digest ") else {
    Issue.record(
      "expected a Digest Authorization, got \(String(describing: header))",
      sourceLocation: sourceLocation)
    return
  }
  #expect(digestParameter(header, "username") == "admin", sourceLocation: sourceLocation)
  #expect(digestParameter(header, "uri") == uri, sourceLocation: sourceLocation)
  #expect(digestParameter(header, "nc") == nc, sourceLocation: sourceLocation)
  let cnonce = digestParameter(header, "cnonce") ?? ""
  let ha1 = md5Hex("admin:camera:secret")
  let ha2 = md5Hex("\(method):\(uri)")
  let expected = md5Hex("\(ha1):n0nce:\(nc):\(cnonce):auth:\(ha2)")
  #expect(digestParameter(header, "response") == expected, sourceLocation: sourceLocation)
}

private let digestChallenge =
  "HTTP/1.0 401 Unauthorized\r\n"
  + "WWW-Authenticate: Digest realm=\"camera\", nonce=\"n0nce\", qop=\"auth\"\r\n"
  + "Content-Length: 0\r\n\r\n"

/// A 401 offering both schemes, Digest first.
private let digestAndBasicChallenge =
  "HTTP/1.0 401 Unauthorized\r\n"
  + "WWW-Authenticate: Digest realm=\"camera\", nonce=\"n0nce\", qop=\"auth\"\r\n"
  + "WWW-Authenticate: Basic realm=\"camera\"\r\n"
  + "Content-Length: 0\r\n\r\n"

private let credentials = Credentials(username: "admin", password: "secret")
private let basicAuthorization = "Basic " + Data("admin:secret".utf8).base64EncodedString()

/// Expect `body` to throw `expected` (compared by description: `RTSPError` is
/// not `Equatable`).
private func expectRTSPError(
  _ expected: RTSPError, sourceLocation: SourceLocation = #_sourceLocation,
  _ body: () async throws -> Void
) async {
  do {
    try await body()
    Issue.record("expected \(expected), nothing was thrown", sourceLocation: sourceLocation)
  } catch {
    #expect(
      (error as? RTSPError)?.description == expected.description, "got \(error)",
      sourceLocation: sourceLocation)
  }
}

// MARK: - HTTP tunnel tests

@Suite("RTSP over HTTP tunnel")
struct HTTPTunnelTests {

  @Test("GET and POST headers, shared cookie, base64 POST body, and RTSP after the 200")
  func tunnelFormatsAndData() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/cam/live?channel=1"))

    let serverTask = Task {
      let get = try await server.accept()
      let getRequest = try await get.readRequest()
      // The RTSP response rides in the same write as the HTTP 200 header block.
      try await get.send(tunnelResponseHead + optionsResponse)
      let post = try await server.accept()
      let postRequest = try await post.readRequest()
      return (get, getRequest, post, postRequest)
    }
    try await client.connectHTTPTunnel(
      url: url, tls: .default, credentials: nil, userAgent: "IPCamKitTests/1.0")
    let (get, getRequest, post, postRequest) = try await serverTask.value

    #expect(getRequest.requestLine == "GET /cam/live?channel=1 HTTP/1.0")
    let cookie = try #require(getRequest.header("x-sessioncookie"))
    #expect(cookie.count >= 22)
    #expect(cookie.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
    #expect(getRequest.header("Accept") == "application/x-rtsp-tunnelled")
    #expect(getRequest.header("Pragma") == "no-cache")
    #expect(getRequest.header("Cache-Control") == "no-cache")
    #expect(getRequest.header("User-Agent") == "IPCamKitTests/1.0")
    #expect(getRequest.header("Host") == "127.0.0.1:\(server.port)")
    #expect(getRequest.header("Authorization") == nil)

    #expect(postRequest.requestLine == "POST /cam/live?channel=1 HTTP/1.0")
    #expect(postRequest.header("x-sessioncookie") == cookie)
    #expect(postRequest.header("Content-Type") == "application/x-rtsp-tunnelled")
    #expect(postRequest.header("Pragma") == "no-cache")
    #expect(postRequest.header("Cache-Control") == "no-cache")
    #expect(postRequest.header("Content-Length") == "32767")
    #expect(postRequest.header("Expires") == "Sun, 9 Jan 1972 00:00:00 GMT")
    #expect(postRequest.header("User-Agent") == "IPCamKitTests/1.0")
    #expect(postRequest.header("Host") == "127.0.0.1:\(server.port)")

    // The RTSP response that shared a segment with the 200 header is not lost.
    expectResponse(try await client.receiveMessage(), status: 200, cseq: 1)

    // Each send is base64-encoded on its own (each one padded), and decodes to
    // exactly the bytes sent: an RTSP request and a `$` interleaved packet
    // (sizes chosen so both need padding).
    let backchannel = interleaved(channel: 2, rtpPayload(count: 162))
    try await client.send(optionsRequest)
    try await client.send(backchannel)
    for sent in [optionsRequest, backchannel] {
      #expect(sent.count % 3 != 0, "test data must need base64 padding")
      let encodedLength = (sent.count + 2) / 3 * 4
      let encoded = try await post.read(count: encodedLength)
      #expect(encoded.last == UInt8(ascii: "="), "each send carries its own padding")
      #expect(Data(base64Encoded: encoded) == sent)
    }

    // Server-to-client: an interleaved packet split across writes, then a
    // response, both on the GET connection.
    let media = interleaved(channel: 0, rtpPayload(count: 1200))
    try await get.send(media.prefix(3))
    try await get.send(media.dropFirst(3) + Data(optionsResponse.utf8))
    expectInterleaved(
      try await client.receiveMessage(), channel: 0, payload: rtpPayload(count: 1200))
    expectResponse(try await client.receiveMessage(), status: 200, cseq: 1)
    #expect(await client.resolvedRemote() == nil, "tunnels carry RTP interleaved only")

    await client.close()
  }

  @Test("POST responses are discarded, and a POST closed by the server still sends")
  func postResponseIgnored() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/"))
    let serverTask = Task {
      let get = try await server.accept()
      _ = try await get.readRequest()
      try await get.send(tunnelResponseHead)
      let post = try await server.accept()
      let request = try await post.readRequest()
      // mediamtx-style: a 200 header block on the POST, then (some servers)
      // closing the server's sending side.
      try await post.send(tunnelResponseHead)
      await post.finishSending()
      return (get, post, request)
    }
    try await client.connectHTTPTunnel(url: url, tls: .default, credentials: nil, userAgent: nil)
    let (get, post, request) = try await serverTask.value
    #expect(request.requestLine == "POST / HTTP/1.0")
    #expect(request.header("User-Agent") == nil)
    // Give the client's POST reader time to see the 200 and the FIN.
    try await Task.sleep(for: .milliseconds(200))

    try await client.send(optionsRequest)
    let encoded = try await post.read(count: (optionsRequest.count + 2) / 3 * 4)
    #expect(Data(base64Encoded: encoded) == optionsRequest)
    try await get.send(optionsResponse)
    expectResponse(try await client.receiveMessage(), status: 200, cseq: 1)
    await client.close()
  }

  /// `splitWithBody`: the head arrives in two reads, the second with a body
  /// that takes the buffer past 64 KiB before the head is parsed.
  @Test("An error status on the POST connection fails later sends", arguments: [false, true])
  func postRejectedFailsSends(splitWithBody: Bool) async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/"))
    let serverTask = Task {
      let get = try await server.accept()
      _ = try await get.readRequest()
      try await get.send(tunnelResponseHead)
      let post = try await server.accept()
      _ = try await post.readRequest()
      if splitWithBody {
        try await post.send("HTTP/1.0 403 Forbidden\r\nServer: x")
        try await Task.sleep(for: .milliseconds(300))
        try await post.send(
          "\r\nContent-Length: 70000\r\n\r\n" + String(repeating: "x", count: 70_000))
      } else {
        try await post.send("HTTP/1.0 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
      }
      return (get, post)
    }
    try await client.connectHTTPTunnel(url: url, tls: .default, credentials: nil, userAgent: nil)
    let peers = try await serverTask.value
    _ = peers

    var failure: Error?
    for _ in 0..<40 where failure == nil {
      do {
        try await client.send(optionsRequest)
        try await Task.sleep(for: .milliseconds(50))
      } catch {
        failure = error
      }
    }
    guard case .connectionFailed(let message)? = failure as? RTSPError else {
      Issue.record("expected connectionFailed, got \(String(describing: failure))")
      return
    }
    #expect(message.contains("403"), "got: \(message)")
    await client.close()
  }

  @Test("A hard failure of the POST connection fails later sends")
  func postResetFailsSends() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/"))
    let serverTask = Task {
      let get = try await server.accept()
      _ = try await get.readRequest()
      try await get.send(tunnelResponseHead)
      let post = try await server.accept()
      _ = try await post.readRequest()
      await post.forceClose()
      return get
    }
    try await client.connectHTTPTunnel(url: url, tls: .default, credentials: nil, userAgent: nil)
    _ = try await serverTask.value

    var failure: Error?
    for _ in 0..<40 where failure == nil {
      do {
        try await client.send(optionsRequest)
        try await Task.sleep(for: .milliseconds(50))
      } catch {
        failure = error
      }
    }
    #expect(failure is RTSPError, "sends must fail once the POST connection is gone")
    await client.close()
  }

  @Test(
    "A POST rejected while a read is pending ends the read with the status",
    .timeLimit(.minutes(1)))
  func postRejectedEndsPendingRead() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/"))
    let serverTask = Task {
      let get = try await server.accept()
      _ = try await get.readRequest()
      try await get.send(tunnelResponseHead)
      let post = try await server.accept()
      _ = try await post.readRequest()
      return (get, post)
    }
    try await client.connectHTTPTunnel(url: url, tls: .default, credentials: nil, userAgent: nil)
    let (get, post) = try await serverTask.value

    let reader = Task { await outcome { try await client.receiveMessage() } }
    try await client.send(optionsRequest)
    _ = try await post.read(count: (optionsRequest.count + 2) / 3 * 4)
    let rejected = ContinuousClock.now
    try await post.send("HTTP/1.0 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
    let result = await reader.value
    let elapsed = ContinuousClock.now - rejected
    #expect(elapsed < .seconds(2), "the read ended \(elapsed) after the rejection")
    guard case .failure(RTSPError.connectionFailed(let message)) = result else {
      Issue.record("expected connectionFailed, got \(result)")
      return
    }
    #expect(message.contains("403"), "got: \(message)")
    _ = get
    await client.close()
  }

  @Test(
    "A refused GET or upgrade hides credential parameters of the tunnel URL in its error",
    .timeLimit(.minutes(1)),
    arguments: [("http", true), ("ws", true), ("http", false), ("ws", false)])
  func refusedTunnelHidesCredentials(scheme: String, replies: Bool) async throws {
    let server = try await FakeServer.start()
    let url = try #require(
      URL(
        string:
          "\(scheme)://127.0.0.1:\(server.port)/user=admin_password=hunter2/t?password=hunter3&token=abc"
      ))
    let session = RTSPClientSession(
      url: "rtsp://camera.test/stream", transport: .tcp,
      tunnel: scheme == "ws" ? .webSocket(url) : .http(url))
    let dog = watchdog {
      server.stop()
      await session.stop()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    // A 404, or a close before any response (whose error names the request
    // too).
    let serverTask = Task {
      let get = try await server.accept()
      _ = try await get.readRequest()
      if replies {
        try await get.send("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n")
      } else {
        await get.finishSending()
      }
      return get
    }
    let result = await outcome { try await session.start() }
    guard case .failure(RTSPError.connectionFailed(let message)) = result else {
      Issue.record("expected connectionFailed, got \(result)")
      return
    }
    #expect(message.contains(replies ? "404" : "closed the connection"), "\(message)")
    #expect(message.contains("/user=***/t?password=***&token=***"), "\(message)")
    #expect(!message.contains("hunter") && !message.contains("abc"), "\(message)")
    _ = try await serverTask.value
  }

  @Test(
    "A POST rejected after the first request fails start() at once with its cause",
    .timeLimit(.minutes(1)), arguments: [404, 401])
  func postRejectedFailsStart(status: Int) async throws {
    let server = try await FakeServer.start()
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/"))
    let session = RTSPClientSession(
      url: "rtsp://camera.test/stream", credentials: nil, transport: .tcp, tunnel: .http(url),
      userAgent: "IPCamKit", onDiagnostic: nil, keepaliveInterval: nil,
      setupResponseTimeout: .seconds(4))
    let dog = watchdog {
      server.stop()
      await session.stop()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let reason = status == 401 ? "Unauthorized" : "Not Found"
    let serverTask = Task {
      let get = try await server.accept()
      _ = try await get.readRequest()
      try await get.send(tunnelResponseHead)
      let post = try await server.accept()
      _ = try await post.readRequest()
      // The first base64 request arrives; then the server rejects the POST.
      _ = try await post.read(count: 8)
      try await post.send("HTTP/1.0 \(status) \(reason)\r\nContent-Length: 0\r\n\r\n")
      return (get, post)
    }

    // Before the fix, start() waited out setupResponseTimeout and threw
    // RTSPError.timeout.
    let started = ContinuousClock.now
    let result = await outcome { try await session.start() }
    let elapsed = ContinuousClock.now - started
    #expect(elapsed < .seconds(2), "start() took \(elapsed)")
    switch result {
    case .failure(RTSPError.connectionFailed(let message)) where status == 404:
      #expect(message.contains("404"), "got: \(message)")
    case .failure(RTSPError.authenticationFailed) where status == 401:
      break
    default:
      Issue.record("unexpected result for a \(status) on the POST: \(result)")
    }
    _ = try await serverTask.value
  }

  @Test("A non-200 GET fails with connectionFailed naming the status")
  func getErrorStatus() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/missing"))
    let serverTask = Task {
      let get = try await server.accept()
      _ = try await get.readRequest()
      try await get.send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
      return get
    }
    do {
      try await client.connectHTTPTunnel(url: url, tls: .default, credentials: nil, userAgent: nil)
      Issue.record("connect should fail")
    } catch RTSPError.connectionFailed(let message) {
      #expect(message.contains("404"), "got: \(message)")
      #expect(message.contains("Not Found"), "got: \(message)")
    }
    _ = try await serverTask.value
    #expect(server.acceptedCount == 1, "no POST after a failed GET")
  }

  @Test("A 401 is answered with Digest on a new GET, and the POST carries Authorization")
  func digestAuthRetry() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/stream?a=b"))
    let serverTask = Task {
      let first = try await server.accept()
      let firstRequest = try await first.readRequest()
      try await first.send(digestChallenge)
      let get = try await server.accept()
      let getRequest = try await get.readRequest()
      try await get.send(tunnelResponseHead)
      let post = try await server.accept()
      let postRequest = try await post.readRequest()
      return (firstRequest, getRequest, postRequest, get, post)
    }
    try await client.connectHTTPTunnel(
      url: url, tls: .default, credentials: credentials, userAgent: nil)
    let (firstRequest, getRequest, postRequest, get, post) = try await serverTask.value
    _ = (get, post)

    #expect(firstRequest.header("Authorization") == nil)
    #expect(getRequest.header("x-sessioncookie") == firstRequest.header("x-sessioncookie"))
    #expect(postRequest.header("x-sessioncookie") == getRequest.header("x-sessioncookie"))
    expectDigest(
      getRequest.header("Authorization"), method: "GET", uri: "/stream?a=b", nc: "00000001")
    expectDigest(
      postRequest.header("Authorization"), method: "POST", uri: "/stream?a=b", nc: "00000002")
    await client.close()
  }

  @Test("A 401 answered with Basic succeeds")
  func basicAuthRetry() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/s"))
    let serverTask = Task {
      let first = try await server.accept()
      _ = try await first.readRequest()
      try await first.send(
        "HTTP/1.0 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"camera\"\r\n\r\n")
      let get = try await server.accept()
      let getRequest = try await get.readRequest()
      try await get.send(tunnelResponseHead + optionsResponse)
      let post = try await server.accept()
      let postRequest = try await post.readRequest()
      return (getRequest, postRequest, get, post)
    }
    try await client.connectHTTPTunnel(
      url: url, tls: .default, credentials: credentials, userAgent: nil)
    let (getRequest, postRequest, get, post) = try await serverTask.value
    _ = (get, post)
    let basic = "Basic " + Data("admin:secret".utf8).base64EncodedString()
    #expect(getRequest.header("Authorization") == basic)
    #expect(postRequest.header("Authorization") == basic)
    expectResponse(try await client.receiveMessage(), status: 200, cseq: 1)
    await client.close()
  }

  @Test("A 401 offering Basic then Digest in one WWW-Authenticate is answered with Digest")
  func combinedChallengeAnsweredWithDigest() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/stream?a=b"))
    let challenge: String =
      "HTTP/1.0 401 Unauthorized\r\n"
      + "WWW-Authenticate: Basic realm=\"camera\", Digest realm=\"camera\", "
      + "nonce=\"n0nce\", qop=\"auth\"\r\nContent-Length: 0\r\n\r\n"
    let serverTask = Task {
      let first = try await server.accept()
      _ = try await first.readRequest()
      try await first.send(challenge)
      let get = try await server.accept()
      let getRequest = try await get.readRequest()
      try await get.send(tunnelResponseHead)
      let post = try await server.accept()
      let postRequest = try await post.readRequest()
      return (getRequest, postRequest, get, post)
    }
    try await client.connectHTTPTunnel(
      url: url, tls: .default, credentials: credentials, userAgent: nil)
    let (getRequest, postRequest, get, post) = try await serverTask.value
    _ = (get, post)
    expectDigest(
      getRequest.header("Authorization"), method: "GET", uri: "/stream?a=b", nc: "00000001")
    expectDigest(
      postRequest.header("Authorization"), method: "POST", uri: "/stream?a=b", nc: "00000002")
    await client.close()
  }

  @Test("A second 401 fails with authenticationFailed")
  func authRejected() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/s"))
    let serverTask = Task {
      for _ in 0..<2 {
        let peer = try await server.accept()
        _ = try await peer.readRequest()
        try await peer.send(digestChallenge)
      }
    }
    await expectRTSPError(.authenticationFailed) {
      try await client.connectHTTPTunnel(
        url: url, tls: .default, credentials: credentials, userAgent: nil)
    }
    try await serverTask.value
    #expect(server.acceptedCount == 2, "one retry only")
  }

  @Test("A rejected Digest falls back to Basic when the server offered both")
  func basicFallback() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/s"))
    let serverTask = Task {
      var requests: [ReceivedRequest] = []
      for _ in 0..<2 {
        let peer = try await server.accept()
        requests.append(try await peer.readRequest())
        try await peer.send(digestAndBasicChallenge)
      }
      let get = try await server.accept()
      requests.append(try await get.readRequest())
      try await get.send(tunnelResponseHead + optionsResponse)
      let post = try await server.accept()
      requests.append(try await post.readRequest())
      return (requests, get, post)
    }
    try await client.connectHTTPTunnel(
      url: url, tls: .default, credentials: credentials, userAgent: nil)
    let (requests, get, post) = try await serverTask.value
    _ = (get, post)
    #expect(requests[0].header("Authorization") == nil)
    #expect(requests[1].header("Authorization")?.hasPrefix("Digest ") == true)
    #expect(requests[2].header("Authorization") == basicAuthorization)
    #expect(requests[3].header("Authorization") == basicAuthorization, "POST keeps Basic")
    expectResponse(try await client.receiveMessage(), status: 200, cseq: 1)
    await client.close()
  }

  @Test("Basic is tried only once after a rejected Digest")
  func basicFallbackRejected() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/s"))
    let serverTask = Task {
      for _ in 0..<3 {
        let peer = try await server.accept()
        _ = try await peer.readRequest()
        try await peer.send(digestAndBasicChallenge)
      }
    }
    await expectRTSPError(.authenticationFailed) {
      try await client.connectHTTPTunnel(
        url: url, tls: .default, credentials: credentials, userAgent: nil)
    }
    try await serverTask.value
    #expect(server.acceptedCount == 3)
  }

  /// The GET's Digest answer is refused with a new nonce, with `stale=true`
  /// when `stale`; only an answer to that nonce is accepted.
  @Test(
    "A GET retry refused with stale=true and a new nonce is answered once more",
    .timeLimit(.minutes(1)), arguments: [true, false])
  func staleRetryAnsweredOnceMore(stale: Bool) async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/s"))
    let staleChallenge =
      "HTTP/1.0 401 Unauthorized\r\n"
      + "WWW-Authenticate: Digest realm=\"camera\", nonce=\"fresh\", qop=\"auth\""
      + (stale ? ", stale=true" : "") + "\r\nContent-Length: 0\r\n\r\n"
    let serverTask = Task {
      var requests: [ReceivedRequest] = []
      for reply in [digestChallenge, staleChallenge] {
        let peer = try await server.accept()
        requests.append(try await peer.readRequest())
        try await peer.send(reply)
      }
      guard stale else { return requests }
      let get = try await server.accept()
      requests.append(try await get.readRequest())
      try await get.send(tunnelResponseHead + optionsResponse)
      let post = try await server.accept()
      requests.append(try await post.readRequest())
      _ = (get, post)
      return requests
    }
    let connected = await outcome {
      try await client.connectHTTPTunnel(
        url: url, tls: .default, credentials: credentials, userAgent: nil)
    }
    let requests = try await serverTask.value
    if stale {
      #expect(throws: Never.self) { try connected.get() }
      #expect(requests.count == 4)
      #expect(requests[1].header("Authorization")?.contains("nonce=\"n0nce\"") == true)
      #expect(requests[2].header("Authorization")?.contains("nonce=\"fresh\"") == true)
      expectResponse(try await client.receiveMessage(), status: 200, cseq: 1)
    } else {
      guard case .failure(let error) = connected, case RTSPError.authenticationFailed = error
      else {
        Issue.record("Expected authenticationFailed, got \(connected)")
        return
      }
      #expect(server.acceptedCount == 2, "a new nonce without stale=true refuses the password")
    }
    await client.close()
  }

  @Test("A Basic offer first made on the GET retry's 401 still gets Basic once")
  func basicOfferedOnRetryFallsBack() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/s"))
    let serverTask = Task {
      var requests: [ReceivedRequest] = []
      for reply in [digestChallenge, digestAndBasicChallenge] {
        let peer = try await server.accept()
        requests.append(try await peer.readRequest())
        try await peer.send(reply)
      }
      let get = try await server.accept()
      requests.append(try await get.readRequest())
      try await get.send(tunnelResponseHead + optionsResponse)
      let post = try await server.accept()
      requests.append(try await post.readRequest())
      _ = (get, post)
      return requests
    }
    try await client.connectHTTPTunnel(
      url: url, tls: .default, credentials: credentials, userAgent: nil)
    let requests = try await serverTask.value
    #expect(requests[1].header("Authorization")?.hasPrefix("Digest ") == true)
    #expect(requests[2].header("Authorization") == basicAuthorization)
    #expect(requests[3].header("Authorization") == basicAuthorization, "POST keeps Basic")
    expectResponse(try await client.receiveMessage(), status: 200, cseq: 1)
    await client.close()
  }

  @Test("A 401 without credentials fails with authenticationFailed")
  func authWithoutCredentials() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/s"))
    let serverTask = Task {
      let peer = try await server.accept()
      _ = try await peer.readRequest()
      try await peer.send(digestChallenge)
    }
    await expectRTSPError(.authenticationFailed) {
      try await client.connectHTTPTunnel(url: url, tls: .default, credentials: nil, userAgent: nil)
    }
    try await serverTask.value
  }

  @Test("close() during the handshake cancels the connect")
  func closeDuringConnect() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "ws://127.0.0.1:\(server.port)/s"))
    let closer = Task {
      // The server never answers; close once the upgrade request is out.
      let peer = try await server.accept()
      _ = try await peer.readRequest()
      await client.close()
      return peer
    }
    let started = ContinuousClock.now
    await expectRTSPError(.unexpectedDisconnection) {
      try await client.connectWebSocket(url: url, tls: .default, credentials: nil, userAgent: nil)
    }
    #expect(ContinuousClock.now - started < .seconds(5))
    _ = try await closer.value
    await expectRTSPError(.connectionFailed("Not connected")) {
      try await client.send(optionsRequest)
    }
  }

  @Test("A server that never answers the GET hits the connect timeout")
  func getTimeout() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection(connectTimeoutSeconds: 1)
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/s"))
    let started = ContinuousClock.now
    await expectRTSPError(.timeout) {
      try await client.connectHTTPTunnel(url: url, tls: .default, credentials: nil, userAgent: nil)
    }
    #expect(ContinuousClock.now - started < .seconds(5))
  }

  @Test("A non-HTTP answer to the GET is rejected")
  func getNotHTTP() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/s"))
    let serverTask = Task {
      let peer = try await server.accept()
      _ = try await peer.readRequest()
      try await peer.send("RTSP/1.0 400 Bad Request\r\nCSeq: 0\r\n\r\n")
      return peer
    }
    do {
      try await client.connectHTTPTunnel(url: url, tls: .default, credentials: nil, userAgent: nil)
      Issue.record("connect should fail")
    } catch RTSPError.connectionFailed(let message) {
      #expect(message.contains("did not answer with HTTP"), "got: \(message)")
    }
    _ = try await serverTask.value
  }

  @Test("Tunnel URLs must be http:// or https://")
  func wrongScheme() async throws {
    let client = RTSPTransportConnection()
    let url = try #require(URL(string: "rtsp://127.0.0.1:9/s"))
    do {
      try await client.connectHTTPTunnel(url: url, tls: .default, credentials: nil, userAgent: nil)
      Issue.record("connect should fail")
    } catch RTSPError.connectionFailed(let message) {
      #expect(message.contains("Unsupported URL scheme"), "got: \(message)")
    }
  }
}

// MARK: - WebSocket tests

/// The `101` a correct server sends for `request`; mediamtx-style, without
/// echoing `Sec-WebSocket-Protocol` unless `subprotocol` is given.
private func switchingProtocols(for request: ReceivedRequest, subprotocol: String? = nil) -> String
{
  let key = request.header("Sec-WebSocket-Key") ?? ""
  var response =
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    + "Sec-WebSocket-Accept: \(WebSocketTransport.acceptValue(forKey: key))\r\n"
  if let subprotocol {
    response += "Sec-WebSocket-Protocol: \(subprotocol)\r\n"
  }
  return response + "\r\n"
}

@Suite("RTSP over WebSocket")
struct WebSocketTransportTests {

  @Test("Handshake, masked binary sends, fragmented and split responses, ping/pong, close")
  func handshakeAndFraming() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "ws://127.0.0.1:\(server.port)/onvif/rtsp?x=1"))
    let response = Data(optionsResponse.utf8)

    let serverTask = Task {
      let peer = try await server.accept()
      let request = try await peer.readRequest()
      // The first RTSP response's opening bytes ride in the same write as the
      // 101 (as one complete frame).
      var handshake = Data(switchingProtocols(for: request).utf8)
      handshake.append(
        WebSocketFrame.encode(opcode: .binary, payload: response.prefix(10), maskKey: nil))
      try await peer.send(handshake)
      return (peer, request)
    }
    try await client.connectWebSocket(
      url: url, tls: .default, credentials: nil, userAgent: "IPCamKitTests/1.0")
    let (peer, request) = try await serverTask.value

    #expect(request.requestLine == "GET /onvif/rtsp?x=1 HTTP/1.1")
    #expect(request.header("Host") == "127.0.0.1:\(server.port)")
    #expect(request.header("Upgrade") == "websocket")
    #expect(request.header("Connection") == "Upgrade")
    #expect(request.header("Sec-WebSocket-Version") == "13")
    #expect(request.header("Sec-WebSocket-Protocol") == "rtsp.onvif.org")
    #expect(request.header("User-Agent") == "IPCamKitTests/1.0")
    let key = try #require(request.header("Sec-WebSocket-Key"))
    #expect(Data(base64Encoded: key)?.count == 16)

    // Rest of the first response: one more message, split across two writes.
    let rest = WebSocketFrame.encode(opcode: .binary, payload: response.dropFirst(10), maskKey: nil)
    try await peer.send(rest.prefix(5))
    try await peer.send(rest.dropFirst(5))
    expectResponse(try await client.receiveMessage(), status: 200, cseq: 1)

    // Each send is one masked binary frame with FIN set.
    let backchannel = interleaved(channel: 2, rtpPayload(count: 300))
    try await client.send(optionsRequest)
    try await client.send(backchannel)
    for sent in [optionsRequest, backchannel] {
      let frame = try await peer.readFrame()
      #expect(frame.fin)
      #expect(frame.opcode == 0x2)
      #expect(frame.masked)
      #expect(frame.payload == sent)
    }

    // A response fragmented into three frames with a ping in the middle; the
    // client answers the ping with a matching pong.
    try await peer.sendFrame(.binary, response.prefix(7), fin: false)
    try await peer.sendFrame(.continuation, response.dropFirst(7).prefix(20), fin: false)
    try await peer.sendFrame(.ping, Data("are you there".utf8))
    try await peer.sendFrame(.continuation, response.dropFirst(27))
    expectResponse(try await client.receiveMessage(), status: 200, cseq: 1)
    let pong = try await peer.readFrame()
    #expect(pong.opcode == 0xA)
    #expect(pong.fin)
    #expect(pong.masked)
    #expect(pong.payload == Data("are you there".utf8))

    // Media: two interleaved packets in one message, then two large ones split
    // across a 64-bit-length message and a 16-bit-length one.
    let small = interleaved(channel: 0, rtpPayload(count: 100))
    let large = interleaved(channel: 0, rtpPayload(count: 65_000))
    try await peer.sendFrame(.binary, small + small)
    try await peer.sendFrame(.binary, (large + large).prefix(70_000))
    try await peer.sendFrame(.binary, (large + large).dropFirst(70_000))
    for expected in [100, 100, 65_000, 65_000] {
      expectInterleaved(
        try await client.receiveMessage(), channel: 0, payload: rtpPayload(count: expected))
    }

    // Server close: the client echoes the code and the stream ends.
    try await peer.sendFrame(.close, WebSocketFrame.closePayload(1001) + Data("bye".utf8))
    await expectRTSPError(.unexpectedDisconnection) {
      _ = try await client.receiveMessage()
    }
    let closeEcho = try await peer.readFrame()
    #expect(closeEcho.opcode == 0x8)
    #expect(closeEcho.payload == WebSocketFrame.closePayload(1001))
    await expectRTSPError(.unexpectedDisconnection) {
      try await client.send(optionsRequest)
    }
    #expect(await client.resolvedRemote() == nil)
    await client.close()
    // One close frame per side: closing doesn't send another.
    await #expect(throws: FakeServerError.self) { _ = try await peer.read(count: 1) }
  }

  /// Open a WebSocket connection to `server` and return the client and the
  /// server's side of it.
  private func openWebSocket(
    _ server: FakeServer
  ) async throws -> (RTSPTransportConnection, FakePeer) {
    let client = RTSPTransportConnection()
    let url = try #require(URL(string: "ws://127.0.0.1:\(server.port)/"))
    let serverTask = Task {
      let peer = try await server.accept()
      let request = try await peer.readRequest()
      try await peer.send(switchingProtocols(for: request, subprotocol: "rtsp.onvif.org"))
      return peer
    }
    try await client.connectWebSocket(url: url, tls: .default, credentials: nil, userAgent: nil)
    return (client, try await serverTask.value)
  }

  /// The opcodes of the frames the client sends until it closes the
  /// connection.
  private func remainingOpcodes(from peer: FakePeer) async -> [UInt8] {
    var opcodes: [UInt8] = []
    while let frame = try? await peer.readFrame() { opcodes.append(frame.opcode) }
    return opcodes
  }

  /// close() right after the stream ended with a protocol error or a server
  /// close must not drop the close frame the client queued for it.
  @Test(
    "close() right after an error or a server close keeps the close frame",
    .timeLimit(.minutes(1)), arguments: [false, true])
  func closeRightAfterEnd(serverCloses: Bool) async throws {
    let server = try await FakeServer.start()
    defer { server.stop() }
    var missing = 0
    for _ in 0..<20 {
      let (client, peer) = try await openWebSocket(server)
      if serverCloses {
        try await peer.sendFrame(.close, WebSocketFrame.closePayload(1001))
      } else {
        try await peer.send(WebSocketFrame.encode(opcode: .binary, payload: Data([1]), maskKey: 7))
      }
      _ = try? await client.receiveMessage()
      await client.close()
      var payloads: [Data] = []
      while let frame = try? await peer.readFrame() {
        if frame.opcode == 0x8 { payloads.append(frame.payload) }
      }
      if payloads != [WebSocketFrame.closePayload(serverCloses ? 1001 : 1002)] { missing += 1 }
    }
    #expect(missing == 0)
  }

  /// A send racing close() must not put a data frame after the close frame
  /// (RFC 6455 section 5.5.1).
  @Test("No data frame follows the close frame", .timeLimit(.minutes(1)))
  func noDataAfterClose() async throws {
    let server = try await FakeServer.start()
    defer { server.stop() }
    var late = 0
    for _ in 0..<100 {
      let (client, peer) = try await openWebSocket(server)
      let send = Task { try? await client.send(Data(repeating: 0x41, count: 16)) }
      let close = Task { await client.close() }
      _ = await (send.value, close.value)
      let opcodes = await remainingOpcodes(from: peer)
      if let closeIndex = opcodes.firstIndex(of: 0x8), closeIndex != opcodes.count - 1 {
        late += 1
      }
    }
    #expect(late == 0)
  }

  @Test("A protocol violation from the server fails the read and is answered with close 1002")
  func protocolViolation() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "ws://127.0.0.1:\(server.port)/"))
    let serverTask = Task {
      let peer = try await server.accept()
      let request = try await peer.readRequest()
      try await peer.send(switchingProtocols(for: request, subprotocol: "rtsp.onvif.org"))
      return peer
    }
    try await client.connectWebSocket(url: url, tls: .default, credentials: nil, userAgent: nil)
    let peer = try await serverTask.value
    // A masked frame from the server.
    try await peer.send(WebSocketFrame.encode(opcode: .binary, payload: Data([1]), maskKey: 7))
    do {
      _ = try await client.receiveMessage()
      Issue.record("read should fail")
    } catch RTSPError.connectionFailed(let message) {
      #expect(message.contains("masked"), "got: \(message)")
    }
    let close = try await peer.readFrame()
    #expect(close.opcode == 0x8)
    #expect(close.payload == WebSocketFrame.closePayload(1002))
    // Then the client closes the TCP connection itself (RFC 6455 section
    // 7.1.7), without waiting for close().
    let started = ContinuousClock.now
    await #expect(throws: FakeServerError.self) { _ = try await peer.read(count: 1) }
    #expect(ContinuousClock.now - started < .seconds(2))
    await client.close()
  }

  @Test("close() sends a close frame with 1000 before closing the TCP connection")
  func normalClose() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "ws://127.0.0.1:\(server.port)/"))
    let serverTask = Task {
      let peer = try await server.accept()
      let request = try await peer.readRequest()
      try await peer.send(switchingProtocols(for: request, subprotocol: "rtsp.onvif.org"))
      return peer
    }
    try await client.connectWebSocket(url: url, tls: .default, credentials: nil, userAgent: nil)
    let peer = try await serverTask.value
    await client.close()
    let close = try await peer.readFrame()
    #expect(close.opcode == 0x8)
    #expect(close.masked)
    #expect(close.payload == WebSocketFrame.closePayload(1000))
    await #expect(throws: FakeServerError.self) { _ = try await peer.read(count: 1) }
  }

  @Test("Upgrade responses that break RFC 6455 are rejected")
  func badUpgradeResponses() async throws {
    let cases: [(String, @Sendable (ReceivedRequest) -> String, String)] = [
      ("status", { _ in "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n" }, "400"),
      (
        "accept",
        { _ in
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"
        },
        "Sec-WebSocket-Accept"
      ),
      (
        "subprotocol",
        { switchingProtocols(for: $0, subprotocol: "chat") }, "subprotocol"
      ),
      (
        "upgrade",
        {
          switchingProtocols(for: $0).replacingOccurrences(of: "Upgrade: websocket\r\n", with: "")
        },
        "Upgrade"
      ),
    ]
    for (name, respond, expected) in cases {
      let server = try await FakeServer.start()
      let client = RTSPTransportConnection()
      let dog = watchdog {
        server.stop()
        await client.close()
      }
      defer {
        dog.cancel()
        server.stop()
      }
      let url = try #require(URL(string: "ws://127.0.0.1:\(server.port)/"))
      let serverTask = Task {
        let peer = try await server.accept()
        let request = try await peer.readRequest()
        try await peer.send(respond(request))
        return peer
      }
      do {
        try await client.connectWebSocket(url: url, tls: .default, credentials: nil, userAgent: nil)
        Issue.record("\(name): connect should fail")
      } catch RTSPError.connectionFailed(let message) {
        #expect(message.contains(expected), "\(name): got \(message)")
      }
      _ = try await serverTask.value
    }
  }

  @Test("A 401 on the upgrade is retried once with credentials")
  func authRetry() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "ws://127.0.0.1:\(server.port)/ws"))
    let serverTask = Task {
      let first = try await server.accept()
      _ = try await first.readRequest()
      try await first.send(digestChallenge)
      let second = try await server.accept()
      let request = try await second.readRequest()
      try await second.send(switchingProtocols(for: request))
      return (request, second)
    }
    try await client.connectWebSocket(
      url: url, tls: .default, credentials: credentials, userAgent: nil)
    let (request, peer) = try await serverTask.value
    expectDigest(request.header("Authorization"), method: "GET", uri: "/ws", nc: "00000001")
    try await peer.sendFrame(.binary, Data(optionsResponse.utf8))
    expectResponse(try await client.receiveMessage(), status: 200, cseq: 1)
    await client.close()
  }

  @Test("A second 401 on the upgrade fails with authenticationFailed")
  func authRejected() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "ws://127.0.0.1:\(server.port)/ws"))
    let serverTask = Task {
      for _ in 0..<2 {
        let peer = try await server.accept()
        _ = try await peer.readRequest()
        try await peer.send(digestChallenge)
      }
    }
    await expectRTSPError(.authenticationFailed) {
      try await client.connectWebSocket(
        url: url, tls: .default, credentials: credentials, userAgent: nil)
    }
    try await serverTask.value
    #expect(server.acceptedCount == 2)
  }

  @Test("A rejected Digest on the upgrade falls back to Basic when offered")
  func basicFallback() async throws {
    let server = try await FakeServer.start()
    let client = RTSPTransportConnection()
    let dog = watchdog {
      server.stop()
      await client.close()
    }
    defer {
      dog.cancel()
      server.stop()
    }
    let url = try #require(URL(string: "ws://127.0.0.1:\(server.port)/ws"))
    let serverTask = Task {
      for _ in 0..<2 {
        let peer = try await server.accept()
        _ = try await peer.readRequest()
        try await peer.send(digestAndBasicChallenge)
      }
      let third = try await server.accept()
      let request = try await third.readRequest()
      try await third.send(switchingProtocols(for: request))
      return (request, third)
    }
    try await client.connectWebSocket(
      url: url, tls: .default, credentials: credentials, userAgent: nil)
    let (request, peer) = try await serverTask.value
    #expect(request.header("Authorization") == basicAuthorization)
    try await peer.sendFrame(.binary, Data(optionsResponse.utf8))
    expectResponse(try await client.receiveMessage(), status: 200, cseq: 1)
    await client.close()
  }
}

// MARK: - Codec and parsing tests

@Suite("WebSocket frame codec")
struct WebSocketFrameCodecTests {

  @Test("Client frames are masked with the given key and unmask to the payload")
  func masking() throws {
    let payload = Data("DESCRIBE rtsp://camera/ RTSP/1.0\r\n\r\n".utf8)
    let frame = WebSocketFrame.encode(opcode: .binary, payload: payload, maskKey: 0x1234_5678)
    #expect(frame[0] == 0x82, "FIN + binary")
    #expect(frame[1] == 0x80 | UInt8(payload.count), "mask bit + 7-bit length")
    #expect(Array(frame[2..<6]) == [0x12, 0x34, 0x56, 0x78])
    var body = Data(frame[6...])
    #expect(body != payload)
    WebSocketFrame.applyMask([0x12, 0x34, 0x56, 0x78], to: &body)
    #expect(body == payload)
  }

  @Test("Payload length uses the 7-bit, 16-bit and 64-bit encodings at the boundaries")
  func lengthEncodings() throws {
    for (length, headerLength) in [(0, 2), (125, 2), (126, 4), (65_535, 4), (65_536, 10)] {
      let payload = Data(repeating: 0xAB, count: length)
      let frame = WebSocketFrame.encode(opcode: .binary, payload: payload, maskKey: nil)
      #expect(frame.count == headerLength + length, "length \(length)")
      var decoder = WebSocketFrameDecoder()
      decoder.append(frame)
      #expect(try decoder.next() == .data(payload), "length \(length)")
      #expect(decoder.bufferedByteCount == 0)
    }
  }

  @Test("Frames fed one byte at a time decode once complete")
  func byteAtATime() throws {
    let bytes =
      WebSocketFrame.encode(opcode: .ping, payload: Data("p".utf8), maskKey: nil)
      + WebSocketFrame.encode(
        opcode: .binary, payload: Data(repeating: 1, count: 300), maskKey: nil)
    // A slice with a nonzero startIndex.
    let slice = (Data([0xFF, 0xFF]) + bytes).dropFirst(2)
    var decoder = WebSocketFrameDecoder()
    var events: [WebSocketFrameDecoder.Event] = []
    for index in slice.indices {
      decoder.append(slice[index...index])
      while let event = try decoder.next() {
        events.append(event)
      }
    }
    #expect(events == [.ping(Data("p".utf8)), .data(Data(repeating: 1, count: 300))])
  }

  @Test("Fragments decode in order with control frames between them")
  func fragmentation() throws {
    var decoder = WebSocketFrameDecoder()
    decoder.append(
      WebSocketFrame.encode(opcode: .text, payload: Data("ab".utf8), fin: false, maskKey: nil))
    decoder.append(WebSocketFrame.encode(opcode: .pong, payload: Data(), maskKey: nil))
    decoder.append(
      WebSocketFrame.encode(
        opcode: .continuation, payload: Data("cd".utf8), fin: false, maskKey: nil))
    decoder.append(
      WebSocketFrame.encode(opcode: .continuation, payload: Data("e".utf8), maskKey: nil))
    decoder.append(WebSocketFrame.encode(opcode: .binary, payload: Data("f".utf8), maskKey: nil))
    var events: [WebSocketFrameDecoder.Event] = []
    while let event = try decoder.next() {
      events.append(event)
    }
    #expect(
      events == [
        .data(Data("ab".utf8)), .pong(Data()), .data(Data("cd".utf8)), .data(Data("e".utf8)),
        .data(Data("f".utf8)),
      ])
  }

  /// RFC 6455 section 7.4: 1005, 1006 and 1015 are never sent, and other
  /// codes outside the assigned ranges aren't valid either; echoing one back
  /// would put it on the wire.
  @Test("A close frame with a reserved status code or a non-UTF-8 reason is a protocol error")
  func closeCodes() throws {
    func decode(_ payload: Data) throws -> WebSocketFrameDecoder.Event? {
      var decoder = WebSocketFrameDecoder()
      decoder.append(WebSocketFrame.encode(opcode: .close, payload: payload, maskKey: nil))
      return try decoder.next()
    }
    for code in [999, 1004, 1005, 1006, 1015, 1016, 2999, 5000] as [UInt16] {
      #expect(throws: WebSocketProtocolError.self, "\(code)") {
        _ = try decode(WebSocketFrame.closePayload(code))
      }
    }
    for code in [1000, 1001, 1002, 1003, 1007, 1011, 1014, 3000, 4999] as [UInt16] {
      #expect(try decode(WebSocketFrame.closePayload(code)) == .close(code: code, reason: ""))
    }
    #expect(throws: WebSocketProtocolError.self) {
      _ = try decode(WebSocketFrame.closePayload(1000) + Data([0xC3, 0x28]))
    }
    #expect(
      try decode(WebSocketFrame.closePayload(1000) + Data("bye".utf8))
        == .close(code: 1000, reason: "bye"))
  }

  @Test("Protocol violations are rejected with the right close code")
  func violations() {
    func decode(_ bytes: Data) -> WebSocketProtocolError? {
      var decoder = WebSocketFrameDecoder(maxPayloadBytes: 1024)
      decoder.append(bytes)
      do {
        while try decoder.next() != nil {}
        return nil
      } catch {
        return error
      }
    }
    let cases: [(String, Data, UInt16)] = [
      (
        "continuation without a start",
        WebSocketFrame.encode(opcode: .continuation, payload: Data([1]), maskKey: nil), 1002
      ),
      (
        "new message inside a fragmented one",
        WebSocketFrame.encode(opcode: .binary, payload: Data([1]), fin: false, maskKey: nil)
          + WebSocketFrame.encode(opcode: .binary, payload: Data([2]), maskKey: nil), 1002
      ),
      (
        "fragmented control frame",
        WebSocketFrame.encode(opcode: .ping, payload: Data(), fin: false, maskKey: nil), 1002
      ),
      (
        "oversized control frame",
        WebSocketFrame.encode(opcode: .ping, payload: Data(count: 126), maskKey: nil), 1002
      ),
      (
        "masked server frame",
        WebSocketFrame.encode(opcode: .binary, payload: Data([1]), maskKey: 1), 1002
      ),
      ("reserved bit", Data([0xC2, 0x00]), 1002),
      ("unknown opcode", Data([0x83, 0x00]), 1002),
      ("1-byte close payload", Data([0x88, 0x01, 0x03]), 1002),
      ("frame over the size limit", Data([0x82, 126, 0x04, 0x01]), 1009),
      ("16-bit length under 126", Data([0x82, 126, 0x00, 0x01, 0xAB]), 1002),
      ("64-bit length under 65536", Data([0x82, 127, 0, 0, 0, 0, 0, 0, 0x00, 0x01, 0xAB]), 1002),
      (
        "64-bit length with the top bit set", Data([0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 0x01]), 1002
      ),
      // 2^63 - 1: rejected from the header alone, never buffered.
      (
        "absurd 64-bit length", Data([0x82, 127, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        1009
      ),
    ]
    for (name, bytes, code) in cases {
      let error = decode(bytes)
      #expect(error?.closeCode == code, "\(name): \(String(describing: error))")
    }
  }

  @Test("Text messages must be UTF-8, also across fragments")
  func textMessagesUTF8() {
    /// The close code the frames fail with, or nil when all decode.
    func closeCode(_ frames: [(WebSocketOpcode, [UInt8], Bool)]) -> UInt16? {
      var decoder = WebSocketFrameDecoder()
      for (opcode, payload, fin) in frames {
        decoder.append(
          WebSocketFrame.encode(opcode: opcode, payload: Data(payload), fin: fin, maskKey: nil))
      }
      do {
        while try decoder.next() != nil {}
        return nil
      } catch {
        return error.closeCode
      }
    }
    let smile: [UInt8] = [0xF0, 0x9F, 0x98, 0x80]
    #expect(closeCode([(.text, Array("h\u{E9}llo".utf8), true)]) == nil)
    // A character split between fragments, at each point.
    for split in 1..<4 {
      #expect(
        closeCode([
          (.text, [0x41] + smile.prefix(split), false),
          (.continuation, Array(smile.dropFirst(split)) + [0x42], true),
        ]) == nil, "split \(split)")
    }
    #expect(closeCode([(.text, [0xC3], false), (.continuation, [0xA9], true)]) == nil)
    for bad: [UInt8] in [
      [0xFF, 0xFE], [0xC0, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80],
    ] {
      #expect(closeCode([(.text, bad, true)]) == 1007, "\(bad)")
      #expect(closeCode([(.text, [0x41], false), (.continuation, bad, true)]) == 1007, "\(bad)")
    }
    // A message that ends inside a character.
    #expect(closeCode([(.text, [0x41, 0xC3], true)]) == 1007)
    #expect(closeCode([(.text, [0x41, 0xC3], false), (.continuation, [], true)]) == 1007)
    // Binary messages are bytes, and a text message's check ends with it.
    #expect(closeCode([(.binary, [0xFF, 0xFE], true)]) == nil)
    #expect(
      closeCode([(.text, [0x41], true), (.binary, [0xC3], false), (.continuation, [0xFF], true)])
        == nil)
  }

  @Test("Payload lengths in their shortest form are accepted", arguments: [125, 126, 65535, 65536])
  func lengthForms(count: Int) throws {
    var decoder = WebSocketFrameDecoder(maxPayloadBytes: 70_000)
    let payload = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
    decoder.append(WebSocketFrame.encode(opcode: .binary, payload: payload, maskKey: nil))
    #expect(try decoder.next() == .data(payload))
  }

  @Test("Close frames carry an optional code and reason")
  func closeFrames() throws {
    var decoder = WebSocketFrameDecoder()
    decoder.append(Data([0x88, 0x00]))
    decoder.append(
      WebSocketFrame.encode(
        opcode: .close, payload: WebSocketFrame.closePayload(1000) + Data("done".utf8),
        maskKey: nil))
    #expect(try decoder.next() == .close(code: nil, reason: ""))
    #expect(try decoder.next() == .close(code: 1000, reason: "done"))
  }

  @Test("Sec-WebSocket-Accept matches the RFC 6455 example")
  func acceptValue() {
    #expect(
      WebSocketTransport.acceptValue(forKey: "dGhlIHNhbXBsZSBub25jZQ==")
        == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
  }
}

@Suite("HTTP helpers for tunnels")
struct HTTPTunnelHelperTests {

  @Test("Response heads parse from a slice and report the bytes after them")
  func parseResponseHead() throws {
    let bytes = Data(("xx" + tunnelResponseHead + "RTSP/1.0").utf8).dropFirst(2)
    let (head, length) = try #require(try HTTPResponseHead.parse(bytes))
    #expect(head.statusCode == 200)
    #expect(head.reasonPhrase == "OK")
    #expect(head.version == "HTTP/1.0")
    #expect(head.header("content-type") == "application/x-rtsp-tunnelled")
    #expect(Data(bytes.dropFirst(length)) == Data("RTSP/1.0".utf8))
    #expect(try HTTPResponseHead.parse(Data("HTTP/1.0 200 OK\r\n".utf8)) == nil)
  }

  @Test("A GBK Digest realm in a tunnel 401 is hashed and echoed as the bytes the server sent")
  func latin1TunnelChallenge() throws {
    let realm: [UInt8] = [0xC9, 0xE3, 0xCF, 0xF1, 0xBB, 0xFA]  // GBK "camera"
    var bytes = Data("HTTP/1.0 401 Unauthorized\r\nWWW-Authenticate: Digest realm=\"".utf8)
    bytes.append(contentsOf: realm)
    bytes.append(Data("\",\r\n nonce=\"abc\"\r\nContent-Length: 0\r\n\r\n".utf8))
    let (head, _) = try #require(try HTTPResponseHead.parse(bytes))
    let values = head.headerValues(named: "www-authenticate")
    #expect(values.map(\.isLatin1) == [true])
    var expectedChallenge = Data("Digest realm=\"".utf8)
    expectedChallenge.append(contentsOf: realm)
    expectedChallenge.append(Data("\", nonce=\"abc\"".utf8))
    #expect(values.first?.bytes == expectedChallenge)
    #expect(head.headerValues(named: "content-length").map(\.isLatin1) == [false])

    var auth = RTSPAuthenticator(credentials: Credentials(username: "u", password: "p"))
    auth.handleChallenges(values)
    let endpoint = try HTTPEndpoint(
      url: try #require(URL(string: "http://camera.local/s")),
      plainScheme: "http", tlsScheme: "https")
    let request = HTTPTunnel.getRequest(
      endpoint: endpoint, cookie: "c", userAgent: nil,
      authorization: auth.authorizationHeader(method: "GET", uri: "/s"))
    var ha1Input = Data("u:".utf8)
    ha1Input.append(contentsOf: realm)
    ha1Input.append(Data(":p".utf8))
    let ha1 = Insecure.MD5.hash(data: ha1Input).map { String(format: "%02x", $0) }.joined()
    let response = md5Hex("\(ha1):abc:\(md5Hex("GET:/s"))")
    var expected = Data("Authorization: Digest username=\"u\", realm=\"".utf8)
    expected.append(contentsOf: realm)
    expected.append(Data("\", nonce=\"abc\", uri=\"/s\", response=\"\(response)\"\r\n\r\n".utf8))
    #expect(request.suffix(expected.count) == expected)
  }

  /// A valid 101 head for the RFC 6455 sample key, with `extra` lines added.
  @Test(
    "Every line of a repeated upgrade header is checked",
    arguments: [
      ("Connection: keep-alive\r\nConnection: Upgrade\r\n", true),
      ("Upgrade: websocket\r\n", true),
      ("Upgrade: h2c\r\n", false),
      ("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n", false),
      ("Sec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAA=\r\n", false),
      ("Sec-WebSocket-Protocol: rtsp.onvif.org\r\nSec-WebSocket-Protocol: chat\r\n", false),
      ("Sec-WebSocket-Protocol: rtsp.onvif.org\r\n", true),
      ("Sec-WebSocket-Extensions:\r\nSec-WebSocket-Extensions: permessage-deflate\r\n", false),
      ("Sec-WebSocket-Extensions: \r\n", true),
      ("Sec-WebSocket-Protocol:\r\n", true),
      ("Sec-WebSocket-Protocol:\r\nSec-WebSocket-Protocol: rtsp.onvif.org\r\n", true),
    ])
  func repeatedUpgradeHeaders(extra: String, accepted: Bool) throws {
    var lines = [
      "HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade",
      "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
    ]
    // The Connection case replaces the valid Connection line.
    if extra.hasPrefix("Connection:") { lines.remove(at: 2) }
    let text = lines.joined(separator: "\r\n") + "\r\n" + extra + "\r\n"
    let (head, _) = try #require(try HTTPResponseHead.parse(Data(text.utf8)))
    let result = Result {
      try WebSocketTransport.validateUpgrade(head, key: "dGhlIHNhbXBsZSBub25jZQ==")
    }
    if accepted {
      #expect(throws: Never.self) { try result.get() }
    } else {
      #expect(throws: RTSPError.self) { try result.get() }
    }
  }

  @Test("Response heads with CR CR LF line endings parse like CRLF ones")
  func crCRLFHeads() throws {
    let upgrade =
      "HTTP/1.1 101 Switching Protocols\r\r\nUpgrade: websocket\r\r\nConnection: Upgrade\r\r\n"
      + "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\r\n\r\r\n"
    let (head, _) = try #require(try HTTPResponseHead.parse(Data(upgrade.utf8)))
    #expect(head.reasonPhrase == "Switching Protocols")
    #expect(head.header("Upgrade") == "websocket")
    #expect(throws: Never.self) {
      try WebSocketTransport.validateUpgrade(head, key: "dGhlIHNhbXBsZSBub25jZQ==")
    }
    let challenge =
      "HTTP/1.0 401 Unauthorized\r\r\nWWW-Authenticate: Digest realm=\"r\", nonce=\"n\"\r\r\n"
      + "Server: cam\r\r\n\r\r\n"
    let (challengeHead, _) = try #require(try HTTPResponseHead.parse(Data(challenge.utf8)))
    var auth = RTSPAuthenticator(credentials: Credentials(username: "u", password: "p"))
    auth.handleChallenges(challengeHead.headerValues(named: "WWW-Authenticate"))
    #expect(auth.usesDigest)
  }

  @Test("A response head arriving two bytes at a time costs little and its line count is capped")
  func trickledHead() throws {
    var buffer = Data("HTTP/1.0 200 OK\r\n".utf8)
    let started = ContinuousClock.now
    var rejected = false
    while buffer.count < HTTPResponseHead.maxBytes {
      buffer.append(Data("a\n".utf8))
      do {
        #expect(try HTTPResponseHead.parse(buffer) == nil)
      } catch {
        rejected = true
        break
      }
    }
    #expect(rejected, "more than \(HTTPResponseHead.maxLines) header lines accepted")
    // One long header line, which has no line feeds to cap.
    buffer = Data("HTTP/1.0 200 OK\r\nX: ".utf8)
    while buffer.count < HTTPResponseHead.maxBytes {
      buffer.append(Data("ab".utf8))
      #expect(try HTTPResponseHead.parse(buffer) == nil)
    }
    #expect(ContinuousClock.now - started < .seconds(1))
  }

  @Test("An IPv6 zone id stays out of the Host header but is kept for connecting")
  func zoneNotInHostHeader() throws {
    let endpoint = try HTTPEndpoint(
      url: try #require(URL(string: "http://[fe80::1%25lo0]:8080/x")),
      plainScheme: "http", tlsScheme: "https")
    #expect(endpoint.hostHeader == "[fe80::1]:8080")
    #expect(endpoint.host == "fe80::1%lo0")
  }

  @Test(
    "An internationalized tunnel host is sent and connected to as IDNA A-labels",
    .timeLimit(.minutes(1)),
    arguments: [
      "http://xn--caf-dma.example:8080/live", "http://café.example:8080/live",
      "http://caf%C3%A9.example:8080/live",
    ])
  func idnHostHeader(_ url: String) throws {
    let endpoint = try HTTPEndpoint(
      url: try #require(URL(string: url)), plainScheme: "http", tlsScheme: "https")
    #expect(endpoint.host == "xn--caf-dma.example")
    #expect(endpoint.hostHeader == "xn--caf-dma.example:8080")
    let heads = [
      HTTPTunnel.getRequest(endpoint: endpoint, cookie: "c", userAgent: nil, authorization: nil),
      HTTPTunnel.postRequest(endpoint: endpoint, cookie: "c", userAgent: nil, authorization: nil),
      WebSocketTransport.upgradeRequest(
        endpoint: endpoint, key: "dGhlIHNhbXBsZSBub25jZQ==", userAgent: nil, authorization: nil),
    ]
    for head in heads {
      let text = String(decoding: head, as: UTF8.self)
      #expect(head.allSatisfy { $0 < 0x80 }, "\(text)")
      #expect(text.contains("\r\nHost: xn--caf-dma.example:8080\r\n"), "\(text)")
    }
  }

  @Test(
    "Errors about a tunnel URL don't show its password",
    arguments: [
      "ftp://admin:s3cret@cam/x", "http://admin:s3cret@cam:0/x",
      "http://admin:s3cret@cam:18446744073709551615/x",
    ])
  func tunnelURLErrorsRedacted(_ url: String) throws {
    let error = #expect(throws: RTSPError.self) {
      try HTTPEndpoint(url: try #require(URL(string: url)), plainScheme: "http", tlsScheme: "https")
    }
    let message = String(describing: try #require(error))
    #expect(!message.contains("s3cret"), "\(message)")
    #expect(message.contains("***@cam"), "\(message)")
  }

  @Test("Response heads may have 256 header lines, not 257, as RTSP responses")
  func headLineLimit() throws {
    func head(_ lines: Int) -> Data {
      var text = "HTTP/1.0 200 OK\r\n"
      for index in 0..<lines { text += "X-\(index): v\r\n" }
      return Data((text + "\r\n").utf8)
    }
    #expect(try HTTPResponseHead.parse(head(256))?.head.headers.count == 256)
    #expect(throws: RTSPError.self) { _ = try HTTPResponseHead.parse(head(257)) }
  }

  @Test("Request heads drop control characters, so no value adds a header")
  func requestHeadControlCharacters() {
    let head = httpRequestHead(
      method: "GET", target: "/s", version: "HTTP/1.0",
      headers: [("Host", "camera\r\nX-Injected: 1")])
    let text = String(decoding: head, as: UTF8.self)
    #expect(text == "GET /s HTTP/1.0\r\nHost: cameraX-Injected: 1\r\n\r\n")
  }

  @Test("Malformed status lines are rejected")
  func malformedStatus() {
    for line in ["RTSP/1.0 200 OK", "HTTP/1.0 2000 OK", "HTTP/1.0 abc", "HTTP/1.0"] {
      #expect(throws: RTSPError.self, "\(line)") {
        _ = try HTTPResponseHead.parse(Data("\(line)\r\n\r\n".utf8))
      }
    }
  }

  @Test("Endpoints get default ports, a bracketed IPv6 Host, and path + query")
  func endpoints() throws {
    let plain = try HTTPEndpoint(
      url: try #require(URL(string: "http://camera.local/a/b?c=d%20e")),
      plainScheme: "http", tlsScheme: "https")
    #expect(plain.host == "camera.local")
    #expect(plain.port == 80)
    #expect(!plain.usesTLS)
    #expect(plain.target == "/a/b?c=d%20e")
    #expect(plain.hostHeader == "camera.local")

    let secure = try HTTPEndpoint(
      url: try #require(URL(string: "WSS://[::1]:8443")), plainScheme: "ws", tlsScheme: "wss")
    #expect(secure.host == "::1")
    #expect(secure.port == 8443)
    #expect(secure.usesTLS)
    #expect(secure.target == "/")
    #expect(secure.hostHeader == "[::1]:8443")

    #expect(throws: RTSPError.self) {
      _ = try HTTPEndpoint(
        url: try #require(URL(string: "ws://camera.local/")), plainScheme: "http",
        tlsScheme: "https")
    }
  }

  @Test("Header values lose control characters")
  func sanitizing() {
    #expect(sanitizedHeaderValue("agent\r\nX-Evil: 1") == "agentX-Evil: 1")
  }

  @Test("Session cookies are long, alphanumeric and distinct")
  func cookies() {
    let first = randomAlphanumericToken(length: HTTPTunnel.cookieLength)
    let second = randomAlphanumericToken(length: HTTPTunnel.cookieLength)
    #expect(first.count >= 22)
    #expect(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
    #expect(first != second)
  }
}
