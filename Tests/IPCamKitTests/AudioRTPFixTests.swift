// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Regression tests for audio depacketizer and RTP-layer recovery fixes.

import Foundation
import Testing

@testable import IPCamKit

// MARK: - Helpers

private let fmtp1188 =
  "streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;"
  + "indexdeltalength=3;config=1188"

private func aacFmtp(config: String) -> String {
  "streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;"
    + "indexdeltalength=3;config=\(config)"
}

private func audioPacket(
  seq: UInt16, ts: Int64, clockRate: UInt32 = 48_000, mark: Bool, loss: UInt16 = 0,
  payload: Data
) -> ReceivedRTPPacket {
  let timestamp = Timestamp(timestamp: ts, clockRate: clockRate, start: 0)!
  let builder = ReceivedPacketBuilder(
    ctx: .dummy, streamId: 0, sequenceNumber: seq, timestamp: timestamp, payloadType: 97,
    ssrc: 0x1234, mark: mark, loss: loss)
  return try! builder.build(payload: payload).get()
}

/// An AAC-hbr payload with one AU header (`auSize`, index 0) and `data`.
private func aacPayload(auSize: Int, data: Data, index: UInt16 = 0) -> Data {
  let header = UInt16(auSize) << 3 | index
  return Data([0x00, 0x10, UInt8(header >> 8), UInt8(header & 0xFF)]) + data
}

/// An AAC-hbr payload with one AU header per element of `aus`.
private func aacAggregate(_ aus: [Data]) -> Data {
  let bits = UInt16(aus.count * 16)
  var payload = Data([UInt8(bits >> 8), UInt8(bits & 0xFF)])
  for au in aus {
    let header = UInt16(au.count) << 3
    payload.append(contentsOf: [UInt8(header >> 8), UInt8(header & 0xFF)])
  }
  for au in aus { payload.append(au) }
  return payload
}

/// Drains `d`, returning the audio frames and the number of failures.
private func drain(_ d: inout AACDepacketizer) -> (frames: [AudioFrame], failures: Int) {
  var frames: [AudioFrame] = []
  var failures = 0
  while let item = d.pull() {
    switch item {
    case .success(.audioFrame(let f)): frames.append(f)
    case .failure: failures += 1
    default: break
    }
  }
  return (frames, failures)
}

private func rtpData(
  seq: UInt16, ts: UInt32, ssrc: UInt32, mark: Bool = true, payload: Data = Data("x".utf8)
) -> Data {
  try! RTPPacketBuilder(
    sequenceNumber: seq, timestamp: ts, payloadType: 96, ssrc: ssrc, mark: mark
  ).build(payload: payload).get().data
}

private func makeParser(
  ssrc: UInt32?, isTcp: Bool, clockRate: UInt32 = 8_000,
  policy: UnknownRtcpSsrcPolicy = .dropPackets
) throws -> InorderParser {
  InorderParser(
    ssrc: ssrc, nextSeq: nil, isTcp: isTcp,
    timeline: try Timeline(start: nil, clockRate: clockRate),
    unknownRtcpSsrcPolicy: policy)
}

private func feed(_ p: inout InorderParser, _ data: Data) throws -> ReceivedRTPPacket? {
  try p.rtp(data: data, ctx: .dummy, streamId: 0, streamCtx: .dummy)
}

private func senderReport(ssrc: UInt32, rtpTimestamp: UInt32) -> Data {
  func be32(_ v: UInt32) -> [UInt8] {
    [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
  }
  var d = Data([0x80, 0xC8, 0x00, 0x06])
  d.append(contentsOf: be32(ssrc))
  d.append(contentsOf: [UInt8](repeating: 0, count: 8))
  d.append(contentsOf: be32(rtpTimestamp))
  d.append(contentsOf: [UInt8](repeating: 0, count: 8))
  return d
}

// MARK: - AAC fragment recovery (finding 1)

@Suite("AAC fragment recovery")
struct AACFragmentRecoveryTests {
  private let fragStart = aacPayload(auSize: 100, data: Data(repeating: 0xAA, count: 50))

  @Test("A fragment interrupted by a new timestamp is abandoned, not a permanent stall")
  func timestampChangeAbandonsFragment() throws {
    var d = try AACDepacketizer(clockRate: 48_000, channels: nil, formatSpecificParams: fmtp1188)
    try d.push(audioPacket(seq: 0, ts: 0, mark: false, payload: fragStart))
    #expect(drain(&d).frames.isEmpty)

    var frames: [AudioFrame] = []
    var throwsCount = 0
    for i in 1...50 {
      let pkt = audioPacket(
        seq: UInt16(i), ts: Int64(i) * 1_024, mark: true,
        payload: aacPayload(auSize: 4, data: Data("abcd".utf8)))
      do {
        try d.push(pkt)
      } catch {
        throwsCount += 1
        continue
      }
      frames += drain(&d).frames
    }
    #expect(throwsCount == 0)
    #expect(frames.count == 50)
    // The abandoned AU surfaces as loss on the next frame.
    #expect(frames.first?.loss == 1)
    #expect(frames.dropFirst().allSatisfy { $0.loss == 0 })
  }

  @Test("A multi-AU packet during a fragment abandons the fragment and is processed")
  func aggregateAbandonsFragment() throws {
    var d = try AACDepacketizer(clockRate: 48_000, channels: nil, formatSpecificParams: fmtp1188)
    try d.push(audioPacket(seq: 0, ts: 0, mark: false, payload: fragStart))
    #expect(drain(&d).frames.isEmpty)
    try d.push(
      audioPacket(
        seq: 1, ts: 1_024, mark: true,
        payload: aacAggregate([Data("ab".utf8), Data("cd".utf8)])))
    let out = drain(&d)
    #expect(out.frames.map(\.data) == [Data("ab".utf8), Data("cd".utf8)])
    #expect(out.frames.first?.loss == 1)
  }

  /// Each case: a fragment start, a bad continuation at the same timestamp
  /// (which must throw), then a valid AU at a new timestamp (which must decode).
  @Test(
    "A bad continuation resets the fragment so the next AU decodes",
    arguments: [
      // frag marked complete with too little data
      (aacPayload(auSize: 9, data: Data("foo".utf8)), true, 9),
      // frag not marked complete when full data present
      (aacPayload(auSize: 6, data: Data("foo".utf8)), false, 6),
      // too much data in fragment
      (aacPayload(auSize: 5, data: Data("foo".utf8)), true, 5),
      // size changed mid-fragment
      (aacPayload(auSize: 8, data: Data("foo".utf8)), true, 9),
    ])
  func badContinuationResets(continuation: Data, mark: Bool, startSize: Int) throws {
    var d = try AACDepacketizer(clockRate: 48_000, channels: nil, formatSpecificParams: fmtp1188)
    try d.push(
      audioPacket(
        seq: 0, ts: 0, mark: false,
        payload: aacPayload(auSize: startSize, data: Data("abc".utf8))))
    #expect(drain(&d).frames.isEmpty)
    #expect(throws: DepacketizeError.self) {
      try d.push(audioPacket(seq: 1, ts: 0, mark: mark, payload: continuation))
    }
    #expect(drain(&d).frames.isEmpty)
    try d.push(
      audioPacket(
        seq: 2, ts: 1_024, mark: true, payload: aacPayload(auSize: 4, data: Data("abcd".utf8))))
    let out = drain(&d)
    #expect(out.frames.map(\.data) == [Data("abcd".utf8)])
    #expect(out.frames.first?.loss == 1)
  }
}

