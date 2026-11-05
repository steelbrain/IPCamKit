// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Live tests for RTSP over HTTP(S) tunneling and over WebSocket (ws/wss)
// against mediamtx, which accepts both on its RTSP and RTSPS ports.
//
// `ffmpeg` publishes a synthetic H.264 stream over plain RTSP/TCP and
// `RTSPTransportConnection` reads it back through each tunnel with a hand-driven
// DESCRIBE -> SETUP -> PLAY. Like LiveIntegrationTests, these REQUIRE `ffmpeg`
// and `mediamtx` on `PATH` and run `/usr/bin/openssl` for a self-signed
// certificate. The fixture's processes carry their own marker
// (`ipcamkit-tunnel-<token>`), so this suite's cleanup never touches another
// suite's servers.

import Foundation
import Network
import Security
import Testing

@testable import IPCamKit

// MARK: - Fixture

private struct TunnelLiveError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// A one-shot flag (first `claim()` wins), safe across threads.
private final class LiveOnce: @unchecked Sendable {
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

/// Whether a TCP connection to 127.0.0.1:`port` succeeds now. Suspends (never
/// blocks) for at most about a second.
private func loopbackAccepts(_ port: UInt16) async -> Bool {
  guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
  let queue = DispatchQueue(label: "ipcamkit.tunnel-live.probe")
  let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
  let once = LiveOnce()
  let accepted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready:
        if once.claim() { continuation.resume(returning: true) }
      case .waiting, .failed, .cancelled:
        // A refused connection parks in .waiting; treat it as "not yet".
        if once.claim() { continuation.resume(returning: false) }
      default:
        break
      }
    }
    queue.asyncAfter(deadline: .now() + 1) {
      if once.claim() { continuation.resume(returning: false) }
    }
    connection.start(queue: queue)
  }
  connection.cancel()
  return accepted
}

/// mediamtx serving one ffmpeg-published H.264 stream on a plain RTSP port and
/// an RTSPS port (`rtspEncryption: optional`, fresh self-signed certificate).
/// mediamtx accepts HTTP tunnels and WebSockets on both.
///
/// Blocking work (port reservation, openssl) runs on a private queue, never on
/// the cooperative pool. `@unchecked Sendable`: mutable state is written only
/// by `start()` before any reader runs, and by `shutDown()` after.
private final class TunnelLiveFixture: @unchecked Sendable {
  private(set) var rtspPort: UInt16 = 0
  private(set) var rtspsPort: UInt16 = 0
  /// The RTSPS certificate's SHA-256 pin.
  private(set) var pin: CertificateFingerprint?
  /// Unique token in every process's command line and the stream path.
  let marker: String

  /// Private directory for this fixture's files (see `init`).
  private let directory: String
  private let configPath: String
  private let logPath: String
  private let certPath: String
  private let keyPath: String
  private let queue: DispatchQueue
  private let mediamtx = Process()
  private let ffmpeg = Process()

  init() {
    let token = UUID().uuidString.prefix(8)
    marker = "ipcamkit-tunnel-\(token)"
    // mediamtx watches its config file's directory and exits if a file there
    // vanishes mid-scan ("lstat ...: no such file or directory"), which other
    // processes' temp files in the shared temp directory trigger. A directory
    // of our own avoids that.
    directory = NSTemporaryDirectory() + "ipcamkit-tunnel-live/\(marker)/"
    configPath = directory + "mediamtx.yml"
    logPath = directory + "mediamtx.log"
    certPath = directory + "server.crt"
    keyPath = directory + "server.key"
    queue = DispatchQueue(label: "ipcamkit.tunnel-live.\(token)")
  }

