// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Live tests for MulticastPair against mediamtx serving RTSP-initiated multicast.
//
// `ffmpeg` publishes an H.264 test pattern to `mediamtx` over RTSP/TCP. Each
// test drives DESCRIBE, SETUP with `Transport: RTP/AVP;multicast`, and PLAY by
// hand over the internal `RTSPTransportConnection`, joins the group and ports
// named in the SETUP reply with `MulticastPair`, and checks what arrives.
//
// These tests REQUIRE `ffmpeg` and `mediamtx` on `PATH`. They skip, with a
// message, on a host where lo0 does not deliver IPv4 multicast (a raw-socket
// probe in MulticastTests.swift checks this first).
//
// Each fixture gives mediamtx a random /24 in 239.255.0.0/16 (administratively
// scoped) and its own ports, so concurrent runs don't share a group. mediamtx
// sends each multicast datagram out of every multicast-capable interface with
// TTL 127, so the test stream also reaches the local network segment.

import Foundation
import Network
import Testing

@testable import IPCamKit

private struct MulticastLiveError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

// MARK: - Fixture

/// Owns a mediamtx server (multicast + TCP) and an ffmpeg publisher for one
/// test, and kills both on teardown.
///
/// The blocking work (port reservation, launch, waiting for the RTSP port) runs
/// on a private `DispatchQueue`, never on a Swift Concurrency cooperative
/// thread. `@unchecked Sendable`: mutable state is only written in `startSync`
/// (on `queue`) and read after `start()` returns, or in `shutDown()`.
final class MulticastStreamFixture: @unchecked Sendable {
  /// Unique token in the config path (mediamtx's command line) and the stream
  /// URL (ffmpeg's), so `pkill -f` matches only this fixture's processes.
  let marker: String
  /// The fixture's multicast range is `\(groupPrefix)0/24`.
  let groupPrefix: String
  private(set) var rtspPort: UInt16 = 0
  private(set) var multicastRTPPort: UInt16 = 0
  private(set) var multicastRTCPPort: UInt16 = 0
  /// RTSPS listener (only with `tls`); its multicast media is SRTP.
  private(set) var rtspsPort: UInt16 = 0

  /// The stream's URL on the IPv4 loopback.
  var url: String { "rtsp://127.0.0.1:\(rtspPort)/\(marker)" }
  /// The stream's `rtsps://` URL (only with `tls`).
  var rtspsURL: String { "rtsps://127.0.0.1:\(rtspsPort)/\(marker)" }

  /// Also serve RTSPS, with a fresh self-signed certificate, and send its
  /// multicast media as SRTP.
  private let tls: Bool

  /// Private directory for the config and log. mediamtx watches its config
  /// file's directory, and an unrelated file vanishing from the shared temp
  /// directory at the wrong moment made it fail at startup.
  private let directory: String
  private let configPath: String
  private let logPath: String
  private let queue: DispatchQueue
  private let mediamtx = Process()
  private let ffmpeg = Process()
  private var launched: [Process] = []

  init(tls: Bool = false) {
    self.tls = tls
    let token = UUID().uuidString.prefix(8).lowercased()
    marker = "ipcamkit-mcast-\(token)"
    groupPrefix = "239.255.\(Int.random(in: 1...254))."
    directory = NSTemporaryDirectory() + marker
    configPath = directory + "/mediamtx.yml"
    logPath = directory + "/mediamtx.log"
    queue = DispatchQueue(label: "ipcamkit.live-mcast.\(token)")
  }

  /// PATH with the usual Homebrew and system locations, so `/usr/bin/env` finds
  /// `mediamtx` and `ffmpeg` however the test runner was started.
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
    // An RTSP TCP port plus an even/odd UDP pair, all free on this host; the
    // UDP pair becomes mediamtx's multicast RTP/RTCP ports.
    guard let ports = reserveServerPorts(family: .ipv4, rtsps: tls) else {
      throw MulticastLiveError("could not reserve RTSP and multicast ports")
    }
    rtspPort = ports.rtsp
    multicastRTPPort = ports.rtp
    multicastRTCPPort = ports.rtcp
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

