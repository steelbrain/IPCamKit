// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// RTCP receiver reports: reception statistics, packet layout, and what the
// session sends to a fake camera over TCP and UDP.

import Foundation
import Testing

@testable import IPCamKit

/// The fields of a received RR + SDES compound packet.
private struct ParsedReport {
  var reporterSSRC: UInt32
  var sourceSSRC: UInt32
  var fractionLost: UInt8
  var cumulativeLost: Int32
  var extendedHighestSequence: UInt32
  var jitter: UInt32
  var lastSR: UInt32
  var delaySinceLastSR: UInt32
  var cname: String
}

private func be32(_ data: Data, _ offset: Int) -> UInt32 {
  let base = data.startIndex + offset
  return data[base..<(base + 4)].reduce(0) { $0 << 8 | UInt32($1) }
}

private func parseReport(_ data: Data) -> ParsedReport? {
  let bytes = Data(data)
  guard bytes.count >= 8 + 24 + 8, bytes[0] == 0x81, bytes[1] == 201,
    UInt16(bytes[2]) << 8 | UInt16(bytes[3]) == 7
  else { return nil }
  let sdes = 32
  guard bytes[sdes] == 0x81, bytes[sdes + 1] == 202, bytes[sdes + 8] == 1 else { return nil }
  let length = Int(bytes[sdes + 9])
  guard bytes.count >= sdes + 10 + length else { return nil }
  let lost24 = be32(bytes, 12) & 0xFF_FFFF
  let signedLost = lost24 & 0x80_0000 != 0 ? Int32(lost24) - 0x100_0000 : Int32(lost24)
  return ParsedReport(
    reporterSSRC: be32(bytes, 4), sourceSSRC: be32(bytes, 8), fractionLost: bytes[12],
    cumulativeLost: signedLost, extendedHighestSequence: be32(bytes, 16),
    jitter: be32(bytes, 20), lastSR: be32(bytes, 24), delaySinceLastSR: be32(bytes, 28),
    cname: String(decoding: bytes[(sdes + 10)..<(sdes + 10 + length)], as: UTF8.self))
}

@Suite("RTCP receiver reports")
struct ReceiverReportTests {
  @Test("Statistics follow RFC 3550: loss, wrap, fraction per interval, SR timing")
  func statistics() throws {
    var stats = ReceptionStats()
    let start = ContinuousClock.now
    #expect(stats.reportBlock(now: start) == nil, "nothing to report before a packet")
    stats.recordSenderReport(ssrc: 7, ntpTimestamp: 0x1122_3344_5566_7788, arrival: start)
    // 65530...65535 and 0...3, with 65533 and 1 missing: a wrap and two losses.
    let sequences: [UInt16] = [65530, 65531, 65532, 65534, 65535, 0, 2, 3]
    for (index, sequence) in sequences.enumerated() {
      stats.recordPacket(
        ssrc: 7, sequence: sequence, rtpTimestamp: UInt32(index) * 3000,
        arrivalTicks: Int64(index) * 3000)
    }
    let maybeBlock = stats.reportBlock(now: start + .seconds(2))
    let block = try #require(maybeBlock)
    #expect(block.count == 24)
    #expect(be32(block, 0) == 7)
    #expect(block[block.startIndex + 4] == UInt8((2 << 8) / 10), "2 of 10 lost")
    #expect(be32(block, 4) & 0xFF_FFFF == 2)
    #expect(be32(block, 8) == 0x1_0003, "one wrap, highest 3")
    #expect(be32(block, 12) == 0, "evenly spaced arrivals have no jitter")
    #expect(be32(block, 16) == 0x3344_5566, "middle 32 bits of the SR's NTP time")
    #expect(be32(block, 20) == 2 * 65536, "2 s since the SR, in 1/65536 s")

    // The next interval has no loss, so the fraction resets while the total stays.
    stats.recordPacket(ssrc: 7, sequence: 4, rtpTimestamp: 8 * 3000, arrivalTicks: 8 * 3000)
    let maybeNext = stats.reportBlock(now: start + .seconds(3))
    let next = try #require(maybeNext)
    #expect(next[next.startIndex + 4] == 0)
    #expect(be32(next, 4) & 0xFF_FFFF == 2)
  }

  @Test("Jitter grows when arrivals don't match the RTP timestamps")
  func jitter() throws {
    var stats = ReceptionStats()
    stats.recordPacket(ssrc: 1, sequence: 1, rtpTimestamp: 0, arrivalTicks: 0)
    stats.recordPacket(ssrc: 1, sequence: 2, rtpTimestamp: 3000, arrivalTicks: 3000 + 1600)
    let maybeBlock = stats.reportBlock(now: .now)
    let block = try #require(maybeBlock)
    #expect(be32(block, 12) == 100, "1600 / 16")
  }

