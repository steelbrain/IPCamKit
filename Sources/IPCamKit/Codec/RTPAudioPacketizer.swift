// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// RTP packetizer for outgoing audio (e.g. ONVIF backchannel): G.711, G.722, G.726, L16, AAC.

import Foundation

/// Error thrown by ``RTPAudioPacketizer``.
struct RTPPacketizeError: Error, Sendable, Equatable, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

/// Turns encoded audio into RTP packets (RFC 3550) for sending to a camera, for example on
/// an ONVIF two-way-audio backchannel.
///
/// - Sample-based encodings (RFC 3551 section 4.5): `pcmu`, `pcma`, `g722`, `l16` and
///   `g726-16/24/32/40`. Each call takes any whole number of samples (interleaved across
///   channels when there are several); a chunk larger than `maxPayloadBytes` is split on
///   sample boundaries, and each packet's timestamp advances by the ticks before it. The
///   marker bit is set on the first packet the packetizer produces (start of talkspurt).
/// - `mpeg4-generic` (AAC, RFC 3640): each call takes one raw access unit (no ADTS header).
///   Every packet carries the AU-headers-length, one AU-header (AU-size, AU-index 0) and the
///   AU or a fragment of it; fragments repeat the AU-header with the full AU size, share
///   the AU's timestamp, and only the last one has the marker bit (RFC 3640 section 3.2.3).
///
/// Every packet is a complete RTP packet: a 12-byte header (version 2, no padding, header
/// extension or CSRCs) followed by the payload. Sequence numbers and timestamps wrap.
struct RTPAudioPacketizer: Sendable {
  /// Largest payload that keeps a packet within the 16-bit length of RTSP interleaved
  /// framing (and of the library's own RTP parser).
  static let maxPayloadLimit = Int(UInt16.max) - rtpHeaderBytes
  private static let rtpHeaderBytes = 12

  /// Bits per channel per RTP clock tick of each sample-based encoding (RFC 3551 section
  /// 4.5). G.722 samples at 16 kHz but its RTP clock is 8000 Hz, so one byte is one tick.
  private static let bitsPerTick: [String: Int] = [
    "pcmu": 8, "pcma": 8, "g722": 8, "l16": 16,
    "g726-16": 2, "g726-24": 3, "g726-32": 4, "g726-40": 5,
  ]

  private enum Format: Sendable {
    /// `blockBytes` bytes hold exactly `blockTicks` ticks for all channels: the smallest
    /// whole-byte run of whole samples, and the unit payloads are split on.
    case sampled(blockBytes: Int, blockTicks: UInt32)
    /// RFC 3640 with one AU-header per packet.
    case aac(AACHeaderLayout)
  }

  let payloadType: UInt8
  let ssrc: UInt32
  let clockRate: UInt32
  private let format: Format
  private let maxPayloadBytes: Int
  /// Sequence number of the next packet.
  private(set) var nextSequenceNumber: UInt16
  /// RTP timestamp of the next chunk of audio.
  private(set) var nextTimestamp: UInt32
  /// Whether a sample-based packet has been sent, i.e. the talkspurt's marker is spent.
  private var startedTalkspurt = false

