// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Live end-to-end integration tests.
//
// `ffmpeg` publishes a synthetic stream to a `mediamtx` RTSP server, and
// `RTSPClientSession` pulls it back — exercising the full DESCRIBE -> SETUP ->
// PLAY -> depacketize pipeline against a real, spec-compliant server. Each test
// runs `mediamtx` in a single RTP transport mode (TCP-interleaved OR UDP) so the
// matching client transport is validated in isolation: a server in one mode
// rejects a SETUP for the other, so the client cannot silently fall back.
//
// These tests REQUIRE `ffmpeg` and `mediamtx` on `PATH` (see README "Testing").
// They are serialized so only one server/publisher pair runs at a time.

import Foundation
import Network
import Testing

@testable import IPCamKit

// MARK: - Errors

private struct LiveError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

// MARK: - Loopback port helpers (Network framework; IPv4 + IPv6)

/// Address family for the live fixture's loopback server. Lets one fixture
/// exercise the client over both IPv4 (`127.0.0.1`) and IPv6 (`[::1]`).
enum LiveIPFamily: Sendable {
  case ipv4
  case ipv6

  /// Loopback literal for client/probe connections (bare, for `NWEndpoint`).
  var loopback: String { self == .ipv6 ? "::1" : "127.0.0.1" }
  /// Loopback host as it appears in an RTSP URL (IPv6 is bracketed).
  var urlHost: String { self == .ipv6 ? "[::1]" : "127.0.0.1" }
  /// Wildcard bind host for reserving ports in this family.
  var wildcardHost: NWEndpoint.Host {
    self == .ipv6 ? NWEndpoint.Host("::") : NWEndpoint.Host("0.0.0.0")
  }
  /// MediaMTX listen address for `port` in this family (`[::]:P` / `:P`).
  func mediamtxAddress(_ port: UInt16) -> String {
    self == .ipv6 ? "[::]:\(port)" : ":\(port)"
  }
}

/// Thread-safe box for handing a Network framework callback's result back to a
/// semaphore-blocked caller. The `DispatchSemaphore` signal/wait provides the
/// happens-before barrier; the lock guards against any spurious concurrent set.
private final class ResultBox<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: T
  init(_ value: T) { self.value = value }
  func set(_ newValue: T) {
    lock.lock()
    value = newValue
    lock.unlock()
  }
  var get: T {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

/// Reserve a port by binding an `NWListener` (using `params`: `.tcp` or `.udp`)
/// to `family`'s wildcard address on `port` (0 = OS-assigned ephemeral). The
/// listener stays open so the caller holds the port reserved; the caller must
/// cancel it. Returns the listener plus the bound port, or `nil` on failure.
private func reserveListener(
  _ params: NWParameters, family: LiveIPFamily, port: UInt16, queue: DispatchQueue
) -> (listener: NWListener, port: UInt16)? {
  params.allowLocalEndpointReuse = true
  let portEndpoint: NWEndpoint.Port
  if port == 0 {
    portEndpoint = .any
  } else if let p = NWEndpoint.Port(rawValue: port) {
    portEndpoint = p
  } else {
    return nil
  }
  params.requiredLocalEndpoint = .hostPort(host: family.wildcardHost, port: portEndpoint)

  guard let listener = try? NWListener(using: params) else { return nil }
  let bound = ResultBox<UInt16?>(nil)
  let sem = DispatchSemaphore(value: 0)
  listener.newConnectionHandler = { $0.cancel() }
  listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
      bound.set(listener.port?.rawValue)
      sem.signal()
    case .failed, .cancelled:
      // Leaves `bound` nil so the caller treats it as a failed reservation.
      sem.signal()
    default:
      break
    }
  }
  listener.start(queue: queue)
  if sem.wait(timeout: .now() + 3) == .timedOut {
    listener.cancel()
    return nil
  }
  guard let p = bound.get else {
    listener.cancel()
    return nil
  }
  return (listener, p)
}

