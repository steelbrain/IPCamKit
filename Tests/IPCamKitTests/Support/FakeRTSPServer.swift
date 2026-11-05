// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Scriptable in-process fake RTSP/ONVIF camera server (plus a raw RTSP client) for tests

import Foundation
import Network

@testable import IPCamKit

// MARK: - Requests and responses

/// One RTSP request received by `FakeRTSPServer`, as parsed off the wire.
struct FakeRTSPRequest: Sendable {
  /// Server-assigned id of the TCP connection the request arrived on (from 1).
  let connectionID: Int
  /// Method token as sent, e.g. `PLAY`. Unknown methods are kept verbatim.
  let method: String
  /// Request-URI as sent.
  let url: String
  /// Protocol version from the request line, e.g. `RTSP/1.0`.
  let version: String
  /// Header fields in arrival order; names and values are trimmed.
  let headers: [(name: String, value: String)]
  /// Body bytes (`Content-Length` of them; empty when the header is absent).
  let body: Data

  /// First value of header `name` (case-insensitive), or `nil`.
  func header(_ name: String) -> String? {
    headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  /// Every value of header `name` (case-insensitive), in arrival order.
  func headers(named name: String) -> [String] {
    headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
  }

  /// Numeric `CSeq`, or `nil` when absent or not a number.
  var cseq: Int? { header("CSeq").flatMap { Int($0) } }

  /// Session id from the `Session` header, without parameters such as `timeout`.
  var sessionID: String? {
    header("Session")?.split(separator: ";").first.map {
      $0.trimmingCharacters(in: .whitespaces)
    }
  }

  /// Feature tags from every `Require` header (comma-separated lists flattened).
  var requireTags: [String] {
    headers(named: "Require").flatMap { $0.split(separator: ",") }
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// The `Transport` header.
  var transport: String? { header("Transport") }
  /// The `Range` header (e.g. `npt=0.000-` or `clock=20260101T000000Z-`).
  var range: String? { header("Range") }
  /// The `Scale` header.
  var scale: String? { header("Scale") }
  /// The `Speed` header.
  var speed: String? { header("Speed") }
  /// The ONVIF `Rate-Control` header.
  var rateControl: String? { header("Rate-Control") }
  /// The ONVIF `Frames` header.
  var frames: String? { header("Frames") }
  /// The ONVIF `Immediate` header.
  var immediate: String? { header("Immediate") }
  /// The body decoded as UTF-8.
  var bodyText: String { String(decoding: body, as: UTF8.self) }
}

/// An RTSP response the fake server writes, either built by its default
/// handlers or returned by a test's `onRequest` hook.
///
/// On the wire the server adds `CSeq` (echoing the request's) when the headers
/// lack one, and `Content-Length` when the body is non-empty and the headers
/// lack one. Nothing else is added to a hook's response.
struct FakeRTSPResponse: Sendable {
  var statusCode: Int
  var reason: String
  var headers: [(name: String, value: String)]
  var body: Data

  /// `reason` defaults to the standard phrase for `statusCode`.
  init(
    statusCode: Int = 200,
    reason: String? = nil,
    headers: [(name: String, value: String)] = [],
    body: Data = Data()
  ) {
    self.statusCode = statusCode
    self.reason = reason ?? Self.reasonPhrase(for: statusCode)
    self.headers = headers
    self.body = body
  }

  /// Convenience for a UTF-8 text body (e.g. SDP or `GET_PARAMETER` output).
  init(
    statusCode: Int = 200,
    reason: String? = nil,
    headers: [(name: String, value: String)] = [],
    body: String
  ) {
    self.init(statusCode: statusCode, reason: reason, headers: headers, body: Data(body.utf8))
  }

  /// First value of header `name` (case-insensitive), or `nil`.
  func header(_ name: String) -> String? {
    headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  /// Replace every header named `name` (case-insensitive) with one `value`,
  /// keeping the position of the first; append when absent.
  mutating func setHeader(_ name: String, _ value: String) {
    let matches = { (header: (name: String, value: String)) in
      header.name.caseInsensitiveCompare(name) == .orderedSame
    }
    if let index = headers.firstIndex(where: matches) {
      headers[index] = (name, value)
      var seen = false
      headers.removeAll { header in
        guard matches(header) else { return false }
        defer { seen = true }
        return seen
      }
    } else {
      headers.append((name, value))
    }
  }

  /// Remove every header named `name` (case-insensitive).
  mutating func removeHeader(_ name: String) {
    headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
  }

  /// Standard RTSP reason phrase (RFC 2326 section 7.1.1) for `statusCode`.
  static func reasonPhrase(for statusCode: Int) -> String {
    switch statusCode {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 451: return "Parameter Not Understood"
    case 453: return "Not Enough Bandwidth"
    case 454: return "Session Not Found"
    case 455: return "Method Not Valid in This State"
    case 457: return "Invalid Range"
    case 459: return "Aggregate operation not allowed"
    case 460: return "Only aggregate operation allowed"
    case 461: return "Unsupported transport"
    case 500: return "Internal Server Error"
    case 501: return "Not Implemented"
    case 503: return "Service Unavailable"
    case 551: return "Option not supported"
    default: return "Status \(statusCode)"
    }
  }

  /// Wire bytes for this response; `cseq` is the request's `CSeq` value.
  func serialized(echoingCSeq cseq: String?) -> Data {
    var lines = ["RTSP/1.0 \(statusCode) \(reason)"]
    if let cseq, header("CSeq") == nil {
      lines.append("CSeq: \(cseq)")
    }
    lines += headers.map { "\($0.name): \($0.value)" }
    if !body.isEmpty, header("Content-Length") == nil {
      lines.append("Content-Length: \(body.count)")
    }
    var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    data.append(body)
    return data
  }
}

/// A request paired with the response the server wrote for it.
struct FakeRTSPExchange: Sendable {
  let request: FakeRTSPRequest
  let response: FakeRTSPResponse
  /// True when the `onRequest` hook supplied the response.
  let overridden: Bool
}

/// One media packet a client sent to the fake server.
struct FakeRTSPReceivedMedia: Sendable {
  /// Where the packet arrived.
  enum Path: Sendable, Hashable {
    /// A `$`-interleaved frame on the RTSP TCP connection.
    case interleaved(channel: UInt8)
    /// A UDP datagram on one of the server's ports for a UDP SETUP.
    case udp(serverPort: UInt16)
  }

  let connectionID: Int
  let path: Path
  /// SDP media index the channel or port was set up for; `nil` when an
  /// interleaved frame arrived on a channel no SETUP assigned.
  let stream: Int?
  /// True for the RTCP channel or port of the stream's pair.
  let isRTCP: Bool
  let data: Data

  /// The interleaved channel, or `nil` for a UDP datagram.
  var channel: UInt8? {
    if case .interleaved(let channel) = path { return channel }
    return nil
  }
}

/// SSRC and `RTP-Info` seed the fake server advertises for one stream.
struct FakeRTPStreamParameters: Sendable, Equatable {
  /// Sent as `ssrc=` in SETUP `Transport` (always for UDP; for TCP only with
  /// `includeSSRCInInterleavedTransport`).
  var ssrc: UInt32
  /// Sent as `seq=` in PLAY `RTP-Info`.
  var initialSequence: UInt16
  /// Sent as `rtptime=` in PLAY `RTP-Info`.
  var initialRTPTime: UInt32

  /// Default for SDP media index `stream`: SSRC `0x5EED0000 + stream`, sequence
  /// `1000 * (stream + 1)`, RTP time `90000 * (stream + 1)`.
  static func defaults(forStream stream: Int) -> FakeRTPStreamParameters {
    FakeRTPStreamParameters(
      ssrc: 0x5EED_0000 &+ UInt32(truncatingIfNeeded: stream),
      initialSequence: UInt16(truncatingIfNeeded: 1000 * (stream + 1)),
      initialRTPTime: UInt32(truncatingIfNeeded: 90_000 * (stream + 1)))
  }
}

/// One stream a client set up on a connection.
struct FakeRTSPStreamSetup: Sendable, Equatable {
  /// How the stream's RTP/RTCP travel.
  enum Transport: Sendable, Equatable {
    case interleaved(rtpChannel: UInt8, rtcpChannel: UInt8)
    case udp(
      clientRTPPort: UInt16, clientRTCPPort: UInt16, serverRTPPort: UInt16,
      serverRTCPPort: UInt16)
  }

  /// SDP media index (0-based order of `m=` lines; the client's stream index).
  let stream: Int
  /// The media's `a=control:` value from the SDP (empty when it had none).
  let control: String
  let transport: Transport
  let parameters: FakeRTPStreamParameters
  /// The client's `Transport` request header, verbatim.
  let requestedTransport: String
}

// MARK: - Server

/// A scriptable fake RTSP camera that runs inside the test process.
///
/// It listens on the loopback address (`127.0.0.1`, or `::1` with
/// `AddressFamily.ipv6`) on an ephemeral TCP port and accepts any number of
/// concurrent connections. Each connection gets its own serial queue, its own
/// RTSP session (created by the first SETUP), and a `FakeRTSPSessionHandle`
/// for sending media back. Default handlers implement OPTIONS, DESCRIBE,
/// SETUP (interleaved TCP and UDP), PLAY, PAUSE, TEARDOWN, GET_PARAMETER, and
/// SET_PARAMETER, and any request carrying a `Require` header with a tag not
/// in `supportedFeatureTags` gets `551 Option not supported` with
/// `Unsupported`. Tests reshape behavior with three hooks:
///
/// - `onRequest` returns a full replacement response (or `nil` for the default);
///   a replacement skips the default handler and its state changes.
/// - `transformResponse` edits a default response before it is written.
/// - `onPlay` runs once a 2xx PLAY response (default or replaced) is written.
///
/// Hooks run on the connection's serial queue: keep them short, and start a
/// `Task` for long work such as streaming. Media sent from inside `onRequest`
/// goes out before that request's response; media sent from `onPlay` follows
/// the PLAY response.
///
/// Every request, every response, and every media packet the clients send is
/// recorded; the `waitFor…` methods suspend (never block) until enough matching
/// records exist or the timeout passes, and `stop()` releases them early.
///
/// `@unchecked Sendable`: mutable state is guarded by `lock`, and the records
/// by their logs' own locks.
final class FakeRTSPServer: @unchecked Sendable {
  /// Loopback address family to listen on.
  enum AddressFamily: Sendable {
    case ipv4
    case ipv6

    /// Bare loopback literal (`127.0.0.1` or `::1`).
    var loopback: String { self == .ipv6 ? "::1" : "127.0.0.1" }
    /// Loopback host as written in a URL (IPv6 bracketed).
    var urlHost: String { self == .ipv6 ? "[::1]" : "127.0.0.1" }
  }

  /// Server behavior. Read on every request, so changes apply to the next one.
  struct Configuration: Sendable {
    /// SDP body served by DESCRIBE. `a=control:` values should be relative;
    /// they resolve against `Content-Base: <url>/`. SETUP maps a control URL
    /// to an SDP media index using the SDP last served by a 2xx DESCRIBE on the
    /// same connection (including a hook's replacement body), else this one.
    var sdp: String
    /// When set, a DESCRIBE that does not `Require`
    /// `www.onvif.org/ver20/backchannel` is served this SDP instead of `sdp`,
    /// as ONVIF devices list the backchannel media only when asked for it.
    var sdpWithoutBackchannel: String?
    /// URL path (no leading slash).
    var path = "stream"
    var family = AddressFamily.ipv4
    /// `Require` tags the server accepts (compared case-insensitively).
    var supportedFeatureTags: Set<String> = [
      "onvif-replay", "www.onvif.org/ver20/backchannel",
    ]
    /// Seconds, advertised as `Session: <id>;timeout=<n>`. Not enforced.
    var sessionTimeout = 60
    /// Whether OPTIONS lists `GET_PARAMETER` in `Public`.
    var advertiseGetParameter = true
    /// Whether PLAY responses carry `RTP-Info` for the set-up streams.
    var includeRTPInfo = true
    /// Whether interleaved SETUP responses carry `ssrc=` (UDP ones always do).
    var includeSSRCInInterleavedTransport = false
    /// Per-stream SSRC / `RTP-Info` overrides keyed by SDP media index.
    var streamParameters: [Int: FakeRTPStreamParameters] = [:]
    /// Fixed session id for every connection; `nil` picks a random one each.
    var sessionID: String?

    /// Parameters for SDP media index `stream`: the override or the default.
    func parameters(forStream stream: Int) -> FakeRTPStreamParameters {
      streamParameters[stream] ?? .defaults(forStream: stream)
    }
  }

  /// Why `start()` failed.
  enum ServerError: Error, CustomStringConvertible {
    case alreadyStarted
    case stopped
    case listenerFailed(String)
    case startTimedOut

    var description: String {
      switch self {
      case .alreadyStarted: return "FakeRTSPServer.start() called twice"
      case .stopped: return "FakeRTSPServer was stopped"
      case .listenerFailed(let reason): return "FakeRTSPServer listener failed: \(reason)"
      case .startTimedOut: return "FakeRTSPServer listener did not become ready in time"
      }
    }
  }

  /// Hook and configuration snapshot taken once per request.
  fileprivate struct Hooks {
    let configuration: Configuration
    let onRequest: (@Sendable (FakeRTSPRequest) -> FakeRTSPResponse?)?
    let transformResponse: (@Sendable (FakeRTSPRequest, FakeRTSPResponse) -> FakeRTSPResponse)?
  }

  private let lock = NSLock()
  private var config: Configuration
  private var requestHook: (@Sendable (FakeRTSPRequest) -> FakeRTSPResponse?)?
  private var responseHook: (@Sendable (FakeRTSPRequest, FakeRTSPResponse) -> FakeRTSPResponse)?
  private var playHook: (@Sendable (FakeRTSPRequest, FakeRTSPSessionHandle) -> Void)?
  private var listener: NWListener?
  private var handles: [Int: FakeRTSPSessionHandle] = [:]
  private var nextConnectionID = 1
  private var boundPort: UInt16 = 0
  private var hasStarted = false
  private var isStopped = false

  private let requestLog = FakeEventLog<FakeRTSPRequest>()
  private let exchangeLog = FakeEventLog<FakeRTSPExchange>()
  private let mediaLog = FakeEventLog<FakeRTSPReceivedMedia>()
  private let listenerQueue = DispatchQueue(label: "ipcamkit.tests.fake-rtsp.listener")

  init(configuration: Configuration) {
    self.config = configuration
  }

  /// A server with the default configuration serving `sdp`.
  convenience init(sdp: String) {
    self.init(configuration: Configuration(sdp: sdp))
  }

  deinit {
    listener?.cancel()
    for handle in handles.values { handle.close() }
    requestLog.finish()
    exchangeLog.finish()
    mediaLog.finish()
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  // MARK: Configuration and hooks

  var configuration: Configuration {
    get { withLock { config } }
    set { withLock { config = newValue } }
  }

  /// Return non-nil to replace the default response (e.g. 401, 454, 551, or
  /// custom headers). The default handler, and its state changes, are skipped.
  var onRequest: (@Sendable (FakeRTSPRequest) -> FakeRTSPResponse?)? {
    get { withLock { requestHook } }
    set { withLock { requestHook = newValue } }
  }

  /// Edit a default response before it is written (not applied to `onRequest`
  /// replacements), e.g. to add a `Range` or a custom `RTP-Info`.
  var transformResponse: (@Sendable (FakeRTSPRequest, FakeRTSPResponse) -> FakeRTSPResponse)? {
    get { withLock { responseHook } }
    set { withLock { responseHook = newValue } }
  }

  /// Runs after each 2xx PLAY response has been written to its connection, with
  /// the PLAY request (CSeq, Range, Scale, Rate-Control, Frames, Immediate…)
  /// and the connection's handle for streaming media.
  var onPlay: (@Sendable (FakeRTSPRequest, FakeRTSPSessionHandle) -> Void)? {
    get { withLock { playHook } }
    set { withLock { playHook = newValue } }
  }

  fileprivate func hooks() -> Hooks {
    withLock {
      Hooks(configuration: config, onRequest: requestHook, transformResponse: responseHook)
    }
  }

  fileprivate var playHandler: (@Sendable (FakeRTSPRequest, FakeRTSPSessionHandle) -> Void)? {
    withLock { playHook }
  }

  // MARK: Addresses

  /// Bound TCP port; 0 before `start()` completes.
  var port: UInt16 { withLock { boundPort } }

  /// `rtsp://<loopback>:<port>/<path>`; empty before `start()` completes.
  var url: String {
    let (port, family, path) = withLock { (boundPort, config.family, config.path) }
    return port == 0 ? "" : "rtsp://\(family.urlHost):\(port)/\(path)"
  }

  /// The `Content-Base` DESCRIBE advertises: `url` plus a trailing slash.
  var contentBase: String { url + "/" }

  /// Absolute URL for an SDP `a=control:` value, as a client resolves it.
  func controlURL(_ control: String) -> String {
    control.contains("://") ? control : contentBase + control
  }

  // MARK: Lifecycle

  /// Bind the loopback listener and wait (at most 5 s) until it is ready.
  func start() async throws {
    let listener = try withLock { () throws -> NWListener in
      guard !isStopped else { throw ServerError.stopped }
      guard !hasStarted else { throw ServerError.alreadyStarted }
      hasStarted = true
      let params = NWParameters.tcp
      params.allowLocalEndpointReuse = true
      params.requiredLocalEndpoint = .hostPort(
        host: NWEndpoint.Host(config.family.loopback), port: .any)
      let listener = try NWListener(using: params)
      self.listener = listener
      return listener
    }
    let queue = listenerQueue
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      let once = FakeOnce()
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          let port = listener.port?.rawValue ?? 0
          once.run {
            if port == 0 {
              continuation.resume(throwing: ServerError.listenerFailed("no port bound"))
            } else {
              continuation.resume(returning: port)
            }
          }
        case .failed(let error):
          listener.cancel()
          once.run { continuation.resume(throwing: ServerError.listenerFailed("\(error)")) }
        case .cancelled:
          // Break the listener -> handler -> listener reference cycle.
          listener.stateUpdateHandler = nil
          listener.newConnectionHandler = nil
          once.run { continuation.resume(throwing: ServerError.stopped) }
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        guard let self else {
          connection.cancel()
          return
        }
        self.accept(connection)
      }
      listener.start(queue: queue)
      queue.asyncAfter(deadline: .now() + 5) {
        once.run {
          listener.cancel()
          continuation.resume(throwing: ServerError.startTimedOut)
        }
      }
    }
    withLock { boundPort = port }
  }

  /// Close the listener and every connection (abruptly), release all UDP
  /// sockets, and resume every outstanding `waitFor…` call with what has been
  /// recorded so far. Idempotent; records stay readable afterwards.
  func stop() {
    let (listener, open) = withLock { () -> (NWListener?, [FakeRTSPSessionHandle]) in
      isStopped = true
      let listener = self.listener
      self.listener = nil
      let open = Array(handles.values)
      handles.removeAll()
      return (listener, open)
    }
    listener?.cancel()
    for handle in open { handle.close() }
    requestLog.finish()
    exchangeLog.finish()
    mediaLog.finish()
  }

  private func accept(_ connection: NWConnection) {
    let handle = withLock { () -> FakeRTSPSessionHandle? in
      guard !isStopped else { return nil }
      let id = nextConnectionID
      nextConnectionID += 1
      let handle = FakeRTSPSessionHandle(
        connectionID: id, connection: connection, server: self, family: config.family)
      handles[id] = handle
      return handle
    }
    guard let handle else {
      connection.cancel()
      return
    }
    handle.start()
  }

  fileprivate func connectionDidClose(_ id: Int) {
    withLock { _ = handles.removeValue(forKey: id) }
  }

  // MARK: Connections

  /// Handles for the connections that are still open, by connection id.
  var sessionHandles: [FakeRTSPSessionHandle] {
    withLock { handles.values.sorted { $0.connectionID < $1.connectionID } }
  }

  /// The open connection with `connectionID`, if any.
  func sessionHandle(connectionID: Int) -> FakeRTSPSessionHandle? {
    withLock { handles[connectionID] }
  }

  /// Abruptly close every open client connection (the listener stays up).
  func closeAllConnections() {
    for handle in sessionHandles { handle.close() }
  }

  // MARK: Records

  fileprivate func record(request: FakeRTSPRequest, response: FakeRTSPResponse, overridden: Bool) {
    requestLog.append(request)
    exchangeLog.append(
      FakeRTSPExchange(request: request, response: response, overridden: overridden))
  }

  fileprivate func record(media: FakeRTSPReceivedMedia) {
    mediaLog.append(media)
  }

  /// Every request received so far, in arrival order (across connections).
  var requests: [FakeRTSPRequest] { requestLog.snapshot }

  /// Requests whose method matches `method` (case-insensitive).
  func requests(method: String) -> [FakeRTSPRequest] {
    requests.filter { $0.method.caseInsensitiveCompare(method) == .orderedSame }
  }

  /// Every request with the response written for it, in order.
  var exchanges: [FakeRTSPExchange] { exchangeLog.snapshot }

  /// Every media packet clients sent (interleaved frames and UDP datagrams).
  /// Empty UDP datagrams (a client's NAT hole-punch) are not recorded.
  var receivedMedia: [FakeRTSPReceivedMedia] { mediaLog.snapshot }

  /// Wait until at least `count` recorded requests satisfy `predicate`, then
  /// return all that do. On timeout, cancellation, or `stop()`, returns the
  /// matches so far (possibly fewer than `count`). A request is recorded after
  /// its response is computed and before the response is written.
  func waitForRequests(
    where predicate: @escaping @Sendable (FakeRTSPRequest) -> Bool = { _ in true },
    count: Int = 1,
    timeout: Duration = .seconds(5)
  ) async -> [FakeRTSPRequest] {
    await requestLog.wait(where: predicate, count: count, timeout: timeout)
  }

  /// The first request with `method` (case-insensitive), waiting up to
  /// `timeout`; `nil` if none arrived.
  func waitForRequest(
    method: String, timeout: Duration = .seconds(5)
  ) async -> FakeRTSPRequest? {
    await waitForRequests(
      where: { $0.method.caseInsensitiveCompare(method) == .orderedSame },
      count: 1, timeout: timeout
    ).first
  }

  /// Wait until at least `count` received media packets satisfy `predicate`,
  /// then return all that do (same timeout semantics as `waitForRequests`).
  func waitForReceivedMedia(
    where predicate: @escaping @Sendable (FakeRTSPReceivedMedia) -> Bool = { _ in true },
    count: Int = 1,
    timeout: Duration = .seconds(5)
  ) async -> [FakeRTSPReceivedMedia] {
    await mediaLog.wait(where: predicate, count: count, timeout: timeout)
  }
}

// MARK: - Per-connection session handle

/// One client TCP connection to `FakeRTSPServer` and the RTSP session on it.
///
/// Media is written through a single serial queue per connection, so RTP/RTCP
/// sent here keeps its order relative to the RTSP responses on the same TCP
/// connection. Send methods may be called from any thread or task.
///
/// `@unchecked Sendable`: `readBuffer` is confined to `queue`; session state is
/// guarded by `lock`.
final class FakeRTSPSessionHandle: @unchecked Sendable {
  /// Server-assigned connection id (from 1), matching
  /// `FakeRTSPRequest.connectionID`.
  let connectionID: Int

  private let connection: NWConnection
  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<Bool>()
  private weak var server: FakeRTSPServer?
  private let family: FakeRTSPServer.AddressFamily

  // Confined to `queue`.
  private var readBuffer = Data()

  // Guarded by `lock`.
  private let lock = NSLock()
  private var session: String?
  private var streamSetups: [Int: FakeRTSPStreamSetup] = [:]
  private var udpPairs: [Int: FakeUDPPair] = [:]
  private var closed = false
  /// Body of the last 2xx DESCRIBE answered on this connection; SETUP maps
  /// control URLs to SDP media indices against it (else `Configuration.sdp`).
  private var servedSDP: String?

  fileprivate init(
    connectionID: Int, connection: NWConnection, server: FakeRTSPServer,
    family: FakeRTSPServer.AddressFamily
  ) {
    self.connectionID = connectionID
    self.connection = connection
    self.server = server
    self.family = family
    self.queue = DispatchQueue(label: "ipcamkit.tests.fake-rtsp.connection.\(connectionID)")
    queue.setSpecific(key: queueKey, value: true)
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  // MARK: Inspection

  /// The RTSP session id, set by the first successful SETUP and cleared by
  /// TEARDOWN.
  var sessionID: String? { withLock { session } }

  /// Streams currently set up on this connection, by SDP media index.
  var setups: [FakeRTSPStreamSetup] {
    withLock { streamSetups.values.sorted { $0.stream < $1.stream } }
  }

  /// The current setup of SDP media index `stream`, if any.
  func setup(forStream stream: Int) -> FakeRTSPStreamSetup? {
    withLock { streamSetups[stream] }
  }

  /// True once the connection closed (by the peer, `close()`, or `stop()`).
  var isClosed: Bool { withLock { closed } }

  // MARK: Sending

  /// Send one RTP packet for SDP media index `stream`: an interleaved frame on
  /// its RTP channel, or a UDP datagram from the server RTP port to the client
  /// RTP port. Returns `false` if the stream is not set up or the connection is
  /// closed.
  @discardableResult
  func sendRTP(_ packet: Data, stream: Int) -> Bool {
    sendMedia(packet, stream: stream, rtcp: false)
  }

  /// Like `sendRTP`, on the stream's RTCP channel or port.
  @discardableResult
  func sendRTCP(_ packet: Data, stream: Int) -> Bool {
    sendMedia(packet, stream: stream, rtcp: true)
  }

  /// Write one `$`-interleaved frame on any channel. Returns `false` when the
  /// payload exceeds 65535 bytes or the connection is closed.
  @discardableResult
  func sendInterleaved(_ payload: Data, channel: UInt8) -> Bool {
    guard payload.count <= 0xFFFF, !isClosed else { return false }
    var frame = Data([0x24, channel, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
    frame.append(payload)
    sendRaw(frame)
    return true
  }

  /// Write arbitrary bytes on the TCP connection (e.g. a malformed or
  /// unsolicited message), in order with everything else written on it.
  func sendRaw(_ bytes: Data) {
    let connection = self.connection
    perform {
      connection.send(content: bytes, completion: .contentProcessed { _ in })
    }
  }

  /// Abruptly close the connection (pending writes are dropped) and release its
  /// UDP sockets. Idempotent.
  func close() {
    shutDown(abrupt: true)
  }

  private func sendMedia(_ packet: Data, stream: Int, rtcp: Bool) -> Bool {
    let target = withLock { () -> (FakeRTSPStreamSetup, FakeUDPPair?)? in
      guard !closed, let setup = streamSetups[stream] else { return nil }
      return (setup, udpPairs[stream])
    }
    guard let target else { return false }
    let (setup, pair) = target
    switch setup.transport {
    case .interleaved(let rtpChannel, let rtcpChannel):
      return sendInterleaved(packet, channel: rtcp ? rtcpChannel : rtpChannel)
    case .udp(let clientRTPPort, let clientRTCPPort, _, _):
      guard let pair else { return false }
      let socket = rtcp ? pair.rtcp : pair.rtp
      let port = rtcp ? clientRTCPPort : clientRTPPort
      perform { _ = socket.send(packet, toPort: port) }
      return true
    }
  }

  /// Run `body` on the connection queue: inline when already on it (so a send
  /// from a hook keeps its place relative to the response being handled),
  /// otherwise asynchronously. Either way, FIFO with every other write.
  private func perform(_ body: @escaping @Sendable () -> Void) {
    if DispatchQueue.getSpecific(key: queueKey) == true {
      body()
    } else {
      queue.async(execute: body)
    }
  }

  // MARK: Connection lifecycle

  fileprivate func start() {
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled:
        self?.shutDown(abrupt: false)
      default:
        break
      }
    }
    connection.start(queue: queue)
    receiveNext()
  }

  private func receiveNext() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty {
        self.ingest(data)
      }
      if isComplete || error != nil {
        self.shutDown(abrupt: false)
        return
      }
      if !self.isClosed {
        self.receiveNext()
      }
    }
  }

  private func shutDown(abrupt: Bool) {
    let pairs = withLock { () -> [FakeUDPPair]? in
      guard !closed else { return nil }
      closed = true
      let pairs = Array(udpPairs.values)
      udpPairs.removeAll()
      return pairs
    }
    guard let pairs else { return }
    if abrupt {
      connection.forceCancel()
    } else {
      connection.cancel()
    }
    for pair in pairs { pair.close() }
    server?.connectionDidClose(connectionID)
  }

  // MARK: Inbound bytes

  private func ingest(_ data: Data) {
    readBuffer.append(data)
    while !isClosed, let item = FakeWireParser.next(from: &readBuffer) {
      switch item {
      case .request(let method, let url, let version, let headers, let body):
        process(
          FakeRTSPRequest(
            connectionID: connectionID, method: method, url: url, version: version,
            headers: headers, body: body))
      case .interleaved(let channel, let payload):
        recordInterleaved(channel: channel, payload: payload)
      case .malformed(let cseq):
        let response = FakeRTSPResponse(statusCode: 400)
        connection.send(
          content: response.serialized(echoingCSeq: cseq), completion: .contentProcessed { _ in })
      }
    }
  }

  private func recordInterleaved(channel: UInt8, payload: Data) {
    let match = withLock { () -> (stream: Int, isRTCP: Bool)? in
      for setup in streamSetups.values {
        if case .interleaved(let rtpChannel, let rtcpChannel) = setup.transport {
          if channel == rtpChannel { return (setup.stream, false) }
          if channel == rtcpChannel { return (setup.stream, true) }
        }
      }
      return nil
    }
    server?.record(
      media: FakeRTSPReceivedMedia(
        connectionID: connectionID, path: .interleaved(channel: channel), stream: match?.stream,
        isRTCP: match?.isRTCP ?? false, data: payload))
  }

  private func process(_ request: FakeRTSPRequest) {
    guard let server else { return }
    let hooks = server.hooks()
    let response: FakeRTSPResponse
    let overridden: Bool
    if let replacement = hooks.onRequest?(request) {
      response = replacement
      overridden = true
    } else {
      let standard = defaultResponse(for: request, configuration: hooks.configuration)
      response = hooks.transformResponse?(request, standard) ?? standard
      overridden = false
    }
    server.record(request: request, response: response, overridden: overridden)
    if request.method.caseInsensitiveCompare("DESCRIBE") == .orderedSame,
      (200..<300).contains(response.statusCode), !response.body.isEmpty
    {
      let sdp = String(decoding: response.body, as: UTF8.self)
      withLock { servedSDP = sdp }
    }
    // A hook may have closed the connection to simulate a camera hanging up.
    guard !isClosed else { return }

    let firesPlay =
      request.method.caseInsensitiveCompare("PLAY") == .orderedSame
      && (200..<300).contains(response.statusCode)
    connection.send(
      content: response.serialized(echoingCSeq: request.header("CSeq")),
      completion: .contentProcessed { [weak self, weak server] error in
        guard firesPlay, error == nil, let self, let onPlay = server?.playHandler else { return }
        onPlay(request, self)
      })
  }

  // MARK: Default handlers

  private func defaultResponse(
    for request: FakeRTSPRequest, configuration config: FakeRTSPServer.Configuration
  ) -> FakeRTSPResponse {
    let unsupported = request.requireTags.filter { tag in
      !config.supportedFeatureTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
    if !unsupported.isEmpty {
      return FakeRTSPResponse(
        statusCode: 551, headers: [("Unsupported", unsupported.joined(separator: ", "))])
    }
    if let requested = request.sessionID, requested != sessionID {
      return FakeRTSPResponse(statusCode: 454)
    }

    var response: FakeRTSPResponse
    switch request.method.uppercased() {
    case "OPTIONS":
      var methods = ["OPTIONS", "DESCRIBE", "SETUP", "PLAY", "PAUSE", "TEARDOWN", "SET_PARAMETER"]
      if config.advertiseGetParameter { methods.append("GET_PARAMETER") }
      response = FakeRTSPResponse(headers: [("Public", methods.joined(separator: ", "))])
    case "DESCRIBE":
      let wantsBackchannel = request.requireTags.contains {
        $0.caseInsensitiveCompare("www.onvif.org/ver20/backchannel") == .orderedSame
      }
      response = FakeRTSPResponse(
        headers: [
          ("Content-Type", "application/sdp"),
          ("Content-Base", server?.contentBase ?? ""),
        ],
        body: (wantsBackchannel ? nil : config.sdpWithoutBackchannel) ?? config.sdp)
    case "SETUP":
      response = setupResponse(for: request, configuration: config)
    case "PLAY":
      guard sessionID != nil else { return FakeRTSPResponse(statusCode: 455) }
      response = playResponse(for: request, configuration: config)
    case "PAUSE":
      guard sessionID != nil else { return FakeRTSPResponse(statusCode: 455) }
      response = FakeRTSPResponse()
    case "TEARDOWN":
      tearDownSession()
      response = FakeRTSPResponse()
    case "GET_PARAMETER", "SET_PARAMETER":
      response = FakeRTSPResponse()
    default:
      return FakeRTSPResponse(statusCode: 501)
    }
    if (200..<300).contains(response.statusCode), let id = sessionID {
      response.headers.insert(("Session", "\(id);timeout=\(config.sessionTimeout)"), at: 0)
    }
    return response
  }

  private func setupResponse(
    for request: FakeRTSPRequest, configuration config: FakeRTSPServer.Configuration
  ) -> FakeRTSPResponse {
    let sdp = withLock { servedSDP } ?? config.sdp
    guard let media = FakeSDPMedia.stream(forURL: request.url, in: FakeSDPMedia.parse(sdp)) else {
      return FakeRTSPResponse(statusCode: 404)
    }
    guard let transportHeader = request.transport,
      let requested = FakeTransportRequest.parse(transportHeader)
    else {
      return FakeRTSPResponse(statusCode: 461)
    }
    let parameters = config.parameters(forStream: media.index)
    let ssrc = String(format: "%08X", parameters.ssrc)

    switch requested {
    case .interleaved(let channels):
      let (rtpChannel, rtcpChannel) = channels ?? nextFreeChannels()
      install(
        FakeRTSPStreamSetup(
          stream: media.index, control: media.control ?? "",
          transport: .interleaved(rtpChannel: rtpChannel, rtcpChannel: rtcpChannel),
          parameters: parameters, requestedTransport: transportHeader),
        pair: nil, configuration: config)
      var echoed = "RTP/AVP/TCP;unicast;interleaved=\(rtpChannel)-\(rtcpChannel)"
      if config.includeSSRCInInterleavedTransport { echoed += ";ssrc=\(ssrc)" }
      return FakeRTSPResponse(headers: [("Transport", echoed)])

    case .udp(let clientRTPPort, let clientRTCPPort):
      let stream = media.index
      let connectionID = self.connectionID
      let pair = FakeUDPPair.open(family: family, queue: queue) {
        [weak server] data, isRTCP, serverPort in
        server?.record(
          media: FakeRTSPReceivedMedia(
            connectionID: connectionID, path: .udp(serverPort: serverPort), stream: stream,
            isRTCP: isRTCP, data: data))
      }
      guard let pair else {
        return FakeRTSPResponse(statusCode: 500, reason: "Could not bind UDP ports")
      }
      install(
        FakeRTSPStreamSetup(
          stream: stream, control: media.control ?? "",
          transport: .udp(
            clientRTPPort: clientRTPPort, clientRTCPPort: clientRTCPPort,
            serverRTPPort: pair.rtp.port, serverRTCPPort: pair.rtcp.port),
          parameters: parameters, requestedTransport: transportHeader),
        pair: pair, configuration: config)
      let echoed =
        "RTP/AVP;unicast;client_port=\(clientRTPPort)-\(clientRTCPPort);"
        + "server_port=\(pair.rtp.port)-\(pair.rtcp.port);ssrc=\(ssrc)"
      return FakeRTSPResponse(headers: [("Transport", echoed)])
    }
  }

  private func playResponse(
    for request: FakeRTSPRequest, configuration config: FakeRTSPServer.Configuration
  ) -> FakeRTSPResponse {
    var response = FakeRTSPResponse()
    if let range = request.range { response.headers.append(("Range", range)) }
    if let scale = request.scale { response.headers.append(("Scale", scale)) }
    if config.includeRTPInfo, let server {
      let entries = setups.map { setup in
        "url=\(server.controlURL(setup.control));seq=\(setup.parameters.initialSequence);"
          + "rtptime=\(setup.parameters.initialRTPTime)"
      }
      if !entries.isEmpty {
        response.headers.append(("RTP-Info", entries.joined(separator: ",")))
      }
    }
    return response
  }

  /// Record a SETUP, creating the session on the first one. A re-SETUP of the
  /// same stream replaces it (and releases its old UDP pair).
  private func install(
    _ setup: FakeRTSPStreamSetup, pair: FakeUDPPair?,
    configuration config: FakeRTSPServer.Configuration
  ) {
    let replaced = withLock { () -> FakeUDPPair? in
      // Closed while this SETUP was handled: shutDown already took the pairs,
      // so this one is released here rather than left open.
      guard !closed else { return pair }
      if session == nil {
        session = config.sessionID ?? String(format: "%08X", UInt32.random(in: 1...UInt32.max))
      }
      streamSetups[setup.stream] = setup
      let old = udpPairs[setup.stream]
      udpPairs[setup.stream] = pair
      return old
    }
    replaced?.close()
  }

  /// The lowest even channel pair no current setup uses.
  private func nextFreeChannels() -> (UInt8, UInt8) {
    let used = Set(
      setups.flatMap { setup -> [UInt8] in
        if case .interleaved(let rtp, let rtcp) = setup.transport { return [rtp, rtcp] }
        return []
      })
    var channel: UInt8 = 0
    while used.contains(channel) || used.contains(channel + 1), channel < 254 {
      channel += 2
    }
    return (channel, channel + 1)
  }

  /// TEARDOWN always ends the whole session (per-stream teardown is not
  /// modeled): setups are forgotten and UDP sockets released.
  private func tearDownSession() {
    let pairs = withLock { () -> [FakeUDPPair] in
      session = nil
      streamSetups.removeAll()
      let pairs = Array(udpPairs.values)
      udpPairs.removeAll()
      return pairs
    }
    for pair in pairs { pair.close() }
  }
}

// MARK: - Event log with async waiters

/// Thread-safe append-only log whose waiters suspend until enough matching
/// items exist, a timeout passes, their task is cancelled, or `finish()` runs.
private final class FakeEventLog<Item: Sendable>: @unchecked Sendable {
  private struct Waiter {
    let predicate: @Sendable (Item) -> Bool
    let count: Int
    let continuation: CheckedContinuation<[Item], Never>
  }

  private let lock = NSLock()
  private var items: [Item] = []
  private var waiters: [Int: Waiter] = [:]
  /// Waiters cancelled before they registered; they return immediately.
  private var cancelledBeforeRegistration: Set<Int> = []
  private var nextWaiterID = 0
  private var finished = false

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  var snapshot: [Item] { withLock { items } }

  func append(_ item: Item) {
    let ready = withLock { () -> [(CheckedContinuation<[Item], Never>, [Item])] in
      items.append(item)
      var ready: [(CheckedContinuation<[Item], Never>, [Item])] = []
      for (id, waiter) in waiters where waiter.predicate(item) {
        let matches = items.filter(waiter.predicate)
        if matches.count >= waiter.count {
          waiters[id] = nil
          ready.append((waiter.continuation, matches))
        }
      }
      return ready
    }
    for (continuation, matches) in ready { continuation.resume(returning: matches) }
  }

  func wait(
    where predicate: @escaping @Sendable (Item) -> Bool, count: Int, timeout: Duration
  ) async -> [Item] {
    let id = withLock { () -> Int in
      nextWaiterID += 1
      return nextWaiterID
    }
    let seconds = timeout.fakeSeconds
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<[Item], Never>) in
        let immediate = withLock { () -> [Item]? in
          let matches = items.filter(predicate)
          if matches.count >= count || finished
            || cancelledBeforeRegistration.remove(id) != nil
          {
            return matches
          }
          waiters[id] = Waiter(predicate: predicate, count: count, continuation: continuation)
          return nil
        }
        if let immediate {
          continuation.resume(returning: immediate)
          return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
          self?.release(id, cancelled: false)
        }
      }
    } onCancel: {
      self.release(id, cancelled: true)
    }
  }

  /// Resume every waiter with its matches so far; later waits return at once.
  func finish() {
    let pending = withLock { () -> [(CheckedContinuation<[Item], Never>, [Item])] in
      finished = true
      let pending = waiters.values.map { ($0.continuation, items.filter($0.predicate)) }
      waiters.removeAll()
      return pending
    }
    for (continuation, matches) in pending { continuation.resume(returning: matches) }
  }

  private func release(_ id: Int, cancelled: Bool) {
    let resumed = withLock { () -> (CheckedContinuation<[Item], Never>, [Item])? in
      guard let waiter = waiters.removeValue(forKey: id) else {
        if cancelled { cancelledBeforeRegistration.insert(id) }
        return nil
      }
      return (waiter.continuation, items.filter(waiter.predicate))
    }
    if let resumed { resumed.0.resume(returning: resumed.1) }
  }
}

