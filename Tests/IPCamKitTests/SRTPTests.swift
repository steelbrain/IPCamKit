// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Unit tests for SRTP/SRTCP (RFC 3711): key derivation, AES-CM, vectors, ROC, replay, fuzzing.

import Foundation
import Testing

@testable import IPCamKit

// MARK: - Helpers

/// Bytes from a hex string (whitespace ignored). Test vectors only.
private func hexData(_ hex: String) -> Data {
  let digits = Array(hex.filter { !$0.isWhitespace })
  var out = Data()
  var i = 0
  while i + 1 < digits.count {
    out.append(UInt8(String(digits[i...i + 1]), radix: 16) ?? 0)
    i += 2
  }
  return out
}

private func hexString(_ data: some Sequence<UInt8>) -> String {
  data.map { String(format: "%02x", $0) }.joined()
}

/// RFC 3711 Appendix B.3 master key and salt, used by all packet vectors below.
private let vectorKeys = SRTPKeyMaterial(
  masterKey: hexData("e1f97a0d3e018be0d64fa32c06de4139"),
  masterSalt: hexData("0ec675ad498afeebb6960b3aabe6"))

/// A plain RTP packet: V=2, optional marker, PT 96, the given CSRCs and
/// one-word header extension, and `payload`.
private func rtpPacket(
  seq: UInt16, ssrc: UInt32, payload: [UInt8] = Array(0..<40), csrcs: [UInt32] = [],
  extensionWord: UInt32? = nil
) -> Data {
  var bytes: [UInt8] = [
    0x80 | (extensionWord == nil ? 0 : 0x10) | UInt8(csrcs.count & 0x0F), 0x60,
    UInt8(seq >> 8), UInt8(seq & 0xFF), 0x00, 0x01, 0xE2, 0x40,
  ]
  bytes += SRTPContext.bigEndianBytes(ssrc)
  for csrc in csrcs { bytes += SRTPContext.bigEndianBytes(csrc) }
  if let extensionWord {
    bytes += [0xBE, 0xDE, 0x00, 0x01] + SRTPContext.bigEndianBytes(extensionWord)
  }
  return Data(bytes + payload)
}

/// A compound RTCP packet: a sender report from `ssrc` plus an SDES CNAME chunk.
private func rtcpCompound(ssrc: UInt32) -> Data {
  var bytes: [UInt8] = [0x80, 0xC8, 0x00, 0x06] + SRTPContext.bigEndianBytes(ssrc)
  bytes += [0xE9, 0xA3, 0xB1, 0xC2, 0xD4, 0x00, 0x00, 0x00]  // NTP
  bytes += [0x00, 0x01, 0x23, 0x45, 0x00, 0x00, 0x00, 0x2A, 0x00, 0x00, 0x10, 0x00]
  bytes += [0x81, 0xCA, 0x00, 0x03] + SRTPContext.bigEndianBytes(ssrc)
  bytes += [0x01, 0x04, 0x61, 0x62, 0x63, 0x00, 0x00, 0x00]
  return Data(bytes)
}

private func expectSRTPError(
  _ kind: SRTPError.Kind, sourceLocation: SourceLocation = #_sourceLocation,
  _ body: () throws -> Void
) {
  do {
    try body()
    Issue.record("expected SRTPError \(kind), got success", sourceLocation: sourceLocation)
  } catch let error as SRTPError {
    #expect(error.kind == kind, "\(error)", sourceLocation: sourceLocation)
  } catch {
    Issue.record("expected SRTPError \(kind), got \(error)", sourceLocation: sourceLocation)
  }
}

// MARK: - Policy and keys

@Suite("SRTP policy and key validation")
struct SRTPPolicyTests {

  @Test("The default policy is AES_CM_128_HMAC_SHA1_80")
  func defaultPolicy() throws {
    let policy = SRTPPolicy.aesCM128HMACSHA1_80
    #expect(policy.cipher == .aesCM128)
    #expect(policy.auth == .hmacSHA1)
    #expect(policy.encryptionKeyLength == 16)
    #expect(policy.authKeyLength == 20)
    #expect(policy.authTagLength == 10)
    #expect(policy.saltLength == 14)
    #expect(policy.rtpEncryption && policy.rtcpEncryption && policy.rtpAuthentication)
    #expect(policy.rtpTagLength == 10 && policy.rtcpTagLength == 10)
    _ = try SRTPContext(keys: vectorKeys, policy: policy)
  }

