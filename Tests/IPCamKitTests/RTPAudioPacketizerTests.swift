// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Tests for the RTP audio packetizer, including round-trips through the library's depacketizers.

import Foundation
import Testing

@testable import IPCamKit

// MARK: - Helpers

/// AAC-hbr fmtp as cameras announce it: 48 kHz mono AAC-LC (config=1188).
private let aacFmtp =
  "streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;"
  + "indexdeltalength=3;config=1188"

private func makePacketizer(
  _ encodingName: String, clockRate: UInt32 = 8000, channels: UInt16? = nil,
  payloadType: UInt8 = 0, fmtp: String? = nil, ssrc: UInt32 = 0x1234_5678,
  sequenceNumber: UInt16 = 100, timestamp: UInt32 = 5000, maxPayloadBytes: Int = 1400
) throws -> RTPAudioPacketizer {
  try RTPAudioPacketizer(
    encodingName: encodingName, clockRate: clockRate, channels: channels,
    payloadType: payloadType, formatSpecificParams: fmtp, ssrc: ssrc,
    sequenceNumber: sequenceNumber, timestamp: timestamp, maxPayloadBytes: maxPayloadBytes)
}

private func parse(_ packet: Data) throws -> RawRTPPacket {
  try RawRTPPacket.parse(packet).get()
}

/// Deterministic, non-repeating test bytes.
private func testBytes(_ count: Int, seed: UInt8 = 0) -> Data {
  Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed) &+ ($0 >> 8)) })
}

/// Feeds packets through the library's receive path (InorderParser, then the audio
/// depacketizer for the encoding) and returns the frames it produces. Fails the test on
/// any detected packet loss, i.e. a sequence-number gap.
private func depacketize(
  _ packets: [Data], encodingName: String, clockRate: UInt32, channels: UInt16? = nil,
  fmtp: String? = nil
) throws -> [AudioFrame] {
  let timeline = try Timeline(start: nil, clockRate: clockRate, enforceMaxJumpSecs: 10)
  var parser = InorderParser(ssrc: nil, nextSeq: nil, isTcp: true, timeline: timeline)
  var depacketizer = try AudioDepacketizer.create(
    encodingName: encodingName, clockRate: clockRate, channels: channels,
    formatSpecificParams: fmtp)
  var frames: [AudioFrame] = []
  for packet in packets {
    let parsed = try parser.rtp(data: packet, ctx: .dummy, streamId: 0, streamCtx: .dummy)
    let received = try #require(parsed)
    #expect(received.loss == 0, "sequence gap before \(received.sequenceNumber)")
    try depacketizer.push(received)
    while let item = depacketizer.pull() {
      guard case .success(.audioFrame(let frame)) = item else {
        Issue.record("unexpected depacketizer output \(item)")
        continue
      }
      frames.append(frame)
    }
  }
  return frames
}

private func rtpTimestamp(_ frame: AudioFrame) -> UInt32 {
  UInt32(truncatingIfNeeded: frame.timestamp.timestamp)
}

/// One sample-based encoding scenario: chunk size, packet limit and the expected split.
struct SampledCase: Sendable, CustomStringConvertible {
  var name: String
  var clockRate: UInt32
  var channels: UInt16?
  var chunkBytes: Int
  var maxPayloadBytes: Int
  var packetBytes: [Int]
  var packetTicks: [UInt32]
  var description: String { "\(name)/\(channels ?? 1)ch" }
}