  @Test("A new SSRC restarts the statistics")
  func ssrcChange() throws {
    var stats = ReceptionStats()
    stats.recordPacket(ssrc: 1, sequence: 10, rtpTimestamp: 0, arrivalTicks: 0)
    stats.recordPacket(ssrc: 1, sequence: 20, rtpTimestamp: 0, arrivalTicks: 0)
    stats.recordPacket(ssrc: 2, sequence: 500, rtpTimestamp: 0, arrivalTicks: 0)
    let maybeBlock = stats.reportBlock(now: .now)
    let block = try #require(maybeBlock)
    #expect(be32(block, 0) == 2)
    #expect(be32(block, 4) & 0xFF_FFFF == 0)
    #expect(be32(block, 8) == 500)
  }

  @Test("A sequence restart by the same source starts new statistics, not a wrap")
  func sequenceRestart() throws {
    var stats = ReceptionStats()
    stats.recordPacket(ssrc: 3, sequence: 5000, rtpTimestamp: 0, arrivalTicks: 0)
    stats.recordPacket(ssrc: 3, sequence: 5001, rtpTimestamp: 0, arrivalTicks: 0)
    stats.recordPacket(ssrc: 3, sequence: 100, rtpTimestamp: 0, arrivalTicks: 0)
    stats.recordPacket(ssrc: 3, sequence: 101, rtpTimestamp: 0, arrivalTicks: 0)
    let maybeBlock = stats.reportBlock(now: .now)
    let block = try #require(maybeBlock)
    #expect(be32(block, 4) & 0xFF_FFFF == 0, "nothing lost")
    #expect(be32(block, 8) == 101, "no wrap counted")
  }

  @Test("The compound packet is an RR followed by an SDES CNAME, 32-bit aligned")
  func layout() throws {
    var stats = ReceptionStats()
    stats.recordPacket(ssrc: 0xAABB_CCDD, sequence: 1, rtpTimestamp: 0, arrivalTicks: 0)
    let maybeBlock = stats.reportBlock(now: .now)
    let block = try #require(maybeBlock)
    for cname in ["", "a", "ab", "abc", "abcd", String(repeating: "x", count: 300)] {
      let packet = RTCPReport.receiverReport(
        reporterSSRC: 0x0102_0304, blocks: [block], cname: cname)
      #expect(packet.count % 4 == 0)
      let report = try #require(parseReport(packet), "cname \(cname.count)")
      #expect(report.reporterSSRC == 0x0102_0304)
      #expect(report.sourceSSRC == 0xAABB_CCDD)
      #expect(report.cname == String(cname.prefix(255)))
      // The library's own validator accepts it as a compound packet.
      #expect(throws: Never.self) { try ReceivedCompoundPacket.validate(packet) }
    }
  }

  @Test("The session reports loss and sender-report timing", arguments: [Transport.tcp, .udp])
  func sessionSendsReports(transport: Transport) async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    let reportNTP = ntpTimestamp(for: Date())
    let expectedHighest = Box<UInt32>(0)
    server.onPlay = { _, handle in
      guard let setup = handle.setup(forStream: 0) else { return }
      Task {
        handle.sendRTCP(
          makeRTCPSenderReport(
            ssrc: setup.parameters.ssrc, ntp: reportNTP,
            rtpTimestamp: setup.parameters.initialRTPTime),
          stream: 0)
        var sequencer = RTPTestSequencer(parameters: setup.parameters)
        for index in 0..<20 {
          if index == 10 { sequencer.sequence &+= 3 }  // three packets lost
          for packet in sequencer.accessUnit(
            h264AccessUnit(keyframe: index == 0), timestampIncrement: 6000)
          {
            handle.sendRTP(packet, stream: 0)
          }
          try? await Task.sleep(for: .milliseconds(5))
        }
        expectedHighest.value = UInt32(sequencer.sequence &- 1)
      }
    }
    try await server.start()
    defer { server.stop() }

    let session = RTSPClientSession(
      url: server.url, credentials: nil, transport: transport, userAgent: "IPCamKit",
      onDiagnostic: nil, keepaliveInterval: nil, receiverReportInterval: .milliseconds(200))
    _ = try await session.start()
    let consumer = Task {
      var frames = 0
      for try await item in session.frames() {
        if case .video = item { frames += 1 }
      }
      return frames
    }
    defer { consumer.cancel() }

