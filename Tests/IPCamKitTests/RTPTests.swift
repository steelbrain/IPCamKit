// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Ports upstream RTP, RTCP, Timeline, ChannelMapping, and InorderParser tests

import Foundation
import Testing

@testable import IPCamKit

// MARK: - RTP Packet Tests

@Suite("RTP Packet Tests")
struct RTPPacketTests {

  /// Port of upstream pkt_with_extension test from rtp.rs line 370.
  /// Tests RTP packet with extension header — verifies correct payload range calculation.
  @Test("RTP packet with extension header")
  func pktWithExtension() throws {
    let data = Data([
      0x90, 0x60, 0x4C, 0x62, 0x01, 0xBB, 0x3C, 0xB5,
      0x1C, 0x04, 0x15, 0xB1, 0xAB, 0xAC, 0x00, 0x03,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x01, 0x67, 0x64, 0x00, 0x32,
      0xAC, 0x3C, 0x6B, 0x81, 0x7C, 0x05, 0x46, 0x9B,
      0x82, 0x80, 0x82, 0xA0, 0x00, 0x00, 0x03, 0x00,
      0x20, 0x00, 0x00, 0x07, 0x90, 0x80, 0x00,
    ])

    let pkt = try RawRTPPacket.parse(data).get()
    #expect(pkt.payloadRange == 28..<55)
    #expect(pkt.payload[pkt.payload.startIndex] == 0x67)
  }

  @Test("RTP packet builder")
  func packetBuilder() throws {
    let builder = RTPPacketBuilder(
      sequenceNumber: 0x1234,
      timestamp: 141_000,
      payloadType: 105,
      ssrc: 0x0D25_614E,
      mark: true
    )
    let pkt = try builder.build(payload: Data("foo".utf8)).get()
    #expect(pkt.mark == true)
    #expect(pkt.sequenceNumber == 0x1234)
    #expect(pkt.rtpTimestamp == 141_000)
    #expect(pkt.ssrc == 0x0D25_614E)
    #expect(pkt.payloadType == 105)
    #expect(pkt.payload == Data("foo".utf8))
  }
}

// MARK: - RTCP Packet Tests

@Suite("RTCP Packet Tests")
struct RTCPPacketTests {

  /// Port of upstream `dahua` test from rtcp.rs.
  /// Tests parsing a Sender Report + Source Description compound packet.
  @Test("Dahua Sender Report + Source Description")
  func dahua() throws {
    let buf = Data([
      // Sender Report (28 bytes)
      0x80, 0xC8, 0x00, 0x06,
      0x66, 0x42, 0x6A, 0xE1,  // SSRC
      0xE4, 0x36, 0x2F, 0x99, 0xCC, 0xCC, 0xCC, 0xCC,  // NTP timestamp
      0x85, 0x2E, 0xF8, 0x07,  // RTP timestamp
      0x00, 0x2A, 0x43, 0x33,  // packet count
      0x2F, 0x4C, 0x34, 0x1D,  // octet count
      // Source Description (20 bytes)
      0x81, 0xCA, 0x00, 0x04,
      0x66, 0x42, 0x6A, 0xE1,  // SSRC
      0x01, 0x06, 0x28, 0x6E, 0x6F, 0x6E, 0x65, 0x29,  // CNAME "(none)"
      0x00, 0x00, 0x00, 0x00,  // padding
    ])

    // Parse first packet (SR)
    let (pkt1, rest1) = try RTCPPacketRef.parse(buf)
    #expect(pkt1.payloadType == 200)  // SR
    let sr = try pkt1.asSenderReport()
    #expect(sr != nil)
    #expect(sr!.ntpTimestamp == NtpTimestamp(rawValue: 0xE436_2F99_CCCC_CCCC))
    #expect(sr!.rtpTimestamp == 0x852E_F807)

    // Parse second packet (SDES)
    let (pkt2, rest2) = try RTCPPacketRef.parse(rest1)
    #expect(pkt2.payloadType == 202)  // SDES
    #expect(rest2.isEmpty)
  }

  /// Port of upstream `padding` test from rtcp.rs.
  /// Tests RTCP packet with padding.
  @Test("RTCP packet with padding")
  func padding() throws {
    let buf = Data([
      // RTCP packet with padding
      0xA7,  // V=2, P=1, count=7
      0x00,  // PT=0
      0x00, 0x02,  // length=2 (3 words = 12 bytes)
      // payload "asdf"
      0x61, 0x73, 0x64, 0x66,
      // padding (4 bytes, last byte = 4)
      0x00, 0x00, 0x00, 0x04,
      // remaining data
      0x72, 0x65, 0x73, 0x74,  // "rest"
    ])

    let (pkt, rest) = try RTCPPacketRef.parse(buf)
    #expect(pkt.count == 7)
    // payload is buf[4..8] = "asdf"
    let payload = pkt.buf[pkt.buf.startIndex + 4..<pkt.buf.startIndex + pkt.payloadEnd]
    #expect(payload == Data("asdf".utf8))
    #expect(rest == Data("rest".utf8))
  }
}