  @Test("Wrong master key or salt lengths are rejected")
  func keyLengths() {
    let policy = SRTPPolicy.aesCM128HMACSHA1_80
    for keyLength in [0, 15, 17, 32] {
      let keys = SRTPKeyMaterial(
        masterKey: Data(repeating: 1, count: keyLength), masterSalt: Data(count: 14))
      expectSRTPError(.invalidConfiguration) { _ = try SRTPContext(keys: keys, policy: policy) }
    }
    for saltLength in [0, 12, 13, 15, 16] {
      let keys = SRTPKeyMaterial(
        masterKey: Data(count: 16), masterSalt: Data(repeating: 1, count: saltLength))
      expectSRTPError(.invalidConfiguration) { _ = try SRTPContext(keys: keys, policy: policy) }
    }
  }

  @Test("Unsupported policy lengths are rejected")
  func policyLengths() {
    var aes256 = SRTPPolicy.aesCM128HMACSHA1_80
    aes256.encryptionKeyLength = 32
    var noTag = SRTPPolicy.aesCM128HMACSHA1_80
    noTag.authTagLength = 0
    var longTag = SRTPPolicy.aesCM128HMACSHA1_80
    longTag.authTagLength = 21
    var noAuthKey = SRTPPolicy.aesCM128HMACSHA1_80
    noAuthKey.authKeyLength = 0
    var salt12 = SRTPPolicy.aesCM128HMACSHA1_80
    salt12.saltLength = 12
    for policy in [aes256, noTag, longTag, noAuthKey, salt12] {
      expectSRTPError(.invalidConfiguration) { try policy.validate() }
      expectSRTPError(.invalidConfiguration) {
        _ = try SRTPContext(keys: vectorKeys, policy: policy)
      }
    }
  }

  @Test("NULL cipher and NULL auth policies are accepted")
  func nullPolicies() throws {
    var nullCipher = SRTPPolicy.aesCM128HMACSHA1_80
    nullCipher.cipher = .null
    nullCipher.encryptionKeyLength = 0
    var nullAuth = SRTPPolicy.aesCM128HMACSHA1_80
    nullAuth.auth = .null
    nullAuth.authTagLength = 0
    #expect(nullAuth.rtpTagLength == 0 && nullAuth.rtcpTagLength == 0)
    _ = try SRTPContext(keys: vectorKeys, policy: nullCipher)
    _ = try SRTPContext(keys: vectorKeys, policy: nullAuth)
  }

  @Test("Key material never prints key bytes; random keys have the policy's sizes")
  func keyMaterial() {
    #expect(vectorKeys.description == "SRTPKeyMaterial(16-byte key, 14-byte salt)")
    let a = SRTPKeyMaterial.random()
    let b = SRTPKeyMaterial.random()
    #expect(a.masterKey.count == 16 && a.masterSalt.count == 14)
    #expect(a != b)
  }
}

// MARK: - Crypto vectors

/// Expected values were computed independently with the openssl CLI
/// (`enc -aes-128-ecb/-aes-128-ctr`, `dgst -sha1 -mac HMAC`). The B.2/B.3 values
/// equal RFC 3711 Appendix B, and the first SRTP packet equals libsrtp's
/// `srtp_validate` vector.
@Suite("SRTP crypto vectors")
struct SRTPVectorTests {

