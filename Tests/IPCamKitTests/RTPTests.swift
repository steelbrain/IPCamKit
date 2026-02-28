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
}

// MARK: - InorderParser Tests

@Suite("InorderParser Tests")
struct InorderParserTests {

  /// Port of upstream geovision_pt50_packet test.
  /// Tests that payload_type=50 packets are silently dropped.
  @Test("Geovision PT=50 packets are skipped")
  func geovisionPT50() throws {
    var timeline = try Timeline(start: nil, clockRate: 90_000, enforceMaxJumpSecs: nil)
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

    var timeline = try Timeline(start: nil, clockRate: 90_000, enforceMaxJumpSecs: nil)
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
}