/// Runs its body at most once across threads.
private final class FakeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false

  func run(_ body: () -> Void) {
    lock.lock()
    let first = !done
    done = true
    lock.unlock()
    if first { body() }
  }
}

// MARK: - Wire parsing

/// One item framed from a client's byte stream.
private enum FakeWireItem {
  case request(
    method: String, url: String, version: String, headers: [(name: String, value: String)],
    body: Data)
  case interleaved(channel: UInt8, payload: Data)
  /// An unparseable message; the server answers 400 (echoing `cseq` if found).
  case malformed(cseq: String?)
}

/// Frames RTSP requests and `$`-interleaved frames from a TCP byte stream that
/// may be split anywhere.
private enum FakeWireParser {
  /// A header block larger than this without a terminator is discarded.
  static let maxHeaderBytes = 64 * 1024
  /// Largest accepted `Content-Length`.
  static let maxBodyBytes = 4 * 1024 * 1024

  /// Remove and return the next complete item from `buffer`, or `nil` when more
  /// bytes are needed.
  static func next(from buffer: inout Data) -> FakeWireItem? {
    // Skip stray line breaks between messages.
    let skip = buffer.prefix { $0 == 0x0D || $0 == 0x0A }.count
    if skip > 0 { buffer.removeFirst(skip) }
    guard let first = buffer.first else { return nil }
    let start = buffer.startIndex

    if first == 0x24 {
      guard buffer.count >= 4 else { return nil }
      let length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
      guard buffer.count >= 4 + length else { return nil }
      let channel = buffer[start + 1]
      let payload = Data(buffer[(start + 4)..<(start + 4 + length)])
      buffer.removeFirst(4 + length)
      return .interleaved(channel: channel, payload: payload)
    }

    guard let terminator = headerTerminator(in: buffer) else {
      if buffer.count > maxHeaderBytes {
        buffer.removeAll()
        return .malformed(cseq: nil)
      }
      return nil
    }
    let headerBytes = terminator.upperBound - start
    let text = String(decoding: buffer[start..<terminator.lowerBound], as: UTF8.self)
    // "\r\n" is one Character in Swift, so match it explicitly alongside "\n".
    let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

    var headers: [(name: String, value: String)] = []
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers.append(
        (
          String(line[..<colon]).trimmingCharacters(in: .whitespaces),
          String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        ))
    }
    let cseq = headers.first { $0.name.lowercased() == "cseq" }?.value

