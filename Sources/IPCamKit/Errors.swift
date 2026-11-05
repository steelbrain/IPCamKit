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
  /// A library API was used incorrectly (e.g. a second `frames()` sequence
  /// iterated while another is still in use).
  case invalidState(String)

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
    case .invalidState(let msg):
      return "Invalid state: \(msg)"
    }
  }
}

/// Bridges `description` to `localizedDescription`, which otherwise falls back
/// to Foundation's generic "The operation couldn't be completed" text.
extension RTSPError: LocalizedError {
  public var errorDescription: String? { description }
}
