// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Replaces upstream h264_reader crate NAL header parsing

import Foundation

/// H.264 NAL unit types (ITU-T H.264 Table 7-1).
enum NALUnitType: UInt8, Sendable {
  case unspecified = 0
  case sliceNonIDR = 1
  case sliceDataPartitionA = 2
  case sliceDataPartitionB = 3
  case sliceDataPartitionC = 4
  case sliceIDR = 5
  case sei = 6
  case sps = 7
  case pps = 8
  case accessUnitDelimiter = 9
  case endOfSequence = 10
  case endOfStream = 11
  case fillerData = 12

  // 13-23 are other/reserved
  // 24 = STAP-A (RTP)
  // 28 = FU-A (RTP)

  /// Whether this is a VCL NAL (video coding layer).
  var isVCL: Bool {
    rawValue >= 1 && rawValue <= 5
  }
}

/// Parsed 1-byte NAL unit header.
///
/// ```
/// +---------------+
/// |0|1|2|3|4|5|6|7|
/// +-+-+-+-+-+-+-+-+
/// |F|NRI|  Type   |
/// +---------------+
/// ```
struct NALHeader: Sendable, Equatable {
  let rawByte: UInt8

  init(_ byte: UInt8) {
    self.rawByte = byte
  }

  /// Forbidden zero bit (should be 0).
  var forbiddenZeroBit: Bool {
    (rawByte & 0x80) != 0
  }

  /// NAL reference indicator (2 bits).
  var nalRefIdc: UInt8 {
    (rawByte >> 5) & 0x03
  }

  /// NAL unit type (5 bits).
  var nalUnitTypeId: UInt8 {
    rawByte & 0x1F
  }

  /// Parsed NAL unit type, or nil if not a recognized type.
  var nalUnitType: NALUnitType? {
    NALUnitType(rawValue: nalUnitTypeId)
  }
}
