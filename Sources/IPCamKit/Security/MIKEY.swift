// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// MIKEY (RFC 3830) SRTP key messages; RTSP KeyMgmt header and SDP key-mgmt attribute (RFC 4567).

import Foundation

/// MIKEY messages as RTSP servers and cameras use them for SRTP: a pre-shared-key
/// message (data type 0, or the type 1 verification message) whose KEMAC payload
/// carries the TEK in the clear (NULL encryption, NULL MAC) because the RTSPS
/// control connection already protects it.
///
/// Payload chain: HDR -> T -> RAND -> SP... -> KEMAC(Key Data: TEK = master key ||
/// master salt), with an SRTP-ID crypto session map (policy, SSRC, ROC per stream).
enum MIKEY {
  /// One entry of the HDR payload's SRTP-ID crypto session map.
  struct CryptoSession: Sendable, Equatable {
    var policyNumber: UInt8
    var ssrc: UInt32
    var roc: UInt32
  }

  /// The parts of a MIKEY message SRTP needs.
  struct Message: Sendable, Equatable {
    var csbID: UInt32
    var cryptoSessions: [CryptoSession]
    /// SRTP policies by policy number. Every policy number a crypto session
    /// references is present; one without an SP payload gets the RFC 3830
    /// defaults (`SRTPPolicy.aesCM128HMACSHA1_80`).
    var policies: [UInt8: SRTPPolicy]
    /// The TEK, split into master key (first `SRTPPolicy.masterKeyLength` bytes)
    /// and master salt (the rest), or taken from a TEK+SALT key data payload.
    var keys: SRTPKeyMaterial
  }

  // MARK: Constants (RFC 3830 section 6)

  private enum Payload {
    static let last: UInt8 = 0
    static let kemac: UInt8 = 1
    static let pke: UInt8 = 2
    static let dh: UInt8 = 3
    static let sign: UInt8 = 4
    static let timestamp: UInt8 = 5
    static let id: UInt8 = 6
    static let cert: UInt8 = 7
    static let chash: UInt8 = 8
    static let verification: UInt8 = 9
    static let securityPolicy: UInt8 = 10
    static let rand: UInt8 = 11
    static let error: UInt8 = 12
    static let keyData: UInt8 = 20
    static let generalExtension: UInt8 = 21
  }

  private enum KeyDataType {
    static let tgk: UInt8 = 0
    static let tgkSalt: UInt8 = 1
    static let tek: UInt8 = 2
    static let tekSalt: UInt8 = 3
  }

  /// SP payload parameter types for the SRTP protocol (RFC 3830 section 6.10.1).
  private enum PolicyParameter {
    static let encryptionAlgorithm: UInt8 = 0
    static let encryptionKeyLength: UInt8 = 1
    static let authAlgorithm: UInt8 = 2
    static let authKeyLength: UInt8 = 3
    static let saltLength: UInt8 = 4
    static let prf: UInt8 = 5
    static let keyDerivationRate: UInt8 = 6
    static let rtpEncryption: UInt8 = 7
    static let rtcpEncryption: UInt8 = 8
    static let fecOrder: UInt8 = 9
    static let rtpAuthentication: UInt8 = 10
    static let authTagLength: UInt8 = 11
    static let prefixLength: UInt8 = 12
  }

  // MARK: Parsing

