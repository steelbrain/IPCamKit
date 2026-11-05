// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Regression tests for H.264/H.265 depacketizer audit findings.

import Foundation
import Testing

@testable import IPCamKit

// MARK: - Helpers

private let fixTs2 = Timestamp(timestamp: 2, clockRate: 90000, start: 0)!

private let dahuaH265VPS = "QAEMAf//AWAAAAMAsAAAAwAAAwBarAwAAAMABAAAAwAyqA=="
private let dahuaH265SPS = "QgEBAWAAAAMAsAAAAwAAAwBaoAWCAeFja5JFL83BQYFBAAADAAEAAAMADKE="
private let dahuaH265PPS = "RAHA8saNA7NA"
private let dahuaH265Trio =
  "sprop-vps=\(dahuaH265VPS);sprop-sps=\(dahuaH265SPS);sprop-pps=\(dahuaH265PPS)"

/// Everything a depacketizer has buffered for `pull()`.
private struct Drained {
  var frames: [VideoFrame] = []
  var errors: [DepacketizeError] = []
}

private func drain(_ pull: () -> Result<CodecItem, DepacketizeError>?) -> Drained {
  var out = Drained()
  while let result = pull() {
    switch result {
    case .success(.videoFrame(let frame)): out.frames.append(frame)
    case .failure(let err): out.errors.append(err)
    default: Issue.record("unexpected non-video item")
    }
  }
  return out
}

/// Push `pkt`, returning whether the push threw.
private func pushThrew(_ d: inout H264Depacketizer, _ pkt: ReceivedRTPPacket) -> Bool {
  do {
    try d.push(pkt)
    return false
  } catch {
    return true
  }
}

private func pushThrew(_ d: inout H265Depacketizer, _ pkt: ReceivedRTPPacket) -> Bool {
  do {
    try d.push(pkt)
    return false
  } catch {
    return true
  }
}

private let accessUnitCap = 16 << 20

/// A 90 kHz timestamp at `value` ticks.
private func fixTs(_ value: Int64) -> Timestamp {
  Timestamp(timestamp: value, clockRate: 90000, start: 0)!
}

/// Aggregate NAL units into one packet payload: `header` (the STAP-A or AP
/// NAL header), then each NAL with a 2-byte big-endian length.
private func aggregate(header: [UInt8], _ nals: [Data]) -> Data {
  var out = Data(header)
  for nal in nals {
    out.append(UInt8(nal.count >> 8))
    out.append(UInt8(nal.count & 0xFF))
    out.append(nal)
  }
  return out
}

/// An H.265 IDR_W_RADL slice NAL (type 19).
private let h265IDRSlice = Data([0x26, 0x01, 0xAA])

/// An H.264 SEI NAL (reserved payload type 229), as the "H264DVR 1.0"
/// firmware sends it.
private let h264SEI = Data([0x06, 0xE5, 0x01, 0xA7, 0x80])

/// An H.264 access unit delimiter (type 9).
private let h264AUD = Data([0x09, 0xF0])

/// An H.264 end of sequence NAL (type 10).
private let h264EndOfSequence = Data([0x0A])

/// H.265 TRAIL_R slice (type 1), access unit delimiter (35), prefix SEI (39)
/// and suffix SEI (40) NALs.
private let h265TrailSlice = Data([0x02, 0x01, 0xBB])
private let h265AUD = Data([0x46, 0x01, 0x50])
private let h265PrefixSEI = Data([0x4E, 0x01, 0x05])
private let h265SuffixSEI = Data([0x50, 0x01, 0x05])

/// Tenda CP3 Pro VPS/SPS/PPS (640x368): a second valid H.265 parameter set.
private let tendaH265VPS = "QAEMAf//AWAAAAMAkAAAAwAAAwA/LAwAAgAAAwAoAAIAAgACgA=="
private let tendaH265SPS = "QgEBAWAAAAMAkAAAAwAAAwA/oAUCAXFlLkkyS7I="
private let tendaH265PPS = "RAHA8vAzJA=="

/// One access unit for `pushUnits`: one packet per payload, all at `ts`
/// ticks, with MARK on the last packet when `mark` is set.
private struct TestUnit {
  var ts: Int64
  var payloads: [Data]
  var mark: Bool
}

/// Push `units` in order and collect every frame and error, including errors
/// thrown by `push`.
private func pushUnits(_ d: inout H264Depacketizer, _ units: [TestUnit]) -> Drained {
  var out = Drained()
  var seq: UInt16 = 0
  for unit in units {
    for (i, payload) in unit.payloads.enumerated() {
      let mark = unit.mark && i == unit.payloads.count - 1
      let pkt = makePacket(seq: seq, timestamp: fixTs(unit.ts), mark: mark, payload: payload)
      seq &+= 1
      do {
        try d.push(pkt)
      } catch {
        out.errors.append(DepacketizeError("push threw: \(error)"))
      }
      let drained = drain { d.pull() }
      out.frames += drained.frames
      out.errors += drained.errors
    }
  }
  return out
}

private func pushUnits(_ d: inout H265Depacketizer, _ units: [TestUnit]) -> Drained {
  var out = Drained()
  var seq: UInt16 = 0
  for unit in units {
    for (i, payload) in unit.payloads.enumerated() {
      let mark = unit.mark && i == unit.payloads.count - 1
      let pkt = makePacket(seq: seq, timestamp: fixTs(unit.ts), mark: mark, payload: payload)
      seq &+= 1
      do {
        try d.push(pkt)
      } catch {
        out.errors.append(DepacketizeError("push threw: \(error)"))
      }
      let drained = drain { d.pull() }
      out.frames += drained.frames
      out.errors += drained.errors
    }
  }
  return out
}

/// The NAL units of an AVCC frame (each after a 4-byte big-endian length).
private func avccNALs(_ data: Data) -> [Data] {
  let bytes = [UInt8](data)
  var nals: [Data] = []
  var i = 0
  while i + 4 <= bytes.count {
    var len = 0
    for k in 0..<4 {
      len = len << 8 | Int(bytes[i + k])
    }
    let start = i + 4
    let end = min(start + len, bytes.count)
    nals.append(Data(bytes[start..<end]))
    i = end
  }
  return nals
}

/// `nals` in AVCC form, as a frame's `data`.
private func avcc(_ nals: [Data]) -> Data {
  var out = Data()
  for nal in nals {
    let len = UInt32(nal.count)
    let prefix: [UInt8] = [
      UInt8(len >> 24), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF),
    ]
    out.append(contentsOf: prefix)
    out.append(nal)
  }
  return out
}

/// Each H.264 frame as "<timestamp> <NAL unit types>", e.g. "3000 [7, 8, 5]".
private func h264Summary(_ frames: [VideoFrame]) -> [String] {
  frames.map { frame in
    let types: [UInt8] = avccNALs(frame.data).map { ($0.first ?? 0) & 0x1F }
    return "\(frame.timestamp.timestamp) \(types)"
  }
}

/// Each H.265 frame as "<timestamp> <NAL unit types>".
private func h265Summary(_ frames: [VideoFrame]) -> [String] {
  frames.map { frame in
    let types: [UInt8] = avccNALs(frame.data).map { (($0.first ?? 0) >> 1) & 0x3F }
    return "\(frame.timestamp.timestamp) \(types)"
  }
}

/// `nal` as H.264 FU-A payloads of up to `chunk` body bytes each.
private func h264FUA(_ nal: Data, chunk: Int) -> [Data] {
  let bytes = [UInt8](nal)
  let hdr = bytes[0]
  let body = Array(bytes[1...])
  var out: [Data] = []
  var offset = 0
  while offset < body.count {
    let end = min(offset + chunk, body.count)
    var fuHeader = hdr & 0x1F
    if offset == 0 { fuHeader |= 0x80 }
    if end == body.count { fuHeader |= 0x40 }
    var payload: [UInt8] = [(hdr & 0xE0) | 28, fuHeader]
    payload += body[offset..<end]
    out.append(Data(payload))
    offset = end
  }
  return out
}

/// `nal` as H.265 FU payloads of up to `chunk` body bytes each.
private func h265FU(_ nal: Data, chunk: Int) -> [Data] {
  let bytes = [UInt8](nal)
  let unitType = (bytes[0] >> 1) & 0x3F
  let body = Array(bytes[2...])
  var out: [Data] = []
  var offset = 0
  while offset < body.count {
    let end = min(offset + chunk, body.count)
    var fuHeader = unitType
    if offset == 0 { fuHeader |= 0x80 }
    if end == body.count { fuHeader |= 0x40 }
    var payload: [UInt8] = [(bytes[0] & 0x81) | (49 << 1), bytes[1], fuHeader]
    payload += body[offset..<end]
    out.append(Data(payload))
    offset = end
  }
  return out
}

/// `base64` without its trailing `=` padding.
private func unpadded(_ base64: String) -> String {
  var s = base64
  while s.hasSuffix("=") {
    s.removeLast()
  }
  return s
}

@Suite("Video depacketizer audit fixes")
struct VideoDepacketizerFixTests {

  // MARK: - Finding 1: access-unit cap counts every output byte

  /// 200 STAP-A packets of 20,000 one-byte NALs at one timestamp would build a
  /// ~20 MB frame (each NAL is 5 output bytes but had no body to count).
  @Test("H.264: header-only STAP-A flood is bounded by the access-unit cap")
  func h264HeaderOnlyNALFlood() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    var stap: [UInt8] = [0x18]
    for _ in 0..<20_000 { stap += [0x00, 0x01, 0x01] }
    let payload = Data(stap)
    var threwAt: Int?
    for seq in 0..<200 {
      let pkt = makePacket(seq: UInt16(seq), timestamp: ts0, mark: false, payload: payload)
      if pushThrew(&d, pkt) {
        threwAt = seq
        break
      }
    }
    _ = pushThrew(&d, makePacket(seq: 200, timestamp: ts0, mark: true, payload: Data([0x01])))
    let out = drain { d.pull() }
    let largest = out.frames.map(\.data.count).max() ?? 0
    #expect(largest <= accessUnitCap)
    // The NAL-count cap trips long before the byte cap would (each packet adds
    // 20,000 NALs; the byte cap alone would need ~168 packets).
    let limit = H264Depacketizer.maxAccessUnitEntries / 20_000 + 1
    #expect(threwAt != nil && threwAt! <= limit)

