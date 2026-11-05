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
  /// Also runs `validateTransmissionMode`.
  static func parseFormatSpecificParams(_ fmtp: String) throws -> H265Parameters {
    try validateTransmissionMode(fmtp)

    var spsNAL: Data?
    var ppsNAL: Data?
    var vpsNAL: Data?

    for (key, value) in fmtpPairs(fmtp) {
      switch key {
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

  /// Throw if the fmtp describes a stream the depacketizer can't handle: a
  /// `tx-mode` other than SRST, or `sprop-max-don-diff` > 0. DONL/DOND decoding
  /// is not implemented (SRST without DON only); with a nonzero value the
  /// camera adds DONL fields to its packets, which would be misread as NAL
  /// data. Kept apart from parsing the parameter sets so a caller that falls
  /// back to in-band parameters on a bad sprop-* value still fails loud here
  /// rather than silently emitting corrupt frames.
  static func validateTransmissionMode(_ fmtp: String) throws {
    for (key, value) in fmtpPairs(fmtp) {
      switch key {
      case "tx-mode":
        guard value.uppercased() == "SRST" else {
          throw RTSPError.depacketizationError(
            "unsupported/unexpected tx-mode \(cutForMessage(value)); expected SRST")
        }
      case "sprop-max-don-diff":
        if let n = Int(value), n > 0 {
          throw RTSPError.depacketizationError(
            "unsupported sprop-max-don-diff=\(n); DONL/DOND decoding not implemented")
        }
      default:
        break
      }
    }
  }

  /// The `key=value` pairs of an fmtp string, with keys lowercased (cameras
  /// emit Sprop-VPS, tx-mode=srst). Values keep their case: base64 NALs are
  /// case-significant. Empty tokens (a trailing ';') and flag-style tokens
  /// lacking '=' are skipped rather than rejecting the whole fmtp (matches the
  /// H264 parser; a real camera's stray token must not drop the parameter sets).
  /// Produced one at a time, as the fmtp can be as large as the SDP.
  private static func fmtpPairs(_ fmtp: String) -> some Sequence<(key: String, value: String)> {
    fmtp.lazySplit(separator: ";").lazy.compactMap { p -> (key: String, value: String)? in
      let trimmed = p.trimmingCharacters(in: .whitespaces)
      guard let eqIdx = trimmed.firstIndex(of: "=") else { return nil }
      let key = trimmed[..<eqIdx].trimmingCharacters(in: .whitespaces).lowercased()
      let value = trimmed[trimmed.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
      return (key: key, value: value)
    }
  }

  private static func storeSpropNAL(
    key: String, value: String, out: inout Data?
  ) throws {
    guard out == nil else {
      throw RTSPError.depacketizationError("multiple \(key) parameters")
    }
    // RFC 7798 7.1: the value is a comma-separated list of base64 NAL units.
    // Take the first valid NAL — the struct holds a single VPS/SPS/PPS, and the
    // RFC requires later entries be consistent with the first.
    for element in value.lazySplit(separator: ",") {
      let b64 = element.trimmingCharacters(in: .whitespaces)
      guard !b64.isEmpty else { continue }
      guard let decoded = decodeSpropBase64(b64) else {
        throw RTSPError.depacketizationError(
          "bad parameter \(key): NAL has invalid base64 encoding")
      }
      let nal = stripAnnexBStartCode(decoded)
      guard !nal.isEmpty else {
        throw RTSPError.depacketizationError("bad parameter \(key): empty NAL")
      }
      out = nal
      break
    }
    guard out != nil else {
      throw RTSPError.depacketizationError("bad parameter \(key): no NAL units")
    }
  }

  /// Strip a single leading Annex B start code (`00 00 01` or `00 00 00 01`)
  /// that some cameras prepend to a base64 sprop NAL, mirroring the H264 path.
  /// Only a leading prefix is removed, so trailing bytes (and emulation-
  /// prevention sequences) of a bare NAL are left untouched.
  private static func stripAnnexBStartCode(_ d: Data) -> Data {
    let s = d.startIndex
    if d.count >= 4, d[s] == 0, d[s + 1] == 0, d[s + 2] == 0, d[s + 3] == 1 {
      return d.subdata(in: (s + 4)..<d.endIndex)
    }
    if d.count >= 3, d[s] == 0, d[s + 1] == 0, d[s + 2] == 1 {
      return d.subdata(in: (s + 3)..<d.endIndex)
    }
    return d
  }

  /// Parse VPS, SPS, and PPS NALs and build parameters.
  static func parseVPSSPSPPS(
    vps vpsNAL: Data, sps spsNAL: Data, pps ppsNAL: Data
  ) throws -> H265Parameters {
    // The HEVCDecoderConfigurationRecord stores each NAL length in a u16, so a
    // parameter NAL over 65535 bytes would trap building it. Reject it before
    // any splitting or RBSP decoding, mirroring the H264 path: the depacketizer
    // offers an oversized set again with every frame that carries it. (No real
    // camera emits a >64 KiB parameter set.)
    guard vpsNAL.count <= 0xFFFF, spsNAL.count <= 0xFFFF, ppsNAL.count <= 0xFFFF else {
      throw RTSPError.depacketizationError(
        "VPS/SPS/PPS NAL exceeds 65535 bytes; cannot fit the HEVC record u16 length")
    }

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
      // Both must be > 0 (H.265 E.3.1); drop a zero rather than report a
      // meaningless or divide-by-zero rate, as the H.264 path does.
      if let timing = vui.timingInfo, timing.numUnitsInTick > 0, timing.timeScale > 0 {
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
