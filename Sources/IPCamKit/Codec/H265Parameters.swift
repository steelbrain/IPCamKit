// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/codec/h265.rs InternalParameters + h265/record.rs

import Foundation

/// Internal H.265 parameters (VPS + SPS + PPS), used by the depacketizer
/// to track codec parameter changes.
struct H265Parameters: Sendable, Equatable {
  var genericParameters: VideoParameters
  var vpsNAL: Data
  var spsNAL: Data
  var ppsNAL: Data

  /// Parse format-specific parameters from SDP fmtp attribute.
  ///
  /// Expected keys: `sprop-vps`, `sprop-sps`, `sprop-pps`, optionally `tx-mode=SRST`.
  static func parseFormatSpecificParams(_ fmtp: String) throws -> H265Parameters {
    var spsNAL: Data?
    var ppsNAL: Data?
    var vpsNAL: Data?

    for p in fmtp.split(separator: ";") {
      let trimmed = p.trimmingCharacters(in: .whitespaces)
      guard let eqIdx = trimmed.firstIndex(of: "=") else {
        throw RTSPError.depacketizationError("key \(trimmed) without value")
      }
      let key = trimmed[..<eqIdx].trimmingCharacters(in: .whitespaces)
      let value = trimmed[trimmed.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)

      switch key {
      case "tx-mode":
        guard value == "SRST" else {
          throw RTSPError.depacketizationError(
            "unsupported/unexpected tx-mode \(value); expected SRST")
        }
      case "sprop-vps":
        try storeSpropNAL(key: "sprop-vps", value: value, out: &vpsNAL)
      case "sprop-sps":
        try storeSpropNAL(key: "sprop-sps", value: value, out: &spsNAL)
      case "sprop-pps":
        try storeSpropNAL(key: "sprop-pps", value: value, out: &ppsNAL)
      default:
        break  // ignore unknown keys
      }
    }

    guard let vps = vpsNAL else {
      throw RTSPError.depacketizationError("no vps")
    }
    guard let sps = spsNAL else {
      throw RTSPError.depacketizationError("no sps")
    }
    guard let pps = ppsNAL else {
      throw RTSPError.depacketizationError("no pps")
    }

    return try parseVPSSPSPPS(vps: vps, sps: sps, pps: pps)
  }

  private static func storeSpropNAL(
    key: String, value: String, out: inout Data?
  ) throws {
    guard let decoded = Data(base64Encoded: value) else {
      throw RTSPError.depacketizationError(
        "bad parameter \(key): NAL has invalid base64 encoding")
    }
    guard !decoded.isEmpty else {
      throw RTSPError.depacketizationError("bad parameter \(key): empty NAL")
    }
    guard out == nil else {
      throw RTSPError.depacketizationError("multiple \(key) parameters")
    }
    out = decoded
  }

  /// Parse VPS, SPS, and PPS NALs and build parameters.
  static func parseVPSSPSPPS(
    vps vpsNAL: Data, sps spsNAL: Data, pps ppsNAL: Data
  ) throws -> H265Parameters {
    // Validate VPS
    let (vpsH, _) = try h265SplitNAL(vpsNAL)
    guard vpsH.unitType == .vpsNut else {
      throw RTSPError.depacketizationError("VPS NAL is not VPS")
    }

    // Parse SPS
    let (spsH, spsBody) = try h265SplitNAL(spsNAL)
    guard spsH.unitType == .spsNut else {
      throw RTSPError.depacketizationError("SPS NAL is not SPS")
    }
    let spsRBSP = decodeRBSP(spsBody)
    let sps = try parseH265SPS(spsRBSP)

    // Parse PPS
    let (ppsH, ppsBody) = try h265SplitNAL(ppsNAL)
    guard ppsH.unitType == .ppsNut else {
      throw RTSPError.depacketizationError("PPS NAL is not PPS")
    }
    let ppsRBSP = decodeRBSP(ppsBody)
    let pps = try parseH265PPS(ppsRBSP)

    let rfc6381Codec = sps.rfc6381Codec()
    let dims = try sps.pixelDimensions()
    guard let width = UInt16(exactly: dims.0), let height = UInt16(exactly: dims.1) else {
      throw RTSPError.depacketizationError(
        "SPS has invalid pixel dimensions: \(dims.0)x\(dims.1) is too large")
    }

    var pixelAspectRatio: (h: UInt32, v: UInt32)?
    var frameRate: (num: UInt32, den: UInt32)?
    if let vui = sps.vui {
      pixelAspectRatio = vui.aspectRatio
      if let timing = vui.timingInfo {
        frameRate = (num: timing.numUnitsInTick, den: timing.timeScale)
      }
    }

    let record = buildHEVCDecoderConfigurationRecord(
      sps: sps, pps: pps,
      rawVPS: vpsNAL, rawSPS: spsNAL, rawPPS: ppsNAL)

    let params = VideoParameters(
      rfc6381Codec: rfc6381Codec,
      pixelDimensions: (width: width, height: height),
      pixelAspectRatio: pixelAspectRatio,
      frameRate: frameRate,
      codecParams: .h265(vps: vpsNAL, sps: spsNAL, pps: ppsNAL),
      extraData: record)

    return H265Parameters(
      genericParameters: params,
      vpsNAL: vpsNAL,
      spsNAL: spsNAL,
      ppsNAL: ppsNAL)
  }
}

