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
  /// Decoder output parameters: `clockRate` is the output sampling rate (the
  /// SBR extension rate for explicitly signaled HE-AAC) and `frameLength` is
  /// the output samples per AU at that rate (2048 for dual-rate SBR).
  var parameters: AudioParameters
  /// Samples per AU at `coreSamplingFrequency` (1024, 960, 512, 480 or 256).
  var frameLength: UInt16
  /// The sampling rate of the core AAC decoder: the ASC's first
  /// samplingFrequencyIndex. Equal to `parameters.clockRate` unless SBR is
  /// explicitly signaled.
  var coreSamplingFrequency: UInt32
  var channels: ChannelConfig
}

/// Reads a GetAudioObjectType() value (5 bits; 31 escapes to 32 + 6 bits).
private func readAudioObjectType(_ r: inout BitReader, _ field: String) throws -> UInt32 {
  guard let aotRaw = r.readBits(5) else {
    throw DepacketizeError("unable to read \(field)")
  }
  guard aotRaw == 31 else { return aotRaw }
  guard let ext = r.readBits(6) else {
    throw DepacketizeError("unable to read \(field) ext")
  }
  return 32 + ext
}

/// Reads a samplingFrequencyIndex (4 bits; 0xF escapes to a 24-bit value).
private func readSamplingFrequency(_ r: inout BitReader, _ field: String) throws -> UInt32 {
  guard let freqIdx = r.readBits(4) else {
    throw DepacketizeError("unable to read \(field)")
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
      "reserved \(field) index value 0x\(String(freqIdx, radix: 16))")
  case 0xf:
    guard let extFreq = r.readBits(24) else {
      throw DepacketizeError("unable to read \(field) ext")
    }
    guard extFreq > 0 else {
      throw DepacketizeError("\(field) is 0")
    }
    samplingFrequency = extFreq
  default:
    fatalError("unreachable")
  }
  return samplingFrequency
}

