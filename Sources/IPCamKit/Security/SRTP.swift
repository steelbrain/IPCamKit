// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// SRTP/SRTCP packet protection (RFC 3711): AES-CM-128, HMAC-SHA1, key derivation rate 0.

import CommonCrypto
import CryptoKit
import Foundation

// MARK: - Errors

/// An SRTP processing or MIKEY parsing failure.
struct SRTPError: Error, Equatable, Sendable, CustomStringConvertible {
  enum Kind: Sendable, Equatable {
    /// A policy or key length is invalid or unsupported.
    case invalidConfiguration
    /// The packet is too short or its RTP/RTCP header is malformed.
    case malformedPacket
    /// The authentication tag does not match.
    case authenticationFailed
    /// The packet index was already received, or is older than the replay window.
    case replayed
    /// The sender's packet index space is used up; the key must be replaced.
    case keyExhausted
    /// More SSRCs than one context tracks (`SRTPContext.maxSSRCs`).
    case tooManySSRCs
    /// CommonCrypto reported an error.
    case cryptoFailure
    /// A MIKEY message is truncated or inconsistent.
    case malformedMIKEY
    /// A MIKEY message uses a feature this implementation does not support.
    case unsupportedMIKEY
  }

  let kind: Kind
  let message: String

  init(_ kind: Kind, _ message: String) {
    self.kind = kind
    self.message = message
  }

  var description: String { "SRTP: \(message)" }
}

// MARK: - Policy and keys

/// The cryptographic transforms and lengths of one SRTP crypto context
/// (RFC 3711 section 8.2, as negotiated by the MIKEY SP payload).
struct SRTPPolicy: Sendable, Equatable {
  enum Cipher: Sendable, Equatable {
    case null
    case aesCM128
  }
  enum Auth: Sendable, Equatable {
    case null
    case hmacSHA1
  }

  var cipher: Cipher
  var auth: Auth
  /// Session encryption key length in bytes (16 for AES-CM-128; unused by the NULL cipher).
  var encryptionKeyLength: Int
  /// Session authentication key length in bytes (20 for HMAC-SHA1).
  var authKeyLength: Int
  /// Authentication tag length in bytes (10 = 80-bit, 4 = 32-bit). Applies to SRTP and SRTCP.
  var authTagLength: Int
  /// Master and session salt length in bytes (14).
  var saltLength: Int
  /// Whether RTP payloads are encrypted.
  var rtpEncryption: Bool
  /// Whether SRTCP packets are encrypted (sets the E flag).
  var rtcpEncryption: Bool
  /// Whether SRTP packets carry an authentication tag. SRTCP is always authenticated
  /// unless `auth` is `.null`.
  var rtpAuthentication: Bool

  /// `AES_CM_128_HMAC_SHA1_80`, the RFC 3711 default and the MIKEY default policy.
  /// (The underscore mirrors the profile name `AES_CM_128_HMAC_SHA1_80`.)
  // swift-format-ignore: AlwaysUseLowerCamelCase
  static let aesCM128HMACSHA1_80 = SRTPPolicy(
    cipher: .aesCM128, auth: .hmacSHA1, encryptionKeyLength: 16, authKeyLength: 20,
    authTagLength: 10, saltLength: 14, rtpEncryption: true, rtcpEncryption: true,
    rtpAuthentication: true)

  /// Master key length in bytes. The key derivation PRF is AES-CM-128 for every
  /// supported policy, so the master key is 16 bytes even with the NULL cipher.
  static let masterKeyLength = 16

  /// Tag bytes appended to each SRTP packet.
  var rtpTagLength: Int { auth == .hmacSHA1 && rtpAuthentication ? authTagLength : 0 }
  /// Tag bytes appended to each SRTCP packet.
  var rtcpTagLength: Int { auth == .hmacSHA1 ? authTagLength : 0 }

