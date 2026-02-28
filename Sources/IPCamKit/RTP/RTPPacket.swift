// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/rtp.rs - RTP packet parsing per RFC 3550

import Foundation

/// Minimum RTP header length (no CSRCs or extensions).
let rtpMinHeaderLen: UInt16 = 12

/// A validated raw RTP packet.
///
/// Validates the buffer on construction and provides accessors for header fields.
/// Ports upstream `RawPacket` from rtp.rs.
struct RawRTPPacket: Sendable, Equatable {
  /// Full packet data including headers.
  let data: Data

  /// Range of the payload within `data`.
  let payloadRange: Range<Int>

  /// Validates and creates a raw RTP packet.
  ///
  /// Checks: version 2, minimum length, CSRC count, extension header,
  /// padding, and computes the payload range.
  static func parse(_ data: Data) -> Result<RawRTPPacket, RTSPError> {
    guard data.count <= 65535 else {
      return .failure(.depacketizationError("too long"))
    }
    let len = UInt16(data.count)
    guard len >= rtpMinHeaderLen else {
      return .failure(.depacketizationError("too short"))
    }

    // Version must be 2
    guard (data[data.startIndex] & 0b1100_0000) == (2 << 6) else {
      return .failure(.depacketizationError("must be version 2"))
    }

    let hasPadding = (data[data.startIndex] & 0b0010_0000) != 0
    let hasExtension = (data[data.startIndex] & 0b0001_0000) != 0
    let csrcCount = UInt16(data[data.startIndex] & 0b0000_1111)
    let csrcEnd = rtpMinHeaderLen + (4 * csrcCount)

    var payloadStart: UInt16
    if hasExtension {
      guard data.count >= Int(csrcEnd + 4) else {
        return .failure(.depacketizationError("extension is after end of packet"))
      }
      let extLen =
        UInt16(data[data.startIndex + Int(csrcEnd) + 2]) << 8
        | UInt16(data[data.startIndex + Int(csrcEnd) + 3])
      // extLen is in 32-bit words, excluding the 4-byte extension header
      let (extMul, mulOF) = extLen.multipliedReportingOverflow(by: 4)
      let (extTotal, addOF) = extMul.addingReportingOverflow(csrcEnd + 4)
      guard !mulOF, !addOF else {
        return .failure(.depacketizationError("extension extends beyond maximum packet size"))
      }
      payloadStart = extTotal
    } else {
      payloadStart = csrcEnd
    }

    guard len >= payloadStart else {
      return .failure(.depacketizationError("payload start is after end of packet"))
    }

    var payloadEnd: UInt16
    if hasPadding {
      guard len > payloadStart else {
        return .failure(.depacketizationError("missing padding"))
      }
      let paddingLen = UInt16(data[data.startIndex + Int(len) - 1])
      guard paddingLen > 0 else {
        return .failure(.depacketizationError("invalid padding length 0"))
      }
      let (pe, subOF) = len.subtractingReportingOverflow(paddingLen)
      guard !subOF else {
        return .failure(.depacketizationError("padding larger than packet"))
      }
      guard pe >= payloadStart else {
        return .failure(.depacketizationError("bad padding"))
      }
      payloadEnd = pe
    } else {
      payloadEnd = len
    }

    let range = Int(payloadStart)..<Int(payloadEnd)
    return .success(RawRTPPacket(data: data, payloadRange: range))
  }

  /// RTP marker bit.
  var mark: Bool {
    (data[data.startIndex + 1] & 0b1000_0000) != 0
  }

  /// RTP sequence number (16-bit).
  var sequenceNumber: UInt16 {
    UInt16(data[data.startIndex + 2]) << 8 | UInt16(data[data.startIndex + 3])
  }

  /// RTP timestamp (32-bit).
  var rtpTimestamp: UInt32 {
    UInt32(data[data.startIndex + 4]) << 24
      | UInt32(data[data.startIndex + 5]) << 16
      | UInt32(data[data.startIndex + 6]) << 8
      | UInt32(data[data.startIndex + 7])
  }

  /// Synchronization source identifier.
  var ssrc: UInt32 {
    UInt32(data[data.startIndex + 8]) << 24
      | UInt32(data[data.startIndex + 9]) << 16
      | UInt32(data[data.startIndex + 10]) << 8
      | UInt32(data[data.startIndex + 11])
  }

  /// RTP payload type (7-bit).
  var payloadType: UInt8 {
    data[data.startIndex + 1] & 0b0111_1111
  }

  /// Payload bytes.
  var payload: Data {
    data[payloadRange]
  }
}

/// A received RTP packet with additional context.
///
/// Holds the parsed raw packet plus context, stream ID, extended timestamp, and loss count.
struct ReceivedRTPPacket: Sendable, Equatable {
  var ctx: PacketContext
  var streamId: Int
  var timestamp: Timestamp
  var raw: RawRTPPacket
  var loss: UInt16

  var mark: Bool { raw.mark }
  var sequenceNumber: UInt16 { raw.sequenceNumber }
  var ssrc: UInt32 { raw.ssrc }
  var payload: Data { raw.payload }
}

/// Builder for constructing RTP packets in tests.
struct RTPPacketBuilder: Sendable {
  var sequenceNumber: UInt16
  var timestamp: UInt32
  var payloadType: UInt8
  var ssrc: UInt32
  var mark: Bool

  /// Build an RTP packet with the given payload.
  func build(payload: Data) -> Result<RawRTPPacket, RTSPError> {
    guard payloadType < 0x80 else {
      return .failure(.depacketizationError("payload type too large"))
    }
    var data = Data(capacity: 12 + payload.count)
    // Byte 0: V=2, no padding, no extension, no CSRCs
    data.append(2 << 6)
    // Byte 1: marker + payload type
    data.append((mark ? 0b1000_0000 : 0) | payloadType)
    // Bytes 2-3: sequence number
    data.append(UInt8(sequenceNumber >> 8))
    data.append(UInt8(sequenceNumber & 0xFF))
    // Bytes 4-7: timestamp
    data.append(UInt8(timestamp >> 24))
    data.append(UInt8((timestamp >> 16) & 0xFF))
    data.append(UInt8((timestamp >> 8) & 0xFF))
    data.append(UInt8(timestamp & 0xFF))
    // Bytes 8-11: SSRC
    data.append(UInt8(ssrc >> 24))
    data.append(UInt8((ssrc >> 16) & 0xFF))
    data.append(UInt8((ssrc >> 8) & 0xFF))
    data.append(UInt8(ssrc & 0xFF))
    // Payload
    data.append(payload)
    return RawRTPPacket.parse(data)
  }
}

/// Builder for constructing received RTP packets in tests.
struct ReceivedPacketBuilder: Sendable {
  var ctx: PacketContext
  var streamId: Int
  var sequenceNumber: UInt16
  var timestamp: Timestamp
  var payloadType: UInt8
  var ssrc: UInt32
  var mark: Bool
  var loss: UInt16

  func build(payload: Data) -> Result<ReceivedRTPPacket, RTSPError> {
    let builder = RTPPacketBuilder(
      sequenceNumber: sequenceNumber,
      timestamp: UInt32(truncatingIfNeeded: timestamp.timestamp),
      payloadType: payloadType,
      ssrc: ssrc,
      mark: mark
    )
    switch builder.build(payload: payload) {
    case .success(let raw):
      return .success(
        ReceivedRTPPacket(
          ctx: ctx,
          streamId: streamId,
          timestamp: timestamp,
          raw: raw,
          loss: loss
        ))
    case .failure(let err):
      return .failure(err)
    }
  }
}