    let parts = (lines.first ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard parts.count == 3 else {
      buffer.removeFirst(headerBytes)
      return .malformed(cseq: cseq)
    }

    var bodyLength = 0
    if let raw = headers.first(where: { $0.name.lowercased() == "content-length" })?.value {
      guard let length = Int(raw), length >= 0, length <= maxBodyBytes else {
        buffer.removeFirst(headerBytes)
        return .malformed(cseq: cseq)
      }
      bodyLength = length
    }
    guard buffer.count - headerBytes >= bodyLength else { return nil }
    let body = Data(buffer[(start + headerBytes)..<(start + headerBytes + bodyLength)])
    buffer.removeFirst(headerBytes + bodyLength)
    return .request(
      method: String(parts[0]), url: String(parts[1]), version: String(parts[2]),
      headers: headers, body: body)
  }

  /// Range of the blank line ending the header block (`\r\n\r\n` or `\n\n`).
  private static func headerTerminator(in buffer: Data) -> Range<Int>? {
    let crlf = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))
    let lf = buffer.range(of: Data([0x0A, 0x0A]))
    switch (crlf, lf) {
    case (let crlf?, let lf?): return crlf.lowerBound <= lf.lowerBound ? crlf : lf
    case (let crlf?, nil): return crlf
    case (nil, let lf?): return lf
    case (nil, nil): return nil
    }
  }
}

