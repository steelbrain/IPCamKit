// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// NWConnection-based TCP (and TLS) transport for RTSP, with RTSP framing on top
// of a pluggable byte stream (direct, HTTP tunnel, or WebSocket)

import Foundation
import Network

/// A bidirectional byte stream that carries the RTSP control connection.
///
/// `RTSPTransportConnection` owns the RTSP framing (its read buffer and
/// `RTSPParser`) and runs it on top of one of these:
/// - `DirectByteStream`: one TCP (or TLS) `NWConnection`, for `rtsp://` and
///   `rtsps://` URLs.
/// - `HTTPTunnelByteStream`: QuickTime-style RTSP over HTTP tunneling, where an
///   HTTP GET carries server-to-client bytes and an HTTP POST carries
///   base64-encoded client-to-server bytes.
/// - `WebSocketByteStream`: ONVIF RTSP over WebSocket (`rtsp.onvif.org`).
protocol RTSPByteStream: AnyObject, Sendable {
  /// Send `data` (one RTSP request or one `$`-framed interleaved packet).
  /// Each call goes out as one unit, so concurrent calls never interleave
  /// their bytes.
  func send(_ data: Data) async throws

  /// The next chunk of server-to-client RTSP bytes, never empty. Chunk
  /// boundaries carry no meaning. Throws `RTSPError.unexpectedDisconnection`
  /// at the end of the stream.
  func receive() async throws -> Data

  /// Tear the stream down. A pending `receive` fails. Idempotent.
  func cancel()
}

/// A connection the connect methods have finished setting up: the byte stream
/// plus any RTSP bytes that arrived during an HTTP or WebSocket handshake and
/// belong at the front of the read buffer.
struct EstablishedStream: Sendable {
  let stream: any RTSPByteStream
  /// RTSP bytes already received (e.g. after the tunnel GET's header block).
  let initialBytes: Data
  /// The connection whose endpoints describe the session in `ctx`.
  let primary: NWConnection
}