// MARK: - AAC error paths keep loss (finding 6)

@Suite("AAC error paths keep loss")
struct AACErrorLossTests {
  @Test("An interleaved AU failure carries the packet's loss plus the dropped AU")
  func interleavingFailureKeepsLoss() throws {
    var d = try AACDepacketizer(clockRate: 48_000, channels: nil, formatSpecificParams: fmtp1188)
    try d.push(
      audioPacket(
        seq: 3, ts: 0, mark: true, loss: 3,
        payload: aacPayload(auSize: 4, data: Data("abcd".utf8), index: 1)))
    let bad = drain(&d)
    #expect(bad.frames.isEmpty)
    #expect(bad.failures == 1)
    try d.push(
      audioPacket(
        seq: 4, ts: 1_024, mark: true, payload: aacPayload(auSize: 4, data: Data("efgh".utf8))))
    #expect(drain(&d).frames.first?.loss == 4)
  }

  @Test("An unmarked non-fragmented AU failure carries the loss forward")
  func unmarkedFailureKeepsLoss() throws {
    var d = try AACDepacketizer(clockRate: 48_000, channels: nil, formatSpecificParams: fmtp1188)
    try d.push(
      audioPacket(
        seq: 2, ts: 0, mark: false, loss: 2,
        payload: aacPayload(auSize: 4, data: Data("abcd".utf8))))
    #expect(drain(&d).failures == 1)
    try d.push(
      audioPacket(
        seq: 3, ts: 1_024, mark: true, payload: aacPayload(auSize: 4, data: Data("efgh".utf8))))
    #expect(drain(&d).frames.first?.loss == 3)
  }

  @Test("A failure on a later AU of an aggregate reports the dropped AU")
  func laterAUFailureReportsLoss() throws {
    var d = try AACDepacketizer(clockRate: 48_000, channels: nil, formatSpecificParams: fmtp1188)
    // Second header has a non-zero AU-index-delta (interleaving).
    let payload = Data([0x00, 0x20, 0x00, 0x10, 0x00, 0x11]) + Data("abcd".utf8)
    try d.push(audioPacket(seq: 0, ts: 0, mark: true, payload: payload))
    let out = drain(&d)
    #expect(out.frames.map(\.data) == [Data("ab".utf8)])
    #expect(out.failures == 1)
    try d.push(
      audioPacket(
        seq: 1, ts: 2_048, mark: true, payload: aacPayload(auSize: 4, data: Data("efgh".utf8))))
    #expect(drain(&d).frames.first?.loss == 1)
  }
}

// MARK: - HE-AAC (findings 4 and 5)

@Suite("HE-AAC timing")
struct HEAACTests {
  @Test("Implicit SBR: per-AU offsets scale with the RTP/ASC clock ratio")
  func implicitSbrAggregateTimestamps() throws {
    var d = try AACDepacketizer(
      clockRate: 48_000, channels: nil, formatSpecificParams: aacFmtp(config: "1308"))
    let base: Int64 = 10_000
    try d.push(
      audioPacket(
        seq: 0, ts: base, mark: true, payload: aacAggregate([Data("ab".utf8), Data("cd".utf8)])))
    let frames = drain(&d).frames
    #expect(frames.count == 2)
    let second = try #require(frames.last)
    let expected: Int64 = base + 2_048
    #expect(second.timestamp.timestamp == expected)
    let expectedLength: UInt32 = 2_048
    #expect(second.frameLength == expectedLength)
    let rate: UInt32 = 48_000
    #expect(d.parameters.clockRate == rate)
    #expect(d.parameters.frameLength == expectedLength)
  }

  @Test("Explicit SBR (AOT 5) AudioSpecificConfig parses")
  func explicitSbrParses() throws {
    // AOT 5, core 24 kHz stereo, extension 48 kHz, core AOT 2 (AAC-LC).
    let asc = try AudioSpecificConfig.parse(Data([0x2B, 0x11, 0x88, 0x00]))
    let rate: UInt32 = 48_000
    #expect(asc.parameters.clockRate == rate)
    let length: UInt32 = 2_048
    #expect(asc.parameters.frameLength == length)
    #expect(asc.parameters.rfc6381Codec == "mp4a.40.5")
    #expect(asc.channels.name == "stereo")
  }

  @Test("Explicit PS (AOT 29) AudioSpecificConfig parses")
  func explicitPsParses() throws {
    // AOT 29, core 24 kHz mono, extension 48 kHz, core AOT 2.
    let asc = try AudioSpecificConfig.parse(Data([0xEB, 0x09, 0x88, 0x00]))
    let rate: UInt32 = 48_000
    #expect(asc.parameters.clockRate == rate)
    #expect(asc.parameters.rfc6381Codec == "mp4a.40.29")
  }

  @Test(
    "Explicit SBR depacketizes with 2048 ticks per AU at a 48 kHz RTP clock",
    arguments: [(UInt32(48_000), Int64(2_048)), (UInt32(24_000), Int64(1_024))])
  func explicitSbrTimestamps(clockRate: UInt32, step: Int64) throws {
    var d = try AACDepacketizer(
      clockRate: clockRate, channels: nil, formatSpecificParams: aacFmtp(config: "2B118800"))
    try d.push(
      audioPacket(
        seq: 0, ts: 0, clockRate: clockRate, mark: true,
        payload: aacAggregate([Data("ab".utf8), Data("cd".utf8)])))
    let frames = drain(&d).frames
    let second = try #require(frames.last)
    #expect(second.timestamp.timestamp == step)
  }
}

// MARK: - InorderParser sequence resync (finding 2)