// MARK: - SDP and Transport parsing

/// One `m=` section of the served SDP.
private struct FakeSDPMedia {
  let index: Int
  let media: String
  let control: String?

  static func parse(_ sdp: String) -> [FakeSDPMedia] {
    var result: [FakeSDPMedia] = []
    var current: (media: String, control: String?)?
    func flush() {
      if let current {
        result.append(
          FakeSDPMedia(index: result.count, media: current.media, control: current.control))
      }
    }
    for raw in sdp.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("m=") {
        flush()
        current = (String(line.dropFirst(2).split(separator: " ").first ?? ""), nil)
      } else if line.hasPrefix("a=control:"), current != nil {
        current?.control = String(line.dropFirst("a=control:".count))
      }
    }
    flush()
    return result
  }

  /// The media whose control matches a SETUP URL: equal to it (absolute
  /// control) or its last path component(s); the longest match wins. A
  /// single-media SDP matches any URL.
  static func stream(forURL url: String, in media: [FakeSDPMedia]) -> FakeSDPMedia? {
    let target = url.hasSuffix("/") ? String(url.dropLast()) : url
    let best = media.filter { entry in
      guard let control = entry.control, !control.isEmpty, control != "*" else { return false }
      return target == control || target.hasSuffix("/" + control)
    }.max { ($0.control?.count ?? 0) < ($1.control?.count ?? 0) }
    return best ?? (media.count == 1 ? media.first : nil)
  }
}