/// A TCP connection for RTSP communication using Apple's Network framework,
/// wrapped in TLS for `rtsps://` URLs, or tunneled through HTTP(S) or a
/// WebSocket.
///
/// Handles:
/// - TCP (or TLS-over-TCP) connection lifecycle (connect, send, receive)
/// - RTSP message framing (responses and interleaved data)
/// - Buffered reading for partial message assembly
/// - Private dispatch queue for NWConnection callbacks
actor RTSPTransportConnection {
  private var stream: (any RTSPByteStream)?
  /// The connect in progress, so `close()` can cancel its connections.
  private var pendingAttempt: ConnectAttempt?
  private let queue = DispatchQueue(label: "ipcamkit.rtsp.connection")
  private let parser = RTSPParser()
  private var readBuffer = Data()
  private var connectionContext: ConnectionContext?

  /// Cap on the unparsed read buffer, checked before each read. A peer that
  /// never frames a message — no header terminator, or a `$`-interleaved frame
  /// whose length is never satisfied — would otherwise grow this without bound
  /// (memory-DoS). One read can add up to a WebSocket message's payload
  /// (`WebSocketFrameDecoder.maxPayloadBytes`) beyond it, so the buffer stays
  /// below twice this size. A full interleaved frame is at most ~64 KiB and an
  /// RTSP message body is capped at `RTSPParser.maxBodyBytes`, so this leaves
  /// wide headroom for any real camera.
  static let maxReadBufferBytes = 4 * 1024 * 1024

  /// Maximum time to wait for the TCP connection to become ready. NWConnection
  /// has no built-in connect deadline, so a half-open server would otherwise
  /// hang `connect()` forever. For tunnels it bounds the whole setup: every
  /// TCP/TLS connect plus the HTTP or WebSocket handshake.
  private let connectTimeoutSeconds: Double

  /// Grace window for a transient `.waiting` state (e.g. connection refused /
  /// no route, which NWConnection parks in `.waiting` rather than `.failed`)
  /// before surfacing the real error, so an unreachable camera fails fast with
  /// its actual cause instead of burning the full connect timeout.
  private let waitingGraceSeconds: Double = 2

  /// Count of interleaved data frames dropped by `receiveResponse` while waiting
  /// for an RTSP response (a camera that streamed media before its PLAY reply).
  private(set) var droppedInterleavedBeforeResponse = 0

  /// - Parameter connectTimeoutSeconds: the connect deadline; tests shorten it.
  init(connectTimeoutSeconds: Double = 15) {
    self.connectTimeoutSeconds = connectTimeoutSeconds
  }

  /// A connection released without `close()` still releases its socket(s):
  /// a started `NWConnection` stays open until cancelled.
  deinit {
    pendingAttempt?.abort(.unexpectedDisconnection)
    stream?.cancel()
  }

  /// Connect to an RTSP server. With `tls` (an `rtsps://` URL) the connection
  /// runs over TLS and becomes ready only after the handshake, including the
  /// server-certificate check `tls.serverTrust` selects, has succeeded.
  func connect(host: String, port: UInt16, tls: TLSOptions? = nil) async throws {
    try await establish { opener in
      let connection = try await opener.open(host: host, port: port, tls: tls)
      return EstablishedStream(
        stream: DirectByteStream(connection: connection), initialBytes: Data(),
        primary: connection.nwConnection)
    }
  }

  /// RTSP over HTTP tunneling. `url` is http:// or https:// (TLS with `tls`);
  /// the GET and POST target url's path+query.
  ///
  /// Opens the QuickTime-style tunnel: an HTTP GET whose response body carries
  /// RTSP responses and interleaved data from the server, and an HTTP POST
  /// (same `x-sessioncookie`) whose body carries each `send(_:)` base64-encoded.
  /// A `401` on the GET is answered with `credentials`, once more when that
  /// answer is refused with `stale=true` and a new nonce, and once with Basic
  /// when the server rejects a Digest answer and offered Basic too; the POST
  /// carries the matching `Authorization`. Throws `RTSPError.connectionFailed` for any
  /// other non-200 status (the message includes the status code),
  /// `RTSPError.authenticationFailed` when the server rejects the credentials
  /// (or none were given), and `RTSPError.timeout` if setup takes longer than
  /// 15 seconds. RTP can only be interleaved on a tunnel, so `resolvedRemote()`
  /// returns `nil`.
  func connectHTTPTunnel(
    url: URL, tls: TLSOptions, credentials: Credentials?, userAgent: String?
  ) async throws {
    try await establish { opener in
      try await HTTPTunnel.connect(
        url: url, tls: tls, credentials: credentials, userAgent: userAgent, opener: opener)
    }
  }

  /// RTSP over WebSocket. `url` is ws:// or wss:// (TLS with `tls`).
  ///
  /// Performs the RFC 6455 upgrade with `Sec-WebSocket-Protocol:
  /// rtsp.onvif.org` (ONVIF Streaming Specification), then carries each
  /// `send(_:)` as one binary message and treats incoming message payloads as
  /// one continuous RTSP byte stream. A `401` on the upgrade is answered as
  /// for `connectHTTPTunnel`. Errors are as for `connectHTTPTunnel`. RTP can only
  /// be interleaved on a WebSocket, so `resolvedRemote()` returns `nil`.
  func connectWebSocket(
    url: URL, tls: TLSOptions, credentials: Credentials?, userAgent: String?
  ) async throws {
    try await establish { opener in
      try await WebSocketTransport.connect(
        url: url, tls: tls, credentials: credentials, userAgent: userAgent, opener: opener)
    }
  }

  /// Run one connect: `open` sets up the byte stream through `opener`, under
  /// the connect deadline, and the result becomes this connection's stream.
  /// `close()` during the connect cancels it.
  private func establish(
    _ open: (ConnectionOpener) async throws -> EstablishedStream
  ) async throws {
    let attempt = ConnectAttempt()
    pendingAttempt = attempt
    defer {
      if pendingAttempt === attempt { pendingAttempt = nil }
    }
    queue.asyncAfter(deadline: .now() + connectTimeoutSeconds) {
      attempt.abort(.timeout)
    }
    let opener = ConnectionOpener(
      queue: queue, timeoutSeconds: connectTimeoutSeconds,
      waitingGraceSeconds: waitingGraceSeconds, attempt: attempt)

    let established: EstablishedStream
    do {
      established = try await open(opener)
    } catch {
      // Cancel whatever the failed setup left open. If the deadline or close()
      // caused the failure, report that rather than the cancellation it caused.
      let reason = attempt.abortReason
      attempt.abort(.unexpectedDisconnection)
      throw reason ?? error
    }
    if let reason = attempt.finish() {
      established.stream.cancel()
      throw reason
    }

    stream = established.stream
    readBuffer = established.initialBytes
    if let localEndpoint = established.primary.currentPath?.localEndpoint,
      let remoteEndpoint = established.primary.currentPath?.remoteEndpoint
    {
      connectionContext = ConnectionContext(
        localAddr: "\(localEndpoint)",
        peerAddr: "\(remoteEndpoint)",
        establishedWall: .now()
      )
    } else {
      connectionContext = .dummy()
    }
  }

  /// Describe a connect failure. TLS failures (a certificate rejected by
  /// `TLSOptions.serverTrust`, or no common protocol version) are labelled as
  /// such so they aren't mistaken for an unreachable host.
  static func describe(_ error: NWError) -> String {
    guard case .tls(let status) = error else { return error.localizedDescription }
    // Network reports a failed server-trust decision (system evaluation of a
    // self-signed certificate, or our verify block returning false) as
    // errSSLBadCert, whose system string, "bad certificate format", would
    // misdirect the reader.
    if status == errSSLBadCert {
      return "TLS handshake failed: server certificate rejected by TLSOptions.serverTrust "
        + "(OSStatus \(status))"
    }
    return "TLS handshake failed: \(tlsReason(status))"
  }

  /// Describe a failure Network reported after the connection became ready.
  /// A TLS error before any data arrived is taken as the server aborting the
  /// handshake after the client finished its part (a TLS 1.3 server that
  /// requires a client certificate does this), so it is labelled as a failed
  /// handshake; one after data arrived, as a failed connection.
  static func describeAfterReady(_ error: NWError, dataReceived: Bool) -> String {
    guard case .tls(let status) = error else { return error.localizedDescription }
    let what = dataReceived ? "TLS connection failed" : "TLS handshake failed"
    return "\(what): \(tlsReason(status))"
  }

  /// The system's text for a TLS `status`, followed by the code.
  private static func tlsReason(_ status: OSStatus) -> String {
    let reason = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
    return "\(reason) (OSStatus \(status))"
  }

  /// Send raw data over the connection.
  func send(_ data: Data) async throws {
    guard let stream else {
      throw RTSPError.connectionFailed("Not connected")
    }
    try await stream.send(data)
  }

  /// Send an RTSP request and wait for the response.
  func sendRequest(_ request: RTSPRequest) async throws -> RTSPResponse {
    let serializer = RTSPSerializer()
    let data = serializer.serialize(request)
    try await send(data)
    return try await receiveResponse()
  }

  /// Buffered bytes the message being received needs before a parse can
  /// complete it: its header block plus `Content-Length`, or a `$` frame's
  /// length. 0 while unknown (an incomplete header block, re-parsed after each
  /// read; `RTSPParser` caps it at 64 KiB). Skipping parses until then keeps a
  /// body that trickles in from re-parsing its headers on every read.
  private var neededBytes = 0

  /// Receive the next RTSP message (response or interleaved data). Requests
  /// the server sends to the client (RFC 2326 section 10, e.g. an OPTIONS
  /// keepalive or a SET_PARAMETER) are answered here (200 for OPTIONS and
  /// GET_PARAMETER, 501 otherwise) and reading continues.
  func receiveMessage() async throws -> RTSPMessage {
    while true {
      if readBuffer.count >= neededBytes {
        switch try parser.parseNext(&readBuffer) {
        case .message(let message):
          neededBytes = 0
          return message
        case .serverRequest(let request):
          neededBytes = 0
          try await send(RTSPSerializer().serializeReply(to: request))
          continue
        case .needMore(let total):
          neededBytes = total ?? 0
        }
      }

      // No complete message yet. Bound the buffer before reading more so a peer
      // that never frames a message can't exhaust memory. Checked here (after
      // the parse attempt) so a message that just completed still parses.
      guard readBuffer.count <= Self.maxReadBufferBytes else {
        throw RTSPError.connectionFailed(
          "RTSP read buffer exceeded \(Self.maxReadBufferBytes) bytes without a complete message")
      }

      // Need more data
      let newData = try await readData()
      Self.appendCompacting(newData, to: &readBuffer)
    }
  }

  /// Append `newData` to `buffer`, first moving any unconsumed bytes to a new
  /// allocation when parsed messages were removed from the front. For `Data`,
  /// `removeFirst` only advances the start index; appending to the same
  /// storage would keep every byte ever received.
  static func appendCompacting(_ newData: Data, to buffer: inout Data) {
    if buffer.startIndex != 0 {
      buffer = buffer.isEmpty ? Data() : Data(buffer)
    }
    buffer.append(newData)
  }

  /// Receive the next RTSP response, skipping interleaved data.
  ///
  /// Only used on the pre-PLAY request/response path (OPTIONS/DESCRIBE/SETUP/
  /// PLAY). Per RFC 2326 the server must not stream media before the PLAY reply,
  /// so no interleaved `.data` is expected here; any that arrives (a
  /// non-conformant camera bursting media on the control channel before PLAY) is
  /// dropped and counted in `droppedInterleavedBeforeResponse` for diagnostics.
  func receiveResponse() async throws -> RTSPResponse {
    while true {
      let msg = try await receiveMessage()
      if case .response(let resp) = msg {
        return resp
      }
      // Interleaved data before the awaited response — drop and tally it.
      droppedInterleavedBeforeResponse += 1
    }
  }

  /// Read raw data from the byte stream.
  ///
  /// Known limitation: there is no per-read idle timeout. A peer that goes
  /// silent after setup leaves this parked until `close()` (via `stop()`) is
  /// called or the keepalive detects the dead session. An idle timeout is
  /// deliberately omitted — sizing it without killing legitimately bursty /
  /// low-FPS streams is unsafe — so liveness is the keepalive/stop() contract.
  private func readData() async throws -> Data {
    guard let stream else {
      throw RTSPError.unexpectedDisconnection
    }
    return try await stream.receive()
  }

  /// Close the connection.
  func close() {
    pendingAttempt?.abort(.unexpectedDisconnection)
    stream?.cancel()
    stream = nil
  }

  /// The connection context for error reporting.
  var ctx: ConnectionContext {
    connectionContext ?? .dummy()
  }

  /// The resolved remote address (and family) of the control connection, if
  /// available. Lets UDP transport pick its local socket family and target the
  /// server's RTP/RTCP ports without a second DNS lookup when the SETUP response
  /// omits an explicit `source`. The host is a numeric literal — a dotted IPv4
  /// address or a bare IPv6 address (with zone id for link-local) — never
  /// bracketed, so it can be handed straight to `NWEndpoint.Host`. Returns `nil`
  /// for unresolved endpoints, and for HTTP-tunnel and WebSocket connections,
  /// which only carry RTP interleaved.
  func resolvedRemote() -> ResolvedPeer? {
    guard let direct = stream as? DirectByteStream else { return nil }
    return Self.peer(direct.connection.nwConnection.currentPath?.remoteEndpoint)
  }

  /// The local address of a direct control connection: the interface a
  /// multicast group is joined on, so the server's packets sent on that
  /// interface are received. nil for tunnels or before connecting.
  func resolvedLocal() -> ResolvedPeer? {
    guard let direct = stream as? DirectByteStream else { return nil }
    return Self.peer(direct.connection.nwConnection.currentPath?.localEndpoint)
  }

  private static func peer(_ endpoint: NWEndpoint?) -> ResolvedPeer? {
    guard case .hostPort(let host, _)? = endpoint else { return nil }
    switch host {
    case .ipv4(let addr):
      return ResolvedPeer(host: "\(addr)", isIPv6: false)
    case .ipv6(let addr):
      return ResolvedPeer(host: "\(addr)", isIPv6: true)
    case .name:
      // An unresolved hostname endpoint is not directly usable as a UDP peer
      // (no family known); callers fall back to the URL host / source instead.
      return nil
    @unknown default:
      return nil
    }
  }
}

