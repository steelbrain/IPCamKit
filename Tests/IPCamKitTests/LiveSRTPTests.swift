// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Live SRTP interop test: unprotect the SRTP/SRTCP mediamtx sends to an rtsps:// UDP reader.
//
// ffmpeg publishes an H.264 test pattern to mediamtx over plain RTSP/TCP. The test
// reads it back over RTSPS with `RTP/SAVP` UDP transport: DESCRIBE (SDP with
// `a=key-mgmt:mikey`), SETUP with our own MIKEY in a `KeyMgmt` header (mediamtx
// answers with its key), PLAY, then decrypts the datagrams with `SRTPContext`.
// Requires `mediamtx`, `ffmpeg` (see README "Testing") and `/usr/bin/openssl`.

import Foundation
import Network
import Testing

@testable import IPCamKit

private struct SRTPLiveError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// Lock-protected value shared with Network framework and process callbacks.
private final class LockedBox<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: T
  init(_ value: T) { self.value = value }
  func set(_ newValue: T) {
    lock.lock()
    value = newValue
    lock.unlock()
  }
  func update(_ body: (inout T) -> Void) {
    lock.lock()
    body(&value)
    lock.unlock()
  }
  var get: T {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

// MARK: - Ports

/// Bind an `NWListener` (`.tcp` or `.udp`) on `0.0.0.0:port` (0 = ephemeral) and
/// keep it open so the port stays reserved. The caller cancels it.
private func reserveIPv4Port(
  _ params: NWParameters, port: UInt16, queue: DispatchQueue
) -> (listener: NWListener, port: UInt16)? {
  params.allowLocalEndpointReuse = true
  let endpointPort: NWEndpoint.Port
  if port == 0 {
    endpointPort = .any
  } else if let p = NWEndpoint.Port(rawValue: port) {
    endpointPort = p
  } else {
    return nil
  }
  params.requiredLocalEndpoint = .hostPort(host: "0.0.0.0", port: endpointPort)
  guard let listener = try? NWListener(using: params) else { return nil }
  let bound = LockedBox<UInt16?>(nil)
  let sem = DispatchSemaphore(value: 0)
  listener.newConnectionHandler = { $0.cancel() }
  listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
      bound.set(listener.port?.rawValue)
      sem.signal()
    case .failed, .cancelled:
      sem.signal()
    default:
      break
    }
  }
  listener.start(queue: queue)
  guard sem.wait(timeout: .now() + 3) == .success, let p = bound.get else {
    listener.cancel()
    return nil
  }
  return (listener, p)
}

/// Reserve the RTSP and RTSPS TCP ports plus two even/odd UDP pairs (RTP/RTCP
/// and SRTP/SRTCP), all held at once so they are distinct, then released for
/// mediamtx to bind.
private func reserveSRTPServerPorts() -> (rtsp: UInt16, rtsps: UInt16, rtp: UInt16, srtp: UInt16)? {
  let queue = DispatchQueue(label: "ipcamkit.srtplive.reserve")
  var held: [NWListener] = []
  defer { for listener in held { listener.cancel() } }
  guard let rtsp = reserveIPv4Port(.tcp, port: 0, queue: queue) else { return nil }
  held.append(rtsp.listener)
  guard let rtsps = reserveIPv4Port(.tcp, port: 0, queue: queue) else { return nil }
  held.append(rtsps.listener)
  var pairs: [UInt16] = []
  for _ in 0..<400 where pairs.count < 2 {
    guard let candidate = reserveIPv4Port(.udp, port: 0, queue: queue) else { continue }
    // An even port is at most 65534, so `+ 1` cannot overflow.
    if candidate.port % 2 == 0,
      let next = reserveIPv4Port(.udp, port: candidate.port + 1, queue: queue)
    {
      held += [candidate.listener, next.listener]
      pairs.append(candidate.port)
    } else {
      candidate.listener.cancel()
    }
  }
  guard pairs.count == 2 else { return nil }
  return (rtsp.port, rtsps.port, pairs[0], pairs[1])
}

