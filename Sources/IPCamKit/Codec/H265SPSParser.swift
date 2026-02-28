// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/codec/h265/nal.rs - H.265 SPS parser types

import Foundation

// MARK: - Profile

/// H.265 section 7.3.3, `profile_tier_level`, `if( profilePresentFlag )` block.
/// 11 raw bytes: profile_space(2) + tier_flag(1) + profile_idc(5) +
/// compat_flags(32) + constraint_flags(48).
struct H265Profile: Sendable, Equatable {
  let data: Data  // exactly 11 bytes

  init(data: Data) {
    precondition(data.count == 11)
    self.data = data
  }

  var generalProfileSpace: UInt8 {
    data[data.startIndex] >> 6
  }

  var generalTierFlag: Bool {
    (data[data.startIndex] & 0b0010_0000) != 0
  }

  var generalProfileIdc: UInt8 {
    data[data.startIndex] & 0b0001_1111
  }

  /// `general_profile_compatibility_flag[i]` for i from 0 to 31, inclusive.
  var generalProfileCompatibilityFlags: UInt32 {
    let s = data.startIndex
    return UInt32(data[s + 1]) << 24
      | UInt32(data[s + 2]) << 16
      | UInt32(data[s + 3]) << 8
      | UInt32(data[s + 4])
  }

  /// The 6 bytes starting with `general_progressive_source_flag`.
  var generalConstraintIndicatorFlags: Data {
    Data(data[(data.startIndex + 5)..<(data.startIndex + 11)])
  }
}

// MARK: - ProfileTierLevel

/// H.265 section 7.3.3.
struct H265ProfileTierLevel: Sendable {
  let profile: H265Profile?
  let generalLevelIdc: UInt8
}

/// Parse profile_tier_level from a BitReader.
func parseH265ProfileTierLevel(
  _ reader: inout BitReader,
  profilePresentFlag: Bool,
  spsMaxSubLayersMinus1: UInt8
) throws -> H265ProfileTierLevel {
  var profile: H265Profile?
  if profilePresentFlag {
    guard let profileData = reader.readBytes(11) else {
      throw RTSPError.depacketizationError("SPS: can't read profile")
    }
    profile = H265Profile(data: profileData)
  }
  guard let generalLevelIdc = reader.readBits(8).map(UInt8.init) else {
    throw RTSPError.depacketizationError("SPS: can't read general_level_idc")
  }
  if spsMaxSubLayersMinus1 > 0 {
    // Read sub_layer_present_flags (2 bits per sub-layer)
    guard let subLayerPresentFlags = reader.readBits(Int(spsMaxSubLayersMinus1) * 2) else {
      throw RTSPError.depacketizationError("SPS: can't read sub_layer_present_flags")
    }
    // Skip reserved zero bits for unused sub-layers
    let reservedBits = (8 - Int(spsMaxSubLayersMinus1)) * 2
    if reservedBits > 0 {
      reader.skip(reservedBits)
    }
    for i in 0..<Int(spsMaxSubLayersMinus1) {
      let subLayerProfilePresent =
        (subLayerPresentFlags & (1 << (Int(spsMaxSubLayersMinus1) * 2 - 1 - 2 * i))) != 0
      let subLayerLevelPresent =
        (subLayerPresentFlags & (1 << (Int(spsMaxSubLayersMinus1) * 2 - 2 - 2 * i))) != 0
      if subLayerProfilePresent {
        // sub_layer_profile_space(2) + sub_layer_tier_flag(1) + sub_layer_profile_idc(5) = 8
        // sub_layer_profile_compatibility_flags(32)
        // progressive + interlaced + non_packed + frame_only = 4
        // reserved_and_inbld = 44
        reader.skip(2 + 1 + 5 + 32 + 1 + 1 + 1 + 1 + 44)
      }
      if subLayerLevelPresent {
        reader.skip(8)
      }
    }
  }
  return H265ProfileTierLevel(profile: profile, generalLevelIdc: generalLevelIdc)
}

// MARK: - ConformanceWindow

/// Conformance cropping window, in chroma samples.
struct H265ConformanceWindow: Sendable {
  let leftOffset: UInt32
  let rightOffset: UInt32
  let topOffset: UInt32
  let bottomOffset: UInt32
}

func parseH265ConformanceWindow(_ reader: inout BitReader) throws -> H265ConformanceWindow {
  guard let left = reader.readExpGolomb(),
    let right = reader.readExpGolomb(),
    let top = reader.readExpGolomb(),
    let bottom = reader.readExpGolomb()
  else {
    throw RTSPError.depacketizationError("SPS: can't read conformance window")
  }
  return H265ConformanceWindow(
    leftOffset: left, rightOffset: right,
    topOffset: top, bottomOffset: bottom)
}