// MARK: - Timeline Tests

@Suite("Timeline Tests")
struct TimelineTests {

  /// Port of upstream `timeline` test from timeline.rs.
  @Test("Timeline basic operations")
  func timeline() throws {
    // clock_rate=0 rejected
    #expect(throws: (any Error).self) {
      _ = try Timeline(start: 0, clockRate: 0, enforceMaxJumpSecs: nil)
    }

    // clock_rate=u32::MAX with enforcement rejected (overflow)
    #expect(throws: (any Error).self) {
      _ = try Timeline(start: 0, clockRate: UInt32.max, enforceMaxJumpSecs: 10)
    }

    // Excessive forward jump rejected
    do {
      var t = try Timeline(start: 100, clockRate: 90_000, enforceMaxJumpSecs: 10)
      #expect(throws: (any Error).self) {
        _ = try t.advanceTo(100 + (10 * 90_000) + 1)
      }
    }

    // Backward jump rejected
    do {
      var t = try Timeline(start: 100, clockRate: 90_000, enforceMaxJumpSecs: 10)
      #expect(throws: (any Error).self) {
        _ = try t.advanceTo(99)
      }
    }

    // place() allows backward timestamps (for RTCP)
    do {
      var t = try Timeline(start: 100, clockRate: 90_000, enforceMaxJumpSecs: 10)
      let placed = try t.place(99)
      #expect(placed.elapsed == -1)
      let advanced = try t.advanceTo(101)
      #expect(advanced.elapsed == 1)
    }

    // No enforcement allows anything
    do {
      var t = try Timeline(start: 100, clockRate: 90_000, enforceMaxJumpSecs: nil)
      _ = try t.advanceTo(100 + (10 * 90_000) + 1)
    }
    do {
      var t = try Timeline(start: 100, clockRate: 90_000, enforceMaxJumpSecs: nil)
      _ = try t.advanceTo(99)
    }

    // Normal usage
    do {
      var t = try Timeline(start: 42, clockRate: 90_000, enforceMaxJumpSecs: 10)
      let ts1 = try t.advanceTo(83)
      #expect(ts1.elapsed == 83 - 42)
      let ts2 = try t.advanceTo(453)
      #expect(ts2.elapsed == 453 - 42)
    }

    // Wraparound
    do {
      var t = try Timeline(start: UInt32.max, clockRate: 90_000, enforceMaxJumpSecs: 10)
      let ts = try t.advanceTo(5)
      #expect(ts.elapsed == 6)  // 5 - (UInt32.max) wraps to +6
    }

    // No initial rtptime
    do {
      var t = try Timeline(start: nil, clockRate: 90_000, enforceMaxJumpSecs: 10)
      let ts = try t.advanceTo(218_250_000)
      #expect(ts.elapsed == 0)
    }
  }

  /// Port of upstream `cast` test from timeline.rs.
  /// Verifies i64-to-i32 truncation behavior used in delta computation.
  @Test("Integer casting behavior")
  func cast() {
    let a: Int64 = 0x1_FFFF_FFFF
    let b: Int64 = 0x1_0000_0000
    #expect(Int32(truncatingIfNeeded: a) == -1)
    #expect(Int32(truncatingIfNeeded: b) == 0)
  }

  /// An unsynced camera commonly sends an NTP timestamp before (or at) the Unix
  /// epoch; it must clamp to 1970 rather than wrapping to a far-future date
  /// (finding #51).
  @Test("NtpTimestamp before the Unix epoch clamps to 1970")
  func ntpBeforeEpochClamps() {
    let epochRaw: UInt64 = 2_208_988_800 << 32
    #expect(NtpTimestamp(rawValue: 0).date == Date(timeIntervalSince1970: 0))
    #expect(NtpTimestamp(rawValue: epochRaw).date == Date(timeIntervalSince1970: 0))
    // A normal post-1970 value (1 second after epoch) is unchanged.
    #expect(NtpTimestamp(rawValue: epochRaw + (1 << 32)).date == Date(timeIntervalSince1970: 1))
    // 1969 (top bit set, before the Unix epoch) still clamps.
    #expect(
      NtpTimestamp(rawValue: epochRaw - (86_400 << 32)).date == Date(timeIntervalSince1970: 0))
  }

  @Test("NTP seconds with the top bit clear are after the 2036 rollover (RFC 4330 era 1)")
  func ntpEraOne() {
    // One hour after 2036-02-07T06:28:16Z, when the 32-bit seconds field wraps.
    let wrap: TimeInterval = 4_294_967_296 - 2_208_988_800
    #expect(NtpTimestamp(rawValue: 3600 << 32).date == Date(timeIntervalSince1970: wrap + 3600))
    let lastEraZero = NtpTimestamp(rawValue: 0xFFFF_FFFF << 32).date
    #expect(lastEraZero == Date(timeIntervalSince1970: wrap - 1))
  }
}