extension AudioSpecificConfig {
  /// Parses an AudioSpecificConfig from raw bytes.
  ///
  /// Supports the GASpecificConfig object types (AAC Main/LC/SSR/LTP, AAC
  /// scalable, TwinVQ and their ER variants), also as the core of explicitly
  /// signaled SBR (object type 5, HE-AAC) or SBR+PS (29, HE-AAC v2).
  static func parse(_ raw: Data) throws -> AudioSpecificConfig {
    var r = BitReader(raw)

    let signaledObjectType = try readAudioObjectType(&r, "audio_object_type")
    let coreFrequency = try readSamplingFrequency(&r, "sampling_frequency")

    // channelConfiguration (4 bits)
    guard let channelsConfigId = r.readBits(4).map(UInt8.init) else {
      throw DepacketizeError("unable to read channels")
    }
    guard Int(channelsConfigId) < channelConfigs.count else {
      throw DepacketizeError(
        "reserved channelConfiguration 0x\(String(channelsConfigId, radix: 16))")
    }
    // channelConfiguration 0 ("defined in AOT-related config") maps to nil here,
    // so this unwrap already rejects it — no separate `> 0` guard needed.
    guard let channels = channelConfigs[Int(channelsConfigId)] else {
      throw DepacketizeError("program_config_element parsing unimplemented")
    }

    // Explicit SBR / PS signaling (ISO/IEC 14496-3 section 1.6.2.1): the
    // extension (output) sampling frequency, then the core object type, then
    // for an ER BSAC core an extensionChannelConfiguration.
    var audioObjectType = signaledObjectType
    var outputFrequency = coreFrequency
    let explicitSBR = signaledObjectType == 5 || signaledObjectType == 29
    if explicitSBR {
      outputFrequency = try readSamplingFrequency(&r, "extension_sampling_frequency")
      audioObjectType = try readAudioObjectType(&r, "core audio_object_type")
      if audioObjectType == 22 {
        guard r.readBits(4) != nil else {
          throw DepacketizeError("unable to read extension_channel_configuration")
        }
      }
    }

    // Validate supported audio object types (ones using GASpecificConfig)
    switch audioObjectType {
    case 1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22, 23:
      break
    default:
      if explicitSBR {
        throw DepacketizeError(
          "unsupported core audio_object_type \(audioObjectType) for "
            + "audio_object_type \(signaledObjectType)")
      }
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

    // SBR outputs either at the core rate (downsampled SBR) or at twice it,
    // with as many more samples per AU.
    let sbrRatio: UInt32
    switch outputFrequency {
    case coreFrequency: sbrRatio = 1
    case coreFrequency * 2: sbrRatio = 2
    default:
      throw DepacketizeError(
        "unsupported SBR extension sampling frequency \(outputFrequency) for "
          + "core sampling frequency \(coreFrequency)")
    }

    let rfc6381Codec = "mp4a.40.\(signaledObjectType)"

    return AudioSpecificConfig(
      parameters: AudioParameters(
        rfc6381Codec: rfc6381Codec,
        frameLength: UInt32(frameLength) * sbrRatio,
        clockRate: outputFrequency,
        extraData: Data(raw),
        codec: .aac(channelsConfigId: channelsConfigId)
      ),
      frameLength: frameLength,
      coreSamplingFrequency: coreFrequency,
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

  for p in formatSpecificParams.lazySplit(separator: ";") {
    let trimmed = p.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { continue }  // Reolink cameras leave a trailing ';'

    guard let eqIdx = trimmed.firstIndex(of: "=") else {
      throw DepacketizeError("bad format-specific-param \(cutForMessage(trimmed))")
    }
    // Blanks around `=` are tolerated, as the backchannel packetizer does.
    let key = trimmed[trimmed.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces).lowercased()
    let value = trimmed[trimmed.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)

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
    throw DepacketizeError("Expected mode AAC-hbr, got \(cutForMessage(mode ?? "nil"))")
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

  guard parsed.rtpTicksPerAU(clockRate: clockRate) != nil else {
    throw DepacketizeError(
      "RTP clock rate \(clockRate) is not a small integer multiple of "
        + "AAC sampling frequency \(parsed.coreSamplingFrequency)")
  }

  return parsed
}

extension AudioSpecificConfig {
  /// RTP clock ticks per AU on an RTP clock of `clockRate` Hz: `frameLength`
  /// scaled by the clock rate's multiple of `coreSamplingFrequency`.
  ///
  /// HE-AAC / AAC+SBR commonly signals an RTP clock rate that is a small
  /// integer multiple of the core ASC sampling frequency (e.g. RTP 44100 with a
  /// 22050 core, implicitly or explicitly signaled SBR). nil unless `clockRate`
  /// is 1 to 4 times the core rate.
  func rtpTicksPerAU(clockRate: UInt32) -> UInt32? {
    let coreRate = coreSamplingFrequency
    guard coreRate > 0, clockRate % coreRate == 0, (1...4).contains(clockRate / coreRate) else {
      return nil
    }
    return UInt32(frameLength) * (clockRate / coreRate)
  }
}

/// RTP clock ticks per AU for the AudioSpecificConfig in an fmtp `config=`
/// value (hex), as `AACDepacketizer` counts them; nil when the config doesn't
/// parse or `clockRate` isn't 1 to 4 times its core sampling rate.
func aacRTPTicksPerAU(configHex: String, clockRate: UInt32) -> UInt32? {
  guard let raw = try? hexDecode(configHex),
    let config = try? AudioSpecificConfig.parse(raw)
  else { return nil }
  return config.rtpTicksPerAU(clockRate: clockRate)
}

/// Decode a hex string to Data, reading its UTF-8 bytes (an array of its
/// Characters would take 16 bytes per digit of a value up to the SDP's size).
private func hexDecode(_ hex: String) throws -> Data {
  func digit(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
    default: return nil
    }
  }
  let bytes = hex.utf8
  guard bytes.count % 2 == 0 else {
    throw DepacketizeError("config has invalid hex encoding")
  }
  var data = Data(capacity: bytes.count / 2)
  var high: UInt8?
  for byte in bytes {
    guard let value = digit(byte) else {
      throw DepacketizeError("config has invalid hex encoding")
    }
    if let first = high {
      data.append(first << 4 | value)
      high = nil
    } else {
      high = value
    }
  }
  return data
}