/// Whether a TCP connection to `127.0.0.1:port` succeeds right now.
private func acceptsTCP(_ port: UInt16) -> Bool {
  guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
  let conn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
  let connected = LockedBox(false)
  let sem = DispatchSemaphore(value: 0)
  conn.stateUpdateHandler = { state in
    switch state {
    case .ready:
      connected.set(true)
      sem.signal()
    case .waiting, .failed, .cancelled:
      // A refused connection parks in .waiting; treat it as "not yet".
      sem.signal()
    default:
      break
    }
  }
  conn.start(queue: DispatchQueue(label: "ipcamkit.srtplive.probe"))
  _ = sem.wait(timeout: .now() + 2)
  conn.cancel()
  return connected.get
}

// MARK: - Fixture

/// A mediamtx server serving RTSPS with SRTP over UDP (`rtspEncryption: optional`)
/// plus an ffmpeg H.264 publisher. Blocking work runs on a private queue, never
/// on a cooperative thread. Mutable state is written only in `startSync` before
/// `start()` returns, then read; `shutDown` kills both processes.
private final class SRTPLiveFixture: @unchecked Sendable {
  /// Shared by every process this suite starts. Distinct from the other live
  /// suite's `ipcamkit-live` marker so neither suite's watchdog kills the other's.
  static let markerPrefix = "ipcamkit-srtplive"

  let marker: String
  private(set) var rtspsPort: UInt16 = 0
  /// A directory of this fixture's own. mediamtx watches its config file's
  /// directory and shuts down (exit 1) when it cannot `lstat` a file that
  /// vanished there, which other processes' churn in the shared temp directory
  /// triggers. It sits under a parent that is never removed, so creating and
  /// removing it is invisible to a mediamtx watching the temp directory itself.
  private let directory: String
  private let configPath: String
  private let logPath: String
  private let certPath: String
  private let keyPath: String
  private let queue: DispatchQueue
  private let mediamtx = Process()
  private let ffmpeg = Process()
  private var launched: [Process] = []

  init() {
    let token = UUID().uuidString.prefix(8)
    marker = "\(Self.markerPrefix)-\(token)"
    directory = (NSTemporaryDirectory() as NSString)
      .appendingPathComponent(Self.markerPrefix + "/" + marker)
    configPath = directory + "/mediamtx.yml"
    logPath = directory + "/mediamtx.log"
    certPath = directory + "/server.crt"
    keyPath = directory + "/server.key"
    queue = DispatchQueue(label: "ipcamkit.srtplive.\(token)")
  }

  /// The aggregate RTSPS URL of the published stream.
  var rtspsURL: String { "rtsps://127.0.0.1:\(rtspsPort)/\(marker)" }

  /// Whether mediamtx is still running, for failure messages.
  var serverStatus: String {
    mediamtx.isRunning
      ? "running" : "exited \(mediamtx.terminationStatus) (\(mediamtx.terminationReason))"
  }

  /// mediamtx's output so far, for failure messages.
  var serverLog: String {
    (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "<no log>"
  }

  private static func childEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    env["PATH"] = env["PATH"].map { "\(extra):\($0)" } ?? extra
    return env
  }

