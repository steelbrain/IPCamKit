// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/codec/g723.rs
// G.723.1 audio as specified in RFC 3551 section 4.5.3.

import Foundation

/// G.723.1 depacketizer.
///
/// Fixed clock rate of 8000 Hz and frame length of 240 samples.
/// Validates packet size (24, 20, or 4 bytes) and that the header bits match.
struct G723Depacketizer: Sendable {
  private static let fixedClockRate: UInt32 = 8_000
  private static let fixedFrameLength: UInt32 = 240

  private var pending: AudioFrame?
  let parameters: AudioParameters

  init(clockRate: UInt32) throws {
    guard clockRate == Self.fixedClockRate else {
      throw DepacketizeError(
        "Expected clock rate of \(Self.fixedClockRate) for G.723, got \(clockRate)")
    }
    self.pending = nil
    self.parameters = AudioParameters(
      rfc6381Codec: nil,
      frameLength: Self.fixedFrameLength,
      clockRate: Self.fixedClockRate,
      extraData: Data(),
      codec: .other
    )
  }

  /// Validates that a G.723.1 packet has a valid size and header bits.
  private static func validate(_ payload: Data) -> Bool {
    let expectedHdrBits: UInt8
    switch payload.count {
    case 24: expectedHdrBits = 0b00
    case 20: expectedHdrBits = 0b01
    case 4: expectedHdrBits = 0b10
    default: return false
    }
    return (payload[payload.startIndex] & 0b11) == expectedHdrBits
  }

  mutating func push(_ pkt: ReceivedRTPPacket) throws {
    precondition(pending == nil)
    let payload = pkt.payload
    guard Self.validate(payload) else {
      throw DepacketizeError(
        "Invalid G.723 packet: \(limitedHex(payload, maxBytes: 64))")
    }
    pending = AudioFrame(
      ctx: pkt.ctx,
      streamId: pkt.streamId,
      timestamp: pkt.timestamp,
      frameLength: Self.fixedFrameLength,
      loss: pkt.loss,
      data: payload
    )
  }

  mutating func pull() -> Result<CodecItem, DepacketizeError>? {
    guard let frame = pending else { return nil }
    pending = nil
    return .success(.audioFrame(frame))
  }
}

/// Format a Data as a hex string, limited to maxBytes.
func limitedHex(_ data: Data, maxBytes: Int) -> String {
  let slice = data.prefix(maxBytes)
  let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
  if data.count > maxBytes {
    return "[\(hex)...] (\(data.count) bytes)"
  }
  return "[\(hex)]"
}