@Suite("InorderParser sequence resync")
struct InorderSequenceResyncTests {
  @Test("UDP: two consecutive packets after a large jump resynchronize")
  func udpJumpResyncs() throws {
    var p = try makeParser(ssrc: nil, isTcp: false)
    #expect(try feed(&p, rtpData(seq: 100, ts: 0, ssrc: 1)) != nil)
    #expect(try feed(&p, rtpData(seq: 101, ts: 160, ssrc: 1)) != nil)
    // A single packet far away is held back (could be a stray).
    #expect(try feed(&p, rtpData(seq: 40_000, ts: 320, ssrc: 1)) == nil)
    let second = try #require(try feed(&p, rtpData(seq: 40_001, ts: 480, ssrc: 1)))
    #expect(second.loss >= 1)
    let third = try #require(try feed(&p, rtpData(seq: 40_002, ts: 640, ssrc: 1)))
    #expect(third.loss == 0)
  }

  @Test("UDP: a single stray packet does not resync")
  func udpStrayIgnored() throws {
    var p = try makeParser(ssrc: nil, isTcp: false)
    #expect(try feed(&p, rtpData(seq: 100, ts: 0, ssrc: 1)) != nil)
    #expect(try feed(&p, rtpData(seq: 40_000, ts: 160, ssrc: 1)) == nil)
    let next = try #require(try feed(&p, rtpData(seq: 101, ts: 320, ssrc: 1)))
    #expect(next.loss == 0)
  }

  @Test("UDP: late packets within the misorder window are dropped without resync")
  func udpLatePacketsDropped() throws {
    var p = try makeParser(ssrc: nil, isTcp: false)
    #expect(try feed(&p, rtpData(seq: 10, ts: 0, ssrc: 1)) != nil)
    #expect(try feed(&p, rtpData(seq: 8, ts: 0, ssrc: 1)) == nil)
    #expect(try feed(&p, rtpData(seq: 9, ts: 0, ssrc: 1)) == nil)
    let next = try #require(try feed(&p, rtpData(seq: 11, ts: 160, ssrc: 1)))
    #expect(next.loss == 0)
  }

  @Test("TCP: a large jump resynchronizes on the first packet", arguments: [40_000, 5])
  func tcpJumpResyncs(newSeq: Int) throws {
    var p = try makeParser(ssrc: nil, isTcp: true)
    #expect(try feed(&p, rtpData(seq: 5_000, ts: 0, ssrc: 1)) != nil)
    let jumped = try #require(try feed(&p, rtpData(seq: UInt16(newSeq), ts: 160, ssrc: 1)))
    #expect(jumped.loss >= 1)
    let next = try #require(try feed(&p, rtpData(seq: UInt16(newSeq + 1), ts: 320, ssrc: 1)))
    #expect(next.loss == 0)
  }
}

// MARK: - InorderParser SSRC change (finding 3)

@Suite("InorderParser SSRC change")
struct InorderSSRCChangeTests {
  @Test(
    "A new SSRC is adopted after two consecutive packets, timeline continuous",
    arguments: [false, true])
  func adoptsNewSSRC(isTcp: Bool) throws {
    var p = try makeParser(ssrc: 0xAAAA, isTcp: isTcp)
    var last: ReceivedRTPPacket?
    for i in 0..<3 {
      last = try feed(&p, rtpData(seq: UInt16(10 + i), ts: UInt32(1_000 + 160 * i), ssrc: 0xAAAA))
    }
    let lastTs = try #require(last).timestamp.timestamp
    // New source: unrelated sequence and timestamp bases.
    #expect(try feed(&p, rtpData(seq: 7_000, ts: 3_000_000_000, ssrc: 0xBBBB)) == nil)
    let adopted = try #require(try feed(&p, rtpData(seq: 7_001, ts: 3_000_000_160, ssrc: 0xBBBB)))
    #expect(adopted.loss >= 1)
    let adoptedTs = adopted.timestamp.timestamp
    #expect(adoptedTs > lastTs)
    #expect(adoptedTs - lastTs < 8_000)
    let next = try #require(try feed(&p, rtpData(seq: 7_002, ts: 3_000_000_320, ssrc: 0xBBBB)))
    #expect(next.loss == 0)
    let step: Int64 = 160
    #expect(next.timestamp.timestamp - adoptedTs == step)
    // The old source is now the foreign one.
    #expect(try feed(&p, rtpData(seq: 13, ts: 1_480, ssrc: 0xAAAA)) == nil)
  }

  @Test("Interleaved stray packets from another SSRC never take over")
  func interleavedStrayIgnored() throws {
    var p = try makeParser(ssrc: 0xAAAA, isTcp: false)
    for i in 0..<4 {
      let own = try #require(
        try feed(&p, rtpData(seq: UInt16(10 + i), ts: UInt32(160 * i), ssrc: 0xAAAA)))
      #expect(own.loss == 0)
      #expect(try feed(&p, rtpData(seq: UInt16(500 + i), ts: 9_999, ssrc: 0xBBBB)) == nil)
    }
  }

  @Test("Two packets from a new SSRC with non-consecutive sequence numbers don't switch")
  func nonConsecutiveNotAdopted() throws {
    var p = try makeParser(ssrc: 0xAAAA, isTcp: true)
    #expect(try feed(&p, rtpData(seq: 1, ts: 0, ssrc: 0xAAAA)) != nil)
    #expect(try feed(&p, rtpData(seq: 500, ts: 0, ssrc: 0xBBBB)) == nil)
    #expect(try feed(&p, rtpData(seq: 505, ts: 0, ssrc: 0xBBBB)) == nil)
    #expect(try feed(&p, rtpData(seq: 506, ts: 160, ssrc: 0xBBBB)) != nil)
  }

  @Test("An RTCP SR before any RTP does not lock the RTP SSRC")
  func srBeforeRtpDoesNotLockSSRC() throws {
    var p = try makeParser(ssrc: nil, isTcp: true)
    #expect(
      try p.rtcp(ctx: .dummy, streamId: 0, data: senderReport(ssrc: 0xCCCC, rtpTimestamp: 0)) != nil
    )
    #expect(try feed(&p, rtpData(seq: 1, ts: 0, ssrc: 0xDDDD)) != nil)
    #expect(try feed(&p, rtpData(seq: 2, ts: 160, ssrc: 0xDDDD)) != nil)
    // The SR SSRC check now follows the RTP source.
    #expect(
      try p.rtcp(ctx: .dummy, streamId: 0, data: senderReport(ssrc: 0xCCCC, rtpTimestamp: 0)) == nil
    )
    #expect(
      try p.rtcp(ctx: .dummy, streamId: 0, data: senderReport(ssrc: 0xDDDD, rtpTimestamp: 0)) != nil
    )
  }

  @Test("After adoption, SRs of the new SSRC are kept and placed continuously")
  func srFollowsAdoptedSSRC() throws {
    var p = try makeParser(ssrc: 0xAAAA, isTcp: true)
    let first = try #require(try feed(&p, rtpData(seq: 1, ts: 1_000, ssrc: 0xAAAA)))
    #expect(try feed(&p, rtpData(seq: 50, ts: 2_000_000_000, ssrc: 0xBBBB)) == nil)
    let adopted = try #require(try feed(&p, rtpData(seq: 51, ts: 2_000_000_000, ssrc: 0xBBBB)))
    #expect(adopted.timestamp.timestamp > first.timestamp.timestamp)
    #expect(
      try p.rtcp(ctx: .dummy, streamId: 0, data: senderReport(ssrc: 0xAAAA, rtpTimestamp: 1_000))
        == nil)
    let sr = try #require(
      try p.rtcp(
        ctx: .dummy, streamId: 0, data: senderReport(ssrc: 0xBBBB, rtpTimestamp: 2_000_000_000)))
    #expect(sr.rtpTimestamp?.timestamp == adopted.timestamp.timestamp)
  }

  @Test("abortSession still throws on an SSRC mismatch")
  func abortSessionStillThrows() throws {
    var p = try makeParser(ssrc: 0xAAAA, isTcp: true, policy: .abortSession)
    #expect(throws: RTSPError.self) {
      _ = try feed(&p, rtpData(seq: 1, ts: 0, ssrc: 0xBBBB))
    }
  }
}