  @Test("AES-CM keystream matches RFC 3711 B.2")
  func aesCMKeystream() throws {
    let key = [UInt8](hexData("2B7E151628AED2A6ABF7158809CF4F3C"))
    let iv = [UInt8](hexData("F0F1F2F3F4F5F6F7F8F9FAFBFCFD0000"))
    let stream = try AESCM.keystream(key: key, iv: iv, count: 48)
    #expect(
      hexString(stream)
        == "e03ead0935c95e80e166b16dd92b4eb4d23513162b02d0f72a43a2fe4a5f97ab"
        + "41e95b3bb0a2e8dd477901e4fca894c0")
    // The tail of the B.2 table: counter blocks 0xFEFF, 0xFF00, 0xFF01.
    let tailIV = [UInt8](hexData("F0F1F2F3F4F5F6F7F8F9FAFBFCFDFEFF"))
    let tail = try AESCM.keystream(key: key, iv: tailIV, count: 48)
    #expect(
      hexString(tail)
        == "ec8cdf7398607cb0f2d21675ea9ea1e4362b7c3c6773516318a077d7fc5073ae"
        + "6a2cc3787889374fbeb4c81b17ba6c44")
    // A partial final block is truncated, not padded.
    #expect(try AESCM.keystream(key: key, iv: iv, count: 5) == Array(stream.prefix(5)))
  }

  @Test("Key derivation matches RFC 3711 B.3 (labels 0-2) and openssl (labels 3-5)")
  func keyDerivation() throws {
    let key = [UInt8](vectorKeys.masterKey)
    let salt = [UInt8](vectorKeys.masterSalt)
    func derive(_ label: UInt8, _ length: Int) throws -> String {
      hexString(
        try AESCM.deriveSessionKey(masterKey: key, masterSalt: salt, label: label, length: length)
      )
    }
    #expect(try derive(0, 16) == "c61e7a93744f39ee10734afe3ff7a087")
    #expect(
      try derive(1, 94)
        == "cebe321f6ff7716b6fd4ab49af256a156d38baa48f0a0acf3c34e2359e6cdbce"
        + "e049646c43d9327ad175578ef72270986371c10c9a369ac2f94a8c5fbcdddc25"
        + "6d6e919a48b610ef17c2041e474035766b68642c59bbfc2f34db60dbdfb2")
    #expect(try derive(2, 14) == "30cbbc08863d8c85d49db34a9ae1")
    #expect(try derive(3, 16) == "4c1aa45a81f73d61c800bbb00fbb1eaa")
    #expect(try derive(4, 20) == "8d54534feb49ae8e7993a6bd0b844fc323a93dfd")
    #expect(try derive(5, 14) == "9581c7ad87b3e530bf3e4454a8b3")
  }

  @Test("SRTP packet with an 80-bit tag matches the independent vector")
  func srtpVector80() throws {
    let plain = hexData("800f1234decafbadcafebabe" + String(repeating: "ab", count: 16))
    let expected = hexData(
      "800f1234decafbadcafebabe4e55dc4ce79978d88ca4d215949d2402b78d6acc99ea179b8dbb")
    var sender = try SRTPContext(keys: vectorKeys, policy: .aesCM128HMACSHA1_80)
    #expect(try sender.protectRTP(plain) == expected)
    var receiver = try SRTPContext(keys: vectorKeys, policy: .aesCM128HMACSHA1_80)
    #expect(try receiver.unprotectRTP(expected) == plain)
  }

  @Test("SRTP packet with a 32-bit tag matches the independent vector")
  func srtpVector32() throws {
    var policy = SRTPPolicy.aesCM128HMACSHA1_80
    policy.authTagLength = 4
    let plain = hexData("800f1234decafbadcafebabe" + String(repeating: "ab", count: 16))
    let expected = hexData(
      "800f1234decafbadcafebabe4e55dc4ce79978d88ca4d215949d2402b78d6acc")
    var sender = try SRTPContext(keys: vectorKeys, policy: policy)
    #expect(try sender.protectRTP(plain) == expected)
    var receiver = try SRTPContext(keys: vectorKeys, policy: policy)
    #expect(try receiver.unprotectRTP(expected) == plain)
  }

  @Test("SRTP with CSRCs, a header extension and ROC 5 matches the independent vector")
  func srtpVectorCSRCExtensionROC() throws {
    let plain = hexData(
      "92e0fffe0001e240123456781111111122222222bede0001aabbccdd"
        + "000102030405060708090a0b0c0d0e0f10111213141516")
    let expected = hexData(
      "92e0fffe0001e240123456781111111122222222bede0001aabbccdd"
        + "c4906203419f5e2350057b518b89fee20aaf27ac3574ba73ebc0b25c0784ff0b58")
    var sender = try SRTPContext(keys: vectorKeys, policy: .aesCM128HMACSHA1_80)
    sender.setROC(5, forSSRC: 0x1234_5678)
    #expect(try sender.protectRTP(plain) == expected)
    var receiver = try SRTPContext(keys: vectorKeys, policy: .aesCM128HMACSHA1_80)
    receiver.setROC(5, forSSRC: 0x1234_5678)
    #expect(try receiver.unprotectRTP(expected) == plain)
    #expect(receiver.currentROC(forSSRC: 0x1234_5678) == 5)

    // Without the ROC the receiver authenticates with ROC 0 and must reject it.
    var unseeded = try SRTPContext(keys: vectorKeys, policy: .aesCM128HMACSHA1_80)
    expectSRTPError(.authenticationFailed) { _ = try unseeded.unprotectRTP(expected) }
  }

  @Test("SRTCP compound packet matches the independent vector (index 1, E=1)")
  func srtcpVector() throws {
    let plain = rtcpCompound(ssrc: 0xCAFE_BABE)
    #expect(
      hexString(plain)
        == "80c80006cafebabee9a3b1c2d4000000000123450000002a00001000"
        + "81ca0003cafebabe0104616263000000")
    let expected = hexData(
      "80c80006cafebabe332019329b2c1216155218af52dc0e297e44032a40de2d24"
        + "555b419714b15a03a3769a3e8000000164b618c4239a6480c777")
    var sender = try SRTPContext(keys: vectorKeys, policy: .aesCM128HMACSHA1_80)
    let first = try sender.protectRTCP(plain)
    #expect(first.suffix(14).prefix(4) == Data([0x80, 0, 0, 0]), "index 0, E set")
    #expect(try sender.protectRTCP(plain) == expected)

    var receiver = try SRTPContext(keys: vectorKeys, policy: .aesCM128HMACSHA1_80)
    #expect(try receiver.unprotectRTCP(expected) == plain)
    #expect(try receiver.unprotectRTCP(first) == plain)
  }

  @Test("Unencrypted SRTCP (E=0) at the top index matches the independent vector")
  func srtcpUnencryptedVector() throws {
    let plain = rtcpCompound(ssrc: 0xCAFE_BABE)
    let packet = hexData(
      hexString(plain) + "7ffffffffdf6e8333cff21896239")
    var receiver = try SRTPContext(keys: vectorKeys, policy: .aesCM128HMACSHA1_80)
    #expect(try receiver.unprotectRTCP(packet) == plain)
  }
}