  /// Throw unless this policy is one `SRTPContext` implements.
  func validate() throws {
    func invalid(_ message: String) -> SRTPError { SRTPError(.invalidConfiguration, message) }
    switch cipher {
    case .aesCM128:
      guard encryptionKeyLength == 16 else {
        throw invalid("AES-CM-128 needs a 16-byte encryption key, not \(encryptionKeyLength)")
      }
    case .null:
      guard encryptionKeyLength >= 0 else {
        throw invalid("negative encryption key length \(encryptionKeyLength)")
      }
    }
    switch auth {
    case .hmacSHA1:
      guard (1...64).contains(authKeyLength) else {
        throw invalid("HMAC-SHA1 auth key length \(authKeyLength) is outside 1...64 bytes")
      }
      guard (4...20).contains(authTagLength) else {
        throw invalid("HMAC-SHA1 tag length \(authTagLength) is outside 4...20 bytes")
      }
    case .null:
      break
    }
    guard saltLength == 14 else {
      throw invalid("salt length \(saltLength) is not 14 bytes (AES-CM PRF)")
    }
  }
}

/// An SRTP master key and master salt.
struct SRTPKeyMaterial: Sendable, Equatable, CustomStringConvertible {
  let masterKey: Data
  let masterSalt: Data

  init(masterKey: Data, masterSalt: Data) {
    self.masterKey = Data(masterKey)
    self.masterSalt = Data(masterSalt)
  }

  /// Fresh random key material sized for `policy`, from the system CSPRNG.
  static func random(policy: SRTPPolicy = .aesCM128HMACSHA1_80) -> SRTPKeyMaterial {
    var rng = SystemRandomNumberGenerator()
    func bytes(_ count: Int) -> Data {
      Data((0..<max(0, count)).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }
    return SRTPKeyMaterial(
      masterKey: bytes(SRTPPolicy.masterKeyLength), masterSalt: bytes(policy.saltLength))
  }

  /// Lengths only, so key bytes never end up in logs.
  var description: String {
    "SRTPKeyMaterial(\(masterKey.count)-byte key, \(masterSalt.count)-byte salt)"
  }
}

// MARK: - Context

/// One direction of an SRTP session (one master key), any number of SSRCs.
///
/// Use one context per direction: the peer's key for `unprotectRTP`/`unprotectRTCP`,
/// your own key for `protectRTP`/`protectRTCP`. Receive and send state are tracked
/// separately per SSRC. A packet from an SSRC never seen before starts at the ROC
/// given to `setROC` (0 if none), and state for it is created only once the packet
/// authenticates.
struct SRTPContext: Sendable {
  /// The most SSRCs tracked per direction (receive, send) and protocol (RTP, RTCP).
  static let maxSSRCs = 1024
  /// The longest packet AES-CM can key (2^16 keystream blocks).
  static let maxPacketLength = 65536 * 16

  let policy: SRTPPolicy
  private let rtpKeys: SessionKeys
  private let rtcpKeys: SessionKeys

  private var initialROC: [UInt32: UInt32] = [:]
  /// Highest SRTP index sent, per SSRC.
  private var rtpSent: [UInt32: UInt64] = [:]
  private var rtpReceived: [UInt32: ReplayWindow] = [:]
  /// Next SRTCP index to send, per SSRC.
  private var rtcpNextIndex: [UInt32: UInt32] = [:]
  private var rtcpReceived: [UInt32: ReplayWindow] = [:]

  /// Validate the key and policy lengths and derive the SRTP and SRTCP session
  /// keys (RFC 3711 section 4.3, key derivation rate 0).
  init(keys: SRTPKeyMaterial, policy: SRTPPolicy) throws {
    try policy.validate()
    guard keys.masterKey.count == SRTPPolicy.masterKeyLength else {
      throw SRTPError(
        .invalidConfiguration,
        "master key is \(keys.masterKey.count) bytes, expected \(SRTPPolicy.masterKeyLength)")
    }
    guard keys.masterSalt.count == policy.saltLength else {
      throw SRTPError(
        .invalidConfiguration,
        "master salt is \(keys.masterSalt.count) bytes, expected \(policy.saltLength)")
    }
    let masterKey = [UInt8](keys.masterKey)
    let masterSalt = [UInt8](keys.masterSalt)
    self.policy = policy
    self.rtpKeys = try SessionKeys(
      masterKey: masterKey, masterSalt: masterSalt, policy: policy, firstLabel: 0)
    self.rtcpKeys = try SessionKeys(
      masterKey: masterKey, masterSalt: masterSalt, policy: policy, firstLabel: 3)
  }