/// The first servable alternative in a client's `Transport` header.
private enum FakeTransportRequest {
  /// `RTP/AVP/TCP`; `nil` channels when `interleaved=` was omitted.
  case interleaved(channels: (rtp: UInt8, rtcp: UInt8)?)
  /// `RTP/AVP` or `RTP/AVP/UDP` unicast with `client_port=`.
  case udp(clientRTPPort: UInt16, clientRTCPPort: UInt16)

  static func parse(_ header: String) -> FakeTransportRequest? {
    for alternative in header.split(separator: ",") {
      let params = alternative.split(separator: ";").map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard let proto = params.first?.uppercased(),
        !params.contains(where: { $0.lowercased() == "multicast" })
      else { continue }
      var values: [String: String] = [:]
      for param in params.dropFirst() {
        let kv = param.split(separator: "=", maxSplits: 1)
        if kv.count == 2 {
          values[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] =
            kv[1].trimmingCharacters(in: .whitespaces)
        }
      }
      switch proto {
      case "RTP/AVP/TCP":
        guard let raw = values["interleaved"] else { return .interleaved(channels: nil) }
        let channels = raw.split(separator: "-").compactMap {
          UInt8($0.trimmingCharacters(in: .whitespaces))
        }
        guard let rtp = channels.first else { continue }
        return .interleaved(channels: (rtp, channels.count > 1 ? channels[1] : rtp &+ 1))
      case "RTP/AVP", "RTP/AVP/UDP":
        guard let raw = values["client_port"] else { continue }
        let ports = raw.split(separator: "-").compactMap {
          UInt16($0.trimmingCharacters(in: .whitespaces))
        }
        guard let rtp = ports.first, rtp < UInt16.max else { continue }
        return .udp(clientRTPPort: rtp, clientRTCPPort: ports.count > 1 ? ports[1] : rtp + 1)
      default:
        continue
      }
    }
    return nil
  }
}