// MARK: - Protect / unprotect behavior

@Suite("SRTP protect and unprotect")
struct SRTPProtectTests {

  @Test("RTP with CSRCs and an extension round-trips; only the payload is encrypted")
  func rtpRoundTrip() throws {
    let keys = SRTPKeyMaterial.random()
    var sender = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    var receiver = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    let plain = rtpPacket(
      seq: 100, ssrc: 0xDEAD_BEEF, csrcs: [1, 2, 3], extensionWord: 0x0102_0304)
    let headerLength = 12 + 12 + 8
    let protected = try sender.protectRTP(plain)
    #expect(protected.count == plain.count + 10)
    #expect(protected.prefix(headerLength) == plain.prefix(headerLength))
    #expect(protected.dropFirst(headerLength).prefix(40) != plain.dropFirst(headerLength))
    #expect(try receiver.unprotectRTP(protected) == plain)
  }

  @Test("An empty payload round-trips")
  func emptyPayload() throws {
    let keys = SRTPKeyMaterial.random()
    var sender = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    var receiver = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    let plain = rtpPacket(seq: 1, ssrc: 7, payload: [])
    #expect(try receiver.unprotectRTP(try sender.protectRTP(plain)) == plain)
  }

  @Test("Compound RTCP round-trips with per-SSRC indices")
  func rtcpRoundTrip() throws {
    let keys = SRTPKeyMaterial.random()
    var sender = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    var receiver = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    for round in 0..<3 {
      for ssrc: UInt32 in [0x1111_1111, 0x2222_2222] {
        let plain = rtcpCompound(ssrc: ssrc)
        let protected = try sender.protectRTCP(plain)
        let word = SRTPContext.readUInt32([UInt8](protected), at: plain.count)
        #expect(word == 0x8000_0000 | UInt32(round), "E flag + per-SSRC index")
        #expect(protected.prefix(8) == plain.prefix(8), "first header stays clear")
        #expect(try receiver.unprotectRTCP(protected) == plain)
      }
    }
  }