/// The resolved remote peer of the control connection: a numeric host literal
/// plus its address family. Drives the UDP transport's local socket family and
/// RTP/RTCP peer selection.
struct ResolvedPeer: Sendable {
  /// Numeric IP literal (dotted IPv4 or bare IPv6, with zone id for link-local).
  let host: String
  /// `true` for IPv6, `false` for IPv4.
  let isIPv6: Bool
}

// MARK: - Direct byte stream

/// RTSP straight over one TCP (or TLS) connection.
final class DirectByteStream: RTSPByteStream {
  let connection: WatchedConnection

  init(connection: WatchedConnection) {
    self.connection = connection
  }

  func send(_ data: Data) async throws {
    try await connection.send(data)
  }

  func receive() async throws -> Data {
    guard let data = try await connection.receive() else {
      throw RTSPError.unexpectedDisconnection
    }
    return data
  }

  func cancel() {
    connection.cancel()
  }
}

// MARK: - Connection setup

/// The connections opened by one connect, so the connect deadline or `close()`
/// can cancel all of them, and the reason it was cut short.
///
/// State is guarded by `lock`, hence `@unchecked Sendable`.
final class ConnectAttempt: @unchecked Sendable {
  private let lock = NSLock()
  private var connections: [NWConnection] = []
  private var reason: RTSPError?
  private var finished = false

