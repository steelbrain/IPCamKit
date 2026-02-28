// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/codec/mod.rs VideoFrame

import Foundation

/// A depacketized video frame consisting of one or more NAL units in AVCC format.
///
/// Each NAL unit is prefixed with a 4-byte big-endian length.
/// This is the format expected by VideoToolbox (CMVideoFormatDescription).
struct VideoFrame: Sendable, Equatable {
  /// Whether codec parameters (SPS/PPS) changed with this frame.
  var hasNewParameters: Bool

  /// Number of RTP packets lost before or during this frame.
  var loss: UInt16

  /// Context of the first packet in this frame.
  var startCtx: PacketContext

  /// Context of the last packet in this frame.
  var endCtx: PacketContext

  /// RTP timestamp of this frame.
  var timestamp: Timestamp

  /// Stream index.
  var streamId: Int

  /// Whether this is a random access point (IDR frame).
  var isRandomAccessPoint: Bool

  /// Whether this frame is disposable (nal_ref_idc == 0 for all NALs).
  var isDisposable: Bool

  /// NAL units in AVCC format: [4-byte length][NAL data]...
  var data: Data
}

/// Errors during depacketization.
///
/// Matches upstream `DepacketizeError` which carries packet context for diagnostics.
struct DepacketizeError: Error, Sendable, Equatable, CustomStringConvertible {
  var pktCtx: PacketContext
  var ssrc: UInt32
  var sequenceNumber: UInt16
  let description: String

  init(
    pktCtx: PacketContext, ssrc: UInt32, sequenceNumber: UInt16,
    description: String
  ) {
    self.pktCtx = pktCtx
    self.ssrc = ssrc
    self.sequenceNumber = sequenceNumber
    self.description = description
  }

  /// Convenience init with just a description (context filled by caller).
  init(_ description: String) {
    self.pktCtx = .dummy
    self.ssrc = 0
    self.sequenceNumber = 0
    self.description = description
  }
}

/// Codec output item.
enum CodecItem: Sendable {
  case videoFrame(VideoFrame)
  case audioFrame(AudioFrame)
}