// MARK: - Channel Mapping Tests

@Suite("Channel Mapping Tests")
struct ChannelMappingTests {

  /// Port of upstream channel_mappings test from channel_mapping.rs.
  @Test("Channel mapping assignment and lookup")
  func channelMappings() throws {
    var mappings = ChannelMappings()
    #expect(mappings.nextUnassigned() == 0)
    #expect(mappings.lookup(0) == nil)

    try mappings.assign(channelId: 0, streamIndex: 42)

    // Already assigned
    #expect(throws: (any Error).self) {
      try mappings.assign(channelId: 0, streamIndex: 43)
    }
    // Odd channel ID
    #expect(throws: (any Error).self) {
      try mappings.assign(channelId: 1, streamIndex: 43)
    }

    #expect(
      mappings.lookup(0) == ChannelMapping(streamIndex: 42, channelType: .rtp))
    #expect(
      mappings.lookup(1) == ChannelMapping(streamIndex: 42, channelType: .rtcp))

    #expect(mappings.nextUnassigned() == 2)

    // Odd channel rejected
    #expect(throws: (any Error).self) {
      try mappings.assign(channelId: 9, streamIndex: 26)
    }
    try mappings.assign(channelId: 8, streamIndex: 26)

    #expect(
      mappings.lookup(8) == ChannelMapping(streamIndex: 26, channelType: .rtp))
    #expect(
      mappings.lookup(9) == ChannelMapping(streamIndex: 26, channelType: .rtcp))

    // Slot 1 (channel 2) still free
    #expect(mappings.nextUnassigned() == 2)
  }

  /// streamIndex is an opaque SDP media index, not a channel slot, so a large
  /// value must be accepted (finding #35 removed a bogus `< 255` guard).
  @Test("Channel mapping accepts a large stream index")
  func channelMappingLargeStreamIndex() throws {
    var mappings = ChannelMappings()
    try mappings.assign(channelId: 0, streamIndex: 300)
    #expect(mappings.lookup(0) == ChannelMapping(streamIndex: 300, channelType: .rtp))
  }
}

// MARK: - InorderParser Tests

@Suite("InorderParser Tests")
struct InorderParserTests {

  /// Port of upstream geovision_pt50_packet test.
  /// Tests that payload_type=50 packets are silently dropped.
  @Test("Geovision PT=50 packets are skipped")
  func geovisionPT50() throws {
    let timeline = try Timeline(start: nil, clockRate: 90_000, enforceMaxJumpSecs: nil)
    var parser = InorderParser(
      ssrc: 0x0D25_614E, nextSeq: nil, isTcp: true, timeline: timeline)

    // Normal packet
    let pkt1 = RTPPacketBuilder(
      sequenceNumber: 0x1234,
      timestamp: 141_000,
      payloadType: 105,
      ssrc: 0x0D25_614E,
      mark: true
    )
    let data1 = try pkt1.build(payload: Data("foo".utf8)).get().data
    let result1 = try parser.rtp(
      data: data1, ctx: .dummy, streamId: 0, streamCtx: .dummy)
    #expect(result1 != nil)

    // PT=50 packet (should be skipped)
    let pkt2 = RTPPacketBuilder(
      sequenceNumber: 0x1234,
      timestamp: 141_000,
      payloadType: 50,
      ssrc: 0x0D25_614E,
      mark: true
    )
    let data2 = try pkt2.build(payload: Data("bar".utf8)).get().data
    let result2 = try parser.rtp(
      data: data2, ctx: .dummy, streamId: 0, streamCtx: .dummy)
    #expect(result2 == nil)
  }