    // Wait for a report that covers all 20 frames.
    var report: ParsedReport?
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      let reports = server.receivedMedia
        .filter { $0.stream == 0 && $0.isRTCP }
        .compactMap { parseReport($0.data) }
      if let last = reports.last, expectedHighest.value != 0,
        last.extendedHighestSequence == expectedHighest.value
      {
        report = last
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let final = try #require(report, "no report covering the stream arrived")
    let setup = try #require(server.sessionHandles.first?.setup(forStream: 0))
    #expect(final.sourceSSRC == setup.parameters.ssrc)
    #expect(final.cumulativeLost == 3)
    #expect(final.lastSR == UInt32(truncatingIfNeeded: reportNTP >> 16))
    #expect(final.delaySinceLastSR > 0)
    #expect(!final.cname.isEmpty)
    await session.stop()
  }
}

extension ReceiverReportTests {
  @Test("Over UDP the RTCP hole punch is a valid, empty receiver report")
  func udpHolePunchIsValidRTCP() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url, transport: .udp)
    _ = try await session.start()
    var punch: Data?
    let deadline = ContinuousClock.now + .seconds(3)
    while punch == nil && ContinuousClock.now < deadline {
      punch = server.receivedMedia.first { $0.stream == 0 && $0.isRTCP }?.data
      try await Task.sleep(for: .milliseconds(20))
    }
    await session.stop()
    let packet = try #require(punch, "no RTCP datagram arrived")
    #expect(Array(packet.prefix(4)) == [0x80, 201, 0x00, 0x01], "RR, no report blocks")
    #expect(throws: Never.self) { try ReceivedCompoundPacket.validate(packet) }
  }
}

extension ReceiverReportTests {
  @Test(
    "After a plain seek, receiver reports don't count the jump to the new sequence as loss",
    arguments: [false, true])
  func seekDoesNotReportLoss(newPacketsFirst: Bool) async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    let sequencer = Box<RTPTestSequencer?>(nil)
    let plays = Box(0)
    server.transformResponse = { [weak server] request, response in
      guard request.method == "PLAY", let server, let handle = server.sessionHandles.first,
        let setup = handle.setup(forStream: 0)
      else { return response }
      plays.value += 1
      guard plays.value == 2, var old = sequencer.value else { return response }
      // The previous playback's last packets arrive ahead of the response,
      // whose RTP-Info starts the new playback far ahead.
      for _ in 0..<5 {
        for packet in old.accessUnit(h264AccessUnit(keyframe: false), timestampIncrement: 3000) {
          handle.sendRTP(packet, stream: 0)
        }
      }
      // Then, optionally, the new playback's first 3 frames.
      var next = RTPTestSequencer(parameters: setup.parameters)
      next.sequence = 20000
      for index in 0..<(newPacketsFirst ? 3 : 0) {
        for packet in next.accessUnit(
          h264AccessUnit(keyframe: index == 0), timestampIncrement: 3000)
        {
          handle.sendRTP(packet, stream: 0)
        }
      }
      let initial = "seq=\(setup.parameters.initialSequence);"
      var response = response
      response.headers = response.headers.map { header in
        guard header.name == "RTP-Info" else { return header }
        return (header.name, header.value.replacingOccurrences(of: initial, with: "seq=20000;"))
      }
      return response
    }
    let reportNTP = ntpTimestamp(for: Date())
    server.onPlay = { _, handle in
      guard let setup = handle.setup(forStream: 0) else { return }
      if plays.value == 1 {
        handle.sendRTCP(
          makeRTCPSenderReport(
            ssrc: setup.parameters.ssrc, ntp: reportNTP,
            rtpTimestamp: setup.parameters.initialRTPTime),
          stream: 0)
      }
      var next = RTPTestSequencer(parameters: setup.parameters)
      if plays.value == 2 { next.sequence = 20000 }
      for index in 0..<20 {
        let packets = next.accessUnit(
          h264AccessUnit(keyframe: index == 0), timestampIncrement: 3000)
        if plays.value == 2 && newPacketsFirst && index < 3 { continue }
        for packet in packets { handle.sendRTP(packet, stream: 0) }
      }
      sequencer.value = next
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: nil, transport: .tcp, userAgent: "IPCamKit",
      onDiagnostic: nil, keepaliveInterval: nil, receiverReportInterval: .milliseconds(50))
    _ = try await session.start()
    try await Task.sleep(for: .milliseconds(200))
    try await session.play(PlayOptions(range: .npt(start: 5), immediate: true))
    var latest: ParsedReport?
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      latest =
        server.receivedMedia.filter { $0.stream == 0 && $0.isRTCP }
        .compactMap { parseReport($0.data) }.last
      if let latest, latest.extendedHighestSequence & 0xFFFF >= 20000 { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let report = try #require(latest)
    #expect(report.extendedHighestSequence & 0xFFFF >= 20000)
    #expect(report.cumulativeLost <= 1, "\(report.cumulativeLost) reported lost")
    // The sender report from before the seek is still the last one received.
    #expect(report.lastSR == UInt32(truncatingIfNeeded: reportNTP >> 16))
    await session.stop()
  }
}

