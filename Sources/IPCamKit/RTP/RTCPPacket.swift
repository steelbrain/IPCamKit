// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/rtcp.rs - RTCP compound packet parsing

import Foundation

/// Minimum RTCP common header length.
private let rtcpCommonHeaderLen = 4

/// RTCP Sender Report payload type.
let rtcpPayloadTypeSR: UInt8 = 200
/// RTCP Receiver Report payload type.
let rtcpPayloadTypeRR: UInt8 = 201

/// A parsed RTCP packet reference.
///
/// Interprets only the leading 4 bytes (common header): version, padding,
/// count/subtype, payload type, length.
struct RTCPPacketRef: Sendable {
  let buf: Data
  let payloadEnd: Int

  /// Parse one RTCP packet from the beginning of a buffer.
  /// Returns the parsed packet and remaining bytes.
  static func parse(_ buf: Data) throws -> (RTCPPacketRef, Data) {
    guard buf.count >= rtcpCommonHeaderLen else {
      throw RTSPError.depacketizationError(
        "RTCP packets must be at least \(rtcpCommonHeaderLen) bytes; have only \(buf.count)")
    }

    let version = buf[buf.startIndex] >> 6
    guard version == 2 else {
      throw RTSPError.depacketizationError("RTCP packets must be version 2; got \(version)")
    }

    let rawLen =
      Int(
        UInt16(buf[buf.startIndex + 2]) << 8
          | UInt16(buf[buf.startIndex + 3]))
    let len = (rawLen + 1) * 4

    guard buf.count >= len else {
      throw RTSPError.depacketizationError(
        "RTCP packet header has length \(len) bytes; have only \(buf.count)")
    }

    let packetData = buf[buf.startIndex..<(buf.startIndex + len)]
    let rest = buf[(buf.startIndex + len)...]

    let paddingBit = packetData[packetData.startIndex] & 0b0010_0000
    if paddingBit != 0 {
      guard rawLen != 0 else {
        throw RTSPError.depacketizationError(
          "RTCP packet has invalid combination of padding and len=0")
      }
      let paddingBytes = Int(packetData[packetData.startIndex + len - 1])
      guard paddingBytes > 0, paddingBytes <= len - rtcpCommonHeaderLen else {
        throw RTSPError.depacketizationError(
          "RTCP packet of len \(len) states invalid \(paddingBytes) padding bytes")
      }
      return (
        RTCPPacketRef(buf: Data(packetData), payloadEnd: len - paddingBytes),
        Data(rest)
      )
    } else {
      return (
        RTCPPacketRef(buf: Data(packetData), payloadEnd: len),
        Data(rest)
      )
    }
  }

  /// Payload type (byte 1).
  var payloadType: UInt8 {
    buf[buf.startIndex + 1]
  }

  /// Whether this packet has padding.
  var hasPadding: Bool {
    (buf[buf.startIndex] & 0b0010_0000) != 0
  }

  /// Count field (low 5 bits of byte 0).
  var count: UInt8 {
    buf[buf.startIndex] & 0b0001_1111
  }

  /// Full raw data including headers.
  var raw: Data {
    buf
  }

  /// Parse as a typed packet (SR or RR) if payload type is recognized.
  func asTyped() throws -> TypedPacketRef? {
    switch payloadType {
    case rtcpPayloadTypeSR:
      return .senderReport(try SenderReportRef.validate(self))
    case rtcpPayloadTypeRR:
      return .receiverReport(try ReceiverReportRef.validate(self))
    default:
      return nil
    }
  }

  /// Parse as a sender report if the type matches.
  func asSenderReport() throws -> SenderReportRef? {
    guard payloadType == rtcpPayloadTypeSR else { return nil }
    return try SenderReportRef.validate(self)
  }
}

/// A payload type-specific RTCP packet accessor.
enum TypedPacketRef: Sendable {
  case senderReport(SenderReportRef)
  case receiverReport(ReceiverReportRef)
}

/// A Sender Report (PT=200), RFC 3550 section 6.4.1.
struct SenderReportRef: Sendable {
  private static let headerLen = 8
  private static let senderInfoLen = 20
  private static let reportBlockLen = 24