  private static func childEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    env["PATH"] = env["PATH"].map { "\(extra):\($0)" } ?? extra
    return env
  }

  /// Launch mediamtx, wait until both ports accept connections, then start
  /// the ffmpeg publisher.
  func start() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        continuation.resume(with: Result { try self.launchServer() })
      }
    }
    var listening = false
    for _ in 0..<60 {
      if await loopbackAccepts(rtspPort), await loopbackAccepts(rtspsPort) {
        listening = true
        break
      }
      try await Task.sleep(for: .milliseconds(150))
    }
    guard listening else {
      let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "<no log>"
      throw TunnelLiveError("mediamtx did not open its ports. Log:\n\(log)")
    }

    ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    ffmpeg.arguments = [
      "ffmpeg", "-hide_banner", "-loglevel", "error",
      "-re", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15",
      "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
      "-g", "15", "-pix_fmt", "yuv420p", "-an",
      "-f", "rtsp", "-rtsp_transport", "tcp", plainRTSPURL,
    ]
    ffmpeg.standardOutput = FileHandle.nullDevice
    ffmpeg.standardError = FileHandle.nullDevice
    ffmpeg.environment = Self.childEnvironment()
    try ffmpeg.run()
  }

  var plainRTSPURL: String { "rtsp://127.0.0.1:\(rtspPort)/\(marker)" }
  var secureRTSPURL: String { "rtsps://127.0.0.1:\(rtspsPort)/\(marker)" }

  private func launchServer() throws {
    guard let ports = reserveServerPorts(family: .ipv4, rtsps: true), let tlsPort = ports.rtsps
    else {
      throw TunnelLiveError("could not reserve server ports")
    }
    rtspPort = ports.rtsp
    rtspsPort = tlsPort
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)
    try runOpenSSL([
      "req", "-x509", "-newkey", "ec",
      "-pkeyopt", "ec_paramgen_curve:prime256v1", "-pkeyopt", "ec_param_enc:named_curve",
      "-nodes", "-keyout", keyPath, "-out", certPath, "-days", "2", "-subj", "/CN=localhost",
      "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1",
      "-addext", "extendedKeyUsage=serverAuth",
    ])
    let pem = try String(contentsOfFile: certPath, encoding: .utf8)
    let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
    guard let der = Data(base64Encoded: base64),
      let certificate = SecCertificateCreateWithData(nil, der as CFData)
    else {
      throw TunnelLiveError("could not decode the generated certificate")
    }
    pin = CertificateFingerprint(certificate: certificate)

    let config = """
      logLevel: error
      api: false
      metrics: false
      pprof: false
      playback: false
      rtmp: false
      hls: false
      webrtc: false
      srt: false
      moq: false
      rtsp: true
      rtspTransports: [tcp]
      rtspEncryption: optional
      rtspAddress: ':\(ports.rtsp)'
      rtspsAddress: ':\(tlsPort)'
      rtspServerKey: '\(keyPath)'
      rtspServerCert: '\(certPath)'
      rtpAddress: ':\(ports.rtp)'
      rtcpAddress: ':\(ports.rtcp)'
      paths:
        all_others:
      """
    try config.write(toFile: configPath, atomically: true, encoding: .utf8)
    FileManager.default.createFile(atPath: logPath, contents: nil)
    let log = FileHandle(forWritingAtPath: logPath) ?? FileHandle.nullDevice
    mediamtx.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    mediamtx.arguments = ["mediamtx", configPath]
    mediamtx.standardOutput = log
    mediamtx.standardError = log
    mediamtx.environment = Self.childEnvironment()
    try mediamtx.run()
  }

  private func runOpenSSL(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw TunnelLiveError("openssl \(arguments.first ?? "") exited \(process.terminationStatus)")
    }
  }

  /// SIGKILL every process carrying this fixture's marker.
  func killProcesses() {
    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    pkill.arguments = ["-9", "-f", marker]
    pkill.standardOutput = FileHandle.nullDevice
    pkill.standardError = FileHandle.nullDevice
    try? pkill.run()
  }

  /// Stop both processes and remove the temp files. Fast and non-blocking.
  func shutDown() {
    for process in [ffmpeg, mediamtx] where process.isRunning {
      process.terminate()
    }
    killProcesses()
    try? FileManager.default.removeItem(atPath: directory)
  }

  /// After `cap`, kill the server (dropping every tunnel, which fails any
  /// pending read) so a stalled test fails instead of hanging. Cancel it on
  /// success.
  func watchdog(_ cap: Duration) -> Task<Void, Never> {
    Task.detached { [self] in
      try? await Task.sleep(for: cap)
      guard !Task.isCancelled else { return }
      Issue.record("live tunnel watchdog fired after \(cap)")
      killProcesses()
    }
  }
}

// MARK: - RTSP dialogue

/// The four control-connection transports under test.
enum TunnelKind: String, CaseIterable, Sendable {
  case http
  case https
  case ws
  case wss

  var usesTLS: Bool { self == .https || self == .wss }
}

/// Builds RTSP requests with increasing CSeq.
private struct RequestBuilder {
  private(set) var cseq: UInt32 = 0

  mutating func make(
    _ method: RTSPMethod, _ url: String, headers: [(String, String)] = []
  ) -> RTSPRequest {
    cseq += 1
    var request = RTSPRequest(method: method, url: url)
    request.setHeader("CSeq", value: "\(cseq)")
    request.setHeader("User-Agent", value: "IPCamKitTests")
    for (name, value) in headers {
      request.setHeader(name, value: value)
    }
    return request
  }
}