  func start() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        continuation.resume(with: Result { try self.startSync() })
      }
    }
  }

  private func startSync() throws {
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)
    guard let ports = reserveSRTPServerPorts() else {
      throw SRTPLiveError("could not reserve mediamtx ports")
    }
    rtspsPort = ports.rtsps
    try runOpenSSL([
      "req", "-x509", "-newkey", "ec",
      "-pkeyopt", "ec_paramgen_curve:prime256v1", "-pkeyopt", "ec_param_enc:named_curve",
      "-nodes", "-keyout", keyPath, "-out", certPath, "-days", "2", "-subj", "/CN=localhost",
      "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
    ])

    let config = """
      logLevel: info
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
      rtspTransports: [udp, tcp]
      rtspEncryption: optional
      rtspAddress: ':\(ports.rtsp)'
      rtspsAddress: ':\(ports.rtsps)'
      rtpAddress: ':\(ports.rtp)'
      rtcpAddress: ':\(ports.rtp + 1)'
      srtpAddress: ':\(ports.srtp)'
      srtcpAddress: ':\(ports.srtp + 1)'
      rtspServerKey: '\(keyPath)'
      rtspServerCert: '\(certPath)'
      paths:
        all_others:
      """
    try config.write(toFile: configPath, atomically: true, encoding: .utf8)

    let env = Self.childEnvironment()
    FileManager.default.createFile(atPath: logPath, contents: nil)
    let logHandle = FileHandle(forWritingAtPath: logPath)
    mediamtx.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    mediamtx.arguments = ["mediamtx", configPath]
    mediamtx.standardOutput = logHandle ?? FileHandle.nullDevice
    mediamtx.standardError = logHandle ?? FileHandle.nullDevice
    mediamtx.environment = env

    ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    ffmpeg.arguments = [
      "ffmpeg", "-hide_banner", "-loglevel", "error",
      "-re", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15",
      "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
      "-g", "15", "-pix_fmt", "yuv420p", "-an",
      "-f", "rtsp", "-rtsp_transport", "tcp", "rtsp://127.0.0.1:\(ports.rtsp)/\(marker)",
    ]
    ffmpeg.standardOutput = FileHandle.nullDevice
    ffmpeg.standardError = FileHandle.nullDevice
    ffmpeg.environment = env

    try mediamtx.run()
    launched.append(mediamtx)
    var listening = false
    for _ in 0..<67 {
      if acceptsTCP(ports.rtsp) && acceptsTCP(ports.rtsps) {
        listening = true
        break
      }
      Thread.sleep(forTimeInterval: 0.15)
    }
    guard listening else {
      let status =
        mediamtx.isRunning
        ? "running" : "exited \(mediamtx.terminationStatus) (\(mediamtx.terminationReason))"
      throw SRTPLiveError(
        "mediamtx (\(status)) did not listen on TCP \(ports.rtsp)/\(ports.rtsps) within 10s."
          + " Log:\n\(serverLog)")
    }
    try ffmpeg.run()
    launched.append(ffmpeg)
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
      throw SRTPLiveError("openssl \(arguments.first ?? "") exited \(process.terminationStatus)")
    }
  }

  /// SIGKILL both processes (`/usr/bin/env` execs in place, so each PID is the
  /// server or publisher itself), pkill anything else with this fixture's
  /// marker, and remove the temp files. Non-blocking.
  func shutDown() {
    for process in launched where process.isRunning { kill(process.processIdentifier, SIGKILL) }
    launched.removeAll()
    srtpLiveKill(marker)
    try? FileManager.default.removeItem(atPath: directory)
  }
}

/// `pkill -9 -f <pattern>` (pkill never matches itself).
private func srtpLiveKill(_ pattern: String) {
  let pkill = Process()
  pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
  pkill.arguments = ["-9", "-f", pattern]
  pkill.standardOutput = FileHandle.nullDevice
  pkill.standardError = FileHandle.nullDevice
  try? pkill.run()
}

/// Kill this fixture's processes after `cap`, which drops the RTSP connection and
/// so ends any await still blocked on it. Cancel on normal completion.
private func srtpLiveWatchdog(marker: String, cap: Duration) -> Task<Void, Never> {
  Task.detached {
    try? await Task.sleep(for: cap)
    guard !Task.isCancelled else { return }
    srtpLiveKill(marker)
  }
}

// MARK: - RTSP driving

/// Sends RTSP requests on an `RTSPTransportConnection` with CSeq numbering and a
/// per-request deadline (on expiry the connection is closed, which fails the
/// pending read).
private struct RTSPDriver {
  let connection: RTSPTransportConnection
  private var cseq = 0

  init(connection: RTSPTransportConnection) {
    self.connection = connection
  }

  mutating func send(
    _ method: RTSPMethod, _ url: String, _ headers: [(String, String)] = [],
    timeout: Duration = .seconds(10)
  ) async throws -> RTSPResponse {
    cseq += 1
    let request = RTSPRequest(
      method: method, url: url,
      headers: [("CSeq", "\(cseq)"), ("User-Agent", "IPCamKit-SRTP-test")] + headers)
    let connection = self.connection
    return try await withThrowingTaskGroup(of: RTSPResponse.self) { group in
      group.addTask { try await connection.sendRequest(request) }
      group.addTask {
        try await Task.sleep(for: timeout)
        await connection.close()
        throw SRTPLiveError("\(method.rawValue) got no response within \(timeout)")
      }
      defer { group.cancelAll() }
      guard let response = try await group.next() else {
        throw SRTPLiveError("\(method.rawValue) produced no result")
      }
      return response
    }
  }
}