  let pkt: RTCPPacketRef

  /// Validate that the packet length is consistent with the report block count.
  static func validate(_ pkt: RTCPPacketRef) throws -> SenderReportRef {
    let count = Int(pkt.count)
    let expectedLen = headerLen + senderInfoLen + (count * reportBlockLen)
    guard pkt.payloadEnd >= expectedLen else {
      throw RTSPError.depacketizationError(
        "RTCP SR has invalid count=\(count) with unpadded_byte_len=\(pkt.payloadEnd)")
    }
    return SenderReportRef(pkt: pkt)
  }

  /// SSRC of sender.
  var ssrc: UInt32 {
    let base = pkt.buf.startIndex + 4
    return UInt32(pkt.buf[base]) << 24
      | UInt32(pkt.buf[base + 1]) << 16
      | UInt32(pkt.buf[base + 2]) << 8
      | UInt32(pkt.buf[base + 3])
  }

  /// NTP timestamp.
  var ntpTimestamp: NtpTimestamp {
    let base = pkt.buf.startIndex + 8
    var value: UInt64 = 0
    for i in 0..<8 {
      value = (value << 8) | UInt64(pkt.buf[base + i])
    }
    return NtpTimestamp(rawValue: value)
  }

  /// RTP timestamp corresponding to the NTP timestamp.
  var rtpTimestamp: UInt32 {
    let base = pkt.buf.startIndex + 16
    return UInt32(pkt.buf[base]) << 24
      | UInt32(pkt.buf[base + 1]) << 16
      | UInt32(pkt.buf[base + 2]) << 8
      | UInt32(pkt.buf[base + 3])
  }
}

/// A Receiver Report (PT=201), RFC 3550 section 6.4.2.
struct ReceiverReportRef: Sendable {
  private static let headerLen = 8
  private static let reportBlockLen = 24

  let pkt: RTCPPacketRef

  /// Validate that the packet length is consistent with the report block count.
  static func validate(_ pkt: RTCPPacketRef) throws -> ReceiverReportRef {
    let count = Int(pkt.count)
    let expectedLen = headerLen + (count * reportBlockLen)
    guard pkt.payloadEnd >= expectedLen else {
      throw RTSPError.depacketizationError(
        "RTCP RR has invalid count=\(count) with unpadded_byte_len=\(pkt.payloadEnd)")
    }
    return ReceiverReportRef(pkt: pkt)
  }

  /// SSRC of sender.
  var ssrc: UInt32 {
    let base = pkt.buf.startIndex + 4
    return UInt32(pkt.buf[base]) << 24
      | UInt32(pkt.buf[base + 1]) << 16
      | UInt32(pkt.buf[base + 2]) << 8
      | UInt32(pkt.buf[base + 3])
  }
}

/// A validated RTCP compound packet.
///
/// Validated per RFC 3550 Appendix A.2:
/// - At least one RTCP packet within the compound
/// - All packets are version 2
/// - Non-final packets have no padding
/// - Packets' lengths add up to the compound packet's length
struct ReceivedCompoundPacket: Sendable {
  let ctx: PacketContext
  let streamId: Int
  let rtpTimestamp: Timestamp?
  let raw: Data

  /// Validate a compound packet, returning the first packet on success.
  static func validate(_ raw: Data) throws -> RTCPPacketRef {
    var (firstPkt, rest) = try RTCPPacketRef.parse(raw)
    var pkt = firstPkt
    while !rest.isEmpty {
      if pkt.hasPadding {
        throw RTSPError.depacketizationError(
          "padding on non-final packet within RTCP compound packet")
      }
      (pkt, rest) = try RTCPPacketRef.parse(rest)
    }
    return firstPkt
  }

  /// Iterate over all packets in this compound packet.
  func packets() -> [RTCPPacketRef] {
    var result: [RTCPPacketRef] = []
    var remaining = raw
    while !remaining.isEmpty {
      guard let (pkt, rest) = try? RTCPPacketRef.parse(remaining) else { break }
      result.append(pkt)
      remaining = rest
    }
    return result
  }
}