  /// Port of upstream out_of_order test.
  /// Tests that out-of-order packets are dropped on UDP.
  @Test("Out-of-order packets dropped on UDP")
  func outOfOrder() throws {
    let streamCtx = StreamContext.udp(
      UdpStreamContext(
        localIP: "0.0.0.0", peerIP: "0.0.0.0",
        localRtpPort: 0, peerRtpPort: 0))

    let timeline = try Timeline(start: nil, clockRate: 90_000, enforceMaxJumpSecs: nil)
    var parser = InorderParser(
      ssrc: 0x0D25_614E, nextSeq: nil, isTcp: false, timeline: timeline)

    // Packet with seq=2 arrives first
    let pkt1 = RTPPacketBuilder(
      sequenceNumber: 2, timestamp: 2, payloadType: 96,
      ssrc: 0x0D25_614E, mark: true)
    let data1 = try pkt1.build(payload: Data("pkt 2".utf8)).get().data
    let result1 = try parser.rtp(
      data: data1, ctx: .dummy, streamId: 0, streamCtx: streamCtx)
    #expect(result1 != nil)
    #expect(result1!.timestamp.elapsed == 0)  // First packet, elapsed=0

    // Packet with seq=1 arrives late (out of order) — should be dropped
    let pkt2 = RTPPacketBuilder(
      sequenceNumber: 1, timestamp: 1, payloadType: 96,
      ssrc: 0x0D25_614E, mark: true)
    let data2 = try pkt2.build(payload: Data("pkt 1".utf8)).get().data
    let result2 = try parser.rtp(
      data: data2, ctx: .dummy, streamId: 0, streamCtx: streamCtx)
    #expect(result2 == nil)

    // Packet with seq=3 arrives normally
    let pkt3 = RTPPacketBuilder(
      sequenceNumber: 3, timestamp: 3, payloadType: 96,
      ssrc: 0x0D25_614E, mark: true)
    let data3 = try pkt3.build(payload: Data("pkt 3".utf8)).get().data
    let result3 = try parser.rtp(
      data: data3, ctx: .dummy, streamId: 0, streamCtx: streamCtx)
    #expect(result3 != nil)
    #expect(result3!.timestamp.elapsed == 1)  // delta from start=2 to 3
  }

  /// Out-of-order packets on TCP-interleaved transport are dropped (matching UDP)
  /// and surfaced via the onDiagnostic callback as `.warning`. Previously this case
  /// threw and tore down the session — see CHANGELOG 0.2.0.
  @Test("Out-of-order packets dropped on TCP and diagnostic emitted")
  func outOfOrderTcp() throws {
    let captured = DiagnosticBox()

    let timeline = try Timeline(start: nil, clockRate: 90_000, enforceMaxJumpSecs: nil)
    var parser = InorderParser(
      ssrc: 0x0D25_614E, nextSeq: nil, isTcp: true, timeline: timeline,
      onDiagnostic: { captured.append($0) })

    // Packet with seq=2 arrives first
    let pkt1 = RTPPacketBuilder(
      sequenceNumber: 2, timestamp: 2, payloadType: 96,
      ssrc: 0x0D25_614E, mark: true)
    let data1 = try pkt1.build(payload: Data("pkt 2".utf8)).get().data
    let result1 = try parser.rtp(
      data: data1, ctx: .dummy, streamId: 0, streamCtx: .dummy)
    #expect(result1 != nil)
    #expect(captured.events.isEmpty)

    // Packet with seq=1 arrives late — must drop without throwing and emit a warning
    let pkt2 = RTPPacketBuilder(
      sequenceNumber: 1, timestamp: 1, payloadType: 96,
      ssrc: 0x0D25_614E, mark: true)
    let data2 = try pkt2.build(payload: Data("pkt 1".utf8)).get().data
    let result2 = try parser.rtp(
      data: data2, ctx: .dummy, streamId: 0, streamCtx: .dummy)
    #expect(result2 == nil)
    #expect(captured.events.count == 1)
    #expect(captured.events.first?.severity == .warning)
    #expect(captured.events.first?.message.contains("seq=1") == true)
    #expect(captured.events.first?.message.contains("expected=3") == true)
  }