// MARK: - ScalingListData

/// T.REC H.265 section 7.3.4, `scaling_list_data`.
func skipH265ScalingListData(_ reader: inout BitReader) throws {
  for sizeId in 0..<4 {
    let numMatrices = sizeId == 3 ? 2 : 6
    for _ in 0..<numMatrices {
      guard let predModeFlag = reader.readBool() else {
        throw RTSPError.depacketizationError("SPS: can't read scaling_list_pred_mode_flag")
      }
      if !predModeFlag {
        guard reader.readExpGolomb() != nil else {
          throw RTSPError.depacketizationError("SPS: can't read scaling_list_pred_matrix_id_delta")
        }
      } else {
        let coefNum = min(64, 1 << (4 + (sizeId << 1)))
        if sizeId > 1 {
          guard reader.readSignedExpGolomb() != nil else {
            throw RTSPError.depacketizationError("SPS: can't read scaling_list_dc_coef_minus8")
          }
        }
        for _ in 0..<coefNum {
          _ = reader.readSignedExpGolomb()
        }
      }
    }
  }
}

// MARK: - ShortTermRefPicSet

private let maxShortTermRefPics = 16

/// Represents a `st_ref_pic_set` as in T.REC H.265 section 7.3.7.
struct H265ShortTermRefPicSet: Sendable, Equatable {
  // delta_poc[0..<numNegativePics] = DeltaPocS0 (always negative)
  // delta_poc[numNegativePics..<numNegativePics+numPositivePics] = DeltaPocS1 (always positive)
  var deltaPoc: [Int32]  // fixed size: maxShortTermRefPics
  var numNegativePics: UInt8
  var numPositivePics: UInt8

  var deltaPocS0: ArraySlice<Int32> {
    deltaPoc[0..<Int(numNegativePics)]
  }

  var deltaPocS1: ArraySlice<Int32> {
    deltaPoc[Int(numNegativePics)..<Int(numNegativePics) + Int(numPositivePics)]
  }

  static func fromDeltaPocs(s0: [Int32], s1: [Int32]) -> H265ShortTermRefPicSet {
    var deltaPoc = [Int32](repeating: 0, count: maxShortTermRefPics)
    for (i, v) in s0.enumerated() { deltaPoc[i] = v }
    for (i, v) in s1.enumerated() { deltaPoc[s0.count + i] = v }
    return H265ShortTermRefPicSet(
      deltaPoc: deltaPoc,
      numNegativePics: UInt8(s0.count),
      numPositivePics: UInt8(s1.count))
  }
}

