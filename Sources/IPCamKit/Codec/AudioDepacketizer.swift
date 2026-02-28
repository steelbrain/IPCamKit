// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Dispatch enum for audio depacketizers, routes to AAC/SimpleAudio/G723

import Foundation

/// Audio depacketizer that dispatches to the appropriate codec implementation.
enum AudioDepacketizer: Sendable {
  case aac(AACDepacketizer)
  case simpleAudio(SimpleAudioDepacketizer)
  case g723(G723Depacketizer)

  /// Creates an audio depacketizer based on encoding name.
  ///
  /// Encoding name matching follows upstream src/codec/mod.rs Depacketizer::new.
  static func create(
    encodingName: String,
    clockRate: UInt32,
    channels: UInt16?,
    formatSpecificParams: String?
  ) throws -> AudioDepacketizer {
    switch encodingName {
    case "mpeg4-generic":
      return .aac(
        try AACDepacketizer(
          clockRate: clockRate,
          channels: channels,
          formatSpecificParams: formatSpecificParams
        ))
    case "g726-16":
      return .simpleAudio(
        SimpleAudioDepacketizer(clockRate: clockRate, bitsPerSample: 2))
    case "g726-24":
      return .simpleAudio(
        SimpleAudioDepacketizer(clockRate: clockRate, bitsPerSample: 3))
    case "dvi4", "g726-32":
      return .simpleAudio(
        SimpleAudioDepacketizer(clockRate: clockRate, bitsPerSample: 4))
    case "g726-40":
      return .simpleAudio(
        SimpleAudioDepacketizer(clockRate: clockRate, bitsPerSample: 5))
    case "pcma", "pcmu", "u8", "g722":
      return .simpleAudio(
        SimpleAudioDepacketizer(clockRate: clockRate, bitsPerSample: 8))
    case "l16":
      return .simpleAudio(
        SimpleAudioDepacketizer(clockRate: clockRate, bitsPerSample: 16))
    case "g723":
      return .g723(try G723Depacketizer(clockRate: clockRate))
    default:
      throw DepacketizeError(
        "no audio depacketizer for encoding \(encodingName)")
    }
  }

  mutating func push(_ pkt: ReceivedRTPPacket) throws {
    switch self {
    case .aac(var d):
      try d.push(pkt)
      self = .aac(d)
    case .simpleAudio(var d):
      try d.push(pkt)
      self = .simpleAudio(d)
    case .g723(var d):
      try d.push(pkt)
      self = .g723(d)
    }
  }

  mutating func pull() -> Result<CodecItem, DepacketizeError>? {
    switch self {
    case .aac(var d):
      let item = d.pull()
      self = .aac(d)
      return item
    case .simpleAudio(var d):
      let item = d.pull()
      self = .simpleAudio(d)
      return item
    case .g723(var d):
      let item = d.pull()
      self = .g723(d)
      return item
    }
  }
}

extension AudioDepacketizer {
  var audioParameters: AudioParameters? {
    switch self {
    case .aac(let d): return d.parameters
    case .simpleAudio(let d): return d.parameters
    case .g723(let d): return d.parameters
    }
  }
}
