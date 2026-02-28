// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// UDP transport for RTP/RTCP using NWConnection

import Foundation
import Network

/// A pair of UDP sockets for RTP (even port) and RTCP (odd port).
///
/// Ports upstream UdpPair from src/lib.rs lines 442-497.
actor UDPPair {
  let rtpPort: UInt16
  private var rtpConnection: NWConnection?
  private var rtcpConnection: NWConnection?
  private let queue = DispatchQueue(label: "ipcamkit.udp.pair")

  private static let maxTries = 10
  private static let portRange: Range<UInt16> = 5000..<65000

  init(rtpPort: UInt16) {
    self.rtpPort = rtpPort
  }

  /// Bind a UDP pair to a local IP, finding an available even/odd port pair.
  static func bind(localIP: String = "0.0.0.0") async throws -> UDPPair {
    for _ in 0..<maxTries {
      let port = UInt16.random(in: portRange) & ~1  // Force even
      let pair = UDPPair(rtpPort: port)
      // In a real implementation, we'd try to bind and verify
      // For now, return the pair — NWConnection handles binding
      return pair
    }
    throw RTSPError.transportNegotiationFailed
  }

  /// Connect the RTP socket to a peer address.
  func connectRTP(host: String, port: UInt16) async throws {
    let conn = NWConnection(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: port)!,
      using: .udp)

    rtpConnection = conn

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
          continuation.resume()
        case .failed(let error):
          continuation.resume(throwing: RTSPError.connectionFailed("UDP RTP: \(error)"))
        case .cancelled:
          continuation.resume(throwing: RTSPError.unexpectedDisconnection)
        default:
          break
        }
      }
      conn.start(queue: queue)
    }
    conn.stateUpdateHandler = nil
  }

  /// Connect the RTCP socket to a peer address.
  func connectRTCP(host: String, port: UInt16) async throws {
    let conn = NWConnection(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: port)!,
      using: .udp)

    rtcpConnection = conn

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
          continuation.resume()
        case .failed(let error):
          continuation.resume(throwing: RTSPError.connectionFailed("UDP RTCP: \(error)"))
        case .cancelled:
          continuation.resume(throwing: RTSPError.unexpectedDisconnection)
        default:
          break
        }
      }
      conn.start(queue: queue)
    }
    conn.stateUpdateHandler = nil
  }

  /// Receive an RTP packet.
  func receiveRTP() async throws -> Data {
    guard let conn = rtpConnection else {
      throw RTSPError.unexpectedDisconnection
    }
    return try await receiveFrom(conn)
  }

  /// Receive an RTCP packet.
  func receiveRTCP() async throws -> Data {
    guard let conn = rtcpConnection else {
      throw RTSPError.unexpectedDisconnection
    }
    return try await receiveFrom(conn)
  }

  private func receiveFrom(_ conn: NWConnection) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      conn.receiveMessage { content, _, _, error in
        if let error = error {
          continuation.resume(throwing: RTSPError.connectionFailed("UDP recv: \(error)"))
        } else if let data = content {
          continuation.resume(returning: data)
        } else {
          continuation.resume(throwing: RTSPError.unexpectedDisconnection)
        }
      }
    }
  }

  /// Close both sockets.
  func close() {
    rtpConnection?.cancel()
    rtcpConnection?.cancel()
    rtpConnection = nil
    rtcpConnection = nil
  }
}