    // The broken access unit is dropped; the next one arrives with loss.
    try d.push(makePacket(seq: 201, timestamp: ts1, mark: true, payload: Data([0x41, 0x9A])))
    let next = drain { d.pull() }
    #expect(next.frames.count == 1)
    #expect((next.frames.first?.loss ?? 0) >= 1)
  }

  @Test("H.265: header-only AP flood is bounded by the access-unit cap")
  func h265HeaderOnlyNALFlood() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    var ap: [UInt8] = [0x60, 0x01]
    for _ in 0..<15_000 { ap += [0x00, 0x02, 0x02, 0x01] }
    let payload = Data(ap)
    var threw = false
    for seq in 0..<200 {
      let pkt = makePacket(seq: UInt16(seq), timestamp: ts0, mark: false, payload: payload)
      if pushThrew(&d, pkt) {
        threw = true
        break
      }
    }
    _ = pushThrew(
      &d, makePacket(seq: 200, timestamp: ts0, mark: true, payload: Data([0x02, 0x01])))
    let out = drain { d.pull() }
    let largest = out.frames.map(\.data.count).max() ?? 0
    #expect(threw)
    #expect(largest <= accessUnitCap)
  }

  /// NALs with bodies: the body bytes stay under 16 MiB, but with the 4-byte
  /// length prefix and header byte of each NAL the frame would exceed it. The
  /// NAL count stays far below the entry cap, so only byte accounting catches it.
  @Test("H.264: length prefix and header bytes count toward the cap")
  func h264PrefixAndHeaderCounted() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    var nal: [UInt8] = [0x03, 0xE8, 0x01]  // length 1000, non-IDR slice header
    nal += [UInt8](repeating: 0xAA, count: 999)
    var stap: [UInt8] = [0x18]
    for _ in 0..<60 { stap += nal }
    let payload = Data(stap)
    // 279 packets * 60 NALs = 16,740 NALs: 16,723,260 body bytes (< 16 MiB),
    // 16,806,960 output bytes (> 16 MiB).
    var threw = false
    for seq in 0..<279 {
      let pkt = makePacket(seq: UInt16(seq), timestamp: ts0, mark: false, payload: payload)
      if pushThrew(&d, pkt) {
        threw = true
        break
      }
    }
    _ = pushThrew(&d, makePacket(seq: 279, timestamp: ts0, mark: true, payload: Data([0x01])))
    let out = drain { d.pull() }
    let largest = out.frames.map(\.data.count).max() ?? 0
    #expect(threw)
    #expect(largest <= accessUnitCap)
  }

  @Test("H.265: length prefix and header bytes count toward the cap")
  func h265PrefixAndHeaderCounted() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    var nal: [UInt8] = [0x03, 0xE8, 0x02, 0x01]  // length 1000, TRAIL_R header
    nal += [UInt8](repeating: 0xAA, count: 998)
    var ap: [UInt8] = [0x60, 0x01]
    for _ in 0..<60 { ap += nal }
    let payload = Data(ap)
    // 16,740 NALs: 16,706,520 body bytes, 16,806,960 output bytes.
    var threw = false
    for seq in 0..<279 {
      let pkt = makePacket(seq: UInt16(seq), timestamp: ts0, mark: false, payload: payload)
      if pushThrew(&d, pkt) {
        threw = true
        break
      }
    }
    _ = pushThrew(
      &d, makePacket(seq: 279, timestamp: ts0, mark: true, payload: Data([0x02, 0x01])))
    let out = drain { d.pull() }
    let largest = out.frames.map(\.data.count).max() ?? 0
    #expect(threw)
    #expect(largest <= accessUnitCap)
  }

  /// One-byte FU fragments add a buffered piece per packet while adding almost
  /// nothing to the byte count; the entry cap bounds them.
  @Test("H.265: flood of one-byte FU fragments is bounded by the entry cap")
  func h265TinyFragmentFlood() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try d.push(
      makePacket(seq: 0, timestamp: ts0, mark: false, payload: Data([0x62, 0x01, 0x81, 0xAA])))
    let cont = Data([0x62, 0x01, 0x01, 0xAA])
    var threw = false
    for seq in 1...(H265Depacketizer.maxAccessUnitEntries + 1) {
      if pushThrew(
        &d,
        makePacket(seq: UInt16(truncatingIfNeeded: seq), timestamp: ts0, mark: false, payload: cont)
      ) {
        threw = true
        break
      }
    }
    #expect(threw)
  }

  // MARK: - Finding 2: DONL / tx-mode check is not swallowed

  @Test("H.265: sprop-max-don-diff > 0 or tx-mode MST fails depacketizer init")
  func h265DonlFailsInit() throws {
    #expect(throws: RTSPError.self) {
      _ = try H265Depacketizer(
        clockRate: 90000, formatSpecificParams: "sprop-max-don-diff=1;\(dahuaH265Trio)")
    }
    #expect(throws: RTSPError.self) {
      _ = try H265Depacketizer(clockRate: 90000, formatSpecificParams: "sprop-max-don-diff=2")
    }
    #expect(throws: RTSPError.self) {
      _ = try H265Depacketizer(
        clockRate: 90000, formatSpecificParams: "tx-mode=MST;\(dahuaH265Trio)")
    }
    let ok = try H265Depacketizer(
      clockRate: 90000, formatSpecificParams: "sprop-max-don-diff=0;\(dahuaH265Trio)")
    #expect(ok.parameters != nil)
    // Unparseable sprop sets still fall back to in-band parameters.
    let fallback = try H265Depacketizer(
      clockRate: 90000, formatSpecificParams: "sprop-vps=!!;sprop-sps=!!;sprop-pps=!!")
    #expect(fallback.parameters == nil)
  }

  // MARK: - Finding 3: a failed push discards the rest of its access unit

  @Test("H.264: error inside a FU-A drops the rest of the access unit and reports loss")
  func h264ErrorDropsAccessUnit() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    // FU-A start of an IDR slice.
    try d.push(makePacket(seq: 0, timestamp: ts0, mark: false, payload: Data([0x7C, 0x85, 0xAA])))
    // A SEI inside the FU-A is invalid.
    #expect(
      pushThrew(&d, makePacket(seq: 1, timestamp: ts0, mark: false, payload: Data([0x06, 0x01]))))
    // The rest of this access unit is discarded, not re-assembled.
    _ = pushThrew(
      &d, makePacket(seq: 2, timestamp: ts0, mark: false, payload: Data([0x7C, 0x45, 0xBB])))
    _ = pushThrew(&d, makePacket(seq: 3, timestamp: ts0, mark: true, payload: Data([0x65, 0xCC])))
    let broken = drain { d.pull() }
    #expect(broken.frames.isEmpty)

    try d.push(makePacket(seq: 4, timestamp: ts1, mark: true, payload: Data([0x41, 0xDD])))
    let next = drain { d.pull() }
    #expect(next.frames.count == 1)
    let frame = try #require(next.frames.first)
    #expect(frame.loss >= 1)
    #expect(!frame.isRandomAccessPoint)
  }

  @Test("H.265: error inside a FU drops the rest of the access unit and reports loss")
  func h265ErrorDropsAccessUnit() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    // FU start of an IDR_W_RADL slice.
    try d.push(
      makePacket(seq: 0, timestamp: ts0, mark: false, payload: Data([0x62, 0x01, 0x93, 0xAA])))
    // A prefix SEI inside the FU is invalid.
    #expect(
      pushThrew(
        &d, makePacket(seq: 1, timestamp: ts0, mark: false, payload: Data([0x4E, 0x01, 0x05]))))
    _ = pushThrew(
      &d, makePacket(seq: 2, timestamp: ts0, mark: false, payload: Data([0x62, 0x01, 0x53, 0xBB])))
    _ = pushThrew(
      &d, makePacket(seq: 3, timestamp: ts0, mark: true, payload: Data([0x26, 0x01, 0xCC])))
    let broken = drain { d.pull() }
    #expect(broken.frames.isEmpty)

    try d.push(
      makePacket(seq: 4, timestamp: ts1, mark: true, payload: Data([0x02, 0x01, 0xDD])))
    let next = drain { d.pull() }
    #expect(next.frames.count == 1)
    let frame = try #require(next.frames.first)
    #expect(frame.loss >= 1)
    #expect(!frame.isRandomAccessPoint)
  }

  @Test("H.264: an error on the marked packet still lets the next timestamp through")
  func h264ErrorOnMarkedPacket() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try d.push(makePacket(seq: 0, timestamp: ts0, mark: false, payload: Data([0x7C, 0x85, 0xAA])))
    // FU-A with MARK but no END bit is invalid.
    #expect(
      pushThrew(
        &d, makePacket(seq: 1, timestamp: ts0, mark: true, payload: Data([0x7C, 0x05, 0xBB]))))
    try d.push(makePacket(seq: 2, timestamp: ts1, mark: true, payload: Data([0x41, 0xDD])))
    let out = drain { d.pull() }
    #expect(out.frames.count == 1)
    #expect((out.frames.first?.loss ?? 0) >= 1)
  }

  @Test("H.264: timestamp change mid-FU-A carries loss into the next frame")
  func h264MidFuTimestampChangeLoss() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try d.push(makePacket(seq: 0, timestamp: ts0, mark: false, payload: Data([0x7C, 0x86, 0xAA])))
    try d.push(makePacket(seq: 1, timestamp: ts1, mark: true, payload: Data([0x41, 0xBB])))
    let out = drain { d.pull() }
    #expect(out.errors.count == 1)
    #expect(out.frames.count == 1)
    let loss: UInt16 = out.frames.first?.loss ?? 0
    #expect(loss == 1)
  }

  @Test("H.265: timestamp change mid-FU carries loss into the next frame")
  func h265MidFuTimestampChangeLoss() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try d.push(
      makePacket(seq: 0, timestamp: ts0, mark: false, payload: Data([0x62, 0x01, 0x93, 0xAA])))
    try d.push(
      makePacket(seq: 1, timestamp: ts1, mark: true, payload: Data([0x02, 0x01, 0xBB])))
    let out = drain { d.pull() }
    #expect(out.errors.count == 1)
    #expect(out.frames.count == 1)
    let loss: UInt16 = out.frames.first?.loss ?? 0
    #expect(loss == 1)
  }

  /// In-band SPS/PPS that fail to parse fail the access unit at finalize; the
  /// next frame must say something was dropped.
  @Test("H.264: finalize failure carries loss into the next frame")
  func h264FinalizeFailureLoss() throws {
    // Failure on the marked packet.
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try d.push(makePacket(seq: 0, timestamp: ts0, mark: false, payload: Data([0x67, 0xFF])))
    try d.push(makePacket(seq: 1, timestamp: ts0, mark: false, payload: Data([0x68, 0xCE])))
    try d.push(makePacket(seq: 2, timestamp: ts0, mark: true, payload: Data([0x65, 0x88])))
    try d.push(makePacket(seq: 3, timestamp: ts1, mark: true, payload: Data([0x41, 0x9A])))
    let out = drain { d.pull() }
    #expect(out.errors.count == 1)
    #expect(out.frames.count == 1)
    let loss: UInt16 = out.frames.first?.loss ?? 0
    #expect(loss == 1)

    // Failure at a timestamp boundary (no MARK on the bad access unit).
    var d2 = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try d2.push(makePacket(seq: 0, timestamp: ts0, mark: false, payload: Data([0x67, 0xFF])))
    try d2.push(makePacket(seq: 1, timestamp: ts0, mark: false, payload: Data([0x68, 0xCE])))
    try d2.push(makePacket(seq: 2, timestamp: ts0, mark: false, payload: Data([0x65, 0x88])))
    try d2.push(makePacket(seq: 3, timestamp: ts1, mark: true, payload: Data([0x41, 0x9A])))
    let out2 = drain { d2.pull() }
    #expect(out2.errors.count == 1)
    #expect(out2.frames.count == 1)
    let loss2: UInt16 = out2.frames.first?.loss ?? 0
    #expect(loss2 == 1)
  }

  @Test("H.265: finalize failure carries loss into the next frame")
  func h265FinalizeFailureLoss() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try d.push(
      makePacket(seq: 0, timestamp: ts0, mark: false, payload: Data([0x40, 0x01, 0xFF])))
    try d.push(
      makePacket(seq: 1, timestamp: ts0, mark: false, payload: Data([0x42, 0x01, 0xFF])))
    try d.push(
      makePacket(seq: 2, timestamp: ts0, mark: false, payload: Data([0x44, 0x01, 0xC0])))
    try d.push(
      makePacket(seq: 3, timestamp: ts0, mark: true, payload: Data([0x26, 0x01, 0x88])))
    try d.push(
      makePacket(seq: 4, timestamp: ts1, mark: true, payload: Data([0x02, 0x01, 0x9A])))
    let out = drain { d.pull() }
    #expect(out.errors.count == 1)
    #expect(out.frames.count == 1)
    let loss: UInt16 = out.frames.first?.loss ?? 0
    #expect(loss == 1)
  }

  // MARK: - Finding 4: short payloads don't desync the state machine

  @Test("H.265: empty packet at a new timestamp does not lose the next frame")
  func h265EmptyPacketAtNewTimestamp() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try d.push(
      makePacket(seq: 0, timestamp: ts0, mark: false, payload: Data([0x02, 0x01, 0xAA])))
    try d.push(makePacket(seq: 1, timestamp: ts1, mark: false, payload: Data()))
    try d.push(
      makePacket(seq: 2, timestamp: ts1, mark: true, payload: Data([0x02, 0x01, 0xBB])))
    let out = drain { d.pull() }
    #expect(out.errors.isEmpty)
    #expect(out.frames.count == 2)
    #expect(out.frames.map(\.timestamp.timestamp) == [0, 1])
    let last = try #require(out.frames.last)
    #expect([UInt8](last.data) == [0x00, 0x00, 0x00, 0x03, 0x02, 0x01, 0xBB])
  }

  @Test("H.264: loss reported on an empty packet reaches the next frame")
  func h264EmptyPacketLoss() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try d.push(makePacket(seq: 0, timestamp: ts0, mark: false, payload: Data([0x65, 0xAA])))
    try d.push(makePacket(seq: 4, timestamp: ts1, mark: false, payload: Data(), loss: 3))
    try d.push(makePacket(seq: 5, timestamp: ts1, mark: true, payload: Data([0x41, 0xBB])))
    let out = drain { d.pull() }
    #expect(out.errors.isEmpty)
    #expect(out.frames.count == 1)
    let frame = try #require(out.frames.first)
    #expect(frame.loss == 3)
    #expect(frame.timestamp.timestamp == 1)
    #expect([UInt8](frame.data) == [0x00, 0x00, 0x00, 0x02, 0x41, 0xBB])
  }

  @Test("H.265: loss reported on a short packet reaches the next frame")
  func h265ShortPacketLoss() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try d.push(
      makePacket(seq: 0, timestamp: ts0, mark: false, payload: Data([0x02, 0x01, 0xAA])))
    try d.push(makePacket(seq: 4, timestamp: ts1, mark: false, payload: Data([0x02]), loss: 3))
    // The next packet carries a new timestamp, so the pending (empty) access
    // unit absorbs it rather than failing.
    try d.push(
      makePacket(seq: 5, timestamp: fixTs2, mark: true, payload: Data([0x02, 0x01, 0xBB])))
    let out = drain { d.pull() }
    #expect(out.errors.isEmpty)
    #expect(out.frames.count == 1)
    let frame = try #require(out.frames.first)
    #expect(frame.loss == 3)
    #expect(frame.timestamp.timestamp == 2)
  }

  @Test("H.264: empty packet without loss leaves an in-progress access unit alone")
  func h264EmptyPacketKeepsAccessUnit() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try d.push(makePacket(seq: 0, timestamp: ts0, mark: false, payload: Data([0x65, 0xAA])))
    try d.push(makePacket(seq: 1, timestamp: ts1, mark: false, payload: Data()))
    try d.push(makePacket(seq: 2, timestamp: ts1, mark: true, payload: Data([0x41, 0xBB])))
    let out = drain { d.pull() }
    #expect(out.frames.count == 2)
    let first = try #require(out.frames.first)
    #expect(first.isRandomAccessPoint)
    #expect(first.timestamp.timestamp == 0)
    let second = try #require(out.frames.last)
    #expect(second.timestamp.timestamp == 1)
  }

  // MARK: - Finding 5: H.265 prefix SEI and AUD cannot end an access unit

  @Test("H.265: prefix SEI with MARK does not end the access unit")
  func h265PrefixSeiCannotEndAU() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try d.push(
      makePacket(seq: 0, timestamp: ts0, mark: true, payload: Data([0x4E, 0x01, 0x05])))
    try d.push(
      makePacket(seq: 1, timestamp: ts0, mark: true, payload: Data([0x26, 0x01, 0xAA])))
    let out = drain { d.pull() }
    #expect(out.frames.count == 1)
    let frame = try #require(out.frames.first)
    #expect(
      [UInt8](frame.data) == [
        0x00, 0x00, 0x00, 0x03, 0x4E, 0x01, 0x05, 0x00, 0x00, 0x00, 0x03, 0x26, 0x01, 0xAA,
      ])
    #expect(frame.isRandomAccessPoint)
  }

  @Test("H.265: AUD does not end the access unit (MARK or timestamp change)")
  func h265AudCannotEndAU() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try d.push(
      makePacket(seq: 0, timestamp: ts0, mark: true, payload: Data([0x46, 0x01, 0x50])))
    try d.push(
      makePacket(seq: 1, timestamp: ts0, mark: true, payload: Data([0x02, 0x01, 0xAA])))
    let out = drain { d.pull() }
    #expect(out.frames.count == 1)

    try d.push(
      makePacket(seq: 2, timestamp: ts1, mark: false, payload: Data([0x46, 0x01, 0x50])))
    try d.push(
      makePacket(seq: 3, timestamp: fixTs2, mark: true, payload: Data([0x02, 0x01, 0xBB])))
    let out2 = drain { d.pull() }
    #expect(out2.frames.count == 1)
    #expect(out2.frames.first?.data.count == 14)
  }

  // MARK: - Finding 6: PPS extensions don't block parameter parsing

  /// Dahua PPS (`RAHA8saNA7NA`) with `pps_extension_present_flag` = 1 and
  /// `pps_range_extension_flag` = 1 followed by an empty range extension.
  static let ppsWithRangeExtension = Data([
    0x44, 0x01, 0xC0, 0xF2, 0xC6, 0x8D, 0x03, 0xB3, 0xC0, 0x1C,
  ])

  @Test("H.265: PPS with a range extension parses")
  func h265PPSRangeExtension() throws {
    let (h, body) = try h265SplitNAL(Self.ppsWithRangeExtension)
    #expect(h.unitType == .ppsNut)
    let pps = try parseH265PPS(decodeRBSP(body))
    #expect(!pps.tilesEnabledFlag)
    #expect(!pps.entropyCodingSyncEnabledFlag)
  }

  @Test("H.265: in-band PPS with a range extension yields a keyframe and parameters")
  func h265InBandPPSRangeExtension() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let vps = try #require(Data(base64Encoded: dahuaH265VPS))
    let sps = try #require(Data(base64Encoded: dahuaH265SPS))
    try d.push(makePacket(seq: 0, timestamp: ts0, mark: false, payload: vps))
    try d.push(makePacket(seq: 1, timestamp: ts0, mark: false, payload: sps))
    try d.push(
      makePacket(seq: 2, timestamp: ts0, mark: false, payload: Self.ppsWithRangeExtension))
    try d.push(
      makePacket(seq: 3, timestamp: ts0, mark: true, payload: Data([0x26, 0x01, 0xAA])))
    let out = drain { d.pull() }
    #expect(out.errors.isEmpty)
    let frame = try #require(out.frames.first)
    #expect(frame.isRandomAccessPoint)
    #expect(frame.hasNewParameters)
    #expect(d.parameters?.ppsNAL == Self.ppsWithRangeExtension)
  }

  // MARK: - Finding 7: H.265 IRAP pictures are random access points

  @Test("H.265: BLA, IDR, CRA and reserved IRAP types are random access points")
  func h265IrapIsRandomAccessPoint() throws {
    for raw: UInt8 in 0...31 {
      var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
      try d.push(
        makePacket(seq: 0, timestamp: ts0, mark: true, payload: Data([raw << 1, 0x01, 0xAA])))
      let out = drain { d.pull() }
      let frame = try #require(out.frames.first)
      let expected = (16...23).contains(raw)
      #expect(frame.isRandomAccessPoint == expected, "unit type \(raw)")
    }
  }

  // MARK: - Finding 8: H.265 frame rate filters zero timing values

  @Test("H.265: zero vui_num_units_in_tick yields no frame rate")
  func h265ZeroTimingFiltered() throws {
    let vps = try #require(Data(base64Encoded: dahuaH265VPS))
    let pps = try #require(Data(base64Encoded: dahuaH265PPS))
    // Dahua SPS with num_units_in_tick rewritten from 1 to 0 (time_scale 12).
    let sps = Data([
      0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0xB0, 0x00, 0x00, 0x03, 0x00,
      0x00, 0x03, 0x00, 0x5A, 0xA0, 0x05, 0x82, 0x01, 0xE1, 0x63, 0x6B, 0x92, 0x45, 0x2F,
      0xCD, 0xC1, 0x41, 0x81, 0x41, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03,
      0x00, 0x0C, 0xA1,
    ])
    let (_, body) = try h265SplitNAL(sps)
    let parsed = try parseH265SPS(decodeRBSP(body))
    let timing = try #require(parsed.vui?.timingInfo)
    #expect(timing.numUnitsInTick == 0)
    #expect(timing.timeScale == 12)

    let params = try H265Parameters.parseVPSSPSPPS(vps: vps, sps: sps, pps: pps)
    #expect(params.genericParameters.frameRate == nil)

    // The unmodified SPS still reports (num_units_in_tick, time_scale).
    let original = try #require(Data(base64Encoded: dahuaH265SPS))
    let okParams = try H265Parameters.parseVPSSPSPPS(vps: vps, sps: original, pps: pps)
    let num: UInt32? = okParams.genericParameters.frameRate?.num
    let den: UInt32? = okParams.genericParameters.frameRate?.den
    #expect(num == 1)
    #expect(den == 12)
  }

  @Test("H.264: an access unit delimiter does not end the access unit")
  func h264AudCannotEndAU() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try d.push(makePacket(seq: 0, timestamp: ts0, mark: true, payload: Data([0x09, 0xF0])))
    try d.push(makePacket(seq: 1, timestamp: ts0, mark: true, payload: Data([0x65, 0xAA])))
    let out = drain { d.pull() }
    #expect(out.frames.count == 1)
    #expect(out.frames.first?.isRandomAccessPoint == true)
  }

  @Test("H.264: loss carried into an access unit survives a further loss that drops it")
  func h264CarriedLossKept() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    // Two packets lost before this unit, then one more inside it.
    try d.push(
      makePacket(seq: 2, timestamp: ts0, mark: false, payload: Data([0x65, 0xAA]), loss: 2))
    try d.push(
      makePacket(seq: 4, timestamp: ts0, mark: true, payload: Data([0x65, 0xBB]), loss: 1))
    try d.push(makePacket(seq: 5, timestamp: fixTs2, mark: true, payload: Data([0x65, 0xCC])))
    let frame = try #require(drain { d.pull() }.frames.first)
    let loss: UInt16 = frame.loss
    #expect(loss == 3)
  }

  @Test("H.265: loss carried into an access unit survives a further loss that drops it")
  func h265CarriedLossKept() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try d.push(
      makePacket(seq: 2, timestamp: ts0, mark: false, payload: Data([0x26, 0x01, 0xAA]), loss: 2))
    try d.push(
      makePacket(seq: 4, timestamp: fixTs2, mark: true, payload: Data([0x26, 0x01, 0xBB]), loss: 1))
    let frame = try #require(drain { d.pull() }.frames.first)
    let loss: UInt16 = frame.loss
    #expect(loss == 3)
  }

  // MARK: - Finding 9: several parameter sets of one type in an access unit

  /// A second H.264 PPS: pic_parameter_set_id 1, seq_parameter_set_id 0.
  /// `h264TestPPS` has pic_parameter_set_id 0.
  static let h264PPSId1 = Data([0x68, 0x53, 0x8F, 0x2C])

  /// The Dahua H.265 PPS (`RAHA8saNA7NA`) with pps_pic_parameter_set_id
  /// re-encoded from 0 to 1.
  static let h265PPSId1 = Data([0x44, 0x01, 0x50, 0x3C, 0xB1, 0xA3, 0x40, 0xEC, 0xD0])

  /// Push each access unit in `units` as single-NAL packets at 3000-tick
  /// intervals, MARK on the last packet, and return each frame's
  /// `hasNewParameters`.
  private func newParameterFlags(_ d: inout H264Depacketizer, _ units: [[Data]]) throws -> [Bool] {
    var flags: [Bool] = []
    var seq: UInt16 = 0
    for (k, nals) in units.enumerated() {
      let t = fixTs(Int64(k) * 3000)
      for (i, nal) in nals.enumerated() {
        try d.push(makePacket(seq: seq, timestamp: t, mark: i == nals.count - 1, payload: nal))
        seq += 1
      }
      let out = drain { d.pull() }
      #expect(out.errors.isEmpty)
      flags += out.frames.map(\.hasNewParameters)
    }
    return flags
  }

  private func newParameterFlags(_ d: inout H265Depacketizer, _ units: [[Data]]) throws -> [Bool] {
    var flags: [Bool] = []
    var seq: UInt16 = 0
    for (k, nals) in units.enumerated() {
      let t = fixTs(Int64(k) * 3000)
      for (i, nal) in nals.enumerated() {
        try d.push(makePacket(seq: seq, timestamp: t, mark: i == nals.count - 1, payload: nal))
        seq += 1
      }
      let out = drain { d.pull() }
      #expect(out.errors.isEmpty)
      flags += out.frames.map(\.hasNewParameters)
    }
    return flags
  }

  @Test("H.264: the second PPS has a different pic_parameter_set_id")
  func h264PPSId1Fixture() {
    var reader = BitReader(Data(Self.h264PPSId1.dropFirst()))
    let ppsId = reader.readExpGolomb()
    let spsId = reader.readExpGolomb()
    #expect(ppsId == 1)
    #expect(spsId == 0)
    var testReader = BitReader(Data(h264TestPPS.dropFirst()))
    let testPPSId = testReader.readExpGolomb()
    #expect(testPPSId == 0)
  }

  @Test("H.264: keyframes with two PPS report new parameters once")
  func h264TwoPPSPerKeyframe() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let keyframe = [h264TestSPS, h264TestPPS, Self.h264PPSId1, h264TestIDRSlice]
    let flags = try newParameterFlags(&d, [keyframe, keyframe, keyframe, keyframe])
    #expect(flags == [true, false, false, false])
    // With no stored PPS, the first PPS in the access unit is adopted.
    #expect(d.parameters?.ppsNAL == h264TestPPS)
  }

  @Test("H.264: a PPS equal to the stored one keeps it, whatever its position")
  func h264StoredPPSKept() throws {
    let spsB64 = h264TestSPS.base64EncodedString()
    let ppsB64 = h264TestPPS.base64EncodedString()
    let fmtp = "packetization-mode=1;sprop-parameter-sets=\(spsB64),\(ppsB64)"
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: fmtp)
    let keyframe = [h264TestSPS, Self.h264PPSId1, h264TestPPS, h264TestIDRSlice]
    let flags = try newParameterFlags(&d, [keyframe, keyframe, keyframe])
    #expect(flags == [false, false, false])
    #expect(d.parameters?.ppsNAL == h264TestPPS)
  }

  @Test("H.265: the second PPS parses and has a different pps_pic_parameter_set_id")
  func h265PPSId1Fixture() throws {
    let (h, body) = try h265SplitNAL(Self.h265PPSId1)
    #expect(h.unitType == .ppsNut)
    let rbsp = decodeRBSP(body)
    _ = try parseH265PPS(rbsp)
    var reader = BitReader(rbsp)
    let ppsId = reader.readExpGolomb()
    #expect(ppsId == 1)
    let vps = try #require(Data(base64Encoded: dahuaH265VPS))
    let sps = try #require(Data(base64Encoded: dahuaH265SPS))
    _ = try H265Parameters.parseVPSSPSPPS(vps: vps, sps: sps, pps: Self.h265PPSId1)
  }

  @Test("H.265: keyframes with two PPS report new parameters once")
  func h265TwoPPSPerKeyframe() throws {
    let vps = try #require(Data(base64Encoded: dahuaH265VPS))
    let sps = try #require(Data(base64Encoded: dahuaH265SPS))
    let pps = try #require(Data(base64Encoded: dahuaH265PPS))
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let keyframe = [vps, sps, pps, Self.h265PPSId1, h265IDRSlice]
    let flags = try newParameterFlags(&d, [keyframe, keyframe, keyframe, keyframe])
    #expect(flags == [true, false, false, false])
    #expect(d.parameters?.ppsNAL == pps)
  }

  @Test("H.265: a parameter set equal to the stored one keeps it, whatever its position")
  func h265StoredParameterSetsKept() throws {
    let vps = try #require(Data(base64Encoded: dahuaH265VPS))
    let sps = try #require(Data(base64Encoded: dahuaH265SPS))
    let pps = try #require(Data(base64Encoded: dahuaH265PPS))
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: dahuaH265Trio)
    let keyframe = [vps, sps, Self.h265PPSId1, pps, h265IDRSlice]
    let flags = try newParameterFlags(&d, [keyframe, keyframe, keyframe])
    #expect(flags == [false, false, false])
    #expect(d.parameters?.ppsNAL == pps)
  }

  // MARK: - Finding 10: each frame carries the parameter sets it was built with

  @Test("H.264: one packet finishing two access units gives each its own parameter sets")
  func h264ParameterSetsPerFrame() throws {
    // Dahua SPS/PPS: a second valid set, different from h264TestSPS/PPS. The
    // sprop parser strips their trailing zero byte, as the depacketizer does.
    let setB = try H264Parameters.parseFormatSpecificParams(dahuaFmtp)
    #expect(setB.spsNAL != h264TestSPS)
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)

    // A frame before any parameters.
    try d.push(makePacket(seq: 0, timestamp: fixTs(0), mark: true, payload: h264TestNonIDRSlice))
    let before = try #require(drain { d.pull() }.frames.first)
    #expect(before.parameterSets == nil)

    // Access unit 1 (set A) without MARK, so it ends only when the next
    // timestamp arrives.
    let t1 = fixTs(3000)
    try d.push(makePacket(seq: 1, timestamp: t1, mark: false, payload: h264TestSPS))
    try d.push(makePacket(seq: 2, timestamp: t1, mark: false, payload: h264TestPPS))
    try d.push(makePacket(seq: 3, timestamp: t1, mark: false, payload: h264TestIDRSlice))
    let pendingFrames = drain { d.pull() }.frames
    #expect(pendingFrames.isEmpty)

    // One STAP-A with set B and an IDR slice, with MARK, at the next timestamp.
    let stap = aggregate(header: [0x18], [setB.spsNAL, setB.ppsNAL, h264TestIDRSlice])
    try d.push(makePacket(seq: 4, timestamp: fixTs(6000), mark: true, payload: stap))
    let out = drain { d.pull() }
    #expect(out.errors.isEmpty)
    #expect(out.frames.count == 2)
    let first = try #require(out.frames.first)
    let second = try #require(out.frames.last)
    let setANALs = VideoParameterSetNALs(sps: h264TestSPS, pps: h264TestPPS)
    let setBNALs = VideoParameterSetNALs(sps: setB.spsNAL, pps: setB.ppsNAL)
    #expect(first.hasNewParameters)
    #expect(first.parameterSets == setANALs)
    #expect(second.hasNewParameters)
    #expect(second.parameterSets == setBNALs)
    // The depacketizer's current parameters already belong to the second frame.
    #expect(d.parameters?.spsNAL == setB.spsNAL)

    // A later frame without parameter sets keeps set B.
    try d.push(makePacket(seq: 5, timestamp: fixTs(9000), mark: true, payload: h264TestNonIDRSlice))
    let later = try #require(drain { d.pull() }.frames.first)
    #expect(!later.hasNewParameters)
    #expect(later.parameterSets == setBNALs)
  }

  @Test("H.265: one packet finishing two access units gives each its own parameter sets")
  func h265ParameterSetsPerFrame() throws {
    let vpsA = try #require(Data(base64Encoded: dahuaH265VPS))
    let spsA = try #require(Data(base64Encoded: dahuaH265SPS))
    let ppsA = try #require(Data(base64Encoded: dahuaH265PPS))
    // Tenda CP3 Pro VPS/SPS/PPS (640x368): a second valid set.
    let vpsB = try #require(
      Data(base64Encoded: "QAEMAf//AWAAAAMAkAAAAwAAAwA/LAwAAgAAAwAoAAIAAgACgA=="))
    let spsB = try #require(Data(base64Encoded: "QgEBAWAAAAMAkAAAAwAAAwA/oAUCAXFlLkkyS7I="))
    let ppsB = try #require(Data(base64Encoded: "RAHA8vAzJA=="))
    _ = try H265Parameters.parseVPSSPSPPS(vps: vpsB, sps: spsB, pps: ppsB)
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)

    let t0 = fixTs(0)
    try d.push(makePacket(seq: 0, timestamp: t0, mark: false, payload: vpsA))
    try d.push(makePacket(seq: 1, timestamp: t0, mark: false, payload: spsA))
    try d.push(makePacket(seq: 2, timestamp: t0, mark: false, payload: ppsA))
    try d.push(makePacket(seq: 3, timestamp: t0, mark: false, payload: h265IDRSlice))
    let pendingFrames = drain { d.pull() }.frames
    #expect(pendingFrames.isEmpty)

    // One AP with set B and an IDR slice, with MARK, at the next timestamp.
    let ap = aggregate(header: [0x60, 0x01], [vpsB, spsB, ppsB, h265IDRSlice])
    try d.push(makePacket(seq: 4, timestamp: fixTs(3000), mark: true, payload: ap))
    let out = drain { d.pull() }
    #expect(out.errors.isEmpty)
    #expect(out.frames.count == 2)
    let first = try #require(out.frames.first)
    let second = try #require(out.frames.last)
    let setANALs = VideoParameterSetNALs(sps: spsA, pps: ppsA, vps: vpsA)
    let setBNALs = VideoParameterSetNALs(sps: spsB, pps: ppsB, vps: vpsB)
    #expect(first.hasNewParameters)
    #expect(first.parameterSets == setANALs)
    #expect(second.hasNewParameters)
    #expect(second.parameterSets == setBNALs)
  }

  @Test("H.265: frames carry the sprop parameter sets, or nil without any")
  func h265ParameterSetsFromSprop() throws {
    let vps = try #require(Data(base64Encoded: dahuaH265VPS))
    let sps = try #require(Data(base64Encoded: dahuaH265SPS))
    let pps = try #require(Data(base64Encoded: dahuaH265PPS))
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: dahuaH265Trio)
    try d.push(makePacket(seq: 0, timestamp: ts0, mark: true, payload: h265IDRSlice))
    let frame = try #require(drain { d.pull() }.frames.first)
    let expected = VideoParameterSetNALs(sps: sps, pps: pps, vps: vps)
    #expect(frame.parameterSets == expected)

    var bare = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try bare.push(makePacket(seq: 0, timestamp: ts0, mark: true, payload: h265IDRSlice))
    let bareFrame = try #require(drain { bare.pull() }.frames.first)
    #expect(bareFrame.parameterSets == nil)
  }

  // MARK: - Finding 11: H.265 SPS with zero width or height is rejected

  /// The Dahua SPS (704x480, no conformance window) with
  /// pic_width_in_luma_samples re-encoded as 0.
  static let h265SPSZeroWidth = Data([
    0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0xB0, 0x00, 0x00, 0x03, 0x00,
    0x00, 0x03, 0x00, 0x5A, 0xA8, 0x07, 0x85, 0x8D, 0xAE, 0x49, 0x14, 0xBF, 0x37, 0x05,
    0x06, 0x05, 0x04, 0x00, 0x00, 0x03, 0x00, 0x04, 0x00, 0x00, 0x03, 0x00, 0x32, 0x84,
  ])

  /// The Dahua SPS with pic_height_in_luma_samples re-encoded as 0.
  static let h265SPSZeroHeight = Data([
    0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0xB0, 0x00, 0x00, 0x03, 0x00,
    0x00, 0x03, 0x00, 0x5A, 0xA0, 0x05, 0x83, 0x63, 0x6B, 0x92, 0x45, 0x2F, 0xCD, 0xC1,
    0x41, 0x81, 0x41, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00, 0x03, 0x00, 0x0C, 0xA1,
  ])

  @Test("H.265: SPS with zero width or height is rejected")
  func h265ZeroDimensionsRejected() throws {
    let vps = try #require(Data(base64Encoded: dahuaH265VPS))
    let pps = try #require(Data(base64Encoded: dahuaH265PPS))
    let cases: [(sps: Data, width: UInt32, height: UInt32)] = [
      (Self.h265SPSZeroWidth, 0, 480),
      (Self.h265SPSZeroHeight, 704, 0),
    ]
    for c in cases {
      let (_, body) = try h265SplitNAL(c.sps)
      let parsed = try parseH265SPS(decodeRBSP(body))
      #expect(parsed.picWidthInLumaSamples == c.width)
      #expect(parsed.picHeightInLumaSamples == c.height)
      #expect(parsed.conformanceWindow == nil)
      #expect(throws: RTSPError.self) {
        _ = try H265Parameters.parseVPSSPSPPS(vps: vps, sps: c.sps, pps: pps)
      }
    }
  }

  @Test("H.265: zero-width SPS falls back like any unparseable parameter set")
  func h265ZeroWidthSPSNotFatal() throws {
    let vps = try #require(Data(base64Encoded: dahuaH265VPS))
    let pps = try #require(Data(base64Encoded: dahuaH265PPS))
    let zeroSPS = Self.h265SPSZeroWidth

    // In sprop: the depacketizer starts without parameters.
    let spsB64 = zeroSPS.base64EncodedString()
    let fmtp = "sprop-vps=\(dahuaH265VPS);sprop-sps=\(spsB64);sprop-pps=\(dahuaH265PPS)"
    let fromSprop = try H265Depacketizer(clockRate: 90000, formatSpecificParams: fmtp)
    #expect(fromSprop.parameters == nil)

    // In band: that access unit is dropped with an error, the next frame
    // reports the loss, and the stream goes on.
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    try d.push(makePacket(seq: 0, timestamp: ts0, mark: false, payload: vps))
    try d.push(makePacket(seq: 1, timestamp: ts0, mark: false, payload: zeroSPS))
    try d.push(makePacket(seq: 2, timestamp: ts0, mark: false, payload: pps))
    try d.push(makePacket(seq: 3, timestamp: ts0, mark: true, payload: h265IDRSlice))
    try d.push(
      makePacket(seq: 4, timestamp: ts1, mark: true, payload: Data([0x02, 0x01, 0x9A])))
    let out = drain { d.pull() }
    #expect(out.errors.count == 1)
    #expect(out.frames.count == 1)
    let loss: UInt16 = out.frames.first?.loss ?? 0
    #expect(loss == 1)
    #expect(d.parameters == nil)
  }

  // MARK: - Finding 12: access-unit boundaries follow the VCL NAL units

  // H.264 7.4.1.2.3 and H.265 7.4.2.4.4: an AUD, SEI (H.265: prefix SEI),
  // SPS or PPS (H.265: also VPS) after the last VCL NAL of an access unit
  // starts the next one. MARK ends an access unit that has a VCL NAL (with
  // any NALs after it that were marked with it); a timestamp change ends it
  // and moves those NALs into the next access unit.

  @Test("H.264: MARK on an SEI after the picture ends the access unit")
  func h264MarkedTrailingSEIEndsAU() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let keyframe = [h264TestSPS, h264TestPPS, h264TestIDRSlice, h264SEI]
    let out = pushUnits(
      &d,
      [
        TestUnit(ts: 0, payloads: keyframe, mark: true),
        TestUnit(ts: 3000, payloads: [h264TestNonIDRSlice], mark: true),
      ])
    #expect(out.errors.isEmpty)
    #expect(h264Summary(out.frames) == ["0 [7, 8, 5, 6]", "3000 [1]"])
    let keyFlags: [Bool] = out.frames.map(\.isRandomAccessPoint)
    #expect(keyFlags == [true, false])
  }

  @Test("H.264: access units ending in a marked SEI are each emitted")
  func h264MarkedSEIStream() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let units: [TestUnit] = (0..<300).map { k in
      TestUnit(ts: Int64(k) * 3000, payloads: [h264TestNonIDRSlice, h264SEI], mark: true)
    }
    let out = pushUnits(&d, units)
    #expect(out.errors.isEmpty)
    #expect(out.frames.count == 300)
    let summary = h264Summary(out.frames)
    let expected: [String] = (0..<300).map { k in "\(k * 3000) [1, 6]" }
    #expect(summary == expected)
  }

  @Test("H.264: SPS and PPS after the picture move to the next access unit")
  func h264TrailingParameterSetsMove() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let out = pushUnits(
      &d,
      [
        TestUnit(ts: 0, payloads: [h264TestNonIDRSlice, h264TestSPS, h264TestPPS], mark: false),
        TestUnit(ts: 3000, payloads: [h264TestIDRSlice], mark: true),
      ])
    #expect(out.errors.isEmpty)
    #expect(h264Summary(out.frames) == ["0 [1]", "3000 [7, 8, 5]"])
    guard out.frames.count == 2 else { return }
    let first = out.frames[0]
    let second = out.frames[1]
    #expect(!first.isRandomAccessPoint)
    #expect(!first.hasNewParameters)
    #expect(first.parameterSets == nil)
    #expect(second.isRandomAccessPoint)
    #expect(second.hasNewParameters)
    #expect(second.parameterSets == VideoParameterSetNALs(sps: h264TestSPS, pps: h264TestPPS))
    #expect(second.data == avcc([h264TestSPS, h264TestPPS, h264TestIDRSlice]))
  }

  @Test("H.264: an AUD or SEI after the picture moves to the next access unit")
  func h264TrailingAUDAndSEIMove() throws {
    let cases: [(nal: Data, expected: String)] = [
      (h264AUD, "3000 [9, 1]"), (h264SEI, "3000 [6, 1]"),
    ]
    for c in cases {
      var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
      let out = pushUnits(
        &d,
        [
          TestUnit(ts: 0, payloads: [h264TestNonIDRSlice, c.nal], mark: false),
          TestUnit(ts: 3000, payloads: [h264TestNonIDRSlice], mark: true),
        ])
      #expect(out.errors.isEmpty)
      #expect(h264Summary(out.frames) == ["0 [1]", c.expected])
    }
  }

  /// End of sequence belongs to the access unit it follows; only the NALs from
  /// the first one that starts an access unit (here the SPS) move.
  @Test("H.264: NALs that don't start an access unit stay with the picture")
  func h264EndOfSequenceStays() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let trailing = [h264TestNonIDRSlice, h264EndOfSequence, h264TestSPS, h264TestPPS]
    let out = pushUnits(
      &d,
      [
        TestUnit(ts: 0, payloads: trailing, mark: false),
        TestUnit(ts: 3000, payloads: [h264TestIDRSlice], mark: true),
      ])
    #expect(out.errors.isEmpty)
    #expect(h264Summary(out.frames) == ["0 [1, 10]", "3000 [7, 8, 5]"])
  }

  @Test("H.264: moved SPS and PPS apply to the access unit they move into")
  func h264MovedParameterSetsApplyToNextAU() throws {
    let setB = try H264Parameters.parseFormatSpecificParams(dahuaFmtp)
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let first = [h264TestSPS, h264TestPPS, h264TestIDRSlice, setB.spsNAL, setB.ppsNAL]
    let out = pushUnits(
      &d,
      [
        TestUnit(ts: 0, payloads: first, mark: false),
        TestUnit(ts: 3000, payloads: [h264TestIDRSlice], mark: true),
      ])
    #expect(out.errors.isEmpty)
    #expect(h264Summary(out.frames) == ["0 [7, 8, 5]", "3000 [7, 8, 5]"])
    guard out.frames.count == 2 else { return }
    let setANALs = VideoParameterSetNALs(sps: h264TestSPS, pps: h264TestPPS)
    let setBNALs = VideoParameterSetNALs(sps: setB.spsNAL, pps: setB.ppsNAL)
    #expect(out.frames[0].hasNewParameters)
    #expect(out.frames[0].parameterSets == setANALs)
    #expect(out.frames[1].hasNewParameters)
    #expect(out.frames[1].parameterSets == setBNALs)
    #expect(d.parameters?.spsNAL == setB.spsNAL)
  }

  @Test("H.264: a moved FU-A NAL keeps its bytes")
  func h264MovedFragmentedNAL() throws {
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    var first: [Data] = [aggregate(header: [0x18], [h264TestSPS, h264TestPPS])]
    first += h264FUA(h264TestIDRSlice, chunk: 3)
    first += h264FUA(h264SEI, chunk: 2)
    let second = h264FUA(h264TestNonIDRSlice, chunk: 2)
    let out = pushUnits(
      &d,
      [
        TestUnit(ts: 0, payloads: first, mark: false),
        TestUnit(ts: 3000, payloads: second, mark: true),
      ])
    #expect(out.errors.isEmpty)
    #expect(out.frames.count == 2)
    guard out.frames.count == 2 else { return }
    #expect(out.frames[0].data == avcc([h264TestSPS, h264TestPPS, h264TestIDRSlice]))
    #expect(out.frames[1].data == avcc([h264SEI, h264TestNonIDRSlice]))
    #expect(out.frames[0].hasNewParameters)
    #expect(!out.frames[1].hasNewParameters)
  }

  @Test("H.264: moved NALs count toward the size cap of the access unit they move into")
  func h264MovedNALsCountTowardCap() throws {
    // The finished access unit's bytes no longer count: two 10 MiB pictures.
    let bigSlice = Data([0x41]) + Data(repeating: 0xAA, count: 10 << 20)
    let bigSliceFUA = h264FUA(bigSlice, chunk: 60_000)
    var d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let out = pushUnits(
      &d,
      [
        TestUnit(ts: 0, payloads: bigSliceFUA + [h264SEI], mark: false),
        TestUnit(ts: 3000, payloads: bigSliceFUA, mark: true),
      ])
    #expect(out.errors.isEmpty)
    #expect(h264Summary(out.frames) == ["0 [1]", "3000 [6, 1]"])

    // A moved 10 MiB SEI plus a 7 MiB slice exceeds the cap.
    let bigSEI = Data([0x06]) + Data(repeating: 0xAA, count: 10 << 20)
    let slice7 = Data([0x41]) + Data(repeating: 0xAA, count: 7 << 20)
    var e = try H264Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let first: [Data] = [h264TestNonIDRSlice] + h264FUA(bigSEI, chunk: 60_000)
    let capped = pushUnits(
      &e,
      [
        TestUnit(ts: 0, payloads: first, mark: false),
        TestUnit(ts: 3000, payloads: h264FUA(slice7, chunk: 60_000), mark: true),
      ])
    #expect(capped.errors.count == 1)
    #expect(h264Summary(capped.frames) == ["0 [1]"])
  }

  @Test("H.265: MARK on a prefix SEI after the picture ends the access unit")
  func h265MarkedTrailingPrefixSEIEndsAU() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let out = pushUnits(
      &d,
      [
        TestUnit(ts: 0, payloads: [h265IDRSlice, h265PrefixSEI], mark: true),
        TestUnit(ts: 3000, payloads: [h265TrailSlice], mark: true),
      ])
    #expect(out.errors.isEmpty)
    #expect(h265Summary(out.frames) == ["0 [19, 39]", "3000 [1]"])
    let keyFlags: [Bool] = out.frames.map(\.isRandomAccessPoint)
    #expect(keyFlags == [true, false])
  }

  @Test("H.265: access units ending in a marked prefix SEI are each emitted")
  func h265MarkedPrefixSEIStream() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let units: [TestUnit] = (0..<300).map { k in
      TestUnit(ts: Int64(k) * 3000, payloads: [h265TrailSlice, h265PrefixSEI], mark: true)
    }
    let out = pushUnits(&d, units)
    #expect(out.errors.isEmpty)
    #expect(out.frames.count == 300)
    let summary = h265Summary(out.frames)
    let expected: [String] = (0..<300).map { k in "\(k * 3000) [1, 39]" }
    #expect(summary == expected)
  }

  @Test("H.265: VPS, SPS and PPS after the picture move to the next access unit")
  func h265TrailingParameterSetsMove() throws {
    let vps = try #require(Data(base64Encoded: dahuaH265VPS))
    let sps = try #require(Data(base64Encoded: dahuaH265SPS))
    let pps = try #require(Data(base64Encoded: dahuaH265PPS))
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let out = pushUnits(
      &d,
      [
        TestUnit(ts: 0, payloads: [h265TrailSlice, vps, sps, pps], mark: false),
        TestUnit(ts: 3000, payloads: [h265IDRSlice], mark: true),
      ])
    #expect(out.errors.isEmpty)
    #expect(h265Summary(out.frames) == ["0 [1]", "3000 [32, 33, 34, 19]"])
    guard out.frames.count == 2 else { return }
    let first = out.frames[0]
    let second = out.frames[1]
    #expect(!first.isRandomAccessPoint)
    #expect(!first.hasNewParameters)
    #expect(first.parameterSets == nil)
    #expect(second.isRandomAccessPoint)
    #expect(second.hasNewParameters)
    #expect(second.parameterSets == VideoParameterSetNALs(sps: sps, pps: pps, vps: vps))
    #expect(second.data == avcc([vps, sps, pps, h265IDRSlice]))

    // Without a VCL NAL (parameter sets sent at the previous picture's
    // timestamp after its MARK), they still join the next picture.
    var r = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let reolinkStyle = pushUnits(
      &r,
      [
        TestUnit(ts: 0, payloads: [h265TrailSlice], mark: true),
        TestUnit(ts: 0, payloads: [vps, sps, pps], mark: false),
        TestUnit(ts: 3000, payloads: [h265IDRSlice], mark: true),
      ])
    #expect(reolinkStyle.errors.isEmpty)
    #expect(h265Summary(reolinkStyle.frames) == ["0 [1]", "3000 [32, 33, 34, 19]"])
  }

  @Test("H.265: an AUD or prefix SEI after the picture moves to the next access unit")
  func h265TrailingAUDAndPrefixSEIMove() throws {
    let cases: [(nal: Data, expected: String)] = [
      (h265AUD, "3000 [35, 1]"), (h265PrefixSEI, "3000 [39, 1]"),
    ]
    for c in cases {
      var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
      let out = pushUnits(
        &d,
        [
          TestUnit(ts: 0, payloads: [h265TrailSlice, c.nal], mark: false),
          TestUnit(ts: 3000, payloads: [h265TrailSlice], mark: true),
        ])
      #expect(out.errors.isEmpty)
      #expect(h265Summary(out.frames) == ["0 [1]", c.expected])
    }
  }

  /// A suffix SEI belongs to the picture it follows; only the NALs from the
  /// first one that starts an access unit (here a prefix SEI) move.
  @Test("H.265: a suffix SEI stays with the picture")
  func h265SuffixSEIStays() throws {
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let trailing = [h265TrailSlice, h265SuffixSEI, h265PrefixSEI]
    let out = pushUnits(
      &d,
      [
        TestUnit(ts: 0, payloads: trailing, mark: false),
        TestUnit(ts: 3000, payloads: [h265TrailSlice], mark: true),
      ])
    #expect(out.errors.isEmpty)
    #expect(h265Summary(out.frames) == ["0 [1, 40]", "3000 [39, 1]"])
  }

  @Test("H.265: moved parameter sets apply to the access unit they move into")
  func h265MovedParameterSetsApplyToNextAU() throws {
    let vpsA = try #require(Data(base64Encoded: dahuaH265VPS))
    let spsA = try #require(Data(base64Encoded: dahuaH265SPS))
    let ppsA = try #require(Data(base64Encoded: dahuaH265PPS))
    let vpsB = try #require(Data(base64Encoded: tendaH265VPS))
    let spsB = try #require(Data(base64Encoded: tendaH265SPS))
    let ppsB = try #require(Data(base64Encoded: tendaH265PPS))
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let first = [vpsA, spsA, ppsA, h265IDRSlice, vpsB, spsB, ppsB]
    let out = pushUnits(
      &d,
      [
        TestUnit(ts: 0, payloads: first, mark: false),
        TestUnit(ts: 3000, payloads: [h265IDRSlice], mark: true),
      ])
    #expect(out.errors.isEmpty)
    #expect(h265Summary(out.frames) == ["0 [32, 33, 34, 19]", "3000 [32, 33, 34, 19]"])
    guard out.frames.count == 2 else { return }
    let setANALs = VideoParameterSetNALs(sps: spsA, pps: ppsA, vps: vpsA)
    let setBNALs = VideoParameterSetNALs(sps: spsB, pps: ppsB, vps: vpsB)
    #expect(out.frames[0].hasNewParameters)
    #expect(out.frames[0].parameterSets == setANALs)
    #expect(out.frames[1].hasNewParameters)
    #expect(out.frames[1].parameterSets == setBNALs)
    #expect(d.parameters?.spsNAL == spsB)
  }

  @Test("H.265: a moved FU NAL keeps its bytes")
  func h265MovedFragmentedNAL() throws {
    let vps = try #require(Data(base64Encoded: dahuaH265VPS))
    let sps = try #require(Data(base64Encoded: dahuaH265SPS))
    let pps = try #require(Data(base64Encoded: dahuaH265PPS))
    let idr = Data([0x26, 0x01, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
    let sei = Data([0x4E, 0x01, 0x05, 0x02, 0xAB, 0xCD, 0x80])
    let trail = Data([0x02, 0x01, 0x9A, 0x9B, 0x9C])
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    var first: [Data] = [aggregate(header: [0x60, 0x01], [vps, sps, pps])]
    first += h265FU(idr, chunk: 2)
    first += h265FU(sei, chunk: 2)
    let out = pushUnits(
      &d,
      [
        TestUnit(ts: 0, payloads: first, mark: false),
        TestUnit(ts: 3000, payloads: h265FU(trail, chunk: 2), mark: true),
      ])
    #expect(out.errors.isEmpty)
    #expect(out.frames.count == 2)
    guard out.frames.count == 2 else { return }
    #expect(out.frames[0].data == avcc([vps, sps, pps, idr]))
    #expect(out.frames[1].data == avcc([sei, trail]))
    #expect(out.frames[0].hasNewParameters)
    #expect(!out.frames[1].hasNewParameters)
  }

  @Test("H.265: moved NALs count toward the size cap of the access unit they move into")
  func h265MovedNALsCountTowardCap() throws {
    let bigSlice = Data([0x02, 0x01]) + Data(repeating: 0xAA, count: 10 << 20)
    let bigSliceFU = h265FU(bigSlice, chunk: 60_000)
    var d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let out = pushUnits(
      &d,
      [
        TestUnit(ts: 0, payloads: bigSliceFU + [h265PrefixSEI], mark: false),
        TestUnit(ts: 3000, payloads: bigSliceFU, mark: true),
      ])
    #expect(out.errors.isEmpty)
    #expect(h265Summary(out.frames) == ["0 [1]", "3000 [39, 1]"])

    let bigSEI = Data([0x4E, 0x01]) + Data(repeating: 0xAA, count: 10 << 20)
    let slice7 = Data([0x02, 0x01]) + Data(repeating: 0xAA, count: 7 << 20)
    var e = try H265Depacketizer(clockRate: 90000, formatSpecificParams: nil)
    let first: [Data] = [h265TrailSlice] + h265FU(bigSEI, chunk: 60_000)
    let capped = pushUnits(
      &e,
      [
        TestUnit(ts: 0, payloads: first, mark: false),
        TestUnit(ts: 3000, payloads: h265FU(slice7, chunk: 60_000), mark: true),
      ])
    #expect(capped.errors.count == 1)
    #expect(h265Summary(capped.frames) == ["0 [1]"])
  }

  // MARK: - Finding 13: sprop base64 without padding

  @Test("H.264: sprop-parameter-sets without base64 padding parse")
  func h264UnpaddedSprop() throws {
    // reolinkFmtp, and the H264DVR camera's sprop (h264dvr_describe.txt).
    let h264dvr = "Z0IAKZY1QPAET8s3AQEBQAAAAwBAAAAHoQ==,aM4xsg=="
    let cases: [(padded: String, stripped: String)] = [
      (reolinkFmtp, "packetization-mode=1;sprop-parameter-sets=Z2QAM6wVFKCgL/lQ,aO48sA"),
      (
        "packetization-mode=1;sprop-parameter-sets=\(h264dvr)",
        "packetization-mode=1;sprop-parameter-sets=Z0IAKZY1QPAET8s3AQEBQAAAAwBAAAAHoQ,aM4xsg"
      ),
    ]
    for c in cases {
      let expected = try H264Parameters.parseFormatSpecificParams(c.padded)
      let parsed = try H264Parameters.parseFormatSpecificParams(c.stripped)
      #expect(parsed == expected)
      let d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: c.stripped)
      #expect(d.parameters == expected)
    }
  }

  @Test("H.265: sprop-vps/sps/pps without base64 padding parse")
  func h265UnpaddedSprop() throws {
    let trios: [(vps: String, sps: String, pps: String)] = [
      (dahuaH265VPS, dahuaH265SPS, dahuaH265PPS),
      (tendaH265VPS, tendaH265SPS, tendaH265PPS),
    ]
    for t in trios {
      let padded = "sprop-vps=\(t.vps);sprop-sps=\(t.sps);sprop-pps=\(t.pps)"
      let stripped =
        "sprop-vps=\(unpadded(t.vps));sprop-sps=\(unpadded(t.sps));sprop-pps=\(unpadded(t.pps))"
      #expect(stripped != padded)
      let expected = try H265Parameters.parseFormatSpecificParams(padded)
      let parsed = try H265Parameters.parseFormatSpecificParams(stripped)
      #expect(parsed == expected)
      let d = try H265Depacketizer(clockRate: 90000, formatSpecificParams: stripped)
      #expect(d.parameters == expected)
    }
  }

  // MARK: - Finding 14: H.264 interleaved mode fails at construction

  @Test("H.264: packetization-mode=2 (interleaved) fails depacketizer init")
  func h264InterleavedModeFailsInit() throws {
    let sprop = "sprop-parameter-sets=Z2QAM6wVFKCgL/lQ,aO48sA=="
    let rejected = [
      "packetization-mode=2;\(sprop)", " Packetization-Mode = 2 ;\(sprop)", "packetization-mode=2",
    ]
    for fmtp in rejected {
      #expect(throws: RTSPError.self, "\(fmtp)") {
        _ = try H264Depacketizer(clockRate: 90000, formatSpecificParams: fmtp)
      }
    }
    do {
      _ = try H264Depacketizer(clockRate: 90000, formatSpecificParams: rejected[0])
      Issue.record("packetization-mode=2 was accepted")
    } catch RTSPError.depacketizationError(let message) {
      #expect(message.contains("packetization-mode=2"), "\(message)")
    }
    for fmtp in ["packetization-mode=0;\(sprop)", "packetization-mode=1;\(sprop)", sprop] {
      let d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: fmtp)
      #expect(d.parameters != nil, "\(fmtp)")
    }
  }

  @Test("Base64 sprop values decode with full, partial or no padding")
  func spropBase64Padding() {
    let pps = Data([0x68, 0xEE, 0x3C, 0xB0])
    #expect(decodeSpropBase64("aO48sA==") == pps)
    #expect(decodeSpropBase64("aO48sA=") == pps)
    #expect(decodeSpropBase64("aO48sA") == pps)
    #expect(decodeSpropBase64("Z2QAM6wVFKCgL/lQ") == h264TestSPS)
    // Five characters can't be base64 with or without padding.
    #expect(decodeSpropBase64("aO48s") == nil)
    #expect(decodeSpropBase64("!!") == nil)
  }

  // MARK: - Finding 15: parameters carried across a depacketizer reset

  @Test("H.264: adoptParameters keeps the stream's parameter sets in a fresh depacketizer")
  func h264AdoptParameters() throws {
    // reolinkFmtp's sprop-parameter-sets are set A (h264TestSPS/PPS).
    let setB = try H264Parameters.parseFormatSpecificParams(dahuaFmtp)
    let setANALs = VideoParameterSetNALs(sps: h264TestSPS, pps: h264TestPPS)
    let setBNALs = VideoParameterSetNALs(sps: setB.spsNAL, pps: setB.ppsNAL)
    let keyframeA = [h264TestSPS, h264TestPPS, h264TestIDRSlice]
    let keyframeB = [setB.spsNAL, setB.ppsNAL, h264TestIDRSlice]

    // The depacketizer in use started from the SDP's set A, switched to set B
    // in band, and has a frame in progress.
    var old = try H264Depacketizer(clockRate: 90000, formatSpecificParams: reolinkFmtp)
    #expect(old.parameters?.spsNAL == h264TestSPS)
    let switched = pushUnits(
      &old,
      [
        TestUnit(ts: 0, payloads: keyframeB, mark: true),
        TestUnit(ts: 3000, payloads: [h264TestNonIDRSlice], mark: false),
      ])
    #expect(switched.frames.count == 1)
    #expect(old.parameters?.spsNAL == setB.spsNAL)

    // A fresh depacketizer from the same SDP (as after a seek) adopts set B.
    var fresh = try H264Depacketizer(clockRate: 90000, formatSpecificParams: reolinkFmtp)
    fresh.adoptParameters(from: old)
    #expect(fresh.parameters == old.parameters)
    let out = pushUnits(
      &fresh,
      [
        TestUnit(ts: 6000, payloads: keyframeB, mark: true),
        TestUnit(ts: 9000, payloads: keyframeA, mark: true),
      ])
    #expect(out.errors.isEmpty)
    // Only these two: `old`'s frame in progress was not adopted.
    #expect(h264Summary(out.frames) == ["6000 [7, 8, 5]", "9000 [7, 8, 5]"])
    guard out.frames.count == 2 else { return }
    #expect(!out.frames[0].hasNewParameters)
    #expect(out.frames[0].parameterSets == setBNALs)
    #expect(out.frames[1].hasNewParameters)
    #expect(out.frames[1].parameterSets == setANALs)

    // Without adopting, set B in band is a change.
    var plain = try H264Depacketizer(clockRate: 90000, formatSpecificParams: reolinkFmtp)
    let plainOut = pushUnits(&plain, [TestUnit(ts: 6000, payloads: keyframeB, mark: true)])
    #expect(plainOut.frames.first?.hasNewParameters == true)
  }

  @Test("H.265: adoptParameters keeps the stream's parameter sets in a fresh depacketizer")
  func h265AdoptParameters() throws {
    // dahuaH265Trio is set A.
    let vpsA = try #require(Data(base64Encoded: dahuaH265VPS))
    let spsA = try #require(Data(base64Encoded: dahuaH265SPS))
    let ppsA = try #require(Data(base64Encoded: dahuaH265PPS))
    let vpsB = try #require(Data(base64Encoded: tendaH265VPS))
    let spsB = try #require(Data(base64Encoded: tendaH265SPS))
    let ppsB = try #require(Data(base64Encoded: tendaH265PPS))
    let setANALs = VideoParameterSetNALs(sps: spsA, pps: ppsA, vps: vpsA)
    let setBNALs = VideoParameterSetNALs(sps: spsB, pps: ppsB, vps: vpsB)
    let keyframeA = [vpsA, spsA, ppsA, h265IDRSlice]
    let keyframeB = [vpsB, spsB, ppsB, h265IDRSlice]

    var old = try H265Depacketizer(clockRate: 90000, formatSpecificParams: dahuaH265Trio)
    #expect(old.parameters?.spsNAL == spsA)
    let switched = pushUnits(
      &old,
      [
        TestUnit(ts: 0, payloads: keyframeB, mark: true),
        TestUnit(ts: 3000, payloads: [h265TrailSlice], mark: false),
      ])
    #expect(switched.frames.count == 1)
    #expect(old.parameters?.spsNAL == spsB)

    var fresh = try H265Depacketizer(clockRate: 90000, formatSpecificParams: dahuaH265Trio)
    fresh.adoptParameters(from: old)
    #expect(fresh.parameters == old.parameters)
    let out = pushUnits(
      &fresh,
      [
        TestUnit(ts: 6000, payloads: keyframeB, mark: true),
        TestUnit(ts: 9000, payloads: keyframeA, mark: true),
      ])
    #expect(out.errors.isEmpty)
    #expect(h265Summary(out.frames) == ["6000 [32, 33, 34, 19]", "9000 [32, 33, 34, 19]"])
    guard out.frames.count == 2 else { return }
    #expect(!out.frames[0].hasNewParameters)
    #expect(out.frames[0].parameterSets == setBNALs)
    #expect(out.frames[1].hasNewParameters)
    #expect(out.frames[1].parameterSets == setANALs)

    var plain = try H265Depacketizer(clockRate: 90000, formatSpecificParams: dahuaH265Trio)
    let plainOut = pushUnits(&plain, [TestUnit(ts: 6000, payloads: keyframeB, mark: true)])
    #expect(plainOut.frames.first?.hasNewParameters == true)
  }
}

