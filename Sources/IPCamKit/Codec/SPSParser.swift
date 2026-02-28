// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Minimal H.264 SPS parser, replaces h264_reader crate
// Ports TolerantBitReader from retina src/codec/h26x.rs

import Foundation

/// Remove emulation prevention bytes (0x00 0x00 0x03 -> 0x00 0x00).
/// This converts a NAL unit to Raw Byte Sequence Payload (RBSP).
func decodeRBSP(_ nal: Data) -> Data {
  var result = Data(capacity: nal.count)
  var i = nal.startIndex
  while i < nal.endIndex {
    if i + 2 < nal.endIndex
      && nal[i] == 0x00 && nal[i + 1] == 0x00 && nal[i + 2] == 0x03
    {
      result.append(0x00)
      result.append(0x00)
      i += 3  // skip the 0x03
    } else {
      result.append(nal[i])
      i += 1
    }
  }
  return result
}

/// A bit reader that tolerates extra trailing data (matching upstream TolerantBitReader).
struct BitReader {
  let data: Data
  var bitOffset: Int = 0

  init(_ data: Data) {
    self.data = data
  }

  var bitsRemaining: Int {
    data.count * 8 - bitOffset
  }

  mutating func readBit() -> UInt8? {
    guard bitOffset < data.count * 8 else { return nil }
    let byteIdx = data.startIndex + bitOffset / 8
    let bitIdx = 7 - (bitOffset % 8)
    bitOffset += 1
    return (data[byteIdx] >> bitIdx) & 1
  }

  mutating func readBits(_ count: Int) -> UInt32? {
    guard count <= 32, bitsRemaining >= count else { return nil }
    var value: UInt32 = 0
    for _ in 0..<count {
      guard let bit = readBit() else { return nil }
      value = (value << 1) | UInt32(bit)
    }
    return value
  }

  /// Read unsigned exp-Golomb coded value.
  mutating func readExpGolomb() -> UInt32? {
    var leadingZeros = 0
    while true {
      guard let bit = readBit() else { return nil }
      if bit == 1 { break }
      leadingZeros += 1
      if leadingZeros > 31 { return nil }
    }
    if leadingZeros == 0 { return 0 }
    guard let suffix = readBits(leadingZeros) else { return nil }
    return (1 << leadingZeros) - 1 + suffix
  }

  /// Read signed exp-Golomb coded value.
  mutating func readSignedExpGolomb() -> Int32? {
    guard let code = readExpGolomb() else { return nil }
    let value = Int32((code + 1) / 2)
    return (code % 2 == 0) ? -value : value
  }

  /// Skip N bits.
  mutating func skip(_ count: Int) {
    bitOffset += count
  }

  /// Read a single boolean (1 bit).
  mutating func readBool() -> Bool? {
    guard let bit = readBit() else { return nil }
    return bit != 0
  }

  /// Read N bytes (N*8 bits) as a Data. Used for reading fixed-size fields like Profile.
  mutating func readBytes(_ count: Int) -> Data? {
    guard bitsRemaining >= count * 8 else { return nil }
    var result = Data(capacity: count)
    for _ in 0..<count {
      guard let byte = readBits(8) else { return nil }
      result.append(UInt8(byte))
    }
    return result
  }

  /// Check if any RBSP data remains (for tolerant parsing).
  var hasMoreData: Bool {
    bitsRemaining > 0
  }
}

/// Parsed SPS data needed for VideoParameters.
struct ParsedSPS: Sendable {
  var profileIdc: UInt8
  var constraintFlags: UInt8
  var levelIdc: UInt8
  var width: UInt16
  var height: UInt16
  var pixelAspectRatio: (h: UInt32, v: UInt32)?
  var frameRate: (num: UInt32, den: UInt32)?
}