// MARK: - HEVCDecoderConfigurationRecord

/// Build an HEVCDecoderConfigurationRecord (ISO/IEC 14496-15).
///
/// Always declares `lengthSizeMinusOne` of 3, meaning that NAL units are
/// prefixed with a 4-byte length.
func buildHEVCDecoderConfigurationRecord(
  sps: H265Sps, pps: H265Pps,
  rawVPS: Data, rawSPS: Data, rawPPS: Data
) -> Data {
  var record = Data()

  // configurationVersion = 1
  record.append(1)

  // Profile (11 bytes)
  let profile = sps.profile()
  record.append(contentsOf: profile.data)

  // general_level_idc
  record.append(sps.generalLevelIdc())

  // min_spatial_segmentation_idc with reserved bits
  let minSpatialSegIdc: UInt16 = sps.vui?.minSpatialSegmentationIdc ?? 0
  let segBytes = (0b1111_0000_0000_0000 | minSpatialSegIdc).bigEndian
  withUnsafeBytes(of: segBytes) { record.append(contentsOf: $0) }

  // parallelismType
  let parallelismType: UInt8
  if minSpatialSegIdc == 0 {
    parallelismType = 0
  } else {
    switch (pps.entropyCodingSyncEnabledFlag, pps.tilesEnabledFlag) {
    case (true, true): parallelismType = 0
    case (true, false): parallelismType = 3
    case (false, true): parallelismType = 2
    case (false, false): parallelismType = 1
    }
  }
  record.append(0b1111_1100 | parallelismType)

  // chromaFormat, bitDepthLuma, bitDepthChroma
  record.append(0b1111_1100 | sps.chromaFormatIdc)
  record.append(0b1111_1000 | sps.bitDepthLumaMinus8)
  record.append(0b1111_1000 | sps.bitDepthChromaMinus8)

  // avgFrameRate (0)
  record.append(contentsOf: [0, 0])

  // constantFrameRate(2) + numTemporalLayers(3) + temporalIdNested(1) + lengthSizeMinusOne(2)
  record.append(
    (sps.maxSubLayers << 3)
      | (sps.temporalIdNestingFlag ? (1 << 2) : 0)
      | 0b0000_0011)

  // numOfArrays = 3 (VPS, SPS, PPS)
  record.append(3)

  // VPS array
  appendNALArray(&record, unitType: .vpsNut, nal: rawVPS)
  // SPS array
  appendNALArray(&record, unitType: .spsNut, nal: rawSPS)
  // PPS array
  appendNALArray(&record, unitType: .ppsNut, nal: rawPPS)

  return record
}

/// Append a single-NAL array entry to the record.
private func appendNALArray(
  _ record: inout Data, unitType: H265UnitType, nal: Data
) {
  // array_completeness(1) + reserved(1) + NAL_unit_type(6)
  record.append(0b1000_0000 | unitType.rawValue)
  // numNalus = 1
  record.append(contentsOf: [0, 1])
  // nalUnitLength
  let len = UInt16(nal.count)
  record.append(UInt8(len >> 8))
  record.append(UInt8(len & 0xFF))
  // nalUnit
  record.append(nal)
}