@Suite("H.264 sprop with several parameter sets")
struct H264SeveralSpropSetsTests {
  @Test("sprop-parameter-sets with two PPS (or two SPS) keeps the first of each")
  func firstOfEach() throws {
    let secondPPS = Data([0x68, 0xEE, 0x31, 0xB2, 0x1B, 0x00])
    let list = [h264TestSPS, h264TestPPS, secondPPS, h264TestSPS]
      .map { $0.base64EncodedString() }.joined(separator: ",")
    let fmtp = "packetization-mode=1;sprop-parameter-sets=\(list)"
    let d = try H264Depacketizer(clockRate: 90000, formatSpecificParams: fmtp)
    let parameters = try #require(d.parameters)
    #expect(parameters.spsNAL == h264TestSPS)
    #expect(parameters.ppsNAL == h264TestPPS)
  }
}

@Suite("Depacketizer wrappers change their buffers in place", .timeLimit(.minutes(1)))
struct DepacketizerWrapperCostTests {
  /// Each packet must not copy the frame being assembled: through the enum
  /// wrappers a 20,000-fragment frame took seconds (quadratic) instead of
  /// milliseconds.
  @Test("A frame of 20,000 FU-A fragments through VideoDepacketizer takes linear time")
  func manyFragments() throws {
    let count = 20_000
    let nal = Data([0x65]) + Data(repeating: 0xAB, count: count * 100)
    let payloads = h264FUA(nal, chunk: 100)
    #expect(payloads.count == count)
    var d = VideoDepacketizer.h264(
      try H264Depacketizer(clockRate: 90000, formatSpecificParams: dahuaFmtp))
    let started = ContinuousClock.now
    var frames = 0
    for (index, payload) in payloads.enumerated() {
      try d.push(
        makePacket(
          seq: UInt16(truncatingIfNeeded: index), timestamp: ts0,
          mark: index == payloads.count - 1, payload: payload))
      while let result = d.pull() {
        if case .success(.videoFrame) = result { frames += 1 }
      }
    }
    #expect(frames == 1)
    #expect(ContinuousClock.now - started < .seconds(1))
  }

