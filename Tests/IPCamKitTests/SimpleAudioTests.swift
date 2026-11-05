// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Ports simple_audio tests from upstream src/codec/simple_audio.rs

import Foundation
import Testing

@testable import IPCamKit

@Suite("Simple Audio Depacketizer Tests")
struct SimpleAudioTests {

  /// 384 bytes of 8-bit samples = 384 samples (G.711 PCMA/PCMU).
  @Test("Frame length valid 8-bit")
  func frameLengthValid8Bit() {
    let d = SimpleAudioDepacketizer(clockRate: 8000, bitsPerSample: 8)
    #expect(d.frameLength(payloadLen: 384) == 384)
  }

  /// 0 bytes should return nil (zero samples).
  @Test("Frame length invalid 8-bit")
  func frameLengthInvalid8Bit() {
    let d = SimpleAudioDepacketizer(clockRate: 8000, bitsPerSample: 8)
    #expect(d.frameLength(payloadLen: 0) == nil)
  }

  /// 320 bytes = 160 16-bit samples.
  @Test("Frame length valid 16-bit")
  func frameLengthValid16Bit() {
    let d = SimpleAudioDepacketizer(clockRate: 16000, bitsPerSample: 16)
    #expect(d.frameLength(payloadLen: 320) == 160)
  }

  /// 321 bytes is not divisible by 2 bytes per sample.
  @Test("Frame length invalid 16-bit")
  func frameLengthInvalid16Bit() {
    let d = SimpleAudioDepacketizer(clockRate: 16000, bitsPerSample: 16)
    #expect(d.frameLength(payloadLen: 321) == nil)
  }

  /// A DVI4 packet's 4-byte header holds no samples: 84 bytes are 160 samples
  /// (20 ms at 8 kHz), so after a new source the stream continues at the
  /// frame's end, not 8 ticks later.
  @Test("DVI4 frame length leaves out the header")
  func dvi4FrameLength() throws {
    let depacketizer = try AudioDepacketizer.create(
      encodingName: "dvi4", clockRate: 8000, channels: nil, formatSpecificParams: nil)
    guard case .simpleAudio(let d) = depacketizer else {
      Issue.record("DVI4 isn't a simple audio depacketizer")
      return
    }
    #expect(d.frameLength(payloadLen: 84) == 160)
    #expect(d.frameLength(payloadLen: 4) == nil)
    #expect(d.frameLength(payloadLen: 3) == nil)
  }

  /// An oversized payload length must return nil rather than trap the process
  /// (was a precondition on attacker-controlled length — finding #19).
  @Test("Oversized payload length returns nil instead of trapping")
  func frameLengthOversized() {
    let d = SimpleAudioDepacketizer(clockRate: 8000, bitsPerSample: 8)
    #expect(d.frameLength(payloadLen: Int(UInt16.max)) == nil)
    #expect(d.frameLength(payloadLen: 70_000) == nil)
  }
}
