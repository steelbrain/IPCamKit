// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/codec/h264.rs InternalParameters

import Foundation

/// Internal H.264 parameters (SPS + PPS), used by the depacketizer to track
/// codec parameter changes.
struct H264Parameters: Sendable, Equatable {
  var genericParameters: VideoParameters
  var spsNAL: Data
  var ppsNAL: Data

  /// Parse format-specific parameters from SDP fmtp attribute.
  ///
  /// Expected format: `packetization-mode=1;profile-level-id=...;sprop-parameter-sets=<base64>,<base64>`
  static func parseFormatSpecificParams(_ fmtp: String) throws -> H264Parameters {
    guard !fmtp.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw RTSPError.depacketizationError("empty format-specific params")
    }

    var spsNAL: Data?
    var ppsNAL: Data?

    // Find sprop-parameter-sets
    for param in fmtp.split(separator: ";") {
      let trimmed = param.trimmingCharacters(in: .whitespaces)
      let kv = trimmed.split(separator: "=", maxSplits: 1)
      guard kv.count == 2 else { continue }
      let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
      guard key == "sprop-parameter-sets" else { continue }

      let sets = kv[1].split(separator: ",")
      for setStr in sets {
        let b64 = setStr.trimmingCharacters(in: .whitespaces)
        guard let decoded = Data(base64Encoded: b64) else { continue }
        guard !decoded.isEmpty else { continue }

        // Process through Annex B to handle cameras that include start codes
        var nals: [Data] = []
        let annexBResult = processAnnexB(decoded) { nal in
          nals.append(nal)
          return .success(())
        }
        if case .failure(let err) = annexBResult {
          throw RTSPError.depacketizationError(err.description)
        }
        if nals.isEmpty {
          nals = [decoded]
        }

        for nal in nals {
          guard !nal.isEmpty else { continue }
          let hdr = NALHeader(nal[nal.startIndex])
          switch hdr.nalUnitTypeId {
          case 7:  // SPS
            guard spsNAL == nil else {
              throw RTSPError.depacketizationError("Multiple SPS NALs in sprop-parameter-sets")
            }
            spsNAL = nal
          case 8:  // PPS
            guard ppsNAL == nil else {
              throw RTSPError.depacketizationError("Multiple PPS NALs in sprop-parameter-sets")
            }
            ppsNAL = nal
          default:
            throw RTSPError.depacketizationError(
              "Unexpected NAL type \(hdr.nalUnitTypeId) in sprop-parameter-sets")
          }
        }
      }
    }

    guard let sps = spsNAL, let pps = ppsNAL else {
      throw RTSPError.depacketizationError(
        "Missing SPS or PPS in sprop-parameter-sets")
    }

    return try parseSPSAndPPS(sps: sps, pps: pps)
  }

  /// Parse SPS and PPS NALs into H264Parameters.
  ///
  /// Builds AVCDecoderConfiguration record (ISO/IEC 14496-15 section 5.2.4.1).
  static func parseSPSAndPPS(sps spsNAL: Data, pps ppsNAL: Data) throws -> H264Parameters {
    // Decode SPS RBSP (skip NAL header byte for rbsp decoding)
    let spsRBSP = decodeRBSP(spsNAL)
    guard spsRBSP.count >= 4 else {
      throw RTSPError.depacketizationError("SPS RBSP too short")
    }

    // Build RFC 6381 codec string from first 3 bytes of SPS RBSP (after NAL header)
    let profileIdc = spsRBSP[spsRBSP.startIndex + 1]
    let constraintFlags = spsRBSP[spsRBSP.startIndex + 2]
    let levelIdc = spsRBSP[spsRBSP.startIndex + 3]
    let rfc6381Codec = String(
      format: "avc1.%02X%02X%02X", profileIdc, constraintFlags, levelIdc)

    // Parse SPS for dimensions and VUI
    let parsedSPS = try parseSPS(spsNAL)

    // Build AVCDecoderConfiguration
    //  configurationVersion = 1
    //  profile_idc, constraint_flags, level_idc
    //  lengthSizeMinusOne = 3 (0xFF = reserved(6) + lengthSizeMinusOne(2))
    //  numSPS = 1 (0xE1 = reserved(3) + numSPS(5))
    //  [u16 BE sps length][sps bytes]
    //  numPPS = 1
    //  [u16 BE pps length][pps bytes]
    guard spsNAL.count <= 0xFFFF else {
      throw RTSPError.depacketizationError(
        "SPS NAL is \(spsNAL.count) bytes long; must fit in u16")
    }
    guard ppsNAL.count <= 0xFFFF else {
      throw RTSPError.depacketizationError(
        "PPS NAL is \(ppsNAL.count) bytes long; must fit in u16")
    }

    var config = Data(capacity: 11 + spsNAL.count + ppsNAL.count)
    config.append(1)  // configurationVersion
    config.append(profileIdc)
    config.append(constraintFlags)
    config.append(levelIdc)
    config.append(0xFF)  // lengthSizeMinusOne = 3
    config.append(0xE1)  // numSPS = 1
    config.append(UInt8(spsNAL.count >> 8))
    config.append(UInt8(spsNAL.count & 0xFF))
    config.append(spsNAL)
    config.append(1)  // numPPS
    config.append(UInt8(ppsNAL.count >> 8))
    config.append(UInt8(ppsNAL.count & 0xFF))
    config.append(ppsNAL)

    let params = VideoParameters(
      rfc6381Codec: rfc6381Codec,
      pixelDimensions: (width: parsedSPS.width, height: parsedSPS.height),
      pixelAspectRatio: parsedSPS.pixelAspectRatio,
      frameRate: parsedSPS.frameRate,
      codecParams: .h264(sps: spsNAL, pps: ppsNAL),
      extraData: config
    )

    return H264Parameters(
      genericParameters: params,
      spsNAL: spsNAL,
      ppsNAL: ppsNAL
    )
  }
}