/// Reserve a free RTSP TCP port plus a consecutive even/odd RTP/RTCP UDP pair on
/// `family`'s wildcard address. MediaMTX requires the RTP port to be even with
/// RTCP = RTP + 1. All listeners are held simultaneously so the ports are
/// distinct and free, then released for the child process. There is a small
/// TOCTOU window, but the live suite is serialized and binds the ports
/// immediately. The UDP pair is reserved with UDP listeners (not TCP) so the
/// ports are free in the protocol MediaMTX actually binds them in.
func reserveServerPorts(
  family: LiveIPFamily
) -> (rtsp: UInt16, rtp: UInt16, rtcp: UInt16)? {
  let queue = DispatchQueue(label: "ipcamkit.live.reserve")
  var held: [NWListener] = []
  defer { for listener in held { listener.cancel() } }

  guard let rtsp = reserveListener(.tcp, family: family, port: 0, queue: queue) else {
    return nil
  }
  held.append(rtsp.listener)

  for _ in 0..<400 {
    guard let candidate = reserveListener(.udp, family: family, port: 0, queue: queue) else {
      continue
    }
    let base = candidate.port
    if base % 2 == 0, base > 0, base + 1 != rtsp.port,
      let next = reserveListener(.udp, family: family, port: base + 1, queue: queue)
    {
      held.append(candidate.listener)
      held.append(next.listener)
      return (rtsp.port, base, base + 1)
    }
    candidate.listener.cancel()
  }
  return nil
}

/// Whether a TCP connection to `family`'s loopback `port` succeeds right now.
private func canConnectLoopback(family: LiveIPFamily, _ port: UInt16) -> Bool {
  guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
  let queue = DispatchQueue(label: "ipcamkit.live.probe")
  let conn = NWConnection(host: NWEndpoint.Host(family.loopback), port: nwPort, using: .tcp)
  let connected = ResultBox(false)
  let sem = DispatchSemaphore(value: 0)
  conn.stateUpdateHandler = { state in
    switch state {
    case .ready:
      connected.set(true)
      sem.signal()
    case .waiting, .failed, .cancelled:
      // Not connectable right now. `.waiting` MUST short-circuit here: a refused
      // connection (server not yet listening) surfaces as `.waiting` (NWConnection
      // treats ECONNREFUSED as transient), so waiting for `.ready`/`.failed` only
      // would burn the full 2s timeout on every pre-startup probe and blow the
      // ~10s startup budget. The next poll iteration retries on a fresh connection.
      sem.signal()
    default:
      break
    }
  }
  conn.start(queue: queue)
  _ = sem.wait(timeout: .now() + 2)
  conn.cancel()
  return connected.get
}

// MARK: - Fixture

/// Owns a MediaMTX server + ffmpeg publisher for the lifetime of one test, and
/// guarantees both are killed on teardown.
///
/// All blocking process/socket work (port reservation, launch, port-wait) runs
/// on a dedicated `DispatchQueue`, NOT on a Swift Concurrency cooperative
/// thread. Under the test runner's default parallelism, blocking a cooperative
/// thread can wedge the shared pool and deadlock unrelated tests; confining the
/// blocking work to a private thread avoids that. `@unchecked Sendable` is safe
/// because mutable state is only touched inside `startSync` (on `queue`) and in
/// `shutDown` (after `start()` has fully completed — a happens-before barrier).
final class LiveStreamFixture: @unchecked Sendable {
  private(set) var rtspURL = ""

  private let transports: [String]
  private let family: LiveIPFamily
  private let readTimeoutSeconds: Int?
  private let ffmpegArgs: [String]
  private let marker: String
  private let configPath: String
  private let logPath: String
  private let queue: DispatchQueue
  private let mediamtx = Process()
  private let ffmpeg = Process()
  private var launched: [Process] = []

  /// - Parameters:
  ///   - transports: value for MediaMTX `rtspTransports` (e.g. `["tcp"]` or
  ///     `["udp"]`). This gates both the ffmpeg publisher and the client reader,
  ///     so a single-element value validates exactly one RTP transport.
  ///   - ffmpegArgs: ffmpeg args between the program name and the output URL
  ///     (inputs + codec options); the `-f rtsp ... <url>` tail is appended.
  ///   - family: loopback address family the server binds and the client/ffmpeg
  ///     reach it over (`127.0.0.1` for IPv4, `[::1]` for IPv6).
  init(
    transports: [String],
    family: LiveIPFamily = .ipv4,
    readTimeoutSeconds: Int? = nil,
    ffmpegArgs: [String]
  ) {
    let token = UUID().uuidString.prefix(8)
    self.transports = transports
    self.family = family
    self.readTimeoutSeconds = readTimeoutSeconds
    self.ffmpegArgs = ffmpegArgs
    self.marker = "ipcamkit-live-\(token)"
    self.configPath = NSTemporaryDirectory() + "ipcamkit-live-\(token).yml"
    self.logPath = NSTemporaryDirectory() + "ipcamkit-live-\(token).log"
    self.queue = DispatchQueue(label: "ipcamkit.live.\(token)")
  }