private let sampledCases: [SampledCase] = [
  SampledCase(
    name: "pcmu", clockRate: 8000, channels: nil, chunkBytes: 400, maxPayloadBytes: 160,
    packetBytes: [160, 160, 80], packetTicks: [160, 160, 80]),
  SampledCase(
    name: "pcma", clockRate: 8000, channels: 1, chunkBytes: 1000, maxPayloadBytes: 400,
    packetBytes: [400, 400, 200], packetTicks: [400, 400, 200]),
  // G.722: 16 kHz audio, 8000 Hz RTP clock, one byte per tick.
  SampledCase(
    name: "g722", clockRate: 8000, channels: nil, chunkBytes: 321, maxPayloadBytes: 160,
    packetBytes: [160, 160, 1], packetTicks: [160, 160, 1]),
  SampledCase(
    name: "l16", clockRate: 44100, channels: 1, chunkBytes: 882, maxPayloadBytes: 301,
    packetBytes: [300, 300, 282], packetTicks: [150, 150, 141]),
  SampledCase(
    name: "l16", clockRate: 16000, channels: 2, chunkBytes: 1000, maxPayloadBytes: 302,
    packetBytes: [300, 300, 300, 100], packetTicks: [75, 75, 75, 25]),
  // G.726-16: 4 samples per byte.
  SampledCase(
    name: "g726-16", clockRate: 8000, channels: nil, chunkBytes: 100, maxPayloadBytes: 30,
    packetBytes: [30, 30, 30, 10], packetTicks: [120, 120, 120, 40]),
  // G.726-24: 8 samples per 3 bytes.
  SampledCase(
    name: "g726-24", clockRate: 8000, channels: nil, chunkBytes: 99, maxPayloadBytes: 40,
    packetBytes: [39, 39, 21], packetTicks: [104, 104, 56]),
  // G.726-32: 2 samples per byte.
  SampledCase(
    name: "g726-32", clockRate: 8000, channels: nil, chunkBytes: 50, maxPayloadBytes: 20,
    packetBytes: [20, 20, 10], packetTicks: [40, 40, 20]),
  // G.726-40: 8 samples per 5 bytes.
  SampledCase(
    name: "g726-40", clockRate: 8000, channels: nil, chunkBytes: 55, maxPayloadBytes: 12,
    packetBytes: [10, 10, 10, 10, 10, 5], packetTicks: [16, 16, 16, 16, 16, 8]),
]

/// An AAC fmtp and RTP clock rate, and the RTP ticks each AU should advance the timestamp.
struct AACDurationCase: Sendable, CustomStringConvertible {
  var name: String
  var clockRate: UInt32
  var fmtp: String
  var ticksPerAU: UInt32
  var description: String { name }
}

/// AAC-hbr fmtp as cameras announce it, with the given AudioSpecificConfig.
private func aacFmtp(config: String) -> String {
  "streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;"
    + "indexdeltalength=3;config=\(config)"
}

/// Configs the depacketizer accepts, so the expected ticks are its own count.
private let aacConfigDurationCases: [AACDurationCase] = [
  // HE-AAC, explicit SBR: 24 kHz core, 48 kHz extension, on a 48 kHz clock.
  AACDurationCase(
    name: "HE-AAC explicit SBR", clockRate: 48_000, fmtp: aacFmtp(config: "2b098800"),
    ticksPerAU: 2048),
  // AAC-LC with a 24 kHz core on a 48 kHz clock (implicit SBR).
  AACDurationCase(
    name: "HE-AAC implicit SBR", clockRate: 48_000, fmtp: aacFmtp(config: "1308"),
    ticksPerAU: 2048),
  // AAC-LC, 48 kHz, frameLengthFlag 1.
  AACDurationCase(
    name: "960-sample AAC-LC", clockRate: 48_000, fmtp: aacFmtp(config: "118c"),
    ticksPerAU: 960),
  AACDurationCase(
    name: "AAC-LC", clockRate: 48_000, fmtp: aacFmtp(config: "1188"), ticksPerAU: 1024),
]

private let aacOtherDurationCases: [AACDurationCase] = [
  AACDurationCase(
    name: "constantduration over HE-AAC config", clockRate: 48_000,
    fmtp: aacFmtp(config: "2b098800") + ";constantDuration=1024", ticksPerAU: 1024),
  AACDurationCase(
    name: "constantduration over 960-sample config", clockRate: 48_000,
    fmtp: "constantduration=1024;" + aacFmtp(config: "118c"), ticksPerAU: 1024),
  AACDurationCase(name: "no config", clockRate: 48_000, fmtp: "mode=AAC-hbr", ticksPerAU: 1024),
  AACDurationCase(
    name: "config not hex", clockRate: 48_000, fmtp: aacFmtp(config: "zz"), ticksPerAU: 1024),
  // 8 kHz is not a whole multiple of the 48 kHz core rate.
  AACDurationCase(
    name: "clock rate not a multiple of the core rate", clockRate: 8000,
    fmtp: aacFmtp(config: "118c"), ticksPerAU: 1024),
]

@Suite("RTP Audio Packetizer Tests")
struct RTPAudioPacketizerTests {

