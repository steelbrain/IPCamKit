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
    case "dvi4":
      // Each packet starts with a 4-byte state header (RFC 3551 section
      // 4.5.1), which holds no samples.
      return .simpleAudio(
        SimpleAudioDepacketizer(clockRate: clockRate, bitsPerSample: 4, headerBytes: 4))
    case "g726-32":
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

  /// Pushes `pkt` to the codec depacketizer. The codec's state is written back
  /// even when its `push` throws: a depacketizer resets (and carries loss
  /// forward) before throwing, and that reset must not be lost. `self` is
  /// consumed so the payload's buffers are changed in place, not copied.
  mutating func push(_ pkt: ReceivedRTPPacket) throws {
    switch consume self {
    case .aac(var d):
      defer { self = .aac(d) }
      try d.push(pkt)
    case .simpleAudio(var d):
      defer { self = .simpleAudio(d) }
      try d.push(pkt)
    case .g723(var d):
      defer { self = .g723(d) }
      try d.push(pkt)
    }
  }

  mutating func pull() -> Result<CodecItem, DepacketizeError>? {
    switch consume self {
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
  /// RTP clock ticks `frame` lasts on a stream of `channels` channels (nil
  /// for one). One tick holds one sample of each channel, but a sample-based
  /// codec's `frameLength` counts the samples of all channels; AAC and G.723
  /// frame lengths are ticks already.
  func ticks(of frame: AudioFrame, channels: UInt16?) -> UInt32 {
    guard case .simpleAudio = self, let channels, channels > 1 else { return frame.frameLength }
    // Rounded up, so a payload cut mid-tick still ends after its last sample.
    return (frame.frameLength + UInt32(channels) - 1) / UInt32(channels)
  }

  var audioParameters: AudioParameters? {
    switch self {
    case .aac(let d): return d.parameters
    case .simpleAudio(let d): return d.parameters
    case .g723(let d): return d.parameters
    }
  }
}