  /// Parse a MIKEY message. Throws `SRTPError` (`.malformedMIKEY` or
  /// `.unsupportedMIKEY`) for truncated input, an encrypted or MAC-protected
  /// KEMAC (no pre-shared key to open it with), a TGK, an MKI, or an SRTP policy
  /// `SRTPContext` cannot run. Payloads SRTP does not use (ID, CERT, CHASH, V,
  /// ERR, general extension, PKE) are skipped; a SIGN payload ends the chain.
  /// Bytes after the last payload are ignored on purpose: the keys come only
  /// from the KEMAC, and the message arrives over the RTSP control connection.
  static func parse(_ data: Data) throws -> Message {
    var reader = Reader(bytes: [UInt8](data))

    // HDR
    let version = try reader.u8("HDR version")
    guard version == 1 else {
      throw SRTPError(.unsupportedMIKEY, "MIKEY version \(version) (only 1 is defined)")
    }
    let dataType = try reader.u8("HDR data type")
    guard dataType == 0 || dataType == 1 else {
      throw SRTPError(
        .unsupportedMIKEY,
        "MIKEY data type \(dataType) (only pre-shared-key messages, 0 and 1, are supported)")
    }
    var next = try reader.u8("HDR next payload")
    _ = try reader.u8("HDR V/PRF")
    let csbID = try reader.u32("HDR CSB ID")
    let sessionCount = try reader.u8("HDR #CS")
    let mapType = try reader.u8("HDR CS ID map type")
    var sessions: [CryptoSession] = []
    if sessionCount > 0 {
      guard mapType == 0 else {
        throw SRTPError(
          .unsupportedMIKEY, "MIKEY CS ID map type \(mapType) (only SRTP-ID, 0, is supported)")
      }
      for _ in 0..<sessionCount {
        let policyNumber = try reader.u8("CS policy number")
        let ssrc = try reader.u32("CS SSRC")
        let roc = try reader.u32("CS ROC")
        sessions.append(CryptoSession(policyNumber: policyNumber, ssrc: ssrc, roc: roc))
      }
    }

    var policies: [UInt8: SRTPPolicy] = [:]
    var tek: (key: [UInt8], salt: [UInt8]?)?
    var sawKEMAC = false
    chain: while next != Payload.last {
      let type = next
      if type == Payload.sign {
        // SIGN has no next-payload field and is always last.
        break chain
      }
      next = try reader.u8("next payload")
      switch type {
      case Payload.timestamp:
        let tsType = try reader.u8("T type")
        switch tsType {
        case 0, 1: try reader.skip(8, "T NTP value")
        case 2: try reader.skip(4, "T counter value")
        default:
          throw SRTPError(.unsupportedMIKEY, "MIKEY timestamp type \(tsType)")
        }
      case Payload.rand:
        let length = try reader.u8("RAND length")
        try reader.skip(Int(length), "RAND")
      case Payload.securityPolicy:
        let policyNumber = try reader.u8("SP policy number")
        let protocolType = try reader.u8("SP protocol type")
        let length = try reader.u16("SP parameter length")
        let parameters = try reader.take(Int(length), "SP parameters")
        guard protocolType == 0 else {
          throw SRTPError(
            .unsupportedMIKEY, "MIKEY SP protocol type \(protocolType) (only SRTP, 0)")
        }
        guard policies[policyNumber] == nil else {
          throw SRTPError(.malformedMIKEY, "MIKEY policy \(policyNumber) defined twice")
        }
        policies[policyNumber] = try parseSRTPPolicy(parameters)
      case Payload.kemac:
        guard !sawKEMAC else {
          throw SRTPError(.malformedMIKEY, "MIKEY message has more than one KEMAC payload")
        }
        sawKEMAC = true
        let encryption = try reader.u8("KEMAC encryption algorithm")
        let length = try reader.u16("KEMAC encrypted data length")
        let keyData = try reader.take(Int(length), "KEMAC key data")
        let mac = try reader.u8("KEMAC MAC algorithm")
        guard encryption == 0 else {
          throw SRTPError(
            .unsupportedMIKEY,
            "MIKEY KEMAC is encrypted (algorithm \(encryption)); no pre-shared key to decrypt it")
        }
        guard mac == 0 else {
          throw SRTPError(
            .unsupportedMIKEY,
            "MIKEY KEMAC MAC algorithm \(mac); only NULL is supported without a pre-shared key")
        }
        tek = try parseKeyData(keyData)
      case Payload.verification:
        let mac = try reader.u8("V MAC algorithm")
        try reader.skip(try macLength(mac), "V verification data")
      case Payload.id, Payload.cert, Payload.generalExtension:
        _ = try reader.u8("payload subtype")
        let length = try reader.u16("payload length")
        try reader.skip(Int(length), "payload data")
      case Payload.chash:
        let function = try reader.u8("CHASH function")
        switch function {
        case 0: try reader.skip(20, "CHASH SHA-1")
        case 1: try reader.skip(16, "CHASH MD5")
        default: throw SRTPError(.unsupportedMIKEY, "MIKEY CHASH function \(function)")
        }
      case Payload.error:
        try reader.skip(3, "ERR payload")
      case Payload.pke:
        let header = try reader.u16("PKE length")
        try reader.skip(Int(header & 0x3FFF), "PKE data")
      default:
        throw SRTPError(.unsupportedMIKEY, "MIKEY payload type \(type) cannot be parsed")
      }
    }
    // The last payload ends the message (unless it is a SIGN, which isn't
    // parsed).
    guard sawKEMAC, let tek else {
      throw SRTPError(.malformedMIKEY, "MIKEY message has no KEMAC payload with a TEK")
    }
    for session in sessions where policies[session.policyNumber] == nil {
      policies[session.policyNumber] = .aesCM128HMACSHA1_80
    }
    let splitPolicy =
      sessions.first.flatMap { policies[$0.policyNumber] }
      ?? policies.keys.min().flatMap { policies[$0] } ?? .aesCM128HMACSHA1_80

    let keys: SRTPKeyMaterial
    if let salt = tek.salt {
      keys = SRTPKeyMaterial(masterKey: Data(tek.key), masterSalt: Data(salt))
    } else {
      let expected = SRTPPolicy.masterKeyLength + splitPolicy.saltLength
      guard tek.key.count == expected else {
        throw SRTPError(
          .malformedMIKEY,
          "MIKEY TEK is \(tek.key.count) bytes; expected \(expected) (master key + salt)")
      }
      keys = SRTPKeyMaterial(
        masterKey: Data(tek.key.prefix(SRTPPolicy.masterKeyLength)),
        masterSalt: Data(tek.key.dropFirst(SRTPPolicy.masterKeyLength)))
    }
    return Message(csbID: csbID, cryptoSessions: sessions, policies: policies, keys: keys)
  }