  /// Creates a packetizer for one outgoing RTP audio stream.
  ///
  /// - Parameters:
  ///   - encodingName: SDP `rtpmap` encoding name (matched case-insensitively).
  ///   - clockRate: RTP clock rate from the `rtpmap`; must be non-zero.
  ///   - channels: `rtpmap` channel count (nil means 1). Used by the sample-based
  ///     encodings; AAC carries its channel layout in the bitstream and ignores it.
  ///   - payloadType: RTP payload type, 0...127.
  ///   - formatSpecificParams: SDP `fmtp` parameters. For `mpeg4-generic`: `mode`,
  ///     `sizelength`, `indexlength`, `indexdeltalength`, `constantduration` and `config`
  ///     (keys are case-insensitive). With `mode=AAC-hbr` or no mode, the lengths default
  ///     to 13/3/3. `config` only sets the default AU duration, so one that doesn't parse
  ///     falls back to 1024 instead of throwing.
  ///   - ssrc: RTP synchronization source.
  ///   - sequenceNumber: Sequence number of the first packet.
  ///   - timestamp: RTP timestamp of the first chunk.
  ///   - maxPayloadBytes: Largest RTP payload (excluding the 12-byte header) per packet.
  /// - Throws: ``RTPPacketizeError`` for an unsupported encoding, invalid parameters, a bad
  ///   `fmtp`, or a `maxPayloadBytes` too small for one sample block (or one AU-header
  ///   section plus one byte of AAC data).
  init(
    encodingName: String, clockRate: UInt32, channels: UInt16?, payloadType: UInt8,
    formatSpecificParams: String?, ssrc: UInt32, sequenceNumber: UInt16, timestamp: UInt32,
    maxPayloadBytes: Int = 1400
  ) throws {
    guard payloadType < 0x80 else {
      throw RTPPacketizeError("payload type \(payloadType) does not fit in 7 bits")
    }
    guard clockRate > 0 else { throw RTPPacketizeError("clock rate must be non-zero") }
    guard maxPayloadBytes > 0, maxPayloadBytes <= Self.maxPayloadLimit else {
      throw RTPPacketizeError(
        "maxPayloadBytes \(maxPayloadBytes) is outside 1...\(Self.maxPayloadLimit)")
    }

    let name = encodingName.lowercased()
    if let bits = Self.bitsPerTick[name] {
      let channelCount = Int(channels ?? 1)
      guard channelCount > 0 else { throw RTPPacketizeError("channel count must be non-zero") }
      // One tick is one sample per channel. The smallest whole-byte run of whole ticks is
      // bitsPerTick / gcd(bitsPerTick, 8) bytes, holding 8 / gcd(bitsPerTick, 8) ticks.
      let tickBits = bits * channelCount
      let gcd = 1 << min(3, tickBits.trailingZeroBitCount)
      let blockBytes = tickBits / gcd
      guard blockBytes <= maxPayloadBytes else {
        throw RTPPacketizeError(
          "maxPayloadBytes \(maxPayloadBytes) cannot hold one \(blockBytes)-byte sample block")
      }
      format = .sampled(blockBytes: blockBytes, blockTicks: UInt32(8 / gcd))
    } else if name == "mpeg4-generic" {
      let layout = try AACHeaderLayout(
        formatSpecificParams: formatSpecificParams, clockRate: clockRate)
      guard layout.sectionBytes < maxPayloadBytes else {
        throw RTPPacketizeError(
          "maxPayloadBytes \(maxPayloadBytes) cannot hold the \(layout.sectionBytes)-byte "
            + "AU-header section and any AAC data")
      }
      format = .aac(layout)
    } else {
      throw RTPPacketizeError("no RTP audio packetizer for encoding \(cutForMessage(encodingName))")
    }

    self.payloadType = payloadType
    self.ssrc = ssrc
    self.clockRate = clockRate
    self.maxPayloadBytes = maxPayloadBytes
    self.nextSequenceNumber = sequenceNumber
    self.nextTimestamp = timestamp
  }

  /// Whether the initializer accepts this SDP encoding name (matched case-insensitively).
  static func isSupported(encodingName: String) -> Bool {
    let name = encodingName.lowercased()
    return bitsPerTick[name] != nil || name == "mpeg4-generic"
  }

  /// Begin a new talkspurt after a silence: the next sample-based packet carries the
  /// marker bit (RFC 3551 section 4.1), and the RTP timestamp skips `silentTicks` so the
  /// receiver keeps the pause. AAC packets keep their per-AU marker; only the skip applies.
  mutating func startTalkspurt(skippingTicks silentTicks: UInt32 = 0) {
    startedTalkspurt = false
    nextTimestamp &+= silentTicks
  }