// MARK: - Metadata loss at a document boundary (finding 7)

@Suite("Metadata loss at a document boundary")
struct MetadataBoundaryLossTests {
  private func packet(
    seq: UInt16, mark: Bool, loss: UInt16 = 0, _ text: String
  ) -> ReceivedRTPPacket {
    audioPacket(
      seq: seq, ts: Int64(seq) * 9_000, clockRate: 90_000, mark: mark, loss: loss,
      payload: Data(text.utf8))
  }

  private func pullData(_ d: inout ApplicationDepacketizer) -> MetadataFrame? {
    guard case .success(.metadataFrame(let f)) = d.pull() else { return nil }
    return f
  }

  @Test("A tail after a lost first packet is not emitted as a document")
  func headlessTailDropped() throws {
    var d = ApplicationDepacketizer()
    try d.push(packet(seq: 0, mark: true, "<tt:MetaDataStream/>"))
    #expect(pullData(&d) != nil)
    try d.push(packet(seq: 2, mark: true, loss: 1, "ent></tt:Event></tt:MetaDataStream>"))
    #expect(pullData(&d) == nil)
    try d.push(packet(seq: 3, mark: true, "<tt:MetaDataStream/>"))
    let next = pullData(&d)
    #expect(next?.loss == 1)
    #expect(next?.data == Data("<tt:MetaDataStream/>".utf8))
  }

  @Test("A multi-packet tail after a lost first packet is dropped until the marker")
  func headlessMultiPacketTailDropped() throws {
    var d = ApplicationDepacketizer()
    try d.push(packet(seq: 2, mark: false, loss: 1, "<tt:Frame>"))
    try d.push(packet(seq: 3, mark: true, "</tt:Frame></tt:MetaDataStream>"))
    #expect(pullData(&d) == nil)
  }

  @Test(
    "A document start after loss is kept",
    arguments: [
      "<?xml version=\"1.0\"?><tt:MetaDataStream/>",
      "<tt:MetaDataStream/>",
      "\u{FEFF} \n<tt:MetadataStream/>",
      "<MetadataStream xmlns=\"http://www.onvif.org/ver10/schema\"/>",
    ])
  func documentStartAfterLossKept(text: String) throws {
    var d = ApplicationDepacketizer()
    try d.push(packet(seq: 5, mark: true, loss: 4, text))
    let frame = pullData(&d)
    #expect(frame?.loss == 4)
    #expect(frame?.data == Data(text.utf8))
  }

  @Test("A gzip document start after loss is kept")
  func gzipStartAfterLossKept() throws {
    var d = ApplicationDepacketizer()
    let gz = Data([0x1F, 0x8B, 0x08, 0x00, 0x01, 0x02])
    try d.push(audioPacket(seq: 5, ts: 0, clockRate: 90_000, mark: true, loss: 2, payload: gz))
    let frame = pullData(&d)
    #expect(frame?.data == gz)
    #expect(frame?.loss == 2)
  }
}

// MARK: - RTCP compound validation (finding 8)

@Suite("RTCP compound validation")
struct RTCPCompoundTests {
  /// `count` empty receiver reports (4 bytes each) in one compound packet.
  private func compound(_ count: Int) -> Data {
    var d = Data(capacity: count * 4)
    for _ in 0..<count { d.append(contentsOf: [0x80, 0xC9, 0x00, 0x00]) }
    return d
  }

  @Test("parse returns slices of the input, not copies")
  func parseReturnsSlices() throws {
    let buf = compound(3)
    let (pkt, rest) = try RTCPPacketRef.parse(buf)
    #expect(pkt.buf.startIndex == buf.startIndex)
    #expect(rest.startIndex == buf.startIndex + 4)
    let (pkt2, rest2) = try RTCPPacketRef.parse(rest)
    #expect(pkt2.buf.startIndex == buf.startIndex + 4)
    #expect(rest2.count == 4)
  }

  /// 262,144 four-byte packets (1 MiB): copying the remainder at each step
  /// (quadratic) moves ~137 GB and takes seconds; walking slices takes ~0.1 s
  /// in a debug build.
  @Test("Validating a large compound is linear")
  func largeCompoundIsFast() throws {
    let big = compound(262_144)
    let elapsed = try ContinuousClock().measure {
      _ = try ReceivedCompoundPacket.validate(big)
    }
    #expect(elapsed < .seconds(1))
  }

  @Test("validate still rejects padding on a non-final packet and short tails")
  func validateRejectsBadCompounds() throws {
    var padded = compound(2)
    padded[0] = 0xA0
    #expect(throws: RTSPError.self) { _ = try ReceivedCompoundPacket.validate(padded) }
    let short = compound(2) + Data([0x80, 0xC9])
    #expect(throws: RTSPError.self) { _ = try ReceivedCompoundPacket.validate(short) }
    // A slice with a non-zero startIndex validates like a standalone buffer.
    let base = Data([0xFF, 0xFF]) + compound(2)
    let pkt = try ReceivedCompoundPacket.validate(base[2...])
    #expect(pkt.payloadType == 0xC9)
    #expect(pkt.buf.count == 4)
  }
}