  @Test("RTCP encryption off clears the E flag but still authenticates")
  func rtcpEncryptionOff() throws {
    var policy = SRTPPolicy.aesCM128HMACSHA1_80
    policy.rtcpEncryption = false
    let keys = SRTPKeyMaterial.random()
    var sender = try SRTPContext(keys: keys, policy: policy)
    var receiver = try SRTPContext(keys: keys, policy: policy)
    let plain = rtcpCompound(ssrc: 9)
    let protected = try sender.protectRTCP(plain)
    #expect(protected.prefix(plain.count) == plain)
    #expect(SRTPContext.readUInt32([UInt8](protected), at: plain.count) == 0)
    var tampered = protected
    tampered[10] ^= 1
    expectSRTPError(.authenticationFailed) { _ = try receiver.unprotectRTCP(tampered) }
    #expect(try receiver.unprotectRTCP(protected) == plain)
  }

  @Test("NULL cipher leaves payloads clear; NULL auth adds no tag")
  func nullTransforms() throws {
    var nullCipher = SRTPPolicy.aesCM128HMACSHA1_80
    nullCipher.cipher = .null
    var sender = try SRTPContext(keys: vectorKeys, policy: nullCipher)
    var receiver = try SRTPContext(keys: vectorKeys, policy: nullCipher)
    let plain = rtpPacket(seq: 5, ssrc: 5)
    let tagged = try sender.protectRTP(plain)
    #expect(tagged.prefix(plain.count) == plain && tagged.count == plain.count + 10)
    #expect(try receiver.unprotectRTP(tagged) == plain)

    var nullBoth = nullCipher
    nullBoth.auth = .null
    var clearSender = try SRTPContext(keys: vectorKeys, policy: nullBoth)
    var clearReceiver = try SRTPContext(keys: vectorKeys, policy: nullBoth)
    #expect(try clearSender.protectRTP(plain) == plain)
    #expect(try clearReceiver.unprotectRTP(plain) == plain)
    let rtcp = rtcpCompound(ssrc: 5)
    let protectedRTCP = try clearSender.protectRTCP(rtcp)
    #expect(protectedRTCP.count == rtcp.count + 4)
    #expect(try clearReceiver.unprotectRTCP(protectedRTCP) == rtcp)

    var noRTPAuth = SRTPPolicy.aesCM128HMACSHA1_80
    noRTPAuth.rtpAuthentication = false
    var untaggedSender = try SRTPContext(keys: vectorKeys, policy: noRTPAuth)
    var untaggedReceiver = try SRTPContext(keys: vectorKeys, policy: noRTPAuth)
    let untagged = try untaggedSender.protectRTP(plain)
    #expect(untagged.count == plain.count && untagged != plain)
    #expect(try untaggedReceiver.unprotectRTP(untagged) == plain)
    #expect(try untaggedSender.protectRTCP(rtcp).count == rtcp.count + 14, "SRTCP keeps its tag")
  }