  /// PATH that includes the usual Homebrew + system locations so `/usr/bin/env`
  /// resolves `mediamtx`/`ffmpeg` regardless of how the test runner was invoked.
  private static func childEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    env["PATH"] = env["PATH"].map { "\(extra):\($0)" } ?? extra
    return env
  }

  /// Reserve ports, launch MediaMTX, wait for its RTSP port, then launch the
  /// ffmpeg publisher — all on the private queue so the calling cooperative
  /// thread only suspends (never blocks).
  func start() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        continuation.resume(with: Result { try self.startSync() })
      }
    }
  }

  private func startSync() throws {
    guard let ports = reserveServerPorts(family: family) else {
      throw LiveError("could not reserve RTSP + RTP/RTCP server ports")
    }
    rtspURL = "rtsp://\(family.urlHost):\(ports.rtsp)/\(marker)"

    let readTimeoutLine = readTimeoutSeconds.map { "readTimeout: \($0)s\n" } ?? ""
    let config = """
      \(readTimeoutLine)logLevel: error
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
      rtspTransports: [\(transports.joined(separator: ", "))]
      rtspAddress: '\(family.mediamtxAddress(ports.rtsp))'
      rtpAddress: '\(family.mediamtxAddress(ports.rtp))'
      rtcpAddress: '\(family.mediamtxAddress(ports.rtcp))'
      paths:
        all_others:
      """
    try config.write(toFile: configPath, atomically: true, encoding: .utf8)

    let env = Self.childEnvironment()

    // Capture mediamtx output to a file (not a pipe — pipes can deadlock) so a
    // startup failure can be surfaced in the test error.
    FileManager.default.createFile(atPath: logPath, contents: nil)
    let logHandle = FileHandle(forWritingAtPath: logPath)

    mediamtx.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    mediamtx.arguments = ["mediamtx", configPath]
    mediamtx.standardOutput = logHandle ?? FileHandle.nullDevice
    mediamtx.standardError = logHandle ?? FileHandle.nullDevice
    mediamtx.environment = env

    // `rtspTransports` gates the publisher too, not just the reader, so the
    // ffmpeg publish leg must use a transport the server accepts. Prefer TCP
    // when allowed (no publish-side packet loss); otherwise publish over UDP so
    // a UDP-only server still receives the stream.
    let publishTransport = transports.contains("tcp") ? "tcp" : "udp"
    ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    ffmpeg.arguments =
      ["ffmpeg", "-hide_banner", "-loglevel", "error"]
      + ffmpegArgs
      + ["-f", "rtsp", "-rtsp_transport", publishTransport, rtspURL]
    ffmpeg.standardOutput = FileHandle.nullDevice
    ffmpeg.standardError = FileHandle.nullDevice
    ffmpeg.environment = env

    try mediamtx.run()
    launched.append(mediamtx)

    // Blocking poll on this private thread (≈10s budget): fine here, off the
    // cooperative pool.
    var opened = false
    for _ in 0..<67 {
      if canConnectLoopback(family: family, ports.rtsp) {
        opened = true
        break
      }
      Thread.sleep(forTimeInterval: 0.15)
    }
    guard opened else {
      let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "<no log>"
      throw LiveError(
        "mediamtx RTSP port \(ports.rtsp) did not open within 10s. mediamtx log:\n\(log)")
    }

    try ffmpeg.run()
    launched.append(ffmpeg)
  }

  /// Terminate both processes and remove the temp files. Runs on the calling
  /// (cooperative) thread but does only fast, non-blocking work: SIGTERM plus a
  /// SIGKILL backstop (`pkill -9 -f <marker>`), with no `waitUntilExit`. The
  /// processes die asynchronously; the next serialized test uses fresh ports.
  func shutDown() {
    for p in launched where p.isRunning { p.terminate() }
    launched.removeAll()

    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    pkill.arguments = ["pkill", "-9", "-f", marker]
    pkill.standardOutput = FileHandle.nullDevice
    pkill.standardError = FileHandle.nullDevice
    pkill.environment = Self.childEnvironment()
    try? pkill.run()

    try? FileManager.default.removeItem(atPath: configPath)
    try? FileManager.default.removeItem(atPath: logPath)
  }
}

// MARK: - Frame collection

