// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/codec/mod.rs VideoParameters

import Foundation

public enum VideoParametersCodec: Sendable, Equatable {
  case h264(sps: Data, pps: Data)
  case h265(vps: Data, sps: Data, pps: Data)
  case jpeg
}

/// Parsed video codec parameters (SPS/PPS for H.264).
public struct VideoParameters: Sendable, Equatable {
  /// RFC 6381 codec string (e.g., "avc1.640033").
  public let rfc6381Codec: String

  /// Pixel dimensions (width, height) from SPS.
  public let pixelDimensions: (width: UInt16, height: UInt16)?

  /// Pixel aspect ratio from VUI parameters.
  public let pixelAspectRatio: (h: UInt32, v: UInt32)?

  /// Frame rate from VUI timing info, as (numerator, denominator).
  public let frameRate: (num: UInt32, den: UInt32)?

  /// Raw codec-specific parameters (SPS, PPS, VPS).
  public let codecParams: VideoParametersCodec

  /// AVCDecoderConfiguration record (ISO/IEC 14496-15 section 5.2.4.1).
  /// Contains SPS and PPS NALs in the format VideoToolbox expects.
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
