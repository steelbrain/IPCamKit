// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Ports H.265 depacketization tests from upstream src/codec/h265.rs and h265/nal.rs

import Foundation
import Testing

@testable import IPCamKit

// MARK: - Test Helpers

private let h265Ts0 = Timestamp(timestamp: 0, clockRate: 90000, start: 0)!
private let h265Ts1 = Timestamp(timestamp: 1, clockRate: 90000, start: 0)!

private func makeH265Packet(
  seq: UInt16, timestamp: Timestamp, mark: Bool, payload: Data, loss: UInt16 = 0
) -> ReceivedRTPPacket {
  let builder = ReceivedPacketBuilder(
    ctx: .dummy, streamId: 0, sequenceNumber: seq,
    timestamp: timestamp, payloadType: 0, ssrc: 0, mark: mark, loss: loss)
  return try! builder.build(payload: payload).get()
}

private func assertDataEqual(
  _ actual: Data, _ expected: [UInt8],
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let actualBytes = [UInt8](actual)
  #expect(actualBytes == expected, sourceLocation: sourceLocation)
}

// MARK: - Depacketizer Tests

@Suite("H.265 Depacketizer Tests")
struct H265DepacketizerTests {

  /// Test 1: Basic depacketization with Single NAL + AP + FU.
  @Test("Depacketize Single NAL + AP + FU")
  func depacketize() throws {
    var d = try H265Depacketizer(
      clockRate: 90000,
      formatSpecificParams:
        "profile-id=1;"
        + "sprop-sps=QgEBAWAAAAMAsAAAAwAAAwBaoAWCAeFja5JFL83BQYFBAAADAAEAAAMADKE=;"
        + "sprop-pps=RAHA8saNA7NA;"
        + "sprop-vps=QAEMAf//AWAAAAMAsAAAAwAAAwBarAwAAAMABAAAAwAyqA==")

    // Packet 1: Single NAL — PREFIX_SEI (\x4e\x01 = type 39, layer_id 0, temporal_id 1)
    try d.push(
      makeH265Packet(
        seq: 0, timestamp: h265Ts0, mark: false,
        payload: Data([0x4e, 0x01]) + Data("plain".utf8)))
    #expect(d.pull() == nil)

    // Packet 2: AP (type 48 = \x60\x01)
    var apPayload = Data([0x60, 0x01])  // AP NAL header
    apPayload.append(contentsOf: [0x00, 0x0a])  // length = 10
    apPayload.append(contentsOf: [0x4e, 0x01])  // PREFIX_SEI header
    apPayload.append(Data("stap-a 1".utf8))
    apPayload.append(contentsOf: [0x00, 0x0a])  // length = 10
    apPayload.append(contentsOf: [0x4e, 0x01])  // PREFIX_SEI header
    apPayload.append(Data("stap-a 2".utf8))
    try d.push(makeH265Packet(seq: 1, timestamp: h265Ts0, mark: false, payload: apPayload))
    #expect(d.pull() == nil)

    // Packet 3: FU start (type 49 = \x62\x01, FU header \x94 = start + type 20 = IDR_N_LP → \x28\x01)
    // Wait — let me decode:
    // Outer NAL: 0x62 0x01 → type = 0x62 >> 1 = 49 (FU), layer_id=0, temporal_id=1
    // FU header: 0x94 = 1001 0100 → start=1, end=0, type=0x14=20 (IDR_N_LP)
    // Reconstructed header: type 20, same layer/temporal → 0x28 0x01
    try d.push(
      makeH265Packet(
        seq: 2, timestamp: h265Ts0, mark: false,
        payload: Data([0x62, 0x01, 0x94]) + Data("fu start, ".utf8)))
    #expect(d.pull() == nil)

    // Packet 4: FU middle
    // FU header: 0x14 = 0001 0100 → start=0, end=0, type=20
    try d.push(
      makeH265Packet(
        seq: 3, timestamp: h265Ts0, mark: false,
        payload: Data([0x62, 0x01, 0x14]) + Data("fu middle, ".utf8)))
    #expect(d.pull() == nil)

    // Packet 5: FU end
    // FU header: 0x54 = 0101 0100 → start=0, end=1, type=20
    try d.push(
      makeH265Packet(
        seq: 4, timestamp: h265Ts0, mark: true,
        payload: Data([0x62, 0x01, 0x54]) + Data("fu end".utf8)))

    guard case .success(.videoFrame(let frame)) = d.pull() else {
      Issue.record("Expected video frame")
      return
    }

    // Expected AVCC output:
    // SEI:     00 00 00 07 4e 01 "plain"
    // AP NAL1: 00 00 00 0a 4e 01 "stap-a 1"
    // AP NAL2: 00 00 00 0a 4e 01 "stap-a 2"
    // FU:      00 00 00 1d 28 01 "fu start, fu middle, fu end"
    var expected: [UInt8] = []
    expected += [0x00, 0x00, 0x00, 0x07, 0x4e, 0x01]
    expected += Array("plain".utf8)
    expected += [0x00, 0x00, 0x00, 0x0a, 0x4e, 0x01]
    expected += Array("stap-a 1".utf8)
    expected += [0x00, 0x00, 0x00, 0x0a, 0x4e, 0x01]
    expected += Array("stap-a 2".utf8)
    expected += [0x00, 0x00, 0x00, 0x1d, 0x28, 0x01]
    expected += Array("fu start, fu middle, fu end".utf8)
    assertDataEqual(frame.data, expected)
    #expect(!d.seenInconsistentFuNalHdr)
  }