// MARK: - G.723 multi-frame packets (finding 9)

@Suite("G.723 multi-frame packets")
struct G723MultiFrameTests {
  private func frame(_ type: UInt8, _ size: Int) -> Data {
    var d = Data(repeating: 0x55 & 0xFC, count: size)
    d[0] = (d[0] & 0xFC) | type
    return d
  }

  private func push(_ payload: Data) throws -> AudioFrame? {
    var d = try G723Depacketizer(clockRate: 8_000)
    try d.push(audioPacket(seq: 0, ts: 0, clockRate: 8_000, mark: false, payload: payload))
    guard case .success(.audioFrame(let f)) = d.pull() else { return nil }
    return f
  }

  @Test(
    "Concatenated frames are accepted with 240 samples per frame",
    arguments: [
      ([0, 0], 480),
      ([1, 1, 1], 720),
      ([0, 2], 480),
      ([1, 0, 2], 720),
      ([0], 240),
      ([2], 240),
    ] as [([UInt8], UInt32)])
  func multiFrameAccepted(types: [UInt8], samples: UInt32) throws {
    let sizes: [UInt8: Int] = [0: 24, 1: 20, 2: 4]
    let payload = types.reduce(into: Data()) { $0 += frame($1, sizes[$1]!) }
    let f = try #require(try push(payload))
    #expect(f.frameLength == samples)
    #expect(f.data == payload)
  }

  @Test(
    "Malformed concatenations are rejected",
    arguments: [
      Data(),
      Data(repeating: 0, count: 23),
      Data(repeating: 0, count: 25),
      Data([0x03]),
      Data(repeating: 0, count: 24) + Data([0x03]),
    ])
  func malformedRejected(payload: Data) throws {
    #expect(throws: DepacketizeError.self) { _ = try push(payload) }
  }
}

// MARK: - InorderParser restart for a seek

@Suite("InorderParser restartSequenceTracking")
struct InorderRestartTests {
  @Test("After a restart the next packet's SSRC is accepted and the timeline continues")
  func restartAcceptsNewSource() throws {
    var p = try makeParser(ssrc: 0xAAAA, isTcp: true)
    #expect(try feed(&p, rtpData(seq: 10, ts: 1_000, ssrc: 0xAAAA)) != nil)
    let last = try #require(try feed(&p, rtpData(seq: 11, ts: 1_160, ssrc: 0xAAAA)))
    p.restartSequenceTracking()
    let first = try #require(try feed(&p, rtpData(seq: 9_000, ts: 4_000_000_000, ssrc: 0xBBBB)))
    #expect(first.loss == 0)
    let oneTick: Int64 = 1
    #expect(first.timestamp.timestamp == last.timestamp.timestamp + oneTick)
    let next = try #require(try feed(&p, rtpData(seq: 9_001, ts: 4_000_000_160, ssrc: 0xBBBB)))
    #expect(next.loss == 0)
    let step: Int64 = 160
    #expect(next.timestamp.timestamp == first.timestamp.timestamp + step)
    // The old source is foreign now.
    #expect(try feed(&p, rtpData(seq: 12, ts: 1_320, ssrc: 0xAAAA)) == nil)
  }

  @Test("A restart with the same SSRC also continues the timeline monotonically")
  func restartSameSSRCContinues() throws {
    var p = try makeParser(ssrc: nil, isTcp: false)
    let last = try #require(try feed(&p, rtpData(seq: 500, ts: 80_000, ssrc: 0xAAAA)))
    p.restartSequenceTracking()
    // The seeked playback's timestamps went backwards.
    let first = try #require(try feed(&p, rtpData(seq: 20, ts: 1_000, ssrc: 0xAAAA)))
    #expect(first.timestamp.timestamp > last.timestamp.timestamp)
  }

  @Test("reseed after a restart seeds sequence and SSRC as before")
  func reseedAfterRestart() throws {
    var p = try makeParser(ssrc: 0xAAAA, isTcp: true)
    let last = try #require(try feed(&p, rtpData(seq: 10, ts: 1_000, ssrc: 0xAAAA)))
    p.restartSequenceTracking()
    p.reseed(nextSeq: 500, ssrc: 0xCCCC)
    let first = try #require(try feed(&p, rtpData(seq: 502, ts: 7_777, ssrc: 0xCCCC)))
    let twoLost: UInt16 = 2
    #expect(first.loss == twoLost)
    #expect(first.timestamp.timestamp == last.timestamp.timestamp + 1)
    // A different SSRC than RTP-Info's still needs two consecutive packets.
    #expect(try feed(&p, rtpData(seq: 503, ts: 7_937, ssrc: 0xDDDD)) == nil)
  }

  @Test("An SR between a restart and the first RTP packet is kept unplaced")
  func srBeforeFirstPacketAfterRestart() throws {
    var p = try makeParser(ssrc: 0xAAAA, isTcp: true)
    #expect(try feed(&p, rtpData(seq: 10, ts: 1_000, ssrc: 0xAAAA)) != nil)
    p.restartSequenceTracking()
    let sr = try #require(
      try p.rtcp(ctx: .dummy, streamId: 0, data: senderReport(ssrc: 0xBBBB, rtpTimestamp: 99)))
    #expect(sr.rtpTimestamp == nil)
  }

  @Test("A restart before any packet keeps the RTP-Info start")
  func restartBeforeFirstPacket() throws {
    var p = InorderParser(
      ssrc: 0xAAAA, nextSeq: nil, isTcp: true,
      timeline: try Timeline(start: 1_000, clockRate: 8_000))
    p.restartSequenceTracking()
    let first = try #require(try feed(&p, rtpData(seq: 1, ts: 1_800, ssrc: 0xBBBB)))
    let elapsed: Int64 = 800
    #expect(first.timestamp.elapsed == elapsed)
  }
}

// MARK: - AudioDepacketizer wrapper

@Suite("AudioDepacketizer wrapper")
struct AudioDepacketizerWrapperTests {
  private func makeAAC() throws -> AudioDepacketizer {
    try AudioDepacketizer.create(
      encodingName: "mpeg4-generic", clockRate: 48_000, channels: nil,
      formatSpecificParams: fmtp1188)
  }

  private func frames(_ d: inout AudioDepacketizer) -> [AudioFrame] {
    var out: [AudioFrame] = []
    while let item = d.pull() {
      if case .success(.audioFrame(let f)) = item { out.append(f) }
    }
    return out
  }