  /// Packetize one chunk of encoded audio into complete RTP packets (header + payload).
  /// `samples` (per channel, in RTP clock ticks) overrides the duration derived from the codec.
  ///
  /// The chunk's duration advances ``nextTimestamp``. Without `samples` it is derived from
  /// the byte count for sample-based encodings. For AAC it is `constantduration` from the
  /// fmtp if given, else the AU duration the fmtp `config` implies, computed as
  /// `AACDepacketizer` does: the AudioSpecificConfig's frame length (1024 samples, or 960,
  /// 512, 480 or 256 for other frame sizes) times the RTP clock rate's multiple of its core
  /// sampling rate (2048 for HE-AAC with a 24 kHz core on a 48 kHz clock). Without a
  /// `config` that parses and whose core rate the clock rate is 1 to 4 times, it is 1024.
  /// When `samples` is given and a sample-based chunk is split, each packet's timestamp
  /// offset is that duration scaled by the bytes before it.
  ///
  /// - Parameter payload: Encoded audio; may be a slice with a nonzero `startIndex`. For
  ///   sample-based encodings a whole number of samples (for every channel); for AAC one
  ///   raw access unit.
  /// - Returns: The packets, in sending order.
  /// - Throws: ``RTPPacketizeError`` for an empty payload, a partial sample, or an access
  ///   unit too large for the AU-size field. The packetizer's state is unchanged then.
  mutating func packetize(_ payload: Data, samples: UInt32? = nil) throws -> [Data] {
    guard !payload.isEmpty else { throw RTPPacketizeError("empty payload") }
    switch format {
    case .sampled(let blockBytes, let blockTicks):
      return try packetizeSamples(
        payload, blockBytes: blockBytes, blockTicks: blockTicks, samples: samples)
    case .aac(let layout):
      return try packetizeAccessUnit(payload, layout: layout, samples: samples)
    }
  }

  private mutating func packetizeSamples(
    _ payload: Data, blockBytes: Int, blockTicks: UInt32, samples: UInt32?
  ) throws -> [Data] {
    let total = payload.count
    guard total % blockBytes == 0 else {
      throw RTPPacketizeError(
        "payload of \(total) bytes is not a whole number of samples "
          + "(\(blockBytes)-byte blocks of \(blockTicks) ticks)")
    }
    /// RTP ticks from the start of the chunk to byte `offset`, a block boundary.
    func ticks(at offset: Int) -> UInt32 {
      if let samples {
        // offset <= total, so the quotient is at most `samples` and cannot overflow.
        let product = UInt64(samples).multipliedFullWidth(by: UInt64(offset))
        return UInt32(truncatingIfNeeded: UInt64(total).dividingFullWidth(product).quotient)
      }
      return UInt32(truncatingIfNeeded: offset / blockBytes) &* blockTicks
    }

    let packetBytes = maxPayloadBytes / blockBytes * blockBytes
    var packets: [Data] = []
    packets.reserveCapacity(total / packetBytes + 1)
    var offset = 0
    while offset < total {
      let length = min(packetBytes, total - offset)
      let start = payload.startIndex + offset
      packets.append(
        makePacket(
          mark: !startedTalkspurt, timestamp: nextTimestamp &+ ticks(at: offset),
          prefix: nil, body: payload[start..<(start + length)]))
      startedTalkspurt = true
      offset += length
    }
    nextTimestamp &+= ticks(at: total)
    return packets
  }

  private mutating func packetizeAccessUnit(
    _ accessUnit: Data, layout: AACHeaderLayout, samples: UInt32?
  ) throws -> [Data] {
    guard accessUnit.count <= layout.maxAccessUnitBytes else {
      throw RTPPacketizeError(
        "access unit of \(accessUnit.count) bytes does not fit the "
          + "\(layout.sizeLength)-bit AU-size field")
    }
    let section = layout.section(accessUnitBytes: accessUnit.count)
    let fragmentBytes = maxPayloadBytes - section.count
    var packets: [Data] = []
    packets.reserveCapacity(accessUnit.count / fragmentBytes + 1)
    var offset = 0
    while offset < accessUnit.count {
      let length = min(fragmentBytes, accessUnit.count - offset)
      let start = accessUnit.startIndex + offset
      offset += length
      packets.append(
        makePacket(
          mark: offset == accessUnit.count, timestamp: nextTimestamp, prefix: section,
          body: accessUnit[start..<(start + length)]))
    }
    nextTimestamp &+= samples ?? layout.defaultDuration
    return packets
  }

  /// Builds one RTP packet and advances the sequence number.
  private mutating func makePacket(
    mark: Bool, timestamp: UInt32, prefix: Data?, body: Data
  ) -> Data {
    var packet = Data(capacity: Self.rtpHeaderBytes + (prefix?.count ?? 0) + body.count)
    packet.append(0x80)  // V=2, P=0, X=0, CC=0
    packet.append((mark ? 0x80 : 0) | payloadType)
    Self.appendBigEndian(nextSequenceNumber, to: &packet)
    Self.appendBigEndian(timestamp, to: &packet)
    Self.appendBigEndian(ssrc, to: &packet)
    if let prefix { packet.append(prefix) }
    packet.append(body)
    nextSequenceNumber &+= 1
    return packet
  }

