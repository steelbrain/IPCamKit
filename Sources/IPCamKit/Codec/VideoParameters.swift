// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/codec/mod.rs VideoParameters

import Foundation

public enum VideoParametersCodec: Sendable, Equatable {
  case h264(sps: Data, pps: Data)
  case h265(vps: Data, sps: Data, pps: Data)
  case jpeg
}

/// Parsed video codec parameters (SPS/PPS for H.264; VPS/SPS/PPS for H.265).
public struct VideoParameters: Sendable, Equatable {
  /// RFC 6381 codec string (e.g., "avc1.640033").
  public let rfc6381Codec: String

  /// Pixel dimensions (width, height) from SPS.
  public let pixelDimensions: (width: UInt16, height: UInt16)?

  /// Pixel aspect ratio from VUI parameters.
  public let pixelAspectRatio: (h: UInt32, v: UInt32)?

  /// Nominal frame duration from the SPS VUI timing info, as a fraction of a
  /// second: `num / den` seconds per frame, so frames per second is
  /// `den / num`. For H.264 this is `(2 * num_units_in_tick, time_scale)`; for
  /// H.265, `(vui_num_units_in_tick, vui_time_scale)`. For example, `(2, 60)`
  /// is 1/30 s per frame (30 fps). `nil` when the SPS has no timing info,
  /// either value is zero, or (H.264) doubling `num_units_in_tick` overflows.
  public let frameRate: (num: UInt32, den: UInt32)?

  /// Raw codec-specific parameters (SPS, PPS, VPS).
  public let codecParams: VideoParametersCodec

  /// Decoder configuration record (ISO/IEC 14496-15), in the format
  /// VideoToolbox expects: an AVCDecoderConfigurationRecord holding the SPS and
  /// PPS for H.264, or an HEVCDecoderConfigurationRecord holding the VPS, SPS
  /// and PPS for H.265. Both declare 4-byte NAL length prefixes.
  public let extraData: Data

  public static func == (lhs: VideoParameters, rhs: VideoParameters) -> Bool {
    lhs.rfc6381Codec == rhs.rfc6381Codec
      && lhs.pixelDimensions?.width == rhs.pixelDimensions?.width
      && lhs.pixelDimensions?.height == rhs.pixelDimensions?.height
      && lhs.pixelAspectRatio?.h == rhs.pixelAspectRatio?.h
      && lhs.pixelAspectRatio?.v == rhs.pixelAspectRatio?.v
      && lhs.frameRate?.num == rhs.frameRate?.num
      && lhs.frameRate?.den == rhs.frameRate?.den
      && lhs.codecParams == rhs.codecParams
      && lhs.extraData == rhs.extraData
  }
}