  @Test("The stuck-fragment scenario recovers through the wrapper")
  func stuckFragmentRecovers() throws {
    var d = try makeAAC()
    try d.push(
      audioPacket(
        seq: 0, ts: 0, mark: false,
        payload: aacPayload(auSize: 100, data: Data(repeating: 1, count: 50))))
    #expect(frames(&d).isEmpty)
    var count = 0
    for i in 1...50 {
      let pkt = audioPacket(
        seq: UInt16(i), ts: Int64(i) * 1_024, mark: true,
        payload: aacPayload(auSize: 4, data: Data("abcd".utf8)))
      try? d.push(pkt)
      count += frames(&d).count
    }
    #expect(count == 50)
  }

  @Test("A reset made by a throwing push persists through the wrapper")
  func throwingPushStateIsKept() throws {
    var d = try makeAAC()
    // Malformed (too short) packet after 3 lost packets: dropped, loss kept.
    #expect(throws: DepacketizeError.self) {
      try d.push(audioPacket(seq: 3, ts: 0, mark: true, loss: 3, payload: Data([0x00])))
    }
    try d.push(
      audioPacket(
        seq: 4, ts: 1_024, mark: true, payload: aacPayload(auSize: 4, data: Data("abcd".utf8))))
    #expect(frames(&d).first?.loss == 4)

    // A bad continuation resets the fragment before throwing; the next
    // continuation-shaped packet is then a quietly dropped tail, not an error.
    try d.push(
      audioPacket(
        seq: 5, ts: 2_048, mark: false, payload: aacPayload(auSize: 9, data: Data("abc".utf8))))
    #expect(frames(&d).isEmpty)
    #expect(throws: DepacketizeError.self) {
      try d.push(
        audioPacket(
          seq: 6, ts: 2_048, mark: false, payload: aacPayload(auSize: 8, data: Data("def".utf8))))
    }
    try d.push(
      audioPacket(
        seq: 7, ts: 2_048, mark: true, payload: aacPayload(auSize: 9, data: Data("ghi".utf8))))
    var failures = 0
    while let item = d.pull() {
      if case .failure = item { failures += 1 }
    }
    #expect(failures == 0)
  }

  @Test("A frame pending before a throwing push is still returned by pull")
  func pendingFrameSurvivesThrow() throws {
    var d = try makeAAC()
    try d.push(
      audioPacket(
        seq: 0, ts: 0, mark: true, payload: aacAggregate([Data("ab".utf8), Data("cd".utf8)])))
    guard case .success(.audioFrame(let first)) = d.pull() else {
      Issue.record("expected the first AU")
      return
    }
    #expect(first.data == Data("ab".utf8))
    #expect(throws: DepacketizeError.self) {
      try d.push(audioPacket(seq: 1, ts: 2_048, mark: true, payload: Data([0x00])))
    }
    guard case .success(.audioFrame(let second)) = d.pull() else {
      Issue.record("expected the pending second AU")
      return
    }
    #expect(second.data == Data("cd".utf8))
  }
}

// MARK: - Metadata encodings

@Suite("Metadata document start by encoding")
struct MetadataEncodingStartTests {
  static let cases: [(String, [UInt8], Bool)] = [
    ("vnd.onvif.metadata", Array("<tt:MetadataStream>".utf8), true),
    ("vnd.onvif.metadata", Array("<tt:Frame>".utf8), false),
    ("vnd.onvif.metadata", Array("</tt:MetadataStream>".utf8), false),
    ("vnd.onvif.metadata", [0x1F, 0x8B, 0x08], false),
    ("vnd.onvif.metadata.gzip", [0x1F, 0x8B, 0x08, 0x00], true),
    ("vnd.onvif.metadata.gzip", [0x12, 0x8B, 0x08, 0x00], false),
    ("vnd.onvif.metadata.exi.onvif", Array("$EXI".utf8), true),
    ("vnd.onvif.metadata.exi.ext", [0x80, 0x01], true),
    ("vnd.onvif.metadata.exi.onvif", [0x40, 0x01], false),
    ("", [0x80, 0x01], false),
    ("", Array("$EXI".utf8), true),
  ]

  @Test("Document starts are recognized per encoding", arguments: cases)
  func startsDocument(encoding: String, payload: [UInt8], expected: Bool) {
    let enc = ApplicationDepacketizer.Encoding(encodingName: encoding)
    #expect(ApplicationDepacketizer.startsDocument(Data(payload), encoding: enc) == expected)
  }

  @Test("An EXI document after loss is kept when the encoding is known")
  func exiAfterLossKept() throws {
    var d = ApplicationDepacketizer(encodingName: "vnd.onvif.metadata.exi.onvif")
    let exi = Data([0x80, 0x40, 0x22])
    try d.push(audioPacket(seq: 1, ts: 0, clockRate: 90_000, mark: true, loss: 1, payload: exi))
    guard case .success(.metadataFrame(let f)) = d.pull() else {
      Issue.record("expected a frame")
      return
    }
    #expect(f.data == exi)
  }

  @Test("A loss while dropping until a marker resumes at a new document start")
  func docStartEndsDrop() throws {
    var d = ApplicationDepacketizer(encodingName: "vnd.onvif.metadata")
    let doc = "<tt:MetadataStream/>"
    try d.push(
      audioPacket(
        seq: 0, ts: 0, clockRate: 90_000, mark: false, loss: 1, payload: Data("tail".utf8)))
    try d.push(
      audioPacket(
        seq: 2, ts: 9_000, clockRate: 90_000, mark: true, loss: 1, payload: Data(doc.utf8)))
    guard case .success(.metadataFrame(let f)) = d.pull() else {
      Issue.record("expected a frame")
      return
    }
    #expect(f.data == Data(doc.utf8))
    #expect(f.loss == 2)
  }
}

// MARK: - AudioSpecificConfig edge cases

@Suite("AudioSpecificConfig SBR edge cases")
struct AudioSpecificConfigSBRTests {
  @Test("Explicit SBR with an escaped 24-bit extension frequency")
  func escapedExtensionFrequency() throws {
    // AOT 5, core idx 6 (24 kHz), stereo, ext idx 0xF + 48000, core AOT 2.
    var bits = "00101_0110_0010_1111"
    bits += String(48_000, radix: 2).leftPadded(to: 24)
    bits += "00010_000"
    let asc = try AudioSpecificConfig.parse(bitsToData(bits))
    let rate: UInt32 = 48_000
    #expect(asc.parameters.clockRate == rate)
    let core: UInt32 = 24_000
    #expect(asc.coreSamplingFrequency == core)
  }