  @Test("Tampering with header, payload or tag is rejected without committing state")
  func tampering() throws {
    let keys = SRTPKeyMaterial.random()
    var sender = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    var receiver = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    let protected = try sender.protectRTP(rtpPacket(seq: 10, ssrc: 77))
    for offset in [1, 4, 11, 12, 30, protected.count - 1] {
      var tampered = protected
      tampered[offset] ^= 0x01
      expectSRTPError(.authenticationFailed) { _ = try receiver.unprotectRTP(tampered) }
    }
    // A forged packet that claims a far-future sequence number must not move the ROC.
    var forged = protected
    forged[2] = 0x90
    expectSRTPError(.authenticationFailed) { _ = try receiver.unprotectRTP(forged) }
    #expect(receiver.currentROC(forSSRC: 77) == nil)
    #expect(try receiver.unprotectRTP(protected) == rtpPacket(seq: 10, ssrc: 77))

    let rtcp = try sender.protectRTCP(rtcpCompound(ssrc: 77))
    for offset in [0, 9, rtcp.count - 14, rtcp.count - 1] {
      var tampered = rtcp
      tampered[offset] ^= 0x40
      expectSRTPError(offset == 0 ? .malformedPacket : .authenticationFailed) {
        _ = try receiver.unprotectRTCP(tampered)
      }
    }
    #expect(try receiver.unprotectRTCP(rtcp) == rtcpCompound(ssrc: 77))
  }

  @Test("Replays are rejected; reordering inside the window is accepted")
  func replay() throws {
    let keys = SRTPKeyMaterial.random()
    var sender = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    var receiver = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    let packets = try (1000..<1200).map { try sender.protectRTP(rtpPacket(seq: $0, ssrc: 3)) }
    _ = try receiver.unprotectRTP(packets[0])
    expectSRTPError(.replayed) { _ = try receiver.unprotectRTP(packets[0]) }
    _ = try receiver.unprotectRTP(packets[150])
    // 150 - 30 = 120 behind: inside the 128-packet window, never seen.
    _ = try receiver.unprotectRTP(packets[30])
    expectSRTPError(.replayed) { _ = try receiver.unprotectRTP(packets[30]) }
    // 150 - 10 = 140 behind: older than the window.
    expectSRTPError(.replayed) { _ = try receiver.unprotectRTP(packets[10]) }
    _ = try receiver.unprotectRTP(packets[151])

    let rtcp0 = try sender.protectRTCP(rtcpCompound(ssrc: 3))
    let rtcp1 = try sender.protectRTCP(rtcpCompound(ssrc: 3))
    _ = try receiver.unprotectRTCP(rtcp1)
    _ = try receiver.unprotectRTCP(rtcp0)
    expectSRTPError(.replayed) { _ = try receiver.unprotectRTCP(rtcp0) }
    expectSRTPError(.replayed) { _ = try receiver.unprotectRTCP(rtcp1) }
  }

  @Test("ROC rolls over across the sequence wrap, including a late packet")
  func rocRollover() throws {
    let keys = SRTPKeyMaterial.random()
    var sender = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    var receiver = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    let seqs: [UInt16] = Array(65530...65535) + Array(0...5)
    var protected: [UInt16: Data] = [:]
    for seq in seqs {
      protected[seq] = try sender.protectRTP(rtpPacket(seq: seq, ssrc: 42))
    }
    #expect(sender.currentROC(forSSRC: 42) == 1)

    // Deliver everything except 65534, which arrives late, after the wrap.
    for seq in seqs where seq != 65534 {
      let packet = try #require(protected[seq])
      #expect(try receiver.unprotectRTP(packet) == rtpPacket(seq: seq, ssrc: 42))
      #expect(receiver.currentROC(forSSRC: 42) == (seq >= 65530 ? 0 : 1))
    }
    let late = try #require(protected[65534])
    #expect(try receiver.unprotectRTP(late) == rtpPacket(seq: 65534, ssrc: 42))
    #expect(receiver.currentROC(forSSRC: 42) == 1, "a late packet does not roll ROC back")

    // The late packet authenticated with ROC 0: replaying it is still caught.
    expectSRTPError(.replayed) { _ = try receiver.unprotectRTP(late) }

    // A second wrap.
    for seq in stride(from: UInt16(10_000), through: 60_000, by: 10_000) {
      _ = try receiver.unprotectRTP(try sender.protectRTP(rtpPacket(seq: seq, ssrc: 42)))
    }
    for seq: UInt16 in [100, 30_000] {
      _ = try receiver.unprotectRTP(try sender.protectRTP(rtpPacket(seq: seq, ssrc: 42)))
    }
    #expect(receiver.currentROC(forSSRC: 42) == 2)
    #expect(sender.currentROC(forSSRC: 42) == 2)
  }