  private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
  }
}

/// RFC 3640 AU-header layout for `mpeg4-generic`, read from the SDP fmtp.
private struct AACHeaderLayout: Sendable {
  /// Bits of the AU-size field.
  let sizeLength: Int
  /// Bits of the AU-index field (always sent as 0: one AU per packet, not interleaved).
  let indexLength: Int
  /// RTP ticks per access unit when the caller gives no duration: `constantduration`,
  /// else the duration `config` implies, else 1024.
  let defaultDuration: UInt32

  /// Bytes before the AU data in every packet: the 16-bit AU-headers-length plus one
  /// AU-header padded to a byte boundary.
  var sectionBytes: Int { 2 + (sizeLength + indexLength + 7) / 8 }

  /// Largest access unit the AU-size field can express.
  var maxAccessUnitBytes: Int { Int((UInt64(1) << UInt64(sizeLength)) - 1) }

  init(formatSpecificParams: String?, clockRate: UInt32) throws {
    var mode: String?
    var sizeLength: Int?
    var indexLength: Int?
    var constantDuration: UInt32?
    var config: String?
    for param in (formatSpecificParams ?? "").lazySplit(separator: ";") {
      let trimmed = param.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }  // e.g. a trailing ';'
      guard let equals = trimmed.firstIndex(of: "=") else {
        throw RTPPacketizeError("bad format-specific parameter \(cutForMessage(trimmed))")
      }
      let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
      let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      switch key {
      case "mode":
        mode = value
      case "sizelength":
        sizeLength = try Self.parse(key, value, in: 1...32)
      case "indexlength":
        indexLength = try Self.parse(key, value, in: 0...32)
      case "indexdeltalength":
        // Only separates AU-headers within a packet; each packet here carries one.
        _ = try Self.parse(key, value, in: 0...32)
      case "constantduration":
        guard let duration = UInt32(value), duration > 0 else {
          throw RTPPacketizeError("bad constantduration=\(cutForMessage(value))")
        }
        constantDuration = duration
      case "config":
        config = value
      case "ctsdeltalength", "dtsdeltalength", "randomaccessindication",
        "streamstateindication", "auxiliarydatasizelength":
        // These add AU-header fields or an auxiliary section this packetizer doesn't write.
        guard try Self.parse(key, value, in: 0...Int(Int32.max)) == 0 else {
          throw RTPPacketizeError("unsupported \(cutForMessage(key))=\(cutForMessage(value))")
        }
      default:
        break
      }
    }

    if mode == nil || mode?.lowercased() == "aac-hbr" {
      self.sizeLength = sizeLength ?? 13
      self.indexLength = indexLength ?? 3
    } else {
      // Other modes have no defaults this packetizer can assume.
      guard let explicitSizeLength = sizeLength else {
        throw RTPPacketizeError("mode \(cutForMessage(mode ?? "")) requires an explicit sizelength")
      }
      self.sizeLength = explicitSizeLength
      self.indexLength = indexLength ?? 0
    }
    self.defaultDuration =
      constantDuration
      ?? config.flatMap { aacRTPTicksPerAU(configHex: $0, clockRate: clockRate) } ?? 1024
  }

  /// The AU-headers-length and AU-header for an access unit of `accessUnitBytes` bytes.
  func section(accessUnitBytes: Int) -> Data {
    let headerBits = sizeLength + indexLength  // at most 64
    let headerBytes = (headerBits + 7) / 8
    // AU-size, then a zero AU-index, left-aligned in `headerBytes` bytes. The size fits in
    // `sizeLength` bits, so the shifted value fits in 64 bits.
    let header = UInt64(accessUnitBytes) << UInt64(headerBytes * 8 - sizeLength)
    var section = Data(capacity: 2 + headerBytes)
    section.append(UInt8(truncatingIfNeeded: headerBits >> 8))
    section.append(UInt8(truncatingIfNeeded: headerBits))
    for byte in (0..<headerBytes).reversed() {
      section.append(UInt8(truncatingIfNeeded: header >> UInt64(byte * 8)))
    }
    return section
  }

  private static func parse(
    _ key: String, _ value: String, in range: ClosedRange<Int>
  ) throws -> Int {
    guard let number = Int(value), range.contains(number) else {
      throw RTPPacketizeError("bad \(cutForMessage(key))=\(cutForMessage(value))")
    }
    return number
  }
}
