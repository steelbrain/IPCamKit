// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina (https://github.com/scottlamb/retina) src/lib.rs context types

import Foundation

/// RTSP connection context. Identifies a flow in a packet capture.
public struct ConnectionContext: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let localAddr: String
  public let peerAddr: String
  public let establishedWall: WallTime

  public init(localAddr: String, peerAddr: String, establishedWall: WallTime) {
    self.localAddr = localAddr
    self.peerAddr = peerAddr
    self.establishedWall = establishedWall
  }

  public static func dummy() -> ConnectionContext {
    ConnectionContext(
      localAddr: "0.0.0.0:0",
      peerAddr: "0.0.0.0:0",
      establishedWall: .now()
    )
  }

  public var description: String {
    "\(localAddr)(me)->\(peerAddr)@\(establishedWall)"
  }

  public var debugDescription: String {
    description
  }
}

/// Context of a received message within an RTSP connection.
/// When paired with a ConnectionContext, allows identification of a message in a packet capture.
public struct RtspMessageContext: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  /// Starting byte position within the input stream.
  /// The bottom 32 bits can be compared to the relative TCP sequence number.
  public let pos: UInt64

  /// Time when the application parsed the message.
  public let receivedWall: WallTime

  /// Monotonic time when the message was received.
  public let received: ContinuousClock.Instant

  public init(pos: UInt64, receivedWall: WallTime, received: ContinuousClock.Instant) {
    self.pos = pos
    self.receivedWall = receivedWall
    self.received = received
  }

  public static func dummy() -> RtspMessageContext {
    RtspMessageContext(pos: 0, receivedWall: .now(), received: .now)
  }

  public var description: String {
    "\(pos)@\(receivedWall)"
  }

  public var debugDescription: String {
    description
  }

  public static func == (lhs: RtspMessageContext, rhs: RtspMessageContext) -> Bool {
    lhs.pos == rhs.pos
      && lhs.receivedWall == rhs.receivedWall
      && lhs.received == rhs.received
  }
}

/// Context for an active stream (RTP+RTCP session), either TCP or UDP.
public enum StreamContext: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  case tcp(TcpStreamContext)
  case udp(UdpStreamContext)
  case dummy

  public var description: String {
    switch self {
    case .tcp(let tcp):
      return "TCP, interleaved channel ids \(tcp.rtpChannelId)-\(tcp.rtpChannelId + 1)"
    case .udp(let udp):
      return udp.description
    case .dummy:
      return "dummy"
    }
  }

  public var debugDescription: String {
    description
  }
}

/// Context for a TCP interleaved stream.
/// Stores the RTP channel id; the RTCP channel id is assumed to be one higher.
public struct TcpStreamContext: Sendable {
  public let rtpChannelId: UInt8

  public init(rtpChannelId: UInt8) {
    self.rtpChannelId = rtpChannelId
  }
}

/// Context for a UDP stream.
/// Stores only the RTP addresses; RTCP addresses use the same IPs and one port higher.
public struct UdpStreamContext: Sendable, CustomStringConvertible {
  public let localIP: String
  public let peerIP: String
  public let localRtpPort: UInt16
  public let peerRtpPort: UInt16

  public init(localIP: String, peerIP: String, localRtpPort: UInt16, peerRtpPort: UInt16) {
    self.localIP = localIP
    self.peerIP = peerIP
    self.localRtpPort = localRtpPort
    self.peerRtpPort = peerRtpPort
  }

  public var description: String {
    "\(localIP):\(localRtpPort)-\(localRtpPort + 1)(me) -> \(peerIP):\(peerRtpPort)-\(peerRtpPort + 1)"
  }
}

/// Context for an RTP or RTCP packet, received via RTSP interleaved data or UDP.
public enum PacketContext: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  case tcp(RtspMessageContext)
  case udp(receivedWall: WallTime)
  case dummy

  public var description: String {
    switch self {
    case .tcp(let msgCtx):
      return msgCtx.description
    case .udp(let wall):
      return wall.description
    case .dummy:
      return "dummy"
    }
  }

  public var debugDescription: String {
    description
  }
}

extension PacketContext: Equatable {
  public static func == (lhs: PacketContext, rhs: PacketContext) -> Bool {
    switch (lhs, rhs) {
    case (.tcp(let a), .tcp(let b)):
      return a == b
    case (.udp(let a), .udp(let b)):
      return a.date == b.date
    case (.dummy, .dummy):
      return true
    default:
      return false
    }
  }
}