// MARK: - UDP sockets

/// Call `body` with a loopback socket address of `family` and `port`.
private func withLoopbackAddress<T>(
  family: FakeRTSPServer.AddressFamily, port: UInt16,
  _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
) -> T {
  switch family {
  case .ipv4:
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
  case .ipv6:
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_port = port.bigEndian
    var loopback = in6_addr()
    loopback.__u6_addr.__u6_addr8.15 = 1
    address.sin6_addr = loopback
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        body($0, socklen_t(MemoryLayout<sockaddr_in6>.size))
      }
    }
  }
}

/// Bind a non-blocking UDP socket to loopback `port` (0 = ephemeral). Returns
/// the descriptor and the bound port, or `nil`.
private func bindLoopbackUDP(
  family: FakeRTSPServer.AddressFamily, port: UInt16
) -> (fd: Int32, port: UInt16)? {
  let fd = socket(family == .ipv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
  guard fd >= 0 else { return nil }
  _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
  let bound = withLoopbackAddress(family: family, port: port) { Darwin.bind(fd, $0, $1) == 0 }
  var storage = sockaddr_storage()
  var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
  let named =
    bound
    && withUnsafeMutablePointer(to: &storage) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) == 0 }
    }
  guard named else {
    Darwin.close(fd)
    return nil
  }
  let boundPort = withUnsafePointer(to: &storage) { pointer -> UInt16 in
    if family == .ipv6 {
      return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
        UInt16(bigEndian: $0.pointee.sin6_port)
      }
    }
    return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
      UInt16(bigEndian: $0.pointee.sin_port)
    }
  }
  return (fd, boundPort)
}