  /// Test 2: FU end with different NAL type is tolerated.
  @Test("Allow inconsistent FU NAL header")
  func allowInconsistentFUNALHeader() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)

    // FU start: type 20 (IDR_N_LP)
    try d.push(
      makeH265Packet(
        seq: 0, timestamp: h265Ts0, mark: false,
        payload: Data([0x62, 0x01, 0x94]) + Data("fu start, ".utf8)))
    #expect(d.pull() == nil)

    // FU end: type 0x26 = 38 (FdNut) — inconsistent
    // FU header: 0x66 = 0110 0110 → start=0, end=1, type=0x26=38
    try d.push(
      makeH265Packet(
        seq: 2, timestamp: h265Ts0, mark: true,
        payload: Data([0x62, 0x01, 0x66]) + Data("fu end".utf8)))

    guard case .success(.videoFrame(let frame)) = d.pull() else {
      Issue.record("Expected video frame")
      return
    }

    // Output uses the START fragment's NAL type (20 → 0x28 0x01)
    let expected: [UInt8] =
      [0x00, 0x00, 0x00, 0x12, 0x28, 0x01]
      + Array("fu start, fu end".utf8)
    assertDataEqual(frame.data, expected)
    #expect(d.seenInconsistentFuNalHdr)
  }

  /// Test 3: Empty FU fragments (no payload bytes after FU header) are accepted.
  @Test("Empty FU fragment")
  func emptyFragment() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)

    // FU start with data
    try d.push(
      makeH265Packet(
        seq: 0, timestamp: h265Ts0, mark: false,
        payload: Data([0x62, 0x01, 0x94]) + Data("start, ".utf8)))
    #expect(d.pull() == nil)

    // FU middle with empty payload (just header bytes)
    try d.push(
      makeH265Packet(
        seq: 1, timestamp: h265Ts0, mark: false,
        payload: Data([0x62, 0x01, 0x14])))
    #expect(d.pull() == nil)

    // FU end with data
    try d.push(
      makeH265Packet(
        seq: 2, timestamp: h265Ts0, mark: true,
        payload: Data([0x62, 0x01, 0x54]) + Data("end".utf8)))

    guard case .success(.videoFrame(let frame)) = d.pull() else {
      Issue.record("Expected video frame")
      return
    }

    let expected: [UInt8] =
      [0x00, 0x00, 0x00, 0x0c, 0x28, 0x01]
      + Array("start, end".utf8)
    assertDataEqual(frame.data, expected)
  }

  /// Test 4: Timestamp change mid-FU → error + recovery.
  @Test("Skip end of fragment")
  func skipEndOfFragment() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)

    // FU start
    try d.push(
      makeH265Packet(
        seq: 0, timestamp: h265Ts0, mark: false,
        payload: Data([0x62, 0x01, 0x94]) + Data("fu start, ".utf8)))
    #expect(d.pull() == nil)

    // Different timestamp — single NAL PREFIX_SEI with mark
    try d.push(
      makeH265Packet(
        seq: 0, timestamp: h265Ts1, mark: true,
        payload: Data([0x4e, 0x01]) + Data("plain".utf8)))

    // First pull: error about timestamp change mid-fragment
    guard case .failure(let err) = d.pull() else {
      Issue.record("Expected error")
      return
    }
    #expect(
      err.description.contains("timestamp changed")
        && err.description.contains("in the middle of a fragmented NAL"))

    // Second pull: the recovery frame
    guard case .success(.videoFrame(let f)) = d.pull() else {
      Issue.record("Expected recovered frame")
      return
    }
    let expected: [UInt8] = [0x00, 0x00, 0x00, 0x07, 0x4e, 0x01] + Array("plain".utf8)
    assertDataEqual(f.data, expected)
    #expect(d.pull() == nil)
  }

  /// Test 5: Parse Tenda CP3 Pro format-specific-params.
  @Test("Parse Tenda CP3 Pro format-specific-params")
  func parseTendaCP3ProFormatSpecificParams() throws {
    let p = try H265Parameters.parseFormatSpecificParams(
      "profile-space=0;"
        + "profile-id=1;"
        + "tier-flag=0;"
        + "level-id=63;"
        + "interop-constraints=900000000000;"
        + "sprop-vps=QAEMAf//AWAAAAMAkAAAAwAAAwA/LAwAAgAAAwAoAAIAAgACgA==;"
        + "sprop-sps=QgEBAWAAAAMAkAAAAwAAAwA/oAUCAXFlLkkyS7I=;"
        + "sprop-pps=RAHA8vAzJA==")
    #expect(p.genericParameters.pixelDimensions?.width == 640)
    #expect(p.genericParameters.pixelDimensions?.height == 368)
  }

  /// Test 6: Parse hacked Xiaomi Yi Pro 2K Home format-specific-params.
  @Test("Parse hacked Xiaomi Yi Pro 2K Home format-specific-params")
  func parseHackedXiaomiYiPro2KHomeFormatSpecificParams() throws {
    let p = try H265Parameters.parseFormatSpecificParams(
      "profile-space=0;"
        + "profile-id=1;"
        + "tier-flag=0;"
        + "level-id=186;"
        + "interop-constraints=000000000000;"
        + "sprop-vps=QAEMAf//AWAAAAMAAAMAAAMAAAMAuqwJ;"
        + "sprop-sps=QgEBAWAAAAMAAAMAAAMAAAMAuqABICAFEf5a7kSIi/Lc1AQEBAI=;"
        + "sprop-pps=RAHA8oSJAzJA")
    #expect(p.genericParameters.pixelDimensions?.width == 2304)
    #expect(p.genericParameters.pixelDimensions?.height == 1296)
  }

  /// Short RTP payloads (zero or one byte — too short for the 2-byte H.265 NAL
  /// header) are tolerated and do not tear the stream down. Previously this
  /// surfaced as a `DepacketizeError("Short NAL")` that propagated up and
  /// ended the session. See CHANGELOG 0.2.0.
  @Test("Short RTP payload tolerated")
  func shortRTPPayload() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)

    // Zero-byte payload — must not throw.
    try d.push(makeH265Packet(seq: 0, timestamp: h265Ts0, mark: false, payload: Data()))
    #expect(d.pull() == nil)

    // One-byte payload (insufficient for H.265's 2-byte NAL header) — must not throw.
    try d.push(makeH265Packet(seq: 1, timestamp: h265Ts0, mark: false, payload: Data([0x40])))
    #expect(d.pull() == nil)
  }
}