  /// A foreign-SSRC RTCP Sender Report under the default dropPackets policy must
  /// be dropped BEFORE it anchors the timeline, and warn exactly once per stream.
  @Test("Foreign-SSRC RTCP SR is dropped without corrupting the timeline (#9/#33)")
  func foreignRtcpSRDoesNotAnchorTimeline() throws {
    let captured = DiagnosticBox()
    let timeline = try Timeline(start: nil, clockRate: 90_000, enforceMaxJumpSecs: nil)
    var parser = InorderParser(
      ssrc: 0x0D25_614E, nextSeq: nil, isTcp: true, timeline: timeline,
      onDiagnostic: { captured.append($0) })

    // Foreign SR arrives before any RTP packet: dropped, one warning, timeline
    // untouched.
    let sr1 = makeSenderReport(ssrc: 0xDEAD_BEEF, rtpTimestamp: 1_000_000)
    #expect(try parser.rtcp(ctx: .dummy, streamId: 0, data: sr1) == nil)
    #expect(captured.events.count == 1)
    #expect(captured.events.first?.severity == .warning)

    // A second foreign SR is still dropped, but no second diagnostic (latched).
    let sr2 = makeSenderReport(ssrc: 0xDEAD_BEEF, rtpTimestamp: 2_000_000)
    #expect(try parser.rtcp(ctx: .dummy, streamId: 0, data: sr2) == nil)
    #expect(captured.events.count == 1)

    // The next RTP packet anchors the timeline to ITS own timestamp (elapsed 0),
    // proving the dropped foreign SR did not anchor the origin at 1_000_000.
    let rtp = try RTPPacketBuilder(
      sequenceNumber: 100, timestamp: 5_000_000, payloadType: 96,
      ssrc: 0x0D25_614E, mark: true
    ).build(payload: Data("x".utf8)).get().data
    let recv = try parser.rtp(data: rtp, ctx: .dummy, streamId: 0, streamCtx: .dummy)
    #expect(recv?.timestamp.elapsed == 0)
  }

  /// A malformed RTP datagram is dropped (with a single warning), never fatal —
  /// one bad packet must not tear down the stream (finding #1).
  @Test("Malformed RTP packet is dropped, not fatal")
  func malformedRtpDropped() throws {
    let captured = DiagnosticBox()
    let timeline = try Timeline(start: nil, clockRate: 90_000, enforceMaxJumpSecs: nil)
    var parser = InorderParser(
      ssrc: nil, nextSeq: nil, isTcp: true, timeline: timeline,
      onDiagnostic: { captured.append($0) })

    // Fewer than 12 bytes is not a valid RTP packet -> RawRTPPacket.parse fails.
    #expect(
      try parser.rtp(data: Data([0x80, 0x60]), ctx: .dummy, streamId: 0, streamCtx: .dummy) == nil)
    #expect(captured.events.count == 1)
    #expect(captured.events.first?.severity == .warning)

    // A second malformed packet drops silently (latched).
    #expect(try parser.rtp(data: Data([0x80]), ctx: .dummy, streamId: 0, streamCtx: .dummy) == nil)
    #expect(captured.events.count == 1)

    // A subsequent valid packet still processes.
    let good = try RTPPacketBuilder(
      sequenceNumber: 5, timestamp: 100, payloadType: 96, ssrc: 0x1111_2222, mark: true
    ).build(payload: Data("ok".utf8)).get().data
    #expect(try parser.rtp(data: good, ctx: .dummy, streamId: 0, streamCtx: .dummy) != nil)
  }

  /// An RTP SSRC mismatch drops by default, throws only under .abortSession, and
  /// is accepted under .processPackets (finding #1).
  @Test("RTP SSRC mismatch is policy-gated")
  func rtpSsrcMismatchPolicies() throws {
    func makeParser(_ policy: UnknownRtcpSsrcPolicy, _ box: DiagnosticBox) throws -> InorderParser {
      let tl = try Timeline(start: nil, clockRate: 90_000, enforceMaxJumpSecs: nil)
      return InorderParser(
        ssrc: 0xAAAA_AAAA, nextSeq: nil, isTcp: false, timeline: tl,
        unknownRtcpSsrcPolicy: policy, onDiagnostic: { box.append($0) })
    }
    func packet(ssrc: UInt32) -> Data {
      try! RTPPacketBuilder(
        sequenceNumber: 1, timestamp: 1, payloadType: 96, ssrc: ssrc, mark: true
      ).build(payload: Data("x".utf8)).get().data
    }

    // dropPackets: mismatch dropped + warned once; matching SSRC still processes.
    let dropBox = DiagnosticBox()
    var dropParser = try makeParser(.dropPackets, dropBox)
    #expect(
      try dropParser.rtp(
        data: packet(ssrc: 0xDEAD_BEEF), ctx: .dummy, streamId: 0, streamCtx: .dummy) == nil)
    #expect(dropBox.events.count == 1)
    #expect(
      try dropParser.rtp(
        data: packet(ssrc: 0xAAAA_AAAA), ctx: .dummy, streamId: 0, streamCtx: .dummy) != nil)

    // abortSession: mismatch throws.
    var abortParser = try makeParser(.abortSession, DiagnosticBox())
    #expect(throws: RTSPError.self) {
      _ = try abortParser.rtp(
        data: packet(ssrc: 0xDEAD_BEEF), ctx: .dummy, streamId: 0, streamCtx: .dummy)
    }

    // processPackets: mismatch accepted.
    var processParser = try makeParser(.processPackets, DiagnosticBox())
    #expect(
      try processParser.rtp(
        data: packet(ssrc: 0xDEAD_BEEF), ctx: .dummy, streamId: 0, streamCtx: .dummy) != nil)
  }
}