  /// Set the rollover counter that `ssrc`'s packet index starts from, as carried
  /// in the MIKEY crypto session map. Call before the first packet of `ssrc`;
  /// calling it later restarts that SSRC's index tracking at `roc`.
  mutating func setROC(_ roc: UInt32, forSSRC ssrc: UInt32) {
    initialROC[ssrc] = roc
    rtpSent[ssrc] = nil
    rtpReceived[ssrc] = nil
  }

  /// The current RTP rollover counter for `ssrc`: from received packets if any,
  /// else from sent packets, else the value given to `setROC`.
  func currentROC(forSSRC ssrc: UInt32) -> UInt32? {
    if let window = rtpReceived[ssrc] { return UInt32(truncatingIfNeeded: window.highest >> 16) }
    if let sent = rtpSent[ssrc] { return UInt32(truncatingIfNeeded: sent >> 16) }
    return initialROC[ssrc]
  }

  // MARK: SRTP

  /// Encrypt and authenticate an RTP packet. The payload (everything after the
  /// fixed header, CSRCs and header extension) is encrypted; the tag is appended.
  mutating func protectRTP(_ packet: Data) throws -> Data {
    var bytes = [UInt8](packet)
    guard bytes.count <= Self.maxPacketLength else {
      throw SRTPError(.malformedPacket, "RTP packet of \(bytes.count) bytes is too long")
    }
    let headerLength = try Self.rtpHeaderLength(bytes, limit: bytes.count)
    let seq = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
    let ssrc = Self.readUInt32(bytes, at: 8)

    let index: UInt64
    if let highest = rtpSent[ssrc] {
      let estimate = Self.estimateIndex(seq: seq, highest: highest)
      guard estimate >= 0 else {
        throw SRTPError(.malformedPacket, "RTP sequence \(seq) precedes the first packet sent")
      }
      guard estimate <= Self.maxRTPIndex else {
        throw SRTPError(.keyExhausted, "SRTP index space exhausted for SSRC \(ssrc)")
      }
      index = UInt64(estimate)
    } else {
      guard rtpSent.count < Self.maxSSRCs else {
        throw SRTPError(.tooManySSRCs, "more than \(Self.maxSSRCs) sending SSRCs")
      }
      index = UInt64(initialROC[ssrc] ?? 0) << 16 | UInt64(seq)
    }

    if policy.rtpEncryption {
      try rtpKeys.applyKeystream(
        to: &bytes, range: headerLength..<bytes.count, cipher: policy.cipher, ssrc: ssrc,
        index: index)
    }
    let tagLength = policy.rtpTagLength
    if tagLength > 0 {
      let roc = UInt32(truncatingIfNeeded: index >> 16)
      bytes += rtpKeys.tag(bytes[...], roc: roc, length: tagLength)
    }
    rtpSent[ssrc] = max(rtpSent[ssrc] ?? index, index)
    return Data(bytes)
  }