/// One bound loopback UDP socket with a read source on its owner's queue.
///
/// `@unchecked Sendable`: `closed` is guarded by `lock`. The descriptor is only
/// used on `queue` (reads in the source handler; `send` must be called there
/// too) and is closed by the source's cancel handler, also on `queue`, so it is
/// never closed under an in-flight call.
private final class FakeUDPSocket: @unchecked Sendable {
  let port: UInt16
  private let fd: Int32
  private let family: FakeRTSPServer.AddressFamily
  private let source: DispatchSourceRead
  private let lock = NSLock()
  private var closed = false

  init(
    fd: Int32, port: UInt16, family: FakeRTSPServer.AddressFamily, queue: DispatchQueue,
    onDatagram: @escaping @Sendable (Data) -> Void
  ) {
    self.fd = fd
    self.port = port
    self.family = family
    // macOS sends no UDP datagram larger than the socket's send buffer, which
    // defaults to `net.inet.udp.maxdgram` (9216 bytes); tests send up to 64 KiB.
    var sendBuffer: Int32 = 1 << 20
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
    self.source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler {
      var buffer = [UInt8](repeating: 0, count: 65_536)
      while true {
        let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if count < 0 { return }
        // An empty datagram is a client's NAT hole-punch; not media.
        if count > 0 { onDatagram(Data(buffer[0..<count])) }
      }
    }
    source.setCancelHandler { Darwin.close(fd) }
    source.resume()
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  /// Send one datagram to loopback `port`. Call on the owner's queue.
  func send(_ data: Data, toPort port: UInt16) -> Bool {
    guard !withLock({ closed }) else { return false }
    return withLoopbackAddress(family: family, port: port) { address, length in
      data.withUnsafeBytes { bytes in
        sendto(fd, bytes.baseAddress, bytes.count, 0, address, length) == bytes.count
      }
    }
  }

  /// Stop reading and close the descriptor (on the queue). Idempotent.
  func close() {
    let first = withLock { () -> Bool in
      defer { closed = true }
      return !closed
    }
    if first { source.cancel() }
  }
}

/// A server RTP/RTCP socket pair on consecutive loopback ports (RTP even).
private final class FakeUDPPair: Sendable {
  let rtp: FakeUDPSocket
  let rtcp: FakeUDPSocket

  private init(rtp: FakeUDPSocket, rtcp: FakeUDPSocket) {
    self.rtp = rtp
    self.rtcp = rtcp
  }

  /// Bind a pair and start reading; `onDatagram` gets each non-empty datagram
  /// with whether it hit the RTCP port and the server port it arrived on.
  static func open(
    family: FakeRTSPServer.AddressFamily, queue: DispatchQueue,
    onDatagram: @escaping @Sendable (Data, Bool, UInt16) -> Void
  ) -> FakeUDPPair? {
    for _ in 0..<128 {
      guard let first = bindLoopbackUDP(family: family, port: 0) else { return nil }
      if first.port % 2 == 0, first.port < UInt16.max,
        let second = bindLoopbackUDP(family: family, port: first.port + 1)
      {
        let rtp = FakeUDPSocket(
          fd: first.fd, port: first.port, family: family, queue: queue
        ) { onDatagram($0, false, first.port) }
        let rtcp = FakeUDPSocket(
          fd: second.fd, port: second.port, family: family, queue: queue
        ) { onDatagram($0, true, second.port) }
        return FakeUDPPair(rtp: rtp, rtcp: rtcp)
      }
      Darwin.close(first.fd)
    }
    return nil
  }