// MARK: - NAL Tests

@Suite("H.265 NAL Tests")
struct H265NALTests {

  /// Test 7: Parse basic SPS.
  @Test("Parse SPS")
  func parseSPS() throws {
    let data = Data([
      0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0xB0, 0x00, 0x00, 0x03, 0x00,
      0x00, 0x03, 0x00, 0x5A, 0xA0, 0x05, 0x82, 0x01, 0xE1, 0x63, 0x6B, 0x92, 0x45, 0x2F,
      0xCD, 0xC1, 0x41, 0x81, 0x41, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00, 0x03, 0x00,
      0x0C, 0xA1,
    ])
    let (h, body) = try h265SplitNAL(data)
    #expect(h.unitType == .spsNut)
    let rbsp = decodeRBSP(body)
    let sps = try parseH265SPS(rbsp)
    #expect(sps.rfc6381Codec() == "hvc1.1.6.L90.B0")
    let dims = try sps.pixelDimensions()
    #expect(dims.0 == 704)
    #expect(dims.1 == 480)
    let vui = sps.vui!
    let timing = vui.timingInfo!
    #expect(timing.numUnitsInTick == 1)
    #expect(timing.timeScale == 12)
  }

  /// Test 8: Parse SPS with inter-predicted ShortTermRefPicSet.
  @Test("Parse SPS with inter ref pic set prediction")
  func parseSPSWithInterRefPicSetPrediction() throws {
    let data = Data([
      0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03,
      0x00, 0x00, 0x03, 0x00, 0xBA, 0xA0, 0x01, 0x20, 0x20, 0x05, 0x11, 0xFE, 0x5A, 0xEE,
      0x44, 0x88, 0x8B, 0xF2, 0xDC, 0xD4, 0x04, 0x04, 0x04, 0x02,
    ])
    let (h, body) = try h265SplitNAL(data)
    #expect(h.unitType == .spsNut)
    let rbsp = decodeRBSP(body)
    let sps = try parseH265SPS(rbsp)
    let dims = try sps.pixelDimensions()
    #expect(dims.0 == 2304)
    #expect(dims.1 == 1296)
    #expect(sps.shortTermPicRefSets.count == 3)
    #expect(
      sps.shortTermPicRefSets[0]
        == H265ShortTermRefPicSet.fromDeltaPocs(s0: [-1], s1: []))
    #expect(
      sps.shortTermPicRefSets[1]
        == H265ShortTermRefPicSet.fromDeltaPocs(s0: [-1], s1: []))
    #expect(
      sps.shortTermPicRefSets[2]
        == H265ShortTermRefPicSet.fromDeltaPocs(s0: [], s1: []))
  }

  /// Test 9: Parse SPS with max_sub_layers_minus1 > 0.
  @Test("Parse SPS max_sub_layers_minus1 nonzero")
  func parseSPSMaxSubLayersMinus1Nonzero() throws {
    let data = Data([
      0x42, 0x01, 0x04, 0x21, 0x60, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03,
      0x00, 0x00, 0x03, 0x00, 0x7B, 0x00, 0x00, 0xA0, 0x03, 0xC0, 0x80, 0x11, 0x07, 0xCB,
      0xEB, 0x5A, 0xD3, 0x92, 0x89, 0xAE, 0x55, 0x64, 0x00,
    ])
    let (h, body) = try h265SplitNAL(data)
    #expect(h.unitType == .spsNut)
    let rbsp = decodeRBSP(body)
    let sps = try parseH265SPS(rbsp)
    #expect(sps.rfc6381Codec() == "hvc1.1.6.H123.00")
    let dims = try sps.pixelDimensions()
    #expect(dims.0 == 1920)
    #expect(dims.1 == 1080)
  }

  /// Test 10: Fuzz data that should cause SPS parse error.
  @Test("Excessive short term ref pics")
  func excessiveShortTermRefPics() throws {
    let data = Data([
      66, 23, 0, 219, 219, 219, 219, 219, 255, 255, 255, 255, 255, 255, 219, 219, 20, 66,
      219, 162, 219, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 219, 255,
      255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 219, 219, 210, 255,
    ])
    let (h, body) = try h265SplitNAL(data)
    #expect(h.unitType == .spsNut)
    let rbsp = decodeRBSP(body)
    #expect(throws: (any Error).self) {
      try parseH265SPS(rbsp)
    }
  }

  /// Test 11: Parse basic PPS.
  @Test("Parse PPS")
  func parsePPS() throws {
    let data = Data([0x44, 0x01, 0xC0, 0xF2, 0xC6, 0x8D, 0x03, 0xB3, 0x40])
    let (h, body) = try h265SplitNAL(data)
    #expect(h.unitType == .ppsNut)
    let rbsp = decodeRBSP(body)
    _ = try parseH265PPS(rbsp)
  }

  /// Test 12: All 64 UnitType values round-trip.
  @Test("Unit type roundtrip")
  func unitTypeRoundtrip() {
    for raw: UInt8 in 0..<64 {
      let unitType = H265UnitType(rawValue: raw)!
      #expect(unitType.rawValue == raw)
    }
  }
}