  /// Authenticate and decrypt an SRTP packet, returning the plain RTP packet.
  ///
  /// Estimates the packet index from the sequence number and the highest index
  /// seen for its SSRC (RFC 3711 section 3.3.1), rejects replays, then verifies
  /// the tag in constant time before decrypting. The SSRC's rollover counter and
  /// replay window are updated only after the tag verifies.
  mutating func unprotectRTP(_ packet: Data) throws -> Data {
    var bytes = [UInt8](packet)
    let tagLength = policy.rtpTagLength
    guard bytes.count >= 12 + tagLength else {
      throw SRTPError(
        .malformedPacket, "SRTP packet of \(bytes.count) bytes is shorter than header + tag")
    }
    guard bytes.count <= Self.maxPacketLength + tagLength else {
      throw SRTPError(.malformedPacket, "SRTP packet of \(bytes.count) bytes is too long")
    }
    let authenticatedLength = bytes.count - tagLength
    let headerLength = try Self.rtpHeaderLength(bytes, limit: authenticatedLength)
    let seq = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
    let ssrc = Self.readUInt32(bytes, at: 8)

    let index: UInt64
    let window = rtpReceived[ssrc]
    if let window {
      let estimate = Self.estimateIndex(seq: seq, highest: window.highest)
      guard estimate >= 0 else {
        throw SRTPError(.replayed, "SRTP sequence \(seq) precedes the stream start")
      }
      guard estimate <= Self.maxRTPIndex else {
        throw SRTPError(.keyExhausted, "SRTP index space exhausted for SSRC \(ssrc)")
      }
      index = UInt64(estimate)
      guard window.accepts(index) else {
        throw SRTPError(.replayed, "SRTP index \(index) of SSRC \(ssrc) replayed or too old")
      }
    } else {
      guard rtpReceived.count < Self.maxSSRCs else {
        throw SRTPError(.tooManySSRCs, "more than \(Self.maxSSRCs) receiving SSRCs")
      }
      index = UInt64(initialROC[ssrc] ?? 0) << 16 | UInt64(seq)
    }

    if tagLength > 0 {
      let roc = UInt32(truncatingIfNeeded: index >> 16)
      let expected = rtpKeys.tag(bytes[..<authenticatedLength], roc: roc, length: tagLength)
      guard Self.constantTimeEqual(expected[...], bytes[authenticatedLength...]) else {
        throw SRTPError(.authenticationFailed, "SRTP tag mismatch (SSRC \(ssrc), seq \(seq))")
      }
    }
    if policy.rtpEncryption {
      try rtpKeys.applyKeystream(
        to: &bytes, range: headerLength..<authenticatedLength, cipher: policy.cipher,
        ssrc: ssrc, index: index)
    }

    var updated = window ?? ReplayWindow(first: index)
    updated.insert(index)
    rtpReceived[ssrc] = updated
    return Data(bytes[..<authenticatedLength])
  }

  // MARK: SRTCP

  /// Encrypt (if the policy says so) and authenticate a compound RTCP packet.
  /// Appends the E flag and 31-bit SRTCP index (counted per sender SSRC from 0),
  /// then the tag.
  mutating func protectRTCP(_ packet: Data) throws -> Data {
    var bytes = [UInt8](packet)
    guard bytes.count >= 8 else {
      throw SRTPError(.malformedPacket, "RTCP packet of \(bytes.count) bytes is shorter than 8")
    }
    guard bytes.count <= Self.maxPacketLength else {
      throw SRTPError(.malformedPacket, "RTCP packet of \(bytes.count) bytes is too long")
    }
    guard bytes[0] >> 6 == 2 else {
      throw SRTPError(.malformedPacket, "RTCP version \(bytes[0] >> 6), expected 2")
    }
    let ssrc = Self.readUInt32(bytes, at: 4)
    let index: UInt32
    if let next = rtcpNextIndex[ssrc] {
      index = next
    } else {
      guard rtcpNextIndex.count < Self.maxSSRCs else {
        throw SRTPError(.tooManySSRCs, "more than \(Self.maxSSRCs) sending RTCP SSRCs")
      }
      index = 0
    }
    guard index <= Self.maxRTCPIndex else {
      throw SRTPError(.keyExhausted, "SRTCP index space exhausted for SSRC \(ssrc)")
    }

    let encrypt = policy.rtcpEncryption
    if encrypt {
      try rtcpKeys.applyKeystream(
        to: &bytes, range: 8..<bytes.count, cipher: policy.cipher, ssrc: ssrc,
        index: UInt64(index))
    }
    let word = (encrypt ? 0x8000_0000 : 0) | index
    bytes += Self.bigEndianBytes(word)
    let tagLength = policy.rtcpTagLength
    if tagLength > 0 {
      bytes += rtcpKeys.tag(bytes[...], roc: nil, length: tagLength)
    }
    rtcpNextIndex[ssrc] = index + 1
    return Data(bytes)
  }