func parseH265ShortTermRefPicSet(
  _ reader: inout BitReader,
  prev: H265ShortTermRefPicSet?
) throws -> H265ShortTermRefPicSet {
  // Check inter_ref_pic_set_prediction_flag if prev exists
  let interRefPicSetPredictionFlag: Bool
  if prev != nil {
    guard let flag = reader.readBool() else {
      throw RTSPError.depacketizationError("SPS: can't read inter_ref_pic_set_prediction_flag")
    }
    interRefPicSetPredictionFlag = flag
  } else {
    interRefPicSetPredictionFlag = false
  }

  if interRefPicSetPredictionFlag {
    let refRps = prev!
    let numRefRpsDeltaPocs = Int(refRps.numNegativePics) + Int(refRps.numPositivePics)

    guard let deltaRpsSign = reader.readBool(),
      let absDeltaRpsMinus1 = reader.readExpGolomb()
    else {
      throw RTSPError.depacketizationError("SPS: can't read delta_rps")
    }
    guard absDeltaRpsMinus1 < (1 << 15) else {
      throw RTSPError.depacketizationError("abs_delta_rps_minus1 must be in [0, 2^15 - 1]")
    }
    let deltaRps = (1 - 2 * (deltaRpsSign ? Int32(1) : Int32(0))) * (Int32(absDeltaRpsMinus1) + 1)

    // "When use_delta_flag[j] is not present, its value is inferred to be equal to 1."
    var useDeltaFlag = [Bool](repeating: true, count: maxShortTermRefPics + 1)
    for j in 0...numRefRpsDeltaPocs {
      guard let usedByCurrPicFlag = reader.readBool() else {
        throw RTSPError.depacketizationError("SPS: can't read used_by_curr_pic_flag")
      }
      if !usedByCurrPicFlag {
        guard let flag = reader.readBool() else {
          throw RTSPError.depacketizationError("SPS: can't read use_delta_flag")
        }
        useDeltaFlag[j] = flag
      }
    }

    // Build the new set per H.265 (7-61)
    var deltaPoc = [Int32](repeating: 0, count: maxShortTermRefPics)
    var numNegativePics = 0

    let refDeltaPocS0 = Array(refRps.deltaPocS0)
    let refDeltaPocS1 = Array(refRps.deltaPocS1)

    // Negative pics from S1 (reversed)
    for (j, d) in refDeltaPocS1.enumerated().reversed() {
      let dpoc = d + deltaRps
      if dpoc < 0 && useDeltaFlag[Int(refRps.numNegativePics) + j] {
        deltaPoc[numNegativePics] = dpoc
        numNegativePics += 1
      }
    }
    if deltaRps < 0 && useDeltaFlag[numRefRpsDeltaPocs] {
      guard numNegativePics < maxShortTermRefPics else {
        throw RTSPError.depacketizationError(
          "num_negative_pics must be less than \(maxShortTermRefPics)")
      }
      deltaPoc[numNegativePics] = deltaRps
      numNegativePics += 1
    }
    for (j, d) in refDeltaPocS0.enumerated() {
      let dpoc = d + deltaRps
      if dpoc < 0 && useDeltaFlag[j] {
        guard numNegativePics < maxShortTermRefPics else {
          throw RTSPError.depacketizationError(
            "num_negative_pics must be less than \(maxShortTermRefPics)")
        }
        deltaPoc[numNegativePics] = dpoc
        numNegativePics += 1
      }
    }

    // Positive pics
    let maxPositivePics = maxShortTermRefPics - numNegativePics
    var numPositivePics = 0
    for (j, d) in refDeltaPocS0.enumerated().reversed() {
      let dpoc = d + deltaRps
      if dpoc > 0 && useDeltaFlag[j] {
        guard numPositivePics < maxPositivePics else {
          throw RTSPError.depacketizationError(
            "NumDeltaPocs must be less than or equal to \(maxShortTermRefPics)")
        }
        deltaPoc[numNegativePics + numPositivePics] = dpoc
        numPositivePics += 1
      }
    }
    if deltaRps > 0 && useDeltaFlag[numRefRpsDeltaPocs] {
      guard numPositivePics < maxPositivePics else {
        throw RTSPError.depacketizationError(
          "NumDeltaPocs must be less than or equal to \(maxShortTermRefPics)")
      }
      deltaPoc[numNegativePics + numPositivePics] = deltaRps
      numPositivePics += 1
    }
    for (j, d) in refDeltaPocS1.enumerated() {
      let dpoc = d + deltaRps
      if dpoc > 0 && useDeltaFlag[Int(refRps.numNegativePics) + j] {
        guard numPositivePics < maxPositivePics else {
          throw RTSPError.depacketizationError(
            "NumDeltaPocs must be less than or equal to \(maxShortTermRefPics)")
        }
        deltaPoc[numNegativePics + numPositivePics] = dpoc
        numPositivePics += 1
      }
    }

    return H265ShortTermRefPicSet(
      deltaPoc: deltaPoc,
      numNegativePics: UInt8(numNegativePics),
      numPositivePics: UInt8(numPositivePics))
  } else {
    // Direct (non-prediction) mode
    guard let numNegativePics = reader.readExpGolomb(),
      let numPositivePics = reader.readExpGolomb()
    else {
      throw RTSPError.depacketizationError("SPS: can't read num_negative/positive_pics")
    }
    // Saturating add to match upstream Rust — overflow clamps to UInt32.max,
    // which exceeds maxShortTermRefPics, so the guard catches it.
    let (sum, overflow) = numNegativePics.addingReportingOverflow(numPositivePics)
    let numDeltaPocs = overflow ? UInt32.max : sum
    guard numDeltaPocs <= UInt32(maxShortTermRefPics) else {
      throw RTSPError.depacketizationError(
        "NumDeltaPocs must be in [0, \(maxShortTermRefPics)]")
    }
    var deltaPoc = [Int32](repeating: 0, count: maxShortTermRefPics)
    var dpoc: Int32 = 0
    for i in 0..<Int(numNegativePics) {
      guard let v = reader.readExpGolomb() else {
        throw RTSPError.depacketizationError("SPS: can't read delta_poc_s0_minus1")
      }
      guard v < (1 << 15) else {
        throw RTSPError.depacketizationError("delta_poc_s0_minus1 must be in [0, 2^15 - 1]")
      }
      dpoc -= Int32(v) + 1
      deltaPoc[i] = dpoc
      _ = reader.readBool()  // used_by_curr_pic_s0_flag
    }
    dpoc = 0
    for i in 0..<Int(numPositivePics) {
      guard let v = reader.readExpGolomb() else {
        throw RTSPError.depacketizationError("SPS: can't read delta_poc_s1_minus1")
      }
      guard v < (1 << 15) else {
        throw RTSPError.depacketizationError("delta_poc_s1_minus1 must be in [0, 2^15 - 1]")
      }
      dpoc += Int32(v) + 1
      deltaPoc[Int(numNegativePics) + i] = dpoc
      _ = reader.readBool()  // used_by_curr_pic_s1_flag
    }
    return H265ShortTermRefPicSet(
      deltaPoc: deltaPoc,
      numNegativePics: UInt8(numNegativePics),
      numPositivePics: UInt8(numPositivePics))
  }
}