  /// The session's own copy of a depacketizer must not share its buffers
  /// while a packet is pushed, for video and for metadata (documents up to
  /// 1 MiB).
  @Test("A fragmented frame and a large metadata document reach frames() in linear time")
  func sessionManyFragments() async throws {
    let sdp = makeTestSDP(media: [h264VideoMediaSDP(), onvifMetadataMediaSDP()])
    let server = FakeRTSPServer(sdp: sdp)
    let nal = Data([0x65]) + Data(repeating: 0xAB, count: 30_000 * 100)
    let document = Data(
      ("<?xml version=\"1.0\"?><tt:MetadataStream xmlns:tt=\"http://www.onvif.org/ver10/schema\">"
        + String(repeating: "<tt:Event/>", count: 80_000) + "</tt:MetadataStream>").utf8)
    server.onPlay = { _, handle in
      guard let video = handle.setup(forStream: 0), let metadata = handle.setup(forStream: 1)
      else { return }
      let fragments = h264FUA(nal, chunk: 100)
      for (index, payload) in fragments.enumerated() {
        handle.sendRTP(
          makeRTP(
            sequence: video.parameters.initialSequence &+ UInt16(truncatingIfNeeded: index),
            timestamp: video.parameters.initialRTPTime, ssrc: video.parameters.ssrc,
            payloadType: 96, marker: index == fragments.count - 1, payload: payload),
          stream: 0)
      }
      let pieces = stride(from: 0, to: document.count, by: 64).map {
        document[$0..<min($0 + 64, document.count)]
      }
      for (index, piece) in pieces.enumerated() {
        handle.sendRTP(
          makeRTP(
            sequence: metadata.parameters.initialSequence &+ UInt16(truncatingIfNeeded: index),
            timestamp: metadata.parameters.initialRTPTime, ssrc: metadata.parameters.ssrc,
            payloadType: 107, marker: index == pieces.count - 1, payload: Data(piece)),
          stream: 1)
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url)
    _ = try await session.start()
    let started = ContinuousClock.now
    var gotVideo = false
    var gotMetadata = false
    for try await item in session.frames() {
      switch item {
      case .video: gotVideo = true
      case .metadata(let frame): gotMetadata = frame.data.count == document.count
      default: break
      }
      if gotVideo && gotMetadata { break }
    }
    #expect(ContinuousClock.now - started < .seconds(2))
    await session.stop()
  }
}

/// Writes RBSP bits most significant first, with exp-Golomb codes.
private struct SPSBitWriter {
  private(set) var bytes: [UInt8] = []
  private var bitCount = 0