  /// Map SRTP SP parameters onto a policy, starting from the RFC 3830 defaults.
  private static func parseSRTPPolicy(_ bytes: [UInt8]) throws -> SRTPPolicy {
    var policy = SRTPPolicy.aesCM128HMACSHA1_80
    var reader = Reader(bytes: bytes)
    while reader.remaining > 0 {
      let type = try reader.u8("SP parameter type")
      let length = try reader.u8("SP parameter length")
      let raw = try reader.take(Int(length), "SP parameter value")
      guard (1...4).contains(raw.count) else {
        // Every parameter defined for SRTP is a small integer.
        if type <= PolicyParameter.prefixLength {
          throw SRTPError(
            .malformedMIKEY, "MIKEY SP parameter \(type) has a \(raw.count)-byte value")
        }
        continue
      }
      let value = raw.reduce(0) { $0 << 8 | Int($1) }
      switch type {
      case PolicyParameter.encryptionAlgorithm:
        switch value {
        case 0: policy.cipher = .null
        case 1: policy.cipher = .aesCM128
        case 2: throw SRTPError(.unsupportedMIKEY, "SRTP cipher AES-F8 is not supported")
        default: throw SRTPError(.unsupportedMIKEY, "SRTP cipher \(value)")
        }
      case PolicyParameter.encryptionKeyLength: policy.encryptionKeyLength = value
      case PolicyParameter.authAlgorithm:
        switch value {
        case 0: policy.auth = .null
        case 1: policy.auth = .hmacSHA1
        default: throw SRTPError(.unsupportedMIKEY, "SRTP auth algorithm \(value)")
        }
      case PolicyParameter.authKeyLength: policy.authKeyLength = value
      case PolicyParameter.saltLength: policy.saltLength = value
      case PolicyParameter.prf:
        guard value == 0 else {
          throw SRTPError(.unsupportedMIKEY, "SRTP PRF \(value) (only AES-CM, 0)")
        }
      case PolicyParameter.keyDerivationRate:
        guard value == 0 else {
          throw SRTPError(.unsupportedMIKEY, "SRTP key derivation rate \(value) (only 0)")
        }
      case PolicyParameter.rtpEncryption: policy.rtpEncryption = value != 0
      case PolicyParameter.rtcpEncryption: policy.rtcpEncryption = value != 0
      case PolicyParameter.rtpAuthentication: policy.rtpAuthentication = value != 0
      case PolicyParameter.authTagLength: policy.authTagLength = value
      case PolicyParameter.prefixLength:
        guard value == 0 else {
          throw SRTPError(.unsupportedMIKEY, "SRTP prefix length \(value) (only 0)")
        }
      default:
        // FEC order and parameter types defined later do not change the transform.
        break
      }
    }
    do {
      try policy.validate()
    } catch let error as SRTPError {
      throw SRTPError(.unsupportedMIKEY, "MIKEY SRTP policy: \(error.message)")
    }
    return policy
  }

