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
}