/// Build a minimal RTCP Sender Report (PT=200, no report blocks) for tests.
private func makeSenderReport(ssrc: UInt32, rtpTimestamp: UInt32, ntp: UInt64 = 0) -> Data {
  func be32(_ v: UInt32) -> [UInt8] {
    [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
  }
  var d = Data([0x80, 0xC8, 0x00, 0x06])  // V=2, PT=200, length=6 words => 28 bytes
  d.append(contentsOf: be32(ssrc))
  for shift in stride(from: 56, through: 0, by: -8) {
    d.append(UInt8((ntp >> shift) & 0xFF))  // 8-byte NTP timestamp
  }
  d.append(contentsOf: be32(rtpTimestamp))
  d.append(contentsOf: [0, 0, 0, 0])  // packet count
  d.append(contentsOf: [0, 0, 0, 0])  // octet count
  return d
}

/// Thread-safe collector for diagnostic events captured during a test.
private final class DiagnosticBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _events: [RTSPDiagnostic] = []

  func append(_ event: RTSPDiagnostic) {
    lock.lock()
    defer { lock.unlock() }
    _events.append(event)
  }

  var events: [RTSPDiagnostic] {
    lock.lock()
    defer { lock.unlock() }
    return _events
  }
}

@Suite("Seek start mapping")
struct SeekStartMappingTests {
  private func packet(
    _ parser: inout InorderParser, sequence: UInt16, timestamp: UInt32
  ) throws -> ReceivedRTPPacket {
    let data = makeRTP(
      sequence: sequence, timestamp: timestamp, ssrc: 9, payloadType: 96, marker: true,
      payload: Data(count: 4))
    return try #require(
      try parser.rtp(data: data, ctx: .dummy, streamId: 0, streamCtx: .dummy))
  }

  /// 30,000 s at 90 kHz is 2.7e9 ticks, past a 32-bit RTP timestamp step.
  @Test(
    "After a seek a stream's first packet goes to the common start, even hours ahead",
    arguments: [7.5, 30_000])
  func farTarget(_ target: Double) throws {
    // A stream that sent nothing before the seek.
    var silent = InorderParser(
      ssrc: nil, nextSeq: nil, isTcp: true, timeline: try Timeline(start: nil, clockRate: 90_000))
    silent.restartSequenceTracking(continuingAt: target)
    let first = try packet(&silent, sequence: 1, timestamp: 5)
    #expect(abs(first.timestamp.elapsedSeconds - target) < 0.001)
    let next = try packet(&silent, sequence: 2, timestamp: 3005)
    #expect(abs(next.timestamp.elapsedSeconds - target - 3000.0 / 90_000) < 0.001)

    // A stream that sent one packet, then nothing.
    var quiet = InorderParser(
      ssrc: nil, nextSeq: nil, isTcp: true, timeline: try Timeline(start: nil, clockRate: 90_000))
    _ = try packet(&quiet, sequence: 1, timestamp: 5)
    quiet.restartSequenceTracking(continuingAt: target)
    let resumed = try packet(&quiet, sequence: 700, timestamp: 123_456)
    #expect(abs(resumed.timestamp.elapsedSeconds - target) < 0.001)

    // RTP-Info mapping a stream's `rtptime` there.
    var mapped = InorderParser(
      ssrc: nil, nextSeq: nil, isTcp: true, timeline: try Timeline(start: nil, clockRate: 90_000))
    _ = try packet(&mapped, sequence: 1, timestamp: 5)
    mapped.restartSequenceTracking(continuingAt: nil)
    let applied = mapped.applySeekRTPInfo(seq: 50, rtptime: 777, ssrc: nil, elapsedSeconds: target)
    #expect(applied)
    let fromInfo = try packet(&mapped, sequence: 50, timestamp: 777)
    #expect(abs(fromInfo.timestamp.elapsedSeconds - target) < 0.001)
  }

  /// A metadata stream sending one document every 5 s mustn't push the common
  /// start 3 s past the video; B-frames (sent in decoding order) mustn't put
  /// it at a timestamp already delivered.
  @Test("The seek start follows the highest timestamp, one capped step on")
  func nextAfterHighest() throws {
    var video = try Timeline(start: 0, clockRate: 90_000)
    for index in 0..<300 { _ = try video.advanceTo(UInt32(index * 3600)) }  // 25 fps, 11.96 s
    var metadata = try Timeline(start: 0, clockRate: 90_000)
    for seconds in [0, 5, 10] { _ = try metadata.advanceTo(UInt32(seconds * 90_000)) }
    let videoNext = try #require(video.nextElapsedSeconds)
    let metadataNext = try #require(metadata.nextElapsedSeconds)
    #expect(abs(videoNext - 12.0) < 0.001)
    #expect(abs(metadataNext - 10.5) < 0.001)
    #expect(max(videoNext, metadataNext) < 12.1)

    // I0 P3 B1 B2, 3000 ticks a frame.
    var bFrames = try Timeline(start: 0, clockRate: 90_000)
    for ticks in [0, 9000, 3000, 6000] { _ = try bFrames.advanceTo(UInt32(ticks)) }
    let next = try #require(bFrames.nextElapsedSeconds)
    #expect(next > 9000.0 / 90_000)
    var continued = bFrames
    continued.rebase(continuingWith: 777)
    #expect(try continued.advanceTo(777).elapsedSeconds > 9000.0 / 90_000)

    // I0 P3 B1 B2 P6 B4: the last forward step (B2 to P6) is 4 frames, the
    // frame interval 1, so the next frame is at 7.
    var reordered = try Timeline(start: 0, clockRate: 90_000)
    for frame in [0, 3, 1, 2, 6, 4] { _ = try reordered.advanceTo(UInt32(frame * 3000)) }
    let reorderedNext = try #require(reordered.nextElapsedSeconds)
    #expect(abs(reorderedNext - 7.0 * 3000 / 90_000) < 0.0001)

    // A single timestamp (one keyframe, sent as several packets) gives no
    // interval: the next frame is still after it, one tick on.
    var single = try Timeline(start: 0, clockRate: 90_000)
    for _ in 0..<3 { _ = try single.advanceTo(4500) }
    let singleNext = try #require(single.nextElapsedSeconds)
    #expect(singleNext > 4500.0 / 90_000)
    #expect(singleNext < 4502.0 / 90_000)
  }
}

