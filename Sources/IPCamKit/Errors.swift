// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina (https://github.com/scottlamb/retina) src/error.rs

import Foundation

/// Public error type for the IPCamKit RTSP client library.
public enum RTSPError: Error, Sendable, CustomStringConvertible {
  case connectionFailed(String)
  case authenticationFailed
  case sessionSetupFailed(statusCode: Int, reason: String)
  case transportNegotiationFailed
  case unexpectedDisconnection
  case timeout
  case invalidSDP(String)
  case depacketizationError(String)

  public var description: String {
    switch self {
    case .connectionFailed(let msg):
      return "Connection failed: \(msg)"
    case .authenticationFailed:
      return "Authentication failed"
    case .sessionSetupFailed(let code, let reason):
      return "\(code) response: \(reason)"
    case .transportNegotiationFailed:
      return "Transport negotiation failed"
    case .unexpectedDisconnection:
      return "Unexpected disconnection"
    case .timeout:
      return "Timeout"
    case .invalidSDP(let msg):
      return "Invalid SDP: \(msg)"
    case .depacketizationError(let msg):
      return "Depacketization error: \(msg)"
    }
  }
}

/// Internal error type mirroring upstream `ErrorInt` variants.
/// Provides detailed context for debugging (connection info, packet position, etc.).
enum InternalError: Error, Sendable, CustomStringConvertible {
  case invalidArgument(String)

  case rtspFramingError(
    connCtx: ConnectionContext,
    msgCtx: RtspMessageContext,
    description: String
  )

  case rtspResponseError(
    connCtx: ConnectionContext,
    msgCtx: RtspMessageContext,
    method: String,
    cseq: UInt32,
    statusCode: UInt16,
    description: String
  )

  case rtspUnassignedChannelError(
    connCtx: ConnectionContext,
    msgCtx: RtspMessageContext,
    channelId: UInt8,
    data: Data
  )

  case packetError(
    connCtx: ConnectionContext,
    streamCtx: StreamContext,
    pktCtx: PacketContext,
    streamId: Int,
    description: String
  )

  case rtpPacketError(
    connCtx: ConnectionContext,
    streamCtx: StreamContext,
    pktCtx: PacketContext,
    streamId: Int,
    ssrc: UInt32,
    sequenceNumber: UInt16,
    description: String
  )

  case connectError(any Error & Sendable)
  case writeError(connCtx: ConnectionContext, source: any Error & Sendable)
  case rtspReadError(
    connCtx: ConnectionContext,
    msgCtx: RtspMessageContext,
    source: any Error & Sendable
  )
  case udpRecvError(
    connCtx: ConnectionContext,
    streamCtx: StreamContext,
    when: WallTime,
    source: any Error & Sendable
  )

  case failedPrecondition(String)
  case `internal`(String)
  case unsupported(String)

  var description: String {
    switch self {
    case .invalidArgument(let msg):
      return "Invalid argument: \(msg)"
    case .rtspFramingError(let conn, let msg, let desc):
      return "RTSP framing error: \(desc)\n\nconn: \(conn)\nmsg: \(msg)"
    case .rtspResponseError(let conn, let msg, let method, let cseq, let status, let desc):
      return "\(status) response to \(method) CSeq=\(cseq): \(desc)\n\nconn: \(conn)\nmsg: \(msg)"
    case .rtspUnassignedChannelError(_, _, let ch, _):
      return "Received interleaved data on unassigned channel \(ch)"
    case .packetError(let conn, let stream, let pkt, _, let desc):
      return "\(desc)\n\nconn: \(conn)\nstream: \(stream)\npkt: \(pkt)"
    case .rtpPacketError(let conn, let stream, let pkt, _, let ssrc, let seq, let desc):
      return
        "\(desc)\n\nconn: \(conn)\nstream: \(stream)\nssrc: \(String(format: "%08x", ssrc))\nseq: \(seq)\npkt: \(pkt)"
    case .connectError(let err):
      return "Unable to connect to RTSP server: \(err)"
    case .writeError(let conn, let err):
      return "Error writing to RTSP peer: \(err)\n\nconn: \(conn)"
    case .rtspReadError(let conn, let msg, let err):
      return "Error reading from RTSP peer: \(err)\n\nconn: \(conn)\nmsg: \(msg)"
    case .udpRecvError(let conn, let stream, let when, let err):
      return "Error receiving UDP packet: \(err)\n\nconn: \(conn)\nstream: \(stream)\nat: \(when)"
    case .failedPrecondition(let msg):
      return "Failed precondition: \(msg)"
    case .internal(let msg):
      return "Internal error: \(msg)"
    case .unsupported(let msg):
      return "Unsupported: \(msg)"
    }
  }
}