  @Test("A packet from before the stream start (ROC would be -1) is rejected")
  func beforeStreamStart() throws {
    let keys = SRTPKeyMaterial.random()
    var sender = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    var receiver = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    let early = try sender.protectRTP(rtpPacket(seq: 65000, ssrc: 1))
    var other = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    _ = try receiver.unprotectRTP(try other.protectRTP(rtpPacket(seq: 10, ssrc: 1)))
    expectSRTPError(.replayed) { _ = try receiver.unprotectRTP(early) }
    expectSRTPError(.malformedPacket) { _ = try other.protectRTP(rtpPacket(seq: 40000, ssrc: 1)) }
  }

  @Test("SSRCs are tracked independently and the initial ROC applies per SSRC")
  func multipleSSRCs() throws {
    let keys = SRTPKeyMaterial.random()
    var sender = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    var receiver = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    sender.setROC(9, forSSRC: 2)
    receiver.setROC(9, forSSRC: 2)
    for seq: UInt16 in [1, 2, 3] {
      for ssrc: UInt32 in [1, 2, 3] {
        let plain = rtpPacket(seq: seq, ssrc: ssrc)
        #expect(try receiver.unprotectRTP(try sender.protectRTP(plain)) == plain)
      }
    }
    #expect(receiver.currentROC(forSSRC: 1) == 0)
    #expect(receiver.currentROC(forSSRC: 2) == 9)
    #expect(receiver.currentROC(forSSRC: 4) == nil)
  }

  @Test("A Data slice with a nonzero startIndex is handled")
  func dataSlices() throws {
    let keys = SRTPKeyMaterial.random()
    var sender = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    var receiver = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    let plain = rtpPacket(seq: 8, ssrc: 8, csrcs: [5], extensionWord: 6)
    let protected = try sender.protectRTP((Data([0xFF, 0xFF, 0xFF]) + plain).dropFirst(3))
    let slice = (Data([0, 0, 0, 0, 0]) + protected + Data([1])).dropFirst(5).dropLast()
    #expect(slice.startIndex == 5)
    let result = try receiver.unprotectRTP(slice)
    #expect(result == plain && result.startIndex == 0)

    let rtcp = try sender.protectRTCP(rtcpCompound(ssrc: 8))
    #expect(try receiver.unprotectRTCP((Data([9]) + rtcp).dropFirst()) == rtcpCompound(ssrc: 8))
  }
}

// MARK: - Hostile input

@Suite("SRTP hostile input")
struct SRTPHostileInputTests {

  @Test("Truncated and malformed packets throw")
  func malformed() throws {
    let keys = SRTPKeyMaterial.random()
    var context = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    for length in 0..<22 {
      let packet = Data(repeating: 0x80, count: length)
      expectSRTPError(.malformedPacket) { _ = try context.unprotectRTP(packet) }
      if length < 8 {
        expectSRTPError(.malformedPacket) { _ = try context.protectRTCP(packet) }
      }
      if length < 22 {
        expectSRTPError(.malformedPacket) { _ = try context.unprotectRTCP(packet) }
      }
      if length < 12 {
        expectSRTPError(.malformedPacket) { _ = try context.protectRTP(packet) }
      }
    }
    // Wrong version.
    for first: UInt8 in [0x00, 0x40, 0xC0] {
      var packet = rtpPacket(seq: 1, ssrc: 1)
      packet[0] = first
      expectSRTPError(.malformedPacket) { _ = try context.protectRTP(packet) }
      expectSRTPError(.malformedPacket) { _ = try context.unprotectRTP(packet + Data(count: 10)) }
      var rtcp = rtcpCompound(ssrc: 1)
      rtcp[0] = first
      expectSRTPError(.malformedPacket) { _ = try context.protectRTCP(rtcp) }
      expectSRTPError(.malformedPacket) { _ = try context.unprotectRTCP(rtcp + Data(count: 14)) }
    }
    // 15 CSRCs in a short packet; extension header past the end; huge extension length.
    let manyCSRCs = Data(
      [0x8F, 0x60, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1] + [UInt8](repeating: 0, count: 30))
    expectSRTPError(.malformedPacket) { _ = try context.protectRTP(manyCSRCs) }
    expectSRTPError(.malformedPacket) { _ = try context.unprotectRTP(manyCSRCs + Data(count: 10)) }
    let shortExtension = Data([0x90, 0x60, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0xBE, 0xDE])
    expectSRTPError(.malformedPacket) { _ = try context.protectRTP(shortExtension) }
    let hugeExtension = Data(
      [0x90, 0x60, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0xBE, 0xDE, 0xFF, 0xFF]
        + [UInt8](repeating: 0, count: 40))
    expectSRTPError(.malformedPacket) { _ = try context.protectRTP(hugeExtension) }
    expectSRTPError(.malformedPacket) { _ = try context.unprotectRTP(hugeExtension) }
    // The header must end before the tag.
    let headerIntoTag = Data(
      [0x81, 0x60, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1] + [UInt8](repeating: 0, count: 12))
    expectSRTPError(.malformedPacket) { _ = try context.unprotectRTP(headerIntoTag) }
    // Oversized packets.
    let oversized = rtpPacket(seq: 1, ssrc: 1, payload: [UInt8](repeating: 0, count: 65536 * 16))
    expectSRTPError(.malformedPacket) { _ = try context.protectRTP(oversized) }
  }