  /// Register `connection` for cancellation. Returns `false` (and cancels
  /// it) if the attempt was already aborted.
  @discardableResult
  func track(_ connection: NWConnection) -> Bool {
    lock.lock()
    let aborted = reason != nil
    if !aborted && !finished {
      connections.append(connection)
    }
    lock.unlock()
    if aborted { connection.cancel() }
    return !aborted
  }

  /// Stop tracking `connection` (the setup closed it itself).
  func untrack(_ connection: NWConnection) {
    lock.lock()
    connections.removeAll { $0 === connection }
    lock.unlock()
  }

  /// Cut the attempt short with `error`, cancelling every tracked connection.
  /// No-op once finished or already aborted.
  func abort(_ error: RTSPError) {
    lock.lock()
    guard !finished, reason == nil else {
      lock.unlock()
      return
    }
    reason = error
    let toCancel = connections
    connections.removeAll()
    lock.unlock()
    for connection in toCancel { connection.cancel() }
  }

  /// Why the attempt was aborted, or `nil` if it wasn't.
  var abortReason: RTSPError? {
    lock.lock()
    defer { lock.unlock() }
    return reason
  }

  /// Mark the attempt complete, so a later abort is a no-op. Returns the abort
  /// reason if an abort won the race (the setup's connections are cancelled).
  func finish() -> RTSPError? {
    lock.lock()
    defer { lock.unlock() }
    finished = true
    connections.removeAll()
    return reason
  }
}