// MARK: - BitstreamRestriction

struct H265BitstreamRestriction: Sendable {
  let minSpatialSegmentationIdc: UInt16
}

func parseH265BitstreamRestriction(_ reader: inout BitReader) throws -> H265BitstreamRestriction {
  _ = reader.readBool()  // tiles_fixed_structure_flag
  _ = reader.readBool()  // motion_vectors_over_pic_boundaries_flag
  _ = reader.readBool()  // restricted_ref_pic_lists_flag
  guard let minSpatialSegIdc = reader.readExpGolomb() else {
    throw RTSPError.depacketizationError(
      "SPS: can't read min_spatial_segmentation_idc")
  }
  guard minSpatialSegIdc < 4096 else {
    throw RTSPError.depacketizationError(
      "min_spatial_segmentation_idc must be less than 4096")
  }
  _ = reader.readExpGolomb()  // max_bytes_per_pic_denom
  _ = reader.readExpGolomb()  // max_bits_per_min_cu_denom
  _ = reader.readExpGolomb()  // log2_max_mv_length_horizontal
  _ = reader.readExpGolomb()  // log2_max_mv_length_vertical
  return H265BitstreamRestriction(minSpatialSegmentationIdc: UInt16(minSpatialSegIdc))
}

// MARK: - VUI Timing Info

/// T.REC H.265 section E.2.1 `vui_parameters`, timing info block.
struct H265VuiTimingInfo: Sendable {
  let numUnitsInTick: UInt32
  let timeScale: UInt32
}

func parseH265VuiTimingInfo(
  _ reader: inout BitReader,
  spsMaxSubLayersMinus1: UInt8
) throws -> H265VuiTimingInfo {
  guard let numUnitsInTick = reader.readBits(32),
    let timeScale = reader.readBits(32)
  else {
    throw RTSPError.depacketizationError("SPS: can't read vui timing info")
  }
  if let pocProportional = reader.readBool(), pocProportional {
    _ = reader.readExpGolomb()  // vui_num_ticks_poc_diff_one_minus1
  }
  guard let hrdPresent = reader.readBool() else {
    throw RTSPError.depacketizationError("SPS: can't read vui_hrd_parameters_present_flag")
  }
  if hrdPresent {
    try skipH265HrdParameters(
      &reader,
      spsMaxSubLayersMinus1: spsMaxSubLayersMinus1)
  }
  return H265VuiTimingInfo(numUnitsInTick: numUnitsInTick, timeScale: timeScale)
}