  @Test("Random and mutated packets never trap")
  func fuzz() throws {
    let keys = SRTPKeyMaterial.random()
    var sender = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    var receiver = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    var rng = SystemRandomNumberGenerator()
    let valid = try sender.protectRTP(rtpPacket(seq: 1, ssrc: 1, csrcs: [1], extensionWord: 2))
    let validRTCP = try sender.protectRTCP(rtcpCompound(ssrc: 1))
    var accepted = 0
    for i in 0..<3000 {
      let packet: Data
      switch i % 3 {
      case 0:
        let length = Int.random(in: 0..<80, using: &rng)
        packet = Data((0..<length).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
      case 1:
        var mutated = [UInt8](valid)
        mutated[Int.random(in: 0..<mutated.count, using: &rng)] = .random(in: .min ... .max)
        packet = Data(mutated.prefix(Int.random(in: 0...mutated.count, using: &rng)))
      default:
        var mutated = [UInt8](validRTCP)
        mutated[Int.random(in: 0..<mutated.count, using: &rng)] = .random(in: .min ... .max)
        packet = Data(mutated.prefix(Int.random(in: 0...mutated.count, using: &rng)))
      }
      if (try? receiver.unprotectRTP(packet)) != nil { accepted += 1 }
      if (try? receiver.unprotectRTCP(packet)) != nil { accepted += 1 }
      _ = try? sender.protectRTP(packet)
      _ = try? sender.protectRTCP(packet)
    }
    // Only an unmodified full-length copy of a valid packet can authenticate.
    #expect(accepted <= 2)
  }

  @Test("Replay window bookkeeping across large jumps")
  func replayWindow() {
    var window = ReplayWindow(first: 1000)
    window.insert(1000)
    #expect(!window.accepts(1000))
    #expect(window.accepts(999) && window.accepts(1001))
    window.insert(1064)  // shift by exactly 64
    #expect(!window.accepts(1000) && !window.accepts(1064))
    #expect(window.accepts(1001) && window.accepts(1063))
    window.insert(1100)  // 1000 is now 100 behind: still tracked in the older word
    #expect(!window.accepts(1000) && window.accepts(1001))
    window.insert(1127)
    #expect(!window.accepts(1000), "127 behind: inside the window, seen")
    window.insert(1128)
    #expect(!window.accepts(1000), "128 behind: outside the window")
    #expect(!window.accepts(1064) && window.accepts(1065))
    window.insert(5000)  // a jump beyond the window clears it
    #expect(!window.accepts(1128) && window.accepts(4999) && !window.accepts(5000))
    window.insert(4873)
    #expect(!window.accepts(4873) && window.accepts(4874))
    #expect(!window.accepts(4872), "128 behind")
  }
}
