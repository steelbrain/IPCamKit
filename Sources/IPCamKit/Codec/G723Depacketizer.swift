// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/codec/g723.rs
// G.723.1 audio as specified in RFC 3551 section 4.5.3.

import Foundation

/// G.723.1 depacketizer.
///
/// Fixed clock rate of 8000 Hz. A packet carries one or more G.723.1 frames
/// back to back (RFC 3551 section 4.5.3); the low two bits of each frame's
/// first octet give its size: 0 = 24 octets (6.3 kb/s), 1 = 20 octets
/// (5.3 kb/s), 2 = 4 octets (SID), 3 = reserved (rejected). Each frame,
/// speech or SID, covers 30 ms = 240 samples, so a packet's audio frame has
/// `frameLength` 240 times its frame count, and the whole payload as `data`.
/// A packet that isn't a concatenation of valid frames is dropped (`push`
/// throws) and counts as one lost packet, together with the loss it reported,
/// on the next frame.
struct G723Depacketizer: Sendable {
  private static let fixedClockRate: UInt32 = 8_000
  private static let samplesPerFrame: UInt32 = 240

  private var pending: AudioFrame?
  /// Packets lost or dropped since the last frame, added to the next frame's
  /// `loss`.
  private var pendingLoss: UInt16 = 0
  let parameters: AudioParameters

  init(clockRate: UInt32) throws {
    guard clockRate == Self.fixedClockRate else {
      throw DepacketizeError(
        "Expected clock rate of \(Self.fixedClockRate) for G.723, got \(clockRate)")
    }
    self.pending = nil
    self.parameters = AudioParameters(
      rfc6381Codec: nil,
      frameLength: nil,  // variable: 240 per G.723.1 frame in the packet
      clockRate: Self.fixedClockRate,
      extraData: Data(),
      codec: .other
    )
  }

  /// The number of G.723.1 frames in `payload`, or nil unless it is an exact
  /// concatenation of valid frames (at least one).
  static func frameCount(_ payload: Data) -> Int? {
    var offset = payload.startIndex
    var count = 0
    while offset < payload.endIndex {
      let size: Int
      switch payload[offset] & 0b11 {
      case 0b00: size = 24
      case 0b01: size = 20
      case 0b10: size = 4
      default: return nil
      }
      guard payload.endIndex - offset >= size else { return nil }
      offset += size
      count += 1
    }
    return count > 0 ? count : nil
  }

  mutating func push(_ pkt: ReceivedRTPPacket) throws {
    precondition(pending == nil)
    let payload = pkt.payload
    guard let frames = Self.frameCount(payload) else {
      pendingLoss = UInt16(clamping: UInt32(pendingLoss) + UInt32(pkt.loss) + 1)
      throw DepacketizeError(
        "Invalid G.723 packet: \(limitedHex(payload, maxBytes: 64))")
    }
    pending = AudioFrame(
      ctx: pkt.ctx,
      streamId: pkt.streamId,
      timestamp: pkt.timestamp,
      // A payload is at most 64 KiB, so at most 16384 frames: no overflow.
      frameLength: UInt32(frames) * Self.samplesPerFrame,
      loss: UInt16(clamping: UInt32(pendingLoss) + UInt32(pkt.loss)),
      // Normalize to a standalone Data (startIndex 0) for the public frame.
      data: Data(payload)
    )
    pendingLoss = 0
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