  // MARK: Configuration

  @Test("Supported encodings")
  func supportedEncodings() {
    for name in [
      "pcmu", "pcma", "g722", "l16", "g726-16", "g726-24", "g726-32", "g726-40",
      "mpeg4-generic", "PCMU", "MPEG4-GENERIC",
    ] {
      #expect(RTPAudioPacketizer.isSupported(encodingName: name), "\(name)")
    }
    for name in ["dvi4", "g723", "u8", "opus", "h264", ""] {
      #expect(!RTPAudioPacketizer.isSupported(encodingName: name), "\(name)")
      #expect(throws: RTPPacketizeError.self) { try makePacketizer(name) }
    }
  }

  @Test("Invalid parameters throw")
  func invalidParameters() throws {
    #expect(throws: RTPPacketizeError.self) { try makePacketizer("pcmu", payloadType: 128) }
    _ = try makePacketizer("pcmu", payloadType: 127)
    #expect(throws: RTPPacketizeError.self) { try makePacketizer("pcmu", clockRate: 0) }
    #expect(throws: RTPPacketizeError.self) { try makePacketizer("l16", channels: 0) }
    for size in [0, -1, RTPAudioPacketizer.maxPayloadLimit + 1] {
      #expect(throws: RTPPacketizeError.self) { try makePacketizer("pcmu", maxPayloadBytes: size) }
    }
    _ = try makePacketizer("pcmu", maxPayloadBytes: RTPAudioPacketizer.maxPayloadLimit)
    #expect(RTPAudioPacketizer.maxPayloadLimit == 65523)
    // One stereo L16 tick is 4 bytes; one G.726-40 block is 5 bytes; AAC-hbr needs 4 + 1.
    #expect(throws: RTPPacketizeError.self) {
      try makePacketizer("l16", channels: 2, maxPayloadBytes: 3)
    }
    _ = try makePacketizer("l16", channels: 2, maxPayloadBytes: 4)
    #expect(throws: RTPPacketizeError.self) { try makePacketizer("g726-40", maxPayloadBytes: 4) }
    _ = try makePacketizer("g726-40", maxPayloadBytes: 5)
    #expect(throws: RTPPacketizeError.self) {
      try makePacketizer("mpeg4-generic", fmtp: aacFmtp, maxPayloadBytes: 4)
    }
    _ = try makePacketizer("mpeg4-generic", fmtp: aacFmtp, maxPayloadBytes: 5)
  }

  // MARK: RTP header

  @Test("Header fields, marker on first packet only, sequence and timestamp advance")
  func headerFields() throws {
    var p = try makePacketizer(
      "pcmu", payloadType: 0, ssrc: 0xDEAD_BEEF, sequenceNumber: 7, timestamp: 1000)
    let first = try p.packetize(testBytes(160))
    let second = try p.packetize(testBytes(80, seed: 1))
    #expect(first.count == 1 && second.count == 1)

    let a = first[0]
    #expect(a.count == 12 + 160)
    #expect(a[0] == 0x80)  // V=2, no padding, no extension, no CSRCs
    #expect(a[1] == 0x80)  // marker + PT 0
    #expect([UInt8](a[2..<12]) == [0x00, 0x07, 0x00, 0x00, 0x03, 0xE8, 0xDE, 0xAD, 0xBE, 0xEF])
    #expect(a[12...] == testBytes(160))

    let raw = try parse(second[0])
    #expect(!raw.mark)
    #expect(raw.payloadType == 0)
    #expect(raw.sequenceNumber == 8)
    #expect(raw.rtpTimestamp == 1160)
    #expect(raw.ssrc == 0xDEAD_BEEF)
    #expect(raw.payload == testBytes(80, seed: 1))
    #expect(p.nextSequenceNumber == 9)
    #expect(p.nextTimestamp == 1240)
  }

  @Test("Sequence number wraps")
  func sequenceWrap() throws {
    var p = try makePacketizer("pcma", payloadType: 8, sequenceNumber: 0xFFFE, maxPayloadBytes: 10)
    let packets = try p.packetize(testBytes(40))
    #expect(try packets.map { try parse($0).sequenceNumber } == [0xFFFE, 0xFFFF, 0, 1])
    #expect(p.nextSequenceNumber == 2)
    // The receive path sees no gap across the wrap.
    let frames = try depacketize(packets, encodingName: "pcma", clockRate: 8000)
    #expect(frames.count == 4)
  }

  @Test("Timestamp wraps")
  func timestampWrap() throws {
    var p = try makePacketizer("pcmu", timestamp: 0xFFFF_FF00, maxPayloadBytes: 160)
    var packets: [Data] = []
    for i in 0..<4 { packets += try p.packetize(testBytes(160, seed: UInt8(i))) }
    #expect(
      try packets.map { try parse($0).rtpTimestamp }
        == [0xFFFF_FF00, 0xFFFF_FFA0, 0x40, 0xE0])
    #expect(p.nextTimestamp == 0x180)
    // The library's timeline extends the wrapped timestamps monotonically.
    let frames = try depacketize(packets, encodingName: "pcmu", clockRate: 8000)
    #expect(frames.map(\.timestamp.elapsed) == [0, 160, 320, 480])
  }

  @Test("startTalkspurt marks the next packet and skips the silent ticks")
  func talkspurt() throws {
    var p = try makePacketizer("pcmu", timestamp: 1000)
    let first = try p.packetize(testBytes(160)).map(parse)
    let second = try p.packetize(testBytes(160)).map(parse)
    p.startTalkspurt(skippingTicks: 4000)
    let third = try p.packetize(testBytes(320), samples: nil).map(parse)
    let fourth = try p.packetize(testBytes(160)).map(parse)
    #expect(first.map(\.mark) == [true])
    #expect(second.map(\.mark) == [false])
    #expect(third.map(\.mark) == [true])
    #expect(fourth.map(\.mark) == [false])
    let resumed: UInt32 = 1000 + 320 + 4000
    #expect(third.first?.rtpTimestamp == resumed)
    #expect(fourth.first?.rtpTimestamp == resumed + 320)
    #expect(fourth.first?.sequenceNumber == 103, "sequence numbers stay contiguous")
  }

  @Test("Failed packetize leaves state unchanged and the marker pending")
  func failureKeepsState() throws {
    var p = try makePacketizer("l16", channels: 2, sequenceNumber: 9, timestamp: 77)
    #expect(throws: RTPPacketizeError.self) { try p.packetize(Data()) }
    #expect(throws: RTPPacketizeError.self) { try p.packetize(testBytes(6)) }
    #expect(p.nextSequenceNumber == 9)
    #expect(p.nextTimestamp == 77)
    let packets = try p.packetize(testBytes(8))
    let raw = try parse(try #require(packets.first))
    #expect(raw.mark)
    #expect(raw.sequenceNumber == 9)
    #expect(raw.rtpTimestamp == 77)
  }

  // MARK: Sample-based encodings

  @Test("Sample-based encodings split on sample boundaries and round-trip", arguments: sampledCases)
  func sampledRoundTrip(_ c: SampledCase) throws {
    let base: UInt32 = 90_000
    var p = try makePacketizer(
      c.name, clockRate: c.clockRate, channels: c.channels, payloadType: 96,
      sequenceNumber: 40, timestamp: base, maxPayloadBytes: c.maxPayloadBytes)
    let chunk = testBytes(c.chunkBytes)
    // A second, identical-size chunk checks the marker stays off and timing continues.
    let packets = try p.packetize(chunk) + p.packetize(chunk)
    let expectedBytes = c.packetBytes + c.packetBytes
    let expectedTicks = c.packetTicks + c.packetTicks
    #expect(packets.map { $0.count - 12 } == expectedBytes)

    var expectedTimestamps: [UInt32] = []
    var ts = base
    for ticks in expectedTicks {
      expectedTimestamps.append(ts)
      ts &+= ticks
    }
    let raws = try packets.map(parse)
    #expect(raws.map(\.rtpTimestamp) == expectedTimestamps)
    #expect(raws.map(\.mark) == [true] + Array(repeating: false, count: packets.count - 1))
    #expect(raws.map(\.sequenceNumber) == (0..<packets.count).map { UInt16(40 + $0) })
    #expect(p.nextTimestamp == ts)
    #expect(p.nextSequenceNumber == UInt16(40 + packets.count))

    let frames = try depacketize(
      packets, encodingName: c.name, clockRate: c.clockRate, channels: c.channels)
    #expect(frames.count == packets.count)
    #expect(Data(frames.flatMap(\.data)) == chunk + chunk)
    #expect(frames.map(rtpTimestamp) == expectedTimestamps)
    if (c.channels ?? 1) == 1 {
      // The depacketizer derives each frame's length from its size; mono only, since it
      // counts samples rather than ticks.
      #expect(frames.map(\.frameLength) == expectedTicks)
    }
  }

  @Test("Payload that is not a whole number of samples throws")
  func partialSamples() throws {
    for (name, channels, bytes) in [
      ("l16", UInt16(1), 3), ("l16", 2, 6), ("g726-24", 1, 4), ("g726-24", 1, 1),
      ("g726-40", 1, 6), ("pcmu", 2, 3),
    ] {
      var p = try makePacketizer(name, channels: channels)
      #expect(throws: RTPPacketizeError.self, "\(name) \(channels)ch \(bytes)B") {
        try p.packetize(testBytes(bytes))
      }
    }
    for name in ["pcmu", "mpeg4-generic"] {
      var p = try makePacketizer(name, fmtp: aacFmtp)
      #expect(throws: RTPPacketizeError.self) { try p.packetize(Data()) }
    }
  }

  @Test("Explicit duration overrides the derived one, spread over split packets")
  func samplesOverride() throws {
    var p = try makePacketizer("pcmu", timestamp: 0, maxPayloadBytes: 160)
    let packets = try p.packetize(testBytes(400), samples: 1000)
    #expect(try packets.map { try parse($0).rtpTimestamp } == [0, 400, 800])
    #expect(p.nextTimestamp == 1000)
    _ = try p.packetize(testBytes(160), samples: 0)
    #expect(p.nextTimestamp == 1000)
  }

  @Test("Payload slices with a nonzero startIndex")
  func sliceInput() throws {
    var p = try makePacketizer("pcma", maxPayloadBytes: 100)
    let backing = testBytes(260)
    let slice = backing[10..<250]
    let packets = try p.packetize(slice)
    #expect(
      try packets.map { try parse($0).payload } == [
        backing[10..<110], backing[110..<210], backing[210..<250],
      ])

    var aac = try makePacketizer("mpeg4-generic", fmtp: aacFmtp, maxPayloadBytes: 104)
    let fragments = try aac.packetize(slice)
    #expect(
      try fragments.map { Data(try parse($0).payload.dropFirst(4)) } == [
        backing[10..<110], backing[110..<210], backing[210..<250],
      ])
  }

  // MARK: AAC (RFC 3640)

  @Test("AAC: one AU per packet with AU-headers-length and AU-header")
  func aacSinglePacket() throws {
    var p = try makePacketizer(
      "mpeg4-generic", clockRate: 48_000, payloadType: 97, fmtp: aacFmtp, timestamp: 3000)
    let au = testBytes(300)
    let packets = try p.packetize(au)
    #expect(packets.count == 1)
    let raw = try parse(packets[0])
    #expect(raw.mark)
    #expect(raw.payloadType == 97)
    #expect(raw.rtpTimestamp == 3000)
    // AU-headers-length 16 bits; AU-header = 300 << 3 | index 0 = 0x0960.
    #expect([UInt8](raw.payload.prefix(4)) == [0x00, 0x10, 0x09, 0x60])
    #expect(raw.payload.dropFirst(4) == au)
    #expect(p.nextTimestamp == 3000 + 1024)
  }

  @Test("AAC: oversized AU is fragmented per RFC 3640 3.2.3")
  func aacFragmentation() throws {
    var p = try makePacketizer(
      "mpeg4-generic", clockRate: 48_000, payloadType: 97, fmtp: aacFmtp,
      sequenceNumber: 0xFFFF, timestamp: 0xFFFF_FE00, maxPayloadBytes: 300)
    let au = testBytes(1000)
    let packets = try p.packetize(au)
    let raws = try packets.map(parse)
    #expect(packets.map(\.count) == [312, 312, 312, 128])  // 4 + 296 per full fragment
    #expect(raws.map(\.mark) == [false, false, false, true])
    #expect(raws.map(\.sequenceNumber) == [0xFFFF, 0, 1, 2])
    #expect(raws.allSatisfy { $0.rtpTimestamp == 0xFFFF_FE00 })
    for raw in raws {
      // Each fragment repeats the AU-header with the full AU size (1000 << 3 = 0x1F40).
      #expect([UInt8](raw.payload.prefix(4)) == [0x00, 0x10, 0x1F, 0x40])
    }
    #expect(Data(raws.flatMap { $0.payload.dropFirst(4) }) == au)
    #expect(p.nextTimestamp == 0x200)  // wrapped
  }

  @Test("AAC round-trips through AACDepacketizer, with and without fragmentation")
  func aacRoundTrip() throws {
    var p = try makePacketizer(
      "mpeg4-generic", clockRate: 48_000, payloadType: 97, fmtp: aacFmtp, timestamp: 1_000,
      maxPayloadBytes: 256)
    let aus = [
      testBytes(200, seed: 1), testBytes(700, seed: 2), testBytes(252, seed: 3),
      testBytes(253, seed: 4), testBytes(1, seed: 5), testBytes(8191, seed: 6),
    ]
    var packets: [Data] = []
    for au in aus { packets += try p.packetize(au) }
    // 252 bytes fill one packet exactly; 253 need a second fragment.
    #expect(packets.count == 1 + 3 + 1 + 2 + 1 + 33)

    let frames = try depacketize(
      packets, encodingName: "mpeg4-generic", clockRate: 48_000, fmtp: aacFmtp)
    #expect(frames.map(\.data) == aus)
    let expectedTimestamps: [UInt32] = (0..<aus.count).map { 1_000 + UInt32($0) * 1024 }
    #expect(frames.map(rtpTimestamp) == expectedTimestamps)
    #expect(frames.allSatisfy { $0.loss == 0 && $0.frameLength == 1024 })
  }

  @Test("AAC durations: default, constantduration, explicit samples")
  func aacDurations() throws {
    var p = try makePacketizer("mpeg4-generic", clockRate: 48_000, fmtp: aacFmtp, timestamp: 0)
    _ = try p.packetize(testBytes(10))
    #expect(p.nextTimestamp == 1024)
    _ = try p.packetize(testBytes(10), samples: 2048)
    #expect(p.nextTimestamp == 3072)

    var constant = try makePacketizer(
      "mpeg4-generic", clockRate: 48_000, fmtp: aacFmtp + ";constantDuration=960",
      timestamp: 0)
    _ = try constant.packetize(testBytes(10))
    #expect(constant.nextTimestamp == 960)
  }

  @Test(
    "AAC default duration is the one config implies, as AACDepacketizer counts it",
    arguments: aacConfigDurationCases)
  func aacDurationFromConfig(_ c: AACDurationCase) throws {
    let receiver = try AACDepacketizer(
      clockRate: c.clockRate, channels: nil, formatSpecificParams: c.fmtp)
    #expect(receiver.parameters.frameLength == c.ticksPerAU)

    var p = try makePacketizer(
      "mpeg4-generic", clockRate: c.clockRate, payloadType: 97, fmtp: c.fmtp,
      timestamp: 1_000, maxPayloadBytes: 256)
    let aus = [testBytes(200, seed: 1), testBytes(700, seed: 2), testBytes(300, seed: 3)]
    var packets: [Data] = []
    for au in aus { packets += try p.packetize(au) }
    #expect(p.nextTimestamp == 1_000 + 3 * c.ticksPerAU)

    let frames = try depacketize(
      packets, encodingName: "mpeg4-generic", clockRate: c.clockRate, fmtp: c.fmtp)
    #expect(frames.map(\.data) == aus)
    #expect(frames.allSatisfy { $0.loss == 0 && $0.frameLength == c.ticksPerAU })
    let expectedTimestamps = (0..<UInt32(aus.count)).map { 1_000 + $0 * c.ticksPerAU }
    #expect(frames.map(rtpTimestamp) == expectedTimestamps)
  }

  @Test(
    "AAC default duration: constantduration wins, 1024 without a usable config",
    arguments: aacOtherDurationCases)
  func aacDurationOverridesAndFallback(_ c: AACDurationCase) throws {
    var p = try makePacketizer(
      "mpeg4-generic", clockRate: c.clockRate, fmtp: c.fmtp, timestamp: 0)
    _ = try p.packetize(testBytes(10))
    _ = try p.packetize(testBytes(10))
    #expect(p.nextTimestamp == 2 * c.ticksPerAU)
  }

  @Test("AAC fmtp parsing: case-insensitive keys, defaults, other layouts")
  func aacFormatParameters() throws {
    // Typical camera spelling, mixed case and spaces, trailing ';'.
    let cameraFmtp =
      "streamtype=5; profile-level-id=15; Mode=AAC-hbr; config=1408; SizeLength=13; "
      + "IndexLength=3; IndexDeltaLength=3; Profile=1;"
    for fmtp in [cameraFmtp, "mode=aac-hbr", nil] {
      var p = try makePacketizer("mpeg4-generic", fmtp: fmtp)
      let packets = try p.packetize(testBytes(4))
      let raw = try parse(try #require(packets.first))
      #expect([UInt8](raw.payload.prefix(4)) == [0x00, 0x10, 0x00, 0x20], "\(fmtp ?? "nil")")
    }

    // AAC-lbr style: 6-bit size + 2-bit index = one byte, AU at most 63 bytes.
    var lbr = try makePacketizer(
      "mpeg4-generic", fmtp: "mode=AAC-lbr;sizelength=6;indexlength=2;indexdeltalength=2")
    let lbrPackets = try lbr.packetize(testBytes(63))
    let lbrRaw = try parse(try #require(lbrPackets.first))
    #expect([UInt8](lbrRaw.payload.prefix(3)) == [0x00, 0x08, 63 << 2])
    #expect(lbrRaw.payload.count == 3 + 63)
    #expect(throws: RTPPacketizeError.self) { try lbr.packetize(testBytes(64)) }

    // 13-bit header without an index: AU-headers-length 13, header padded to 2 bytes.
    var unpadded = try makePacketizer(
      "mpeg4-generic", fmtp: "mode=generic;sizelength=13", maxPayloadBytes: 1400)
    let unpaddedPackets = try unpadded.packetize(testBytes(5))
    let unpaddedRaw = try parse(try #require(unpaddedPackets.first))
    #expect([UInt8](unpaddedRaw.payload.prefix(4)) == [0x00, 0x0D, 0x00, 0x28])

    // 32-bit size + 32-bit index: eight header bytes.
    var wide = try makePacketizer(
      "mpeg4-generic", fmtp: "mode=generic;sizelength=32;indexlength=32",
      maxPayloadBytes: 20)
    let widePackets = try wide.packetize(testBytes(30))
    let wideRaw = try parse(try #require(widePackets.first))
    #expect([UInt8](wideRaw.payload.prefix(10)) == [0x00, 0x40, 0, 0, 0, 30, 0, 0, 0, 0])
    #expect(wideRaw.payload.count == 20)
  }

  @Test("AAC: bad or unsupported fmtp throws")
  func aacBadFormatParameters() throws {
    for fmtp in [
      "mode=AAC-hbr;sizelength=abc", "mode=AAC-hbr;sizelength=0", "mode=AAC-hbr;sizelength=33",
      "mode=AAC-hbr;indexlength=-1", "mode=AAC-hbr;indexdeltalength=x", "mode",
      "mode=AAC-hbr;garbage", "mode=AAC-lbr", "mode=AAC-hbr;constantduration=0",
      "mode=AAC-hbr;constantduration=x", "mode=AAC-hbr;ctsdeltalength=8",
      "mode=AAC-hbr;dtsdeltalength=8", "mode=AAC-hbr;randomaccessindication=1",
      "mode=AAC-hbr;streamstateindication=4", "mode=AAC-hbr;auxiliarydatasizelength=16",
    ] {
      #expect(throws: RTPPacketizeError.self, "\(fmtp)") {
        try makePacketizer("mpeg4-generic", fmtp: fmtp)
      }
    }
    // Zero-length optional fields are the same as absent.
    _ = try makePacketizer(
      "mpeg4-generic", fmtp: aacFmtp + ";ctsdeltalength=0;randomaccessindication=0")
    // AU-size of 13 bits caps an AU at 8191 bytes.
    var p = try makePacketizer("mpeg4-generic", fmtp: aacFmtp)
    #expect(throws: RTPPacketizeError.self) { try p.packetize(testBytes(8192)) }
    #expect(p.nextSequenceNumber == 100)
  }
}
