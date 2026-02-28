// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/codec/aac.rs - AudioSpecificConfig + fmtp parsing

import Foundation

/// A channel configuration as in ISO/IEC 14496-3 Table 1.19.
struct ChannelConfig: Sendable {
  let channels: UInt16
  /// The "number of considered channels" (non-subwoofer channels).
  let ncc: UInt16
  let name: String
}

/// Channel configuration table indexed by channelConfiguration value (0-7).
let channelConfigs: [ChannelConfig?] = [
  nil,  // 0: defined in AOT related SpecificConfig
  ChannelConfig(channels: 1, ncc: 1, name: "mono"),  // 1
  ChannelConfig(channels: 2, ncc: 2, name: "stereo"),  // 2
  ChannelConfig(channels: 3, ncc: 3, name: "3.0"),  // 3
  ChannelConfig(channels: 4, ncc: 4, name: "4.0"),  // 4
  ChannelConfig(channels: 5, ncc: 5, name: "5.0"),  // 5
  ChannelConfig(channels: 6, ncc: 5, name: "5.1"),  // 6
  ChannelConfig(channels: 8, ncc: 7, name: "7.1"),  // 7
]

/// An AudioSpecificConfig as in ISO/IEC 14496-3 section 1.6.2.1.
struct AudioSpecificConfig: Sendable {
  var parameters: AudioParameters
  var frameLength: UInt16
  var channels: ChannelConfig
}

extension AudioSpecificConfig {
  /// Parses an AudioSpecificConfig from raw bytes.
  static func parse(_ raw: Data) throws -> AudioSpecificConfig {
    var r = BitReader(raw)

    // audioObjectType (5 bits, extended if 31)
    guard let aotRaw = r.readBits(5) else {
      throw DepacketizeError("unable to read audio_object_type")
    }
    let audioObjectType: UInt32
    if aotRaw == 31 {
      guard let ext = r.readBits(6) else {
        throw DepacketizeError("unable to read audio_object_type ext")
      }
      audioObjectType = 32 + ext
    } else {
      audioObjectType = aotRaw
    }

    // samplingFrequencyIndex (4 bits)
    guard let freqIdx = r.readBits(4) else {
      throw DepacketizeError("unable to read sampling_frequency")
    }
    let samplingFrequency: UInt32
    switch freqIdx {
    case 0x0: samplingFrequency = 96_000
    case 0x1: samplingFrequency = 88_200
    case 0x2: samplingFrequency = 64_000
    case 0x3: samplingFrequency = 48_000
    case 0x4: samplingFrequency = 44_100
    case 0x5: samplingFrequency = 32_000
    case 0x6: samplingFrequency = 24_000
    case 0x7: samplingFrequency = 22_050
    case 0x8: samplingFrequency = 16_000
    case 0x9: samplingFrequency = 12_000
    case 0xa: samplingFrequency = 11_025
    case 0xb: samplingFrequency = 8_000
    case 0xc: samplingFrequency = 7_350
    case 0xd, 0xe:
      throw DepacketizeError(
        "reserved sampling_frequency_index value 0x\(String(freqIdx, radix: 16))")
    case 0xf:
      guard let extFreq = r.readBits(24) else {
        throw DepacketizeError("unable to read sampling_frequency ext")
      }
      samplingFrequency = extFreq
    default:
      fatalError("unreachable")
    }

    // channelConfiguration (4 bits)
    guard let channelsConfigId = r.readBits(4).map(UInt8.init) else {
      throw DepacketizeError("unable to read channels")
    }
    guard Int(channelsConfigId) < channelConfigs.count else {
      throw DepacketizeError(
        "reserved channelConfiguration 0x\(String(channelsConfigId, radix: 16))")
    }
    guard let channels = channelConfigs[Int(channelsConfigId)] else {
      throw DepacketizeError("program_config_element parsing unimplemented")
    }
    guard channelsConfigId > 0 else {
      throw DepacketizeError("program_config_element parsing unimplemented")
    }

    // SBR/PS extensions
    if audioObjectType == 5 || audioObjectType == 29 {
      if let extFreqIdx = r.readBits(4), extFreqIdx == 0xf {
        r.skip(24)
      }
      if let secondAot = r.readBits(5), secondAot == 22 {
        r.skip(4)
      }
    }

    // Validate supported audio object types (ones using GASpecificConfig)
    switch audioObjectType {
    case 1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22, 23:
      break
    default:
      throw DepacketizeError("unsupported audio_object_type \(audioObjectType)")
    }

    // GASpecificConfig, ISO/IEC 14496-3 section 4.4.1.
    guard let frameLengthFlag = r.readBits(1) else {
      throw DepacketizeError("unable to read frame_length_flag")
    }
    let frameLength: UInt16
    switch (audioObjectType, frameLengthFlag != 0) {
    case (3, false):  // AAC SSR
      frameLength = 256
    case (3, true):
      throw DepacketizeError("frame_length_flag must be false for AAC SSR")
    case (23, false):  // ER AAC LD
      frameLength = 512
    case (23, true):
      frameLength = 480
    case (_, false):
      frameLength = 1024
    case (_, true):
      frameLength = 960
    }

    let rfc6381Codec = "mp4a.40.\(audioObjectType)"

    return AudioSpecificConfig(
      parameters: AudioParameters(
        rfc6381Codec: rfc6381Codec,
        frameLength: UInt32(frameLength),
        clockRate: samplingFrequency,
        extraData: Data(raw),
        codec: .aac(channelsConfigId: channelsConfigId)
      ),
      frameLength: frameLength,
      channels: channels
    )
  }
}