    // With TLS, SRTP multicast goes to the same groups on the next port pair.
    var tlsLines = ""
    if tls, let rtsps = ports.rtsps {
      rtspsPort = rtsps
      let keyPath = directory + "/server.key"
      let certPath = directory + "/server.crt"
      let openssl = Process()
      openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
      openssl.arguments = [
        "req", "-x509", "-newkey", "ec",
        "-pkeyopt", "ec_paramgen_curve:prime256v1", "-pkeyopt", "ec_param_enc:named_curve",
        "-nodes", "-keyout", keyPath, "-out", certPath, "-days", "2", "-subj", "/CN=localhost",
        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
      ]
      openssl.standardOutput = FileHandle.nullDevice
      openssl.standardError = FileHandle.nullDevice
      try openssl.run()
      openssl.waitUntilExit()
      guard openssl.terminationStatus == 0 else {
        throw MulticastLiveError("openssl exited \(openssl.terminationStatus)")
      }
      tlsLines = """
        rtspEncryption: optional
        rtspsAddress: ':\(rtsps)'
        rtspServerKey: '\(keyPath)'
        rtspServerCert: '\(certPath)'
        multicastSRTPPort: \(ports.rtp + 2)
        multicastSRTCPPort: \(ports.rtp + 3)

        """
    }

    // Without `udp`, mediamtx needs no unicast RTP/RTCP ports. `tcp` stays on
    // for the ffmpeg publisher.
    let config = """
      \(tlsLines)logLevel: error
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
      rtspTransports: [multicast, tcp]
      rtspAddress: ':\(rtspPort)'
      multicastIPRange: \(groupPrefix)0/24
      multicastRTPPort: \(multicastRTPPort)
      multicastRTCPPort: \(multicastRTCPPort)
      paths:
        all_others:
      """
    try config.write(toFile: configPath, atomically: false, encoding: .utf8)

    let env = Self.childEnvironment()
    // A log file, not a pipe (an unread pipe can block the child).
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
      "-f", "rtsp", "-rtsp_transport", "tcp", url,
    ]
    ffmpeg.standardOutput = FileHandle.nullDevice
    ffmpeg.standardError = FileHandle.nullDevice
    ffmpeg.environment = env

    try mediamtx.run()
    launched.append(mediamtx)
    // Blocking poll on this private queue (about 10 s budget).
    var opened = false
    for _ in 0..<67 {
      if canConnectLoopback(rtspPort) && (!tls || canConnectLoopback(rtspsPort)) {
        opened = true
        break
      }
      Thread.sleep(forTimeInterval: 0.15)
    }
    guard opened else {
      let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "<no log>"
      throw MulticastLiveError("mediamtx port \(rtspPort) did not open within 10s. Log:\n\(log)")
    }
    try ffmpeg.run()
    launched.append(ffmpeg)
  }

  /// Whether a TCP connection to 127.0.0.1:`port` succeeds right now. A refused
  /// connection parks in `.waiting`, which counts as "not yet".
  private func canConnectLoopback(_ port: UInt16) -> Bool {
    guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
    let conn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
    let connected = LockedFlag()
    let done = DispatchSemaphore(value: 0)
    conn.stateUpdateHandler = { state in
      switch state {
      case .ready:
        connected.set()
        done.signal()
      case .waiting, .failed, .cancelled:
        done.signal()
      default:
        break
      }
    }
    conn.start(queue: DispatchQueue(label: "ipcamkit.live-mcast.probe"))
    _ = done.wait(timeout: .now() + 2)
    conn.cancel()
    return connected.value
  }

  /// SIGTERM both processes, SIGKILL anything left with this fixture's marker,
  /// and remove the temp files. Never waits for the processes to exit.
  func shutDown() {
    for process in launched where process.isRunning { process.terminate() }
    launched.removeAll()
    killMarkedProcesses(marker)
    try? FileManager.default.removeItem(atPath: directory)
  }
}