/// Connect `kind` to the fixture and DESCRIBE the stream, retrying on a fresh
/// connection until the publisher's stream is up (mediamtx answers 404 until
/// then).
private func connectAndDescribe(
  _ kind: TunnelKind, fixture: TunnelLiveFixture, requests: inout RequestBuilder
) async throws -> (RTSPTransportConnection, RTSPResponse, String) {
  let port = kind.usesTLS ? fixture.rtspsPort : fixture.rtspPort
  let rtspURL = kind.usesTLS ? fixture.secureRTSPURL : fixture.plainRTSPURL
  let tunnelURL = try #require(
    URL(string: "\(kind.rawValue)://127.0.0.1:\(port)/\(fixture.marker)"))
  let pin = try #require(fixture.pin)
  let tls = TLSOptions(serverTrust: .pinned([pin]))

  let deadline = ContinuousClock.now + .seconds(20)
  var lastStatus: UInt16?
  while ContinuousClock.now < deadline {
    let connection = RTSPTransportConnection()
    switch kind {
    case .http, .https:
      try await connection.connectHTTPTunnel(
        url: tunnelURL, tls: tls, credentials: nil, userAgent: "IPCamKitTests")
    case .ws, .wss:
      try await connection.connectWebSocket(
        url: tunnelURL, tls: tls, credentials: nil, userAgent: "IPCamKitTests")
    }
    let response = try await connection.sendRequest(
      requests.make(.describe, rtspURL, headers: [("Accept", "application/sdp")]))
    if response.statusCode == 200 {
      return (connection, response, rtspURL)
    }
    lastStatus = response.statusCode
    await connection.close()
    try await Task.sleep(for: .milliseconds(400))
  }
  throw TunnelLiveError("DESCRIBE never succeeded; last status \(String(describing: lastStatus))")
}

/// Read messages until `count` RTP packets (version 2) arrived on channel 0,
/// returning the responses seen on the way.
@discardableResult
private func readRTP(
  _ connection: RTSPTransportConnection, count: Int
) async throws -> [RTSPResponse] {
  var packets = 0
  var responses: [RTSPResponse] = []
  while packets < count {
    switch try await connection.receiveMessage() {
    case .data(let data):
      if data.channelId == 0, let first = data.data.first, first >> 6 == 2 {
        packets += 1
      }
    case .response(let response):
      responses.append(response)
    }
  }
  return responses
}

// MARK: - Tests

@Suite("Live tunnel tests", .serialized, .liveServer)
struct LiveTunnelTests {

  @Test(
    "DESCRIBE, SETUP and PLAY through the tunnel, then RTP arrives", arguments: TunnelKind.allCases)
  func streamThroughTunnel(kind: TunnelKind) async throws {
    let fixture = TunnelLiveFixture()
    defer { fixture.shutDown() }
    let dog = fixture.watchdog(.seconds(45))
    defer { dog.cancel() }
    try await fixture.start()

    var requests = RequestBuilder()
    let (connection, describe, rtspURL) = try await connectAndDescribe(
      kind, fixture: fixture, requests: &requests)
    #expect(describe.contentType?.hasPrefix("application/sdp") == true)
    #expect(String(decoding: describe.body, as: UTF8.self).contains("m=video"))

    // SETUP the video stream at its control URL (SDP a=control resolved
    // against Content-Base by the library's DESCRIBE parser).
    let presentation = try parseDescribe(requestURL: rtspURL, response: describe)
    let video = try #require(presentation.streams.first { $0.media == "video" })
    let control = try #require(video.control)
    let setup = try await connection.sendRequest(
      requests.make(
        .setup, control, headers: [("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1")]))
    #expect(setup.statusCode == 200)
    let session = try #require(
      setup.header("Session")?.split(separator: ";").first.map {
        $0.trimmingCharacters(in: .whitespaces)
      })
    #expect(setup.header("Transport")?.contains("interleaved=0-1") == true)

    let play = try await connection.sendRequest(
      requests.make(.play, presentation.control, headers: [("Session", session)]))
    #expect(play.statusCode == 200)

    try await readRTP(connection, count: 10)