  /// Authenticate and (if its E flag is set) decrypt an SRTCP packet, returning
  /// the plain compound RTCP packet.
  mutating func unprotectRTCP(_ packet: Data) throws -> Data {
    var bytes = [UInt8](packet)
    let tagLength = policy.rtcpTagLength
    guard bytes.count >= 8 + 4 + tagLength else {
      throw SRTPError(
        .malformedPacket, "SRTCP packet of \(bytes.count) bytes is shorter than header + tag")
    }
    guard bytes.count <= Self.maxPacketLength + 4 + tagLength else {
      throw SRTPError(.malformedPacket, "SRTCP packet of \(bytes.count) bytes is too long")
    }
    guard bytes[0] >> 6 == 2 else {
      throw SRTPError(.malformedPacket, "RTCP version \(bytes[0] >> 6), expected 2")
    }
    let authenticatedLength = bytes.count - tagLength
    let rtcpLength = authenticatedLength - 4
    let ssrc = Self.readUInt32(bytes, at: 4)
    let word = Self.readUInt32(bytes, at: rtcpLength)
    let encrypted = word & 0x8000_0000 != 0
    let index = UInt64(word & 0x7FFF_FFFF)

    let window = rtcpReceived[ssrc]
    if let window {
      guard window.accepts(index) else {
        throw SRTPError(.replayed, "SRTCP index \(index) of SSRC \(ssrc) replayed or too old")
      }
    } else {
      guard rtcpReceived.count < Self.maxSSRCs else {
        throw SRTPError(.tooManySSRCs, "more than \(Self.maxSSRCs) receiving RTCP SSRCs")
      }
    }

    if tagLength > 0 {
      let expected = rtcpKeys.tag(bytes[..<authenticatedLength], roc: nil, length: tagLength)
      guard Self.constantTimeEqual(expected[...], bytes[authenticatedLength...]) else {
        throw SRTPError(.authenticationFailed, "SRTCP tag mismatch (SSRC \(ssrc))")
      }
    }
    if encrypted {
      try rtcpKeys.applyKeystream(
        to: &bytes, range: 8..<rtcpLength, cipher: policy.cipher, ssrc: ssrc, index: index)
    }

    var updated = window ?? ReplayWindow(first: index)
    updated.insert(index)
    rtcpReceived[ssrc] = updated
    return Data(bytes[..<rtcpLength])
  }

  // MARK: Helpers

  /// The largest SRTP packet index (48 bits).
  static let maxRTPIndex: Int64 = (1 << 48) - 1
  /// The largest SRTCP index (31 bits).
  static let maxRTCPIndex: UInt32 = 0x7FFF_FFFF

  /// RFC 3711 section 3.3.1: the index of `seq`, guessed from the highest index
  /// seen (`ROC || s_l`). May be negative (before the stream start) or exceed
  /// `maxRTPIndex`; callers range-check.
  static func estimateIndex(seq: UInt16, highest: UInt64) -> Int64 {
    let roc = Int64(highest >> 16 & 0xFFFF_FFFF)
    let last = UInt16(truncatingIfNeeded: highest)
    var v = roc
    if last < 0x8000 {
      if seq > last && seq - last > 0x8000 { v = roc - 1 }
    } else if last - 0x8000 > seq {
      v = roc + 1
    }
    return v << 16 | Int64(seq)
  }

  /// Length of the RTP header (fixed part, CSRCs and extension), which must fit
  /// in the first `limit` bytes.
  static func rtpHeaderLength(_ bytes: [UInt8], limit: Int) throws -> Int {
    guard limit >= 12, bytes.count >= limit else {
      throw SRTPError(.malformedPacket, "RTP packet shorter than its 12-byte header")
    }
    guard bytes[0] >> 6 == 2 else {
      throw SRTPError(.malformedPacket, "RTP version \(bytes[0] >> 6), expected 2")
    }
    var length = 12 + Int(bytes[0] & 0x0F) * 4
    if bytes[0] & 0x10 != 0 {
      guard length + 4 <= limit else {
        throw SRTPError(.malformedPacket, "RTP header extension truncated")
      }
      let words = Int(bytes[length + 2]) << 8 | Int(bytes[length + 3])
      length += 4 + words * 4
    }
    guard length <= limit else {
      throw SRTPError(
        .malformedPacket, "RTP header (\(length) bytes) is longer than the packet (\(limit))")
    }
    return length
  }