/// A Bool set from a Network framework callback and read after a semaphore wait.
private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var isSet = false
  func set() {
    lock.lock()
    isSet = true
    lock.unlock()
  }
  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return isSet
  }
}

/// `pkill -9 -f marker`, fire-and-forget.
private func killMarkedProcesses(_ marker: String) {
  let pkill = Process()
  pkill.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  pkill.arguments = ["pkill", "-9", "-f", marker]
  pkill.standardOutput = FileHandle.nullDevice
  pkill.standardError = FileHandle.nullDevice
  try? pkill.run()
}

/// Kills the fixture's processes after `cap` unless cancelled. That bounds the
/// test even if an RTSP read never returns: killing mediamtx drops the TCP
/// connection, which ends the read.
private func multicastWatchdog(
  _ fixture: MulticastStreamFixture, cap: Duration
) -> Task<Void, Never> {
  let marker = fixture.marker
  return Task.detached {
    try? await Task.sleep(for: cap)
    guard !Task.isCancelled else { return }
    killMarkedProcesses(marker)
  }
}

// MARK: - Hand-driven RTSP client

/// The control side of one multicast RTSP session, driven request by request
/// over `RTSPTransportConnection` (which has no CSeq bookkeeping of its own).
private actor MulticastRTSPClient {
  let connection = RTSPTransportConnection()
  private var cseq = 0

  func request(
    _ method: RTSPMethod, _ url: String, _ headers: [(String, String)] = []
  ) async throws -> RTSPResponse {
    cseq += 1
    let request = RTSPRequest(
      method: method, url: url,
      headers: [("CSeq", "\(cseq)"), ("User-Agent", "IPCamKit-tests")] + headers)
    return try await connection.sendRequest(request)
  }
}

/// What SETUP negotiated for the video stream.
private struct MulticastSession: Sendable {
  let client: MulticastRTSPClient
  /// Aggregate control URL, for PLAY.
  let playURL: String
  let sessionID: String
  /// `destination`, the two ports of `port=P-Q`, and `ssrc` from the reply.
  let group: String
  let rtpPort: UInt16
  let rtcpPort: UInt16
  let ssrc: UInt32?
  /// The video payload type from the SDP.
  let payloadType: UInt8
  /// The control connection's local address: the interface to join on.
  let localHost: String

  func play() async throws {
    let response = try await client.request(
      .play, playURL, [("Session", sessionID), ("Range", "npt=0.000-")])
    guard response.statusCode == 200 else {
      throw MulticastLiveError("PLAY returned \(response.statusCode) \(response.reasonPhrase)")
    }
  }

  func close() async {
    await client.connection.close()
  }
}

/// `key=value` parameters of a Transport header (keys lowercased); bare flags
/// such as `multicast` map to "".
private func transportParameters(_ header: String) -> [String: String] {
  var parameters: [String: String] = [:]
  for part in header.split(separator: ";") {
    let pair = part.split(separator: "=", maxSplits: 1).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    parameters[pair[0].lowercased()] = pair.count == 2 ? pair[1] : ""
  }
  return parameters
}