private actor ItemSink {
  private(set) var items: [PublicCodecItem] = []
  private(set) var finished = false
  private(set) var failure: Error?
  func add(_ item: PublicCodecItem) { items.append(item) }
  func finish(_ error: Error?) {
    finished = true
    failure = error
  }
}

/// Thread-safe collector for the `RTSPDiagnostic` messages a session emits via
/// its synchronous `onDiagnostic` callback.
private final class DiagnosticLog: @unchecked Sendable {
  private let lock = NSLock()
  private var messages: [String] = []
  func add(_ message: String) {
    lock.lock()
    messages.append(message)
    lock.unlock()
  }
  var all: [String] {
    lock.lock()
    defer { lock.unlock() }
    return messages
  }
}

/// Consume `session.frames()` until `until` is satisfied, the stream ends, or
/// `deadline` elapses — never an unbounded await. Returns everything collected.
@discardableResult
private func collectItems(
  from session: RTSPClientSession,
  deadline: Duration,
  until: @escaping @Sendable ([PublicCodecItem]) -> Bool
) async -> [PublicCodecItem] {
  let sink = ItemSink()
  let consumer = Task {
    do {
      for try await item in session.frames() {
        await sink.add(item)
        if until(await sink.items) { break }
      }
      await sink.finish(nil)
    } catch {
      await sink.finish(error)
    }
  }

  let endBy = ContinuousClock.now + deadline
  while ContinuousClock.now < endBy {
    let snapshot = await sink.items
    let isFinished = await sink.finished
    if until(snapshot) || isFinished { break }
    try? await Task.sleep(for: .milliseconds(120))
  }
  consumer.cancel()
  return await sink.items
}

/// Create a fresh session and retry `start()` until it succeeds or `deadline`
/// elapses. A fresh session per attempt avoids carrying partial state across the
/// 404s MediaMTX returns until the publisher's stream is ready.
private func startSessionWithRetry(
  deadline: Duration,
  _ makeSession: () -> RTSPClientSession
) async throws -> (RTSPClientSession, SessionDescription) {
  let endBy = ContinuousClock.now + deadline
  var lastError: Error?
  while ContinuousClock.now < endBy {
    let session = makeSession()
    do {
      let desc = try await session.start()
      return (session, desc)
    } catch {
      lastError = error
      await session.stop()
      try? await Task.sleep(for: .milliseconds(400))
    }
  }
  throw lastError ?? LiveError("RTSPClientSession.start() did not succeed in time")
}

private func videoFrames(_ items: [PublicCodecItem]) -> [PublicVideoFrame] {
  items.compactMap { if case .video(let f) = $0 { return f } else { return nil } }
}

private func audioFrames(_ items: [PublicCodecItem]) -> [PublicAudioFrame] {
  items.compactMap { if case .audio(let f) = $0 { return f } else { return nil } }
}

/// A detached backstop that SIGKILLs any live test server/publisher after `cap`.
/// This bounds the *whole* test even if an await inside the library is itself
/// unbounded (e.g. an RTSP read with no timeout while the server stalls):
/// killing the server drops the TCP connection, which unblocks the pending
/// read. Cancel it (via `defer`) on normal completion. The pkill matches the
/// shared `ipcamkit-live` marker; the suite is serialized, so only the current
/// test's processes exist.
private func liveWatchdog(_ cap: Duration) -> Task<Void, Never> {
  Task.detached {
    try? await Task.sleep(for: cap)
    guard !Task.isCancelled else { return }
    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    pkill.arguments = ["pkill", "-9", "-f", "ipcamkit-live"]
    pkill.standardOutput = FileHandle.nullDevice
    pkill.standardError = FileHandle.nullDevice
    try? pkill.run()
    pkill.waitUntilExit()
  }
}

// MARK: - Tests

@Suite("Live Integration Tests", .serialized)
struct LiveIntegrationTests {