// MARK: - Record Tests

@Suite("H.265 Record Tests")
struct H265RecordTests {

  /// Test 13: HEVC config record from Dahua camera.
  @Test("Simple record (Dahua)")
  func simple() throws {
    let rawPPS = Data(base64Encoded: "RAHA8saNA7NA")!
    let rawSPS = Data(
      base64Encoded: "QgEBAWAAAAMAsAAAAwAAAwBaoAWCAeFja5JFL83BQYFBAAADAAEAAAMADKE=")!
    let rawVPS = Data(
      base64Encoded: "QAEMAf//AWAAAAMAsAAAAwAAAwBarAwAAAMABAAAAwAyqA==")!

    let (ppsH, ppsBody) = try h265SplitNAL(rawPPS)
    #expect(ppsH.unitType == .ppsNut)
    _ = try parseH265PPS(decodeRBSP(ppsBody))
    let (spsH, spsBody) = try h265SplitNAL(rawSPS)
    #expect(spsH.unitType == .spsNut)
    _ = try parseH265SPS(decodeRBSP(spsBody))
    let (vpsH, _) = try h265SplitNAL(rawVPS)
    #expect(vpsH.unitType == .vpsNut)

    let params = try H265Parameters.parseVPSSPSPPS(
      vps: rawVPS, sps: rawSPS, pps: rawPPS)
    #expect(params.ppsNAL == rawPPS)
    #expect(params.spsNAL == rawSPS)
    #expect(params.vpsNAL == rawVPS)

    let expected: [UInt8] = [
      0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0xB0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5A, 0xF0,
      0x00, 0xFC, 0xFD, 0xF8, 0xF8, 0x00, 0x00, 0x0F, 0x03, 0xA0, 0x00, 0x01, 0x00, 0x22,
      0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0xB0, 0x00,
      0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x5A, 0xAC, 0x0C, 0x00, 0x00, 0x03, 0x00, 0x04,
      0x00, 0x00, 0x03, 0x00, 0x32, 0xA8, 0xA1, 0x00, 0x01, 0x00, 0x2C, 0x42, 0x01, 0x01,
      0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0xB0, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00,
      0x5A, 0xA0, 0x05, 0x82, 0x01, 0xE1, 0x63, 0x6B, 0x92, 0x45, 0x2F, 0xCD, 0xC1, 0x41,
      0x81, 0x41, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00, 0x03, 0x00, 0x0C, 0xA1, 0xA2,
      0x00, 0x01, 0x00, 0x09, 0x44, 0x01, 0xC0, 0xF2, 0xC6, 0x8D, 0x03, 0xB3, 0x40,
    ]
    assertDataEqual(params.genericParameters.extraData, expected)
  }

