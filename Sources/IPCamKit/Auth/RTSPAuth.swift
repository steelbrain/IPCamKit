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
  /// Whether the challenges `handleChallenges` took in last offered Basic:
  /// a request falls back to Basic only when one of its own 401s did.
  private(set) var latestChallengesOfferBasic = false
  /// Some embedded cameras advertise Digest but reject valid Digest responses.
  /// If Basic was also offered and succeeds as a fallback, keep using Basic for
  /// the rest of the session instead of rediscovering the broken Digest path on
  /// every RTSP request (a later Digest challenge doesn't bring it back).
  private var forceBasic = false

  init(credentials: Credentials) {
    self.credentials = credentials
  }

  /// Take in every `WWW-Authenticate` header of ONE 401 response.
  ///
  /// Each header may hold several challenges (RFC 7235 section 4.1, e.g.
  /// `Basic realm="cam", Digest realm="cam", nonce="abc"`); all of them, in
  /// order, take part. Picks the first usable Digest challenge whose algorithm
  /// we support (MD5, MD5-sess, SHA-256, SHA-256-sess; absent means MD5): RFC
  /// 7616 servers list their preferred challenge first. A Digest challenge with
  /// an unsupported algorithm (e.g. SHA-512-256) or no nonce is skipped, so we
  /// never answer one algorithm's challenge with another's hash. The pick
  /// replaces any Digest state from an earlier response: a new nonce starts
  /// nc at 0, while the nonce in use keeps its count (nc counts the requests
  /// sent with a nonce, so two requests refused for the same new nonce must
  /// not both retry with nc=1); a response with no usable Digest challenge
  /// keeps the earlier state. An offered Basic challenge is remembered for
  /// `hasBasicChallenge` and the Basic fallback.
  ///
  /// Every value is taken as UTF-8 text; use the `RTSPHeaderValue` overload
  /// (`RTSPResponse.headerValues(named:)`) so a challenge the parser decoded as
  /// ISO Latin-1 is answered in the bytes the server sent.
  mutating func handleChallenges(_ headers: [String]) {
    handleChallenges(headers.map { RTSPHeaderValue($0) })
  }

  /// `handleChallenges(_:)` for header values that may be ISO Latin-1 text
  /// (see `RTSPHeaderValue`). The `realm`, `nonce` and `opaque` of a Latin-1
  /// Digest challenge go into the hashes and the `Authorization` header as the
  /// bytes the server sent; `authorizationHeader(method:uri:)` then returns a
  /// Latin-1 value for `RTSPRequest.setHeader(_:value:)`.
  mutating func handleChallenges(_ headers: [RTSPHeaderValue]) {
    var picked: DigestState?
    latestChallengesOfferBasic = false
    for header in headers {
      for challenge in Self.splitChallenges(header.text) {
        switch challenge.scheme.lowercased() {
        case "digest":
          guard picked == nil else { continue }
          let state = parseDigestChallenge(challenge.params, isLatin1: header.isLatin1)
          // A digest challenge without a nonce is unusable; ignore it rather
          // than emit a bogus Authorization header.
          if !state.nonce.isEmpty, parseAlgorithm(state.algorithm ?? "MD5") != nil {
            picked = state
          }
        case "basic":
          basicChallengeSeen = true
          latestChallengesOfferBasic = true
        default:
          break
        }
      }
    }
    if var picked {
      if let current = digestState, current.nonce == picked.nonce,
        current.isLatin1 == picked.isLatin1
      {
        picked.nc = current.nc
      }
      digestState = picked
    } else {
      // `stale` speaks for the response that said it: a later 401 without a
      // usable Digest challenge doesn't make the nonce worth sending again.
      digestState?.stale = false
    }
  }

  /// The credentials a request carried, for deciding whether its 401 is
  /// worth a retry.
  enum Sent: Equatable, Sendable {
    case none
    case basic
    case digest(nonce: String)
  }

  /// What `authorizationHeader(method:uri:)` answers with now.
  var sending: Sent {
    guard hasChallenge else { return .none }
    if let digestState, !forceBasic { return .digest(nonce: digestState.nonce) }
    return .basic
  }

  /// Whether to retry a request the server answered with 401, once this
  /// response's challenges are taken in, given what the request carried. A
  /// retry that would only repeat the credentials just refused isn't made:
  /// Basic again, or Digest with the same nonce when the server didn't mark
  /// it `stale`.
  func retries(afterRejecting sent: Sent) -> Bool {
    guard hasChallenge else { return false }
    switch sent {
    case .none:
      return true
    case .basic:
      return usesDigest
    case .digest(let nonce):
      guard usesDigest, let digestState else { return true }
      return digestState.nonce != nonce || digestState.stale
    }
  }

  /// Take in a single `WWW-Authenticate` header, as the whole challenge set of
  /// a response. Prefer `handleChallenges(_:)` with all of a response's headers.
  mutating func handleChallenge(_ wwwAuthenticate: String) {
    handleChallenges([wwwAuthenticate])
  }

  /// Generate an Authorization header value for the given request.
  ///
  /// Mutates internal state: Digest+qop advances the nonce-count so each
  /// authorized request carries a unique, monotonically increasing `nc`.
  ///
  /// The text of `authorizationHeader(method:uri:)`: for a challenge taken in
  /// as ISO Latin-1 it only works when written as Latin-1, which
  /// `RTSPRequest.setHeader(_:value:)` with that method's result arranges.
  mutating func authorize(method: String, uri: String) -> String? {
    authorizationHeader(method: method, uri: uri)?.text
  }

  /// `authorize(method:uri:)`, marked as ISO Latin-1 when it answers a Digest
  /// challenge the parser decoded as Latin-1: the text then stands for the
  /// header's bytes (the challenge's `realm`, `nonce` and `opaque` as sent, the
  /// username and URI as UTF-8), so set it with
  /// `RTSPRequest.setHeader(_:value:)`.
  mutating func authorizationHeader(method: String, uri: String) -> RTSPHeaderValue? {
    if digestState != nil && !forceBasic {
      return generateDigestAuth(method: method, uri: uri)
    }
    // Fall back to Basic auth
    return RTSPHeaderValue(generateBasicAuth())
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

  /// Whether `authorize` currently answers with Digest (a usable Digest
  /// challenge was seen and Basic hasn't been forced).
  var usesDigest: Bool {
    digestState != nil && !forceBasic
  }

  /// Whether the latest response's Digest challenge said `stale=true`: the
  /// nonce, not the password, was refused (RFC 7616 section 3.3).
  var digestIsStale: Bool {
    digestState?.stale == true
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
    /// The challenge was ISO Latin-1 text: `realm`, `nonce` and `opaque` hold
    /// one scalar per byte the server sent (see `RTSPHeaderValue`).
    var isLatin1 = false
    /// The challenge said `stale=true`: the nonce, not the password, was
    /// refused (RFC 7616 section 3.3).
    var stale = false
    var nc: UInt32 = 0
  }

  private func parseDigestChallenge(_ params: [String], isLatin1: Bool) -> DigestState {
    var realm = ""
    var nonce = ""
    var qop: String?
    var opaque: String?
    var algorithm: String?
    var stale = false

    for param in params {
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
      case "stale": stale = value.lowercased() == "true"
      default: break
      }
    }

    return DigestState(
      realm: realm, nonce: nonce, qop: qop,
      opaque: opaque, algorithm: algorithm, isLatin1: isLatin1, stale: stale)
  }

  /// Digest hash family parsed from the challenge `algorithm` token.
  private enum DigestHash { case md5, sha256 }

  /// Map an `algorithm` token to a hash family and the `-sess` flag, or nil for
  /// an algorithm we don't implement.
  private func parseAlgorithm(_ algorithm: String) -> (hash: DigestHash, sess: Bool)? {
    switch algorithm.trimmingCharacters(in: .whitespaces).lowercased() {
    case "md5": return (.md5, false)
    case "md5-sess": return (.md5, true)
    case "sha-256": return (.sha256, false)
    case "sha-256-sess": return (.sha256, true)
    default: return nil
    }
  }

  /// True iff the server's `qop` list offers plain "auth" (not only "auth-int").
  private func qopOffersAuth(_ qop: String) -> Bool {
    qop.split(separator: ",").contains {
      $0.trimmingCharacters(in: .whitespaces) == "auth"
    }
  }

  /// The hex digest of `input`'s bytes: its ISO Latin-1 encoding when
  /// `isLatin1` (see `generateDigestAuth`), else UTF-8.
  private func hashHex(_ hash: DigestHash, _ input: String, isLatin1: Bool) -> String {
    let bytes = RTSPHeaderValue(input, isLatin1: isLatin1).bytes
    switch hash {
    case .md5:
      return Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    case .sha256:
      return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
  }

  /// For a Latin-1 challenge every string here is ISO Latin-1 text (one
  /// scalar per byte): the challenge's values as the parser decoded them, and
  /// the username, password, method and URI as the Latin-1 text of their UTF-8
  /// bytes. Hashing and writing that text as Latin-1 then gives the server's
  /// own `realm`/`nonce`/`opaque` bytes next to the UTF-8 credentials.
  private mutating func generateDigestAuth(method: String, uri: String) -> RTSPHeaderValue {
    guard var state = digestState, let (hash, sess) = parseAlgorithm(state.algorithm ?? "MD5")
    else { return RTSPHeaderValue(generateBasicAuth()) }
    let isLatin1 = state.isLatin1
    func text(_ utf8: String) -> String {
      isLatin1 ? RTSPHeaderValue.latin1Text(utf8.utf8) : utf8
    }
    let username = text(credentials.username)
    let password = text(credentials.password)
    let method = text(method)
    let uri = text(uri)
    let cnonce = generateCNonce()

    var ha1 = hashHex(hash, "\(username):\(state.realm):\(password)", isLatin1: isLatin1)
    if sess {
      ha1 = hashHex(hash, "\(ha1):\(state.nonce):\(cnonce)", isLatin1: isLatin1)
    }
    let ha2 = hashHex(hash, "\(method):\(uri)", isLatin1: isLatin1)

    // Quoted-string fields are escaped (RFC 7616); the hash inputs above use the
    // raw, unescaped values. `algorithm`, `qop=auth`, and `nc=` stay unquoted —
    // they are RFC tokens, not quoted-strings.
    var header =
      "Digest username=\(quote(username)), realm=\(quote(state.realm)), "
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
      let response = hashHex(
        hash, "\(ha1):\(state.nonce):\(nc):\(cnonce):auth:\(ha2)", isLatin1: isLatin1)
      header += ", response=\(quote(response)), qop=auth, nc=\(nc), cnonce=\(quote(cnonce))"
    } else {
      let response = hashHex(hash, "\(ha1):\(state.nonce):\(ha2)", isLatin1: isLatin1)
      header += ", response=\(quote(response))"
    }
    if let opaque = state.opaque {
      header += ", opaque=\(quote(opaque))"
    }
    digestState = state  // persist the advanced nonce-count
    return RTSPHeaderValue(header, isLatin1: isLatin1)
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

  /// Split a `WWW-Authenticate` value into its challenges (RFC 7235 section
  /// 4.1: `1#challenge`, each `auth-scheme [ 1*SP ( token68 / #auth-param ) ]`).
  ///
  /// The value is split on commas outside quoted strings. An element that is a
  /// token alone, or a token, whitespace, and then anything but `=` (an
  /// auth-param or a token68), starts a challenge with that token as its
  /// scheme, except a bare token after an unquoted parameter value, which
  /// continues that value unless it is a known scheme name. Any other element
  /// (`name=value`, `name = value`) is an auth-param of the challenge before
  /// it; one before any challenge is ignored.
  static func splitChallenges(_ value: String) -> [(scheme: String, params: [String])] {
    var challenges: [(scheme: String, params: [String])] = []
    for element in splitAuthParams(value) {
      let tokenEnd = element.firstIndex(where: { !isTokenCharacter($0) }) ?? element.endIndex
      let rest = element[tokenEnd...]
      let afterBlanks = rest.drop(while: { $0 == " " || $0 == "\t" })
      // A bare token after an unquoted parameter value continues that value
      // unless it names a scheme: cameras send `qop=auth,auth-int` unquoted,
      // and taking `auth-int` as a new challenge would move the parameters
      // after it (the nonce) away from Digest.
      if tokenEnd > element.startIndex, rest.isEmpty,
        !knownSchemes.contains(element.lowercased()),
        let last = challenges.indices.last, let lastParam = challenges[last].params.last,
        let equals = lastParam.firstIndex(of: "="),
        lastParam[lastParam.index(after: equals)...].first != "\""
      {
        challenges[last].params[challenges[last].params.count - 1] = lastParam + "," + element
        continue
      }
      if tokenEnd > element.startIndex,
        rest.isEmpty || (afterBlanks.startIndex > rest.startIndex && afterBlanks.first != "=")
      {
        let scheme = String(element[..<tokenEnd])
        challenges.append((scheme, afterBlanks.isEmpty ? [] : [String(afterBlanks)]))
      } else if !challenges.isEmpty {
        challenges[challenges.count - 1].params.append(element)
      }
    }
    return challenges
  }

  /// Scheme names a bare token is taken as, starting a new challenge.
  private static let knownSchemes: Set<String> = [
    "basic", "digest", "bearer", "negotiate", "ntlm", "hoba", "mutual",
  ]

  /// An RFC 7230 `tchar`.
  private static func isTokenCharacter(_ ch: Character) -> Bool {
    guard ch.isASCII else { return false }
    return ch.isLetter || ch.isNumber || "!#$%&'*+-.^_`|~".contains(ch)
  }

  /// Split auth parameters on commas, honoring quoted strings (commas inside a
  /// quoted-string don't split) and backslash escaping inside quotes (so a `\"`
  /// doesn't prematurely close the quote).
  private static func splitAuthParams(_ params: String) -> [String] {
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