  func close() {
    rtp.close()
    rtcp.close()
  }
}

// MARK: - Raw RTSP client

/// A bare RTSP client for wire-level tests: it writes arbitrary bytes on one
/// TCP connection (optionally one byte per write) and frames what comes back
/// (responses and `$`-interleaved data) with the library's `RTSPParser`.
///
/// A receive loop on a private queue appends to a buffer from connect until
/// close, so no bytes are lost between reads; every wait has a timeout.
///
/// `@unchecked Sendable`: mutable state is guarded by `lock`.
final class RawRTSPTestClient: @unchecked Sendable {
  enum ClientError: Error, CustomStringConvertible {
    case connectFailed(String)
    case sendFailed(String)
    case timedOut
    case closed

    var description: String {
      switch self {
      case .connectFailed(let reason): return "raw client connect failed: \(reason)"
      case .sendFailed(let reason): return "raw client send failed: \(reason)"
      case .timedOut: return "raw client timed out"
      case .closed: return "raw client connection closed"
      }
    }
  }

  private let connection: NWConnection
  private let queue = DispatchQueue(label: "ipcamkit.tests.raw-rtsp-client")
  private let parser = RTSPParser()
  private let lock = NSLock()
  private var buffer = Data()
  private var generation = 0
  private var peerClosed = false
  private var dataWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
  private var nextWaiterID = 0
  private var nextCSeq = 1

  /// A client for `host:port` with Nagle disabled, so small writes go out as
  /// separate TCP segments.
  init(host: String, port: UInt16) {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    connection = NWConnection(
      host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any,
      using: NWParameters(tls: nil, tcp: tcp))
  }

  /// A client for `server`'s loopback address and port.
  convenience init(server: FakeRTSPServer) {
    self.init(host: server.configuration.family.loopback, port: server.port)
  }

  deinit {
    connection.cancel()
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  /// Connect, failing fast on refusal and after `timeout` otherwise.
  func connect(timeout: Duration = .seconds(5)) async throws {
    let queue = self.queue
    let connection = self.connection
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = FakeOnce()
      connection.stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready:
          once.run { continuation.resume() }
        case .waiting(let error), .failed(let error):
          once.run { continuation.resume(throwing: ClientError.connectFailed("\(error)")) }
          if case .failed = state { self?.markClosed() }
        case .cancelled:
          once.run { continuation.resume(throwing: ClientError.closed) }
          self?.markClosed()
        default:
          break
        }
      }
      connection.start(queue: queue)
      queue.asyncAfter(deadline: .now() + timeout.fakeSeconds) {
        once.run { continuation.resume(throwing: ClientError.timedOut) }
      }
    }
    receiveNext()
  }

  /// Write `bytes` in one send and wait until the stack accepted them.
  func send(_ bytes: Data) async throws {
    let connection = self.connection
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: bytes,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: ClientError.sendFailed("\(error)"))
          } else {
            continuation.resume()
          }
        })
    }
  }

  /// Write `bytes` one byte per send, waiting for each.
  func sendBytewise(_ bytes: Data) async throws {
    for byte in bytes { try await send(Data([byte])) }
  }

  /// Serialize a request with the next CSeq (plus `Content-Length` for a body).
  /// Returns the bytes and the CSeq used.
  func makeRequest(
    method: String, url: String, headers: [(String, String)] = [], body: Data = Data()
  ) -> (bytes: Data, cseq: Int) {
    let cseq = withLock { () -> Int in
      defer { nextCSeq += 1 }
      return nextCSeq
    }
    var text = "\(method) \(url) RTSP/1.0\r\nCSeq: \(cseq)\r\n"
    for (name, value) in headers { text += "\(name): \(value)\r\n" }
    if !body.isEmpty { text += "Content-Length: \(body.count)\r\n" }
    text += "\r\n"
    var bytes = Data(text.utf8)
    bytes.append(body)
    return (bytes, cseq)
  }

  /// Send a request and return the next RTSP response (interleaved frames
  /// received before it are discarded).
  func request(
    method: String, url: String, headers: [(String, String)] = [], body: Data = Data(),
    timeout: Duration = .seconds(5)
  ) async throws -> RTSPResponse {
    try await send(makeRequest(method: method, url: url, headers: headers, body: body).bytes)
    return try await receiveResponse(timeout: timeout)
  }

  /// The next framed message (response or interleaved frame).
  func receiveMessage(timeout: Duration = .seconds(5)) async throws -> RTSPMessage {
    let deadline = ContinuousClock.now + timeout
    while true {
      let (message, seen, closed) = try withLock {
        () throws -> (RTSPMessage?, Int, Bool) in
        var copy = buffer
        if let (message, _) = try parser.parse(&copy) {
          buffer = copy
          return (message, generation, peerClosed)
        }
        return (nil, generation, peerClosed)
      }
      if let message { return message }
      if closed { throw ClientError.closed }
      let remaining = deadline - ContinuousClock.now
      guard remaining > .zero else { throw ClientError.timedOut }
      await waitForData(after: seen, timeout: remaining)
    }
  }

  /// The next RTSP response, skipping interleaved frames.
  func receiveResponse(timeout: Duration = .seconds(5)) async throws -> RTSPResponse {
    let deadline = ContinuousClock.now + timeout
    while true {
      let remaining = deadline - ContinuousClock.now
      guard remaining > .zero else { throw ClientError.timedOut }
      if case .response(let response) = try await receiveMessage(timeout: remaining) {
        return response
      }
    }
  }

  /// Close the connection.
  func close() {
    connection.cancel()
    markClosed()
  }

  private func receiveNext() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty {
        let waiters = self.withLock { () -> [CheckedContinuation<Void, Never>] in
          self.buffer.append(data)
          self.generation += 1
          return self.takeWaiters()
        }
        for waiter in waiters { waiter.resume() }
      }
      if isComplete || error != nil {
        self.markClosed()
      } else {
        self.receiveNext()
      }
    }
  }

  private func markClosed() {
    let waiters = withLock { () -> [CheckedContinuation<Void, Never>] in
      peerClosed = true
      generation += 1
      return takeWaiters()
    }
    for waiter in waiters { waiter.resume() }
  }

  /// Remove and return every data waiter. Call with `lock` held.
  private func takeWaiters() -> [CheckedContinuation<Void, Never>] {
    let waiters = Array(dataWaiters.values)
    dataWaiters.removeAll()
    return waiters
  }

  /// Suspend until the buffer changes after generation `seen`, or `timeout`.
  private func waitForData(after seen: Int, timeout: Duration) async {
    let id = withLock { () -> Int in
      nextWaiterID += 1
      return nextWaiterID
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let registered = withLock { () -> Bool in
        guard generation == seen else { return false }
        dataWaiters[id] = continuation
        return true
      }
      guard registered else {
        continuation.resume()
        return
      }
      queue.asyncAfter(deadline: .now() + timeout.fakeSeconds) { [weak self] in
        guard let self else { return }
        let waiter = self.withLock { self.dataWaiters.removeValue(forKey: id) }
        waiter?.resume()
      }
    }
  }
}

extension Duration {
  /// This duration in (fractional) seconds, for `DispatchTime` arithmetic.
  fileprivate var fakeSeconds: Double {
    Double(components.seconds) + Double(components.attoseconds) * 1e-18
  }
}
