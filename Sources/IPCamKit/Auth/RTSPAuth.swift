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
  /// Set once the server has offered Basic, so later requests can attach it
  /// pre-emptively instead of paying a fresh 401 round-trip every time.
  private var basicChallengeSeen = false
  /// Some embedded cameras advertise Digest but reject valid Digest responses.
  /// If Basic was also offered and succeeds as a fallback, keep using Basic for
  /// the rest of the session instead of rediscovering the broken Digest path on
  /// every RTSP request.
  private var forceBasic = false

  init(credentials: Credentials) {
    self.credentials = credentials
  }

  /// Parse a WWW-Authenticate header and update internal state.
  mutating func handleChallenge(_ wwwAuthenticate: String) {
    let trimmed = wwwAuthenticate.trimmingCharacters(in: .whitespaces)
    let lower = trimmed.lowercased()
    if lower.hasPrefix("digest") {
      let state = parseDigestChallenge(String(trimmed.dropFirst(6)))
      // A digest challenge without a nonce is unusable; ignore it rather than
      // emit a bogus Authorization header — and never let a nonce-less re-offer
      // (or a second challenge line) clobber a good earlier Digest challenge.
      // A usable challenge replaces any prior one, resetting nc (nc starts 0).
      if !state.nonce.isEmpty {
        digestState = state
        forceBasic = false
      }
    } else if lower.hasPrefix("basic") {
      basicChallengeSeen = true
    }
  }

  /// Generate an Authorization header value for the given request.
  ///
  /// Mutates internal state: Digest+qop advances the nonce-count so each
  /// authorized request carries a unique, monotonically increasing `nc`.
  mutating func authorize(method: String, uri: String) -> String? {
    if digestState != nil && !forceBasic {
      return generateDigestAuth(method: method, uri: uri)
    }
    // Fall back to Basic auth
    return generateBasicAuth()
  }

  /// Generate a Basic Authorization header and prefer Basic on future requests.
  ///
  /// Used only after a server has offered Basic and rejected Digest. Calling this
  /// without a Basic challenge would silently weaken auth selection, so it
  /// returns nil unless Basic was actually advertised.
  mutating func authorizeBasicFallback() -> String? {
    guard basicChallengeSeen else { return nil }
    forceBasic = true
    return generateBasicAuth()
  }

  /// Whether we have received a challenge and can generate auth headers.
  var hasChallenge: Bool {
    digestState != nil || basicChallengeSeen
  }

  var hasBasicChallenge: Bool {
    basicChallengeSeen
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
    /// The challenge's `algorithm` token, or nil when the server omitted it
    /// (which means MD5). Kept optional so the response only echoes it back
    /// when the server actually sent one.
    var algorithm: String?
    var nc: UInt32 = 0
  }

  private func parseDigestChallenge(_ params: String) -> DigestState {
    var realm = ""
    var nonce = ""
    var qop: String?
    var opaque: String?
    var algorithm: String?

    for param in splitAuthParams(params) {
      let kv = param.split(separator: "=", maxSplits: 1)
      guard kv.count == 2 else { continue }
      let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
      let value = unquote(String(kv[1]))
      // Reject control characters (a bare CR/LF/tab/DEL) in a challenge value:
      // they're illegal in an RFC 7230/7616 quoted-string, and echoing one into
      // the Authorization header would inject control bytes into the request.
      // Dropping the param fails the challenge safely (e.g. an empty nonce).
      guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
      else { continue }

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

  /// Digest hash family parsed from the challenge `algorithm` token.
  private enum DigestHash { case md5, sha256 }

  /// Map an `algorithm` token to a hash family and the `-sess` flag. Unknown
  /// algorithms fall back to MD5 (RFC 7616's default).
  private func parseAlgorithm(_ algorithm: String) -> (hash: DigestHash, sess: Bool) {
    let lower = algorithm.lowercased()
    let hash: DigestHash = lower.hasPrefix("sha-256") ? .sha256 : .md5
    return (hash, lower.hasSuffix("-sess"))
  }

  /// True iff the server's `qop` list offers plain "auth" (not only "auth-int").
  private func qopOffersAuth(_ qop: String) -> Bool {
    qop.split(separator: ",").contains {
      $0.trimmingCharacters(in: .whitespaces) == "auth"
    }
  }

  private func hashHex(_ hash: DigestHash, _ input: String) -> String {
    let bytes = Data(input.utf8)
    switch hash {
    case .md5:
      return Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    case .sha256:
      return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
  }

  private mutating func generateDigestAuth(method: String, uri: String) -> String {
    guard var state = digestState else { return generateBasicAuth() }
    let (hash, sess) = parseAlgorithm(state.algorithm ?? "MD5")
    let cnonce = generateCNonce()

    var ha1 = hashHex(hash, "\(credentials.username):\(state.realm):\(credentials.password)")
    if sess {
      ha1 = hashHex(hash, "\(ha1):\(state.nonce):\(cnonce)")
    }
    let ha2 = hashHex(hash, "\(method):\(uri)")

    // Quoted-string fields are escaped (RFC 7616); the hash inputs above use the
    // raw, unescaped values. `algorithm`, `qop=auth`, and `nc=` stay unquoted —
    // they are RFC tokens, not quoted-strings.
    var header =
      "Digest username=\(quote(credentials.username)), realm=\(quote(state.realm)), "
      + "nonce=\(quote(state.nonce)), uri=\(quote(uri))"
    // Echo `algorithm` only when the challenge carried one (as curl and ffmpeg
    // do). Reolink cameras omit it from the challenge and reject a response
    // that includes it, even `algorithm=MD5`.
    if let algorithm = state.algorithm {
      header += ", algorithm=\(algorithm)"
    }

    if let qop = state.qop, qopOffersAuth(qop) {
      state.nc &+= 1
      let nc = String(format: "%08x", state.nc)
      let response = hashHex(hash, "\(ha1):\(state.nonce):\(nc):\(cnonce):auth:\(ha2)")
      header += ", response=\(quote(response)), qop=auth, nc=\(nc), cnonce=\(quote(cnonce))"
    } else {
      let response = hashHex(hash, "\(ha1):\(state.nonce):\(ha2)")
      header += ", response=\(quote(response))"
    }
    if let opaque = state.opaque {
      header += ", opaque=\(quote(opaque))"
    }
    digestState = state  // persist the advanced nonce-count
    return header
  }

  private func generateCNonce() -> String {
    let bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// Encode a string as an RFC 7616 quoted-string: escape `\` then `"`, wrap in
  /// quotes. Used only for header construction — never for hash inputs.
  private func quote(_ s: String) -> String {
    let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  /// Decode an auth parameter value: trim surrounding whitespace, and if it is a
  /// quoted-string strip exactly one surrounding pair of quotes and unescape
  /// `\\`/`\"` (RFC 7616). Bare token values pass through unchanged. A blanket
  /// quote-trim would mishandle escaped quotes and over-strip.
  private func unquote(_ raw: String) -> String {
    let v = raw.trimmingCharacters(in: .whitespaces)
    guard v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") else { return v }
    var out = ""
    out.reserveCapacity(v.count)
    var escaped = false
    for ch in v.dropFirst().dropLast() {
      if escaped {
        out.append(ch)
        escaped = false
      } else if ch == "\\" {
        escaped = true
      } else {
        out.append(ch)
      }
    }
    if escaped { out.append("\\") }  // dangling backslash: keep literal
    return out
  }

  /// Split auth parameters on commas, honoring quoted strings (commas inside a
  /// quoted-string don't split) and backslash escaping inside quotes (so a `\"`
  /// doesn't prematurely close the quote).
  private func splitAuthParams(_ params: String) -> [String] {
    var result: [String] = []
    var current = ""
    var inQuotes = false
    var escaped = false
    for ch in params {
      if escaped {
        current.append(ch)
        escaped = false
      } else if ch == "\\" && inQuotes {
        current.append(ch)
        escaped = true
      } else if ch == "\"" {
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
