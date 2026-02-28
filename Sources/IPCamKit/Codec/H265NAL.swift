// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/codec/h265/nal.rs - H.265 NAL header and unit types

import Foundation

/// Whether a unit type is VCL or non-VCL, as defined in T.REC H.265 Table 7-1.
enum H265UnitTypeClass: Sendable, Equatable {
  case vcl(intraCoded: Bool)
  case nonVcl
}

/// NAL unit type, as in T.REC H.265 Table 7-1.
enum H265UnitType: UInt8, Sendable, CaseIterable {
  case trailN = 0
  case trailR = 1
  case tsaN = 2
  case tsaR = 3
  case stsaN = 4
  case stsaR = 5
  case radlN = 6
  case radlR = 7
  case raslN = 8
  case raslR = 9
  case rsvVclN10 = 10
  case rsvVclR11 = 11
  case rsvVclN12 = 12
  case rsvVclR13 = 13
  case rsvVclN14 = 14
  case rsvVclR15 = 15
  case blaWLp = 16
  case blaWRadl = 17
  case blaNLp = 18
  case idrWRadl = 19
  case idrNLp = 20
  case craNut = 21
  case rsvIrapVcl22 = 22
  case rsvIrapVcl23 = 23
  case rsvVcl24 = 24
  case rsvVcl25 = 25
  case rsvVcl26 = 26
  case rsvVcl27 = 27
  case rsvVcl28 = 28
  case rsvVcl29 = 29
  case rsvVcl30 = 30
  case rsvVcl31 = 31
  case vpsNut = 32
  case spsNut = 33
  case ppsNut = 34
  /// Access unit delimiter.
  case audNut = 35
  /// End of sequence.
  case eosNut = 36
  /// End of bitstream.
  case eobNut = 37
  case fdNut = 38
  case prefixSeiNut = 39
  case suffixSeiNut = 40
  case rsvNvcl41 = 41
  case rsvNvcl42 = 42
  case rsvNvcl43 = 43
  case rsvNvcl44 = 44
  case rsvNvcl45 = 45
  case rsvNvcl46 = 46
  case rsvNvcl47 = 47
  case unspec48 = 48
  case unspec49 = 49
  case unspec50 = 50
  case unspec51 = 51
  case unspec52 = 52
  case unspec53 = 53
  case unspec54 = 54
  case unspec55 = 55
  case unspec56 = 56
  case unspec57 = 57
  case unspec58 = 58
  case unspec59 = 59
  case unspec60 = 60
  case unspec61 = 61
  case unspec62 = 62
  case unspec63 = 63

  var unitTypeClass: H265UnitTypeClass {
    switch self {
    case .idrWRadl, .idrNLp:
      return .vcl(intraCoded: true)
    case .trailN, .trailR, .tsaN, .tsaR, .stsaN, .stsaR,
      .radlN, .radlR, .raslN, .raslR,
      .rsvVclN10, .rsvVclR11, .rsvVclN12, .rsvVclR13,
      .rsvVclN14, .rsvVclR15,
      .blaWLp, .blaWRadl, .blaNLp,
      .craNut, .rsvIrapVcl22, .rsvIrapVcl23,
      .rsvVcl24, .rsvVcl25, .rsvVcl26, .rsvVcl27,
      .rsvVcl28, .rsvVcl29, .rsvVcl30, .rsvVcl31:
      return .vcl(intraCoded: false)
    default:
      return .nonVcl
    }
  }
}

/// `nal_unit_header` as in T.REC H.265 section 7.3.1.2.
///
/// ```
/// 0                   1
/// 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |F|ttttttttttttt|lllllllll|TTTTT|
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///
/// F: forbidden_zero_bit, must be 0.
/// t: unit_type, in [0, 63].
/// l: nuh_layer_id, in [0, 63].
/// T: nuh_temporal_id_plus1, in [1, 7].
/// ```
struct H265NALHeader: Sendable, Equatable {
  let byte0: UInt8
  let byte1: UInt8

  /// Parse from 2-byte NAL header.
  /// Validates forbidden zero bit and temporal_id_plus1 != 0.
  init(byte0: UInt8, byte1: UInt8) throws {
    if (byte0 & 0b1000_0000) != 0 {
      throw DepacketizeError(
        "forbidden zero bit is set in NAL header 0x\(String(format: "%02X%02X", byte0, byte1))"
      )
    }
    if (byte1 & 0b111) == 0 {
      throw DepacketizeError(
        "zero temporal_id_plus1 in NAL header 0x\(String(format: "%02X%02X", byte0, byte1))"
      )
    }
    self.byte0 = byte0
    self.byte1 = byte1
  }

  /// The NAL unit type.
  var unitType: H265UnitType {
    // 6-bit value must be valid
    H265UnitType(rawValue: byte0 >> 1)!
  }

  /// The `nuh_layer_id`, as a 6-bit value.
  var nuhLayerId: UInt8 {
    (byte0 & 0b1) << 5 | (byte1 >> 3)
  }

  /// The `nuh_temporal_id_plus1`, as a non-zero 3-bit value.
  var nuhTemporalIdPlus1: UInt8 {
    byte1 & 0b111
  }

  /// Returns a new header with the given unit type, preserving layer_id and temporal_id.
  func withUnitType(_ t: H265UnitType) -> H265NALHeader {
    let newByte0 = (byte0 & 0b1000_0001) | (t.rawValue << 1)
    // This is safe because we preserve the valid temporal_id_plus1 and clear forbidden bit
    return try! H265NALHeader(byte0: newByte0, byte1: byte1)
  }

  /// The raw 2-byte representation.
  var rawBytes: [UInt8] {
    [byte0, byte1]
  }
}

/// Splits an H.265 NAL unit into its header and the remaining RBSP data.
/// The returned Data does not include the 2-byte NAL header.
func h265SplitNAL(_ nal: Data) throws -> (H265NALHeader, Data) {
  guard nal.count >= 2 else {
    throw DepacketizeError("NAL unit too short")
  }
  let header = try H265NALHeader(byte0: nal[nal.startIndex], byte1: nal[nal.startIndex + 1])
  let rest = nal.count > 2 ? Data(nal[(nal.startIndex + 2)...]) : Data()
  return (header, rest)
}
