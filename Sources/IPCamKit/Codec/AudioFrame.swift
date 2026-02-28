// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/codec/mod.rs AudioFrame, AudioParameters

import Foundation

/// A depacketized audio frame consisting of one or more samples.
struct AudioFrame: Sendable, Equatable {
  /// Context of the packet containing this frame.
  var ctx: PacketContext

  /// Stream index.
  var streamId: Int

  /// RTP timestamp of this frame.
  var timestamp: Timestamp

  /// Frame length in clock-rate units (samples per frame).
  var frameLength: UInt32

  /// Number of RTP packets lost before this audio frame.
  var loss: UInt16

  /// Raw audio data (codec-specific).
  var data: Data
}

/// Parameters which describe an audio stream.
struct AudioParameters: Sendable, Equatable {
  /// Codec description in RFC 6381 form, e.g. "mp4a.40.2".
  var rfc6381Codec: String?

  /// The length of each frame (in clock_rate units), if fixed.
  var frameLength: UInt32?

  /// The codec clock rate in Hz.
  var clockRate: UInt32

  /// Codec-specific extra data (e.g. AudioSpecificConfig for AAC).
  var extraData: Data

  /// Codec-specific information.
  var codec: AudioCodec
}

/// Codec-specific data needed from AudioParameters.
enum AudioCodec: Sendable, Equatable {
  case aac(channelsConfigId: UInt8)
  case other
}