  /// Test 14: HEVC config record from GeoVision camera.
  @Test("GeoVision record")
  func geovision() throws {
    let rawVPS = Data([
      0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF, 0x01, 0x40, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03,
      0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x99, 0xAC, 0x09,
    ])
    let rawSPS = Data([
      0x42, 0x01, 0x01, 0x01, 0x40, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03,
      0x00, 0x00, 0x03, 0x00, 0x99, 0xA0, 0x01, 0x50, 0x20, 0x06, 0x01, 0xF1, 0x39, 0x6B,
      0xB9, 0x1B, 0x06, 0xB9, 0x54, 0x4D, 0xC0, 0x40, 0x40, 0x41, 0x00, 0x00, 0x03, 0x00,
      0x01, 0x00, 0x00, 0x03, 0x00, 0x1E, 0x08,
    ])
    let rawPPS = Data([0x44, 0x01, 0xC0, 0x73, 0xC0, 0x4C, 0x90])

    let (ppsH, ppsBody) = try h265SplitNAL(rawPPS)
    #expect(ppsH.unitType == .ppsNut)
    _ = try parseH265PPS(decodeRBSP(ppsBody))
    let (spsH, spsBody) = try h265SplitNAL(rawSPS)
    #expect(spsH.unitType == .spsNut)
    let sps = try parseH265SPS(decodeRBSP(spsBody))
    #expect(sps.rfc6381Codec() == "hvc1.1.2.L153.00")
    let (vpsH, _) = try h265SplitNAL(rawVPS)
    #expect(vpsH.unitType == .vpsNut)

    let params = try H265Parameters.parseVPSSPSPPS(
      vps: rawVPS, sps: rawSPS, pps: rawPPS)
    #expect(params.ppsNAL == rawPPS)
    #expect(params.spsNAL == rawSPS)
    #expect(params.vpsNAL == rawVPS)

    let expected: [UInt8] = [
      0x01, 0x01, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x99, 0xF0,
      0x00, 0xFC, 0xFD, 0xF8, 0xF8, 0x00, 0x00, 0x0F, 0x03, 0xA0, 0x00, 0x01, 0x00, 0x18,
      0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF, 0x01, 0x40, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03,
      0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x99, 0xAC, 0x09, 0xA1, 0x00, 0x01, 0x00,
      0x31, 0x42, 0x01, 0x01, 0x01, 0x40, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x00,
      0x03, 0x00, 0x00, 0x03, 0x00, 0x99, 0xA0, 0x01, 0x50, 0x20, 0x06, 0x01, 0xF1, 0x39,
      0x6B, 0xB9, 0x1B, 0x06, 0xB9, 0x54, 0x4D, 0xC0, 0x40, 0x40, 0x41, 0x00, 0x00, 0x03,
      0x00, 0x01, 0x00, 0x00, 0x03, 0x00, 0x1E, 0x08, 0xA2, 0x00, 0x01, 0x00, 0x07, 0x44,
      0x01, 0xC0, 0x73, 0xC0, 0x4C, 0x90,
    ]
    assertDataEqual(params.genericParameters.extraData, expected)
  }
}