/// Parse an H.264 Sequence Parameter Set (minimal, tolerant).
///
/// Extracts profile, level, pixel dimensions, and optionally VUI parameters.
/// Tolerates extra trailing data (matching upstream behavior).
func parseSPS(_ spsNAL: Data) throws -> ParsedSPS {
  // Skip NAL header byte
  guard spsNAL.count > 1 else {
    throw RTSPError.depacketizationError("SPS too short")
  }
  let rbsp = decodeRBSP(Data(spsNAL[(spsNAL.startIndex + 1)...]))
  var reader = BitReader(rbsp)

  guard let profileIdc = reader.readBits(8).map(UInt8.init) else {
    throw RTSPError.depacketizationError("SPS: can't read profile_idc")
  }
  guard let constraintFlags = reader.readBits(8).map(UInt8.init) else {
    throw RTSPError.depacketizationError("SPS: can't read constraint_flags")
  }
  guard let levelIdc = reader.readBits(8).map(UInt8.init) else {
    throw RTSPError.depacketizationError("SPS: can't read level_idc")
  }
  // seq_parameter_set_id
  guard reader.readExpGolomb() != nil else {
    throw RTSPError.depacketizationError("SPS: can't read sps_id")
  }

  // Chroma format (determines crop units)
  // For non-high profiles, chroma_format_idc defaults to 1 (4:2:0)
  var chromaFormatIdc: UInt32 = 1
  var separateColourPlaneFlag = false

  // High profile extensions
  if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profileIdc) {
    guard let cfi = reader.readExpGolomb() else {
      throw RTSPError.depacketizationError("SPS: can't read chroma_format_idc")
    }
    chromaFormatIdc = cfi
    if chromaFormatIdc == 3 {
      if let flag = reader.readBool() {
        separateColourPlaneFlag = flag
      }
    }
    _ = reader.readExpGolomb()  // bit_depth_luma_minus8
    _ = reader.readExpGolomb()  // bit_depth_chroma_minus8
    reader.skip(1)  // qpprime_y_zero_transform_bypass_flag
    guard let scalingMatrixPresent = reader.readBits(1) else {
      throw RTSPError.depacketizationError("SPS: can't read scaling_matrix_present")
    }
    if scalingMatrixPresent == 1 {
      let count = chromaFormatIdc != 3 ? 8 : 12
      for _ in 0..<count {
        guard let flag = reader.readBits(1) else { break }
        if flag == 1 {
          let size = count < 8 ? 16 : 64
          skipScalingList(&reader, size: size)
        }
      }
    }
  }

  // log2_max_frame_num_minus4
  _ = reader.readExpGolomb()
  guard let picOrderCntType = reader.readExpGolomb() else {
    throw RTSPError.depacketizationError("SPS: can't read pic_order_cnt_type")
  }
  if picOrderCntType == 0 {
    _ = reader.readExpGolomb()  // log2_max_pic_order_cnt_lsb_minus4
  } else if picOrderCntType == 1 {
    reader.skip(1)  // delta_pic_order_always_zero_flag
    _ = reader.readSignedExpGolomb()  // offset_for_non_ref_pic
    _ = reader.readSignedExpGolomb()  // offset_for_top_to_bottom_field
    if let numRefFrames = reader.readExpGolomb() {
      for _ in 0..<numRefFrames {
        _ = reader.readSignedExpGolomb()
      }
    }
  }

  _ = reader.readExpGolomb()  // max_num_ref_frames
  reader.skip(1)  // gaps_in_frame_num_allowed_flag

  guard let picWidthMinus1 = reader.readExpGolomb(),
    let picHeightMinus1 = reader.readExpGolomb()
  else {
    throw RTSPError.depacketizationError("SPS: can't read dimensions")
  }

  guard let frameMbsOnlyFlag = reader.readBits(1) else {
    throw RTSPError.depacketizationError("SPS: can't read frame_mbs_only_flag")
  }
  if frameMbsOnlyFlag == 0 {
    reader.skip(1)  // mb_adaptive_frame_field_flag
  }

  reader.skip(1)  // direct_8x8_inference_flag

  // Frame cropping
  var cropLeft: UInt32 = 0
  var cropRight: UInt32 = 0
  var cropTop: UInt32 = 0
  var cropBottom: UInt32 = 0
  guard let frameCroppingFlag = reader.readBits(1) else {
    throw RTSPError.depacketizationError("SPS: can't read frame_cropping_flag")
  }
  if frameCroppingFlag == 1 {
    cropLeft = reader.readExpGolomb() ?? 0
    cropRight = reader.readExpGolomb() ?? 0
    cropTop = reader.readExpGolomb() ?? 0
    cropBottom = reader.readExpGolomb() ?? 0
  }

  // Calculate dimensions
  // Crop units depend on chroma_format_idc (H.264 Table 6-1)
  let subWidthC: UInt32
  let subHeightC: UInt32
  if separateColourPlaneFlag || chromaFormatIdc == 0 {
    // Monochrome or separate colour plane: crop unit = 1
    subWidthC = 1
    subHeightC = 1
  } else {
    switch chromaFormatIdc {
    case 1:  // 4:2:0
      subWidthC = 2
      subHeightC = 2
    case 2:  // 4:2:2
      subWidthC = 2
      subHeightC = 1
    default:  // 4:4:4
      subWidthC = 1
      subHeightC = 1
    }
  }

  let mbWidth = picWidthMinus1 + 1
  let mbHeight = picHeightMinus1 + 1
  let heightMultiplier: UInt32 = frameMbsOnlyFlag == 1 ? 1 : 2
  // CropUnitX = SubWidthC, CropUnitY = SubHeightC * (2 - frame_mbs_only_flag)
  let rawWidth = mbWidth * 16 - (cropLeft + cropRight) * subWidthC
  let rawHeight =
    mbHeight * 16 * heightMultiplier - (cropTop + cropBottom) * subHeightC
    * heightMultiplier

  guard let width = UInt16(exactly: rawWidth), let height = UInt16(exactly: rawHeight) else {
    throw RTSPError.depacketizationError(
      "SPS dimensions too large: \(rawWidth)x\(rawHeight)")
  }

  // VUI parameters (optional)
  var pixelAspectRatio: (h: UInt32, v: UInt32)?
  var frameRate: (num: UInt32, den: UInt32)?

  if let vuiPresent = reader.readBits(1), vuiPresent == 1 {
    // aspect_ratio_info_present_flag
    if let arPresent = reader.readBits(1), arPresent == 1 {
      if let arIdc = reader.readBits(8) {
        if arIdc == 255 {  // Extended_SAR
          if let sarW = reader.readBits(16), let sarH = reader.readBits(16) {
            if sarW > 0 && sarH > 0 {
              pixelAspectRatio = (h: sarW, v: sarH)
            }
          }
        } else {
          pixelAspectRatio = sarTable(arIdc)
        }
      }
    }
    // overscan_info_present_flag
    if let overscanPresent = reader.readBits(1), overscanPresent == 1 {
      reader.skip(1)  // overscan_appropriate_flag
    }
    // video_signal_type_present_flag
    if let vsPresent = reader.readBits(1), vsPresent == 1 {
      reader.skip(3 + 1)  // video_format + video_full_range_flag
      if let colourPresent = reader.readBits(1), colourPresent == 1 {
        reader.skip(8 + 8 + 8)  // colour_primaries + transfer + matrix
      }
    }
    // chroma_loc_info_present_flag
    if let chromaPresent = reader.readBits(1), chromaPresent == 1 {
      _ = reader.readExpGolomb()
      _ = reader.readExpGolomb()
    }
    // timing_info_present_flag
    if let timingPresent = reader.readBits(1), timingPresent == 1 {
      if let numUnitsInTick = reader.readBits(32),
        let timeScale = reader.readBits(32)
      {
        if numUnitsInTick > 0 && timeScale > 0 {
          // frame_rate = time_scale / (2 * num_units_in_tick)
          // We store as (num_units_in_tick * 2, time_scale) to represent the denominator/numerator
          frameRate = (num: numUnitsInTick * 2, den: timeScale)
        }
      }
    }
  }

  return ParsedSPS(
    profileIdc: profileIdc,
    constraintFlags: constraintFlags,
    levelIdc: levelIdc,
    width: width,
    height: height,
    pixelAspectRatio: pixelAspectRatio,
    frameRate: frameRate
  )
}

/// Skip a scaling list in the SPS.
private func skipScalingList(_ reader: inout BitReader, size: Int) {
  var lastScale: Int32 = 8
  var nextScale: Int32 = 8
  for _ in 0..<size {
    if nextScale != 0 {
      let delta = reader.readSignedExpGolomb() ?? 0
      nextScale = (lastScale + delta + 256) % 256
    }
    lastScale = nextScale != 0 ? nextScale : lastScale
  }
}

/// SAR (Sample Aspect Ratio) table from H.264/H.265 Table E-1.
func sarTable(_ idc: UInt32) -> (h: UInt32, v: UInt32)? {
  switch idc {
  case 1: return (1, 1)
  case 2: return (12, 11)
  case 3: return (10, 11)
  case 4: return (16, 11)
  case 5: return (40, 33)
  case 6: return (24, 11)
  case 7: return (20, 11)
  case 8: return (32, 11)
  case 9: return (80, 33)
  case 10: return (18, 11)
  case 11: return (15, 11)
  case 12: return (64, 33)
  case 13: return (160, 99)
  case 14: return (4, 3)
  case 15: return (3, 2)
  case 16: return (2, 1)
  default: return nil
  }
}
