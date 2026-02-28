// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Ports all 16 H.264 depacketization tests from upstream src/codec/h264.rs

import Foundation
import Testing

@testable import IPCamKit

// MARK: - Test Helpers

/// Create a ReceivedRTPPacket with the given parameters.
func makePacket(
  seq: UInt16, timestamp: Timestamp, mark: Bool, payload: Data, loss: UInt16 = 0
) -> ReceivedRTPPacket {
  // Use ssrc: 0 and payloadType: 0 to match upstream test data
  let builder = ReceivedPacketBuilder(
    ctx: .dummy, streamId: 0, sequenceNumber: seq,
    timestamp: timestamp, payloadType: 0, ssrc: 0, mark: mark, loss: loss)
  return try! builder.build(payload: payload).get()
}

let ts0 = Timestamp(timestamp: 0, clockRate: 90000, start: 0)!
let ts1 = Timestamp(timestamp: 1, clockRate: 90000, start: 0)!

let dahuaFmtp =
  "packetization-mode=1;profile-level-id=64001E;sprop-parameter-sets=Z2QAHqwsaoLA9puCgIKgAAADACAAAAMD0IAA,aO4xshsA"

let reolinkFmtp =
  "packetization-mode=1;profile-level-id=640033;sprop-parameter-sets=Z2QAM6wVFKCgL/lQ,aO48sA=="

// MARK: - Tests

@Suite("H.264 Depacketizer Tests")
struct H264DepacketizerTests {