/// Opens TCP (or TLS) connections for one connect attempt with the connect
/// timeout, the `.waiting` grace, and TLS error labelling.
struct ConnectionOpener: Sendable {
  let queue: DispatchQueue
  let timeoutSeconds: Double
  let waitingGraceSeconds: Double
  let attempt: ConnectAttempt

  /// One-shot guard so the connect continuation resumes exactly once across the
  /// state handler and the timeout. Both run on the serial `queue`, so plain
  /// access is race-free (hence `@unchecked Sendable`).
  private final class ConnectGuard: @unchecked Sendable {
    var settled = false
  }

  /// Open a connection to `host`:`port`, over TLS when `tls` is non-nil. The
  /// connection becomes ready only after the TLS handshake, including the
  /// server-certificate check `tls.serverTrust` selects, has succeeded. From
  /// then on it is watched for a failure (see `WatchedConnection`).
  func open(host: String, port: UInt16, tls: TLSOptions?) async throws -> WatchedConnection {
    let nwHost = NWEndpoint.Host(host)
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      throw RTSPError.invalidURL("Invalid port \(port)")
    }
    let parameters: NWParameters
    if let tls {
      let verifyQueue = DispatchQueue(label: "ipcamkit.rtsp.tls-verify")
      parameters = NWParameters(
        tls: tls.makeProtocolOptions(host: host, verifyQueue: verifyQueue),
        tcp: NWProtocolTCP.Options())
    } else {
      parameters = .tcp
    }
    let conn = NWConnection(host: nwHost, port: nwPort, using: parameters)
    guard attempt.track(conn) else {
      throw attempt.abortReason ?? RTSPError.unexpectedDisconnection
    }
    let watched = WatchedConnection(conn)
    let watch: @Sendable (NWConnection.State) -> Void = { [weak watched] state in
      watched?.handle(state)
    }