  @Test("Downsampled SBR keeps the core frame length")
  func downsampledSBR() throws {
    // AOT 5, core 48 kHz, ext 48 kHz, core AOT 2.
    let asc = try AudioSpecificConfig.parse(bitsToData("00101_0011_0010_0011_00010_000"))
    let length: UInt32 = 1_024
    #expect(asc.parameters.frameLength == length)
  }

  /// Fields: AOT, core frequency index, channels, extension index, core AOT,
  /// GASpecificConfig flags.
  static let rejectedConfigs: [String] = [
    // core AOT 5 nested inside AOT 5
    "00101_0110_0010_0011_00101_000",
    // core AOT 8 (CELP)
    "00101_0110_0010_0011_01000_000",
    // extension 44.1 kHz over a 24 kHz core
    "00101_0110_0010_0100_00010_000",
    // truncated before the core object type
    "00101_0110_0010_0011",
  ]

  @Test("Unsupported SBR configurations are rejected", arguments: rejectedConfigs)
  func rejected(bits: String) {
    #expect(throws: DepacketizeError.self) {
      _ = try AudioSpecificConfig.parse(bitsToData(bits))
    }
  }
}

/// Packs a string of `0`/`1` (underscores ignored) into bytes, zero-padded.
private func bitsToData(_ bits: String) -> Data {
  var padded = bits.filter { $0 != "_" }
  while padded.count % 8 != 0 { padded += "0" }
  var out = Data()
  var i = padded.startIndex
  while i < padded.endIndex {
    let next = padded.index(i, offsetBy: 8)
    out.append(UInt8(padded[i..<next], radix: 2)!)
    i = next
  }
  return out
}

extension String {
  fileprivate func leftPadded(to width: Int) -> String {
    String(repeating: "0", count: max(0, width - count)) + self
  }
}

@Suite("RTP clock restart")
struct RTPClockRestartTests {
  @Test("A large backward RTP timestamp jump continues the timeline instead of stalling")
  func backwardJumpContinues() throws {
    var p = try makeParser(ssrc: 0xAAAA, isTcp: true)
    var last: ReceivedRTPPacket?
    for i in 0..<3 {
      last = try feed(&p, rtpData(seq: UInt16(10 + i), ts: UInt32(800_000 + 160 * i), ssrc: 0xAAAA))
    }
    let lastTs = try #require(last).timestamp.timestamp
    // Same SSRC and sequence, but the RTP clock restarted far behind the
    // start of the stream (100 s at 8 kHz).
    let restarted = try #require(try feed(&p, rtpData(seq: 13, ts: 1_000, ssrc: 0xAAAA)))
    #expect(restarted.loss >= 1)
    #expect(restarted.timestamp.timestamp > lastTs)
    let next = try #require(try feed(&p, rtpData(seq: 14, ts: 1_160, ssrc: 0xAAAA)))
    #expect(next.loss == 0)
    let step: Int64 = 160
    #expect(next.timestamp.timestamp - restarted.timestamp.timestamp == step)
  }

  @Test("Small backward steps (B-frame order) are kept as they are")
  func smallBackwardStepKept() throws {
    var p = try makeParser(ssrc: 0xAAAA, isTcp: true)
    let first = try #require(try feed(&p, rtpData(seq: 1, ts: 90_000, ssrc: 0xAAAA)))
    _ = try #require(try feed(&p, rtpData(seq: 2, ts: 90_000 + 4 * 160, ssrc: 0xAAAA)))
    let back = try #require(try feed(&p, rtpData(seq: 3, ts: 90_000 + 160, ssrc: 0xAAAA)))
    #expect(back.loss == 0)
    let expected: Int64 = 160
    #expect(back.timestamp.timestamp - first.timestamp.timestamp == expected)
  }
}

@Suite("Seek RTP-Info")
struct SeekRTPInfoTests {
  @Test("More than 100 packets of the new playback before the response keep their tracking")
  func manyPacketsBeforeResponse() throws {
    var p = try makeParser(ssrc: 0xAAAA, isTcp: false)
    _ = try feed(&p, rtpData(seq: 1, ts: 0, ssrc: 0xAAAA))
    p.restartSequenceTracking()
    for i in 0..<150 {
      _ = try feed(&p, rtpData(seq: UInt16(1000 + i), ts: UInt32(160 * i), ssrc: 0xAAAA))
    }
    let applied = p.applySeekRTPInfo(seq: 1000, rtptime: 0, ssrc: nil, elapsedSeconds: 10)
    #expect(!applied)
    let next = try #require(try feed(&p, rtpData(seq: 1150, ts: 160 * 150, ssrc: 0xAAAA)))
    #expect(next.loss == 0)
  }

  @Test("Packets of the previous playback before the response don't stop the reseed")
  func stalePacketsBeforeResponse() throws {
    var p = try makeParser(ssrc: 0xAAAA, isTcp: true)
    _ = try feed(&p, rtpData(seq: 500, ts: 0, ssrc: 0xAAAA))
    p.restartSequenceTracking()
    _ = try feed(&p, rtpData(seq: 501, ts: 160, ssrc: 0xAAAA))
    let applied = p.applySeekRTPInfo(seq: 1000, rtptime: 80_000, ssrc: nil, elapsedSeconds: 3)
    #expect(applied)
    let first = try #require(try feed(&p, rtpData(seq: 1000, ts: 80_000, ssrc: 0xAAAA)))
    #expect(first.loss == 0)
    // rtptime maps to the requested time: 3 s at 8 kHz after the start.
    #expect(first.timestamp.elapsed == 24_000)
  }

  @Test("Previous-playback packets, then new ones, before the response: tracking stays")
  func staleThenNewPacketsBeforeResponse() throws {
    var p = try makeParser(ssrc: 0xAAAA, isTcp: false)
    for i in 0..<10 {
      _ = try feed(&p, rtpData(seq: UInt16(100 + i), ts: UInt32(160 * i), ssrc: 0xAAAA))
    }
    p.restartSequenceTracking()
    for i in 10..<13 {
      _ = try feed(&p, rtpData(seq: UInt16(100 + i), ts: UInt32(160 * i), ssrc: 0xAAAA))
    }
    let base: UInt32 = 5_000_000
    for i in 0..<3 {
      _ = try feed(&p, rtpData(seq: UInt16(20000 + i), ts: base + UInt32(160 * i), ssrc: 0xAAAA))
    }
    let before = try #require(p.nextElapsedSeconds)
    let applied = p.applySeekRTPInfo(
      seq: 20000, rtptime: base, ssrc: nil, elapsedSeconds: p.nextElapsedSeconds)
    #expect(!applied)
    let next = try #require(try feed(&p, rtpData(seq: 20003, ts: base + 480, ssrc: 0xAAAA)))
    #expect(next.loss == 0)
    // One 20 ms packet after the previous one.
    #expect(abs(next.timestamp.elapsedSeconds - before) < 0.0001)
  }