/// Audio frames last past their own timestamp, and an aggregated AAC packet's
/// access units are timestamped past the packet's: a new source, a clock
/// restart or a seek must continue after the end of the last frame delivered.
@Suite("Audio continuity across a timeline rebase")
struct AudioRebaseContinuityTests {
  /// An in-order parser and audio depacketizer wired as the session wires
  /// them: the end of every frame delivered is noted on the timeline.
  private struct Receiver {
    var parser: InorderParser
    var depacketizer: AudioDepacketizer
    let channels: UInt16?
    var frames: [AudioFrame] = []

    init(encodingName: String, clockRate: UInt32, channels: UInt16?, fmtp: String?) throws {
      parser = InorderParser(
        ssrc: nil, nextSeq: nil, isTcp: true,
        timeline: try Timeline(start: nil, clockRate: clockRate))
      depacketizer = try AudioDepacketizer.create(
        encodingName: encodingName, clockRate: clockRate, channels: channels,
        formatSpecificParams: fmtp)
      self.channels = channels
    }

    mutating func send(seq: UInt16, ts: UInt32, ssrc: UInt32, payload: Data) throws {
      let data = makeRTP(
        sequence: seq, timestamp: ts, ssrc: ssrc, payloadType: 96, marker: true, payload: payload)
      guard let pkt = try parser.rtp(data: data, ctx: .dummy, streamId: 0, streamCtx: .dummy)
      else { return }
      try depacketizer.push(pkt)
      while let result = depacketizer.pull() {
        guard case .success(.audioFrame(let frame)) = result else { continue }
        parser.timeline.noteFrameEnd(
          frame.timestamp.timestamp + Int64(depacketizer.ticks(of: frame, channels: channels)))
        frames.append(frame)
      }
    }
  }

  /// AAC-LC at 48 kHz (1024 ticks an access unit), AAC-hbr.
  private static let aacFmtp =
    "streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;"
    + "config=1190"

  /// An AAC-hbr payload carrying `count` access units of 4 bytes.
  private static func aacPayload(_ count: Int) -> Data {
    var payload = Data([0, UInt8(count * 16)])
    for _ in 0..<count { payload.append(contentsOf: [0, 4 << 3]) }
    payload.append(Data(repeating: 0x21, count: 4 * count))
    return payload
  }

  enum Change: String, CaseIterable, CustomTestStringConvertible {
    case ssrc, clockRestart, seek
    var testDescription: String { rawValue }
  }