  /// Parse the KEMAC's Key Data sub-payloads and return the first TEK.
  private static func parseKeyData(_ bytes: [UInt8]) throws -> (key: [UInt8], salt: [UInt8]?) {
    var reader = Reader(bytes: bytes)
    var tek: (key: [UInt8], salt: [UInt8]?)?
    var next = Payload.keyData
    while next != Payload.last {
      guard next == Payload.keyData else {
        throw SRTPError(.malformedMIKEY, "KEMAC sub-payload type \(next) is not Key Data")
      }
      next = try reader.u8("Key Data next payload")
      let typeAndKV = try reader.u8("Key Data type")
      let type = typeAndKV >> 4
      let kv = typeAndKV & 0x0F
      let keyLength = try reader.u16("Key Data length")
      let key = try reader.take(Int(keyLength), "Key Data")
      var salt: [UInt8]?
      if type == KeyDataType.tgkSalt || type == KeyDataType.tekSalt {
        let saltLength = try reader.u16("Key Data salt length")
        salt = try reader.take(Int(saltLength), "Key Data salt")
      }
      switch kv {
      case 0:
        break
      case 1:
        throw SRTPError(.unsupportedMIKEY, "MIKEY key with an SPI/MKI (SRTP MKI unsupported)")
      case 2:
        // Key validity interval: accepted, not enforced.
        let fromLength = try reader.u8("Key Data valid-from length")
        try reader.skip(Int(fromLength), "Key Data valid-from")
        let toLength = try reader.u8("Key Data valid-to length")
        try reader.skip(Int(toLength), "Key Data valid-to")
      default:
        throw SRTPError(.unsupportedMIKEY, "MIKEY key validity type \(kv)")
      }
      switch type {
      case KeyDataType.tek, KeyDataType.tekSalt:
        if tek == nil { tek = (key, salt) }
      case KeyDataType.tgk, KeyDataType.tgkSalt:
        throw SRTPError(.unsupportedMIKEY, "MIKEY TGK keys (TEK derivation) are not supported")
      default:
        throw SRTPError(.unsupportedMIKEY, "MIKEY key data type \(type)")
      }
    }
    guard let tek else {
      throw SRTPError(.malformedMIKEY, "MIKEY KEMAC carries no TEK")
    }
    return tek
  }

  /// Length of a MAC for a KEMAC/V MAC algorithm.
  private static func macLength(_ algorithm: UInt8) throws -> Int {
    switch algorithm {
    case 0: return 0
    case 1: return 20  // HMAC-SHA-1-160
    default: throw SRTPError(.unsupportedMIKEY, "MIKEY MAC algorithm \(algorithm)")
    }
  }

  // MARK: Building

