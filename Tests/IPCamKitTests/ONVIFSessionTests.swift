// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// RTSPClientSession against FakeRTSPServer: ONVIF replay (PLAY headers, replay
// info on frames, seeking), pause/resume, frame backpressure, the ONVIF
// backchannel, and compressed metadata.

import Foundation
import Testing

@testable import IPCamKit

// MARK: - Helpers

/// Collects what a `frames()` consumer receives, for tests that keep
/// controlling the session while frames arrive.
private actor FrameRecorder {
  private(set) var items: [PublicCodecItem] = []
  private(set) var error: Error?
  private(set) var finished = false

  func add(_ item: PublicCodecItem) { items.append(item) }
  func finish(_ error: Error?) {
    self.error = error
    finished = true
  }

  var videoFrames: [PublicVideoFrame] {
    items.compactMap {
      if case .video(let frame) = $0 { return frame }
      return nil
    }
  }

  var metadataFrames: [PublicMetadataFrame] {
    items.compactMap {
      if case .metadata(let frame) = $0 { return frame }
      return nil
    }
  }
}

/// Iterate `session.frames()` into a recorder until cancelled or the stream ends.
private func record(_ session: RTSPClientSession) -> (FrameRecorder, Task<Void, Never>) {
  let recorder = FrameRecorder()
  let task = Task {
    do {
      for try await item in session.frames() {
        await recorder.add(item)
      }
      await recorder.finish(nil)
    } catch {
      await recorder.finish(error)
    }
  }
  return (recorder, task)
}

/// Poll `condition` every 20 ms until it holds or `timeout` passes.
private func eventually(
  timeout: Duration = .seconds(5), _ condition: () async -> Bool
) async -> Bool {
  let end = ContinuousClock.now + timeout
  while ContinuousClock.now < end {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return await condition()
}

/// Stop `server` after `cap` unless cancelled, so a hung client fails instead of
/// stalling the run.
private func serverWatchdog(_ server: FakeRTSPServer, after cap: Duration) -> Task<Void, Never> {
  Task.detached {
    try? await Task.sleep(for: cap)
    guard !Task.isCancelled else { return }
    server.stop()
  }
}

/// Send one H.264 access unit on stream 0 carrying the ONVIF replay extension
/// for recording time `time`, on every packet or only on the first one.
/// Keyframes are clean points.
@discardableResult
private func sendReplayFrame(
  _ handle: FakeRTSPSessionHandle, _ sequencer: inout RTPTestSequencer, time: Date,
  keyframe: Bool, cseq: UInt8, terminal: Bool = false, tagEveryPacket: Bool = true
) -> Bool {
  let ext = onvifReplayExtension(
    ntp: ntpTimestamp(for: time), cleanPoint: keyframe, endOfSection: false,
    discontinuity: false, terminal: terminal, cseq: cseq)
  for packet in sequencer.accessUnit(
    h264AccessUnit(keyframe: keyframe), timestampIncrement: 9000, rtpExtension: ext,
    extensionOnAllPackets: tagEveryPacket)
  {
    guard handle.sendRTP(packet, stream: 0) else { return false }
  }
  return true
}

/// Thread-safe list of diagnostic messages.
private final class Diagnostics: @unchecked Sendable {
  private let lock = NSLock()
  private var messages: [String] = []
  func add(_ diagnostic: RTSPDiagnostic) {
    lock.withLock { messages.append(diagnostic.message) }
  }
  var all: [String] { lock.withLock { messages } }
}

/// Mutable box shared between a server hook and the test.
private final class Box<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

/// gzip-compress `data` with the system gzip (RFC 1952 container).
private func gzip(_ data: Data) throws -> Data {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
  process.arguments = ["-c", "-n"]
  let input = Pipe()
  let output = Pipe()
  process.standardInput = input
  process.standardOutput = output
  try process.run()
  input.fileHandleForWriting.write(data)
  try input.fileHandleForWriting.close()
  let compressed = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw RTSPError.invalidState("gzip exited \(process.terminationStatus)")
  }
  return compressed
}

private let recordingStart = Date(timeIntervalSince1970: 1_735_732_800)  // 2025-01-01T12:00:00Z

// MARK: - Replay

@Suite("ONVIF session against a fake camera", .timeLimit(.minutes(1)))
struct ONVIFSessionTests {
  @Test("Replay: Require and PLAY headers, SDP range, and recording time on frames")
  func replayHeadersAndFrames() async throws {
    let server = FakeRTSPServer(
      sdp: makeTestSDP(
        media: [h264VideoMediaSDP(recvonly: true)],
        sessionAttributes: ["range:clock=20250101T120000Z-20250101T130000Z"]))
    server.onPlay = { request, handle in
      let cseq = UInt8(truncatingIfNeeded: request.cseq ?? 0)
      guard let setup = handle.setup(forStream: 0) else { return }
      var sequencer = RTPTestSequencer(parameters: setup.parameters)
      for index in 0..<6 {
        sendReplayFrame(
          handle, &sequencer, time: recordingStart.addingTimeInterval(Double(index) * 0.5),
          keyframe: index % 3 == 0, cseq: cseq, terminal: index == 5)
      }
    }
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }

    let session = RTSPClientSession(url: server.url, onvif: .replay)
    let desc = try await session.start(
      PlayOptions(
        range: .clock(start: recordingStart), scale: 2, rateControl: false, frames: .intra))
    #expect(
      desc.range == .clock(start: recordingStart, end: recordingStart.addingTimeInterval(3600)))

    let (recorder, consumer) = record(session)
    defer { consumer.cancel() }
    #expect(await eventually { await recorder.videoFrames.count >= 6 })
    let frames = await recorder.videoFrames
    #expect(frames.count == 6)
    for (index, frame) in frames.enumerated() {
      let replay = try #require(frame.replay)
      #expect(
        abs(replay.time.timeIntervalSince(recordingStart) - Double(index) * 0.5) < 0.001)
      #expect(replay.isCleanPoint == (index % 3 == 0))
      #expect(replay.isTerminal == (index == 5))
      #expect(!replay.isDiscontinuity)
    }

    for method in ["DESCRIBE", "SETUP", "PLAY"] {
      let request = try #require(server.requests(method: method).first)
      #expect(request.requireTags == ["onvif-replay"], "\(method)")
    }
    #expect(server.requests(method: "OPTIONS").first?.requireTags == [])
    let play = try #require(server.requests(method: "PLAY").first)
    #expect(play.range == "clock=20250101T120000.000Z-")
    #expect(play.scale == "2.0")
    #expect(play.rateControl == "no")
    #expect(play.frames == "intra")
    #expect(play.immediate == nil)

    await session.stop()
  }

  @Test(
    "Seeking drops packets of the previous playback and restarts reassembly",
    arguments: [true, false])
  func seekDropsStalePackets(tagEveryPacket: Bool) async throws {
    let server = FakeRTSPServer(sdp: makeTestSDP(media: [h264VideoMediaSDP(recvonly: true)]))
    let seekTarget = recordingStart.addingTimeInterval(600)
    let staleTime = recordingStart.addingTimeInterval(5000)
    server.onPlay = { [weak server] request, handle in
      let cseq = UInt8(truncatingIfNeeded: request.cseq ?? 0)
      guard let server, let setup = handle.setup(forStream: 0) else { return }
      let playCount = server.requests(method: "PLAY").count
      Task {
        // Each PLAY restarts the RTP sequence at the RTP-Info value.
        var sequencer = RTPTestSequencer(parameters: setup.parameters)
        if playCount == 1 {
          for index in 0..<2000 {
            if server.requests(method: "PLAY").count > 1 {
              // Still in flight when the seek PLAY arrived.
              for offset in 0..<4 {
                sendReplayFrame(
                  handle, &sequencer, time: staleTime.addingTimeInterval(Double(offset)),
                  keyframe: offset == 0, cseq: cseq, tagEveryPacket: tagEveryPacket)
              }
              return
            }
            guard
              sendReplayFrame(
                handle, &sequencer,
                time: recordingStart.addingTimeInterval(Double(index) * 0.1),
                keyframe: index % 10 == 0, cseq: cseq, tagEveryPacket: tagEveryPacket)
            else { return }
            try? await Task.sleep(for: .milliseconds(10))
          }
        } else {
          // Let the old stream's stragglers go out first.
          try? await Task.sleep(for: .milliseconds(50))
          for index in 0..<20 {
            sendReplayFrame(
              handle, &sequencer, time: seekTarget.addingTimeInterval(Double(index) * 0.1),
              keyframe: index % 10 == 0, cseq: cseq, tagEveryPacket: tagEveryPacket)
          }
        }
      }
    }
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }

    let session = RTSPClientSession(url: server.url, onvif: .replay)
    _ = try await session.start(PlayOptions(range: .clock(start: recordingStart)))
    let (recorder, consumer) = record(session)
    defer { consumer.cancel() }
    #expect(await eventually { await recorder.videoFrames.count >= 15 })

    try await session.play(PlayOptions(range: .clock(start: seekTarget), immediate: true))
    #expect(
      await eventually {
        await recorder.videoFrames.filter { ($0.replay?.time ?? .distantPast) >= seekTarget }
          .count >= 20
      })

    let frames = await recorder.videoFrames
    #expect(!frames.contains { ($0.replay?.time ?? .distantPast) >= staleTime })
    // Each access unit's first packet is tagged, so every frame has a time.
    #expect(frames.allSatisfy { $0.replay != nil })
    let firstNew = try #require(
      frames.firstIndex { ($0.replay?.time ?? .distantPast) >= seekTarget })
    #expect(frames[firstNew].isKeyframe)
    #expect(frames[firstNew].replay?.isCleanPoint == true)
    #expect(frames[firstNew...].allSatisfy { ($0.replay?.time ?? .distantPast) >= seekTarget })
    #expect(frames[firstNew...].allSatisfy { $0.loss == 0 })

    let seek = try #require(server.requests(method: "PLAY").dropFirst().first)
    #expect(seek.range == "clock=20250101T121000.000Z-")
    #expect(seek.immediate == "yes")
    #expect(seek.requireTags == ["onvif-replay"])
    await session.stop()
  }

  /// After each seek's response, the server sends stale packets carrying the
  /// first PLAY's CSeq, then the new playback. One stale frame of 1101
  /// packets (only the first tagged) keeps the filter on; 1001 stale tagged
  /// packets turn it off, with a warning for each seek.
  @Test(
    "Untagged packets continuing a stale frame don't count toward the replay filter's limit",
    .timeLimit(.minutes(1)), arguments: [false, true])
  func staleReplayLimitCountsTaggedPackets(manyTagged: Bool) async throws {
    let server = FakeRTSPServer(sdp: makeTestSDP(media: [h264VideoMediaSDP(recvonly: true)]))
    let staleTime = recordingStart.addingTimeInterval(5000)
    let firstCSeq = Box<UInt8>(0)
    server.onPlay = { [weak server] request, handle in
      let cseq = UInt8(truncatingIfNeeded: request.cseq ?? 0)
      guard let server, let setup = handle.setup(forStream: 0) else { return }
      let playCount = server.requests(method: "PLAY").count
      if playCount == 1 { firstCSeq.value = cseq }
      Task {
        var sequencer = RTPTestSequencer(parameters: setup.parameters)
        let start = recordingStart.addingTimeInterval(Double(playCount) * 600)
        if playCount > 1 {
          // After the seek's response has gone out.
          try? await Task.sleep(for: .milliseconds(100))
          let ext = onvifReplayExtension(
            ntp: ntpTimestamp(for: staleTime), cleanPoint: false, endOfSection: false,
            discontinuity: false, terminal: false, cseq: firstCSeq.value)
          let units = manyTagged ? Array(repeating: 1, count: 1001) : [1101]
          for (index, size) in units.enumerated() {
            let packets = sequencer.accessUnit(
              Array(repeating: h264TestNonIDRSlice, count: size), timestampIncrement: 9000,
              rtpExtension: ext)
            for (offset, packet) in packets.enumerated() {
              guard handle.sendRTP(packet, stream: 0) else { return }
              if (index + offset) % 20 == 19 { try? await Task.sleep(for: .milliseconds(1)) }
            }
          }
        }
        for index in 0..<20 {
          guard
            sendReplayFrame(
              handle, &sequencer, time: start.addingTimeInterval(Double(index) * 0.1),
              keyframe: index % 10 == 0, cseq: cseq)
          else { return }
          try? await Task.sleep(for: .milliseconds(5))
        }
      }
    }
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }
    let diagnostics = Diagnostics()
    let session = RTSPClientSession(
      url: server.url, transport: .tcp, onvif: .replay, onDiagnostic: { diagnostics.add($0) })
    _ = try await session.start(PlayOptions(range: .clock(start: recordingStart)))
    let (recorder, consumer) = record(session)
    defer { consumer.cancel() }
    #expect(await eventually { await recorder.videoFrames.count >= 20 })
    for seek in 2...3 {
      let target = recordingStart.addingTimeInterval(Double(seek) * 600)
      try await session.play(PlayOptions(range: .clock(start: target), immediate: true))
      #expect(
        await eventually {
          await recorder.videoFrames.filter { ($0.replay?.time ?? .distantPast) >= target }
            .count >= 20
        })
    }
    await session.stop()
    let warnings = diagnostics.all.filter { $0.contains("no longer filtering") }
    #expect(warnings.count == (manyTagged ? 2 : 0), "\(warnings)")
    if !manyTagged {
      let frames = await recorder.videoFrames
      #expect(!frames.contains { $0.replay == nil || $0.replay!.time >= staleTime })
    }
  }

  /// A large frame (tagged on its first packet only) is in flight when the
  /// seek is sent: its untagged rest, arriving after the seek's response,
  /// continues a stale frame and doesn't count toward the filter's limit.
  @Test(
    "The rest of a stale frame that began before a seek doesn't end replay filtering",
    .timeLimit(.minutes(1)))
  func staleFrameStraddlingSeek() async throws {
    let server = FakeRTSPServer(sdp: makeTestSDP(media: [h264VideoMediaSDP(recvonly: true)]))
    server.configuration.includeRTPInfo = false
    let staleTime = recordingStart.addingTimeInterval(5000)
    let seekTarget = recordingStart.addingTimeInterval(600)
    let sequencerBox = Box<RTPTestSequencer?>(nil)
    let rest = Box<[Data]>([])
    let firstCSeq = Box<UInt8>(0)
    server.onPlay = { [weak server] request, handle in
      let cseq = UInt8(truncatingIfNeeded: request.cseq ?? 0)
      guard let server, let setup = handle.setup(forStream: 0) else { return }
      let playCount = server.requests(method: "PLAY").count
      Task {
        var sequencer = sequencerBox.value ?? RTPTestSequencer(parameters: setup.parameters)
        if playCount == 1 {
          firstCSeq.value = cseq
          for index in 0..<20 {
            sendReplayFrame(
              handle, &sequencer, time: recordingStart.addingTimeInterval(Double(index) * 0.1),
              keyframe: index % 10 == 0, cseq: cseq)
          }
          // Only the first packet of a 1101-packet frame before the seek.
          let ext = onvifReplayExtension(
            ntp: ntpTimestamp(for: staleTime), cleanPoint: false, endOfSection: false,
            discontinuity: false, terminal: false, cseq: cseq)
          let packets = sequencer.accessUnit(
            Array(repeating: h264TestNonIDRSlice, count: 1101), timestampIncrement: 9000,
            rtpExtension: ext)
          _ = handle.sendRTP(packets[0], stream: 0)
          rest.value = Array(packets.dropFirst())
          sequencerBox.value = sequencer
          return
        }
        try? await Task.sleep(for: .milliseconds(100))
        for (index, packet) in rest.value.enumerated() {
          guard handle.sendRTP(packet, stream: 0) else { return }
          if index % 20 == 19 { try? await Task.sleep(for: .milliseconds(1)) }
        }
        for second in 1...5 {
          sendReplayFrame(
            handle, &sequencer, time: staleTime.addingTimeInterval(Double(second)),
            keyframe: false, cseq: firstCSeq.value)
        }
        for index in 0..<20 {
          sendReplayFrame(
            handle, &sequencer, time: seekTarget.addingTimeInterval(Double(index) * 0.1),
            keyframe: index % 10 == 0, cseq: cseq)
        }
      }
    }
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }
    let diagnostics = Diagnostics()
    let session = RTSPClientSession(
      url: server.url, transport: .tcp, onvif: .replay, onDiagnostic: { diagnostics.add($0) })
    _ = try await session.start(PlayOptions(range: .clock(start: recordingStart)))
    let (recorder, consumer) = record(session)
    defer { consumer.cancel() }
    #expect(await eventually { await recorder.videoFrames.count >= 20 })
    try await Task.sleep(for: .milliseconds(100))
    try await session.play(PlayOptions(range: .clock(start: seekTarget), immediate: true))
    #expect(
      await eventually {
        await recorder.videoFrames.filter { ($0.replay?.time ?? .distantPast) >= seekTarget }
          .count >= 20
      })
    await session.stop()
    #expect(!diagnostics.all.contains { $0.contains("no longer filtering") })
    let frames = await recorder.videoFrames
    #expect(!frames.contains { ($0.replay?.time ?? .distantPast) >= staleTime })
  }

  /// The playback after a seek carries no replay tags although the one
  /// before did: its packets count toward the limit, so it is delivered once
  /// filtering stops, with a warning.
  @Test(
    "A seek's playback without replay tags is delivered once the filter's limit is reached",
    .timeLimit(.minutes(1)))
  func untaggedPlaybackAfterSeekDelivered() async throws {
    let server = FakeRTSPServer(sdp: makeTestSDP(media: [h264VideoMediaSDP(recvonly: true)]))
    server.onPlay = { [weak server] request, handle in
      let cseq = UInt8(truncatingIfNeeded: request.cseq ?? 0)
      guard let server, let setup = handle.setup(forStream: 0) else { return }
      let playCount = server.requests(method: "PLAY").count
      Task {
        var sequencer = RTPTestSequencer(parameters: setup.parameters)
        for index in 0..<(playCount == 1 ? 20 : 1200) {
          if playCount == 1 {
            sendReplayFrame(
              handle, &sequencer, time: recordingStart.addingTimeInterval(Double(index) * 0.1),
              keyframe: index % 10 == 0, cseq: cseq)
          } else {
            for packet in sequencer.accessUnit(
              h264AccessUnit(keyframe: index % 10 == 0), timestampIncrement: 9000)
            {
              guard handle.sendRTP(packet, stream: 0) else { return }
            }
          }
          if index % 20 == 19 { try? await Task.sleep(for: .milliseconds(1)) }
        }
      }
    }
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }
    let diagnostics = Diagnostics()
    let session = RTSPClientSession(
      url: server.url, transport: .tcp, onvif: .replay, onDiagnostic: { diagnostics.add($0) })
    _ = try await session.start(PlayOptions(range: .clock(start: recordingStart)))
    let (recorder, consumer) = record(session)
    defer { consumer.cancel() }
    #expect(await eventually { await recorder.videoFrames.count >= 20 })
    try await session.play(
      PlayOptions(range: .clock(start: recordingStart.addingTimeInterval(600)), immediate: true))
    #expect(
      await eventually { await recorder.videoFrames.filter { $0.replay == nil }.count >= 50 })
    await session.stop()
    #expect(diagnostics.all.filter { $0.contains("no longer filtering") }.count == 1)
  }

  @Test("The response to a seek that a newer seek replaced doesn't reseed sequence tracking")
  func supersededSeekResponseIgnored() async throws {
    let server = FakeRTSPServer(sdp: makeTestSDP(media: [h264VideoMediaSDP(recvonly: true)]))
    let seekTarget = recordingStart.addingTimeInterval(200)
    let plays = Box(0)
    server.transformResponse = { [weak server] request, response in
      guard request.method == "PLAY", let server, let handle = server.sessionHandles.first,
        let setup = handle.setup(forStream: 0)
      else { return response }
      plays.value += 1
      let initial = "seq=\(setup.parameters.initialSequence);"
      var response = response
      func setRTPInfoSequence(_ seq: UInt16) {
        response.headers = response.headers.map { header in
          guard header.name == "RTP-Info" else { return header }
          return (header.name, header.value.replacingOccurrences(of: initial, with: "seq=\(seq);"))
        }
      }
      switch plays.value {
      case 2:
        // The first seek's response comes late, after the second seek was sent.
        Thread.sleep(forTimeInterval: 0.3)
        setRTPInfoSequence(4950)
      case 3:
        // The second seek's packets go out ahead of its response.
        var sequencer = RTPTestSequencer(parameters: setup.parameters)
        sequencer.sequence = 5000
        let cseq = UInt8(truncatingIfNeeded: request.cseq ?? 0)
        for index in 0..<6 {
          sendReplayFrame(
            handle, &sequencer, time: seekTarget.addingTimeInterval(Double(index) * 0.1),
            keyframe: index == 0, cseq: cseq)
        }
        setRTPInfoSequence(5000)
      default:
        break
      }
      return response
    }
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }

    let session = RTSPClientSession(url: server.url, onvif: .replay)
    _ = try await session.start(PlayOptions(range: .clock(start: recordingStart)))
    let (recorder, consumer) = record(session)
    defer { consumer.cancel() }

    let firstSeek = Task {
      try await session.play(
        PlayOptions(range: .clock(start: recordingStart.addingTimeInterval(100)), immediate: true))
    }
    try await Task.sleep(for: .milliseconds(100))
    try await session.play(PlayOptions(range: .clock(start: seekTarget), immediate: true))
    try await firstSeek.value
    #expect(
      await eventually {
        await recorder.videoFrames.filter { ($0.replay?.time ?? .distantPast) >= seekTarget }
          .count >= 6
      })
    let frames = await recorder.videoFrames
    let losses = frames.filter { ($0.replay?.time ?? .distantPast) >= seekTarget }.map(\.loss)
    #expect(losses == [0, 0, 0, 0, 0, 0])
    await session.stop()
  }

  @Test("pause() and play() go through while frames() is iterated, and without it")
  func pauseAndResume() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onPlay = { _, handle in
      guard let setup = handle.setup(forStream: 0) else { return }
      Task {
        var sequencer = RTPTestSequencer(parameters: setup.parameters)
        for index in 0..<50 {
          for packet in sequencer.accessUnit(
            h264AccessUnit(keyframe: index % 10 == 0), timestampIncrement: 6000)
          {
            guard handle.sendRTP(packet, stream: 0) else { return }
          }
          try? await Task.sleep(for: .milliseconds(10))
        }
      }
    }
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }

    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    // No reader yet: requests read their own responses.
    try await session.pause()
    try await session.play(PlayOptions())

    let (recorder, consumer) = record(session)
    defer { consumer.cancel() }
    #expect(await eventually { await recorder.videoFrames.count >= 5 })
    try await session.pause()
    try await session.play(PlayOptions(scale: 0.5))

    let plays = server.requests(method: "PLAY")
    #expect(plays.count == 3)
    #expect(plays.first?.range == "npt=0.000-")
    #expect(plays.count == 3 && plays[1].range == nil)
    #expect(plays.count == 3 && plays[2].scale == "0.5")
    #expect(plays.allSatisfy { $0.requireTags.isEmpty })
    #expect(server.requests(method: "PAUSE").count == 2)
    #expect(server.requests(method: "PAUSE").allSatisfy { $0.sessionID != nil })

    // A server rejection surfaces as sessionSetupFailed.
    server.onRequest = { request in
      request.method == "PAUSE" ? FakeRTSPResponse(statusCode: 455) : nil
    }
    await #expect(throws: RTSPError.self) { try await session.pause() }

    let start = ContinuousClock.now
    await session.stop()
    #expect(ContinuousClock.now - start < .seconds(3))
    await #expect(throws: RTSPError.self) { try await session.pause() }
  }

  @Test("Rate-Control: no — a stalled consumer loses nothing and control requests still work")
  func backpressure() async throws {
    let frameCount = 1500
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onPlay = { request, handle in
      guard request.range != nil, let setup = handle.setup(forStream: 0) else { return }
      Task {
        var sequencer = RTPTestSequencer(parameters: setup.parameters)
        let slice = Data([0x41]) + Data(repeating: 0x9A, count: 1200)
        for index in 0..<frameCount {
          let nalus = index == 0 ? h264AccessUnit(keyframe: true) : [slice]
          for packet in sequencer.accessUnit(nalus, timestampIncrement: 3000) {
            guard handle.sendRTP(packet, stream: 0) else { return }
          }
        }
      }
    }
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(40))
    defer {
      watchdog.cancel()
      server.stop()
    }

    let session = RTSPClientSession(url: server.url, onvif: .replay)
    _ = try await session.start(PlayOptions(range: .npt(start: 0), rateControl: false))
    #expect(server.requests(method: "PLAY").first?.rateControl == "no")

    let received = Box(0)
    let losses = Box(0)
    let stalled = Box(false)
    let consumer = Task {
      for try await item in session.frames() {
        guard case .video(let frame) = item else { continue }
        received.value += 1
        losses.value += Int(frame.loss)
        if received.value == 10 {
          stalled.value = true
          // Stall long enough for the queue to fill and the reader to stop.
          try await Task.sleep(for: .seconds(1))
          stalled.value = false
        }
        if received.value == frameCount { break }
      }
    }
    defer { consumer.cancel() }

    #expect(await eventually { stalled.value })
    // The reader has to read past the queued frames to find this response.
    try await session.pause()
    #expect(await eventually(timeout: .seconds(15)) { received.value == frameCount })
    #expect(losses.value == 0)
    await session.stop()
  }

  @Test("A new frames() call continues the stream after the previous consumer stops")
  func framesAfterConsumerStops() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onPlay = { _, handle in
      guard let setup = handle.setup(forStream: 0) else { return }
      Task {
        var sequencer = RTPTestSequencer(parameters: setup.parameters)
        for index in 0..<200 {
          for packet in sequencer.accessUnit(
            h264AccessUnit(keyframe: index % 5 == 0), timestampIncrement: 6000)
          {
            guard handle.sendRTP(packet, stream: 0) else { return }
          }
          try? await Task.sleep(for: .milliseconds(5))
        }
      }
    }
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }

    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    var first = 0
    for try await item in session.frames() {
      if case .video = item { first += 1 }
      if first == 3 { break }
    }
    // The first sequence's iterator is gone; its release reaches the session
    // asynchronously, so retry briefly.
    var second = 0
    #expect(
      await eventually {
        do {
          for try await item in session.frames() {
            if case .video = item { second += 1 }
            if second == 3 { break }
          }
          return second == 3
        } catch {
          return false
        }
      })
    await session.stop()
  }

  // MARK: - Backchannel

  private func backchannelServer() -> FakeRTSPServer {
    var configuration = FakeRTSPServer.Configuration(sdp: onvifBackchannelSDP())
    configuration.sdpWithoutBackchannel = onvifBackchannelSDP(includeBackchannel: false)
    return FakeRTSPServer(configuration: configuration)
  }

  @Test("While paused over TCP, nothing is sent on the interleaved channels")
  func pausedSessionSendsNoInterleavedData() async throws {
    let server = backchannelServer()
    server.configuration.includeRTPInfo = false
    // Video on every PLAY, so the client has receptions to report.
    server.onPlay = { _, handle in
      guard let setup = handle.setup(forStream: 0) else { return }
      var sequencer = RTPTestSequencer(parameters: setup.parameters)
      for packet in sequencer.accessUnit(h264AccessUnit(keyframe: true), timestampIncrement: 0) {
        handle.sendRTP(packet, stream: 0)
      }
    }
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }

    let session = RTSPClientSession(
      url: server.url, credentials: nil, transport: .tcp, onvif: .backchannel,
      userAgent: "IPCamKit", onDiagnostic: nil, keepaliveInterval: nil,
      receiverReportInterval: .milliseconds(50))
    _ = try await session.start()
    let reports = await server.waitForReceivedMedia(where: { $0.isRTCP }, count: 2)
    try #require(reports.count == 2, "no receiver reports before PAUSE")

    try await session.pause()
    // The server reads in order: anything sent before PAUSE is recorded by now.
    let beforePause = server.receivedMedia.count
    await #expect(throws: RTSPError.self) {
      try await session.sendBackchannelAudio(Data(repeating: 0xFF, count: 160))
    }
    try await Task.sleep(for: .milliseconds(400))
    #expect(server.receivedMedia.count == beforePause, "interleaved data sent while paused")

    try await session.play(PlayOptions())
    let resumed = await server.waitForReceivedMedia(
      where: { $0.isRTCP }, count: beforePause + 1)
    #expect(resumed.count > beforePause, "receiver reports resume after PLAY")
    try await session.sendBackchannelAudio(Data(repeating: 0xFF, count: 160))
    await session.stop()
  }

  @Test("A PLAY answered after a later PAUSE was sent leaves the session paused")
  func playAnsweredAfterPause() async throws {
    let server = backchannelServer()
    server.configuration.includeRTPInfo = false
    server.onPlay = { _, handle in
      guard let setup = handle.setup(forStream: 0) else { return }
      var sequencer = RTPTestSequencer(parameters: setup.parameters)
      for packet in sequencer.accessUnit(h264AccessUnit(keyframe: true), timestampIncrement: 0) {
        handle.sendRTP(packet, stream: 0)
      }
    }
    let plays = Box(0)
    let secondPlayArrived = Box(false)
    server.transformResponse = { request, response in
      guard request.method == "PLAY" else { return response }
      plays.value += 1
      if plays.value == 2 {
        secondPlayArrived.value = true
        Thread.sleep(forTimeInterval: 0.3)
      }
      return response
    }
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }

    let session = RTSPClientSession(
      url: server.url, credentials: nil, transport: .tcp, onvif: .backchannel,
      userAgent: "IPCamKit", onDiagnostic: nil, keepaliveInterval: nil,
      receiverReportInterval: .milliseconds(50))
    _ = try await session.start()
    let reports = await server.waitForReceivedMedia(where: { $0.isRTCP }, count: 2)
    try #require(reports.count == 2, "no receiver reports before PAUSE")

    let player = Task { try await session.play(PlayOptions(scale: 2)) }
    #expect(await eventually { secondPlayArrived.value })
    try await session.pause()
    try await player.value
    #expect(server.requests.map(\.method).suffix(3) == ["PLAY", "PLAY", "PAUSE"])
    let before = server.receivedMedia.filter(\.isRTCP).count
    await #expect(throws: RTSPError.self) {
      try await session.sendBackchannelAudio(Data(repeating: 0xFF, count: 160))
    }
    try await Task.sleep(for: .milliseconds(400))
    #expect(server.receivedMedia.filter(\.isRTCP).count == before, "reports sent while paused")
    await session.stop()
  }

  @Test("A rejected seek loses none of the playback in flight and keeps its timestamps")
  func rejectedSeekKeepsPlayback() async throws {
    let server = FakeRTSPServer(sdp: makeTestSDP(media: [h264VideoMediaSDP(recvonly: true)]))
    let sequencer = Box<RTPTestSequencer?>(nil)
    let playCSeq = Box<UInt8>(0)
    let frameIndex = Box(0)
    @Sendable func sendFrames(_ handle: FakeRTSPSessionHandle, count: Int) {
      guard var current = sequencer.value else { return }
      for _ in 0..<count {
        let index = frameIndex.value
        sendReplayFrame(
          handle, &current, time: recordingStart.addingTimeInterval(Double(index) * 0.1),
          keyframe: index == 0, cseq: playCSeq.value)
        frameIndex.value = index + 1
      }
      sequencer.value = current
    }
    server.onPlay = { request, handle in
      guard let setup = handle.setup(forStream: 0) else { return }
      playCSeq.value = UInt8(truncatingIfNeeded: request.cseq ?? 0)
      sequencer.value = RTPTestSequencer(parameters: setup.parameters)
      sendFrames(handle, count: 10)
    }
    let plays = Box(0)
    server.onRequest = { [weak server] request in
      guard request.method == "PLAY" else { return nil }
      plays.value += 1
      guard plays.value == 2, let handle = server?.sessionHandles.first else { return nil }
      // The playback continues around the rejected seek's response.
      sendFrames(handle, count: 5)
      Task.detached {
        try? await Task.sleep(for: .milliseconds(100))
        sendFrames(handle, count: 5)
      }
      return FakeRTSPResponse(statusCode: 457)
    }
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }

    let session = RTSPClientSession(url: server.url, onvif: .replay)
    _ = try await session.start(PlayOptions(range: .clock(start: recordingStart)))
    let (recorder, consumer) = record(session)
    defer { consumer.cancel() }
    #expect(await eventually { await recorder.videoFrames.count == 10 })
    await #expect(throws: RTSPError.self) {
      try await session.play(
        PlayOptions(range: .clock(start: recordingStart.addingTimeInterval(500)), immediate: true))
    }
    #expect(await eventually { await recorder.videoFrames.count == 20 })
    let frames = await recorder.videoFrames
    #expect(frames.count == 20)
    #expect(frames.allSatisfy { $0.loss == 0 })
    let steps = zip(frames.dropFirst(), frames).map { $0.timestamp - $1.timestamp }
    #expect(steps.allSatisfy { abs($0 - 0.1) < 0.0001 }, "\(steps)")
    await session.stop()
  }

  @Test("A backchannel format the packetizer can't send sets nothing up")
  func unusableBackchannelNotSetUp() async throws {
    let backchannel = [
      "m=audio 0 RTP/AVP 97", "a=rtpmap:97 MPEG4-GENERIC/16000/1",
      "a=fmtp:97 streamtype=5; mode=AAC-hbr; bogus", "a=control:audioback", "a=sendonly",
    ].map { $0 + "\r\n" }.joined()
    let server = FakeRTSPServer(
      sdp: makeTestSDP(media: [h264VideoMediaSDP(recvonly: true), backchannel]))
    try await server.start()
    defer { server.stop() }
    let diagnostics = Diagnostics()
    let session = RTSPClientSession(
      url: server.url, onvif: .backchannel, onDiagnostic: { diagnostics.add($0) })
    let desc = try await session.start()
    #expect(desc.backchannel == nil)
    #expect(!server.requests(method: "SETUP").contains { $0.url.hasSuffix("audioback") })
    #expect(diagnostics.all.contains { $0.contains("backchannel format can't be sent") })
    await session.stop()
  }

  @Test("A backchannel the packetizer can't send gives way to the next one it can")
  func unusableBackchannelSkipped() async throws {
    let unusable = [
      "m=audio 0 RTP/AVP 97", "a=rtpmap:97 MPEG4-GENERIC/16000/1",
      "a=fmtp:97 streamtype=5; mode=AAC-hbr; bogus", "a=control:audioback", "a=sendonly",
    ].map { $0 + "\r\n" }.joined()
    let server = FakeRTSPServer(
      sdp: makeTestSDP(media: [
        h264VideoMediaSDP(recvonly: true), unusable,
        pcmuAudioMediaSDP(control: "audioback2", direction: "sendonly"),
      ]))
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url, onvif: .backchannel)
    let desc = try await session.start()
    #expect(desc.backchannel?.codec == .pcmu)
    let setups = server.requests(method: "SETUP").map(\.url)
    #expect(setups.contains { $0.hasSuffix("audioback2") }, "\(setups)")
    #expect(!setups.contains { $0.hasSuffix("audioback") }, "\(setups)")
    await session.stop()
  }

  /// Some cameras list their backchannel even when not asked for it.
  @Test("Without .backchannel, the received audio is not the camera's backchannel")
  func receiveAudioSkipsBackchannel() async throws {
    let server = FakeRTSPServer(
      sdp: makeTestSDP(media: [
        h264VideoMediaSDP(recvonly: true),
        pcmuAudioMediaSDP(control: "audioback", direction: "sendonly"),
        pcmuAudioMediaSDP(control: "audio", direction: "recvonly"),
      ]))
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    let desc = try await session.start()
    #expect(desc.audio != nil)
    let setups = server.requests(method: "SETUP").map(\.url)
    #expect(setups.contains { $0.hasSuffix("/audio") })
    #expect(!setups.contains { $0.hasSuffix("audioback") }, "\(setups)")
    await session.stop()
  }

  /// The first of two overlapping seeks is accepted and its playback is held
  /// while the second is outstanding; the second is rejected only after
  /// stop(). Adopting the first seek then must not turn its held packets
  /// into frames.
  @Test(
    "Overlapping seeks: nothing is delivered when the first is adopted after stop()",
    .timeLimit(.minutes(1)), arguments: [Transport.tcp, .udp])
  func adoptedSeekAfterStop(transport: Transport) async throws {
    let server = FakeRTSPServer(sdp: makeTestSDP(media: [h264VideoMediaSDP(recvonly: true)]))
    server.configuration.includeRTPInfo = false
    let playCSeqs = Box<[Int]>([])
    @Sendable func sendFrames(_ handle: FakeRTSPSessionHandle, from start: UInt16, cseq: Int) {
      guard let setup = handle.setup(forStream: 0) else { return }
      var sequencer = RTPTestSequencer(parameters: setup.parameters)
      sequencer.sequence = start
      for frame in 0..<5 {
        sendReplayFrame(
          handle, &sequencer, time: recordingStart.addingTimeInterval(Double(frame) * 0.1),
          keyframe: frame == 0, cseq: UInt8(truncatingIfNeeded: cseq))
      }
    }
    server.onRequest = { [weak server] request in
      guard request.method == "PLAY", let handle = server?.sessionHandles.first else { return nil }
      playCSeqs.value.append(request.cseq ?? 0)
      switch playCSeqs.value.count {
      case 2:
        // The first seek is accepted, late.
        Thread.sleep(forTimeInterval: 0.3)
        return nil
      case 3:
        // Its playback runs while the second seek waits for an answer, which
        // comes after the client's stop().
        sendFrames(handle, from: 5000, cseq: playCSeqs.value[1])
        Thread.sleep(forTimeInterval: 0.8)
        return FakeRTSPResponse(statusCode: 457)
      default:
        return nil
      }
    }
    server.onPlay = { request, handle in
      if playCSeqs.value.count == 1 { sendFrames(handle, from: 1000, cseq: request.cseq ?? 0) }
    }
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }

    let session = RTSPClientSession(url: server.url, transport: transport, onvif: .replay)
    _ = try await session.start(PlayOptions(range: .clock(start: recordingStart)))
    let (recorder, consumer) = record(session)
    defer { consumer.cancel() }
    #expect(await eventually { await recorder.videoFrames.count == 5 })
    let first = Task {
      try await session.play(
        PlayOptions(range: .clock(start: recordingStart.addingTimeInterval(100)), immediate: true))
    }
    try await Task.sleep(for: .milliseconds(80))
    let second = Task {
      try await session.play(
        PlayOptions(range: .clock(start: recordingStart.addingTimeInterval(200)), immediate: true))
    }
    try await Task.sleep(for: .milliseconds(500))
    let atStop = await recorder.videoFrames.count
    await session.stop()
    _ = await first.result
    _ = await second.result
    _ = await consumer.value
    let delivered = await recorder.videoFrames.count
    #expect(delivered == atStop, "\(atStop) at stop(), \(delivered) delivered")
  }

  /// A scrubbing UI sends a second seek before the first is answered; the
  /// server accepts the first and rejects the second. It then plays from the
  /// first seek's position, which must start cleanly, not continue the
  /// playback from before both seeks. With a speed change sent between the
  /// seeks, the server's packets carry the speed change's CSeq.
  @Test(
    "Overlapping seeks: the first accepted, the second rejected, the first's playback starts",
    arguments: [false, true])
  func overlappingSeeksSecondRejected(speedChangeBetween: Bool) async throws {
    let server = FakeRTSPServer(sdp: makeTestSDP(media: [h264VideoMediaSDP(recvonly: true)]))
    let playCSeqs = Box<[Int]>([])
    let seekStart = recordingStart.addingTimeInterval(100)
    // PLAY requests: the initial one, the first seek, [the speed change,]
    // the second seek.
    let rejected = speedChangeBetween ? 4 : 3
    server.onRequest = { request in
      guard request.method == "PLAY" else { return nil }
      playCSeqs.value.append(request.cseq ?? 0)
      switch playCSeqs.value.count {
      case 2:
        // The first seek is answered late, after the second was sent.
        Thread.sleep(forTimeInterval: 0.3)
        return nil
      case rejected: return FakeRTSPResponse(statusCode: 457)
      default: return nil
      }
    }
    server.transformResponse = { request, response in
      guard request.method == "PLAY", playCSeqs.value.count == 2 else { return response }
      var response = response
      response.headers = response.headers.map { header in
        guard header.name == "RTP-Info" else { return header }
        return (header.name, header.value.replacingOccurrences(of: "seq=1000;", with: "seq=5000;"))
      }
      return response
    }
    server.onPlay = { request, handle in
      guard let setup = handle.setup(forStream: 0),
        let index = playCSeqs.value.firstIndex(of: request.cseq ?? -1)
      else { return }
      // The new position's frames go out tagged with the PLAY in effect: the
      // first seek, or the speed change sent after it.
      let isNewPosition = index == (speedChangeBetween ? 2 : 1)
      guard index == 0 || isNewPosition else { return }
      var sequencer = RTPTestSequencer(parameters: setup.parameters)
      if isNewPosition { sequencer.sequence = 5000 }
      for frame in 0..<10 {
        sendReplayFrame(
          handle, &sequencer,
          time: (isNewPosition ? seekStart : recordingStart).addingTimeInterval(
            Double(frame) * 0.1),
          keyframe: frame == 0, cseq: UInt8(truncatingIfNeeded: request.cseq ?? 0))
      }
    }
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }

    let session = RTSPClientSession(url: server.url, onvif: .replay)
    _ = try await session.start(PlayOptions(range: .clock(start: recordingStart)))
    let (recorder, consumer) = record(session)
    defer { consumer.cancel() }
    #expect(await eventually { await recorder.videoFrames.count == 10 })
    let first = Task {
      try await session.play(PlayOptions(range: .clock(start: seekStart), immediate: true))
    }
    try await Task.sleep(for: .milliseconds(50))
    let speedChange = Task {
      if speedChangeBetween { try await session.play(PlayOptions(scale: 2)) }
    }
    try await Task.sleep(for: .milliseconds(50))
    await #expect(throws: RTSPError.self) {
      try await session.play(
        PlayOptions(range: .clock(start: recordingStart.addingTimeInterval(9999)), immediate: true))
    }
    try await first.value
    try await speedChange.value
    #expect(await eventually { await recorder.videoFrames.count == 20 })
    let frames = await recorder.videoFrames
    let after = frames.dropFirst(10)
    #expect(after.allSatisfy { $0.loss == 0 }, "\(after.map(\.loss))")
    let times = frames.map(\.timestamp)
    #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 }, "\(times)")
    let firstTime = try #require(after.first?.replay?.time)
    #expect(abs(firstTime.timeIntervalSince(seekStart)) < 0.001)
    await session.stop()
  }

  /// The replay extension carries only the low byte of the PLAY's CSeq.
  /// A seek whose CSeq shares it with the PLAY still streaming would let that
  /// playback's packets through as the seek's.
  @Test("A PLAY's CSeq skips the low byte of a recent PLAY once packets carry replay tags")
  func playCSeqSkipsRecentLowBytes() async throws {
    let server = FakeRTSPServer(sdp: makeTestSDP(media: [h264VideoMediaSDP(recvonly: true)]))
    server.onPlay = { request, handle in
      guard let setup = handle.setup(forStream: 0) else { return }
      var sequencer = RTPTestSequencer(parameters: setup.parameters)
      for index in 0..<3 {
        sendReplayFrame(
          handle, &sequencer, time: recordingStart.addingTimeInterval(Double(index)),
          keyframe: index == 0, cseq: UInt8(truncatingIfNeeded: request.cseq ?? 0))
      }
    }
    let initialPlay = Box<Int?>(nil)
    let held = Box(false)
    server.onRequest = { request in
      if request.method == "PLAY", initialPlay.value == nil { initialPlay.value = request.cseq }
      // Keepalives run every millisecond. The one just before the CSeq that
      // shares the initial PLAY's low byte is answered late, so the next
      // request is the seek.
      if request.method != "PLAY", let first = initialPlay.value, request.cseq == first + 255 {
        held.value = true
        Thread.sleep(forTimeInterval: 0.5)
      }
      return nil
    }
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }
    let session = RTSPClientSession(
      url: server.url, credentials: nil, transport: .tcp, onvif: .replay, userAgent: "IPCamKit",
      onDiagnostic: nil, keepaliveInterval: .milliseconds(1))
    _ = try await session.start(PlayOptions(range: .clock(start: recordingStart)))
    let (recorder, consumer) = record(session)
    defer { consumer.cancel() }
    #expect(await eventually { await recorder.videoFrames.count == 3 })
    #expect(await eventually(timeout: .seconds(10)) { held.value })
    try await session.play(
      PlayOptions(range: .clock(start: recordingStart.addingTimeInterval(500)), immediate: true))
    let plays = server.requests.filter { $0.method == "PLAY" }.compactMap(\.cseq)
    let first = try #require(plays.first)
    let seek = try #require(plays.last)
    #expect(seek > first + 255)
    #expect(seek & 0xFF != first & 0xFF, "seek CSeq \(seek), initial PLAY \(first)")
    await session.stop()
  }

  @Test(
    "Backchannel: the sendonly stream is set up and audio arrives as RTP",
    arguments: [Transport.tcp, .udp])
  func backchannelSendsAudio(transport: Transport) async throws {
    let server = backchannelServer()
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }

    let session = RTSPClientSession(url: server.url, transport: transport, onvif: .backchannel)
    let desc = try await session.start()
    let back = try #require(desc.backchannel)
    #expect(back.codec == .pcmu)
    #expect(back.clockRate == 8000)
    #expect(back.payloadType == 0)
    // The receive-side audio is the recvonly stream, not the backchannel.
    #expect(desc.audio?.codec == .pcmu)
    #expect(desc.video?.codec == .h264)

    let setups = server.requests(method: "SETUP")
    #expect(setups.map(\.url).contains(server.controlURL("audioback")))
    #expect(
      setups.allSatisfy { $0.requireTags == ["www.onvif.org/ver20/backchannel"] })
    #expect(
      server.requests(method: "DESCRIBE").first?.requireTags == [
        "www.onvif.org/ver20/backchannel"
      ])

    let tone = (0..<320).map { Int16(truncatingIfNeeded: ($0 * 977) % 20000 - 10000) }
    let chunks = [G711.encodeMuLaw(Array(tone[0..<160])), G711.encodeMuLaw(Array(tone[160...]))]
    for chunk in chunks {
      try await session.sendBackchannelAudio(chunk)
    }

    let media = await server.waitForReceivedMedia(
      where: { $0.stream == 3 && !$0.isRTCP }, count: 2)
    #expect(media.count == 2)
    let packets = media.compactMap { record -> RawRTPPacket? in
      if case .success(let packet) = RawRTPPacket.parse(record.data) { return packet }
      return nil
    }
    #expect(packets.count == 2)
    if packets.count == 2 {
      #expect(packets.allSatisfy { $0.payloadType == 0 })
      #expect(packets[1].sequenceNumber == packets[0].sequenceNumber &+ 1)
      #expect(packets[1].rtpTimestamp == packets[0].rtpTimestamp &+ 160)
      #expect(packets[0].ssrc == packets[1].ssrc)
      #expect(packets.map(\.payload) == chunks)
    }
    switch transport {
    case .tcp:
      #expect(media.allSatisfy { if case .interleaved = $0.path { true } else { false } })
    default:
      #expect(media.allSatisfy { if case .udp = $0.path { true } else { false } })
      // The UDP hole-punch receiver report comes from the same participant:
      // one SSRC for its RTCP and its backchannel RTP (RFC 3550 section 8).
      let reports = await server.waitForReceivedMedia(where: { $0.isRTCP }, count: 1)
      let report = try #require(reports.first?.data)
      try #require(report.count >= 8)
      let reportSSRC = report.dropFirst(4).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
      #expect(packets.first?.ssrc == reportSSRC)
    }
    await session.stop()
  }

  @Test("Backchannel: a new talkspurt is marked and keeps the pause in the timestamps")
  func backchannelTalkspurt() async throws {
    let server = backchannelServer()
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }

    let session = RTSPClientSession(url: server.url, onvif: .backchannel)
    _ = try await session.start()
    let chunk = Data(repeating: 0xFF, count: 160)  // 20 ms of G.711 silence
    try await session.sendBackchannelAudio(chunk)
    try await Task.sleep(for: .milliseconds(500))
    try await session.sendBackchannelAudio(chunk, startsTalkspurt: true)
    try await session.sendBackchannelAudio(chunk)

    let media = await server.waitForReceivedMedia(
      where: { $0.stream == 3 && !$0.isRTCP }, count: 3)
    let packets = media.compactMap { try? RawRTPPacket.parse($0.data).get() }
    try #require(packets.count == 3)
    #expect(packets.map(\.mark) == [true, true, false])
    #expect(packets.map(\.sequenceNumber) == [0, 1, 2].map { packets[0].sequenceNumber &+ $0 })
    // The pause (about 500 ms, minus the 20 ms already sent) shows up as a gap.
    let gap = packets[1].rtpTimestamp &- packets[0].rtpTimestamp
    #expect(gap >= 160 + 3000 && gap <= 160 + 8000, "gap \(gap)")
    #expect(packets[2].rtpTimestamp &- packets[1].rtpTimestamp == 160)
    await session.stop()
  }

  @Test(
    "Backchannel: a talkspurt skips the silence beyond the audio sent, however long",
    arguments: [
      // 500 ms at 8 kHz after 20 ms of audio.
      (Duration.milliseconds(500), UInt32(8000), UInt64(160), UInt32(3840)),
      // Audio sent ahead of real time: no skip.
      (Duration.milliseconds(10), UInt32(8000), UInt64(160), UInt32(0)),
      // 13 hours at 48 kHz: past 2^31 ticks.
      (Duration.seconds(13 * 3600), UInt32(48000), UInt64(0), UInt32(2_246_400_000)),
      // 25 hours at 48 kHz: past 2^32 ticks, modulo 2^32.
      (
        Duration.seconds(25 * 3600), UInt32(48000), UInt64(1000),
        UInt32(truncatingIfNeeded: UInt64(25 * 3600 * 48000) - 1000)
      ),
      // Audio sent for more than 2^32 ticks since the anchor.
      (
        Duration.seconds(25 * 3600 + 1), UInt32(48000), UInt64(25 * 3600 * 48000),
        UInt32(48000)
      ),
    ])
  func backchannelTalkspurtSkip(
    elapsed: Duration, clockRate: UInt32, sentTicks: UInt64, skip: UInt32
  ) {
    #expect(
      SessionState.talkspurtSkip(elapsed: elapsed, clockRate: clockRate, sentTicks: sentTicks)
        == skip)
  }

  @Test("Backchannel: a send in progress stops at pause() and throws")
  func backchannelSendStopsAtPause() async throws {
    let server = backchannelServer()
    let sentBeforePause = Box(-1)
    server.onRequest = { [weak server] request in
      if request.method == "PAUSE", let server {
        sentBeforePause.value =
          server.receivedMedia.filter { $0.stream == 3 && !$0.isRTCP }.count
      }
      return nil
    }
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }
    let session = RTSPClientSession(url: server.url, onvif: .backchannel)
    _ = try await session.start()
    // 2000 packets of G.711.
    let sender = Task {
      try await session.sendBackchannelAudio(Data(repeating: 0xFF, count: 160 * 2000))
    }
    _ = await server.waitForReceivedMedia(where: { $0.stream == 3 && !$0.isRTCP }, count: 5)
    try await session.pause()
    let result = await sender.result
    try await Task.sleep(for: .milliseconds(300))
    let total = server.receivedMedia.filter { $0.stream == 3 && !$0.isRTCP }.count
    #expect(total == sentBeforePause.value, "\(total - sentBeforePause.value) sent after PAUSE")
    guard case .failure(let error) = result, case .invalidState = error as? RTSPError else {
      Issue.record("expected RTSPError.invalidState, got \(result)")
      await session.stop()
      return
    }
    await session.stop()
  }

  @Test("Backchannel: a cancelled send stops and throws CancellationError")
  func backchannelSendStopsAtCancel() async throws {
    let server = backchannelServer()
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }
    let session = RTSPClientSession(url: server.url, onvif: .backchannel)
    _ = try await session.start()
    let isBackchannel: @Sendable (FakeRTSPReceivedMedia) -> Bool = { $0.stream == 3 && !$0.isRTCP }
    // Cancelled before the call: nothing is sent.
    let early = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await session.sendBackchannelAudio(Data(repeating: 0xFF, count: 160))
    }
    let earlyResult = await early.result
    #expect(throws: CancellationError.self) { try earlyResult.get() }
    // 2000 packets of G.711, cancelled once a few have arrived.
    let sender = Task {
      try await session.sendBackchannelAudio(Data(repeating: 0xFF, count: 160 * 2000))
    }
    _ = await server.waitForReceivedMedia(where: isBackchannel, count: 5)
    sender.cancel()
    let result = await sender.result
    #expect(throws: CancellationError.self) { try result.get() }
    try await Task.sleep(for: .milliseconds(300))
    let afterCancel = server.receivedMedia.filter(isBackchannel).count
    #expect(afterCancel < 2000, "\(afterCancel) packets sent")
    // The session still sends: the next chunk follows the cancelled one.
    try await session.sendBackchannelAudio(Data(repeating: 0xFF, count: 160))
    let media = await server.waitForReceivedMedia(where: isBackchannel, count: afterCancel + 1)
    #expect(media.count == afterCancel + 1)
    await session.stop()
  }

  @Test(
    "Backchannel: a call cancelled before sending uses no sequence number",
    .timeLimit(.minutes(1)))
  func cancelledSendUsesNoSequenceNumber() async throws {
    let server = backchannelServer()
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(50))
    defer {
      watchdog.cancel()
      server.stop()
    }
    let session = RTSPClientSession(url: server.url, onvif: .backchannel)
    _ = try await session.start()
    let chunk = Data(repeating: 0xFF, count: 160)  // one packet
    // Each call is cancelled at a random moment: it sends its packet, or
    // throws CancellationError having taken no sequence number. A taken but
    // unsent one shows up as a gap.
    var sent = 0
    var spin = 0
    for _ in 0..<20_000 {
      let task = Task { try await session.sendBackchannelAudio(chunk) }
      for value in 0..<Int.random(in: 0...400) { spin &+= value }
      task.cancel()
      switch await task.result {
      case .success: sent += 1
      case .failure(let error) where error is CancellationError: break
      case .failure(let error): Issue.record("unexpected \(error)")
      }
    }
    try await session.sendBackchannelAudio(chunk)
    sent += 1
    let media = await server.waitForReceivedMedia(
      where: { $0.stream == 3 && !$0.isRTCP }, count: sent, timeout: .seconds(20))
    let sequenceNumbers = media.compactMap {
      try? RawRTPPacket.parse($0.data).get().sequenceNumber
    }
    let gaps = zip(sequenceNumbers, sequenceNumbers.dropFirst()).filter { $1 &- $0 != 1 }
    #expect(sequenceNumbers.count == sent, "spin \(spin & 1)")
    #expect(gaps.isEmpty, "\(gaps.count) gaps")
    await session.stop()
  }

  @Test("Backchannel: a payload the codec can't carry throws RTSPError")
  func backchannelRejectsEmptyPayload() async throws {
    let server = backchannelServer()
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }
    let session = RTSPClientSession(url: server.url, onvif: .backchannel)
    _ = try await session.start()
    let result = await outcome { try await session.sendBackchannelAudio(Data()) }
    guard case .failure(let error) = result, case .invalidState = error as? RTSPError else {
      Issue.record("expected RTSPError.invalidState, got \(result)")
      await session.stop()
      return
    }
    await session.stop()
  }

  @Test("Backchannel: a 551 at DESCRIBE falls back to a session without it")
  func backchannelRejected() async throws {
    var configuration = FakeRTSPServer.Configuration(sdp: onvifBackchannelSDP())
    configuration.supportedFeatureTags = ["onvif-replay"]
    let server = FakeRTSPServer(configuration: configuration)
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }

    let diagnostics = Diagnostics()
    let session = RTSPClientSession(
      url: server.url, onvif: .backchannel, onDiagnostic: diagnostics.add)
    let desc = try await session.start()
    #expect(desc.backchannel == nil)
    #expect(desc.video != nil)
    #expect(diagnostics.all.contains { $0.contains("551") })
    let describes = server.requests(method: "DESCRIBE")
    #expect(describes.count == 2)
    #expect(describes.last?.requireTags == [])
    // Without the backchannel, every request after the 551 drops the tag.
    #expect(server.requests(method: "SETUP").allSatisfy { $0.requireTags.isEmpty })
    await #expect(throws: RTSPError.self) {
      try await session.sendBackchannelAudio(Data(repeating: 0xFF, count: 160))
    }
    await session.stop()
  }

  @Test("Backchannel: a 551 for onvif-replay isn't reported as the backchannel's")
  func replayRejectedNotBlamedOnBackchannel() async throws {
    var configuration = FakeRTSPServer.Configuration(sdp: onvifBackchannelSDP())
    configuration.supportedFeatureTags = ["www.onvif.org/ver20/backchannel"]
    let server = FakeRTSPServer(configuration: configuration)
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }
    let diagnostics = Diagnostics()
    let session = RTSPClientSession(
      url: server.url, onvif: [.replay, .backchannel], onDiagnostic: diagnostics.add)
    let result = await outcome { try await session.start() }
    await session.stop()
    guard case .failure(let error) = result,
      case RTSPError.sessionSetupFailed(551, _) = error
    else {
      Issue.record("expected a 551, got \(result)")
      return
    }
    #expect(!diagnostics.all.contains { $0.contains("backchannel") }, "\(diagnostics.all)")
  }

  @Test("Backchannel: an SDP marking every stream sendonly has no backchannel")
  func allSendOnly() async throws {
    let sdp = makeTestSDP(
      media: [
        h264VideoMediaSDP() + "a=sendonly\r\n",
        pcmuAudioMediaSDP(direction: "sendonly"),
      ])
    let server = FakeRTSPServer(sdp: sdp)
    try await server.start()
    let watchdog = serverWatchdog(server, after: .seconds(30))
    defer {
      watchdog.cancel()
      server.stop()
    }

    let session = RTSPClientSession(url: server.url, onvif: .backchannel)
    let desc = try await session.start()
    #expect(desc.backchannel == nil)
    #expect(desc.video?.codec == .h264)
    #expect(desc.audio?.codec == .pcmu)
    await session.stop()
  }

  // MARK: - Metadata

  @Test("gzip metadata is decompressed into xml; EXI is passed through")
  func compressedMetadata() async throws {
    let xml = Data(
      #"<?xml version="1.0"?><tt:MetadataStream xmlns:tt="http://www.onvif.org/ver10/schema"/>"#
        .utf8)
    let compressed = try gzip(xml)
    for (encoding, payload, expectedXML) in [
      ("vnd.onvif.metadata.gzip", compressed, Optional(xml)),
      ("vnd.onvif.metadata.exi.onvif", Data([0x80, 0x40, 0x01, 0x02]), nil),
    ] {
      let sdp = makeTestSDP(media: [
        "m=application 0 RTP/AVP 107\r\na=rtpmap:107 \(encoding)/90000\r\n"
          + "a=control:metadata\r\na=recvonly\r\n"
      ])
      let server = FakeRTSPServer(sdp: sdp)
      server.onPlay = { _, handle in
        guard let setup = handle.setup(forStream: 0) else { return }
        var sequencer = RTPTestSequencer(parameters: setup.parameters, payloadType: 107)
        for packet in sequencer.accessUnit([payload], timestampIncrement: 9000) {
          handle.sendRTP(packet, stream: 0)
        }
      }
      try await server.start()
      defer { server.stop() }

      let session = RTSPClientSession(url: server.url)
      let desc = try await session.start()
      #expect(desc.metadataEncoding == encoding)
      let (recorder, consumer) = record(session)
      #expect(await eventually { await !recorder.metadataFrames.isEmpty })
      consumer.cancel()
      let frame = try #require(await recorder.metadataFrames.first)
      #expect(frame.encodingName == encoding)
      #expect(frame.data == payload)
      #expect(frame.xml == expectedXML)
      #expect(frame.replay == nil)
      await session.stop()
    }
  }

  @Test("A tunnel requires Transport.tcp")
  func tunnelNeedsTCP() async throws {
    let session = RTSPClientSession(
      url: "rtsp://127.0.0.1:9/stream", transport: .udp,
      tunnel: .http(URL(string: "http://127.0.0.1:9/stream")!))
    await #expect {
      try await session.start()
    } throws: { error in
      guard case .invalidState(let message) = error as? RTSPError else { return false }
      return message.contains("Transport.tcp")
    }
  }

  @Test("stop() without iterating frames() doesn't wait for a TEARDOWN timeout")
  func stopWithoutFrames() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    let start = ContinuousClock.now
    await session.stop()
    #expect(ContinuousClock.now - start < .seconds(2))
    #expect(await server.waitForRequest(method: "TEARDOWN") != nil)
  }
}
