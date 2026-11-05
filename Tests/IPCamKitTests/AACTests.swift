// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Ports AAC tests from upstream src/codec/aac.rs

import Foundation
import Testing

@testable import IPCamKit

// MARK: - Test Helpers

private let aacFmtp =
  "streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config=1188"

private let aacTs = Timestamp(
  timestamp: 42, clockRate: 48_000, start: 0)!

private func makeAACPacket(
  seq: UInt16, mark: Bool, loss: UInt16 = 0, payload: Data
) -> ReceivedRTPPacket {
  let builder = ReceivedPacketBuilder(
    ctx: .dummy, streamId: 0, sequenceNumber: seq,
    timestamp: aacTs, payloadType: 0, ssrc: 0, mark: mark, loss: loss)
  return try! builder.build(payload: payload).get()
}

/// Base address of the buffer holding the fragment being assembled, found
/// through `Mirror` because the depacketizer state is private (`path` leads
/// from `value` to that state). nil when no fragment is in progress. The
/// reflected copy is released on return, so it doesn't make the next push
/// copy the buffer.
private func fragmentBufferAddress(_ value: Any, path: [String]) -> UInt? {
  var node = value
  for label in path + ["fragmented", "buf"] {
    guard let child = Mirror(reflecting: node).children.first(where: { $0.label == label })
    else { return nil }
    node = child.value
  }
  guard let buf = node as? Data else { return nil }
  return buf.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
}

@Suite("AAC Tests")
struct AACTests {

  @Test("Parse AudioSpecificConfig")
  func parseAudioSpecificConfig() throws {
    // Dahua: 48000 Hz, mono
    let dahua = try AudioSpecificConfig.parse(Data([0x11, 0x88]))
    #expect(dahua.parameters.clockRate == 48_000)
    #expect(dahua.channels.name == "mono")
    #expect(dahua.parameters.rfc6381Codec == "mp4a.40.2")

    // Bunny (Wowza): 12000 Hz, stereo
    let bunny = try AudioSpecificConfig.parse(Data([0x14, 0x90]))
    #expect(bunny.parameters.clockRate == 12_000)
    #expect(bunny.channels.name == "stereo")
    #expect(bunny.parameters.rfc6381Codec == "mp4a.40.2")

    // RFC 3640 example: 48000 Hz, 5.1
    let rfc3640 = try AudioSpecificConfig.parse(Data([0x11, 0xB0]))
    #expect(rfc3640.parameters.clockRate == 48_000)
    #expect(rfc3640.channels.name == "5.1")
    #expect(rfc3640.parameters.rfc6381Codec == "mp4a.40.2")
  }

  @Test("Blanks around = in the AAC fmtp are tolerated")
  func fmtpBlanksAroundEquals() throws {
    let d = try AACDepacketizer(
      clockRate: 48_000, channels: 1,
      formatSpecificParams:
        "streamtype=5; mode = AAC-hbr; SizeLength = 13; IndexLength =3; indexdeltalength= 3; "
        + "config = 1188")
    #expect(d.parameters.clockRate == 48_000)
  }

  @Test("AAC trusts the ASC over an rtpmap channel mismatch (#5)")
  func aacChannelMismatchTrustsASC() throws {
    // config=1188 is mono; an rtpmap claiming stereo must NOT reject the stream.
    let d = try AACDepacketizer(clockRate: 48_000, channels: 2, formatSpecificParams: aacFmtp)
    #expect(d.parameters.clockRate == 48_000)
  }