  @Test(
    "Aggregated AAC continues after the last access unit delivered",
    .timeLimit(.minutes(1)), arguments: Change.allCases)
  func aacAggregated(_ change: Change) throws {
    var receiver = try Receiver(
      encodingName: "mpeg4-generic", clockRate: 48_000, channels: 2, fmtp: Self.aacFmtp)
    let expected: [Int64]
    switch change {
    case .ssrc:
      try receiver.send(seq: 10, ts: 1_000_000, ssrc: 1, payload: Self.aacPayload(4))
      try receiver.send(seq: 11, ts: 1_004_096, ssrc: 1, payload: Self.aacPayload(4))
      // The first packet of the new SSRC is dropped; the second confirms it.
      try receiver.send(seq: 500, ts: 9_000_000, ssrc: 2, payload: Self.aacPayload(4))
      try receiver.send(seq: 501, ts: 9_004_096, ssrc: 2, payload: Self.aacPayload(4))
      expected = (0..<12).map { Int64($0) * 1024 }
    case .clockRestart:
      try receiver.send(seq: 10, ts: 1_000_000, ssrc: 1, payload: Self.aacPayload(4))
      try receiver.send(seq: 11, ts: 1_004_096, ssrc: 1, payload: Self.aacPayload(4))
      // More than 5 s behind: the sender's RTP clock restarted.
      try receiver.send(seq: 12, ts: 1_000, ssrc: 1, payload: Self.aacPayload(4))
      expected = (0..<12).map { Int64($0) * 1024 }
    case .seek:
      // One access unit, then four: the smallest packet gap (1024) is less
      // than the last packet's four access units.
      try receiver.send(seq: 10, ts: 1_000_000, ssrc: 1, payload: Self.aacPayload(1))
      try receiver.send(seq: 11, ts: 1_001_024, ssrc: 1, payload: Self.aacPayload(4))
      let next = try #require(receiver.parser.nextElapsedSeconds)
      #expect(next == 5120.0 / 48_000)
      receiver.parser.restartSequenceTracking(continuingAt: next)
      receiver.depacketizer = try AudioDepacketizer.create(
        encodingName: "mpeg4-generic", clockRate: 48_000, channels: 2,
        formatSpecificParams: Self.aacFmtp)
      try receiver.send(seq: 9000, ts: 77_777, ssrc: 3, payload: Self.aacPayload(4))
      expected = (0..<9).map { Int64($0) * 1024 }
    }
    #expect(receiver.frames.map(\.timestamp.elapsed) == expected)
  }

  @Test(
    "Sample-based audio from a new SSRC starts where the last frame ended",
    .timeLimit(.minutes(1)),
    arguments: [
      ("pcmu", nil, 160),
      // 160 ticks of 2 channels of 2 bytes: `frameLength` counts 320 samples.
      ("l16", 2, 640),
    ] as [(String, UInt16?, Int)])
  func sampleBasedSSRC(encodingName: String, channels: UInt16?, bytes: Int) throws {
    var receiver = try Receiver(
      encodingName: encodingName, clockRate: 8000, channels: channels, fmtp: nil)
    let payload = Data(repeating: 0x7F, count: bytes)
    try receiver.send(seq: 10, ts: 1000, ssrc: 1, payload: payload)
    try receiver.send(seq: 11, ts: 1160, ssrc: 1, payload: payload)
    try receiver.send(seq: 500, ts: 50_000, ssrc: 2, payload: payload)
    try receiver.send(seq: 501, ts: 50_160, ssrc: 2, payload: payload)
    let ticks = receiver.frames.map {
      receiver.depacketizer.ticks(of: $0, channels: channels)
    }
    #expect(receiver.frames.map(\.timestamp.elapsed) == [0, 160, 320])
    #expect(ticks == [160, 160, 160])
  }

  @Test("A seek mapping behind the end of the last frame is refused", .timeLimit(.minutes(1)))
  func mappingBehindFrameEnd() throws {
    var timeline = try Timeline(start: 0, clockRate: 48_000)
    _ = try timeline.advanceTo(0)
    _ = try timeline.advanceTo(1024)
    timeline.noteFrameEnd(5120)
    timeline.noteFrameEnd(2048)  // An earlier end doesn't move it back.
    #expect(timeline.nextElapsedSeconds == 5120.0 / 48_000)
    let behind = timeline.rebase(mapping: 9, toElapsedSeconds: 3000.0 / 48_000)
    #expect(!behind)
    let atEnd = timeline.rebase(mapping: 9, toElapsedSeconds: 5120.0 / 48_000)
    #expect(atEnd)
    let first = try timeline.advanceTo(9)
    #expect(first.elapsed == 5120)
  }
}
