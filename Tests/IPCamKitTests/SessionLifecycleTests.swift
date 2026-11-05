// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Session lifecycle against the fake server: who owns the connection, stop()
// during start(), cleanup after failures, frames() consumers, control
// requests (keepalive, re-authentication) and request hygiene.

import Foundation
import Testing

@testable import IPCamKit

/// Lock-protected value shared with server hooks and consumer tasks.
private final class Shared<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
  func update(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

/// Poll `condition` every 20 ms until it holds or `timeout` passes.
private func poll(
  _ timeout: Duration = .seconds(3), _ condition: @Sendable () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return await condition()
}

/// Stream `count` H.264 access units (a keyframe every 10th) on stream 0,
/// `interval` apart, continuing the stream's sequence numbers.
private func streamVideo(
  _ handle: FakeRTSPSessionHandle, count: Int, interval: Duration = .milliseconds(5),
  parameters: FakeRTPStreamParameters? = nil
) {
  guard let setup = handle.setup(forStream: 0) else { return }
  let params = parameters ?? setup.parameters
  Task.detached {
    var sequencer = RTPTestSequencer(parameters: params)
    for index in 0..<count {
      for packet in sequencer.accessUnit(
        h264AccessUnit(keyframe: index % 10 == 0), timestampIncrement: 3000)
      {
        guard handle.sendRTP(packet, stream: 0) else { return }
      }
      try? await Task.sleep(for: interval)
    }
  }
}

private func isInvalidState(_ error: any Error) -> Bool {
  if case .invalidState = error as? RTSPError { return true }
  return false
}

@Suite("Session lifecycle")
struct SessionLifecycleTests {
  // MARK: Connection ownership

  @Test("A seek sent before frames() is iterated completes, and no media is lost")
  func seekBeforeFrames() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    // The server keeps sending the same RTP stream after the seek, so an
    // RTP-Info naming its initial sequence number would read as loss.
    server.configuration.includeRTPInfo = false
    let plays = Shared(0)
    server.onRequest = { request in
      if request.method == "PLAY" {
        plays.update { $0 += 1 }
        // Answer the seek late, while media keeps flowing.
        if plays.value == 2 { Thread.sleep(forTimeInterval: 0.3) }
      }
      return nil
    }
    server.onPlay = { _, handle in
      if plays.value == 1 { streamVideo(handle, count: 200, interval: .milliseconds(3)) }
    }
    try await server.start()
    defer { server.stop() }

    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    let seekDone = Shared(false)
    let seek = Task {
      try await session.play(PlayOptions(range: .npt(start: 5), immediate: true))
      seekDone.value = true
    }
    try await Task.sleep(for: .milliseconds(50))
    let loss = Shared(0)
    let frames = Shared(0)
    let consumer = Task {
      for try await item in session.frames() {
        guard case .video(let frame) = item else { continue }
        frames.update { $0 += 1 }
        loss.update { $0 += Int(frame.loss) }
      }
    }
    defer { consumer.cancel() }
    #expect(await poll { seekDone.value }, "play() did not complete")
    try await seek.value
    #expect(await poll { frames.value >= 150 })
    #expect(loss.value == 0)
    await session.stop()
  }

  @Test("Keepalives run while paused, before frames() is iterated")
  func keepaliveWithoutFrames() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: nil, transport: .tcp, userAgent: "IPCamKit",
      onDiagnostic: nil, keepaliveInterval: .milliseconds(100))
    _ = try await session.start()
    try await session.pause()
    #expect(await poll { server.requests(method: "GET_PARAMETER").count >= 2 })
    await session.stop()
  }

  @Test("Frames sent between start() and frames() reach the first consumer")
  func framesBeforeFirstConsumer() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onPlay = { _, handle in streamVideo(handle, count: 5, interval: .zero) }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    try await Task.sleep(for: .milliseconds(300))
    var first: PublicVideoFrame?
    for try await item in session.frames() {
      if case .video(let frame) = item {
        first = frame
        break
      }
    }
    #expect(first?.isKeyframe == true, "the first frame, a keyframe, was kept for the consumer")
    await session.stop()
  }

  @Test("Before the first frames() the reader keeps reading and the newest 256 frames wait")
  func firstConsumerGetsNewestFrames() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.configuration.includeRTPInfo = false
    server.onPlay = { _, handle in streamVideo(handle, count: 600, interval: .zero) }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: nil, transport: .tcp, userAgent: "IPCamKit",
      onDiagnostic: nil, keepaliveInterval: nil, receiverReportInterval: .milliseconds(50))
    _ = try await session.start()
    let setup = try #require(server.sessionHandles.first?.setup(forStream: 0))
    let initial = setup.parameters.initialSequence
    let packets = (0..<600).reduce(0) { $0 + h264AccessUnit(keyframe: $1 % 10 == 0).count }
    // The receiver reports show how far the session has read.
    let readAll = await poll(.seconds(5)) {
      server.receivedMedia.contains { media in
        media.isRTCP && media.data.count >= 32 && media.data[media.data.startIndex + 1] == 201
          && Self.reportedPackets(media.data, initialSequence: initial) >= packets
      }
    }
    #expect(readAll, "the session stopped reading before frames() was called")

    let consumer = Task {
      var seen: [PublicVideoFrame] = []
      for try await item in session.frames() {
        guard case .video(let frame) = item else { continue }
        seen.append(frame)
        if seen.count == 256 { break }
      }
      return seen
    }
    let frames = try await consumer.value
    // Frame i is at i/30 s: the queue held frames 344 to 599.
    let first = try #require(frames.first)
    #expect(abs(first.timestamp - 344.0 / 30) < 0.001, "first queued frame at \(first.timestamp) s")
    // The 344 dropped frames show in `loss`.
    #expect(first.loss == 344)
    #expect(frames.dropFirst().allSatisfy { $0.loss == 0 })
    await session.stop()
  }

  @Test("While a control response is awaited, queued frames stay under 64 MiB")
  func queueBoundedWhileResponsePending() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.configuration.includeRTPInfo = false
    let started = Shared(false)
    // Once streaming, keepalives are never answered: a response is always awaited.
    server.onRequest = { request in
      guard started.value, request.method == "GET_PARAMETER" || request.method == "OPTIONS"
      else { return nil }
      return FakeRTSPResponse(headers: [("CSeq", "999999")])
    }
    server.onPlay = { _, handle in streamVideo(handle, count: 1, interval: .zero) }
    try await server.start()
    defer { server.stop() }
    let diagnostics = Shared<[String]>([])
    let session = RTSPClientSession(
      url: server.url, credentials: nil, transport: .tcp, userAgent: "IPCamKit",
      onDiagnostic: { diagnostic in diagnostics.update { $0.append(diagnostic.message) } },
      keepaliveInterval: .milliseconds(100), receiverReportInterval: .milliseconds(100))
    _ = try await session.start()
    started.value = true

    let gate = Shared(false)
    let received = Shared(0)
    let consumer = Task {
      for try await item in session.frames() {
        guard case .video = item else { continue }
        received.update { $0 += 1 }
        while !gate.value { try await Task.sleep(for: .milliseconds(10)) }
      }
    }
    defer { consumer.cancel() }
    #expect(await poll { received.value == 1 })
    _ = await server.waitForRequests(where: { $0.method != "PLAY" && started.value }, count: 1)

    // 1600 frames of 60 kB (96 MB) while the consumer is stalled.
    let handle = try #require(server.sessionHandles.first)
    let setup = try #require(handle.setup(forStream: 0))
    var sequencer = RTPTestSequencer(parameters: setup.parameters)
    sequencer.sequence &+= UInt16(h264AccessUnit(keyframe: true).count)
    sequencer.timestamp &+= 3000
    var slice = Data([0x41])
    slice.append(Data(repeating: 0x9A, count: 60_000))
    for _ in 0..<1600 {
      for packet in sequencer.accessUnit([slice], timestampIncrement: 3000) {
        handle.sendRTP(packet, stream: 0)
      }
    }
    let lastSequence = sequencer.sequence &- 1
    let initial = setup.parameters.initialSequence
    let readAll = await poll(.seconds(10)) {
      server.receivedMedia.contains { media in
        media.isRTCP && media.data.count >= 32 && media.data[media.data.startIndex + 1] == 201
          && Self.reportedPackets(media.data, initialSequence: initial)
            >= Int(lastSequence &- initial) + 1
      }
    }
    #expect(readAll, "the session didn't read the stream while a response was pending")

    gate.value = true
    var previous = -1
    while received.value != previous {
      previous = received.value
      try await Task.sleep(for: .milliseconds(300))
    }
    // 64 MiB holds 1118 of these frames; before, all 1600 were queued.
    #expect(received.value <= 1 + 1119, "\(received.value) frames were queued")
    #expect(diagnostics.value.contains { $0.contains("dropping the oldest frames") })
    await session.stop()
  }

  @Test(
    "After a seek, the first frame with other parameter sets than the last delivered carries them")
  func seekReportsParameterSetsAgain() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())  // sprop: h264TestSPS/PPS
    server.configuration.includeRTPInfo = false
    let other = try #require(
      try H264Depacketizer(clockRate: 90000, formatSpecificParams: dahuaFmtp).parameters)
    let (spsB, ppsB) = (other.spsNAL, other.ppsNAL)
    let plays = Shared(0)
    server.onPlay = { _, handle in
      plays.update { $0 += 1 }
      let first = plays.value == 1
      guard let setup = handle.setup(forStream: 0) else { return }
      Task.detached {
        var sequencer = RTPTestSequencer(parameters: setup.parameters)
        if !first { sequencer.sequence &+= 100 }
        // The first playback uses other parameter sets in band; after the
        // seek the camera is back to the SDP's.
        let keyframe = first ? [spsB, ppsB, h264TestIDRSlice] : h264AccessUnit(keyframe: true)
        for index in 0..<5 {
          let unit = index == 0 ? keyframe : h264AccessUnit(keyframe: false)
          for packet in sequencer.accessUnit(unit, timestampIncrement: 3000) {
            handle.sendRTP(packet, stream: 0)
          }
        }
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    let desc = try await session.start()
    #expect(desc.video?.sps == h264TestSPS)
    let frames = Shared<[PublicVideoFrame]>([])
    let consumer = Task {
      for try await item in session.frames() {
        if case .video(let frame) = item { frames.update { $0.append(frame) } }
      }
    }
    defer { consumer.cancel() }
    #expect(await poll { frames.value.count == 5 })
    try await session.play(PlayOptions(range: .npt(start: 5), immediate: true))
    #expect(await poll { frames.value.count == 10 })
    let sps = frames.value.map(\.sps)
    #expect(sps == [spsB, nil, nil, nil, nil, h264TestSPS, nil, nil, nil, nil])
    await session.stop()
  }

  @Test("After a seek, frames still using the in-band parameter sets carry no notice")
  func seekKeepsInBandParameterSets() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())  // sprop: h264TestSPS/PPS
    server.configuration.includeRTPInfo = false
    let other = try #require(
      try H264Depacketizer(clockRate: 90000, formatSpecificParams: dahuaFmtp).parameters)
    let (spsB, ppsB) = (other.spsNAL, other.ppsNAL)
    let plays = Shared(0)
    server.onPlay = { _, handle in
      plays.update { $0 += 1 }
      let first = plays.value == 1
      guard let setup = handle.setup(forStream: 0) else { return }
      Task.detached {
        var sequencer = RTPTestSequencer(parameters: setup.parameters)
        if !first { sequencer.sequence &+= 100 }
        // In-band parameter sets B; after the seek the camera sends slices
        // (still B) before its next keyframe repeats B.
        for index in 0..<5 {
          let unit =
            first && index == 0 ? [spsB, ppsB, h264TestIDRSlice] : h264AccessUnit(keyframe: false)
          for packet in sequencer.accessUnit(unit, timestampIncrement: 3000) {
            handle.sendRTP(packet, stream: 0)
          }
        }
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    let frames = Shared<[PublicVideoFrame]>([])
    let consumer = Task {
      for try await item in session.frames() {
        if case .video(let frame) = item { frames.update { $0.append(frame) } }
      }
    }
    defer { consumer.cancel() }
    #expect(await poll { frames.value.count == 5 })
    try await session.play(PlayOptions(range: .npt(start: 5), immediate: true))
    #expect(await poll { frames.value.count == 10 })
    // Only the first keyframe's B is a change; the SDP's set is not reported
    // after the seek.
    #expect(frames.value.map(\.sps) == [spsB] + Array(repeating: nil, count: 9))
    await session.stop()
  }

  @Test("The first video frame of a later frames() sequence carries the parameter sets")
  func laterConsumerGetsParameterSets() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onPlay = { _, handle in
      streamVideo(handle, count: 400, interval: .milliseconds(2))
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    var firstRun: [PublicVideoFrame] = []
    for try await item in session.frames() {
      if case .video(let frame) = item { firstRun.append(frame) }
      if firstRun.count == 3 { break }
    }
    // The SDP's parameter sets are the description's: no notice.
    #expect(firstRun.allSatisfy { $0.sps == nil })
    var next: PublicVideoFrame?
    for try await item in session.frames() {
      if case .video(let frame) = item {
        next = frame
        break
      }
    }
    let frame = try #require(next)
    #expect(frame.sps == h264TestSPS)
    #expect(frame.pps == h264TestPPS)
    await session.stop()
  }

  @Test("A parameter-set change survives frames dropped before the first frames()")
  func droppedFrameKeepsParameterNotice() async throws {
    // No sprop: the parameter sets only arrive in band, with the first frame.
    let media = [
      "m=video 0 RTP/AVP 96", "a=rtpmap:96 H264/90000", "a=fmtp:96 packetization-mode=1",
      "a=control:video",
    ].map { $0 + "\r\n" }.joined()
    let server = FakeRTSPServer(sdp: makeTestSDP(media: [media]))
    server.configuration.includeRTPInfo = false
    server.onPlay = { _, handle in
      guard let setup = handle.setup(forStream: 0) else { return }
      Task.detached {
        var sequencer = RTPTestSequencer(parameters: setup.parameters)
        for index in 0..<300 {
          for packet in sequencer.accessUnit(
            h264AccessUnit(keyframe: index == 0), timestampIncrement: 3000)
          {
            handle.sendRTP(packet, stream: 0)
          }
        }
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    let desc = try await session.start()
    #expect(desc.video?.sps == nil)
    try await Task.sleep(for: .milliseconds(500))
    var first: PublicVideoFrame?
    for try await item in session.frames() {
      if case .video(let frame) = item {
        first = frame
        break
      }
    }
    // The frame that brought the parameter sets was dropped (only the newest
    // 256 are kept); the first one delivered carries them instead.
    let frame = try #require(first)
    #expect(!frame.isKeyframe)
    #expect(frame.sps == h264TestSPS)
    #expect(frame.pps == h264TestPPS)
    await session.stop()
  }

  @Test("G.722 reports a 16 kHz sample rate, not its 8000 RTP clock rate")
  func g722SampleRate() async throws {
    let audio = ["m=audio 0 RTP/AVP 9", "a=rtpmap:9 G722/8000", "a=control:audio"]
      .map { $0 + "\r\n" }.joined()
    let server = FakeRTSPServer(sdp: makeTestSDP(media: [h264VideoMediaSDP(), audio]))
    server.onPlay = { _, handle in
      guard let setup = handle.setup(forStream: 1) else { return }
      var sequencer = RTPTestSequencer(parameters: setup.parameters, payloadType: 9)
      for packet in sequencer.accessUnit(
        [Data(repeating: 0x55, count: 160)], timestampIncrement: 160)
      {
        handle.sendRTP(packet, stream: 1)
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    let desc = try await session.start()
    #expect(desc.audio?.codec == .g722)
    #expect(desc.audio?.sampleRate == 16000)
    // G.722 has no decoder configuration.
    #expect(desc.audio?.extraData == nil)
    var rate: UInt32?
    for try await item in session.frames() {
      if case .audio(let frame) = item {
        rate = frame.sampleRate
        break
      }
    }
    #expect(rate == 16000)
    await session.stop()
  }

  @Test("A seek response arriving after the new playback's first packets adds no loss")
  func seekResponseAfterNewPackets() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    let plays = Shared(0)
    let sequencer = Shared<RTPTestSequencer?>(nil)
    server.transformResponse = { [weak server] request, response in
      guard request.method == "PLAY", let server, let handle = server.sessionHandles.first,
        let setup = handle.setup(forStream: 0)
      else { return response }
      plays.update { $0 += 1 }
      guard plays.value == 2 else { return response }
      // The seek's first frames go out ahead of its response, whose RTP-Info
      // names the first of them.
      var next = RTPTestSequencer(parameters: setup.parameters)
      next.sequence = 5000
      for index in 0..<3 {
        for packet in next.accessUnit(
          h264AccessUnit(keyframe: index == 0), timestampIncrement: 3000)
        {
          handle.sendRTP(packet, stream: 0)
        }
      }
      sequencer.value = next
      var response = response
      let initial = "seq=\(setup.parameters.initialSequence);"
      response.headers = response.headers.map { header in
        guard header.name == "RTP-Info" else { return header }
        return (header.name, header.value.replacingOccurrences(of: initial, with: "seq=5000;"))
      }
      return response
    }
    server.onPlay = { _, handle in
      if plays.value == 1 {
        streamVideo(handle, count: 5, interval: .zero)
        return
      }
      guard var next = sequencer.value else { return }
      for _ in 0..<3 {
        for packet in next.accessUnit(h264AccessUnit(keyframe: false), timestampIncrement: 3000) {
          handle.sendRTP(packet, stream: 0)
        }
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    let frames = Shared<[PublicVideoFrame]>([])
    let consumer = Task {
      for try await item in session.frames() {
        if case .video(let frame) = item { frames.update { $0.append(frame) } }
      }
    }
    defer { consumer.cancel() }
    #expect(await poll { frames.value.count == 5 })
    try await session.play(PlayOptions(range: .npt(start: 5), immediate: true))
    #expect(await poll { frames.value.count == 11 })
    #expect(frames.value.dropFirst(5).map(\.loss) == [0, 0, 0, 0, 0, 0])
    await session.stop()
  }

  @Test("After a seek, audio and video of the same instant have the same timestamp")
  func seekKeepsStreamsAligned() async throws {
    let sdp = makeTestSDP(media: [h264VideoMediaSDP(), pcmuAudioMediaSDP(direction: nil)])
    let server = FakeRTSPServer(sdp: sdp)
    // Each PLAY restarts both streams at their RTP-Info values: 25 video
    // frames (0.83 s) and 55 audio packets (1.1 s).
    server.onPlay = { _, handle in
      guard let video = handle.setup(forStream: 0), let audio = handle.setup(forStream: 1) else {
        return
      }
      var videoSequencer = RTPTestSequencer(parameters: video.parameters)
      var audioSequencer = RTPTestSequencer(parameters: audio.parameters, payloadType: 0)
      for index in 0..<25 {
        for packet in videoSequencer.accessUnit(
          h264AccessUnit(keyframe: index == 0), timestampIncrement: 3000)
        {
          handle.sendRTP(packet, stream: 0)
        }
      }
      for _ in 0..<55 {
        for packet in audioSequencer.accessUnit(
          [Data(repeating: 0xFF, count: 160)], timestampIncrement: 160)
        {
          handle.sendRTP(packet, stream: 1)
        }
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    let video = Shared<[Double]>([])
    let audio = Shared<[Double]>([])
    let consumer = Task {
      for try await item in session.frames() {
        switch item {
        case .video(let frame): video.update { $0.append(frame.timestamp) }
        case .audio(let frame): audio.update { $0.append(frame.timestamp) }
        default: break
        }
      }
    }
    defer { consumer.cancel() }
    #expect(await poll { video.value.count == 25 && audio.value.count == 55 })
    #expect(video.value.first == 0 && audio.value.first == 0)
    try await session.play(PlayOptions(range: .npt(start: 30), immediate: true))
    #expect(await poll { video.value.count == 50 && audio.value.count == 110 })
    let firstVideo = try #require(video.value.dropFirst(25).first)
    let firstAudio = try #require(audio.value.dropFirst(55).first)
    #expect(abs(firstVideo - firstAudio) < 0.001, "video \(firstVideo) s, audio \(firstAudio) s")
    // After the end of both streams' previous playback.
    #expect(firstAudio >= 1.1)
    await session.stop()
  }

  @Test("After a seek whose video arrives before the response, audio starts with that video")
  func seekAlignedWithEarlyVideo() async throws {
    let sdp = makeTestSDP(media: [h264VideoMediaSDP(), pcmuAudioMediaSDP(direction: nil)])
    let server = FakeRTSPServer(sdp: sdp)
    let plays = Shared(0)
    // The seek's first 3 video frames go out ahead of its response.
    server.transformResponse = { [weak server] request, response in
      guard request.method == "PLAY", let server, let handle = server.sessionHandles.first,
        let video = handle.setup(forStream: 0)
      else { return response }
      plays.update { $0 += 1 }
      if plays.value == 2 {
        var sequencer = RTPTestSequencer(parameters: video.parameters)
        for index in 0..<3 {
          for packet in sequencer.accessUnit(
            h264AccessUnit(keyframe: index == 0), timestampIncrement: 3000)
          {
            handle.sendRTP(packet, stream: 0)
          }
        }
      }
      return response
    }
    // Each playback: 30 video frames (1 s), then 5 audio packets (0.1 s).
    server.onPlay = { _, handle in
      guard let video = handle.setup(forStream: 0), let audio = handle.setup(forStream: 1) else {
        return
      }
      let early = plays.value == 2 ? 3 : 0
      var videoSequencer = RTPTestSequencer(parameters: video.parameters)
      var audioSequencer = RTPTestSequencer(parameters: audio.parameters, payloadType: 0)
      for index in 0..<30 {
        let packets = videoSequencer.accessUnit(
          h264AccessUnit(keyframe: index == 0), timestampIncrement: 3000)
        guard index >= early else { continue }
        for packet in packets { handle.sendRTP(packet, stream: 0) }
      }
      for _ in 0..<5 {
        for packet in audioSequencer.accessUnit(
          [Data(repeating: 0xFF, count: 160)], timestampIncrement: 160)
        {
          handle.sendRTP(packet, stream: 1)
        }
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    let video = Shared<[Double]>([])
    let audio = Shared<[Double]>([])
    let consumer = Task {
      for try await item in session.frames() {
        switch item {
        case .video(let frame): video.update { $0.append(frame.timestamp) }
        case .audio(let frame): audio.update { $0.append(frame.timestamp) }
        default: break
        }
      }
    }
    defer { consumer.cancel() }
    #expect(await poll { video.value.count == 30 && audio.value.count == 5 })
    try await session.play(PlayOptions(range: .npt(start: 30), immediate: true))
    #expect(await poll { video.value.count == 60 && audio.value.count == 10 })
    let firstVideo = try #require(video.value.dropFirst(30).first)
    let firstAudio = try #require(audio.value.dropFirst(5).first)
    #expect(abs(firstVideo - firstAudio) < 0.001, "video \(firstVideo) s, audio \(firstAudio) s")
    await session.stop()
  }

  enum SeekAlignmentCase: String, CaseIterable, Sendable {
    /// The seek's first audio packets arrive ahead of its response.
    case earlyAudio
    /// Both streams' first packets arrive ahead of the response.
    case earlyBoth
    /// The response has no RTP-Info.
    case noRTPInfo
    /// The response's RTP-Info names only the video stream.
    case rtpInfoWithoutAudio
    /// Audio sent nothing before the seek, and the first PLAY's RTP-Info
    /// didn't name it.
    case audioSilentBefore
    /// Packets carry the ONVIF replay extension (so early ones aren't held);
    /// video's arrive early and RTP-Info names only audio.
    case taggedEarlyVideoAudioInfo
    /// Tagged; audio's arrive early and RTP-Info names only video.
    case taggedEarlyAudioVideoInfo

    var tagged: Bool { self == .taggedEarlyVideoAudioInfo || self == .taggedEarlyAudioVideoInfo }
    var earlyVideo: Int { self == .earlyBoth || self == .taggedEarlyVideoAudioInfo ? 3 : 0 }
    var earlyAudio: Int {
      [.earlyAudio, .earlyBoth, .taggedEarlyAudioVideoInfo].contains(self) ? 3 : 0
    }
    /// The stream the seek response's RTP-Info leaves out, if any.
    var seekInfoOmits: String? {
      switch self {
      case .rtpInfoWithoutAudio, .taggedEarlyAudioVideoInfo: "audio"
      case .taggedEarlyVideoAudioInfo: "video"
      default: nil
      }
    }
  }

  /// Each playback: 30 video frames (1 s), then 5 audio packets (0.1 s). The
  /// new playback of both streams must start at one time, wherever each
  /// stream stopped.
  @Test(
    "A seek starts every stream's new playback at one time", arguments: SeekAlignmentCase.allCases)
  func seekAlignedStreams(_ scenario: SeekAlignmentCase) async throws {
    let sdp = makeTestSDP(media: [h264VideoMediaSDP(), pcmuAudioMediaSDP(direction: nil)])
    let server = FakeRTSPServer(sdp: sdp)
    let plays = Shared(0)
    // Sends the units of the current playback that go out `early` (ahead of
    // the seek's response) or not.
    @Sendable func playback(_ handle: FakeRTSPSessionHandle, early: Bool, cseq: Int?) {
      guard let video = handle.setup(forStream: 0), let audio = handle.setup(forStream: 1) else {
        return
      }
      let isSeek = plays.value == 2
      let tag =
        scenario.tagged
        ? onvifReplayExtension(
          ntp: ntpTimestamp(for: Date()), cleanPoint: true, endOfSection: false,
          discontinuity: false, terminal: false, cseq: UInt8(truncatingIfNeeded: cseq ?? 0))
        : nil
      var videoSequencer = RTPTestSequencer(parameters: video.parameters)
      var audioSequencer = RTPTestSequencer(parameters: audio.parameters, payloadType: 0)
      for index in 0..<30 {
        let packets = videoSequencer.accessUnit(
          h264AccessUnit(keyframe: index == 0), timestampIncrement: 3000, rtpExtension: tag,
          extensionOnAllPackets: true)
        guard (isSeek && index < scenario.earlyVideo) == early else { continue }
        for packet in packets { handle.sendRTP(packet, stream: 0) }
      }
      guard isSeek || scenario != .audioSilentBefore else { return }
      for index in 0..<5 {
        let packets = audioSequencer.accessUnit(
          [Data(repeating: 0xFF, count: 160)], timestampIncrement: 160, rtpExtension: tag,
          extensionOnAllPackets: true)
        guard (isSeek && index < scenario.earlyAudio) == early else { continue }
        for packet in packets { handle.sendRTP(packet, stream: 1) }
      }
    }
    server.transformResponse = { [weak server] request, response in
      guard request.method == "PLAY", let server, let handle = server.sessionHandles.first else {
        return response
      }
      plays.update { $0 += 1 }
      playback(handle, early: true, cseq: request.cseq)
      var response = response
      let omitted =
        plays.value == 2
        ? scenario.seekInfoOmits : (scenario == .audioSilentBefore ? "audio" : nil)
      if plays.value == 2 && scenario == .noRTPInfo {
        response.headers.removeAll { $0.name == "RTP-Info" }
      } else if let omitted {
        response.headers = response.headers.map { header in
          guard header.name == "RTP-Info" else { return header }
          let entries = header.value.split(separator: ",").filter { !$0.contains("\(omitted);") }
          return (header.name, entries.joined(separator: ","))
        }
      }
      return response
    }
    server.onPlay = { request, handle in playback(handle, early: false, cseq: request.cseq) }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    let video = Shared<[Double]>([])
    let audio = Shared<[Double]>([])
    let consumer = Task {
      for try await item in session.frames() {
        switch item {
        case .video(let frame): video.update { $0.append(frame.timestamp) }
        case .audio(let frame): audio.update { $0.append(frame.timestamp) }
        default: break
        }
      }
    }
    defer { consumer.cancel() }
    let audioBefore = scenario == .audioSilentBefore ? 0 : 5
    #expect(await poll { video.value.count == 30 && audio.value.count == audioBefore })
    try await session.play(PlayOptions(range: .npt(start: 30), immediate: true))
    #expect(await poll { video.value.count == 60 && audio.value.count == audioBefore + 5 })
    let firstVideo = try #require(video.value.dropFirst(30).first)
    let firstAudio = try #require(audio.value.dropFirst(audioBefore).first)
    #expect(abs(firstVideo - firstAudio) < 0.001, "video \(firstVideo) s, audio \(firstAudio) s")
    #expect(firstVideo >= 1.0 - 0.001, "the new playback starts after the previous one")
    await session.stop()
  }

  /// The first PLAY's playback sent nothing before the seek, so no stream has
  /// a time yet; the seek's RTP-Info, with timestamps unrelated to the first
  /// PLAY's, must still start both streams at 0.
  @Test("A seek before any packet starts every stream at 0", .timeLimit(.minutes(1)))
  func seekBeforeAnyPacket() async throws {
    let sdp = makeTestSDP(media: [h264VideoMediaSDP(), pcmuAudioMediaSDP(direction: nil)])
    let server = FakeRTSPServer(sdp: sdp)
    let plays = Shared(0)
    // The first PLAY's RTP-Info is seq=1000;rtptime=90000 (video) and
    // seq=2000;rtptime=180000 (audio).
    let seekVideo = (seq: UInt16(5000), rtpTime: UInt32(500_000))
    let seekAudio = (seq: UInt16(6000), rtpTime: UInt32(70_000))
    server.transformResponse = { request, response in
      guard request.method == "PLAY" else { return response }
      plays.update { $0 += 1 }
      guard plays.value == 2 else { return response }
      var response = response
      response.headers = response.headers.map { header in
        guard header.name == "RTP-Info" else { return header }
        let value = header.value
          .replacingOccurrences(
            of: "seq=1000;rtptime=90000", with: "seq=\(seekVideo.seq);rtptime=\(seekVideo.rtpTime)"
          )
          .replacingOccurrences(
            of: "seq=2000;rtptime=180000",
            with: "seq=\(seekAudio.seq);rtptime=\(seekAudio.rtpTime)")
        return (header.name, value)
      }
      return response
    }
    server.onPlay = { _, handle in
      guard plays.value == 2, let video = handle.setup(forStream: 0),
        let audio = handle.setup(forStream: 1)
      else { return }
      var videoSequencer = RTPTestSequencer(
        sequence: seekVideo.seq, timestamp: seekVideo.rtpTime, ssrc: video.parameters.ssrc)
      var audioSequencer = RTPTestSequencer(
        sequence: seekAudio.seq, timestamp: seekAudio.rtpTime, ssrc: audio.parameters.ssrc,
        payloadType: 0)
      for index in 0..<30 {
        for packet in videoSequencer.accessUnit(
          h264AccessUnit(keyframe: index == 0), timestampIncrement: 3000)
        {
          handle.sendRTP(packet, stream: 0)
        }
      }
      for _ in 0..<5 {
        for packet in audioSequencer.accessUnit(
          [Data(repeating: 0xFF, count: 160)], timestampIncrement: 160)
        {
          handle.sendRTP(packet, stream: 1)
        }
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    let video = Shared<[Double]>([])
    let audio = Shared<[Double]>([])
    let consumer = Task {
      for try await item in session.frames() {
        switch item {
        case .video(let frame): video.update { $0.append(frame.timestamp) }
        case .audio(let frame): audio.update { $0.append(frame.timestamp) }
        default: break
        }
      }
    }
    defer { consumer.cancel() }
    try await session.play(PlayOptions(range: .npt(start: 30), immediate: true))
    #expect(await poll { video.value.count == 30 && audio.value.count == 5 })
    let firstVideo = try #require(video.value.first)
    let firstAudio = try #require(audio.value.first)
    #expect(abs(firstVideo) < 0.001, "video \(firstVideo) s")
    #expect(abs(firstAudio) < 0.001, "audio \(firstAudio) s")
    await session.stop()
  }

  /// Over UDP a seek's response comes on the control connection while the
  /// datagrams of the playback before it still wait behind a consumer that
  /// fell behind: they belong to that playback, not the new one.
  @Test(
    "A UDP seek doesn't deliver the backlog of the playback it replaced",
    .timeLimit(.minutes(1)), arguments: [false, true])
  func udpSeekBacklog(tagged: Bool) async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    let plays = Shared(0)
    let sentOld = Shared(false)
    // More than the frame queue's 256 frames, so the rest of the old
    // playback waits in the datagram queue.
    let oldFrames = 600
    // The keyframe is 3 packets, the other frames 1 each.
    let newStart = (seq: UInt16(1000 + oldFrames + 2), rtpTime: UInt32(90_000 + oldFrames * 3000))
    @Sendable func tag(_ cseq: Int?) -> (profile: UInt16, data: Data)? {
      guard tagged else { return nil }
      return onvifReplayExtension(
        ntp: ntpTimestamp(for: Date()), cleanPoint: true, endOfSection: false,
        discontinuity: false, terminal: false, cseq: UInt8(truncatingIfNeeded: cseq ?? 0))
    }
    server.transformResponse = { request, response in
      guard request.method == "PLAY" else { return response }
      plays.update { $0 += 1 }
      guard plays.value == 2 else { return response }
      var response = response
      response.headers = response.headers.map { header in
        guard header.name == "RTP-Info" else { return header }
        let value = header.value.replacingOccurrences(
          of: "seq=1000;rtptime=90000", with: "seq=\(newStart.seq);rtptime=\(newStart.rtpTime)")
        return (header.name, value)
      }
      return response
    }
    server.onPlay = { request, handle in
      guard let video = handle.setup(forStream: 0) else { return }
      let ext = tag(request.cseq)
      // Old frames are marked 0xAA, new ones 0xBB (after the NAL header).
      var sequencer =
        plays.value == 1
        ? RTPTestSequencer(parameters: video.parameters)
        : RTPTestSequencer(
          sequence: newStart.seq, timestamp: newStart.rtpTime, ssrc: video.parameters.ssrc)
      let marker: UInt8 = plays.value == 1 ? 0xAA : 0xBB
      for index in 0..<(plays.value == 1 ? oldFrames : 10) {
        let nalus =
          index == 0
          ? h264AccessUnit(keyframe: true)
          : [Data([0x41, marker, UInt8(index >> 8), UInt8(index & 0xFF), 1])]
        for packet in sequencer.accessUnit(
          nalus, timestampIncrement: 3000, rtpExtension: ext, extensionOnAllPackets: true)
        {
          handle.sendRTP(packet, stream: 0)
        }
        if index % 20 == 19 { Thread.sleep(forTimeInterval: 0.001) }
      }
      if plays.value == 1 { sentOld.value = true }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url, transport: .udp, onvif: tagged ? .replay : [])
    _ = try await session.start()
    let markers = Shared<[UInt8]>([])
    let gate = Shared(false)
    let consumer = Task {
      for try await item in session.frames() {
        guard case .video(let frame) = item else { continue }
        let marked = frame.nalus.first { $0.count > 1 && $0[$0.startIndex] == 0x41 }
        markers.update { $0.append(marked.map { $0[$0.startIndex + 1] } ?? 0) }
        // Falls behind after the first frame until the gate opens.
        while !gate.value { try await Task.sleep(for: .milliseconds(10)) }
      }
    }
    defer { consumer.cancel() }
    #expect(await poll { markers.value.count == 1 })
    // The first playback is all sent and, once the client has read the
    // datagrams (about 1,500 a second on a machine busy with other tests),
    // waits in the queues.
    #expect(await poll(.seconds(20)) { sentOld.value })
    try await Task.sleep(for: .seconds(1))
    try await session.play(PlayOptions(range: .npt(start: 100), immediate: true))
    gate.value = true
    #expect(await poll(.seconds(10)) { markers.value.filter { $0 == 0xBB }.count == 9 })
    // At most the frame queue's 256 frames, delivered first.
    let old = markers.value.filter { $0 == 0xAA }.count
    #expect(old <= 257, "\(old) frames of the replaced playback")
    await session.stop()
  }

  /// After stop() the session takes no more media: a UDP session leaves the
  /// datagrams still buffered, and a TCP session discards what it reads on
  /// the way to TEARDOWN's response. Only the frames already queued are
  /// delivered, all of them.
  @Test(
    "After stop(), only the frames already queued are delivered", .timeLimit(.minutes(1)),
    arguments: [(Transport.udp, 2000), (.tcp, 2000), (.tcp, 6000)])
  func stopDeliversQueuedOnly(transport: Transport, total: Int) async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onPlay = { _, handle in
      guard let video = handle.setup(forStream: 0) else { return }
      // Sent from its own task, so a TCP server isn't blocked by the client's
      // backpressure while it answers TEARDOWN.
      Task.detached {
        var sequencer = RTPTestSequencer(parameters: video.parameters)
        for index in 0..<total {
          for packet in sequencer.accessUnit(
            h264AccessUnit(keyframe: index == 0), timestampIncrement: 3000)
          {
            guard handle.sendRTP(packet, stream: 0) else { return }
          }
          if index % 20 == 19 { try? await Task.sleep(for: .milliseconds(1)) }
        }
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url, transport: transport)
    _ = try await session.start()
    let count = Shared(0)
    let losses = Shared(0)
    let gate = Shared(false)
    let consumer = Task {
      for try await item in session.frames() {
        guard case .video(let frame) = item else { continue }
        count.update { $0 += 1 }
        losses.update { $0 += Int(frame.loss) }
        // Falls behind after the first frame until the gate opens.
        while !gate.value { try await Task.sleep(for: .milliseconds(10)) }
      }
    }
    #expect(await poll { count.value == 1 })
    // The server sends for a while; the client's queue fills and the rest
    // waits in the socket and server buffers.
    try await Task.sleep(for: .milliseconds(800))
    await session.stop()
    gate.value = true
    _ = await consumer.result
    // The frame in hand and the 256 queued, none of them lost.
    #expect(count.value <= 258, "\(count.value) frames")
    #expect(count.value >= 200, "\(count.value) frames")
    #expect(losses.value == 0, "loss \(losses.value)")
  }

  /// The seek's response, or its rejection, comes after stop(): the packets
  /// held for it must not become frames then.
  @Test(
    "A seek answered after stop() delivers nothing more", .timeLimit(.minutes(1)),
    arguments: [(Transport.tcp, 200), (.tcp, 457), (.udp, 200), (.udp, 457)])
  func stopDuringSeek(transport: Transport, status: Int) async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.configuration.includeRTPInfo = false
    let sequencer = Shared<RTPTestSequencer?>(nil)
    @Sendable func sendFrames(_ handle: FakeRTSPSessionHandle, count: Int) {
      sequencer.update { sequencer in
        for index in 0..<count {
          for packet in sequencer!.accessUnit(
            h264AccessUnit(keyframe: index == 0), timestampIncrement: 3000)
          {
            handle.sendRTP(packet, stream: 0)
          }
        }
      }
    }
    let plays = Shared(0)
    server.onRequest = { [weak server] request in
      guard request.method == "PLAY", let handle = server?.sessionHandles.first,
        let video = handle.setup(forStream: 0)
      else { return nil }
      plays.update { $0 += 1 }
      if plays.value == 1 {
        sequencer.value = RTPTestSequencer(parameters: video.parameters)
        return nil
      }
      // The playback goes on while the seek waits for its answer, which comes
      // after the client's stop().
      sendFrames(handle, count: 5)
      Thread.sleep(forTimeInterval: 0.6)
      return status == 200 ? nil : FakeRTSPResponse(statusCode: status)
    }
    server.onPlay = { _, handle in
      if plays.value == 1 { sendFrames(handle, count: 5) }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url, transport: transport)
    _ = try await session.start()
    let count = Shared(0)
    let consumer = Task {
      for try await item in session.frames() {
        if case .video = item { count.update { $0 += 1 } }
      }
    }
    #expect(await poll { count.value == 5 })
    let seek = Task { try await session.play(PlayOptions(range: .npt(start: 30), immediate: true)) }
    try await Task.sleep(for: .milliseconds(200))
    let atStop = count.value
    await session.stop()
    _ = await seek.result
    _ = await consumer.result
    #expect(count.value == atStop, "\(atStop) at stop(), \(count.value) delivered")
  }

  /// A request answered with 401 after stop() sent TEARDOWN isn't retried:
  /// the retry would carry the torn-down session's id.
  @Test(
    "A 401 that arrives after TEARDOWN isn't retried", .timeLimit(.minutes(1)),
    arguments: ["PLAY", "GET_PARAMETER", "PAUSE"])
  func noRetryAfterTeardown(method: String) async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    let started = Shared(false)
    server.onRequest = { request in
      if request.method == "TEARDOWN" {
        Thread.sleep(forTimeInterval: 0.2)
        return nil
      }
      guard started.value, request.method == method, request.header("Authorization") == nil
      else { return nil }
      Thread.sleep(forTimeInterval: 0.3)
      return FakeRTSPResponse(
        statusCode: 401, headers: [("WWW-Authenticate", #"Basic realm="camera""#)])
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "admin", password: "secret"),
      transport: .tcp, userAgent: "IPCamKit", onDiagnostic: nil,
      keepaliveInterval: method == "GET_PARAMETER" ? .milliseconds(100) : .seconds(30))
    _ = try await session.start()
    started.value = true
    let request = Task {
      if method == "PLAY" {
        try await session.play(PlayOptions(range: .npt(start: 10), immediate: true))
      }
      if method == "PAUSE" { try await session.pause() }
    }
    try await Task.sleep(for: .milliseconds(method == "GET_PARAMETER" ? 160 : 100))
    await session.stop()
    _ = await request.result
    try await Task.sleep(for: .milliseconds(300))
    let order = server.requests.map {
      $0.method + ($0.header("Authorization") == nil ? "" : "+auth")
    }
    let teardown = try #require(order.firstIndex(of: "TEARDOWN"))
    #expect(!order[(teardown + 1)...].contains { $0.hasPrefix(method) }, "\(order)")
  }

  /// The first seek's 401 arrives after the second seek went out: a retry
  /// would move the server back to the first seek's position.
  @Test("A replaced seek's 401 isn't retried", .timeLimit(.minutes(1)))
  func replacedSeekNotRetriedAfter401() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    let plays = Shared(0)
    server.onRequest = { request in
      guard request.method == "PLAY" else { return nil }
      plays.update { $0 += 1 }
      guard plays.value == 2 else { return nil }
      Thread.sleep(forTimeInterval: 0.3)
      return FakeRTSPResponse(
        statusCode: 401, headers: [("WWW-Authenticate", #"Basic realm="camera""#)])
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "admin", password: "secret"))
    _ = try await session.start()
    let first = Task {
      try await session.play(PlayOptions(range: .npt(start: 100), immediate: true))
    }
    try await Task.sleep(for: .milliseconds(80))
    try await session.play(PlayOptions(range: .npt(start: 200), immediate: true))
    _ = await first.result
    let ranges = server.requests(method: "PLAY").map(\.range)
    #expect(ranges.last == "npt=200.000-", "\(ranges)")
    #expect(ranges.count == 3, "\(ranges)")
    await session.stop()
  }

  /// A server without the ONVIF replay extension keeps streaming while it
  /// refuses a seek; its packets can't be told apart until the response.
  @Test("A rejected seek on a server without replay tags keeps the playback whole")
  func rejectedSeekWithoutReplayTags() async throws {
    let sdp = makeTestSDP(media: [pcmuAudioMediaSDP(direction: nil), onvifMetadataMediaSDP()])
    let server = FakeRTSPServer(sdp: sdp)
    let audioSequencer = Shared<RTPTestSequencer?>(nil)
    let metadataSequencer = Shared<RTPTestSequencer?>(nil)
    let secondHalf = Shared<Data?>(nil)
    @Sendable func document(_ name: String) -> Data {
      Data(
        ("<?xml version=\"1.0\"?><tt:MetadataStream xmlns:tt=\"http://www.onvif.org/ver10/schema\">"
          + "<tt:Name>\(name)</tt:Name></tt:MetadataStream>").utf8)
    }
    @Sendable func sendAudio(_ handle: FakeRTSPSessionHandle, count: Int) {
      audioSequencer.update { sequencer in
        for _ in 0..<count {
          for packet in sequencer!.accessUnit(
            [Data(repeating: 0xFF, count: 160)], timestampIncrement: 160)
          {
            handle.sendRTP(packet, stream: 0)
          }
        }
      }
    }
    // Sends `name`, or only its first half (the rest goes to `secondHalf`).
    @Sendable func sendDocument(_ handle: FakeRTSPSessionHandle, _ name: String, half: Bool) {
      let data = document(name)
      let middle = data.count / 2
      metadataSequencer.update { sequencer in
        let packets = sequencer!.accessUnit(
          [data.prefix(middle), data.dropFirst(middle)], timestampIncrement: 9000)
        handle.sendRTP(packets[0], stream: 1)
        if half { secondHalf.value = packets[1] } else { handle.sendRTP(packets[1], stream: 1) }
      }
    }
    server.onPlay = { _, handle in
      guard let audio = handle.setup(forStream: 0), let metadata = handle.setup(forStream: 1),
        audioSequencer.value == nil
      else { return }
      audioSequencer.value = RTPTestSequencer(parameters: audio.parameters, payloadType: 0)
      metadataSequencer.value = RTPTestSequencer(parameters: metadata.parameters, payloadType: 107)
      sendAudio(handle, count: 10)
      sendDocument(handle, "one", half: false)
      sendDocument(handle, "two", half: true)
    }
    let plays = Shared(0)
    server.onRequest = { [weak server] request in
      guard request.method == "PLAY" else { return nil }
      plays.update { $0 += 1 }
      guard plays.value == 2, let handle = server?.sessionHandles.first else { return nil }
      // The playback continues around the rejected seek's response.
      if let rest = secondHalf.value { handle.sendRTP(rest, stream: 1) }
      sendAudio(handle, count: 5)
      Task.detached {
        try? await Task.sleep(for: .milliseconds(100))
        sendAudio(handle, count: 5)
        sendDocument(handle, "three", half: false)
      }
      return FakeRTSPResponse(statusCode: 457)
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    let audio = Shared<[Double]>([])
    let documents = Shared<[String]>([])
    let losses = Shared<[Int]>([])
    let consumer = Task {
      for try await item in session.frames() {
        switch item {
        case .audio(let frame):
          audio.update { $0.append(frame.timestamp) }
          losses.update { $0.append(Int(frame.loss)) }
        case .metadata(let frame):
          let text = String(decoding: frame.data, as: UTF8.self)
          documents.update { $0.append(text) }
          losses.update { $0.append(Int(frame.loss)) }
        default: break
        }
      }
    }
    defer { consumer.cancel() }
    #expect(await poll { audio.value.count == 10 && documents.value.count == 1 })
    await #expect(throws: RTSPError.self) {
      try await session.play(PlayOptions(range: .npt(start: 50), immediate: true))
    }
    #expect(await poll { audio.value.count == 20 && documents.value.count == 3 })
    let steps = zip(audio.value.dropFirst(), audio.value).map { $0 - $1 }
    #expect(steps.allSatisfy { abs($0 - 0.02) < 0.0001 }, "\(steps)")
    #expect(documents.value.map { $0.contains("<tt:Name>two</tt:Name>") } == [false, true, false])
    #expect(losses.value.allSatisfy { $0 == 0 }, "\(losses.value)")
    await session.stop()
  }

  /// Each request is sent from its own task; with the session busy (a flood
  /// of media), a higher-priority caller's request used to overtake an
  /// earlier one, so the server saw PAUSE before PLAY while the client took
  /// the PAUSE as the final state.
  @Test(
    "Control requests reach the server in CSeq order whatever their callers' priorities",
    .timeLimit(.minutes(1)))
  func controlRequestsInCSeqOrder() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    let flooding = Shared(false)
    server.onPlay = { _, handle in
      guard !flooding.value, let setup = handle.setup(forStream: 0) else { return }
      flooding.value = true
      Task.detached {
        var sequencer = RTPTestSequencer(parameters: setup.parameters)
        var index = 0
        // About 20 frames a millisecond, leaving the connection room for
        // the responses.
        while flooding.value {
          for _ in 0..<20 {
            for packet in sequencer.accessUnit(
              h264AccessUnit(keyframe: index % 30 == 0), timestampIncrement: 3000)
            {
              guard handle.sendRTP(packet, stream: 0) else { return }
            }
            index += 1
          }
          try? await Task.sleep(for: .milliseconds(1))
        }
      }
    }
    try await server.start()
    defer {
      flooding.value = false
      server.stop()
    }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    let deadline = ContinuousClock.now + .seconds(20)
    for _ in 0..<150 where ContinuousClock.now < deadline {
      let play = Task(priority: .low) {
        _ = await outcome { try await session.play(PlayOptions()) }
      }
      let pause = Task(priority: .high) { _ = await outcome { try await session.pause() } }
      _ = await (play.value, pause.value)
    }
    flooding.value = false
    let controls = server.requests.filter { $0.method == "PLAY" || $0.method == "PAUSE" }
    #expect(controls.count > 100, "\(controls.count) PLAY/PAUSE requests")
    let cseqs = server.requests.compactMap(\.cseq)
    let inversions = zip(cseqs, cseqs.dropFirst()).filter { $0 > $1 }
    #expect(
      inversions.isEmpty, "\(inversions.count) requests overtaken, e.g. \(inversions.prefix(3))")
    await session.stop()
  }

  /// Frames that arrive before the first `frames()` call are kept up to
  /// 32 MiB. A plain XML document's `xml` is its `data`, so it counts once.
  @Test("Plain XML metadata counts once against the frame queue's byte limit")
  func plainMetadataCountedOnce() async throws {
    let server = FakeRTSPServer(sdp: makeTestSDP(media: [onvifMetadataMediaSDP()]))
    let document = Data(
      ("<?xml version=\"1.0\"?><tt:MetadataStream xmlns:tt=\"http://www.onvif.org/ver10/schema\">"
        + String(repeating: "<tt:Event/>", count: 50_000) + "</tt:MetadataStream>").utf8)
    let pieces = stride(from: 0, to: document.count, by: 1400).map {
      Data(document[$0..<min($0 + 1400, document.count)])
    }
    let documents = 34  // 18.7 MB; twice that is over 32 MiB
    let sent = Shared(false)
    server.onPlay = { _, handle in
      guard let metadata = handle.setup(forStream: 0) else { return }
      var sequencer = RTPTestSequencer(parameters: metadata.parameters, payloadType: 107)
      for _ in 0..<documents {
        for packet in sequencer.accessUnit(pieces, timestampIncrement: 9000) {
          handle.sendRTP(packet, stream: 0)
        }
      }
      sent.value = true
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    #expect(await poll { sent.value })
    // Let the session read and queue every document before frames() is called.
    try await Task.sleep(for: .seconds(1))
    var received = 0
    var loss = 0
    for try await item in session.frames() {
      guard case .metadata(let frame) = item else { continue }
      received += 1
      loss += Int(frame.loss)
      if received == documents || loss > 0 { break }
    }
    #expect(received == documents && loss == 0, "\(received) documents, loss \(loss)")
    await session.stop()
  }

  @Test("A UDP SETUP reply with server_port 0 fails start()")
  func udpServerPortZero() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.transformResponse = { request, response in
      guard request.method == "SETUP" else { return response }
      var response = response
      response.headers = response.headers.map { header in
        guard header.name == "Transport" else { return header }
        let value = header.value.replacingOccurrences(
          of: #"server_port=\d+-\d+"#, with: "server_port=0-1", options: .regularExpression)
        return (header.name, value)
      }
      return response
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url, transport: .udp)
    let result = await outcome { try await session.start() }
    guard case .failure(let error) = result,
      case .sessionSetupFailed(_, let reason) = error as? RTSPError
    else {
      Issue.record("expected sessionSetupFailed, got \(result)")
      await session.stop()
      return
    }
    #expect(reason.contains("server_port"), "\(reason)")
  }

  /// A UDP or multicast session's datagrams wait in a queue bounded by count
  /// and by bytes, the oldest dropped first: 4096 multicast datagrams of
  /// 64 KiB each could hold 256 MiB when only the count was bounded.
  @Test("The datagram queue drops the oldest past its count or byte bound")
  func datagramQueueBounds() async {
    func drain(_ queue: DatagramQueue) async -> (arrivals: [UInt64], bytes: Int) {
      queue.finish()
      var arrivals: [UInt64] = []
      var bytes = 0
      while let event = await queue.next() {
        arrivals.append(event.arrival)
        bytes += event.byteCount
      }
      return (arrivals, bytes)
    }
    let large = DatagramQueue(maxCount: 4096, maxBytes: 1 << 20)
    for _ in 0..<100 {
      large.enqueue { .rtp(streamIndex: 0, data: Data(count: 60_000), arrival: $0) }
    }
    let kept = await drain(large)
    // 17 datagrams of 60,000 bytes fit in 1 MiB; the newest are kept, in order.
    #expect(kept.arrivals == Array(84...100))
    #expect(kept.bytes <= 1 << 20)
    #expect(large.queued == 100)

    let many = DatagramQueue(maxCount: 10, maxBytes: 1 << 20)
    for _ in 0..<25 { many.enqueue { .rtcp(streamIndex: 1, data: Data(count: 10), arrival: $0) } }
    #expect(await drain(many).arrivals == Array(16...25))

    // A reader already waiting gets the next datagram at once.
    let waiting = DatagramQueue(maxCount: 10, maxBytes: 1 << 20)
    let reader = Task { await waiting.next()?.arrival }
    try? await Task.sleep(for: .milliseconds(20))
    waiting.enqueue { .rtp(streamIndex: 0, data: Data(count: 1), arrival: $0) }
    #expect(await reader.value == 1)
  }

  /// Taken and dropped items are released at once, not when the queue's
  /// array is next compacted: a slot that kept its payload let 64 KiB
  /// multicast datagrams hold about 73 MiB against an 8 MiB bound, and frames
  /// a consumer had taken stay in memory.
  @Test("The datagram and frame queues release what they drop or hand out")
  func queuesReleasePayloads() async {
    final class Live: @unchecked Sendable {
      private let lock = NSLock()
      private var count = 0
      private(set) var peak = 0
      var current: Int { lock.withLock { count } }
      func add(_ delta: Int) {
        lock.withLock {
          count += delta
          peak = max(peak, count)
        }
      }
    }
    func tracked(_ size: Int, _ live: Live) -> Data {
      let pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
      live.add(1)
      return Data(
        bytesNoCopy: pointer, count: size,
        deallocator: .custom { pointer, _ in
          pointer.deallocate()
          live.add(-1)
        })
    }

    // 17 datagrams of 60,000 bytes fit in 1 MiB; one more is held while it's queued.
    let live = Live()
    let datagrams = DatagramQueue(maxCount: 4096, maxBytes: 1 << 20)
    for _ in 0..<2000 {
      datagrams.enqueue { .rtp(streamIndex: 0, data: tracked(60_000, live), arrival: $0) }
    }
    #expect(live.peak <= 18, "peak \(live.peak) live datagrams")
    datagrams.finish()
    while await datagrams.next() != nil {}
    #expect(live.current == 0)

    let frameLive = Live()
    var frames = FrameQueue()
    for _ in 0..<100 {
      frames.append(.rtcp(PublicRTCPPacket(timestamp: nil, data: tracked(1000, frameLive))))
    }
    for _ in 0..<50 { _ = frames.popFirst() }
    #expect(frameLive.current == 50)
    frames.removeAll()
    #expect(frameLive.current == 0)
  }

  /// The `seq=0;rtptime=0` RTP-Info placeholder some cameras send says
  /// nothing about where their (random) RTP timestamps start: like a seek's,
  /// the first PLAY ignores both values, so each stream starts at 0.
  @Test("The seq=0;rtptime=0 RTP-Info placeholder doesn't set the timeline start")
  func rtpInfoPlaceholderIgnored() async throws {
    var configuration = FakeRTSPServer.Configuration(
      sdp: makeTestSDP(media: [h264VideoMediaSDP(), pcmuAudioMediaSDP()]))
    configuration.streamParameters[0] = FakeRTPStreamParameters(
      ssrc: 0x5EED_0000, initialSequence: 0, initialRTPTime: 0)
    configuration.streamParameters[1] = FakeRTPStreamParameters(
      ssrc: 0x5EED_0001, initialSequence: 0, initialRTPTime: 0)
    let server = FakeRTSPServer(configuration: configuration)
    server.onPlay = { _, handle in
      guard let video = handle.setup(forStream: 0), let audio = handle.setup(forStream: 1)
      else { return }
      var videoSequencer = RTPTestSequencer(
        sequence: 5000, timestamp: 3_000_000_000, ssrc: video.parameters.ssrc)
      var audioSequencer = RTPTestSequencer(
        sequence: 7000, timestamp: 1_234_567_890, ssrc: audio.parameters.ssrc, payloadType: 0)
      for index in 0..<5 {
        for packet in videoSequencer.accessUnit(
          h264AccessUnit(keyframe: index == 0), timestampIncrement: 3000)
        {
          handle.sendRTP(packet, stream: 0)
        }
        for packet in audioSequencer.accessUnit(
          [Data(repeating: 0x7F, count: 160)], timestampIncrement: 160)
        {
          handle.sendRTP(packet, stream: 1)
        }
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url, transport: .tcp)
    _ = try await session.start()
    var firstVideo: Double?
    var firstAudio: Double?
    for try await item in session.frames() {
      switch item {
      case .video(let frame): firstVideo = firstVideo ?? frame.timestamp
      case .audio(let frame): firstAudio = firstAudio ?? frame.timestamp
      default: break
      }
      if firstVideo != nil, firstAudio != nil { break }
    }
    await session.stop()
    #expect(abs(firstVideo ?? 99) < 1, "first video frame at \(firstVideo ?? .nan) s")
    #expect(abs(firstAudio ?? 99) < 1, "first audio frame at \(firstAudio ?? .nan) s")
  }

  /// A response that arrives as `setupResponseTimeout` runs out: either it
  /// counts, or start() fails with `RTSPError.timeout`. The deadline used to
  /// close the connection after its exchange had already returned, so the
  /// next request failed with "Not connected".
  @Test("A response at the setup deadline gives success or timeout", .timeLimit(.minutes(1)))
  func responseAtDeadline() async throws {
    let delay = Shared(0.0)
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      if request.method == "SETUP" { Thread.sleep(forTimeInterval: delay.value) }
      return nil
    }
    try await server.start()
    defer { server.stop() }
    var outcomes: [String: Int] = [:]
    for step in 0..<60 {
      delay.value = 0.040 + Double(step % 20) * 0.001
      let session = RTSPClientSession(
        url: server.url, credentials: nil, transport: .tcp, userAgent: "IPCamKit",
        onDiagnostic: nil, keepaliveInterval: nil, setupResponseTimeout: .milliseconds(50))
      let result = await outcome { try await session.start() }
      await session.stop()
      switch result {
      case .success: outcomes["success", default: 0] += 1
      case .failure(RTSPError.timeout): outcomes["timeout", default: 0] += 1
      case .failure(let error): outcomes["\(error)", default: 0] += 1
      }
    }
    #expect(outcomes.keys.allSatisfy { $0 == "success" || $0 == "timeout" }, "\(outcomes)")
  }

  @Test("start() times out when an optional stream's SETUP gets no answer")
  func optionalSetupTimesOut() async throws {
    let sdp = makeTestSDP(media: [h264VideoMediaSDP(), pcmuAudioMediaSDP(direction: nil)])
    let server = FakeRTSPServer(sdp: sdp)
    server.onRequest = { request in
      if request.method == "SETUP", request.url.hasSuffix("audio") {
        Thread.sleep(forTimeInterval: 2)
      }
      return nil
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: nil, transport: .tcp, userAgent: "IPCamKit",
      onDiagnostic: nil, keepaliveInterval: nil, setupResponseTimeout: .milliseconds(300))
    let result = await outcome { try await session.start() }
    guard case .failure(let error) = result, case .timeout = error as? RTSPError else {
      Issue.record("expected RTSPError.timeout, got \(result)")
      return
    }
  }

  /// Packets covered by an RTCP receiver report's first block: extended
  /// highest sequence number minus the stream's first sequence number, plus 1.
  private static func reportedPackets(_ report: Data, initialSequence: UInt16) -> Int {
    let base = report.startIndex
    func be32(_ offset: Int) -> UInt32 {
      (UInt32(report[base + offset]) << 24) | (UInt32(report[base + offset + 1]) << 16)
        | (UInt32(report[base + offset + 2]) << 8) | UInt32(report[base + offset + 3])
    }
    let highest = be32(16)
    return Int(highest &- UInt32(initialSequence)) + 1
  }

  // MARK: stop() and failures

  @Test(
    "stop() during start() makes start() throw and closes the connection",
    arguments: [Transport.tcp, .udp])
  func stopDuringStart(transport: Transport) async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      if request.method == "SETUP" { Thread.sleep(forTimeInterval: 0.3) }
      return nil
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url, transport: transport)
    let starter = Task { try await session.start() }
    _ = await server.waitForRequest(method: "SETUP")
    await session.stop()
    let result = await starter.result
    #expect(throws: RTSPError.self) { try result.get() }
    if case .failure(let error) = result { #expect(isInvalidState(error)) }
    #expect(await poll { server.sessionHandles.allSatisfy(\.isClosed) })
    #expect(server.requests(method: "PLAY").isEmpty)
  }

  @Test("start() against a server that never answers times out", arguments: ["OPTIONS", "SETUP"])
  func startTimesOutWithoutResponse(method: String) async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      if request.method == method { Thread.sleep(forTimeInterval: 2) }
      return nil
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: nil, transport: .tcp, userAgent: "IPCamKit",
      onDiagnostic: nil, keepaliveInterval: nil, setupResponseTimeout: .milliseconds(300))
    let started = ContinuousClock.now
    let result = await outcome { try await session.start() }
    #expect(ContinuousClock.now - started < .seconds(1.5))
    guard case .failure(let error) = result, case .timeout = error as? RTSPError else {
      Issue.record("expected RTSPError.timeout, got \(result)")
      return
    }
  }

  @Test("A failed start() closes its connection; after SETUP it also sends TEARDOWN")
  func failedStartCleansUp() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      request.method == "PLAY" ? FakeRTSPResponse(statusCode: 500) : nil
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    await #expect(throws: RTSPError.self) { try await session.start() }
    #expect(await server.waitForRequest(method: "TEARDOWN") != nil)
    #expect(await poll { server.sessionHandles.allSatisfy(\.isClosed) })
  }

  @Test("start() fails on an H.264 stream in interleaved packetization mode")
  func interleavedH264FailsStart() async throws {
    let sprop = "\(h264TestSPS.base64EncodedString()),\(h264TestPPS.base64EncodedString())"
    let lines: [String] = [
      "m=video 0 RTP/AVP 96",
      "a=rtpmap:96 H264/90000",
      "a=fmtp:96 packetization-mode=2;profile-level-id=640033;sprop-parameter-sets=\(sprop)",
      "a=control:video",
    ]
    let media = lines.map { $0 + "\r\n" }.joined()
    let server = FakeRTSPServer(sdp: makeTestSDP(media: [media]))
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    let result = await outcome { try await session.start() }
    guard case .failure(let error) = result,
      case .depacketizationError(let message) = error as? RTSPError
    else {
      Issue.record("expected RTSPError.depacketizationError, got \(result)")
      await session.stop()
      return
    }
    #expect(message.contains("packetization-mode=2"), "\(message)")
  }

  @Test("Releasing a session without stop() tears it down")
  func releasedSessionStops() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    try await server.start()
    defer { server.stop() }
    do {
      let session = RTSPClientSession(url: server.url)
      _ = try await session.start()
    }
    #expect(await server.waitForRequest(method: "TEARDOWN") != nil)
    #expect(await poll { server.sessionHandles.allSatisfy(\.isClosed) })
  }

  @Test("A frames() sequence keeps its session alive")
  func streamRetainsSession() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onPlay = { _, handle in streamVideo(handle, count: 50) }
    try await server.start()
    defer { server.stop() }
    func openStream() async throws -> AsyncThrowingStream<PublicCodecItem, Error> {
      let session = RTSPClientSession(url: server.url)
      _ = try await session.start()
      return session.frames()
    }
    var frames = 0
    for try await item in try await openStream() {
      if case .video = item { frames += 1 }
      if frames == 20 { break }
    }
    #expect(frames == 20)
    #expect(await server.waitForRequest(method: "TEARDOWN") != nil)
  }

  @Test("start() runs once per session")
  func startOnce() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    await #expect { try await session.start() } throws: { isInvalidState($0) }
    await session.stop()
    await #expect { try await session.start() } throws: { isInvalidState($0) }
  }

  @Test("A failed audio SETUP leaves the session running with video")
  func audioSetupFailure() async throws {
    let server = FakeRTSPServer(
      sdp: makeTestSDP(media: [h264VideoMediaSDP(), pcmuAudioMediaSDP()]))
    server.onRequest = { request in
      request.method == "SETUP" && request.url.hasSuffix("audio")
        ? FakeRTSPResponse(statusCode: 461) : nil
    }
    try await server.start()
    defer { server.stop() }
    let messages = Shared<[String]>([])
    let session = RTSPClientSession(
      url: server.url,
      onDiagnostic: { diagnostic in messages.update { $0.append(diagnostic.message) } })
    let desc = try await session.start()
    #expect(desc.video != nil)
    #expect(desc.audio == nil)
    #expect(messages.value.contains { $0.contains("Audio SETUP failed") })
    await session.stop()
  }

  // MARK: frames() consumers

  @Test("frames() right after breaking out of the previous loop continues the stream")
  func framesAfterBreak() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onPlay = { _, handle in streamVideo(handle, count: 2000, interval: .milliseconds(1)) }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    for _ in 0..<30 {
      var received = 0
      for try await _ in session.frames() {
        received += 1
        if received == 2 { break }
      }
      #expect(received == 2)
    }
    await session.stop()
  }

  @Test("A second task iterating the same frames() sequence is rejected, not leaked")
  func sameSequenceTwice() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    let stream = session.frames()
    let firstEnded = Shared(false)
    let first = Task {
      do { for try await _ in stream {} } catch {}
      firstEnded.value = true
    }
    defer { first.cancel() }
    try await Task.sleep(for: .milliseconds(200))
    var second = stream.makeAsyncIterator()
    await #expect { _ = try await second.next() } throws: { isInvalidState($0) }
    await session.stop()
    #expect(await poll { firstEnded.value })
  }

  // MARK: Control requests

  @Test("A keepalive answered with an error status is reported as failed")
  func keepaliveErrorStatus() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      request.method == "GET_PARAMETER" ? FakeRTSPResponse(statusCode: 454) : nil
    }
    try await server.start()
    defer { server.stop() }
    let messages = Shared<[RTSPDiagnostic]>([])
    let session = RTSPClientSession(
      url: server.url, credentials: nil, transport: .tcp, userAgent: "IPCamKit",
      onDiagnostic: { diagnostic in messages.update { $0.append(diagnostic) } },
      keepaliveInterval: .milliseconds(100))
    _ = try await session.start()
    #expect(
      await poll {
        messages.value.contains { $0.severity == .warning && $0.message.contains("failed: 454") }
      })
    #expect(!messages.value.contains { $0.message.contains("acknowledged") })
    await session.stop()
  }

  @Test("A 401 on a keepalive is answered with the new challenge")
  func keepaliveReauthenticates() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      guard request.method == "GET_PARAMETER", request.header("Authorization") == nil else {
        return nil
      }
      return FakeRTSPResponse(
        statusCode: 401, headers: [("WWW-Authenticate", #"Basic realm="camera""#)])
    }
    try await server.start()
    defer { server.stop() }
    let messages = Shared<[String]>([])
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "admin", password: "secret"),
      transport: .tcp, userAgent: "IPCamKit",
      onDiagnostic: { diagnostic in messages.update { $0.append(diagnostic.message) } },
      keepaliveInterval: .milliseconds(100))
    _ = try await session.start()
    #expect(await poll { messages.value.contains { $0.contains("acknowledged") } })
    let expected = "Basic " + Data("admin:secret".utf8).base64EncodedString()
    #expect(
      server.requests(method: "GET_PARAMETER").contains { $0.header("Authorization") == expected })
    await session.stop()
  }

  @Test("A 401 on TEARDOWN is answered with the new challenge")
  func teardownReauthenticates() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      guard request.method == "TEARDOWN", request.header("Authorization") == nil else {
        return nil
      }
      return FakeRTSPResponse(
        statusCode: 401, headers: [("WWW-Authenticate", #"Basic realm="camera""#)])
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "admin", password: "secret"))
    _ = try await session.start()
    await session.stop()
    let expected = "Basic " + Data("admin:secret".utf8).base64EncodedString()
    let teardowns = server.requests(method: "TEARDOWN").map { $0.header("Authorization") }
    #expect(teardowns == [nil, expected])
  }

  @Test("Two overlapping stop() calls send one TEARDOWN and both return")
  func overlappingStops() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      if request.method == "TEARDOWN" { Thread.sleep(forTimeInterval: 0.2) }
      return nil
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    async let first: Void = session.stop()
    async let second: Void = session.stop()
    _ = await (first, second)
    try await Task.sleep(for: .milliseconds(400))
    #expect(server.requests(method: "TEARDOWN").count == 1)
  }

  @Test("A request from the server mid-stream is answered and streaming continues")
  func serverRequestAnswered() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onPlay = { _, handle in
      guard let setup = handle.setup(forStream: 0) else { return }
      Task.detached {
        var sequencer = RTPTestSequencer(parameters: setup.parameters)
        for index in 0..<40 {
          if index == 10 {
            handle.sendRaw(Data("OPTIONS * RTSP/1.0\r\nCSeq: 7\r\n\r\n".utf8))
            handle.sendRaw(
              Data("SET_PARAMETER * RTSP/1.0\r\nCSeq: 8\r\nContent-Length: 4\r\n\r\nab\r\n".utf8))
          }
          for packet in sequencer.accessUnit(
            h264AccessUnit(keyframe: index % 10 == 0), timestampIncrement: 3000)
          {
            handle.sendRTP(packet, stream: 0)
          }
          try? await Task.sleep(for: .milliseconds(3))
        }
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    var frames = 0
    for try await item in session.frames() {
      if case .video = item { frames += 1 }
      if frames == 40 { break }
    }
    #expect(frames == 40)
    // The fake server logs a reply whose status line has three tokens as a
    // request with the first token as its "method"; "RTSP/1.0 200 OK" is one.
    // (The SET_PARAMETER's "501 Not Implemented" has four, so only the
    // stream continuing shows it was handled; ParsingFixTests checks the
    // reply bytes.)
    let replies = server.requests(method: "RTSP/1.0")
    #expect(replies.contains { $0.url == "200" && $0.header("CSeq") == "7" })
    await session.stop()
  }

  // MARK: Request hygiene

  @Test("user:password in the URL authenticates and is never sent")
  func urlCredentials() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      guard request.method == "DESCRIBE", request.header("Authorization") == nil else {
        return nil
      }
      return FakeRTSPResponse(
        statusCode: 401, headers: [("WWW-Authenticate", #"Basic realm="camera""#)])
    }
    try await server.start()
    defer { server.stop() }
    let url = server.url.replacingOccurrences(of: "rtsp://", with: "rtsp://admin:p%40ss@")
    let session = RTSPClientSession(url: url)
    _ = try await session.start()
    await session.stop()
    #expect(!server.requests.contains { $0.url.contains("@") || $0.url.contains("admin") })
    let expected = "Basic " + Data("admin:p@ss".utf8).base64EncodedString()
    #expect(server.requests(method: "DESCRIBE").last?.header("Authorization") == expected)
  }

  @Test("URLs with spaces or control characters are rejected; credentials stay out of errors")
  func invalidURLs() async throws {
    for url in [
      "rtsp://127.0.0.1:9/a b", "rtsp://127.0.0.1:9/a\r\nX-Injected: 1",
      "rtsp://admin:pw@127.0.0.1:9/a b",
      // An @ that a combining mark follows still ends the password.
      "rtsp://admin:pw@\u{301}127.0.0.1:9/a b",
    ] {
      let session = RTSPClientSession(url: url)
      let result = await outcome { try await session.start() }
      guard case .failure(let error) = result else {
        Issue.record("\(url) was accepted")
        continue
      }
      #expect("\(error)".contains("space or control character"), "\(error)")
      #expect(!"\(error)".contains("pw"))
    }
    #expect(throws: RTSPError.self) { try rtspEndpoint(for: "rtsp:/192.168.1.10/stream") }
    // An @ in the query could be the password's: more is redacted.
    #expect(redactedURL("rtsp://admin:s3cret@cam/x?a=b@c") == "rtsp://***@c")
    #expect(redactedURL("rtsp://cam/x") == "rtsp://cam/x")
    // A raw / ? or # in the password.
    #expect(redactedURL("rtsp://admin:p/ss@cam/stream") == "rtsp://***@cam/stream")
    #expect(redactedURL("rtsp://admin:p?s#s@cam/stream") == "rtsp://***@cam/stream")
    #expect(redactedURL("rtsp://admin:p@ss/1@cam/stream") == "rtsp://***@cam/stream")
    #expect(redactedURL("rtsp://admin:s3cret\u{FF20}cam/s") == "rtsp://***\u{FF20}cam/s")
    #expect(redactedURL("rtsp://admin:s3cret\u{FE6B}cam/s") == "rtsp://***\u{FE6B}cam/s")
    #expect(redactedURL("rtsp://admin:s3cret@\u{301}cam/s") == "rtsp://***@\u{301}cam/s")
    #expect(
      redactedURL("rtsp://admin:s3cret\u{FF20}\u{301}cam/s") == "rtsp://***\u{FF20}\u{301}cam/s")
    #expect(withoutFragment("rtsp://cam/s#\u{301}x") == "rtsp://cam/s")
    let split = try splitUserInfo("rtsp://u%3Ax:p@[::1]:8554/cam/realmonitor?channel=1&subtype=0")
    #expect(throws: RTSPError.self) { try splitUserInfo("rtsp://a:%FF@cam/s") }
    #expect(throws: RTSPError.self) { try splitUserInfo("rtsp://%C3%28:p@cam/s") }
    #expect(try splitUserInfo("rtsp://a:p%C3%A9@cam/s").credentials?.password == "pé")
    // An escape next to a raw non-ASCII character is decoded, not encoded again.
    let mixed = try splitUserInfo("rtsp://j%C3%BCrgen:pässw%40rd@cam/x")
    #expect(mixed.credentials?.password == "pässw@rd")
    #expect(
      try splitUserInfo("rtsp://jürgen%40home:pw@cam/x").credentials?.username == "jürgen@home")
    #expect(asciiURL("rtsp://cam/a%20b/é") == "rtsp://cam/a%20b/%C3%A9")
    #expect(asciiURL("rtsp://cam/x?a=%26b&c=é") == "rtsp://cam/x?a=%26b&c=%C3%A9")
    #expect(asciiURL(try splitUserInfo("rtsp://u:p@cam/é%20").url) == "rtsp://cam/%C3%A9%20")
    #expect(asciiURL("rtsp://café.example/é%20") == "rtsp://xn--caf-dma.example/%C3%A9%20")
    #expect(split.url == "rtsp://[::1]:8554/cam/realmonitor?channel=1&subtype=0")
    #expect(split.credentials?.username == "u:x")
    #expect(split.credentials?.password == "p")
  }

  @Test(
    "Credential-like URL parameters are hidden in error messages",
    arguments: [
      (
        "rtsp://cam/s?user=admin&password=secret&channel=1",
        "rtsp://cam/s?user=***&password=***&channel=1"
      ),
      ("rtsp://cam/user=admin_password=abc_channel=1.sdp?real", "rtsp://cam/user=***?real"),
      ("https://cam/tunnel?%70wd=secret&x=1", "https://cam/tunnel?%70wd=***&x=1"),
      ("rtsp://cam/s?pwd=a;b&x=1", "rtsp://cam/s?pwd=***&x=1"),
      ("rtsp://cam/s?a=b;PassWord=x", "rtsp://cam/s?a=b;PassWord=***"),
      ("rtsp://u:p@cam/s?token=abc#frag", "rtsp://***@cam/s?token=***#frag"),
      (
        "http://cam/decoder_control.cgi?loginuse=admin&loginpas=12345&pwx=1",
        "http://cam/decoder_control.cgi?loginuse=***&loginpas=***&pwx=1"
      ),
      ("rtsp://cam/s?pass word=se cret&x=1", "rtsp://cam/s?pass word=***&x=1"),
      ("rtsp://cam/s?pass%20word=x&y=1", "rtsp://cam/s?pass%20word=***&y=1"),
      ("rtsp://cam/s??password=x", "rtsp://cam/s??password=***"),
      ("rtsp://cam/s?password=se cret&x=1", "rtsp://cam/s?password=***&x=1"),
      (
        "rtsp://cam/cam/realmonitor?channel=1&subtype=0",
        "rtsp://cam/cam/realmonitor?channel=1&subtype=0"
      ),
    ])
  func credentialParametersRedacted(url: String, shown: String) {
    #expect(redactedURL(url) == shown)
  }

  @Test("Redacting a URL takes time linear in its length", .timeLimit(.minutes(1)))
  func credentialRedactionLinear() {
    // No `=` until the end: each `?` starts a name that ends at the next.
    let url = "rtsp://cam/s" + String(repeating: "?", count: 100_000) + "&password=x"
    let start = ContinuousClock.now
    let shown = redactedURL(url)
    #expect(ContinuousClock.now - start < .seconds(2))
    #expect(shown.hasSuffix("?&password=***"))
    // Many hidden values, in the query and in path segments: about 1 s in a
    // debug build, against over 20 s when each append copied the result.
    for (url, hidden) in [
      ("rtsp://cam/s?" + String(repeating: "pass=1&", count: 300_000), "pass=***&"),
      ("rtsp://cam" + String(repeating: "/user=1", count: 300_000), "/user=***"),
    ] {
      let start = ContinuousClock.now
      let shown = redactedURL(url)
      #expect(ContinuousClock.now - start < .seconds(8))
      #expect(shown.hasSuffix(hidden) && !shown.contains("=1"))
    }
  }

  @Test("A malformed URL's error hides credential parameters")
  func malformedURLHidesQueryPassword() async throws {
    let session = RTSPClientSession(url: "rtsp://127.0.0.1:9/s?password=se cret&channel=1")
    let result = await outcome { try await session.start() }
    #expect(throws: RTSPError.self) { try result.get() }
    #expect(!"\(result)".contains("cret"), "\(result)")
    let tunnel = RTSPClientSession(
      url: "rtsp://127.0.0.1:9/s", tunnel: .http(try #require(URL(string: "ftp://cam/t?token=abc")))
    )
    let tunnelResult = await outcome { try await tunnel.start() }
    #expect(throws: RTSPError.self) { try tunnelResult.get() }
    #expect(!"\(tunnelResult)".contains("abc"), "\(tunnelResult)")
  }

  @Test("An rtsps:// URL through an http:// or ws:// tunnel is refused before connecting")
  func rtspsNeedsEncryptedTunnel() async throws {
    let tunnels: [RTSPTunnel] = [
      .http(URL(string: "http://127.0.0.1:9/t")!), .webSocket(URL(string: "ws://127.0.0.1:9/t")!),
    ]
    for tunnel in tunnels {
      let session = RTSPClientSession(url: "rtsps://127.0.0.1:9/stream", tunnel: tunnel)
      let result = await outcome { try await session.start() }
      guard case .failure(let error) = result else {
        Issue.record("accepted")
        continue
      }
      #expect(isInvalidState(error), "\(error)")
    }
  }

  @Test("A User-Agent with CR or LF can't add headers")
  func userAgentSanitized() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url, userAgent: "Agent\r\nX-Injected: 1")
    _ = try await session.start()
    await session.stop()
    let describe = try #require(server.requests(method: "DESCRIBE").first)
    #expect(describe.header("X-Injected") == nil)
    #expect(describe.header("User-Agent") == "AgentX-Injected: 1")
  }

  // MARK: Seeks

  @Test("Resuming after a seek and a pause delivers the resumed playback")
  func seekPauseResume() async throws {
    let origin = Date(timeIntervalSince1970: 1_735_732_800)
    let server = FakeRTSPServer(sdp: makeTestSDP(media: [h264VideoMediaSDP(recvonly: true)]))
    let plays = Shared(0)
    server.onPlay = { request, handle in
      guard let setup = handle.setup(forStream: 0) else { return }
      plays.update { $0 += 1 }
      let index = plays.value
      // The seek (second PLAY) is paused before any of its packets go out.
      guard index != 2 else { return }
      let cseq = UInt8(truncatingIfNeeded: request.cseq ?? 0)
      Task.detached {
        var sequencer = RTPTestSequencer(parameters: setup.parameters)
        sequencer.sequence &+= UInt16(index * 1000)
        for frame in 0..<20 {
          let time = origin.addingTimeInterval(Double(index * 100 + frame))
          let ext = onvifReplayExtension(
            ntp: ntpTimestamp(for: time), cleanPoint: frame % 5 == 0, endOfSection: false,
            discontinuity: false, terminal: false, cseq: cseq)
          for packet in sequencer.accessUnit(
            h264AccessUnit(keyframe: frame % 5 == 0), timestampIncrement: 9000,
            rtpExtension: ext, extensionOnAllPackets: true)
          {
            handle.sendRTP(packet, stream: 0)
          }
          try? await Task.sleep(for: .milliseconds(5))
        }
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url, onvif: .replay)
    _ = try await session.start(PlayOptions(range: .clock(start: origin)))
    let resumed = Shared(0)
    let consumer = Task {
      for try await item in session.frames() {
        if case .video(let frame) = item, let replay = frame.replay,
          replay.time >= origin.addingTimeInterval(300)
        {
          resumed.update { $0 += 1 }
        }
      }
    }
    defer { consumer.cancel() }
    try await Task.sleep(for: .milliseconds(200))
    try await session.play(
      PlayOptions(range: .clock(start: origin.addingTimeInterval(200)), immediate: true))
    try await session.pause()
    try await session.play(PlayOptions())
    #expect(await poll { resumed.value >= 15 })
    await session.stop()
  }

  @Test("A seek whose playback has a new SSRC keeps delivering frames")
  func seekWithNewSSRC() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.configuration.includeRTPInfo = false
    let plays = Shared(0)
    server.onPlay = { _, handle in
      guard let setup = handle.setup(forStream: 0) else { return }
      plays.update { $0 += 1 }
      var parameters = setup.parameters
      if plays.value > 1 {
        parameters.ssrc &+= 1
        parameters.initialSequence &+= 5000
        parameters.initialRTPTime &+= 123_456
      }
      streamVideo(handle, count: 20, parameters: parameters)
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    let frames = Shared<[Double]>([])
    let consumer = Task {
      for try await item in session.frames() {
        if case .video(let frame) = item { frames.update { $0.append(frame.timestamp) } }
      }
    }
    defer { consumer.cancel() }
    #expect(await poll { frames.value.count >= 20 })
    let before = frames.value.count
    try await session.play(PlayOptions(range: .npt(start: 30), immediate: true))
    #expect(await poll { frames.value.count >= before + 15 })
    let timestamps = frames.value
    #expect(zip(timestamps, timestamps.dropFirst()).allSatisfy { $0 < $1 }, "monotonic")
    await session.stop()
  }

  // MARK: Metadata

  @Test("gzip metadata that inflates past 1 MiB has no xml")
  func gzipMetadataCap() async throws {
    let large = Data(count: 2 << 20)
    let compressed = try (large as NSData).compressed(using: .zlib) as Data
    var member = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
    member.append(compressed)
    let crc = Gzip.crc32(large)
    let size = UInt32(large.count)
    for shift in stride(from: 0, to: 32, by: 8) {
      member.append(UInt8(truncatingIfNeeded: crc >> shift))
    }
    for shift in stride(from: 0, to: 32, by: 8) {
      member.append(UInt8(truncatingIfNeeded: size >> shift))
    }
    #expect(try Gzip.decompress(member).count == large.count)
    let payload = member

    let sdp = makeTestSDP(media: [
      "m=application 0 RTP/AVP 107\r\na=rtpmap:107 vnd.onvif.metadata.gzip/90000\r\n"
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
    let messages = Shared<[String]>([])
    let session = RTSPClientSession(
      url: server.url,
      onDiagnostic: { diagnostic in messages.update { $0.append(diagnostic.message) } })
    _ = try await session.start()
    var metadata: PublicMetadataFrame?
    for try await item in session.frames() {
      if case .metadata(let frame) = item {
        metadata = frame
        break
      }
    }
    #expect(metadata?.data == payload)
    #expect(metadata?.xml == nil)
    #expect(messages.value.contains { $0.contains("Could not decompress gzip metadata") })
    await session.stop()
  }

  // MARK: Depacketizer errors

  @Test("A frame completed by a packet that then fails is still delivered")
  func frameCompletedByFailingPacket() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onPlay = { _, handle in
      guard let setup = handle.setup(forStream: 0) else { return }
      let p = setup.parameters
      // A keyframe whose last packet lacks the marker bit: only the next
      // timestamp ends it. That next packet has a forbidden NAL type (0).
      let nals = h264AccessUnit(keyframe: true)
      for (offset, nal) in nals.enumerated() {
        handle.sendRTP(
          makeRTP(
            sequence: p.initialSequence &+ UInt16(offset), timestamp: p.initialRTPTime,
            ssrc: p.ssrc, payloadType: 96, marker: false, payload: nal),
          stream: 0)
      }
      handle.sendRTP(
        makeRTP(
          sequence: p.initialSequence &+ UInt16(nals.count), timestamp: p.initialRTPTime &+ 3000,
          ssrc: p.ssrc, payloadType: 96, marker: true, payload: Data([0x00, 0x01])),
        stream: 0)
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    let keyframe = Shared(false)
    let consumer = Task {
      for try await item in session.frames() {
        if case .video(let frame) = item, frame.isKeyframe { keyframe.value = true }
      }
    }
    defer { consumer.cancel() }
    #expect(await poll(.seconds(2)) { keyframe.value })
    await session.stop()
  }

  // MARK: Audio timestamps

  /// An audio-only presentation for the audio timestamp tests: one packet's
  /// payload, the frames it holds and the RTP ticks each frame lasts.
  struct AudioTiming: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let media: String
    let payloadType: UInt8
    let payload: Data
    let framesPerPacket: Int
    let frameTicks: Int64
    let clockRate: UInt32
    var packetTicks: UInt32 { UInt32(Int64(framesPerPacket) * frameTicks) }

    /// The timestamp of a stream's `index`th frame when every frame starts
    /// where the previous one ended.
    func seconds(ofFrame index: Int) -> Double {
      Double(Int64(index) * frameTicks) / Double(clockRate)
    }

    /// AAC-hbr payload of `count` 4-byte access units.
    static func aacPayload(_ count: Int) -> Data {
      var payload = Data([0, UInt8(count * 16)])
      for _ in 0..<count { payload.append(contentsOf: [0, 4 << 3]) }
      payload.append(Data(repeating: 0x21, count: 4 * count))
      return payload
    }

    static let aacMedia = [
      "m=audio 0 RTP/AVP 97", "a=rtpmap:97 mpeg4-generic/48000/2",
      "a=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;"
        + "indexdeltalength=3;config=1190",
      "a=control:audio",
    ].map { $0 + "\r\n" }.joined()

    /// AAC-LC at 48 kHz, four access units of 1024 ticks a packet.
    static let aac = AudioTiming(
      testDescription: "AAC, 4 AUs a packet", media: aacMedia, payloadType: 97,
      payload: aacPayload(4), framesPerPacket: 4, frameTicks: 1024, clockRate: 48_000)
    static let pcmu = AudioTiming(
      testDescription: "PCMU", media: pcmuAudioMediaSDP(), payloadType: 0,
      payload: Data(repeating: 0xFF, count: 160), framesPerPacket: 1, frameTicks: 160,
      clockRate: 8000)
    /// 160 ticks of two 16-bit channels: 320 samples.
    static let l16Stereo = AudioTiming(
      testDescription: "L16 stereo",
      media: ["m=audio 0 RTP/AVP 98", "a=rtpmap:98 L16/8000/2", "a=control:audio"]
        .map { $0 + "\r\n" }.joined(),
      payloadType: 98, payload: Data(count: 640), framesPerPacket: 1, frameTicks: 160,
      clockRate: 8000)
  }

  enum AudioSourceChange: String, Sendable, CaseIterable, CustomTestStringConvertible {
    /// A new SSRC with its own sequence numbers and timestamp base.
    case ssrc
    /// The same SSRC, its RTP timestamp 10 s back.
    case clockRestart
    var testDescription: String { rawValue }
  }

  @Test(
    "Audio from a new SSRC or a restarted RTP clock starts where the last frame ended",
    .timeLimit(.minutes(1)),
    arguments: [AudioTiming.aac, .pcmu, .l16Stereo], AudioSourceChange.allCases)
  func audioContinuesAfterSourceChange(
    _ codec: AudioTiming, _ change: AudioSourceChange
  ) async throws {
    let server = FakeRTSPServer(sdp: makeTestSDP(media: [codec.media]))
    server.onPlay = { _, handle in
      guard let setup = handle.setup(forStream: 0) else { return }
      let p = setup.parameters
      var sequencer = RTPTestSequencer(parameters: p, payloadType: codec.payloadType)
      var next =
        change == .ssrc
        ? RTPTestSequencer(
          sequence: p.initialSequence &+ 30_000, timestamp: p.initialRTPTime &+ 0x6000_0000,
          ssrc: p.ssrc &+ 1, payloadType: codec.payloadType)
        : RTPTestSequencer(
          sequence: p.initialSequence &+ 3, timestamp: p.initialRTPTime &- 10 * codec.clockRate,
          ssrc: p.ssrc, payloadType: codec.payloadType)
      for _ in 0..<3 {
        for packet in sequencer.accessUnit([codec.payload], timestampIncrement: codec.packetTicks) {
          handle.sendRTP(packet, stream: 0)
        }
      }
      for _ in 0..<3 {
        for packet in next.accessUnit([codec.payload], timestampIncrement: codec.packetTicks) {
          handle.sendRTP(packet, stream: 0)
        }
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    let timestamps = Shared<[Double]>([])
    let consumer = Task {
      for try await item in session.frames() {
        if case .audio(let frame) = item { timestamps.update { $0.append(frame.timestamp) } }
      }
    }
    defer { consumer.cancel() }
    // The new SSRC's first packet is dropped: its second confirms the change.
    let packets = change == .ssrc ? 5 : 6
    let count = packets * codec.framesPerPacket
    #expect(await poll { timestamps.value.count >= count })
    #expect(timestamps.value == (0..<count).map(codec.seconds(ofFrame:)))
    await session.stop()
  }

  @Test(
    "After a seek, AAC and video start together after the last access unit delivered",
    .timeLimit(.minutes(1)), arguments: [true, false])
  func aacSeekAfterLastAccessUnit(rtpInfo: Bool) async throws {
    let codec = AudioTiming.aac
    let server = FakeRTSPServer(sdp: makeTestSDP(media: [h264VideoMediaSDP(), codec.media]))
    server.configuration.includeRTPInfo = rtpInfo
    let plays = Shared(0)
    server.onPlay = { _, handle in
      guard let video = handle.setup(forStream: 0), let audio = handle.setup(forStream: 1) else {
        return
      }
      plays.update { $0 += 1 }
      // Three video frames (next one at 0.1 s). Audio: one access unit, then
      // four, ending at 5120 ticks (0.107 s), past where the smallest packet
      // gap (1024 ticks) puts its next frame. After the seek, four a packet.
      var videoSequencer = RTPTestSequencer(parameters: video.parameters)
      for index in 0..<3 {
        for packet in videoSequencer.accessUnit(
          h264AccessUnit(keyframe: index == 0), timestampIncrement: 3000)
        {
          handle.sendRTP(packet, stream: 0)
        }
      }
      var audioSequencer = RTPTestSequencer(parameters: audio.parameters, payloadType: 97)
      for count in plays.value == 1 ? [1, 4] : [4, 4] {
        for packet in audioSequencer.accessUnit(
          [AudioTiming.aacPayload(count)], timestampIncrement: UInt32(count) * 1024)
        {
          handle.sendRTP(packet, stream: 1)
        }
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    let video = Shared<[Double]>([])
    let audio = Shared<[Double]>([])
    let consumer = Task {
      for try await item in session.frames() {
        switch item {
        case .video(let frame): video.update { $0.append(frame.timestamp) }
        case .audio(let frame): audio.update { $0.append(frame.timestamp) }
        default: break
        }
      }
    }
    defer { consumer.cancel() }
    #expect(await poll { video.value.count == 3 && audio.value.count == 5 })
    try await session.play(PlayOptions(range: .npt(start: 30), immediate: true))
    #expect(await poll { video.value.count == 6 && audio.value.count == 13 })
    #expect(audio.value == (0..<13).map(codec.seconds(ofFrame:)))
    let firstVideo = try #require(video.value.dropFirst(3).first)
    #expect(abs(firstVideo - codec.seconds(ofFrame: 5)) < 0.001, "video \(firstVideo) s")
    await session.stop()
  }
}