  mutating func bit(_ value: Bool) {
    if bitCount % 8 == 0 { bytes.append(0) }
    if value { bytes[bytes.count - 1] |= 0x80 >> UInt8(bitCount % 8) }
    bitCount += 1
  }

  /// ue(v): `length - 1` zero bits, then `value + 1` in `length` bits.
  mutating func ue(_ value: UInt32) {
    let code = UInt64(value) + 1
    let length = UInt64.bitWidth - code.leadingZeroBitCount
    for _ in 1..<length { bit(false) }
    for shift in stride(from: length - 1, through: 0, by: -1) {
      bit((code >> UInt64(shift)) & 1 == 1)
    }
  }

  /// se(v): positive v as ue(2v - 1), others as ue(-2v).
  mutating func se(_ value: Int32) {
    ue(value > 0 ? UInt32(2 * Int64(value) - 1) : UInt32(-2 * Int64(value)))
  }
}

/// SPS bits through num_ref_frames_in_pic_order_cnt_cycle, with
/// pic_order_cnt_type 1.
private func h264SPSPrefix(pocCycle cycle: UInt32) -> SPSBitWriter {
  var w = SPSBitWriter()
  w.ue(0)  // seq_parameter_set_id
  w.ue(0)  // log2_max_frame_num_minus4
  w.ue(1)  // pic_order_cnt_type
  w.bit(false)  // delta_pic_order_always_zero_flag
  w.se(0)  // offset_for_non_ref_pic
  w.se(0)  // offset_for_top_to_bottom_field
  w.ue(cycle)  // num_ref_frames_in_pic_order_cnt_cycle
  return w
}

/// A complete Baseline SPS (`67 42 00 1E`, 320x240) whose POC cycle has
/// `cycle` entries. No run of 16 zero bits is written, so the NAL needs no
/// emulation prevention bytes.
private func h264SPS(pocCycle cycle: UInt32) -> Data {
  var w = h264SPSPrefix(pocCycle: cycle)
  for i in 0..<cycle {
    w.se(Int32(i % 3) - 1)  // offset_for_ref_frame: -1, 0, 1, ...
  }
  w.ue(1)  // max_num_ref_frames
  w.bit(false)  // gaps_in_frame_num_value_allowed_flag
  w.ue(19)  // pic_width_in_mbs_minus1: 320 pixels
  w.ue(14)  // pic_height_in_map_units_minus1: 240 pixels
  w.bit(true)  // frame_mbs_only_flag
  w.bit(true)  // direct_8x8_inference_flag
  w.bit(false)  // frame_cropping_flag
  w.bit(false)  // vui_parameters_present_flag
  w.bit(true)  // rbsp_stop_one_bit
  return Data([0x67, 0x42, 0x00, 0x1E] + w.bytes)
}

@Suite("Parameter-set size and count limits", .timeLimit(.minutes(1)))
struct ParameterSetLimitTests {
  /// A parameter set over 64 KiB can't go in the decoder configuration, so it
  /// must be rejected before its RBSP is decoded and parsed. The depacketizer
  /// offers it again with every frame that carries it; parsing this one took
  /// about 1 s in release builds (5 s in debug) each time.
  @Test("H.264: a 4 MiB SPS is rejected for its size before it is parsed")
  func h264OversizedSPSRejectedBeforeParsing() throws {
    var sps = Data([0x67, 0x42, 0x00, 0x1E] + h264SPSPrefix(pocCycle: 1 << 30).bytes)
    sps.append(Data(repeating: 0xFF, count: (4 << 20) - sps.count))
    let started = ContinuousClock.now
    do {
      _ = try H264Parameters.parseSPSAndPPS(sps: sps, pps: h264TestPPS)
      Issue.record("4 MiB SPS was accepted")
    } catch RTSPError.depacketizationError(let message) {
      #expect(message.contains("must fit in u16"), "\(message)")
    }
    #expect(ContinuousClock.now - started < .milliseconds(100))
  }