/// The parts of the DESCRIBE SDP this test needs, for the first video section.
private struct VideoMedia {
  var mLine: String?
  var control: String?
  var keyMgmt: String?
  var sessionKeyMgmt: String?
  var rtpmap: String?

  init(sdp: String) {
    var section: String?
    for rawLine in sdp.split(whereSeparator: \.isNewline) {
      let line = String(rawLine).trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("m=") {
        section = line.hasPrefix("m=video") && mLine == nil ? "video" : "other"
        if section == "video" { mLine = line }
        continue
      }
      if line.hasPrefix("a=key-mgmt:") {
        let value = String(line.dropFirst("a=key-mgmt:".count))
        if section == nil { sessionKeyMgmt = value } else if section == "video" { keyMgmt = value }
      } else if section == "video", line.hasPrefix("a=control:") {
        control = String(line.dropFirst("a=control:".count))
      } else if section == "video", line.hasPrefix("a=rtpmap:") {
        rtpmap = String(line.dropFirst("a=rtpmap:".count))
      }
    }
  }
}

/// Datagrams received on the client RTP/RTCP ports.
private final class SRTPDatagramLog: @unchecked Sendable {
  private let rtp = LockedBox<[Data]>([])
  private let rtcp = LockedBox<[Data]>([])
  func addRTP(_ data: Data) { rtp.update { $0.append(data) } }
  func addRTCP(_ data: Data) { rtcp.update { $0.append(data) } }
  var rtpPackets: [Data] { rtp.get }
  var rtcpPackets: [Data] { rtcp.get }
}

/// `server_port=A-B` from a Transport header: A.
private func serverRTPPort(_ transport: String) -> UInt16? {
  for parameter in transport.split(separator: ";") {
    let parts = parameter.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
    guard parts.count == 2, parts[0].lowercased() == "server_port" else { continue }
    return UInt16(parts[1].split(separator: "-").first ?? "")
  }
  return nil
}

// MARK: - Test

@Suite("Live SRTP interop (mediamtx)", .serialized, .liveServer)
struct LiveSRTPTests {