  @Test("H.264 over interleaved TCP yields a keyframe with in-band SPS/PPS")
  func h264OverTCP() async throws {
    let watchdog = liveWatchdog(.seconds(45))
    defer { watchdog.cancel() }
    let fixture = LiveStreamFixture(
      transports: ["tcp"],
      ffmpegArgs: [
        "-re", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15",
        "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
        "-g", "15", "-pix_fmt", "yuv420p", "-an",
      ])
    defer { fixture.shutDown() }
    try await fixture.start()

    // MediaMTX is TCP-only here, so it rejects a UDP SETUP — the stream only
    // works if the client genuinely used RTP-interleaved TCP.
    let (session, desc) = try await startSessionWithRetry(deadline: .seconds(20)) {
      RTSPClientSession(url: fixture.rtspURL, transport: .tcp)
    }
    #expect(desc.video?.codec == .h264)

    // Teardown is via fixture.shutDown() (defer), which kills the server and
    // drops the connection, ending the frames() producer. We deliberately do
    // NOT call session.stop() here: a graceful TEARDOWN issued while the
    // streamFrames loop is still reading the shared connection blocks until the
    // server's session timeout (~60s), because the producer consumes the
    // TEARDOWN response before stop()'s own read sees it.
    let items = await collectItems(from: session, deadline: .seconds(12)) {
      let vf = videoFrames($0)
      return vf.count >= 3 && vf.contains { $0.isKeyframe }
    }

    let vf = videoFrames(items)
    #expect(!vf.isEmpty, "expected at least one video frame")
    #expect(vf.contains { $0.isKeyframe }, "expected a keyframe (IDR)")
    // SPS/PPS are surfaced either via the SDP (sprop-parameter-sets) or in-band
    // on a frame, depending on how the server advertises them.
    let spsAvailable = desc.video?.sps != nil || vf.contains { $0.sps != nil }
    let ppsAvailable = desc.video?.pps != nil || vf.contains { $0.pps != nil }
    #expect(spsAvailable, "expected SPS via SDP or in-band")
    #expect(ppsAvailable, "expected PPS via SDP or in-band")
    #expect(vf.allSatisfy { !$0.nalus.isEmpty }, "every frame should carry NAL units")

    // Graceful stop during active streaming must return promptly. This guards
    // the control-channel fix: TEARDOWN is routed through the reader loop, so
    // stop() no longer blocks until the server's session timeout (~60s). The
    // 45s watchdog would fail this test if it regressed.
    await session.stop()
  }

  @Test("A second concurrent frames() consumer is rejected (finding #12)")
  func framesRejectsSecondConsumer() async throws {
    let watchdog = liveWatchdog(.seconds(45))
    defer { watchdog.cancel() }
    let fixture = LiveStreamFixture(
      transports: ["tcp"],
      ffmpegArgs: [
        "-re", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15",
        "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
        "-g", "15", "-pix_fmt", "yuv420p", "-an",
      ])
    defer { fixture.shutDown() }
    try await fixture.start()

    let (session, _) = try await startSessionWithRetry(deadline: .seconds(20)) {
      RTSPClientSession(url: fixture.rtspURL, transport: .tcp)
    }

    // Consumer 1 owns the stream; it flips the single-consumer guard once its
    // reader loop is running.
    let sink = ItemSink()
    let consumer1 = Task {
      do {
        for try await item in session.frames() {
          await sink.add(item)
        }
      } catch {
        await sink.finish(error)
      }
    }
    defer { consumer1.cancel() }

    // Wait until consumer 1 is actually streaming: a delivered item proves the
    // reader loop is past the guard, so isStreaming is set.
    let endBy = ContinuousClock.now + .seconds(12)
    while ContinuousClock.now < endBy {
      if !(await sink.items).isEmpty { break }
      try? await Task.sleep(for: .milliseconds(120))
    }
    #expect(!(await sink.items).isEmpty, "consumer 1 should be receiving frames")

    // A second concurrent frames() must be rejected with .invalidState and
    // deliver nothing.
    var secondError: Error?
    do {
      for try await _ in session.frames() {
        Issue.record("second frames() must not deliver any item")
        break
      }
    } catch {
      secondError = error
    }
    if let rtspError = secondError as? RTSPError, case .invalidState = rtspError {
      // expected
    } else {
      Issue.record("expected RTSPError.invalidState, got \(String(describing: secondError))")
    }

    await session.stop()
  }