  /// Test 1: Basic depacketization with SEI + STAP-A + FU-A.
  @Test("Depacketize SEI + STAP-A + FU-A")
  func depacketize() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: dahuaFmtp)

    // Packet 1: Plain SEI
    try d.push(
      makePacket(seq: 0, timestamp: ts0, mark: false, payload: Data([0x06]) + Data("plain".utf8)))
    #expect(d.pull() == nil)

    // Packet 2: STAP-A with two SEI NALs
    var stapPayload = Data([0x18])  // STAP-A type
    stapPayload.append(contentsOf: [0x00, 0x09])  // length=9
    stapPayload.append(0x06)  // SEI header
    stapPayload.append(Data("stap-a 1".utf8))
    stapPayload.append(contentsOf: [0x00, 0x09])  // length=9
    stapPayload.append(0x06)  // SEI header
    stapPayload.append(Data("stap-a 2".utf8))
    try d.push(makePacket(seq: 1, timestamp: ts0, mark: false, payload: stapPayload))
    #expect(d.pull() == nil)

    // Packet 3: FU-A start
    try d.push(
      makePacket(
        seq: 2, timestamp: ts0, mark: false,
        payload: Data([0x7C, 0x86]) + Data("fu-a start, ".utf8)))
    #expect(d.pull() == nil)

    // Packet 4: FU-A middle
    try d.push(
      makePacket(
        seq: 3, timestamp: ts0, mark: false,
        payload: Data([0x7C, 0x06]) + Data("fu-a middle, ".utf8)))
    #expect(d.pull() == nil)

    // Packet 5: FU-A end
    try d.push(
      makePacket(
        seq: 4, timestamp: ts0, mark: true,
        payload: Data([0x7C, 0x46]) + Data("fu-a end".utf8)))

    guard case .success(.videoFrame(let frame)) = d.pull() else {
      Issue.record("Expected video frame")
      return
    }

    var expected = Data()
    // NAL 1: SEI "plain" (len=6)
    expected.append(contentsOf: [0x00, 0x00, 0x00, 0x06, 0x06])
    expected.append(Data("plain".utf8))
    // NAL 2: SEI "stap-a 1" (len=9)
    expected.append(contentsOf: [0x00, 0x00, 0x00, 0x09, 0x06])
    expected.append(Data("stap-a 1".utf8))
    // NAL 3: SEI "stap-a 2" (len=9)
    expected.append(contentsOf: [0x00, 0x00, 0x00, 0x09, 0x06])
    expected.append(Data("stap-a 2".utf8))
    // NAL 4: FU-A reassembled (len=34=0x22, header=0x66)
    expected.append(contentsOf: [0x00, 0x00, 0x00, 0x22, 0x66])
    expected.append(Data("fu-a start, fu-a middle, fu-a end".utf8))

    #expect(frame.data == expected)
    #expect(d.seenInconsistentFuANalHdr == false)
    #expect(d.pull() == nil)
  }

  /// Test 2: FU-A with reserved bit set (Longse camera quirk).
  @Test("FU-A reserved bit set (Longse camera)")
  func depacketizeReservedBitSet() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: dahuaFmtp)

    // FU-A start with reserved bit (0xA6 = START=1, reserved=1, type=6)
    try d.push(
      makePacket(
        seq: 2, timestamp: ts0, mark: false,
        payload: Data([0x7C, 0xA6]) + Data("fu-a start, ".utf8)))
    #expect(d.pull() == nil)

    // FU-A middle with reserved bit
    try d.push(
      makePacket(
        seq: 3, timestamp: ts0, mark: false,
        payload: Data([0x7C, 0x26]) + Data("fu-a middle, ".utf8)))
    #expect(d.pull() == nil)

    // FU-A end with reserved bit
    try d.push(
      makePacket(
        seq: 4, timestamp: ts0, mark: true,
        payload: Data([0x7C, 0x66]) + Data("fu-a end".utf8)))

    guard case .success(.videoFrame(let frame)) = d.pull() else {
      Issue.record("Expected video frame")
      return
    }

    var expected = Data()
    expected.append(contentsOf: [0x00, 0x00, 0x00, 0x22, 0x66])
    expected.append(Data("fu-a start, fu-a middle, fu-a end".utf8))
    #expect(frame.data == expected)
  }

  /// Test 3: Reolink bad framing at start (SPS with incorrect mark bit).
  @Test("Reolink bad framing at start")
  func depacketizeReolinkBadFramingAtStart() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: reolinkFmtp)

    // SPS with incorrect mark
    let spsData = Data([
      0x67, 0x64, 0x00, 0x33, 0xAC, 0x15, 0x14, 0xA0,
      0xA0, 0x2F, 0xF9, 0x50,
    ])
    try d.push(makePacket(seq: 0, timestamp: ts0, mark: true, payload: spsData))
    #expect(d.pull() == nil)  // SPS can't end AU

    // PPS
    let ppsData = Data([0x68, 0xEE, 0x3C, 0xB0])
    try d.push(makePacket(seq: 1, timestamp: ts0, mark: false, payload: ppsData))
    #expect(d.pull() == nil)

    // IDR slice with different timestamp
    try d.push(
      makePacket(
        seq: 2, timestamp: ts1, mark: true,
        payload: Data([0x65]) + Data("slice".utf8)))

    guard case .success(.videoFrame(let frame)) = d.pull() else {
      Issue.record("Expected video frame")
      return
    }

    // Should use ts1 (the IDR timestamp, not the SPS timestamp)
    #expect(frame.timestamp == ts1)

    var expected = Data()
    // SPS
    expected.append(contentsOf: [0x00, 0x00, 0x00, 0x0C])
    expected.append(spsData)
    // PPS
    expected.append(contentsOf: [0x00, 0x00, 0x00, 0x04])
    expected.append(ppsData)
    // IDR slice
    expected.append(contentsOf: [0x00, 0x00, 0x00, 0x06, 0x65])
    expected.append(Data("slice".utf8))

    #expect(frame.data == expected)
  }

  /// Test 4: Reolink GOP boundary (SPS/PPS with wrong timestamp).
  @Test("Reolink GOP boundary")
  func depacketizeReolinkGOPBoundary() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: reolinkFmtp)

    // Non-IDR slice
    try d.push(
      makePacket(
        seq: 0, timestamp: ts0, mark: true,
        payload: Data([0x01]) + Data("slice".utf8)))

    guard case .success(.videoFrame(let frame1)) = d.pull() else {
      Issue.record("Expected first frame")
      return
    }
    #expect(frame1.timestamp == ts0)
    var expectedFrame1 = Data()
    expectedFrame1.append(contentsOf: [0x00, 0x00, 0x00, 0x06, 0x01])
    expectedFrame1.append(Data("slice".utf8))
    #expect(frame1.data == expectedFrame1)

    // SPS with OLD timestamp (same as previous frame)
    let spsData = Data([
      0x67, 0x64, 0x00, 0x33, 0xAC, 0x15, 0x14, 0xA0,
      0xA0, 0x2F, 0xF9, 0x50,
    ])
    try d.push(makePacket(seq: 1, timestamp: ts0, mark: false, payload: spsData))
    #expect(d.pull() == nil)

    // PPS with OLD timestamp
    let ppsData = Data([0x68, 0xEE, 0x3C, 0xB0])
    try d.push(makePacket(seq: 2, timestamp: ts0, mark: false, payload: ppsData))
    #expect(d.pull() == nil)

    // IDR slice with correct NEW timestamp
    try d.push(
      makePacket(
        seq: 3, timestamp: ts1, mark: true,
        payload: Data([0x65]) + Data("slice".utf8)))

    guard case .success(.videoFrame(let frame2)) = d.pull() else {
      Issue.record("Expected second frame")
      return
    }
    #expect(frame2.timestamp == ts1)

    // Verify frame2 data content (upstream assertion at h264.rs line 1722-1727)
    var expectedFrame2 = Data()
    expectedFrame2.append(contentsOf: [0x00, 0x00, 0x00, 0x0C])
    expectedFrame2.append(spsData)
    expectedFrame2.append(contentsOf: [0x00, 0x00, 0x00, 0x04])
    expectedFrame2.append(ppsData)
    expectedFrame2.append(contentsOf: [0x00, 0x00, 0x00, 0x06, 0x65])
    expectedFrame2.append(Data("slice".utf8))
    #expect(frame2.data == expectedFrame2)
  }

  /// Test 5: Parameter change mid-stream.
  @Test("Parameter change mid-stream")
  func depacketizeParameterChange() throws {
    let fmtp =
      "packetization-mode=1;profile-level-id=4d002a;sprop-parameter-sets=Z00AKp2oHgCJ+WbgICAoAAADAAgAAAMAfCA=,aO48gA=="
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: fmtp)

    #expect(d.parameters != nil)
    #expect(d.parameters!.genericParameters.pixelDimensions?.width == 1920)
    #expect(d.parameters!.genericParameters.pixelDimensions?.height == 1080)

    // New SPS with different resolution
    let newSPS = Data([
      0x67, 0x4D, 0x40, 0x1E, 0x9A, 0x64, 0x05, 0x01,
      0xEF, 0xF3, 0x50, 0x10, 0x10, 0x14, 0x00, 0x00,
      0x0F, 0xA0, 0x00, 0x01, 0x38, 0x80, 0x10,
    ])
    try d.push(makePacket(seq: 0, timestamp: ts0, mark: false, payload: newSPS))
    #expect(d.pull() == nil)

    // Same PPS
    try d.push(
      makePacket(
        seq: 1, timestamp: ts0, mark: false,
        payload: Data([0x68, 0xEE, 0x3C, 0x80])))
    #expect(d.pull() == nil)

    // IDR slice
    try d.push(
      makePacket(
        seq: 2, timestamp: ts0, mark: true,
        payload: Data([0x65]) + Data("slice".utf8)))

    guard case .success(.videoFrame(let frame)) = d.pull() else {
      Issue.record("Expected frame")
      return
    }
    #expect(frame.hasNewParameters == true)
    #expect(d.parameters!.genericParameters.pixelDimensions?.width == 640)
    #expect(d.parameters!.genericParameters.pixelDimensions?.height == 480)
  }

  /// Test 6: Empty format-specific params.
  @Test("Empty format-specific params rejected")
  func depacketizeEmpty() {
    #expect(throws: (any Error).self) {
      _ = try H264Parameters.parseFormatSpecificParams("")
    }
    #expect(throws: (any Error).self) {
      _ = try H264Parameters.parseFormatSpecificParams(" ")
    }
  }

  /// Test 7: GW Security params with Annex B separators.
  @Test("GW Security params with Annex B")
  func gwSecurityParams() throws {
    let fmtp =
      "packetization-mode=1;profile-level-id=5046302;sprop-parameter-sets=Z00AHpWoLQ9puAgICBAAAAAB,aO48gAAAAAE="
    let p = try H264Parameters.parseFormatSpecificParams(fmtp)
    #expect(p.genericParameters.rfc6381Codec == "avc1.4D001E")
  }

  /// Test 8: Bad format-specific params with in-band recovery.
  @Test("Bad format-specific params, in-band recovery")
  func badFormatSpecificParams() throws {
    let badFmtp =
      "packetization-mode=1;profile-level-id=00f004;sprop-parameter-sets=6QDwBE/LCAAAH0gAB1TgIAAAAAA=,AAAAAA=="

    // Bad params should fail
    #expect(throws: (any Error).self) {
      _ = try H264Parameters.parseFormatSpecificParams(badFmtp)
    }

    // But depacketizer should still work with in-band params
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: badFmtp)
    #expect(d.parameters == nil)

    // In-band SPS
    try d.push(
      makePacket(
        seq: 0, timestamp: ts0, mark: false,
        payload: Data([
          0x67, 0x4D, 0x00, 0x28, 0xE9, 0x00, 0xF0, 0x04,
          0x4F, 0xCB, 0x08, 0x00, 0x00, 0x1F, 0x48, 0x00,
          0x07, 0x54, 0xE0, 0x20,
        ])))
    #expect(d.pull() == nil)

    // In-band PPS
    try d.push(
      makePacket(
        seq: 1, timestamp: ts0, mark: false,
        payload: Data([0x68, 0xEA, 0x8F, 0x20])))
    #expect(d.pull() == nil)

    // IDR slice
    try d.push(
      makePacket(
        seq: 2, timestamp: ts0, mark: true,
        payload: Data([0x65]) + Data("idr slice".utf8)))

    guard case .success(.videoFrame(let frame)) = d.pull() else {
      Issue.record("Expected frame")
      return
    }
    #expect(frame.hasNewParameters == true)
    #expect(d.parameters != nil)
  }

  /// Test 9: SPS with extra trailing bytes.
  @Test("SPS with extra trailing bytes")
  func spsWithExtraTrailingBytes() throws {
    var d = try H264Depacketizer(
      clockRate: 90000, formatSpecificParams: "packetization-mode=1;profile-level-id=640033")
    #expect(d.parameters == nil)

    // SPS with extra trailing byte
    try d.push(
      makePacket(
        seq: 0, timestamp: ts0, mark: false,
        payload: Data([
          0x67, 0x64, 0x00, 0x33, 0xAC, 0x15, 0x14, 0xA0,
          0xA0, 0x3D, 0xA1, 0x00, 0x00, 0x04, 0xF6, 0x00,
          0x00, 0x63, 0x38, 0x04, 0x04,
        ])))
    #expect(d.pull() == nil)

    // PPS
    try d.push(
      makePacket(
        seq: 1, timestamp: ts0, mark: false,
        payload: Data([0x68, 0xEE, 0x3C, 0xB0])))
    #expect(d.pull() == nil)

    // IDR
    try d.push(
      makePacket(
        seq: 2, timestamp: ts0, mark: true,
        payload: Data([0x65]) + Data("idr slice".utf8)))

    guard case .success(.videoFrame(let frame)) = d.pull() else {
      Issue.record("Expected frame")
      return
    }
    #expect(frame.hasNewParameters == true)
    #expect(d.parameters != nil)
  }

  /// Test 10 & 11: Annex B within single NAL packets.
  @Test("Annex B in single NAL packet")
  func parseAnnexBSingleNAL() throws {
    var d = try H264Depacketizer(
      clockRate: 90000, formatSpecificParams: "packetization-mode=1;profile-level-id=640033")

    let annexBNals = Data(annexBNALsBytes)
    try d.push(makePacket(seq: 0, timestamp: ts0, mark: true, payload: annexBNals))

    guard case .success(.videoFrame(let frame)) = d.pull() else {
      Issue.record("Expected frame")
      return
    }
    #expect(frame.data == Data(prefixedNALsBytes))
  }

  /// Test 13: Inconsistent FU-A headers between fragments.
  @Test("Inconsistent FU-A headers tolerated")
  func allowInconsistentFuAHeaders() throws {
    let fmtp =
      "profile-level-id=TQAf;packetization-mode=1;sprop-parameter-sets=J00AH+dAKALdgKUFBQXwAAADABAAAAMCiwEAAtxoAAIlUX//AoA=,KO48gA=="
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: fmtp)

    // FU-A start: nal_ref_idc=1, type=1 (non-IDR)
    try d.push(
      makePacket(
        seq: 0, timestamp: ts0, mark: false,
        payload: Data([0x3C, 0x81]) + Data("start of non-idr".utf8)))
    #expect(d.pull() == nil)

    // FU-A end: nal type changes to 7 (SPS!) — inconsistent
    try d.push(
      makePacket(
        seq: 1, timestamp: ts0, mark: true,
        payload: Data([0x3C, 0x47]) + Data("a wild sps appeared".utf8)))

    guard case .success(.videoFrame(let frame)) = d.pull() else {
      Issue.record("Expected frame")
      return
    }

    var expected = Data()
    expected.append(contentsOf: [0x00, 0x00, 0x00, 0x24, 0x21])  // len=36, header=0x21
    expected.append(Data("start of non-idr".utf8))
    expected.append(Data("a wild sps appeared".utf8))
    #expect(frame.data == expected)
    #expect(d.seenInconsistentFuANalHdr == true)
  }

  /// Test 14: Empty FU-A fragment.
  @Test("Empty FU-A fragment handled")
  func emptyFragment() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: dahuaFmtp)

    // FU-A start
    try d.push(
      makePacket(
        seq: 0, timestamp: ts0, mark: false,
        payload: Data([0x7C, 0x86]) + Data("start, ".utf8)))
    #expect(d.pull() == nil)

    // FU-A middle with empty payload
    try d.push(
      makePacket(
        seq: 1, timestamp: ts0, mark: false,
        payload: Data([0x7C, 0x06])))
    #expect(d.pull() == nil)

    // FU-A end
    try d.push(
      makePacket(
        seq: 2, timestamp: ts0, mark: true,
        payload: Data([0x7C, 0x46]) + Data("end".utf8)))

    guard case .success(.videoFrame(let frame)) = d.pull() else {
      Issue.record("Expected frame")
      return
    }

    var expected = Data()
    expected.append(contentsOf: [0x00, 0x00, 0x00, 0x0B, 0x66])  // len=11, header=0x66
    expected.append(Data("start, end".utf8))
    #expect(frame.data == expected)
  }

  /// Test 15: Annex B parsing unit test.
  /// Ports upstream `annex_b_parsing` test from h264.rs.
  @Test("Annex B parsing edge cases")
  func annexBParsing() {
    // Empty/trivial inputs should produce no NALs
    for input in [
      Data(),
      Data([0x00]),
      Data([0x00, 0x00, 0x01]),
      Data([0x00, 0x00, 0x00, 0x01]),
    ] {
      var nalCount = 0
      processAnnexB(input) { _ in
        nalCount += 1
        return .success(())
      }
      #expect(
        nalCount == 0, "Expected no NALs from input \(input.map { String(format: "%02x", $0) })")
    }

    // Single NAL unit without start codes
    do {
      var nals: [Data] = []
      processAnnexB(Data([1, 2, 3, 4])) {
        nals.append($0)
        return .success(())
      }
      #expect(nals.count == 1)
      #expect(nals[0] == Data([1, 2, 3, 4]))
    }

    // Single NAL with leading 3-byte start code
    do {
      var nals: [Data] = []
      processAnnexB(Data([0, 0, 1, 1, 2, 3, 4])) {
        nals.append($0)
        return .success(())
      }
      #expect(nals.count == 1)
      #expect(nals[0] == Data([1, 2, 3, 4]))
    }

    // Single NAL with trailing 3-byte start code (stripped)
    do {
      var nals: [Data] = []
      processAnnexB(Data([1, 2, 3, 4, 0, 0, 1])) {
        nals.append($0)
        return .success(())
      }
      #expect(nals.count == 1)
      #expect(nals[0] == Data([1, 2, 3, 4]))
    }

    // Multiple NALs
    do {
      var nals: [Data] = []
      processAnnexB(Data([0, 0, 1, 1, 0, 0, 1, 2, 3, 4])) {
        nals.append($0)
        return .success(())
      }
      #expect(nals.count == 2)
      #expect(nals[0] == Data([1]))
      #expect(nals[1] == Data([2, 3, 4]))
    }

    // Error propagation: handler returning error should propagate
    // (upstream test: Rust lines 2303-2308)
    do {
      let result = processAnnexB(Data([1, 2, 3, 4, 0, 0, 1])) { _ in
        .failure(DepacketizeError("asdf"))
      }
      if case .failure(let err) = result {
        #expect(err.description == "asdf")
      } else {
        Issue.record("Expected handler error to propagate")
      }
    }

    // Error path: forbidden sequence 00 00 02
    do {
      let result = processAnnexB(Data([1, 2, 0, 0, 2])) { _ in .success(()) }
      if case .failure(let err) = result {
        #expect(err.description.contains("forbidden"))
      } else {
        Issue.record("Expected error for forbidden sequence 00 00 02")
      }
    }

    // Error path: 00 00 00 not followed by 01
    do {
      let result = processAnnexB(Data([1, 0, 0, 0, 3])) { _ in .success(()) }
      if case .failure(let err) = result {
        #expect(err.description.contains("forbidden"))
      } else {
        Issue.record("Expected error for forbidden sequence 00 00 00")
      }
    }
  }

  /// Test 16: FU-A Annex B combinatorial test.
  /// Ports upstream `parse_annex_b_fu_a` test — splits ANNEX_B_NALS
  /// at every possible FU-A boundary and verifies output matches PREFIXED_NALS.
  @Test("Annex B across FU-A boundaries")
  func parseAnnexBFuA() throws {
    let annexB = annexBNALsBytes
    let expected = Data(prefixedNALsBytes)

    // Try various split points for first packet.
    // Matches upstream: first_pkt_len in 2..(ANNEX_B_NALS.len()-1), skip if sum >= len
    for firstPktLen in 2..<(annexB.count - 1) {
      for middlePktLen in [0, 1, 2, 3] {
        // Upstream: if first_pkt_len + middle_pkt_len >= ANNEX_B_NALS.len() { continue; }
        if firstPktLen + middlePktLen >= annexB.count { continue }
        let lastStart = firstPktLen + middlePktLen

        var d = try H264Depacketizer(
          clockRate: 90000,
          formatSpecificParams: "packetization-mode=1;profile-level-id=640033")

        // Build FU indicator and headers
        let fuIndicator: UInt8 = (annexB[0] & 0b1110_0000) | 28  // NRI + FU-A type
        let nalType = annexB[0] & 0b0001_1111

        // First packet (START), seq=0
        var firstPayload = Data([fuIndicator, nalType | 0b1000_0000])
        firstPayload.append(contentsOf: annexB[1..<firstPktLen])
        try d.push(makePacket(seq: 0, timestamp: ts0, mark: false, payload: firstPayload))

        // Middle packet (if any), seq=1
        if middlePktLen > 0 {
          var middlePayload = Data([fuIndicator, nalType])
          middlePayload.append(contentsOf: annexB[firstPktLen..<lastStart])
          try d.push(makePacket(seq: 1, timestamp: ts0, mark: false, payload: middlePayload))
        }

        // Last packet (END), always seq=2 (matching upstream)
        var lastPayload = Data([fuIndicator, nalType | 0b0100_0000])
        lastPayload.append(contentsOf: annexB[lastStart...])
        try d.push(makePacket(seq: 2, timestamp: ts0, mark: true, payload: lastPayload))

        guard case .success(.videoFrame(let frame)) = d.pull() else {
          Issue.record(
            "Expected frame for firstPktLen=\(firstPktLen), middlePktLen=\(middlePktLen)")
          continue
        }
        #expect(
          frame.data == expected,
          "Mismatch for firstPktLen=\(firstPktLen), middlePktLen=\(middlePktLen)")
      }
    }
  }

  /// Test 17: Timestamp change mid-FU-A produces error then recovery.
  @Test("Skip end of fragment on timestamp change")
  func skipEndOfFragment() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)

    // FU-A start
    try d.push(
      makePacket(
        seq: 0, timestamp: ts0, mark: false,
        payload: Data([0x7C, 0x86]) + Data("fu-a start, ".utf8)))
    #expect(d.pull() == nil)

    // Plain SEI with different timestamp — triggers error
    // Upstream uses sequence_number: 0 for both packets
    try d.push(
      makePacket(
        seq: 0, timestamp: ts1, mark: true,
        payload: Data([0x06]) + Data("plain".utf8)))

    // First pull: error about timestamp change mid-fragment
    // Upstream asserts exact error string
    if case .failure(let err) = d.pull() {
      #expect(
        err.description
          == "timestamp changed from 0 (mod-2^32: 0), npt 0.000 to 1 (mod-2^32: 1), npt 0.000 in the middle of a fragmented NAL"
      )
    } else {
      Issue.record("Expected error")
    }

    // Second pull: the recovered frame
    guard case .success(.videoFrame(let frame)) = d.pull() else {
      Issue.record("Expected recovered frame")
      return
    }
    var expected = Data()
    expected.append(contentsOf: [0x00, 0x00, 0x00, 0x06, 0x06])
    expected.append(Data("plain".utf8))
    #expect(frame.data == expected)

    // Third pull: nothing
    #expect(d.pull() == nil)
  }
}

