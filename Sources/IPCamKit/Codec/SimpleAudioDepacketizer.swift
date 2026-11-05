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
///
/// A packet whose length isn't a whole number of samples is dropped (`push`
/// throws) and counts as one lost packet, together with the loss it reported,
/// on the next frame.
struct SimpleAudioDepacketizer: Sendable {
  var parameters: AudioParameters
  private var pending: AudioFrame?
  /// Packets lost or dropped since the last frame, added to the next frame's
  /// `loss`.
  private var pendingLoss: UInt16 = 0
  private let bitsPerSample: UInt32
  /// Bytes at the start of each payload that aren't samples (DVI4's header).
  private let headerBytes: Int

  init(clockRate: UInt32, bitsPerSample: UInt32, headerBytes: Int = 0) {
    self.parameters = AudioParameters(
      rfc6381Codec: nil,
      frameLength: nil,  // variable
      clockRate: clockRate,
      extraData: Data(),
      codec: .other
    )
    self.bitsPerSample = bitsPerSample
    self.headerBytes = headerBytes
    self.pending = nil
  }

  /// Computes the frame length in samples from the payload byte count, less
  /// `headerBytes`.
  ///
  /// Returns nil if the payload size is not evenly divisible by bitsPerSample,
  /// if the result would be zero, or if the payload is too large to be a valid
  /// RTP payload (>= UInt16.max). A malformed/oversized length degrades to a
  /// thrown DepacketizeError via push() rather than trapping the process.
  func frameLength(payloadLen: Int) -> UInt32? {
    guard payloadLen < Int(UInt16.max), payloadLen >= headerBytes else { return nil }
    let bits = UInt32(payloadLen - headerBytes) * 8
    guard bits % bitsPerSample == 0 else { return nil }
    let result = bits / bitsPerSample
    return result > 0 ? result : nil
  }

  mutating func push(_ pkt: ReceivedRTPPacket) throws {
    precondition(pending == nil)
    let payload = pkt.payload
    guard let fl = frameLength(payloadLen: payload.count) else {
      pendingLoss = UInt16(clamping: UInt32(pendingLoss) + UInt32(pkt.loss) + 1)
      throw DepacketizeError(
        "invalid length \(payload.count) for payload of \(bitsPerSample)-bit audio samples")
    }
    pending = AudioFrame(
      ctx: pkt.ctx,
      streamId: pkt.streamId,
      timestamp: pkt.timestamp,
      frameLength: fl,
      loss: UInt16(clamping: UInt32(pendingLoss) + UInt32(pkt.loss)),
      // Normalize to a standalone Data (startIndex 0); the payload is a slice
      // of the receive buffer, and handing a nonzero-startIndex slice to the
      // public frame is a subscripting footgun for consumers.
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