    // Client-to-server interleaved data (what two-way audio uses) goes through
    // the tunnel too: an RTCP receiver report on channel 1, then a request the
    // server can only answer if it parsed the `$` frame correctly.
    let receiverReport = Data([0x80, 0xC9, 0x00, 0x01, 0x12, 0x34, 0x56, 0x78])
    var frame = Data([0x24, 0x01, 0x00, UInt8(receiverReport.count)])
    frame.append(receiverReport)
    try await connection.send(frame)
    let options = requests.make(.options, rtspURL, headers: [("Session", session)])
    try await connection.send(RTSPSerializer().serialize(options))
    var reply: RTSPResponse?
    while reply == nil {
      if case .response(let response) = try await connection.receiveMessage() {
        reply = response
      }
    }
    #expect(reply?.cseq == requests.cseq)
    #expect(reply?.statusCode == 200)
    try await readRTP(connection, count: 10)
    #expect(await connection.resolvedRemote() == nil)
    await connection.close()
  }

  @Test("The tunnel POST keeps carrying requests past its 32767-byte Content-Length")
  func postBeyondContentLength() async throws {
    let fixture = TunnelLiveFixture()
    defer { fixture.shutDown() }
    let dog = fixture.watchdog(.seconds(45))
    defer { dog.cancel() }
    try await fixture.start()

    var requests = RequestBuilder()
    let (connection, _, rtspURL) = try await connectAndDescribe(
      .http, fixture: fixture, requests: &requests)
    // ~100 base64 bytes per OPTIONS: 500 of them put ~50 KB on the POST.
    var sentBytes = 0
    for _ in 0..<500 {
      let request = requests.make(.options, rtspURL)
      sentBytes += RTSPSerializer().serialize(request).base64EncodedData().count
      let response = try await connection.sendRequest(request)
      #expect(response.statusCode == 200)
      #expect(response.cseq == requests.cseq)
    }
    #expect(sentBytes > HTTPTunnel.postContentLength)
    await connection.close()
  }

  @Test("RTSPClientSession streams video through the tunnel", arguments: TunnelKind.allCases)
  func sessionThroughTunnel(kind: TunnelKind) async throws {
    let fixture = TunnelLiveFixture()
    defer { fixture.shutDown() }
    let dog = fixture.watchdog(.seconds(45))
    defer { dog.cancel() }
    try await fixture.start()

    let port = kind.usesTLS ? fixture.rtspsPort : fixture.rtspPort
    let rtspURL = kind.usesTLS ? fixture.secureRTSPURL : fixture.plainRTSPURL
    let tunnelURL = try #require(
      URL(string: "\(kind.rawValue)://127.0.0.1:\(port)/\(fixture.marker)"))
    let tunnel: RTSPTunnel =
      kind == .http || kind == .https ? .http(tunnelURL) : .webSocket(tunnelURL)
    let pin = try #require(fixture.pin)
    let tls = TLSOptions(serverTrust: .pinned([pin]))

    // mediamtx answers 404 until the publisher's stream is up.
    let diagnostics = DiagnosticLog()
    var started: (RTSPClientSession, SessionDescription)?
    let deadline = ContinuousClock.now + .seconds(20)
    while started == nil && ContinuousClock.now < deadline {
      // Receiver reports every 250 ms, so several go through the tunnel
      // while the frames below are collected.
      let session = RTSPClientSession(
        url: rtspURL, credentials: nil, transport: .tcp, tls: tls, tunnel: tunnel,
        userAgent: "IPCamKit",
        onDiagnostic: { diagnostics.add($0.message) },
        keepaliveInterval: nil, receiverReportInterval: .milliseconds(250))
      do {
        started = (session, try await session.start())
      } catch {
        await session.stop()
        try await Task.sleep(for: .milliseconds(400))
      }
    }
    let (session, desc) = try #require(started)
    #expect(desc.video?.codec == .h264)

    // Frames keep arriving after the server has received receiver reports.
    var frames: [PublicVideoFrame] = []
    let reportsSent = ContinuousClock.now + .seconds(1.5)
    for try await item in session.frames() {
      if case .video(let frame) = item { frames.append(frame) }
      if frames.count >= 10 && frames.contains(where: \.isKeyframe)
        && ContinuousClock.now > reportsSent
      {
        break
      }
    }
    #expect(frames.count >= 10)
    #expect(frames.contains { $0.isKeyframe })
    let reportFailures = diagnostics.all.filter { $0.contains("receiver report") }
    #expect(reportFailures.isEmpty, "\(reportFailures)")
    // PAUSE and PLAY go through the tunnel while the reader owns it.
    try await session.pause()
    try await session.play(PlayOptions())
    await session.stop()
  }
}