/// Connect and DESCRIBE until mediamtx serves the stream (it answers 404 and
/// drops the connection until ffmpeg is publishing), then SETUP the video stream
/// with `Transport: RTP/AVP;multicast`.
private func setUpMulticast(_ fixture: MulticastStreamFixture) async throws -> MulticastSession {
  let deadline = ContinuousClock.now + .seconds(20)
  var attempt: (client: MulticastRTSPClient, describe: RTSPResponse)?
  var lastFailure = "no attempt"
  while attempt == nil, ContinuousClock.now < deadline {
    let client = MulticastRTSPClient()
    do {
      try await client.connection.connect(host: "127.0.0.1", port: fixture.rtspPort)
      let response = try await client.request(
        .describe, fixture.url, [("Accept", "application/sdp")])
      if response.statusCode == 200 {
        attempt = (client, response)
        break
      }
      lastFailure = "DESCRIBE returned \(response.statusCode)"
    } catch {
      lastFailure = "\(error)"
    }
    await client.connection.close()
    try await Task.sleep(for: .milliseconds(300))
  }
  guard let (client, describe) = attempt else {
    throw MulticastLiveError("DESCRIBE did not succeed within 20s: \(lastFailure)")
  }
  let presentation = try parseDescribe(requestURL: fixture.url, response: describe)
  guard let video = presentation.streams.first(where: { $0.media == "video" }) else {
    throw MulticastLiveError("SDP has no video stream")
  }

  let setup = try await client.request(
    .setup, video.control ?? fixture.url, [("Transport", "RTP/AVP;multicast")])
  guard setup.statusCode == 200, let transport = setup.header("Transport"),
    let sessionHeader = setup.header("Session")
  else {
    throw MulticastLiveError("multicast SETUP failed: \(setup.statusCode) \(setup.headers)")
  }
  let parameters = transportParameters(transport)
  let ports = (parameters["port"] ?? "").split(separator: "-").compactMap { UInt16($0) }
  guard parameters["multicast"] != nil, let group = parameters["destination"], ports.count == 2
  else {
    throw MulticastLiveError("SETUP reply is not a multicast transport: \(transport)")
  }
  let sessionID = sessionHeader.split(separator: ";")[0].trimmingCharacters(in: .whitespaces)

  // `localAddr` is the control connection's local endpoint, "127.0.0.1:PORT".
  let localAddr = await client.connection.ctx.localAddr
  guard let colon = localAddr.lastIndex(of: ":") else {
    throw MulticastLiveError("unexpected local address \(localAddr)")
  }
  return MulticastSession(
    client: client, playURL: presentation.control, sessionID: sessionID, group: group,
    rtpPort: ports[0], rtcpPort: ports[1],
    ssrc: parameters["ssrc"].flatMap { UInt32($0, radix: 16) },
    payloadType: video.rtpPayloadType, localHost: String(localAddr[..<colon]))
}

/// Parse every datagram as RTP; `nil` if any fails (`RawRTPPacket.parse`
/// rejects anything but version 2).
private func parseRTP(_ datagrams: [Data]) -> [RawRTPPacket]? {
  var packets: [RawRTPPacket] = []
  for datagram in datagrams {
    guard case .success(let packet) = RawRTPPacket.parse(datagram) else { return nil }
    packets.append(packet)
  }
  return packets
}

// MARK: - Tests

@Suite("Live Multicast Tests", .serialized, .liveServer, .loopbackIPv4Multicast)
struct LiveMulticastTests {

  @Test("H.264 RTP and RTCP sender reports arrive on the group named in the SETUP reply")
  func rtpAndRTCPOverMulticast() async throws {
    let fixture = MulticastStreamFixture()
    let watchdog = multicastWatchdog(fixture, cap: .seconds(45))
    defer { watchdog.cancel() }
    defer { fixture.shutDown() }
    try await fixture.start()

    let session = try await setUpMulticast(fixture)
    #expect(session.group.hasPrefix(fixture.groupPrefix), "group \(session.group)")
    #expect(session.rtpPort == fixture.multicastRTPPort)
    #expect(session.rtcpPort == fixture.multicastRTCPPort)
    #expect(session.payloadType == 96)
    #expect(session.localHost == "127.0.0.1")

    // Join on the control connection's interface (lo0 here), as the client will.
    let pair = try await MulticastPair.join(
      group: session.group, rtpPort: session.rtpPort, rtcpPort: session.rtcpPort, source: nil,
      interface: session.localHost)
    defer { pair.close() }
    let log = DatagramLog()
    log.attach(to: pair)
    try await session.play()

    let gotRTP = await log.wait(timeout: .seconds(5)) { $0.rtp.count >= 20 }
    #expect(gotRTP, "expected 20 RTP datagrams within 5s, got \(log.rtp.count)")
    let packets = try #require(parseRTP(log.rtp), "every RTP datagram should parse")
    #expect(packets.allSatisfy { $0.data[$0.data.startIndex] >> 6 == 2 })
    #expect(packets.allSatisfy { $0.payloadType == 96 }, "H.264 is payload type 96")
    let ssrcs = Set(packets.map(\.ssrc))
    #expect(ssrcs.count == 1, "one stream, one SSRC: \(ssrcs)")
    if let advertised = session.ssrc {
      #expect(ssrcs == [advertised], "SSRC should match the SETUP reply's ssrc=")
    }
    let sequences = packets.map(\.sequenceNumber)
    #expect(
      zip(sequences, sequences.dropFirst()).allSatisfy { $1 &- $0 == 1 },
      "loopback delivery should be in order without loss")

