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
    for param in fmtp.lazySplit(separator: ";") {
      let trimmed = param.trimmingCharacters(in: .whitespaces)
      let kv = trimmed.split(separator: "=", maxSplits: 1)
      guard kv.count == 2 else { continue }
      let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
      guard key == "sprop-parameter-sets" else { continue }

      for setStr in kv[1].lazySplit(separator: ",") {
        let b64 = setStr.trimmingCharacters(in: .whitespaces)
        guard let decoded = decodeSpropBase64(b64) else { continue }
        guard !decoded.isEmpty else { continue }

        // Process through Annex B to handle cameras that include start codes.
        // Each NAL is taken as it is found rather than collected: a value can
        // hold many tiny ones.
        var sawNAL = false
        var unexpectedType: UInt8?
        func take(_ nal: Data) {
          guard !nal.isEmpty else { return }
          let hdr = NALHeader(nal[nal.startIndex])
          switch hdr.nalUnitTypeId {
          // RFC 6184 section 8.1 allows several of each; the first is kept,
          // as for H.265 (the decoder configuration holds one of each).
          case 7:  // SPS
            if spsNAL == nil { spsNAL = nal }
          case 8:  // PPS
            if ppsNAL == nil { ppsNAL = nal }
          default:
            unexpectedType = hdr.nalUnitTypeId
          }
        }
        let annexBResult = processAnnexB(decoded) { nal in
          sawNAL = true
          take(nal)
          return unexpectedType == nil
            ? .success(()) : .failure(DepacketizeError("unexpected NAL type"))
        }
        if !sawNAL, case .success = annexBResult { take(decoded) }
        if let unexpectedType {
          throw RTSPError.depacketizationError(
            "Unexpected NAL type \(unexpectedType) in sprop-parameter-sets")
        }
        if case .failure(let err) = annexBResult {
          throw RTSPError.depacketizationError(err.description)
        }
      }
    }

    guard let sps = spsNAL, let pps = ppsNAL else {
      throw RTSPError.depacketizationError(
        "Missing SPS or PPS in sprop-parameter-sets")
    }

    return try parseSPSAndPPS(sps: sps, pps: pps)
  }

  /// Throw if the fmtp asks for interleaved mode (`packetization-mode=2`,
  /// RFC 6184 section 6.4). Its packets carry decoding order numbers and use
  /// STAP-B, MTAP and FU-B, which the depacketizer doesn't implement, so every
  /// packet would fail. Kept apart from parsing the parameter sets so a caller
  /// that falls back to in-band parameters on a bad sprop value still fails
  /// here.
  static func validatePacketizationMode(_ fmtp: String) throws {
    for param in fmtp.lazySplit(separator: ";") {
      let kv = param.split(separator: "=", maxSplits: 1)
      guard kv.count == 2 else { continue }
      let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
      guard key == "packetization-mode" else { continue }
      let value = kv[1].trimmingCharacters(in: .whitespaces)
      if Int(value) == 2 {
        throw RTSPError.depacketizationError(
          "unsupported H.264 packetization-mode=2 (interleaved mode); "
            + "only modes 0 and 1 are supported")
      }
    }
  }

  /// Parse SPS and PPS NALs into H264Parameters.
  ///
  /// Builds AVCDecoderConfiguration record (ISO/IEC 14496-15 section 5.2.4.1).
  static func parseSPSAndPPS(sps spsNAL: Data, pps ppsNAL: Data) throws -> H264Parameters {
    // The AVCDecoderConfiguration stores each NAL length in a u16. Check this
    // before parsing, so an oversized SPS or PPS (the depacketizer offers it
    // again with every frame that carries it) is rejected without decoding it.
    guard spsNAL.count <= 0xFFFF else {
      throw RTSPError.depacketizationError(
        "SPS NAL is \(spsNAL.count) bytes long; must fit in u16")
    }
    guard ppsNAL.count <= 0xFFFF else {
      throw RTSPError.depacketizationError(
        "PPS NAL is \(ppsNAL.count) bytes long; must fit in u16")
    }

    // Parse the SPS once: parseSPS already decodes the RBSP and returns the
    // profile/constraint/level bytes along with dimensions and VUI, so there is
    // no need to decode and slice the RBSP a second time here.
    let parsedSPS = try parseSPS(spsNAL)
    let profileIdc = parsedSPS.profileIdc
    let constraintFlags = parsedSPS.constraintFlags
    let levelIdc = parsedSPS.levelIdc

    // Build RFC 6381 codec string
    let rfc6381Codec = String(
      format: "avc1.%02X%02X%02X", profileIdc, constraintFlags, levelIdc)

    // Build AVCDecoderConfiguration
    //  configurationVersion = 1
    //  profile_idc, constraint_flags, level_idc
    //  lengthSizeMinusOne = 3 (0xFF = reserved(6) + lengthSizeMinusOne(2))
    //  numSPS = 1 (0xE1 = reserved(3) + numSPS(5))
    //  [u16 BE sps length][sps bytes]
    //  numPPS = 1
    //  [u16 BE pps length][pps bytes]
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

/// Decode one base64 parameter set from an SDP `sprop-*` value. Some cameras
/// leave out the trailing `=` padding, which `Data(base64Encoded:)` rejects,
/// so it is added back first.
func decodeSpropBase64(_ value: String) -> Data? {
  let remainder = value.utf8.count % 4
  guard remainder != 0 else { return Data(base64Encoded: value) }
  return Data(base64Encoded: value + String(repeating: "=", count: 4 - remainder))
}