  /// Build a pre-shared-key initiator message (data type 0) carrying `keys` in
  /// the clear (KEMAC with NULL encryption and NULL MAC), as RTSP clients send in
  /// the SETUP `KeyMgmt` header.
  ///
  /// One SP payload is emitted per distinct policy number in `cryptoSessions`
  /// (policy 0 if there are none), each with `policy`. At most 255 crypto
  /// sessions fit the header; extras are dropped. `rand` defaults to 16 random
  /// bytes; an empty value is replaced by random bytes and a longer one than 255
  /// bytes is truncated.
  static func makeInitiatorMessage(
    cryptoSessions: [CryptoSession],
    keys: SRTPKeyMaterial,
    policy: SRTPPolicy = .aesCM128HMACSHA1_80,
    csbID: UInt32? = nil,
    timestamp: Date = Date(),
    rand: Data? = nil
  ) -> Data {
    var rng = SystemRandomNumberGenerator()
    let sessions = Array(cryptoSessions.prefix(255))
    var out: [UInt8] = []

    // HDR: version 1, data type 0 (PSK init), next T, V=0 PRF=MIKEY-1.
    out += [1, 0, Payload.timestamp, 0]
    out += SRTPContext.bigEndianBytes(csbID ?? UInt32.random(in: .min ... .max, using: &rng))
    out += [UInt8(sessions.count), 0]  // #CS, CS ID map type SRTP-ID
    for session in sessions {
      out.append(session.policyNumber)
      out += SRTPContext.bigEndianBytes(session.ssrc)
      out += SRTPContext.bigEndianBytes(session.roc)
    }

    // T: NTP-UTC timestamp.
    out += [Payload.rand, 0]
    out += ntpTimestamp(timestamp)

    // RAND.
    var randBytes = [UInt8](rand ?? Data()).prefix(255)
    if randBytes.isEmpty {
      randBytes = ArraySlice((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }
    out += [Payload.securityPolicy, UInt8(randBytes.count)]
    out += randBytes

    // SP, one per policy number.
    var policyNumbers: [UInt8] = []
    for session in sessions where !policyNumbers.contains(session.policyNumber) {
      policyNumbers.append(session.policyNumber)
    }
    if policyNumbers.isEmpty { policyNumbers = [0] }
    let parameters = policyParameters(policy)
    for (i, number) in policyNumbers.enumerated() {
      let isLast = i == policyNumbers.count - 1
      out += [isLast ? Payload.kemac : Payload.securityPolicy, number, 0]
      out += [UInt8(parameters.count >> 8), UInt8(parameters.count & 0xFF)]
      out += parameters
    }

    // KEMAC: NULL encryption, one TEK Key Data sub-payload, NULL MAC.
    let tek = [UInt8](keys.masterKey) + [UInt8](keys.masterSalt)
    let tekLength = min(tek.count, 0xFFFF - 4)
    let keyData: [UInt8] =
      [Payload.last, KeyDataType.tek << 4, UInt8(tekLength >> 8), UInt8(tekLength & 0xFF)]
      + tek.prefix(tekLength)
    out += [Payload.last, 0, UInt8(keyData.count >> 8), UInt8(keyData.count & 0xFF)]
    out += keyData
    out.append(0)  // MAC algorithm NULL
    return Data(out)
  }

  /// SRTP SP parameters for `policy`, in the order mediamtx emits them. Like
  /// mediamtx, the salt length is left out when it is the 14-byte default.
  private static func policyParameters(_ policy: SRTPPolicy) -> [UInt8] {
    func clamp(_ value: Int) -> UInt8 { UInt8(clamping: value) }
    var parameters: [(UInt8, UInt8)] = [
      (PolicyParameter.encryptionAlgorithm, policy.cipher == .aesCM128 ? 1 : 0),
      (PolicyParameter.encryptionKeyLength, clamp(policy.encryptionKeyLength)),
      (PolicyParameter.authAlgorithm, policy.auth == .hmacSHA1 ? 1 : 0),
      (PolicyParameter.authKeyLength, clamp(policy.authKeyLength)),
    ]
    if policy.saltLength != 14 {
      parameters.append((PolicyParameter.saltLength, clamp(policy.saltLength)))
    }
    parameters += [
      (PolicyParameter.rtpEncryption, policy.rtpEncryption ? 1 : 0),
      (PolicyParameter.rtcpEncryption, policy.rtcpEncryption ? 1 : 0),
      (PolicyParameter.rtpAuthentication, policy.rtpAuthentication ? 1 : 0),
      (PolicyParameter.authTagLength, clamp(policy.authTagLength)),
    ]
    return parameters.flatMap { [$0.0, 1, $0.1] }
  }

  /// 64-bit NTP timestamp (seconds since 1900, 32.32 fixed point; era wraps).
  static func ntpTimestamp(_ date: Date) -> [UInt8] {
    let ntp = date.timeIntervalSince1970 + 2_208_988_800
    guard ntp.isFinite, ntp >= 0, ntp < 1e15 else { return [UInt8](repeating: 0, count: 8) }
    let seconds = ntp.rounded(.down)
    let fraction = UInt32(clamping: Int64((ntp - seconds) * 4_294_967_296))
    return SRTPContext.bigEndianBytes(UInt32(truncatingIfNeeded: Int64(seconds)))
      + SRTPContext.bigEndianBytes(fraction)
  }
}

extension MIKEY.Message {
  /// The policy for `session` (the RFC 3830 default if its SP payload was absent).
  func policy(for session: MIKEY.CryptoSession) -> SRTPPolicy {
    policies[session.policyNumber] ?? .aesCM128HMACSHA1_80
  }

  /// An SRTP context for this message's key, seeded with each crypto session's
  /// ROC. Throws if the crypto sessions use different policies (one context runs
  /// one policy) or the key does not fit the policy.
  func makeContext() throws -> SRTPContext {
    let policy =
      cryptoSessions.first.map { self.policy(for: $0) }
      ?? policies.keys.min().flatMap { policies[$0] } ?? .aesCM128HMACSHA1_80
    guard cryptoSessions.allSatisfy({ self.policy(for: $0) == policy }) else {
      throw SRTPError(.unsupportedMIKEY, "MIKEY crypto sessions use different SRTP policies")
    }
    var context = try SRTPContext(keys: keys, policy: policy)
    for session in cryptoSessions {
      context.setROC(session.roc, forSSRC: session.ssrc)
    }
    return context
  }
}

// MARK: - Byte reader

/// Bounds-checked big-endian reader over a zero-based byte array.
private struct Reader {
  let bytes: [UInt8]
  private(set) var offset = 0

  init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  var remaining: Int { bytes.count - offset }

  mutating func take(_ count: Int, _ what: String) throws -> [UInt8] {
    guard count >= 0, count <= remaining else {
      throw SRTPError(
        .malformedMIKEY, "MIKEY truncated: \(what) needs \(count) bytes, \(remaining) left")
    }
    defer { offset += count }
    return Array(bytes[offset..<offset + count])
  }

  mutating func skip(_ count: Int, _ what: String) throws {
    guard count >= 0, count <= remaining else {
      throw SRTPError(
        .malformedMIKEY, "MIKEY truncated: \(what) needs \(count) bytes, \(remaining) left")
    }
    offset += count
  }

  mutating func u8(_ what: String) throws -> UInt8 {
    try take(1, what)[0]
  }

  mutating func u16(_ what: String) throws -> UInt16 {
    let b = try take(2, what)
    return UInt16(b[0]) << 8 | UInt16(b[1])
  }

  mutating func u32(_ what: String) throws -> UInt32 {
    SRTPContext.readUInt32(try take(4, what), at: 0)
  }
}

// MARK: - RTSP KeyMgmt header and SDP key-mgmt attribute (RFC 4567)

enum KeyMgmtHeader {
  /// RTSP `KeyMgmt` header value: `prot=mikey; uri="<uri>"; data="<base64>"`.
  /// A `"` in `uri` is percent-encoded so it cannot end the quoted string.
  static func format(uri: String, mikey: Data) -> String {
    let quotedURI = uri.replacingOccurrences(of: "\"", with: "%22")
    return "prot=mikey; uri=\"\(quotedURI)\"; data=\"\(mikey.base64EncodedString())\""
  }

  /// Parse a KeyMgmt header value (possibly several comma-separated entries);
  /// returns the first `prot=mikey` entry whose `data` decodes. Parameter names
  /// are case-insensitive, values may be quoted or bare, and whitespace around
  /// separators is ignored.
  static func parse(_ value: String) -> (uri: String?, mikey: Data)? {
    for entry in split(value, on: ",") {
      var parameters: [String: String] = [:]
      for field in split(entry, on: ";") {
        guard let equals = field.firstIndex(of: "=") else { continue }
        let name = field[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
        let raw = field[field.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if parameters[name] == nil { parameters[name] = unquote(raw) }
      }
      guard parameters["prot"]?.lowercased() == "mikey",
        let data = parameters["data"], let mikey = decodeBase64(data)
      else { continue }
      return (parameters["uri"], mikey)
    }
    return nil
  }

  /// SDP `a=key-mgmt:mikey <base64>` attribute VALUE (`mikey <base64>`) -> MIKEY
  /// bytes. Also accepts the value with its `a=key-mgmt:` or `key-mgmt:` prefix.
  static func parseSDPAttribute(_ value: String) -> Data? {
    var rest = Substring(value.trimmingCharacters(in: .whitespacesAndNewlines))
    for prefix in ["a=key-mgmt:", "key-mgmt:"]
    where rest.lowercased().hasPrefix(prefix) {
      rest = rest.dropFirst(prefix.count)
      break
    }
    let parts = rest.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
    guard parts.count == 2, parts[0].lowercased() == "mikey" else { return nil }
    return decodeBase64(parts[1].trimmingCharacters(in: .whitespaces))
  }

  /// Split on `separator` outside double-quoted strings.
  private static func split(_ value: some StringProtocol, on separator: Character) -> [String] {
    var parts: [String] = []
    var current = ""
    var quoted = false
    for ch in value {
      if ch == "\"" {
        quoted.toggle()
      } else if ch == separator && !quoted {
        parts.append(current)
        current = ""
        continue
      }
      current.append(ch)
    }
    parts.append(current)
    return parts
  }

  private static func unquote(_ value: String) -> String {
    guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
    return String(value.dropFirst().dropLast())
  }

  /// Standard base64, tolerating missing `=` padding and embedded whitespace.
  static func decodeBase64(_ value: String) -> Data? {
    var text = value.filter { !$0.isWhitespace }
    guard !text.isEmpty else { return nil }
    switch text.count % 4 {
    case 0: break
    case 2: text += "=="
    case 3: text += "="
    default: return nil
    }
    return Data(base64Encoded: text)
  }
}