    let guardState = ConnectGuard()
    let timeout = timeoutSeconds
    let queue = queue
    do {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        // Resume exactly once; only ever called on the serial `queue`.
        @Sendable func settle(_ result: Result<Void, Error>) {
          guard !guardState.settled else { return }
          guardState.settled = true
          continuation.resume(with: result)
        }
        let grace = waitingGraceSeconds
        let graceQueue = queue
        conn.stateUpdateHandler = { [weak conn] state in
          switch state {
          case .ready:
            // Hand later state changes to the watcher. Swapped here, on the
            // connection's queue, so no change can arrive between the two
            // handlers.
            conn?.stateUpdateHandler = watch
            settle(.success(()))
          case .failed(let error):
            settle(
              .failure(
                RTSPError.connectionFailed(
                  RTSPTransportConnection.describe(error), underlying: error)))
          case .waiting(let error):
            if case .tls = error {
              // NWConnection also parks a rejected certificate in .waiting.
              // Retrying the handshake cannot change the verdict, so fail now.
              settle(
                .failure(
                  RTSPError.connectionFailed(
                    RTSPTransportConnection.describe(error), underlying: error)))
              break
            }
            // NWConnection parks in .waiting for ECONNREFUSED/EHOSTUNREACH
            // instead of going to .failed. Give it a brief grace window to
            // self-recover, then surface the real error rather than waiting out
            // the full connect timeout. A later .ready/.failed settles first
            // (the one-shot guard makes this deferred settle a no-op).
            graceQueue.asyncAfter(deadline: .now() + grace) {
              settle(
                .failure(
                  RTSPError.connectionFailed(
                    RTSPTransportConnection.describe(error), underlying: error)))
            }
          case .cancelled:
            settle(.failure(RTSPError.unexpectedDisconnection))
          default:
            break
          }
        }
        queue.asyncAfter(deadline: .now() + timeout) {
          settle(.failure(RTSPError.timeout))
        }
        conn.start(queue: queue)
        // An abort (close() or the connect deadline) that landed between
        // track() and start() cancelled the connection before it started, and
        // Network may then report no state at all; settle with its reason now
        // rather than at the timeout.
        queue.async {
          if let reason = attempt.abortReason { settle(.failure(reason)) }
        }
      }
    } catch {
      // On timeout/failure, tear down the half-open socket. A late `.cancelled`
      // from this is ignored by the already-settled guard.
      conn.cancel()
      attempt.untrack(conn)
      throw error
    }
    return watched
  }
}

// MARK: - NWConnection I/O

/// A connection `ConnectionOpener` opened, watched for a failure after it
/// became ready.
///
/// A ready connection can still fail: a TLS 1.3 server that requires a client
/// certificate lets the client finish its part of the handshake, then aborts
/// it with an alert. Network reports that to the state handler, but a send
/// still pending then, or issued just after, may never complete until the
/// connection is cancelled. So the failure is recorded and the connection
/// cancelled, which ends pending sends and reads; they, and every later one,
/// throw the recorded failure. A send or read can learn of a TLS failure
/// before the state handler does, so a TLS error there is recorded the same
/// way. A failure after `cancel()` is expected and not recorded.
///
/// The state handler holds this object weakly, so there is no reference cycle
/// through the connection. State is guarded by `lock`, hence
/// `@unchecked Sendable`.
final class WatchedConnection: @unchecked Sendable {
  let nwConnection: NWConnection
  private let lock = NSLock()
  private var recordedFailure: RTSPError?
  private var closing = false
  private var dataReceived = false

  init(_ connection: NWConnection) {
    nwConnection = connection
  }

  /// Why the connection failed after it became ready, if it did.
  var failure: RTSPError? {
    lock.lock()
    defer { lock.unlock() }
    return recordedFailure
  }

  /// Send `data`, resuming once Network has processed it.
  func send(_ data: Data) async throws {
    if let failure { throw failure }
    guard let error = await sendResult(data, on: nwConnection) else { return }
    throw await settledFailure(after: error)
      ?? RTSPError.connectionFailed(
        "Send failed: \(error.localizedDescription)", underlying: error)
  }

  /// `send(_:)` for a caller that orders its sends under its own lock:
  /// `gate` runs the closure that queues the send while holding that lock,
  /// or returns false without running it, and the send throws `refused`.
  func send(
    _ data: Data, gate: (_ enqueue: () -> Void) -> Bool, refused: RTSPError
  ) async throws {
    if let failure { throw failure }
    let connection = nwConnection
    let result: NWError?? = await withCheckedContinuation { continuation in
      let queued = gate {
        connection.send(
          content: data,
          completion: .contentProcessed { continuation.resume(returning: .some($0)) })
      }
      if !queued { continuation.resume(returning: nil) }
    }
    guard let result else { throw refused }
    guard let error = result else { return }
    throw await settledFailure(after: error)
      ?? RTSPError.connectionFailed(
        "Send failed: \(error.localizedDescription)", underlying: error)
  }