/// Skip HRD parameters (complex nested structure).
private func skipH265HrdParameters(
  _ reader: inout BitReader,
  spsMaxSubLayersMinus1: UInt8
) throws {
  var subpicParamsPresent = false
  guard let nalParamsPresent = reader.readBool(),
    let vclParamsPresent = reader.readBool()
  else {
    throw RTSPError.depacketizationError("SPS: can't read HRD params present flags")
  }

  if nalParamsPresent || vclParamsPresent {
    guard let sp = reader.readBool() else {
      throw RTSPError.depacketizationError("SPS: can't read subpic_params_present")
    }
    subpicParamsPresent = sp
    if subpicParamsPresent {
      reader.skip(8)  // tick_divisor_minus2
      reader.skip(5)  // du_cpb_removal_delay_increment_length_minus1
      reader.skip(1)  // sub_pic_cpb_params_in_pic_timing_sei_flag
      reader.skip(5)  // dpb_output_delay_du_length_minus1
    }
    reader.skip(4)  // bit_rate_scale
    reader.skip(4)  // cpb_size_scale
    if subpicParamsPresent {
      reader.skip(4)  // cpb_size_du_scale
    }
    reader.skip(5)  // initial_cpb_removal_delay_length_minus1
    reader.skip(5)  // au_cpb_removal_delay_length_minus1
    reader.skip(5)  // dpb_output_delay_length_minus1
  }

  for _ in 0...Int(spsMaxSubLayersMinus1) {
    var lowDelay = false
    var nbCpb: UInt32 = 1
    guard let fixedRateGeneral = reader.readBool() else {
      throw RTSPError.depacketizationError("SPS: can't read fixed_pic_rate_general_flag")
    }
    var fixedRate = fixedRateGeneral
    if !fixedRate {
      guard let fixedWithin = reader.readBool() else {
        throw RTSPError.depacketizationError("SPS: can't read fixed_pic_rate_within_cvs_flag")
      }
      fixedRate = fixedWithin
    }
    if fixedRate {
      _ = reader.readExpGolomb()  // elemental_duration_in_tc_minus1
    } else {
      guard let ld = reader.readBool() else {
        throw RTSPError.depacketizationError("SPS: can't read low_delay")
      }
      lowDelay = ld
    }
    if !lowDelay {
      guard let n = reader.readExpGolomb() else {
        throw RTSPError.depacketizationError("SPS: can't read nb_cpb")
      }
      nbCpb = n + 1
    }
    if nalParamsPresent {
      for _ in 0..<nbCpb {
        _ = reader.readExpGolomb()  // bit_rate_value_minus1
        _ = reader.readExpGolomb()  // cpb_size_value_minus1
        if subpicParamsPresent {
          _ = reader.readExpGolomb()  // cpb_size_du_value_minus1
          _ = reader.readExpGolomb()  // bit_rate_du_value_minus1
        }
        _ = reader.readBool()  // cbr_flag
      }
    }
    if vclParamsPresent {
      for _ in 0..<nbCpb {
        _ = reader.readExpGolomb()  // bit_rate_value_minus1
        _ = reader.readExpGolomb()  // cpb_size_value_minus1
        if subpicParamsPresent {
          _ = reader.readExpGolomb()  // cpb_size_du_value_minus1
          _ = reader.readExpGolomb()  // bit_rate_du_value_minus1
        }
        reader.skip(1)  // cbr_flag
      }
    }
  }
}

// MARK: - VUI Parameters

/// T.REC H.265 section E.2.1 `vui_parameters`.
struct H265VuiParameters: Sendable {
  let aspectRatio: (h: UInt32, v: UInt32)?
  let timingInfo: H265VuiTimingInfo?
  let minSpatialSegmentationIdc: UInt16?
}

func parseH265VuiParameters(
  _ reader: inout BitReader,
  spsMaxSubLayersMinus1: UInt8
) throws -> H265VuiParameters {
  // aspect_ratio
  var aspectRatio: (h: UInt32, v: UInt32)?
  if let arPresent = reader.readBool(), arPresent {
    if let arIdc = reader.readBits(8) {
      if arIdc == 255 {
        if let sarW = reader.readBits(16), let sarH = reader.readBits(16) {
          if sarW > 0 && sarH > 0 {
            aspectRatio = (h: sarW, v: sarH)
          }
        }
      } else {
        aspectRatio = sarTable(arIdc)
      }
    }
  }
  // overscan_info
  if let overscanPresent = reader.readBool(), overscanPresent {
    _ = reader.readBool()  // overscan_appropriate_flag
  }
  // video_signal_type
  if let vsPresent = reader.readBool(), vsPresent {
    reader.skip(3)  // video_format
    _ = reader.readBool()  // video_full_range_flag
    if let colourPresent = reader.readBool(), colourPresent {
      reader.skip(8 + 8 + 8)  // colour_primaries + transfer + matrix
    }
  }
  // chroma_loc_info
  if let chromaPresent = reader.readBool(), chromaPresent {
    _ = reader.readExpGolomb()
    _ = reader.readExpGolomb()
  }
  // H.265-specific VUI fields
  _ = reader.readBool()  // neutral_chroma_indication_flag
  _ = reader.readBool()  // field_seq_flag
  _ = reader.readBool()  // frame_field_info_present_flag
  if let defaultDisplayWindow = reader.readBool(), defaultDisplayWindow {
    _ = reader.readExpGolomb()  // def_disp_win_left_offset
    _ = reader.readExpGolomb()  // def_disp_win_right_offset
    _ = reader.readExpGolomb()  // def_disp_win_top_offset
    _ = reader.readExpGolomb()  // def_disp_win_bottom_offset
  }
  // timing_info
  var timingInfo: H265VuiTimingInfo?
  if let timingPresent = reader.readBool(), timingPresent {
    timingInfo = try parseH265VuiTimingInfo(
      &reader,
      spsMaxSubLayersMinus1: spsMaxSubLayersMinus1)
  }
  // bitstream_restriction
  var minSpatialSegmentationIdc: UInt16?
  if let brPresent = reader.readBool(), brPresent {
    let br = try parseH265BitstreamRestriction(&reader)
    minSpatialSegmentationIdc = br.minSpatialSegmentationIdc
  }
  return H265VuiParameters(
    aspectRatio: aspectRatio,
    timingInfo: timingInfo,
    minSpatialSegmentationIdc: minSpatialSegmentationIdc)
}