  static func constantTimeEqual(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for (x, y) in zip(a, b) { difference |= x ^ y }
    return difference == 0
  }

  /// Big-endian `UInt32` at `offset`; the caller has bounds-checked `offset + 4`.
  static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
      | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
  }

  static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
    [
      UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
    ]
  }
}

// MARK: - Session keys

/// The session keys for SRTP or SRTCP, derived from the master key and salt.
private struct SessionKeys: Sendable {
  let encryptionKey: [UInt8]
  let authKey: SymmetricKey
  let salt: [UInt8]

  /// Derive with labels `firstLabel` (encryption), `+1` (auth) and `+2` (salt):
  /// 0/1/2 for SRTP, 3/4/5 for SRTCP.
  init(masterKey: [UInt8], masterSalt: [UInt8], policy: SRTPPolicy, firstLabel: UInt8) throws {
    let encryptionLength = policy.cipher == .aesCM128 ? policy.encryptionKeyLength : 0
    let authLength = policy.auth == .hmacSHA1 ? policy.authKeyLength : 0
    encryptionKey = try AESCM.deriveSessionKey(
      masterKey: masterKey, masterSalt: masterSalt, label: firstLabel, length: encryptionLength)
    authKey = SymmetricKey(
      data: try AESCM.deriveSessionKey(
        masterKey: masterKey, masterSalt: masterSalt, label: firstLabel + 1, length: authLength))
    salt = try AESCM.deriveSessionKey(
      masterKey: masterKey, masterSalt: masterSalt, label: firstLabel + 2,
      length: policy.saltLength)
  }

  /// XOR the AES-CM keystream for (`ssrc`, `index`) into `bytes[range]`.
  /// The NULL cipher leaves the bytes unchanged.
  func applyKeystream(
    to bytes: inout [UInt8], range: Range<Int>, cipher: SRTPPolicy.Cipher, ssrc: UInt32,
    index: UInt64
  ) throws {
    guard cipher == .aesCM128, !range.isEmpty else { return }
    let iv = AESCM.packetIV(salt: salt, ssrc: ssrc, index: index)
    let keystream = try AESCM.keystream(key: encryptionKey, iv: iv, count: range.count)
    for (offset, k) in zip(range, keystream) { bytes[offset] ^= k }
  }

  /// HMAC-SHA1 over `authenticated` (followed by the big-endian `roc` for SRTP),
  /// truncated to `length` bytes.
  func tag(_ authenticated: ArraySlice<UInt8>, roc: UInt32?, length: Int) -> [UInt8] {
    var hmac = HMAC<Insecure.SHA1>(key: authKey)
    hmac.update(data: authenticated)
    if let roc { hmac.update(data: SRTPContext.bigEndianBytes(roc)) }
    return Array(Array(hmac.finalize()).prefix(length))
  }
}

// MARK: - AES counter mode

/// AES-CM (RFC 3711 section 4.1.1) and the AES-CM PRF (section 4.3.3).
enum AESCM {
  /// IV = (salt * 2^16) XOR (SSRC * 2^64) XOR (index * 2^16), as 16 bytes.
  static func packetIV(salt: [UInt8], ssrc: UInt32, index: UInt64) -> [UInt8] {
    var iv = [UInt8](repeating: 0, count: 16)
    for (offset, byte) in salt.prefix(14).enumerated() { iv[offset] = byte }
    for i in 0..<4 { iv[4 + i] ^= UInt8(truncatingIfNeeded: ssrc >> (24 - 8 * i)) }
    for i in 0..<6 { iv[8 + i] ^= UInt8(truncatingIfNeeded: index >> (40 - 8 * i)) }
    return iv
  }