  /// Read the next chunk (at most 64 KiB). Returns `nil` once the peer has
  /// closed its side and no data is left.
  func receive() async throws -> Data? {
    if let failure { throw failure }
    switch await receiveResult(from: nwConnection) {
    case .success(let chunk?):
      noteDataReceived()
      return chunk
    case .success(nil):
      if let failure { throw failure }
      return nil
    case .failure(let error):
      throw await settledFailure(after: error)
        ?? RTSPError.connectionFailed(
          "Read error: \(error.localizedDescription)", underlying: error)
    }
  }

  /// The failure to report for `error` from a send or read, if the connection
  /// has failed. A TLS error means it has, though the state handler may not
  /// have been told yet, so it is recorded here.
  func failure(after error: NWError) -> RTSPError? {
    if case .tls = error {
      fail(error)
    } else if failure == nil, case .failed(let stateError) = nwConnection.state {
      fail(stateError)
    }
    return failure
  }

  /// `failure(after:)`, waiting up to 200 ms for Network to report the
  /// connection's failure when `error` is a socket error: a TLS alert can end
  /// a send with one (`ENOTCONN`) before the connection's own TLS error is
  /// known.
  private func settledFailure(after error: NWError) async -> RTSPError? {
    if let failure = failure(after: error) { return failure }
    guard case .posix = error else { return nil }
    for _ in 0..<20 {
      if isClosing { return nil }
      try? await Task.sleep(for: .milliseconds(10))
      if let failure = failure(after: error) { return failure }
    }
    return nil
  }

  private var isClosing: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closing
  }

  /// Record that data arrived from the server, for a reader that calls
  /// `nwConnection.receive` itself.
  func noteDataReceived() {
    lock.lock()
    dataReceived = true
    lock.unlock()
  }

  /// Close the connection. Idempotent.
  func cancel() {
    lock.lock()
    closing = true
    lock.unlock()
    nwConnection.cancel()
  }

  /// A state change after `.ready`, on the connection's queue.
  func handle(_ state: NWConnection.State) {
    guard case .failed(let error) = state else { return }
    fail(error)
  }

  /// Record `error` as the connection's failure unless one is recorded or the
  /// connection is being closed, and cancel the connection so pending sends
  /// and reads end.
  private func fail(_ error: NWError) {
    lock.lock()
    if !closing && recordedFailure == nil {
      recordedFailure = .connectionFailed(
        RTSPTransportConnection.describeAfterReady(error, dataReceived: dataReceived),
        underlying: error)
    }
    lock.unlock()
    nwConnection.cancel()
  }
}

/// Send `data` on `connection`, resuming once Network has processed it.
func sendData(_ data: Data, on connection: NWConnection) async throws {
  if let error = await sendResult(data, on: connection) {
    throw RTSPError.connectionFailed(
      "Send failed: \(error.localizedDescription)", underlying: error)
  }
}

/// Read the next chunk (at most 64 KiB) from `connection`. Returns `nil` once
/// the peer has closed its side and no data is left.
func receiveChunk(from connection: NWConnection) async throws -> Data? {
  switch await receiveResult(from: connection) {
  case .success(let chunk):
    return chunk
  case .failure(let error):
    throw RTSPError.connectionFailed(
      "Read error: \(error.localizedDescription)", underlying: error)
  }
}

/// Send `data` on `connection` and wait until Network has processed it.
/// Returns the error Network reported, if any.
private func sendResult(_ data: Data, on connection: NWConnection) async -> NWError? {
  await withCheckedContinuation { continuation in
    connection.send(
      content: data, completion: .contentProcessed { continuation.resume(returning: $0) })
  }
}

/// The next chunk (at most 64 KiB) from `connection`, `nil` once the peer has
/// closed its side and no data is left, or the error Network reported.
private func receiveResult(from connection: NWConnection) async -> Result<Data?, NWError> {
  await withCheckedContinuation { continuation in
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      content, _, _, error in
      if let error {
        continuation.resume(returning: .failure(error))
      } else if let content, !content.isEmpty {
        continuation.resume(returning: .success(content))
      } else {
        continuation.resume(returning: .success(nil))
      }
    }
  }
}