extension ReceiverReportTests {
  @Test("Receiver reports' jitter skips the packet where the sender's RTP clock restarted")
  func jitterIgnoresClockRestart() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onPlay = { _, handle in
      guard let setup = handle.setup(forStream: 0) else { return }
      // 20 frames, then 20 more whose RTP clock restarted 100 s back (same
      // SSRC, sequence numbers continuing).
      var sequencer = RTPTestSequencer(parameters: setup.parameters)
      for index in 0..<40 {
        if index == 20 { sequencer.timestamp &-= 100 * 90000 }
        for packet in sequencer.accessUnit(
          h264AccessUnit(keyframe: index % 20 == 0), timestampIncrement: 3000)
        {
          handle.sendRTP(packet, stream: 0)
        }
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: nil, transport: .tcp, userAgent: "IPCamKit",
      onDiagnostic: nil, keepaliveInterval: nil, receiverReportInterval: .milliseconds(50))
    _ = try await session.start()
    var latest: ParsedReport?
    let deadline = ContinuousClock.now + .seconds(5)
    let lastSequence = UInt32(FakeRTPStreamParameters.defaults(forStream: 0).initialSequence) + 39
    while ContinuousClock.now < deadline {
      latest =
        server.receivedMedia.filter { $0.stream == 0 && $0.isRTCP }
        .compactMap { parseReport($0.data) }.last
      if let latest, latest.extendedHighestSequence >= lastSequence { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let report = try #require(latest)
    #expect(report.extendedHighestSequence >= lastSequence)
    // Frames sent at once, 3000 ticks apart, give a jitter of at most 3000
    // ticks; the restart's 9,000,000-tick step would add over 500,000.
    #expect(report.jitter < 10000, "jitter \(report.jitter)")
    await session.stop()
  }

  /// The reports for later streams went out after TEARDOWN when stop() ran
  /// while an earlier stream's report was being sent.
  @Test("No receiver report follows TEARDOWN", .timeLimit(.minutes(1)))
  func noReportAfterTeardown() async throws {
    let sdp = makeTestSDP(media: [
      h264VideoMediaSDP(), pcmuAudioMediaSDP(), onvifMetadataMediaSDP(),
    ])
    var late: [Int] = []
    for trial in 0..<15 {
      let server = FakeRTSPServer(sdp: sdp)
      let atTeardown = Box<Int?>(nil)
      server.onRequest = { [weak server] request in
        if request.method == "TEARDOWN" { atTeardown.value = server?.receivedMedia.count }
        return nil
      }
      server.onPlay = { _, handle in
        Task {
          var sequencers: [Int: RTPTestSequencer] = [:]
          for (stream, payloadType) in [(0, UInt8(96)), (1, 0), (2, 107)] {
            guard let setup = handle.setup(forStream: stream) else { return }
            sequencers[stream] = RTPTestSequencer(
              parameters: setup.parameters, payloadType: payloadType)
          }
          for round in 0..<2000 {
            for stream in 0..<3 {
              let payload =
                stream == 0
                ? h264AccessUnit(keyframe: round == 0) : [Data(repeating: 0x7F, count: 160)]
              for packet in sequencers[stream]!.accessUnit(payload, timestampIncrement: 160) {
                guard handle.sendRTP(packet, stream: stream) else { return }
              }
            }
            try? await Task.sleep(for: .milliseconds(1))
          }
        }
      }
      try await server.start()
      let session = RTSPClientSession(
        url: server.url, credentials: nil, transport: .tcp, userAgent: "IPCamKit",
        onDiagnostic: nil, keepaliveInterval: nil, receiverReportInterval: .microseconds(200))
      // Reports are sent at the priority start() ran at; a stop() at a
      // higher one must still not overtake one already being sent.
      _ = try await Task(priority: .low) { try await session.start() }.value
      try await Task.sleep(for: .milliseconds(60 + trial * 3))
      await Task(priority: .high) { await session.stop() }.value
      try await Task.sleep(for: .milliseconds(50))
      if let count = atTeardown.value, server.receivedMedia.count > count {
        late.append(trial)
      }
      server.stop()
    }
    #expect(late.isEmpty, "trials with a report after TEARDOWN: \(late)")
  }
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