// MARK: - Test Data

/// ANNEX_B_NALS from upstream test (44 bytes).
/// Contains SPS + Annex B separator + PPS + Annex B separator + IDR slice with embedded 00 00.
let annexBNALsBytes: [UInt8] = [
  // SPS (20 bytes)
  0x67, 0x64, 0x00, 0x33, 0xAC, 0x15, 0x14, 0xA0,
  0xA0, 0x3D, 0xA1, 0x00, 0x00, 0x04, 0xF6, 0x00,
  0x00, 0x63, 0x38, 0x04,
  // Annex B separator (4 bytes)
  0x00, 0x00, 0x00, 0x01,
  // PPS (4 bytes)
  0x68, 0xEE, 0x3C, 0xB0,
  // Annex B separator (3 bytes)
  0x00, 0x00, 0x01,
  // IDR slice (13 bytes, with embedded 00 00 that are NOT separators)
  0x65, 0x69, 0x64, 0x72, 0x20, 0x73, 0x6C, 0x69,
  0x00, 0x00, 0x63, 0x65, 0x00,
]

/// PREFIXED_NALS from upstream test (48 bytes).
/// Same NALs as above but with 4-byte length prefixes instead of Annex B separators.
/// Trailing zero byte from IDR slice is stripped (trailing_zero_8bits).
let prefixedNALsBytes: [UInt8] = [
  // SPS: 4-byte length prefix (0x14=20) + 20 bytes
  0x00, 0x00, 0x00, 0x14,
  0x67, 0x64, 0x00, 0x33, 0xAC, 0x15, 0x14, 0xA0,
  0xA0, 0x3D, 0xA1, 0x00, 0x00, 0x04, 0xF6, 0x00,
  0x00, 0x63, 0x38, 0x04,
  // PPS: 4-byte length prefix (0x04=4) + 4 bytes
  0x00, 0x00, 0x00, 0x04,
  0x68, 0xEE, 0x3C, 0xB0,
  // IDR: 4-byte length prefix (0x0C=12) + 12 bytes (trailing 0x00 stripped)
  0x00, 0x00, 0x00, 0x0C,
  0x65, 0x69, 0x64, 0x72, 0x20, 0x73, 0x6C, 0x69,
  0x00, 0x00, 0x63, 0x65,
]
