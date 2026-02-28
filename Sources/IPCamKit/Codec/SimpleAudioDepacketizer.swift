// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/codec/simple_audio.rs
// Fixed-size audio sample codecs as defined in RFC 3551 section 4.5.

import Foundation

/// Depacketizer for fixed-size audio sample codecs (PCMU, PCMA, L16, G.722, G.726, DVI4).
///
/// These codecs are trivial pass-throughs: each RTP packet contains a complete
/// audio frame. The frame length in samples is computed from the payload size
/// and the bits-per-sample of the codec.
struct SimpleAudioDepacketizer: Sendable {
  var parameters: AudioParameters
  private var pending: AudioFrame?
  private let bitsPerSample: UInt32

  init(clockRate: UInt32, bitsPerSample: UInt32) {
    self.parameters = AudioParameters(
      rfc6381Codec: nil,
      frameLength: nil,  // variable
      clockRate: clockRate,
      extraData: Data(),
      codec: .other
    )
    self.bitsPerSample = bitsPerSample
    self.pending = nil
  }

  /// Computes the frame length in samples from the payload byte count.
  ///
  /// Returns nil if the payload size is not evenly divisible by bitsPerSample,
  /// or if the result would be zero.
  /// Precondition: payloadLen < UInt16.max (matching upstream assert!).
  func frameLength(payloadLen: Int) -> UInt32? {
    precondition(payloadLen < Int(UInt16.max))
    let bits = UInt32(payloadLen) * 8
    guard bits % bitsPerSample == 0 else { return nil }
    let result = bits / bitsPerSample
    return result > 0 ? result : nil
  }

  mutating func push(_ pkt: ReceivedRTPPacket) throws {
    precondition(pending == nil)
    let payload = pkt.payload
    guard let fl = frameLength(payloadLen: payload.count) else {
      throw DepacketizeError(
        "invalid length \(payload.count) for payload of \(bitsPerSample)-bit audio samples")
    }
    pending = AudioFrame(
      ctx: pkt.ctx,
      streamId: pkt.streamId,
      timestamp: pkt.timestamp,
      frameLength: fl,
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