// MARK: - H.265 SPS

/// Parsed H.265 Sequence Parameter Set.
struct H265Sps: Sendable {
  let spsMaxSubLayersMinus1: UInt8
  let spsTemporalIdNestingFlag: Bool
  let profileTierLevel: H265ProfileTierLevel
  let chromaFormatIdc: UInt8
  let picWidthInLumaSamples: UInt32
  let picHeightInLumaSamples: UInt32
  let conformanceWindow: H265ConformanceWindow?
  let bitDepthLumaMinus8: UInt8
  let bitDepthChromaMinus8: UInt8
  let shortTermPicRefSets: [H265ShortTermRefPicSet]
  let vui: H265VuiParameters?

  var maxSubLayers: UInt8 { spsMaxSubLayersMinus1 + 1 }

  var temporalIdNestingFlag: Bool { spsTemporalIdNestingFlag }

  func profile() -> H265Profile {
    profileTierLevel.profile!
  }

  func generalLevelIdc() -> UInt8 {
    profileTierLevel.generalLevelIdc
  }

  /// Returns the pixel dimensions `(width, height)`, subtracting conformance window.
  func pixelDimensions() throws -> (UInt32, UInt32) {
    var width = picWidthInLumaSamples
    var height = picHeightInLumaSamples
    if let c = conformanceWindow {
      let widthShift: UInt32 = (chromaFormatIdc == 1 || chromaFormatIdc == 2) ? 1 : 0
      let heightShift: UInt32 = chromaFormatIdc == 1 ? 1 : 0
      let lr = c.leftOffset &+ c.rightOffset
      let tb = c.topOffset &+ c.bottomOffset
      let subW = lr << widthShift
      let subH = tb << heightShift
      guard width >= subW, height >= subH else {
        throw RTSPError.depacketizationError("bad conformance window")
      }
      width -= subW
      height -= subH
    }
    return (width, height)
  }

  /// Build RFC 6381 codec string: `hvc1.<space><idc>.<compat_reversed>.<tier><level>.<constraints>`
  func rfc6381Codec() -> String {
    let p = profile()
    let space: String
    switch p.generalProfileSpace {
    case 0: space = ""
    case 1: space = "A"
    case 2: space = "B"
    case 3: space = "C"
    default: space = ""
    }
    let idc = p.generalProfileIdc
    let compat = reverseBits32(p.generalProfileCompatibilityFlags)
    let tier = p.generalTierFlag ? "H" : "L"
    let level = profileTierLevel.generalLevelIdc
    var out = "hvc1.\(space)\(idc).\(String(format: "%X", compat)).\(tier)\(level)"
    var constraintBytes = Array(p.generalConstraintIndicatorFlags)
    while constraintBytes.count > 1 && constraintBytes.last == 0 {
      constraintBytes.removeLast()
    }
    for b in constraintBytes {
      out += ".\(String(format: "%02X", b))"
    }
    return out
  }
}

/// Reverse bits in a 32-bit value.
private func reverseBits32(_ x: UInt32) -> UInt32 {
  var v = x
  v = ((v >> 1) & 0x5555_5555) | ((v & 0x5555_5555) << 1)
  v = ((v >> 2) & 0x3333_3333) | ((v & 0x3333_3333) << 2)
  v = ((v >> 4) & 0x0F0F_0F0F) | ((v & 0x0F0F_0F0F) << 4)
  v = ((v >> 8) & 0x00FF_00FF) | ((v & 0x00FF_00FF) << 8)
  v = (v >> 16) | (v << 16)
  return v
}