  /// Key derivation with key_derivation_rate 0: x = (label || 0^48) XOR master
  /// salt, then `length` bytes of AES-CM keystream under the master key from IV
  /// x * 2^16.
  static func deriveSessionKey(
    masterKey: [UInt8], masterSalt: [UInt8], label: UInt8, length: Int
  ) throws -> [UInt8] {
    guard masterSalt.count == 14 else {
      throw SRTPError(.invalidConfiguration, "master salt must be 14 bytes")
    }
    var iv = masterSalt + [0, 0]
    iv[7] ^= label
    return try keystream(key: masterKey, iv: iv, count: length)
  }

  /// `count` bytes of AES-CTR keystream: E(key, iv), E(key, iv + 1), ...
  /// (128-bit big-endian counter).
  static func keystream(key: [UInt8], iv: [UInt8], count: Int) throws -> [UInt8] {
    guard count > 0 else { return [] }
    guard iv.count == 16, count <= SRTPContext.maxPacketLength else {
      throw SRTPError(.malformedPacket, "keystream request of \(count) bytes is out of range")
    }
    let blockCount = (count + 15) / 16
    var counters = [UInt8](repeating: 0, count: blockCount * 16)
    for block in 0..<blockCount {
      var carry = UInt(block)
      for byte in stride(from: 15, through: 0, by: -1) {
        let sum = UInt(iv[byte]) + (carry & 0xFF)
        counters[block * 16 + byte] = UInt8(truncatingIfNeeded: sum)
        carry = (carry >> 8) + (sum >> 8)
      }
    }
    var output = try encryptBlocks(key: key, counters)
    output.removeLast(output.count - count)
    return output
  }

  /// AES-ECB encryption of whole 16-byte blocks (the counter blocks).
  private static func encryptBlocks(key: [UInt8], _ input: [UInt8]) throws -> [UInt8] {
    guard [16, 24, 32].contains(key.count) else {
      throw SRTPError(.invalidConfiguration, "AES key of \(key.count) bytes")
    }
    var output = [UInt8](repeating: 0, count: input.count)
    var moved = 0
    let status = key.withUnsafeBytes { keyBytes in
      input.withUnsafeBytes { inBytes in
        output.withUnsafeMutableBytes { outBytes in
          CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
            keyBytes.baseAddress, keyBytes.count, nil,
            inBytes.baseAddress, inBytes.count,
            outBytes.baseAddress, outBytes.count, &moved)
        }
      }
    }
    guard status == kCCSuccess, moved == input.count else {
      throw SRTPError(.cryptoFailure, "CCCrypt AES-ECB failed (status \(status))")
    }
    return output
  }
}

// MARK: - Replay window

/// RFC 3711 section 3.3.2 replay list: the highest index accepted plus a bitmap
/// of the 128 indices at and below it.
struct ReplayWindow: Sendable, Equatable {
  static let size: UInt64 = 128

  private(set) var highest: UInt64
  /// Bit k set: index `highest - k` was received (k < 64).
  private var recent: UInt64 = 0
  /// Bit k set: index `highest - 64 - k` was received.
  private var older: UInt64 = 0

  /// A window positioned at `index`, with nothing yet marked received.
  init(first index: UInt64) {
    highest = index
  }

  /// Whether `index` is newer than the window or inside it and not yet received.
  func accepts(_ index: UInt64) -> Bool {
    if index > highest { return true }
    let delta = highest - index
    guard delta < Self.size else { return false }
    let bit = delta < 64 ? recent >> delta : older >> (delta - 64)
    return bit & 1 == 0
  }

  /// Mark `index` received, sliding the window forward if it is the newest.
  mutating func insert(_ index: UInt64) {
    if index > highest {
      let shift = index - highest
      if shift >= Self.size {
        recent = 0
        older = 0
      } else if shift >= 64 {
        older = recent << (shift - 64)
        recent = 0
      } else {
        older = older << shift | recent >> (64 - shift)
        recent = recent << shift
      }
      highest = index
      recent |= 1
      return
    }
    let delta = highest - index
    guard delta < Self.size else { return }
    if delta < 64 {
      recent |= 1 << delta
    } else {
      older |= 1 << (delta - 64)
    }
  }
}