    // mediamtx sends a sender report about every 10 s on the RTCP port.
    let gotRTCP = await log.wait(timeout: .seconds(13)) { !$0.rtcp.isEmpty }
    #expect(gotRTCP, "expected an RTCP sender report within 13s")
    for datagram in log.rtcp {
      let first = try ReceivedCompoundPacket.validate(datagram)
      let report = try #require(try first.asSenderReport(), "expected PT 200 (SR)")
      #expect(ssrcs == [report.ssrc], "the SR should describe the RTP stream")
    }
    #expect(log.errors.isEmpty, "receive errors: \(log.errors)")
    await session.close()
  }

  @Test("Receivers sharing the group all get the stream; close() stops only its own")
  func receiversShareGroupAndClose() async throws {
    let fixture = MulticastStreamFixture()
    let watchdog = multicastWatchdog(fixture, cap: .seconds(45))
    defer { watchdog.cancel() }
    defer { fixture.shutDown() }
    try await fixture.start()
    let session = try await setUpMulticast(fixture)

    func join(source: String?, interface: String) async throws -> MulticastPair {
      try await MulticastPair.join(
        group: session.group, rtpPort: session.rtpPort, rtcpPort: session.rtcpPort,
        source: source, interface: interface)
    }
    // Same group and ports three times: by local address, by interface name,
    // and source-specific for the address mediamtx sends from on lo0.
    let byAddress = try await join(source: nil, interface: session.localHost)
    let byName = try await join(source: nil, interface: "lo0")
    let sourced = try await join(source: "127.0.0.1", interface: "lo0")
    let pairs = [byAddress, byName, sourced]
    defer {
      for pair in pairs { pair.close() }
    }
    #expect(sourced.isSourceSpecific)
    let logs = pairs.map { _ in DatagramLog() }
    for (pair, log) in zip(pairs, logs) { log.attach(to: pair) }
    try await session.play()

    for (name, log) in zip(["by address", "by name", "source-specific"], logs) {
      let got = await log.wait(timeout: .seconds(5)) { $0.rtp.count >= 10 }
      #expect(got, "\(name): expected 10 RTP datagrams within 5s, got \(log.rtp.count)")
      #expect(parseRTP(log.rtp)?.allSatisfy { $0.payloadType == 96 } == true)
    }

    byAddress.close()
    byAddress.close()  // idempotent
    byAddress.startReceiving(onRTP: { _ in }, onRTCP: { _ in })  // no-op once closed
    try await Task.sleep(for: .milliseconds(200))
    let closedCount = logs[0].rtp.count
    let openCount = logs[1].rtp.count
    try await Task.sleep(for: .seconds(1))
    #expect(logs[0].rtp.count == closedCount, "a closed pair must not deliver")
    #expect(logs[1].rtp.count > openCount + 5, "the other receivers keep receiving")
    await session.close()
  }

  @Test(
    "Joining with no interface receives the copy sent on the kernel's multicast route",
    .enabled(
      if: LoopbackMulticast.hasIPv4MulticastRoute(),
      "this host has no IPv4 multicast route, so a join without an interface cannot work"))
  func defaultInterfaceJoin() async throws {
    let fixture = MulticastStreamFixture()
    let watchdog = multicastWatchdog(fixture, cap: .seconds(45))
    defer { watchdog.cancel() }
    defer { fixture.shutDown() }
    try await fixture.start()
    let session = try await setUpMulticast(fixture)

    // mediamtx sends every datagram out of each multicast-capable interface, and
    // the kernel loops the copy on the routed interface (en0 on a typical Mac)
    // back to local members joined there.
    let pair = try await MulticastPair.join(
      group: session.group, rtpPort: session.rtpPort, rtcpPort: session.rtcpPort, source: nil)
    defer { pair.close() }
    let log = DatagramLog()
    log.attach(to: pair)
    try await session.play()

    let got = await log.wait(timeout: .seconds(5)) { $0.rtp.count >= 10 }
    #expect(got, "expected 10 RTP datagrams within 5s, got \(log.rtp.count)")
    #expect(parseRTP(log.rtp)?.allSatisfy { $0.payloadType == 96 } == true)
    await session.close()
  }

  @Test("RTSPClientSession with Transport.multicast delivers video frames")
  func sessionOverMulticast() async throws {
    let fixture = MulticastStreamFixture()
    let watchdog = multicastWatchdog(fixture, cap: .seconds(45))
    defer { watchdog.cancel() }
    defer { fixture.shutDown() }
    try await fixture.start()

    // mediamtx answers 404 until the publisher's stream is up.
    var started: (RTSPClientSession, SessionDescription)?
    let deadline = ContinuousClock.now + .seconds(20)
    while started == nil && ContinuousClock.now < deadline {
      let session = RTSPClientSession(url: fixture.url, transport: .multicast)
      do {
        started = (session, try await session.start())
      } catch {
        await session.stop()
        try await Task.sleep(for: .milliseconds(400))
      }
    }
    let (session, desc) = try #require(started)
    #expect(desc.video?.codec == .h264)

    let collector = Task { () -> [PublicVideoFrame] in
      var frames: [PublicVideoFrame] = []
      for try await item in session.frames() {
        if case .video(let frame) = item { frames.append(frame) }
        if frames.count >= 10 && frames.contains(where: { $0.isKeyframe }) { break }
      }
      return frames
    }
    let timeout = Task {
      try await Task.sleep(for: .seconds(10))
      collector.cancel()
    }
    let frames = try await collector.value
    timeout.cancel()
    #expect(frames.count >= 10)
    #expect(frames.contains { $0.isKeyframe })
    #expect(frames.allSatisfy { !$0.nalus.isEmpty })
    await session.stop()
  }

  @Test("rtsps:// with Transport.multicast receives SRTP and decrypts it into frames")
  func sessionOverSRTPMulticast() async throws {
    let fixture = MulticastStreamFixture(tls: true)
    let watchdog = multicastWatchdog(fixture, cap: .seconds(45))
    defer { watchdog.cancel() }
    defer { fixture.shutDown() }
    try await fixture.start()

    // The fixture's certificate is self-signed for this run; trust it here.
    let tls = TLSOptions(serverTrust: .custom { _ in true })
    var started: (RTSPClientSession, SessionDescription)?
    let deadline = ContinuousClock.now + .seconds(20)
    while started == nil && ContinuousClock.now < deadline {
      let session = RTSPClientSession(url: fixture.rtspsURL, transport: .multicast, tls: tls)
      do {
        started = (session, try await session.start())
      } catch {
        await session.stop()
        try await Task.sleep(for: .milliseconds(400))
      }
    }
    let (session, desc) = try #require(started)
    #expect(desc.video?.codec == .h264)

    let collector = Task { () -> [PublicVideoFrame] in
      var frames: [PublicVideoFrame] = []
      for try await item in session.frames() {
        if case .video(let frame) = item { frames.append(frame) }
        if frames.count >= 10 && frames.contains(where: { $0.isKeyframe }) { break }
      }
      return frames
    }
    let timeout = Task {
      try await Task.sleep(for: .seconds(10))
      collector.cancel()
    }
    let frames = try await collector.value
    timeout.cancel()
    #expect(frames.count >= 10)
    #expect(frames.contains { $0.isKeyframe })
    await session.stop()
  }
}