/// Parse an H.265 SPS from RBSP bits (after NAL header has been stripped and RBSP decoded).
func parseH265SPS(_ rbsp: Data) throws -> H265Sps {
  var reader = BitReader(rbsp)

  // sps_video_parameter_set_id (4 bits)
  reader.skip(4)

  guard let maxSubLayersMinus1 = reader.readBits(3).map(UInt8.init) else {
    throw RTSPError.depacketizationError("SPS: can't read sps_max_sub_layers_minus1")
  }
  guard maxSubLayersMinus1 <= 6 else {
    throw RTSPError.depacketizationError("sps_max_sub_layers_minus1 must be in [0, 6]")
  }
  guard let temporalIdNestingFlag = reader.readBool() else {
    throw RTSPError.depacketizationError("SPS: can't read sps_temporal_id_nesting_flag")
  }

  let ptl = try parseH265ProfileTierLevel(
    &reader,
    profilePresentFlag: true,
    spsMaxSubLayersMinus1: maxSubLayersMinus1)

  // sps_seq_parameter_set_id
  _ = reader.readExpGolomb()

  guard let chromaFormatIdc = reader.readExpGolomb() else {
    throw RTSPError.depacketizationError("SPS: can't read chroma_format_idc")
  }
  guard chromaFormatIdc <= 3 else {
    throw RTSPError.depacketizationError("chroma_format_idc must be in [0, 3]")
  }
  if chromaFormatIdc == 3 {
    _ = reader.readBool()  // separate_colour_plane_flag
  }

  guard let picWidth = reader.readExpGolomb(),
    let picHeight = reader.readExpGolomb()
  else {
    throw RTSPError.depacketizationError("SPS: can't read pic dimensions")
  }

  var conformanceWindow: H265ConformanceWindow?
  if let cwFlag = reader.readBool(), cwFlag {
    conformanceWindow = try parseH265ConformanceWindow(&reader)
  }

  guard let bitDepthLuma = reader.readExpGolomb() else {
    throw RTSPError.depacketizationError("SPS: can't read bit_depth_luma_minus8")
  }
  guard bitDepthLuma <= 8 else {
    throw RTSPError.depacketizationError("bit_depth_luma_minus8 must be in [0, 8]")
  }
  guard let bitDepthChroma = reader.readExpGolomb() else {
    throw RTSPError.depacketizationError("SPS: can't read bit_depth_chroma_minus8")
  }
  guard bitDepthChroma <= 8 else {
    throw RTSPError.depacketizationError("bit_depth_chroma_minus8 must be in [0, 8]")
  }

  guard let log2MaxPicOrderCntLsbMinus4 = reader.readExpGolomb() else {
    throw RTSPError.depacketizationError("SPS: can't read log2_max_pic_order_cnt_lsb_minus4")
  }
  guard let subLayerOrderingPresent = reader.readBool() else {
    throw RTSPError.depacketizationError(
      "SPS: can't read sps_sub_layer_ordering_info_present_flag")
  }
  let start: UInt8 = subLayerOrderingPresent ? 0 : maxSubLayersMinus1
  for _ in start...maxSubLayersMinus1 {
    guard let maxDecPicBuf = reader.readExpGolomb() else {
      throw RTSPError.depacketizationError(
        "SPS: can't read sps_max_dec_pic_buffering_minus1")
    }
    guard maxDecPicBuf <= 15 else {
      throw RTSPError.depacketizationError(
        "sps_max_dec_pic_buffering_minus1 must be in [0, 15]")
    }
    _ = reader.readExpGolomb()  // sps_max_num_reorder_pics
    _ = reader.readExpGolomb()  // sps_max_latency_increase_plus1
  }

  _ = reader.readExpGolomb()  // log2_min_luma_coding_block_size_minus3
  _ = reader.readExpGolomb()  // log2_diff_max_min_luma_coding_block_size
  _ = reader.readExpGolomb()  // log2_min_luma_transform_block_size_minus2
  _ = reader.readExpGolomb()  // log2_diff_max_min_luma_transform_block_size
  _ = reader.readExpGolomb()  // max_transform_hierarchy_depth_inter
  _ = reader.readExpGolomb()  // max_transform_hierarchy_depth_intra

  if let scalingListEnabled = reader.readBool(), scalingListEnabled {
    if let scalingListPresent = reader.readBool(), scalingListPresent {
      try skipH265ScalingListData(&reader)
    }
  }
  _ = reader.readBool()  // amp_enabled_flag
  _ = reader.readBool()  // sample_adaptive_offset_enabled_flag

  if let pcmEnabled = reader.readBool(), pcmEnabled {
    reader.skip(4)  // pcm_sample_bit_depth_luma_minus1
    reader.skip(4)  // pcm_sample_bit_depth_chroma_minus1
    _ = reader.readExpGolomb()  // log2_min_pcm_luma_coding_block_size_minus3
    _ = reader.readExpGolomb()  // log2_diff_max_min_pcm_luma_coding_block_size
    _ = reader.readBool()  // pcm_loop_filter_disabled_flag
  }

  guard let numShortTermRefPicSets = reader.readExpGolomb() else {
    throw RTSPError.depacketizationError("SPS: can't read num_short_term_ref_pic_sets")
  }
  guard numShortTermRefPicSets <= 64 else {
    throw RTSPError.depacketizationError("num_short_term_ref_pic_sets must be in [0, 64]")
  }
  var shortTermPicRefSets: [H265ShortTermRefPicSet] = []
  shortTermPicRefSets.reserveCapacity(Int(numShortTermRefPicSets))
  for _ in 0..<numShortTermRefPicSets {
    let next = try parseH265ShortTermRefPicSet(&reader, prev: shortTermPicRefSets.last)
    shortTermPicRefSets.append(next)
  }

  if let longTermPresent = reader.readBool(), longTermPresent {
    guard let numLongTermRefPics = reader.readExpGolomb() else {
      throw RTSPError.depacketizationError("SPS: can't read num_long_term_ref_pics_sps")
    }
    for _ in 0..<numLongTermRefPics {
      reader.skip(Int(log2MaxPicOrderCntLsbMinus4) + 4)  // lt_ref_pic_poc_lsb_sps
      _ = reader.readBool()  // used_by_curr_pic_lt_sps_flag
    }
  }

  _ = reader.readBool()  // sps_temporal_mvp_enabled_flag
  _ = reader.readBool()  // strong_intra_smoothing_enabled_flag

  var vui: H265VuiParameters?
  if let vuiPresent = reader.readBool(), vuiPresent {
    vui = try parseH265VuiParameters(&reader, spsMaxSubLayersMinus1: maxSubLayersMinus1)
  }

  // SPS extension flags — skip but tolerate
  if let extensionFlag = reader.readBool(), extensionFlag {
    // Read extension sub-flags
    let rangeExt = reader.readBool() ?? false
    let multilayerExt = reader.readBool() ?? false
    let ext3d = reader.readBool() ?? false
    let sccExt = reader.readBool() ?? false
    let ext4bits = reader.readBits(4) ?? 0

    if rangeExt {
      reader.skip(9)  // sps_range_extension
    }
    if multilayerExt {
      reader.skip(1)  // inter_view_mv_vert_constraint_flag
    }
    if ext3d {
      // d == 0
      reader.skip(1)  // iv_di_mc_enabled_flag
      reader.skip(1)  // iv_mv_scal_enabled_flag
      _ = reader.readExpGolomb()  // log2_ivmc_sub_pb_size_minus3
      reader.skip(1)  // iv_res_pred_enabled_flag
      reader.skip(1)  // depth_ref_enabled_flag
      reader.skip(1)  // vsp_mc_enabled_flag
      reader.skip(1)  // dbbp_enabled_flag
      // d == 1
      reader.skip(1)  // tex_mc_enabled_flag
      _ = reader.readExpGolomb()  // log2_texmc_sub_pb_size_minus3
      reader.skip(1)  // intra_contour_enabled_flag
      reader.skip(1)  // intra_dc_only_wedge_enabled_flag
      reader.skip(1)  // cqt_cu_part_pred_enabled_flag
      reader.skip(1)  // inter_dc_only_enabled_flag
      reader.skip(1)  // skip_intra_enabled_flag
    }
    if sccExt {
      reader.skip(1)  // sps_curr_pic_ref_enabled_flag
      if let paletteMode = reader.readBool(), paletteMode {
        _ = reader.readExpGolomb()  // palette_max_size (Rust bug: ignores error)
        guard reader.readExpGolomb() != nil else {
          throw RTSPError.depacketizationError("SPS: can't read delta_palette_max_predictor_size")
        }
        if let initPresent = reader.readBool(), initPresent {
          guard reader.readExpGolomb() != nil else {
            throw RTSPError.depacketizationError(
              "SPS: can't read sps_num_palette_predictor_initializers_minus1")
          }
        }
      }
    }
    if ext4bits != 0 {
      throw RTSPError.depacketizationError("sps_extension_4bits unimplemented")
    }
  }

  // finish_rbsp — tolerant, don't error on extra trailing data

  return H265Sps(
    spsMaxSubLayersMinus1: maxSubLayersMinus1,
    spsTemporalIdNestingFlag: temporalIdNestingFlag,
    profileTierLevel: ptl,
    chromaFormatIdc: UInt8(chromaFormatIdc),
    picWidthInLumaSamples: picWidth,
    picHeightInLumaSamples: picHeight,
    conformanceWindow: conformanceWindow,
    bitDepthLumaMinus8: UInt8(bitDepthLuma),
    bitDepthChromaMinus8: UInt8(bitDepthChroma),
    shortTermPicRefSets: shortTermPicRefSets,
    vui: vui)
}
