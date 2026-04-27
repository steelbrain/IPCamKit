// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/client/rtp.rs - RTP/RTCP sequence tracking and SSRC validation

import Foundation

/// Policy for handling RTCP packets with unknown/mismatched SSRC.
/// Matches upstream UnknownRtcpSsrcPolicy.
enum UnknownRtcpSsrcPolicy: Sendable {
  /// Default behavior: silently drop packets with mismatched SSRC.
  case dropPackets
  /// Error out on mismatched SSRC.
  case abortSession
  /// Accept packets regardless of SSRC.
  case processPackets
}

/// Tracks RTP packet ordering, SSRC consistency, and loss detection.
///
/// Handles:
/// - SSRC validation (reject mismatched SSRCs)
/// - Sequence number tracking and loss detection
/// - Out-of-order packet detection (drop, emit diagnostic on TCP)
/// - Geovision PT=50 quirk (silently drop)
/// - RTCP compound packet validation and SR timestamp placement
struct InorderParser: Sendable {
  private var ssrc: UInt32?
  private var nextSeq: UInt16?
  private var isTcp: Bool
  var timeline: Timeline
  private var unknownRtcpSsrcPolicy: UnknownRtcpSsrcPolicy
  private var seenUnknownRtcpSession: Bool = false
  private let onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)?

  /// Number of RTP packets seen.
  private(set) var seenRtpPackets: UInt64 = 0

  /// Number of RTCP packets seen.
  private(set) var seenRtcpPackets: UInt64 = 0

  init(
    ssrc: UInt32?, nextSeq: UInt16?, isTcp: Bool, timeline: Timeline,
    unknownRtcpSsrcPolicy: UnknownRtcpSsrcPolicy = .dropPackets,
    onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)? = nil
  ) {
    self.ssrc = ssrc
    self.nextSeq = nextSeq
    self.isTcp = isTcp
    self.timeline = timeline
    self.unknownRtcpSsrcPolicy = unknownRtcpSsrcPolicy
    self.onDiagnostic = onDiagnostic
  }

  /// Process an incoming RTP packet.
  ///
  /// Returns a ReceivedRTPPacket if the packet should be processed,
  /// or nil if it should be skipped (e.g., PT=50, out-of-order on UDP).
  mutating func rtp(
    data: Data,
    ctx: PacketContext,
    streamId: Int,
    streamCtx: StreamContext
  ) throws -> ReceivedRTPPacket? {
    let raw: RawRTPPacket
    switch RawRTPPacket.parse(data) {
    case .success(let pkt):
      raw = pkt
    case .failure(let reason):
      throw RTSPError.depacketizationError("Invalid RTP packet: \(reason)")
    }

    // Geovision quirk: skip PT=50 packets
    if raw.payloadType == 50 {
      return nil
    }

    // SSRC validation
    if let expectedSSRC = ssrc {
      guard raw.ssrc == expectedSSRC else {
        throw RTSPError.depacketizationError(
          "SSRC mismatch: expected \(String(format: "%08x", expectedSSRC)), "
            + "got \(String(format: "%08x", raw.ssrc))")
      }
    } else {
      ssrc = raw.ssrc
    }

    // Sequence number tracking and loss detection
    var loss: UInt16 = 0
    if let expected = nextSeq {
      let delta = raw.sequenceNumber &- expected
      if delta > 0x8000 {
        // Out of order. UDP reordering is normal and stays silent; TCP-interleaved
        // reordering means the camera's packetizer wrote sequence-numbers out of
        // order before muxing, which is camera misbehavior worth surfacing.
        if isTcp {
          onDiagnostic?(
            RTSPDiagnostic(
              severity: .warning,
              message:
                "Out-of-order RTP packet on TCP-interleaved transport: "
                + "seq=\(raw.sequenceNumber), expected=\(expected); packet dropped."))
        }
        return nil
      }
      loss = delta
    }
    nextSeq = raw.sequenceNumber &+ 1
    seenRtpPackets += 1

    // Advance timeline
    let timestamp = try timeline.advanceTo(raw.rtpTimestamp)

    return ReceivedRTPPacket(
      ctx: ctx,
      streamId: streamId,
      timestamp: timestamp,
      raw: raw,
      loss: loss
    )
  }

  /// Process an incoming RTCP compound packet.
  ///
  /// Validates the compound packet per RFC 3550 Appendix A.2, extracts
  /// the Sender Report's RTP timestamp if present, and validates SSRC.
  /// Matches upstream rtcp() method (client/rtp.rs lines 243-311).
  mutating func rtcp(
    ctx: PacketContext,
    streamId: Int,
    data: Data
  ) throws -> ReceivedCompoundPacket? {
    let firstPkt = try ReceivedCompoundPacket.validate(data)
    var rtpTimestamp: Timestamp?

    if let sr = try firstPkt.asSenderReport() {
      rtpTimestamp = try timeline.place(sr.rtpTimestamp)

      let srSSRC = sr.ssrc
      if let knownSSRC = ssrc, knownSSRC != srSSRC {
        switch unknownRtcpSsrcPolicy {
        case .abortSession:
          throw RTSPError.depacketizationError(
            "Expected ssrc=\(String(format: "%08x", knownSSRC)), "
              + "got RTCP SR ssrc=\(String(format: "%08x", srSSRC))")
        case .dropPackets:
          if !seenUnknownRtcpSession {
            seenUnknownRtcpSession = true
          }
          return nil
        case .processPackets:
          break
        }
      } else if ssrc == nil && unknownRtcpSsrcPolicy != .processPackets {
        ssrc = srSSRC
      }
    }

    seenRtcpPackets += 1
    return ReceivedCompoundPacket(
      ctx: ctx,
      streamId: streamId,
      rtpTimestamp: rtpTimestamp,
      raw: data
    )
  }
}