  @Test("A forward sequence jump of exactly 0x8000 is loss, not a restart, in the statistics")
  func statisticsJumpBoundary() throws {
    var stats = ReceptionStats()
    stats.recordPacket(ssrc: 1, sequence: 100, rtpTimestamp: 0, arrivalTicks: 0)
    stats.recordPacket(ssrc: 1, sequence: 100 &+ 0x8000, rtpTimestamp: 160, arrivalTicks: 160)
    let report = stats.reportBlock(now: .now)
    let block = try #require(report)
    // Cumulative lost (24 bits at offset 5): the 0x7FFF packets in between.
    let lost = UInt32(block[5]) << 16 | UInt32(block[6]) << 8 | UInt32(block[7])
    #expect(lost == 0x7FFF)
  }
}

// MARK: - Metadata loss inside a document

@Suite("Metadata loss inside a document")
struct MetadataMidDocumentLossTests {
  /// Encoding name, then the first and second packet of a two-packet document.
  static let documents: [(String, Data, Data)] = [
    (
      "", Data("<?xml version=\"1.0\"?><tt:MetadataStream>".utf8), Data("</tt:MetadataStream>".utf8)
    ),
    ("vnd.onvif.metadata", Data("<tt:MetadataStream>".utf8), Data("</tt:MetadataStream>".utf8)),
    ("vnd.onvif.metadata.gzip", Data([0x1F, 0x8B, 0x08, 0x00]), Data([0x01, 0x02])),
    // `$EXI`, then an EXI header without options.
    ("vnd.onvif.metadata.exi.onvif", Data([0x24, 0x45, 0x58, 0x49, 0x80]), Data([0x40, 0x22])),
  ]

  private func packet(
    seq: UInt16, mark: Bool, loss: UInt16 = 0, _ payload: Data
  )
    -> ReceivedRTPPacket
  {
    audioPacket(
      seq: seq, ts: Int64(seq / 2) * 9_000, clockRate: 90_000, mark: mark, loss: loss,
      payload: payload)
  }

  private func pullData(_ d: inout ApplicationDepacketizer) -> MetadataFrame? {
    guard case .success(.metadataFrame(let f)) = d.pull() else { return nil }
    return f
  }

  @Test(
    "A document start after a lost packet mid-document is kept", arguments: documents)
  func documentStartAfterMidDocumentLossKept(
    encoding: String, first: Data, second: Data
  )
    throws
  {
    var d = ApplicationDepacketizer(encodingName: encoding)
    // Document A: A1 arrives, A2 (with the marker) is lost.
    try d.push(packet(seq: 0, mark: false, first))
    #expect(pullData(&d) == nil)
    // Document B: B1 reports the lost packet and starts a document.
    try d.push(packet(seq: 2, mark: false, loss: 1, first))
    #expect(pullData(&d) == nil)
    try d.push(packet(seq: 3, mark: true, second))
    let frame = pullData(&d)
    let expected: Data = first + second
    #expect(frame?.data == expected)
    #expect(frame?.loss == 1)
  }

  @Test("A single-packet document after a lost packet mid-document is kept")
  func singlePacketDocumentAfterMidDocumentLossKept() throws {
    var d = ApplicationDepacketizer(encodingName: "vnd.onvif.metadata")
    let doc = Data("<tt:MetadataStream/>".utf8)
    try d.push(packet(seq: 0, mark: false, Data("<tt:MetadataStream>".utf8)))
    try d.push(packet(seq: 2, mark: true, loss: 1, doc))
    let frame = pullData(&d)
    #expect(frame?.data == doc)
    #expect(frame?.loss == 1)
  }

  @Test("After a lost packet mid-document, EXI distinguishing bits alone don't start a document")
  func exiBitsAfterMidDocumentLossDropped() throws {
    var d = ApplicationDepacketizer(encodingName: "vnd.onvif.metadata.exi.onvif")
    try d.push(packet(seq: 0, mark: false, Data([0x80, 0x40])))
    // 0x80 could be an EXI header or the rest of the abandoned document.
    try d.push(packet(seq: 2, mark: false, loss: 1, Data([0x80, 0x41])))
    try d.push(packet(seq: 3, mark: true, Data([0x22])))
    #expect(pullData(&d) == nil)
    let doc = Data([0x80, 0x40, 0x22])
    try d.push(packet(seq: 4, mark: true, doc))
    let frame = pullData(&d)
    #expect(frame?.data == doc)
    #expect(frame?.loss == 1)
  }
}

// MARK: - Rejected simple audio and G.723 packets keep loss

@Suite("Rejected simple audio and G.723 packets keep loss")
struct RejectedAudioPacketLossTests {
  /// Encoding name, then a payload the depacketizer rejects and one it accepts.
  static let cases: [(String, Data, Data)] = [
    ("pcmu", Data(), Data(repeating: 0xFF, count: 160)),
    ("l16", Data([0x00]), Data(repeating: 0x00, count: 320)),
    ("g723", Data(repeating: 0x00, count: 23), Data(repeating: 0x00, count: 24)),
  ]

  private func frames(_ d: inout AudioDepacketizer) -> [AudioFrame] {
    var out: [AudioFrame] = []
    while let item = d.pull() {
      if case .success(.audioFrame(let f)) = item { out.append(f) }
    }
    return out
  }

  @Test(
    "The next frame counts rejected packets and the loss they reported", arguments: cases)
  func rejectedPacketLossCarried(encoding: String, bad: Data, good: Data) throws {
    var d = try AudioDepacketizer.create(
      encodingName: encoding, clockRate: 8_000, channels: nil, formatSpecificParams: nil)
    #expect(throws: DepacketizeError.self) {
      try d.push(audioPacket(seq: 2, ts: 0, clockRate: 8_000, mark: false, loss: 2, payload: bad))
    }
    #expect(frames(&d).isEmpty)
    #expect(throws: DepacketizeError.self) {
      try d.push(audioPacket(seq: 3, ts: 240, clockRate: 8_000, mark: false, payload: bad))
    }
    try d.push(audioPacket(seq: 5, ts: 480, clockRate: 8_000, mark: false, loss: 1, payload: good))
    // 2 lost, the first rejected packet, the second one, 1 lost.
    let expected: UInt16 = 5
    #expect(frames(&d).first?.loss == expected)
    try d.push(audioPacket(seq: 6, ts: 720, clockRate: 8_000, mark: false, payload: good))
    let none: UInt16 = 0
    #expect(frames(&d).first?.loss == none)
  }
}