  @Test("SRTP and SRTCP from mediamtx over RTSPS + UDP unprotect to valid H.264 RTP")
  func receiveSRTPFromMediamtx() async throws {
    let fixture = SRTPLiveFixture()
    defer { fixture.shutDown() }
    let watchdog = srtpLiveWatchdog(marker: fixture.marker, cap: .seconds(60))
    defer { watchdog.cancel() }
    try await fixture.start()

    // DESCRIBE until the publisher's stream is ready. mediamtx answers 404 until
    // then and closes the connection, so each attempt uses a fresh connection.
    var opened: (driver: RTSPDriver, describe: RTSPResponse)?
    var lastAttempt = "no attempt"
    let describeDeadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < describeDeadline {
      let attempt = RTSPTransportConnection()
      do {
        try await attempt.connect(
          host: "127.0.0.1", port: fixture.rtspsPort,
          tls: TLSOptions(serverTrust: .custom { _ in true }))
        var attemptDriver = RTSPDriver(connection: attempt)
        let response = try await attemptDriver.send(
          .describe, fixture.rtspsURL, [("Accept", "application/sdp")])
        if response.statusCode == 200 {
          opened = (attemptDriver, response)
          break
        }
        lastAttempt = "\(response.statusCode) \(response.reasonPhrase)"
      } catch {
        lastAttempt = "\(error)"
      }
      await attempt.close()
      try await Task.sleep(for: .milliseconds(300))
    }
    let describeFailure =
      "DESCRIBE never succeeded (\(lastAttempt)); mediamtx \(fixture.serverStatus). Log:\n"
      + fixture.serverLog
    let (startedDriver, described) = try #require(opened, Comment(rawValue: describeFailure))
    var driver = startedDriver
    let connection = driver.connection
    let media = VideoMedia(sdp: String(decoding: described.body, as: UTF8.self))
    #expect(media.mLine == "m=video 0 RTP/SAVP 96")
    #expect(media.rtpmap?.hasPrefix("96 H264/90000") == true)
    let sdpKeyMgmt = try #require(media.keyMgmt ?? media.sessionKeyMgmt, "no a=key-mgmt in SDP")
    let sdpMessage = try MIKEY.parse(
      try #require(KeyMgmtHeader.parseSDPAttribute(sdpKeyMgmt), "bad a=key-mgmt value"))

    let control = try #require(media.control, "no a=control for video")
    let base = described.header("Content-Base") ?? fixture.rtspsURL
    let controlURL: String
    if control.lowercased().hasPrefix("rtsp") {
      controlURL = control
    } else {
      controlURL = base.hasSuffix("/") ? base + control : base + "/" + control
    }

    // SETUP with our own key; mediamtx answers 400 without a KeyMgmt header.
    let udp = try await UDPPair.bind(family: .ipv4)
    defer { udp.close() }
    let ourSSRC = UInt32.random(in: 1 ... .max)
    let ourMIKEY = MIKEY.makeInitiatorMessage(
      cryptoSessions: [MIKEY.CryptoSession(policyNumber: 0, ssrc: ourSSRC, roc: 0)],
      keys: SRTPKeyMaterial.random())
    let setup = try await driver.send(
      .setup, controlURL,
      [
        ("Transport", "RTP/SAVP;unicast;client_port=\(udp.rtpPort)-\(udp.rtcpPort)"),
        ("KeyMgmt", KeyMgmtHeader.format(uri: controlURL, mikey: ourMIKEY)),
      ])
    try #require(
      setup.statusCode == 200,
      "SETUP answered \(setup.statusCode) \(setup.reasonPhrase). Log:\n\(fixture.serverLog)")
    let session = try #require(
      setup.header("Session")?.split(separator: ";").first.map {
        $0.trimmingCharacters(in: .whitespaces)
      })
    let transport = try #require(setup.header("Transport"))
    #expect(transport.contains("RTP/SAVP"))
    let serverPort = try #require(serverRTPPort(transport), "no server_port in \(transport)")
    let keyMgmtHeader = try #require(setup.header("KeyMgmt"), "SETUP response has no KeyMgmt")
    let keyMgmt = try #require(KeyMgmtHeader.parse(keyMgmtHeader))
    #expect(keyMgmt.uri == controlURL)
    let serverMessage = try MIKEY.parse(keyMgmt.mikey)
    #expect(serverMessage.keys == sdpMessage.keys, "SETUP repeats the SDP's key")
    let serverSSRCs = Set(serverMessage.cryptoSessions.map(\.ssrc))
    var context = try serverMessage.makeContext()

    try await udp.connect(peerHost: "127.0.0.1", peerRTPPort: serverPort)
    let datagrams = SRTPDatagramLog()
    udp.startReceiving(
      onRTP: { datagrams.addRTP($0) }, onRTCP: { datagrams.addRTCP($0) })

    let play = try await driver.send(
      .play, base, [("Session", session), ("Range", "npt=0.000-")])
    #expect(play.statusCode == 200)

