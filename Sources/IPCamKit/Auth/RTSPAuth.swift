// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Replaces upstream http_auth crate with native Swift authentication

import CryptoKit
import Foundation

/// RTSP credentials.
public struct Credentials: Sendable {
  public let username: String
  public let password: String

  public init(username: String, password: String) {
    self.username = username
    self.password = password
  }
}

/// Handles RTSP Basic and Digest authentication.
///
/// Parses WWW-Authenticate headers from 401 responses and generates
/// Authorization headers for subsequent requests.
struct RTSPAuthenticator: Sendable {
  private let credentials: Credentials
  private var digestState: DigestState?

  init(credentials: Credentials) {
    self.credentials = credentials
  }

  /// Parse a WWW-Authenticate header and update internal state.
  mutating func handleChallenge(_ wwwAuthenticate: String) {
    let trimmed = wwwAuthenticate.trimmingCharacters(in: .whitespaces)
    if trimmed.lowercased().hasPrefix("digest") {
      digestState = parseDigestChallenge(String(trimmed.dropFirst(6)))
    }
    // Basic auth doesn't need to parse the challenge
  }

  /// Generate an Authorization header value for the given request.
  func authorize(method: String, uri: String) -> String? {
    if let state = digestState {
      return generateDigestAuth(
        method: method, uri: uri, state: state)
    }
    // Fall back to Basic auth
    return generateBasicAuth()
  }

  /// Whether we have received a challenge and can generate auth headers.
  var hasChallenge: Bool {
    digestState != nil
  }

  // MARK: - Basic Auth

  private func generateBasicAuth() -> String {
    let credString = "\(credentials.username):\(credentials.password)"
    let base64 = Data(credString.utf8).base64EncodedString()
    return "Basic \(base64)"
  }

  // MARK: - Digest Auth

  struct DigestState: Sendable {
    var realm: String
    var nonce: String
    var qop: String?
    var opaque: String?
    var algorithm: String
    var nc: UInt32 = 0
  }

  private func parseDigestChallenge(_ params: String) -> DigestState {
    var realm = ""
    var nonce = ""
    var qop: String?
    var opaque: String?
    var algorithm = "MD5"

    for param in splitAuthParams(params) {
      let kv = param.split(separator: "=", maxSplits: 1)
      guard kv.count == 2 else { continue }
      let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
      let value = kv[1].trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

      switch key {
      case "realm": realm = value
      case "nonce": nonce = value
      case "qop": qop = value
      case "opaque": opaque = value
      case "algorithm": algorithm = value
      default: break
      }
    }

    return DigestState(
      realm: realm, nonce: nonce, qop: qop,
      opaque: opaque, algorithm: algorithm)
  }

  private func generateDigestAuth(method: String, uri: String, state: DigestState) -> String {
    let ha1 = md5Hex("\(credentials.username):\(state.realm):\(credentials.password)")
    let ha2 = md5Hex("\(method):\(uri)")

    let response: String
    if let qop = state.qop, qop.contains("auth") {
      let nc = String(format: "%08x", state.nc + 1)
      let cnonce = generateCNonce()
      response = md5Hex("\(ha1):\(state.nonce):\(nc):\(cnonce):auth:\(ha2)")
      var header =
        "Digest username=\"\(credentials.username)\", realm=\"\(state.realm)\", "
        + "nonce=\"\(state.nonce)\", uri=\"\(uri)\", "
        + "response=\"\(response)\", qop=auth, nc=\(nc), cnonce=\"\(cnonce)\""
      if let opaque = state.opaque {
        header += ", opaque=\"\(opaque)\""
      }
      return header
    } else {
      response = md5Hex("\(ha1):\(state.nonce):\(ha2)")
      var header =
        "Digest username=\"\(credentials.username)\", realm=\"\(state.realm)\", "
        + "nonce=\"\(state.nonce)\", uri=\"\(uri)\", response=\"\(response)\""
      if let opaque = state.opaque {
        header += ", opaque=\"\(opaque)\""
      }
      return header
    }
  }

  private func md5Hex(_ input: String) -> String {
    let digest = Insecure.MD5.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func generateCNonce() -> String {
    let bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// Split auth parameters, handling quoted strings with commas inside.
  private func splitAuthParams(_ params: String) -> [String] {
    var result: [String] = []
    var current = ""
    var inQuotes = false
    for ch in params {
      if ch == "\"" {
        inQuotes.toggle()
        current.append(ch)
      } else if ch == "," && !inQuotes {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { result.append(trimmed) }
        current = ""
      } else {
        current.append(ch)
      }
    }
    let trimmed = current.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty { result.append(trimmed) }
    return result
  }
}
