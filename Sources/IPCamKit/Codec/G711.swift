// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// ITU-T G.711 mu-law (PCMU) and A-law (PCMA) encoders and decoders.

import Foundation

/// ITU-T G.711 mu-law (PCMU) and A-law (PCMA) companding.
///
/// Use the encoders to turn 16-bit linear PCM into the payload of an RTP `PCMU` or `PCMA`
/// stream (RFC 3551), for example audio sent to a camera's ONVIF backchannel, and the
/// decoders to turn received G.711 audio back into linear PCM. Each sample becomes one byte
/// and vice versa; the sample rate is unchanged (8000 Hz for standard PCMU/PCMA).
///
/// The encoders follow the classic Sun Microsystems `g711.c` reference algorithm, which
/// quantizes on the G.711 decision levels. Other encoders can pick the neighboring level
/// for inputs near a decision level (ffmpeg, for example, puts its thresholds midway
/// between output levels on a 14-bit grid). All G.711 decoders produce the same levels.
public enum G711 {
  /// Bias added to the mu-law magnitude before segment search (Sun `g711.c` `BIAS`).
  private static let muLawBias = 0x84
  /// Largest mu-law magnitude before the bias is added (Sun `g711.c` `CLIP`).
  private static let muLawClip = 32635

  /// Encodes 16-bit linear PCM samples as G.711 mu-law (PCMU).
  ///
  /// - Parameter samples: Signed 16-bit linear PCM samples, one per channel per instant.
  /// - Returns: One mu-law byte per input sample, in the same order. Magnitudes above
  ///   32635 are clipped to the largest code.
  public static func encodeMuLaw(_ samples: [Int16]) -> Data {
    Data(samples.map(muLaw(from:)))
  }

  /// Encodes 16-bit linear PCM samples as G.711 A-law (PCMA).
  ///
  /// - Parameter samples: Signed 16-bit linear PCM samples, one per channel per instant.
  /// - Returns: One A-law byte per input sample, in the same order.
  public static func encodeALaw(_ samples: [Int16]) -> Data {
    Data(samples.map(aLaw(from:)))
  }

  /// Decodes G.711 mu-law (PCMU) bytes to 16-bit linear PCM.
  ///
  /// - Parameter data: mu-law bytes, for example an RTP PCMU payload. Every byte value is
  ///   a valid code, so decoding cannot fail.
  /// - Returns: One sample per input byte, in the range -32124...32124.
  public static func decodeMuLaw(_ data: Data) -> [Int16] {
    data.map { muLawTable[Int($0)] }
  }

  /// Decodes G.711 A-law (PCMA) bytes to 16-bit linear PCM.
  ///
  /// - Parameter data: A-law bytes, for example an RTP PCMA payload. Every byte value is
  ///   a valid code, so decoding cannot fail.
  /// - Returns: One sample per input byte, in the range -32256...32256.
  public static func decodeALaw(_ data: Data) -> [Int16] {
    data.map { aLawTable[Int($0)] }
  }

  // MARK: - Per-sample reference algorithm

  /// Number of significant bits in a non-negative value (0 for 0).
  private static func bitLength(_ value: Int) -> Int {
    Int.bitWidth - value.leadingZeroBitCount
  }

  /// Sun `g711.c` `linear2ulaw` for a 16-bit sample.
  static func muLaw(from sample: Int16) -> UInt8 {
    var magnitude = Int(sample)
    let mask: UInt8
    if magnitude < 0 {
      magnitude = -magnitude
      mask = 0x7F
    } else {
      mask = 0xFF
    }
    magnitude = min(magnitude, muLawClip) + muLawBias  // 132...32767
    // Segment = index of the first `seg_end` entry (0xFF, 0x1FF, ..., 0x7FFF) that is
    // >= magnitude, which is the bit length minus 8.
    let segment = max(0, bitLength(magnitude) - 8)
    let quantization = (magnitude >> (segment + 3)) & 0x0F
    return (UInt8(segment << 4) | UInt8(quantization)) ^ mask
  }

  /// Sun `g711.c` `linear2alaw` for a 16-bit sample.
  static func aLaw(from sample: Int16) -> UInt8 {
    var magnitude = Int(sample) >> 3  // 13-bit two's complement
    let mask: UInt8
    if magnitude >= 0 {
      mask = 0xD5  // sign bit set, even bits inverted
    } else {
      mask = 0x55  // even bits inverted
      magnitude = -magnitude - 1  // one's complement: 0...4095
    }
    // Segment = index of the first `seg_aend` entry (0x1F, 0x3F, ..., 0xFFF) that is
    // >= magnitude, which is the bit length minus 5.
    let segment = max(0, bitLength(magnitude) - 5)
    let quantization = (magnitude >> (segment < 2 ? 1 : segment)) & 0x0F
    return (UInt8(segment << 4) | UInt8(quantization)) ^ mask
  }

  /// Sun `g711.c` `ulaw2linear`.
  static func linear(fromMuLaw code: UInt8) -> Int16 {
    let u = ~code
    let segment = Int((u & 0x70) >> 4)
    let level = ((Int(u & 0x0F) << 3) + muLawBias) << segment  // at most 32256
    return Int16((u & 0x80) != 0 ? muLawBias - level : level - muLawBias)
  }

  /// Sun `g711.c` `alaw2linear`.
  static func linear(fromALaw code: UInt8) -> Int16 {
    let a = code ^ 0x55
    let segment = Int((a & 0x70) >> 4)
    var level = Int(a & 0x0F) << 4
    switch segment {
    case 0: level += 8
    case 1: level += 0x108
    default: level = (level + 0x108) << (segment - 1)  // at most 32256
    }
    return Int16((a & 0x80) != 0 ? level : -level)
  }

  private static let muLawTable: [Int16] = (0...255).map { linear(fromMuLaw: UInt8($0)) }
  private static let aLawTable: [Int16] = (0...255).map { linear(fromALaw: UInt8($0)) }
}