/// Parses metadata from the `format-specific-params` of an SDP `fmtp` attribute.
/// The metadata is defined in RFC 3640 section 4.1.
func parseAACFormatSpecificParams(
  clockRate: UInt32, formatSpecificParams: String
) throws -> AudioSpecificConfig {
  var mode: String?
  var config: Data?
  var sizeLength: UInt16?
  var indexLength: UInt16?
  var indexDeltaLength: UInt16?

  for p in formatSpecificParams.split(separator: ";") {
    let trimmed = p.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { continue }  // Reolink cameras leave a trailing ';'

    guard let eqIdx = trimmed.firstIndex(of: "=") else {
      throw DepacketizeError("bad format-specific-param \(trimmed)")
    }
    let key = trimmed[trimmed.startIndex..<eqIdx].lowercased()
    let value = String(trimmed[trimmed.index(after: eqIdx)...])

    switch key {
    case "config":
      config = try hexDecode(value)
    case "mode":
      mode = value
    case "sizelength":
      sizeLength = UInt16(value)
    case "indexlength":
      indexLength = UInt16(value)
    case "indexdeltalength":
      indexDeltaLength = UInt16(value)
    default:
      break
    }
  }

  guard mode == "AAC-hbr" else {
    throw DepacketizeError("Expected mode AAC-hbr, got \(mode ?? "nil")")
  }
  guard let configData = config else {
    throw DepacketizeError("config must be specified")
  }
  guard sizeLength == 13, indexLength == 3, indexDeltaLength == 3 else {
    throw DepacketizeError(
      "Unexpected sizeLength=\(sizeLength.map(String.init) ?? "nil") "
        + "indexLength=\(indexLength.map(String.init) ?? "nil") "
        + "indexDeltaLength=\(indexDeltaLength.map(String.init) ?? "nil")")
  }

  let parsed = try AudioSpecificConfig.parse(configData)

  guard clockRate == parsed.parameters.clockRate else {
    throw DepacketizeError(
      "Expected RTP clock rate \(clockRate) and AAC sampling frequency \(parsed.parameters.clockRate) to match"
    )
  }

  return parsed
}

/// Decode a hex string to Data.
private func hexDecode(_ hex: String) throws -> Data {
  let chars = Array(hex)
  guard chars.count % 2 == 0 else {
    throw DepacketizeError("config has invalid hex encoding")
  }
  var data = Data(capacity: chars.count / 2)
  for i in stride(from: 0, to: chars.count, by: 2) {
    guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else {
      throw DepacketizeError("config has invalid hex encoding")
    }
    data.append(byte)
  }
  return data
}
