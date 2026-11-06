// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina (https://github.com/scottlamb/retina) src/error.rs

import Foundation
import Network

/// Public error type for the IPCamKit RTSP client library.
public enum RTSPError: Error, Sendable, CustomStringConvertible {
  /// The stream URL or a tunnel URL can't be used, and nothing was sent: a
  /// scheme other than `rtsp`/`rtsps` (`http`/`https` or `ws`/`wss` for a
  /// tunnel), no host or a host that isn't a valid name, a bad port, a space
  /// or control character, an `@` after the host that may end a password, or
  /// a user name or password that isn't percent-encoded UTF-8. The message
  /// names the problem and shows the URL with its credentials hidden.
  case invalidURL(String)
  /// The connection couldn't be opened, or failed after it was. `underlying`
  /// is the Network framework error behind it, when there is one: `.dns` for
  /// a name that didn't resolve, `.posix` for a refused or unreachable host
  /// or another socket error (`ECONNREFUSED`, `EHOSTUNREACH`, `ENETUNREACH`,
  /// `ECONNRESET`, and so on, including UDP and multicast socket errors), and
  /// `.tls` for a failed TLS handshake or connection. It is nil for failures
  /// above the network, such as an HTTP tunnel or WebSocket upgrade the
  /// server refused.
  case connectionFailed(String, underlying: NWError? = nil)
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
    case .invalidURL(let msg):
      return msg
    case .connectionFailed(let msg, _):
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

  /// The Network framework error behind a `connectionFailed`, for an error
  /// that wraps one.
  var underlyingNetworkError: NWError? {
    guard case .connectionFailed(_, let underlying) = self else { return nil }
    return underlying
  }
}

/// Bridges `description` to `localizedDescription`, which otherwise falls back
/// to Foundation's generic "The operation couldn't be completed" text.
extension RTSPError: LocalizedError {
  public var errorDescription: String? { description }
}

extension NWError {
  /// `.posix` for the `errno` value `code`; nil for a value Darwin doesn't
  /// define.
  init?(errno code: Int32) {
    guard let posix = POSIXErrorCode(rawValue: code) else { return nil }
    self = .posix(posix)
  }
}