  @Test("H.265 over interleaved TCP yields a keyframe with in-band VPS/SPS/PPS")
  func h265OverTCP() async throws {
    let watchdog = liveWatchdog(.seconds(45))
    defer { watchdog.cancel() }
    // `no-open-gop=1` forces closed-GOP IDR keyframes (libx265 defaults to
    // open-GOP CRA, which — like retina — is not treated as a random-access
    // point). `repeat-headers=1` re-sends VPS/SPS/PPS in-band before each IDR.
    let fixture = LiveStreamFixture(
      transports: ["tcp"],
      ffmpegArgs: [
        "-re", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15",
        "-c:v", "libx265", "-tag:v", "hvc1", "-preset", "ultrafast",
        "-x265-params", "keyint=15:min-keyint=15:no-open-gop=1:repeat-headers=1",
        "-pix_fmt", "yuv420p", "-an",
      ])
    defer { fixture.shutDown() }
    try await fixture.start()

    let (session, desc) = try await startSessionWithRetry(deadline: .seconds(20)) {
      RTSPClientSession(url: fixture.rtspURL, transport: .tcp)
    }
    #expect(desc.video?.codec == .h265)

    let items = await collectItems(from: session, deadline: .seconds(12)) {
      let vf = videoFrames($0)
      return vf.count >= 3 && vf.contains { $0.isKeyframe }
    }

    let vf = videoFrames(items)
    #expect(!vf.isEmpty, "expected at least one video frame")
    #expect(vf.contains { $0.isKeyframe }, "expected a keyframe (IDR)")
    // VPS/SPS/PPS arrive either via the SDP or in-band on a keyframe.
    let vpsAvailable = desc.video?.vps != nil || vf.contains { $0.vps != nil }
    let spsAvailable = desc.video?.sps != nil || vf.contains { $0.sps != nil }
    let ppsAvailable = desc.video?.pps != nil || vf.contains { $0.pps != nil }
    #expect(vpsAvailable, "expected VPS via SDP or in-band")
    #expect(spsAvailable, "expected SPS via SDP or in-band")
    #expect(ppsAvailable, "expected PPS via SDP or in-band")
  }

  @Test("H.264 + AAC over interleaved TCP yields video and 48 kHz audio")
  func h264AacOverTCP() async throws {
    let watchdog = liveWatchdog(.seconds(45))
    defer { watchdog.cancel() }
    let fixture = LiveStreamFixture(
      transports: ["tcp"],
      ffmpegArgs: [
        "-re",
        "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
        "-map", "0:v", "-map", "1:a",
        "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
        "-g", "15", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-ar", "48000",
      ])
    defer { fixture.shutDown() }
    try await fixture.start()

    let (session, desc) = try await startSessionWithRetry(deadline: .seconds(20)) {
      RTSPClientSession(url: fixture.rtspURL, transport: .tcp)
    }
    #expect(desc.video?.codec == .h264)
    #expect(desc.audio != nil, "expected an audio stream in the SDP")
    #expect(desc.audio?.sampleRate == 48000)

    let items = await collectItems(from: session, deadline: .seconds(12)) {
      !videoFrames($0).isEmpty && audioFrames($0).count >= 2
    }

    #expect(!videoFrames(items).isEmpty, "expected video frames")
    let af = audioFrames(items)
    #expect(!af.isEmpty, "expected audio frames")
    #expect(af.allSatisfy { $0.sampleRate == 48000 }, "audio sample rate should be 48 kHz")
  }