  @Test("H.265: a 4 MiB SPS is rejected for its size before it is parsed")
  func h265OversizedSPSRejectedBeforeParsing() throws {
    let vps = try #require(Data(base64Encoded: dahuaH265VPS))
    let pps = try #require(Data(base64Encoded: dahuaH265PPS))
    // An SPS NAL header, then filler that doesn't parse as an SPS.
    let sps = Data([0x42, 0x01]) + Data(repeating: 0xFF, count: (4 << 20) - 2)
    let started = ContinuousClock.now
    do {
      _ = try H265Parameters.parseVPSSPSPPS(vps: vps, sps: sps, pps: pps)
      Issue.record("4 MiB SPS was accepted")
    } catch RTSPError.depacketizationError(let message) {
      #expect(message.contains("exceeds 65535 bytes"), "\(message)")
    }
    #expect(ContinuousClock.now - started < .milliseconds(100))
  }

  /// H.264 7.4.2.1.1 limits num_ref_frames_in_pic_order_cnt_cycle to 255.
  @Test("H.264: SPS POC cycle of 255 entries parses, 256 is rejected")
  func h264POCCycleLimit() throws {
    let parsed = try parseSPS(h264SPS(pocCycle: 255))
    #expect(parsed.width == 320)
    #expect(parsed.height == 240)
    let params = try H264Parameters.parseSPSAndPPS(
      sps: h264SPS(pocCycle: 255), pps: h264TestPPS)
    #expect(params.genericParameters.pixelDimensions?.width == 320)
    #expect(params.genericParameters.pixelDimensions?.height == 240)

    do {
      _ = try parseSPS(h264SPS(pocCycle: 256))
      Issue.record("POC cycle of 256 entries was accepted")
    } catch RTSPError.depacketizationError(let message) {
      #expect(message.contains("num_ref_frames_in_pic_order_cnt_cycle"), "\(message)")
    }
  }
}