  @Test("AAC accepts an RTP clock that is a small multiple of the ASC rate (#6)")
  func aacClockRateMultiple() throws {
    // config=1308 encodes AOT2 / 24000 Hz / mono; HE-AAC commonly doubles the
    // RTP clock, so 48000 (= 2x) must be accepted.
    let heFmtp =
      "streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;"
      + "indexlength=3;indexdeltalength=3;config=1308"
    _ = try AACDepacketizer(clockRate: 48_000, channels: nil, formatSpecificParams: heFmtp)
    // A genuinely unrelated rate (44100 vs 24000) is still rejected.
    #expect(throws: DepacketizeError.self) {
      _ = try AACDepacketizer(clockRate: 44_100, channels: nil, formatSpecificParams: heFmtp)
    }
  }

  @Test("AAC rejects an AU-headers-length that isn't a multiple of 16 (#17)")
  func aacAuHeadersLengthMultipleOf16() throws {
    var d = try AACDepacketizer(clockRate: 48_000, channels: nil, formatSpecificParams: aacFmtp)
    // 24 bits is divisible by 8 but not 16: the old guard accepted it and
    // truncated to one header (misparse); the tightened guard rejects it.
    let payload = Data([0x00, 0x18]) + Data(repeating: 0, count: 10)
    #expect(throws: DepacketizeError.self) {
      try d.push(makeAACPacket(seq: 0, mark: true, payload: payload))
    }
  }

  // MARK: - Depacketizer Tests

  @Test("Depacketize happy path: single, aggregate, fragment")
  func depacketizeHappyPath() throws {
    var d = try AACDepacketizer(
      clockRate: 48_000, channels: nil, formatSpecificParams: aacFmtp)

    // --- Single frame ---
    try d.push(
      makeAACPacket(
        seq: 0, mark: true,
        payload: Data([
          0x00, 0x10,  // AU-headers-length: 16 bits => 1 header
          0x00, 0x20,  // AU-header: AU-size=4 + AU-index=0
        ]) + Data("asdf".utf8)))
    if case .success(.audioFrame(let a)) = d.pull() {
      #expect(a.timestamp == aacTs)
      #expect(a.data == Data("asdf".utf8))
    } else {
      Issue.record("Expected audioFrame")
    }
    #expect(d.pull() == nil)

    // --- Aggregate of 3 frames ---
    try d.push(
      makeAACPacket(
        seq: 1, mark: true,
        payload: Data([
          0x00, 0x30,  // AU-headers-length: 48 bits => 3 headers
          0x00, 0x18,  // AU-header: AU-size=3 + AU-index=0
          0x00, 0x18,  // AU-header: AU-size=3 + AU-index-delta=0
          0x00, 0x18,  // AU-header: AU-size=3 + AU-index-delta=0
        ]) + Data("foobarbaz".utf8)))

    // Frame 1: timestamp = base
    if case .success(.audioFrame(let a)) = d.pull() {
      #expect(a.timestamp == aacTs)
      #expect(a.data == Data("foo".utf8))
    } else {
      Issue.record("Expected audioFrame 1")
    }
    // Frame 2: timestamp = base + 1024
    if case .success(.audioFrame(let a)) = d.pull() {
      #expect(a.timestamp == aacTs.adding(1_024))
      #expect(a.data == Data("bar".utf8))
    } else {
      Issue.record("Expected audioFrame 2")
    }
    // Frame 3: timestamp = base + 2048
    if case .success(.audioFrame(let a)) = d.pull() {
      #expect(a.timestamp == aacTs.adding(2_048))
      #expect(a.data == Data("baz".utf8))
    } else {
      Issue.record("Expected audioFrame 3")
    }
    #expect(d.pull() == nil)

    // --- Fragment across 3 packets ---
    let fragHeader = Data([
      0x00, 0x10,  // AU-headers-length: 16 bits => 1 header
      0x00, 0x48,  // AU-header: AU-size=9 + AU-index=0
    ])
    // Fragment 1/3
    try d.push(
      makeAACPacket(
        seq: 2, mark: false,
        payload: fragHeader + Data("foo".utf8)))
    #expect(d.pull() == nil)
    // Fragment 2/3
    try d.push(
      makeAACPacket(
        seq: 3, mark: false,
        payload: fragHeader + Data("bar".utf8)))
    #expect(d.pull() == nil)
    // Fragment 3/3
    try d.push(
      makeAACPacket(
        seq: 4, mark: true,
        payload: fragHeader + Data("baz".utf8)))
    if case .success(.audioFrame(let a)) = d.pull() {
      #expect(a.timestamp == aacTs)
      #expect(a.data == Data("foobarbaz".utf8))
    } else {
      Issue.record("Expected audioFrame from fragment")
    }
    #expect(d.pull() == nil)
  }

  @Test("Depacketize fragment initial loss")
  func depacketizeFragmentInitialLoss() throws {
    var d = try AACDepacketizer(
      clockRate: 48_000, channels: nil, formatSpecificParams: aacFmtp)

    let fragHeader = Data([
      0x00, 0x10,
      0x00, 0x48,  // AU-size=9
    ])

    // Fragment packet with loss=1 (initial packet was lost)
    try d.push(
      makeAACPacket(
        seq: 1, mark: false, loss: 1,
        payload: fragHeader + Data("bar".utf8)))
    #expect(d.pull() == nil)

    // Final fragment packet (marked)
    try d.push(
      makeAACPacket(
        seq: 2, mark: true,
        payload: fragHeader + Data("baz".utf8)))
    // Fragment is discarded due to loss_since_mark
    #expect(d.pull() == nil)

    // Following frame reports the loss
    let singleHeader = Data([
      0x00, 0x10,
      0x00, 0x20,  // AU-size=4
    ])
    try d.push(
      makeAACPacket(
        seq: 3, mark: true,
        payload: singleHeader + Data("asdf".utf8)))
    if case .success(.audioFrame(let a)) = d.pull() {
      #expect(a.loss == 1)
      #expect(a.data == Data("asdf".utf8))
    } else {
      Issue.record("Expected audioFrame with loss")
    }
    #expect(d.pull() == nil)
  }

  @Test("Depacketize fragment interior loss")
  func depacketizeFragmentInteriorLoss() throws {
    var d = try AACDepacketizer(
      clockRate: 48_000, channels: nil, formatSpecificParams: aacFmtp)

    let fragHeader = Data([
      0x00, 0x10,
      0x00, 0x48,  // AU-size=9
    ])

    // Fragment 1/3
    try d.push(
      makeAACPacket(
        seq: 0, mark: false,
        payload: fragHeader + Data("foo".utf8)))
    #expect(d.pull() == nil)

    // Fragment 2/3 is lost; fragment 3/3 reports loss=1
    try d.push(
      makeAACPacket(
        seq: 2, mark: true, loss: 1,
        payload: fragHeader + Data("baz".utf8)))
    // Fragment discarded due to loss during fragmentation
    #expect(d.pull() == nil)

    // Following frame reports the loss
    let singleHeader = Data([
      0x00, 0x10,
      0x00, 0x20,  // AU-size=4
    ])
    try d.push(
      makeAACPacket(
        seq: 3, mark: true,
        payload: singleHeader + Data("asdf".utf8)))
    if case .success(.audioFrame(let a)) = d.pull() {
      #expect(a.loss == 1)
      #expect(a.data == Data("asdf".utf8))
    } else {
      Issue.record("Expected audioFrame with loss")
    }
    #expect(d.pull() == nil)
  }

  @Test("Depacketize fragment final loss")
  func depacketizeFragmentFinalLoss() throws {
    var d = try AACDepacketizer(
      clockRate: 48_000, channels: nil, formatSpecificParams: aacFmtp)

    let fragHeader = Data([
      0x00, 0x10,
      0x00, 0x48,  // AU-size=9
    ])

    // Fragment 1/3
    try d.push(
      makeAACPacket(
        seq: 0, mark: false,
        payload: fragHeader + Data("foo".utf8)))
    #expect(d.pull() == nil)

    // Fragment 2/3 is lost; fragment 3/3 reports loss=1
    try d.push(
      makeAACPacket(
        seq: 2, mark: true, loss: 1,
        payload: fragHeader + Data("baz".utf8)))
    #expect(d.pull() == nil)

    // Following frame reports the loss
    let singleHeader = Data([
      0x00, 0x10,
      0x00, 0x20,  // AU-size=4
    ])
    try d.push(
      makeAACPacket(
        seq: 3, mark: true,
        payload: singleHeader + Data("asdf".utf8)))
    if case .success(.audioFrame(let a)) = d.pull() {
      #expect(a.loss == 1)
      #expect(a.data == Data("asdf".utf8))
    } else {
      Issue.record("Expected audioFrame with loss")
    }
    #expect(d.pull() == nil)
  }

  @Test("Depacketize fragment old loss doesn't prevent error")
  func depacketizeFragmentOldLossDoesntPreventError() throws {
    var d = try AACDepacketizer(
      clockRate: 48_000, channels: nil, formatSpecificParams: aacFmtp)

    let fragHeader = Data([
      0x00, 0x10,
      0x00, 0x48,  // AU-size=9
    ])

    // End of previous fragment with loss=1 (first parts missing)
    try d.push(
      makeAACPacket(
        seq: 0, mark: true, loss: 1,
        payload: fragHeader + Data("bar".utf8)))
    // This should be silently discarded (loss_since_mark on first
    // pull from aggregate detects it's a short fragment)
    #expect(d.pull() == nil)

    // Incomplete fragment with no reported loss — should error
    try d.push(
      makeAACPacket(
        seq: 1, mark: true,
        payload: fragHeader + Data("bar".utf8)))
    if case .failure(let e) = d.pull() {
      #expect(
        e.description.contains(
          "mark can't be set on beginning of fragment"))
    } else {
      Issue.record("Expected error about mark on fragment start")
    }
  }

  /// Each continuation packet of a fragmented AU must append to one buffer:
  /// `state` kept a second reference to it, so every packet copied the whole
  /// AU so far (an 8000-byte AU in 100-byte pieces moved 78 times).
  @Test(
    "Fragmented AU is assembled in one buffer, not copied per packet",
    .timeLimit(.minutes(1)))
  func fragmentAppendsInPlace() throws {
    let size = 8000
    let au = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
    let auHeader = UInt16(size) << 3  // AU-size=8000 + AU-index=0
    let header = Data([0x00, 0x10, UInt8(auHeader >> 8), UInt8(auHeader & 0xFF)])
    let pieces = stride(from: 0, to: size, by: 100).map { au[$0..<min($0 + 100, size)] }

    func run(
      push: (ReceivedRTPPacket) throws -> Void,
      pull: () -> Result<CodecItem, DepacketizeError>?,
      address: () -> UInt?
    ) throws {
      var addresses: [UInt] = []
      for (i, piece) in pieces.enumerated() {
        let last = i == pieces.count - 1
        try push(
          makeAACPacket(seq: UInt16(truncatingIfNeeded: i), mark: last, payload: header + piece))
        if !last {
          #expect(pull() == nil)
          addresses.append(try #require(address()))
        }
      }
      let moves = zip(addresses, addresses.dropFirst()).filter { $0 != $1 }.count
      #expect(moves == 0, "buffer moved \(moves) times over \(pieces.count) packets")
      guard case .success(.audioFrame(let frame)) = pull() else {
        Issue.record("Expected audioFrame from fragment")
        return
      }
      #expect(frame.data == au)
      // The last piece is appended in place too.
      #expect(frame.data.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) } == addresses.last)
      #expect(pull() == nil)
    }

    // Directly, and through the wrapper the session uses.
    var d = try AACDepacketizer(
      clockRate: 48_000, channels: nil, formatSpecificParams: aacFmtp)
    try run(
      push: { try d.push($0) }, pull: { d.pull() },
      address: { fragmentBufferAddress(d, path: ["state"]) })
    var w = try AudioDepacketizer.create(
      encodingName: "mpeg4-generic", clockRate: 48_000, channels: nil,
      formatSpecificParams: aacFmtp)
    try run(
      push: { try w.push($0) }, pull: { w.pull() },
      address: { fragmentBufferAddress(w, path: ["aac", "state"]) })
  }
}
