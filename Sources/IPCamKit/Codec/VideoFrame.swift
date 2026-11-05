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

  /// Number of RTP packets lost before or during this frame. Also nonzero when
  /// the depacketizer dropped an earlier access unit it could not reassemble.
  var loss: UInt16

  /// Context of the first packet in this frame.
  var startCtx: PacketContext

  /// Context of the last packet in this frame.
  var endCtx: PacketContext

  /// RTP timestamp of this frame.
  var timestamp: Timestamp

  /// Stream index.
  var streamId: Int

  /// Whether decoding can start at this frame: an H.264 IDR picture, or an
  /// H.265 IRAP picture (NAL unit types 16...23: BLA, IDR, CRA). After a CRA or
  /// BLA picture, leading pictures that reference earlier frames (RASL) are not
  /// decodable when decoding starts here.
  var isRandomAccessPoint: Bool

  /// Whether this frame is disposable (nal_ref_idc == 0 for all NALs).
  var isDisposable: Bool

  /// NAL units in AVCC format: [4-byte length][NAL data]...
  var data: Data

  /// The parameter-set NALs in effect for this frame, captured when the
  /// depacketizer finished the access unit (after applying any SPS/PPS/VPS it
  /// carried). `nil` when the depacketizer had no parameters yet.
  ///
  /// One push can finish two access units, so the depacketizer's current
  /// `parameters` may already belong to a later frame; use this instead.
  var parameterSets: VideoParameterSetNALs? = nil
}

/// The raw parameter-set NAL units (no length prefix or start code) a video
/// frame was depacketized with.
struct VideoParameterSetNALs: Sendable, Equatable {
  var sps: Data
  var pps: Data
  /// The VPS, for H.265 only.
  var vps: Data? = nil
}

/// Tracks the parameter-set NALs of one type (SPS, PPS or VPS) seen in an
/// access unit, to decide whether the stored one changes.
///
/// An access unit can carry several NALs of one type, such as two PPS with
/// different ids. The stored NAL is kept when any of them equals it; otherwise
/// the first one in the access unit replaces it. Comparing each NAL on its own
/// would report a change on every such access unit and alternate the stored
/// NAL between them.
struct ParameterSetCandidates {
  private let stored: Data?
  private var first: Data?
  private var matchesStored = false

  init(stored: Data?) {
    self.stored = stored
  }

  mutating func add(_ nal: Data) {
    if first == nil {
      first = nal
    }
    if !matchesStored, let stored, nal == stored {
      matchesStored = true
    }
  }

  /// The NAL to store in place of the current one, or `nil` to keep it (no
  /// NAL of this type in the access unit, or one equal to the stored one).
  var replacement: Data? {
    matchesStored ? nil : first
  }
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
  case metadataFrame(MetadataFrame)
}