  @Test("Keepalive sustains a session past the server read timeout")
  func keepaliveSustainsSession() async throws {
    let watchdog = liveWatchdog(.seconds(45))
    defer { watchdog.cancel() }

    // MediaMTX drops a reader that sends nothing within `readTimeout`. With a 3s
    // read timeout and a 1s keepalive, the session must survive well beyond 3s —
    // which only happens if keepalive requests are interleaved with the RTP and
    // acknowledged on the same TCP connection.
    let fixture = LiveStreamFixture(
      transports: ["tcp"],
      readTimeoutSeconds: 3,
      ffmpegArgs: [
        "-re", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15",
        "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
        "-g", "15", "-pix_fmt", "yuv420p", "-an",
      ])
    defer { fixture.shutDown() }
    try await fixture.start()

    let log = DiagnosticLog()
    let (session, _) = try await startSessionWithRetry(deadline: .seconds(20)) {
      RTSPClientSession(
        url: fixture.rtspURL, credentials: nil, transport: .tcp,
        userAgent: "IPCamKit", onDiagnostic: { log.add($0.message) },
        keepaliveInterval: .seconds(1))
    }

    // Run until a frame arrives from well past the 3s read-timeout window.
    let items = await collectItems(from: session, deadline: .seconds(20)) {
      videoFrames($0).contains { $0.timestamp > 6.0 }
    }
    await session.stop()

    let vf = videoFrames(items)
    #expect(
      vf.contains { $0.timestamp > 6.0 },
      "stream should survive well past the 3s read timeout via keepalive")
    let acked = log.all.filter { $0.contains("keepalive") && $0.contains("acknowledged") }
    #expect(!acked.isEmpty, "expected an acknowledged keepalive; diagnostics: \(log.all)")
  }

  // MARK: - UDP transport

  @Test("H.264 over UDP yields a keyframe with SPS/PPS")
  func h264OverUDP() async throws {
    let watchdog = liveWatchdog(.seconds(45))
    defer { watchdog.cancel() }
    // MediaMTX is UDP-only here (even/odd rtp/rtcp address pair), so it rejects
    // a TCP-interleaved SETUP. The stream only works if the client genuinely
    // negotiated client_port and pulled RTP/RTCP over its own UDP socket pair.
    let fixture = LiveStreamFixture(
      transports: ["udp"],
      ffmpegArgs: [
        "-re", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15",
        "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
        "-g", "15", "-pix_fmt", "yuv420p", "-an",
      ])
    defer { fixture.shutDown() }
    try await fixture.start()

    let (session, desc) = try await startSessionWithRetry(deadline: .seconds(20)) {
      RTSPClientSession(url: fixture.rtspURL, transport: .udp)
    }
    #expect(desc.video?.codec == .h264)

    let items = await collectItems(from: session, deadline: .seconds(12)) {
      let vf = videoFrames($0)
      return vf.count >= 3 && vf.contains { $0.isKeyframe }
    }

    let vf = videoFrames(items)
    #expect(!vf.isEmpty, "expected at least one video frame over UDP")
    #expect(vf.contains { $0.isKeyframe }, "expected a keyframe (IDR) over UDP")
    let spsAvailable = desc.video?.sps != nil || vf.contains { $0.sps != nil }
    let ppsAvailable = desc.video?.pps != nil || vf.contains { $0.pps != nil }
    #expect(spsAvailable, "expected SPS via SDP or in-band")
    #expect(ppsAvailable, "expected PPS via SDP or in-band")
    #expect(vf.allSatisfy { !$0.nalus.isEmpty }, "every frame should carry NAL units")

    // Graceful stop during active UDP streaming must return promptly: TEARDOWN
    // is routed over the TCP control connection while RTP flows on UDP, and the
    // 45s watchdog would fail this test if stop() hung.
    await session.stop()
  }

  @Test("H.265 over UDP yields a keyframe with VPS/SPS/PPS")
  func h265OverUDP() async throws {
    let watchdog = liveWatchdog(.seconds(45))
    defer { watchdog.cancel() }
    let fixture = LiveStreamFixture(
      transports: ["udp"],
      ffmpegArgs: [
        "-re", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15",
        "-c:v", "libx265", "-tag:v", "hvc1", "-preset", "ultrafast",
        "-x265-params", "keyint=15:min-keyint=15:no-open-gop=1:repeat-headers=1",
        "-pix_fmt", "yuv420p", "-an",
      ])
    defer { fixture.shutDown() }
    try await fixture.start()

    let (session, desc) = try await startSessionWithRetry(deadline: .seconds(20)) {
      RTSPClientSession(url: fixture.rtspURL, transport: .udp)
    }
    #expect(desc.video?.codec == .h265)

    let items = await collectItems(from: session, deadline: .seconds(12)) {
      let vf = videoFrames($0)
      return vf.count >= 3 && vf.contains { $0.isKeyframe }
    }

    let vf = videoFrames(items)
    #expect(!vf.isEmpty, "expected at least one video frame over UDP")
    #expect(vf.contains { $0.isKeyframe }, "expected a keyframe (IDR) over UDP")
    let vpsAvailable = desc.video?.vps != nil || vf.contains { $0.vps != nil }
    let spsAvailable = desc.video?.sps != nil || vf.contains { $0.sps != nil }
    let ppsAvailable = desc.video?.pps != nil || vf.contains { $0.pps != nil }
    #expect(vpsAvailable, "expected VPS via SDP or in-band")
    #expect(spsAvailable, "expected SPS via SDP or in-band")
    #expect(ppsAvailable, "expected PPS via SDP or in-band")
  }

  @Test("H.264 + AAC over UDP yields video and 48 kHz audio")
  func h264AacOverUDP() async throws {
    let watchdog = liveWatchdog(.seconds(45))
    defer { watchdog.cancel() }
    let fixture = LiveStreamFixture(
      transports: ["udp"],
      ffmpegArgs: [
        "-re",
        "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
        "-map", "0:v", "-map", "1:a",
        "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
        "-g", "15", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-ar", "48000",
      ])
    defer { fixture.shutDown() }
    try await fixture.start()

    let (session, desc) = try await startSessionWithRetry(deadline: .seconds(20)) {
      RTSPClientSession(url: fixture.rtspURL, transport: .udp)
    }
    #expect(desc.video?.codec == .h264)
    #expect(desc.audio != nil, "expected an audio stream in the SDP")
    #expect(desc.audio?.sampleRate == 48000)

    // Video on one UDP socket pair, audio on another — both must demultiplex.
    let items = await collectItems(from: session, deadline: .seconds(12)) {
      !videoFrames($0).isEmpty && audioFrames($0).count >= 2
    }

    #expect(!videoFrames(items).isEmpty, "expected video frames over UDP")
    let af = audioFrames(items)
    #expect(!af.isEmpty, "expected audio frames over UDP")
    #expect(af.allSatisfy { $0.sampleRate == 48000 }, "audio sample rate should be 48 kHz")

    await session.stop()
  }

  // MARK: - IPv6 transport

  @Test("H.264 over TCP on IPv6 (::1) yields a keyframe with SPS/PPS")
  func h264OverTCPIPv6() async throws {
    let watchdog = liveWatchdog(.seconds(45))
    defer { watchdog.cancel() }
    // MediaMTX bound on [::], pulled over rtsp://[::1]:PORT — proves the
    // RTP-interleaved TCP path works over IPv6 end to end.
    let fixture = LiveStreamFixture(
      transports: ["tcp"],
      family: .ipv6,
      ffmpegArgs: [
        "-re", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15",
        "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
        "-g", "15", "-pix_fmt", "yuv420p", "-an",
      ])
    defer { fixture.shutDown() }
    try await fixture.start()

    let (session, desc) = try await startSessionWithRetry(deadline: .seconds(20)) {
      RTSPClientSession(url: fixture.rtspURL, transport: .tcp)
    }
    #expect(desc.video?.codec == .h264)

    let items = await collectItems(from: session, deadline: .seconds(12)) {
      let vf = videoFrames($0)
      return vf.count >= 3 && vf.contains { $0.isKeyframe }
    }

    let vf = videoFrames(items)
    #expect(!vf.isEmpty, "expected at least one video frame over IPv6 TCP")
    #expect(vf.contains { $0.isKeyframe }, "expected a keyframe (IDR) over IPv6 TCP")
    let spsAvailable = desc.video?.sps != nil || vf.contains { $0.sps != nil }
    let ppsAvailable = desc.video?.pps != nil || vf.contains { $0.pps != nil }
    #expect(spsAvailable, "expected SPS via SDP or in-band")
    #expect(ppsAvailable, "expected PPS via SDP or in-band")

    await session.stop()
  }

  @Test("H.264 over UDP on IPv6 (::1) yields a keyframe with SPS/PPS")
  func h264OverUDPIPv6() async throws {
    let watchdog = liveWatchdog(.seconds(45))
    defer { watchdog.cancel() }
    // MediaMTX bound on [::] with UDP-only RTP transport, pulled from
    // rtsp://[::1]:PORT — proves the UDP RTP/RTCP socket pair works over IPv6.
    let fixture = LiveStreamFixture(
      transports: ["udp"],
      family: .ipv6,
      ffmpegArgs: [
        "-re", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15",
        "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
        "-g", "15", "-pix_fmt", "yuv420p", "-an",
      ])
    defer { fixture.shutDown() }
    try await fixture.start()

    let (session, desc) = try await startSessionWithRetry(deadline: .seconds(20)) {
      RTSPClientSession(url: fixture.rtspURL, transport: .udp)
    }
    #expect(desc.video?.codec == .h264)

    let items = await collectItems(from: session, deadline: .seconds(12)) {
      let vf = videoFrames($0)
      return vf.count >= 3 && vf.contains { $0.isKeyframe }
    }

    let vf = videoFrames(items)
    #expect(!vf.isEmpty, "expected at least one video frame over IPv6 UDP")
    #expect(vf.contains { $0.isKeyframe }, "expected a keyframe (IDR) over IPv6 UDP")
    let spsAvailable = desc.video?.sps != nil || vf.contains { $0.sps != nil }
    let ppsAvailable = desc.video?.pps != nil || vf.contains { $0.pps != nil }
    #expect(spsAvailable, "expected SPS via SDP or in-band")
    #expect(ppsAvailable, "expected PPS via SDP or in-band")

    await session.stop()
  }
}