    // Collect video for a while and wait (bounded) for a sender report.
    let collectDeadline = ContinuousClock.now + .seconds(12)
    let minimumRTP = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < collectDeadline {
      if ContinuousClock.now > minimumRTP, datagrams.rtpPackets.count >= 30,
        !datagrams.rtcpPackets.isEmpty
      {
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    _ = try? await driver.send(.teardown, base, [("Session", session)], timeout: .seconds(3))
    await connection.close()

    // SRTP: every packet authenticates and decrypts to H.264 RTP.
    let received = datagrams.rtpPackets
    #expect(received.count >= 10, "only \(received.count) SRTP packets arrived")
    var nalTypes: [UInt8: Int] = [:]
    var failures: [String] = []
    for packet in received {
      do {
        let plain = try context.unprotectRTP(packet)
        #expect(plain.count == packet.count - 10)
        let rtp = try RawRTPPacket.parse(plain).get()
        #expect(rtp.payloadType == 96)
        #expect(serverSSRCs.isEmpty || serverSSRCs.contains(rtp.ssrc))
        let payload = rtp.payload
        guard let first = payload.first else { continue }
        #expect(first & 0x80 == 0, "forbidden_zero_bit set")
        nalTypes[first & 0x1F, default: 0] += 1
        // `plain` starts at index 0, so its payload range offsets into `packet`.
        let lower = packet.startIndex + rtp.payloadRange.lowerBound
        let upper = packet.startIndex + rtp.payloadRange.upperBound
        #expect(packet[lower..<upper] != payload, "payload was sent in the clear")
      } catch {
        failures.append("\(error)")
      }
    }
    #expect(failures.isEmpty, "\(failures.count) SRTP packets failed: \(failures.prefix(3))")
    // Single NAL units (1 non-IDR, 5 IDR, 6 SEI, 7 SPS, 8 PPS), STAP-A (24), FU-A (28).
    let plausible: Set<UInt8> = [1, 5, 6, 7, 8, 9, 24, 28]
    #expect(nalTypes.keys.allSatisfy(plausible.contains), "NAL types \(nalTypes)")
    #expect(nalTypes[28] != nil || nalTypes[1] != nil || nalTypes[5] != nil, "\(nalTypes)")

    // SRTCP: mediamtx sends its first sender report about a second after PLAY;
    // each unprotects to a compound packet led by an SR.
    let rtcpPackets = datagrams.rtcpPackets
    #expect(!rtcpPackets.isEmpty, "mediamtx sent no SRTCP sender report within 12s")
    for packet in rtcpPackets {
      let plain = try context.unprotectRTCP(packet)
      let (first, _) = try RTCPPacketRef.parse(plain)
      let report = try #require(try first.asSenderReport(), "first RTCP packet is not an SR")
      #expect(serverSSRCs.isEmpty || serverSSRCs.contains(report.ssrc))
    }
    print(
      "LiveSRTPTests: unprotected \(received.count) SRTP and \(rtcpPackets.count) SRTCP packets;"
        + " NAL types \(nalTypes.sorted { $0.key < $1.key })")
  }

  @Test("RTSPClientSession decrypts SRTP from rtsps:// over UDP into video frames")
  func sessionOverSRTP() async throws {
    let fixture = SRTPLiveFixture()
    defer { fixture.shutDown() }
    let watchdog = srtpLiveWatchdog(marker: fixture.marker, cap: .seconds(60))
    defer { watchdog.cancel() }
    try await fixture.start()

    // The fixture's certificate is self-signed for this run; trust it here.
    let tls = TLSOptions(serverTrust: .custom { _ in true })
    let diagnostics = LockedBox<[String]>([])
    var started: (RTSPClientSession, SessionDescription)?
    let deadline = ContinuousClock.now + .seconds(20)
    while started == nil && ContinuousClock.now < deadline {
      // Receiver reports (SRTCP) every 250 ms while frames are collected.
      let session = RTSPClientSession(
        url: fixture.rtspsURL, credentials: nil, transport: .udp, tls: tls,
        userAgent: "IPCamKit",
        onDiagnostic: { diagnostic in diagnostics.update { $0.append(diagnostic.message) } },
        keepaliveInterval: nil, receiverReportInterval: .milliseconds(250))
      do {
        started = (session, try await session.start())
      } catch {
        await session.stop()
        try await Task.sleep(for: .milliseconds(400))
      }
    }
    let (session, desc) = try #require(started, "start() never succeeded")
    #expect(desc.video?.codec == .h264)

    let collector = Task { () -> (frames: [PublicVideoFrame], rtcp: Int) in
      var frames: [PublicVideoFrame] = []
      var rtcp = 0
      let reportsSent = ContinuousClock.now + .seconds(1.5)
      for try await item in session.frames() {
        switch item {
        case .video(let frame): frames.append(frame)
        case .rtcp: rtcp += 1
        default: break
        }
        if frames.count >= 15 && frames.contains(where: { $0.isKeyframe }) && rtcp > 0
          && ContinuousClock.now > reportsSent
        {
          break
        }
      }
      return (frames, rtcp)
    }
    let timeout = Task {
      try await Task.sleep(for: .seconds(12))
      collector.cancel()
    }
    let (frames, rtcp) = try await collector.value
    timeout.cancel()
    #expect(frames.count >= 15)
    #expect(frames.contains { $0.isKeyframe })
    #expect(rtcp > 0, "expected an SRTCP sender report")
    let failures = diagnostics.get.filter { $0.contains("SRTP") || $0.contains("receiver report") }
    #expect(failures.isEmpty, "\(failures)")
    await session.stop()
  }
}
