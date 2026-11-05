// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Unit tests for MIKEY (RFC 3830) parsing/building and the RTSP KeyMgmt / SDP key-mgmt syntax.

import Foundation
import Testing

@testable import IPCamKit

// MARK: - Fixtures

/// `a=key-mgmt:mikey` values from a mediamtx v1.21 DESCRIBE response (video, audio).
private let mediamtxVideoMIKEY =
  "AQAFACAMARUBAAD3LlRtAAAAAAsA7pVYTbwG0NUKEE1ZisGkJsJKYvpq2rcXQdsBAAAAGAABAQEB"
  + "EAIBAQMBFAcBAQgBAQoBAQsBCgAAACIAIAAe+/0ksBKOzeXVRHiMbq92Mc/gFo+Bqo16dpMmHHjK"
  + "AA=="
private let mediamtxAudioMIKEY =
  "AQAFAHunpGsBAABUVbOaAAAAAAsA7pVYTbwHAyoKEHQe9bGH5b5D/QHquUX3GoEBAAAAGAABAQEB"
  + "EAIBAQMBFAcBAQgBAQoBAQsBCgAAACIAIAAeegTtMgpKAiUeYwgp6LiaeQ0NsBatWxm1Q3Pb/1y8"
  + "AA=="

/// The `KeyMgmt` header of a mediamtx SETUP response (its MIKEY repeats the video key).
private let mediamtxSetupKeyMgmt =
  "prot=mikey;uri=\"rtsps://127.0.0.1:48322/probe/trackID=0\";data=\""
  + "AQAFAK3S59EBAAD3LlRtAAAAAAsA7pVYdKc4tHwKEJi7D4Po8TVOv/Ou0SjIzSIBAAAAGAABAQEB"
  + "EAIBAQMBFAcBAQgBAQoBAQsBCgAAACIAIAAe+/0ksBKOzeXVRHiMbq92Mc/gFo+Bqo16dpMmHHjK"
  + "AA==" + "\""

private func base64(_ string: String) throws -> Data {
  try #require(Data(base64Encoded: string))
}

private func bytesFromHex(_ hex: String) -> Data {
  let digits = Array(hex)
  return Data(
    stride(from: 0, to: digits.count - 1, by: 2).map {
      UInt8(String(digits[$0...$0 + 1]), radix: 16) ?? 0
    })
}

private let defaultSRTPParameters: [UInt8] = [
  0, 1, 1, 1, 1, 16, 2, 1, 1, 3, 1, 20, 7, 1, 1, 8, 1, 1, 10, 1, 1, 11, 1, 10,
]

/// Assemble a MIKEY message from payload bodies (each without its leading
/// next-payload byte), chaining the next-payload fields.
private func mikeyMessage(
  version: UInt8 = 1, dataType: UInt8 = 0,
  sessions: [(UInt8, UInt32, UInt32)] = [(0, 0x1122_3344, 7)],
  payloads: [(type: UInt8, body: [UInt8])]
) -> Data {
  var out: [UInt8] = [version, dataType, payloads.first?.type ?? 0, 0, 0xAA, 0xBB, 0xCC, 0xDD]
  out += [UInt8(sessions.count), 0]
  for (policy, ssrc, roc) in sessions {
    out.append(policy)
    out += SRTPContext.bigEndianBytes(ssrc) + SRTPContext.bigEndianBytes(roc)
  }
  for (i, payload) in payloads.enumerated() {
    out.append(i + 1 < payloads.count ? payloads[i + 1].type : 0)
    out += payload.body
  }
  return Data(out)
}

private let timestampPayload: (type: UInt8, body: [UInt8]) = (
  5, [0] + [UInt8](repeating: 1, count: 8)
)
private let randPayload: (type: UInt8, body: [UInt8]) = (
  11, [16] + [UInt8](repeating: 2, count: 16)
)

private func spPayload(
  policy: UInt8 = 0, _ parameters: [UInt8] = defaultSRTPParameters
)
  -> (type: UInt8, body: [UInt8])
{
  (10, [policy, 0, UInt8(parameters.count >> 8), UInt8(parameters.count & 0xFF)] + parameters)
}

/// KEMAC with NULL encryption/MAC around raw Key Data sub-payload bytes.
private func kemacPayload(
  keyData: [UInt8], encryption: UInt8 = 0, mac: UInt8 = 0
)
  -> (type: UInt8, body: [UInt8])
{
  (1, [encryption, UInt8(keyData.count >> 8), UInt8(keyData.count & 0xFF)] + keyData + [mac])
}

/// A single TEK Key Data sub-payload (`typeKV` = type << 4 | KV).
private func tekKeyData(_ key: [UInt8], typeKV: UInt8 = 0x20, extra: [UInt8] = []) -> [UInt8] {
  [0, typeKV, UInt8(key.count >> 8), UInt8(key.count & 0xFF)] + key + extra
}

private let sampleTEK = [UInt8](0..<30)

private func expectMIKEYError(
  _ kind: SRTPError.Kind, sourceLocation: SourceLocation = #_sourceLocation,
  _ data: Data
) {
  do {
    let message = try MIKEY.parse(data)
    Issue.record("expected \(kind), parsed \(message)", sourceLocation: sourceLocation)
  } catch let error as SRTPError {
    #expect(error.kind == kind, "\(error)", sourceLocation: sourceLocation)
  } catch {
    Issue.record("expected SRTPError \(kind), got \(error)", sourceLocation: sourceLocation)
  }
}

// MARK: - Parsing

@Suite("MIKEY parsing")
struct MIKEYParseTests {

  @Test("mediamtx's video key-mgmt message parses to the hand-decoded values")
  func mediamtxVideo() throws {
    let message = try MIKEY.parse(try base64(mediamtxVideoMIKEY))
    #expect(message.csbID == 0x200C_0115)
    #expect(
      message.cryptoSessions == [MIKEY.CryptoSession(policyNumber: 0, ssrc: 0xF72E_546D, roc: 0)])
    #expect(message.policies == [0: .aesCM128HMACSHA1_80])
    #expect(
      message.keys.masterKey + message.keys.masterSalt
        == bytesFromHex("fbfd24b0128ecde5d544788c6eaf7631cfe0168f81aa8d7a7693261c78ca"))
    #expect(message.keys.masterKey == bytesFromHex("fbfd24b0128ecde5d544788c6eaf7631"))
    #expect(message.keys.masterSalt.count == 14)
  }

  @Test("mediamtx's audio key-mgmt message parses")
  func mediamtxAudio() throws {
    let message = try MIKEY.parse(try base64(mediamtxAudioMIKEY))
    #expect(message.csbID == 0x7BA7_A46B)
    #expect(
      message.cryptoSessions == [MIKEY.CryptoSession(policyNumber: 0, ssrc: 0x5455_B39A, roc: 0)])
    #expect(message.policies == [0: .aesCM128HMACSHA1_80])
    #expect(
      message.keys.masterKey + message.keys.masterSalt
        == bytesFromHex("7a04ed320a4a02251e630829e8b89a790d0db016ad5b19b54373dbff5cbc"))
  }

  @Test("mediamtx's SETUP response KeyMgmt header parses and repeats the SDP key")
  func mediamtxSetupResponse() throws {
    let parsed = try #require(KeyMgmtHeader.parse(mediamtxSetupKeyMgmt))
    #expect(parsed.uri == "rtsps://127.0.0.1:48322/probe/trackID=0")
    let message = try MIKEY.parse(parsed.mikey)
    #expect(message.csbID == 0xADD2_E7D1)
    #expect(message.cryptoSessions.map(\.ssrc) == [0xF72E_546D])
    let sdp = try MIKEY.parse(try base64(mediamtxVideoMIKEY))
    #expect(message.keys == sdp.keys)
  }

  @Test("makeContext seeds each crypto session's ROC")
  func makeContext() throws {
    var message = try MIKEY.parse(try base64(mediamtxVideoMIKEY))
    message.cryptoSessions = [
      MIKEY.CryptoSession(policyNumber: 0, ssrc: 1, roc: 3),
      MIKEY.CryptoSession(policyNumber: 0, ssrc: 2, roc: 0),
    ]
    let context = try message.makeContext()
    #expect(context.policy == .aesCM128HMACSHA1_80)
    #expect(context.currentROC(forSSRC: 1) == 3)
    #expect(context.currentROC(forSSRC: 2) == 0)

    var tag32 = SRTPPolicy.aesCM128HMACSHA1_80
    tag32.authTagLength = 4
    message.policies[1] = tag32
    message.cryptoSessions[1].policyNumber = 1
    #expect(throws: SRTPError.self) { _ = try message.makeContext() }
  }

  @Test("Every truncation of a real message throws")
  func truncations() throws {
    let full = try base64(mediamtxVideoMIKEY)
    for length in 0..<full.count {
      #expect(throws: SRTPError.self) { _ = try MIKEY.parse(full.prefix(length)) }
    }
    // A slice with a nonzero startIndex parses like the original.
    let slice = (Data([0xFF, 0xFF]) + full).dropFirst(2)
    #expect(try MIKEY.parse(slice) == MIKEY.parse(full))
    // Trailing bytes after the last payload are ignored.
    #expect(try MIKEY.parse(full + Data([0, 0])) == MIKEY.parse(full))
  }

  @Test("Random mutations never trap")
  func mutations() throws {
    let full = [UInt8](try base64(mediamtxVideoMIKEY))
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<5000 {
      var mutated = full
      for _ in 0..<Int.random(in: 1...4, using: &rng) {
        mutated[Int.random(in: 0..<mutated.count, using: &rng)] = .random(in: .min ... .max)
      }
      _ = try? MIKEY.parse(Data(mutated))
    }
    for _ in 0..<2000 {
      let length = Int.random(in: 0..<200, using: &rng)
      _ = try? MIKEY.parse(Data((0..<length).map { _ in UInt8.random(in: .min ... .max) }))
    }
  }

  @Test("Encrypted or MAC-protected KEMACs, TGKs, MKIs and other modes are rejected")
  func unsupported() throws {
    let full = [UInt8](try base64(mediamtxVideoMIKEY))
    func mutate(_ offset: Int, _ value: UInt8) -> Data {
      var copy = full
      copy[offset] = value
      return Data(copy)
    }
    expectMIKEYError(.unsupportedMIKEY, mutate(0x00, 2))  // version 2
    expectMIKEYError(.unsupportedMIKEY, mutate(0x01, 2))  // public-key data type
    expectMIKEYError(.unsupportedMIKEY, mutate(0x01, 4))  // Diffie-Hellman data type
    expectMIKEYError(.unsupportedMIKEY, mutate(0x09, 1))  // GENERIC-ID CS map
    expectMIKEYError(.unsupportedMIKEY, mutate(0x36, 2))  // AES-F8
    expectMIKEYError(.unsupportedMIKEY, mutate(0x36, 9))  // unknown cipher
    expectMIKEYError(.unsupportedMIKEY, mutate(0x3C, 2))  // unknown auth algorithm
    expectMIKEYError(.unsupportedMIKEY, mutate(0x39, 32))  // AES-256 key length
    expectMIKEYError(.unsupportedMIKEY, mutate(0x4B, 2))  // 2-byte tag
    expectMIKEYError(.unsupportedMIKEY, mutate(0x31, 1))  // SP protocol type 1
    expectMIKEYError(.unsupportedMIKEY, mutate(0x4D, 1))  // AES-CM encrypted KEMAC
    expectMIKEYError(.unsupportedMIKEY, mutate(0x72, 1))  // HMAC-SHA-1 KEMAC MAC
    expectMIKEYError(.unsupportedMIKEY, mutate(0x51, 0x00))  // TGK
    expectMIKEYError(.unsupportedMIKEY, mutate(0x51, 0x21))  // TEK with SPI/MKI
    expectMIKEYError(.unsupportedMIKEY, mutate(0x13, 3))  // DH payload in the chain
    expectMIKEYError(.unsupportedMIKEY, mutate(0x13, 99))  // unknown payload type
    expectMIKEYError(.unsupportedMIKEY, mutate(0x14, 7))  // unknown timestamp type

    // KDR, PRF and prefix length must be the defaults.
    for parameter: [UInt8] in [[6, 1, 4], [5, 1, 1], [12, 1, 8]] {
      expectMIKEYError(
        .unsupportedMIKEY,
        mikeyMessage(payloads: [
          timestampPayload, randPayload, spPayload(defaultSRTPParameters + parameter),
          kemacPayload(keyData: tekKeyData(sampleTEK)),
        ]))
    }
  }

  @Test("Inconsistent messages are malformed")
  func malformed() {
    // TEK of the wrong length.
    expectMIKEYError(
      .malformedMIKEY,
      mikeyMessage(payloads: [
        timestampPayload, kemacPayload(keyData: tekKeyData(Array(sampleTEK.prefix(16)))),
      ]))
    // No KEMAC at all.
    expectMIKEYError(.malformedMIKEY, mikeyMessage(payloads: [timestampPayload, randPayload]))
    // Two SPs with the same policy number.
    expectMIKEYError(
      .malformedMIKEY,
      mikeyMessage(payloads: [
        spPayload(), spPayload(), kemacPayload(keyData: tekKeyData(sampleTEK)),
      ]))
    // A KEMAC sub-payload chain pointing at a non-Key-Data payload.
    var chained = tekKeyData(sampleTEK)
    chained[0] = 5
    expectMIKEYError(.malformedMIKEY, mikeyMessage(payloads: [kemacPayload(keyData: chained)]))
    // An SP parameter with a 5-byte value.
    expectMIKEYError(
      .malformedMIKEY,
      mikeyMessage(payloads: [
        spPayload([1, 5, 0, 0, 0, 0, 16]), kemacPayload(keyData: tekKeyData(sampleTEK)),
      ]))
  }

  @Test("Optional payloads are skipped and defaults fill in missing policies")
  func tolerant() throws {
    // Data type 1 (verification message) with ID, general extension, CHASH and V payloads,
    // a TEK+SALT key, a key-validity interval, no SP payload, and a trailing SIGN.
    let tekSalt =
      [0, 0x32, 0, 16] + [UInt8](repeating: 0xA1, count: 16) + [0, 14]
      + [UInt8](repeating: 0xB2, count: 14) + [2, 0x00, 0x01, 6, 0, 0, 0, 0, 0xFF, 0xFF]
    let data = mikeyMessage(
      dataType: 1, sessions: [(3, 0x0102_0304, 0x10), (3, 0x0506_0708, 0)],
      payloads: [
        timestampPayload,
        (6, [1, 0, 3, 0x61, 0x62, 0x63]),  // ID (URI)
        (21, [0, 0, 2, 9, 9]),  // general extension
        (8, [0] + [UInt8](repeating: 0, count: 20)),  // CHASH SHA-1
        randPayload,
        kemacPayload(keyData: tekSalt),
        (9, [0]),  // V, NULL MAC
        (4, [0x00, 0x02, 0xEE, 0xEE]),  // SIGN: ends the chain
      ])
    let message = try MIKEY.parse(data)
    #expect(message.csbID == 0xAABB_CCDD)
    #expect(message.cryptoSessions.map(\.roc) == [0x10, 0])
    #expect(message.policies == [3: .aesCM128HMACSHA1_80])
    #expect(message.keys.masterKey == Data(repeating: 0xA1, count: 16))
    #expect(message.keys.masterSalt == Data(repeating: 0xB2, count: 14))
  }

  @Test("SP parameters map onto the policy")
  func policyMapping() throws {
    let parameters: [UInt8] = [
      0, 1, 0,  // NULL cipher
      1, 1, 0,  // key length 0
      2, 1, 1, 3, 1, 20, 4, 1, 14,
      5, 1, 0, 6, 1, 0, 9, 1, 0, 12, 1, 0,  // PRF, KDR, FEC, prefix: defaults
      7, 1, 0, 8, 1, 0, 10, 1, 0,
      11, 2, 0, 4,  // 32-bit tag, as a 2-byte value
      200, 3, 1, 2, 3,  // unknown parameter type: ignored
    ]
    let message = try MIKEY.parse(
      mikeyMessage(payloads: [spPayload(parameters), kemacPayload(keyData: tekKeyData(sampleTEK))]))
    let policy = try #require(message.policies[0])
    #expect(policy.cipher == .null && policy.encryptionKeyLength == 0)
    #expect(policy.auth == .hmacSHA1 && policy.authKeyLength == 20 && policy.authTagLength == 4)
    #expect(!policy.rtpEncryption && !policy.rtcpEncryption && !policy.rtpAuthentication)
    #expect(message.keys.masterKey == Data(sampleTEK.prefix(16)))
    #expect(message.keys.masterSalt == Data(sampleTEK.suffix(14)))
  }
}

// MARK: - Building

@Suite("MIKEY building")
struct MIKEYBuildTests {

  @Test("The initiator message reproduces mediamtx's layout byte for byte")
  func matchesMediamtx() throws {
    let original = try base64(mediamtxVideoMIKEY)
    let parsed = try MIKEY.parse(original)
    let built = MIKEY.makeInitiatorMessage(
      cryptoSessions: parsed.cryptoSessions, keys: parsed.keys, csbID: parsed.csbID,
      timestamp: Date(timeIntervalSince1970: 0),
      rand: bytesFromHex("4d598ac1a426c24a62fa6adab71741db"))
    #expect(built.count == original.count)
    // Identical except the 8 NTP timestamp bytes (offsets 21..<29).
    var masked = [UInt8](built)
    masked.replaceSubrange(21..<29, with: [UInt8](original)[21..<29])
    #expect(Data(masked) == original)
    #expect(
      MIKEY.ntpTimestamp(Date(timeIntervalSince1970: 0)) == [0x83, 0xAA, 0x7E, 0x80, 0, 0, 0, 0])
  }

  @Test("Build then parse round-trips sessions, policy and keys")
  func roundTrip() throws {
    let keys = SRTPKeyMaterial.random()
    var policy = SRTPPolicy.aesCM128HMACSHA1_80
    policy.authTagLength = 4
    policy.rtcpEncryption = false
    let sessions = [
      MIKEY.CryptoSession(policyNumber: 1, ssrc: 0xDEAD_BEEF, roc: 0xFFFF_FFFF),
      MIKEY.CryptoSession(policyNumber: 2, ssrc: 0x0000_0001, roc: 5),
      MIKEY.CryptoSession(policyNumber: 1, ssrc: 0x8000_0000, roc: 0),
    ]
    let data = MIKEY.makeInitiatorMessage(
      cryptoSessions: sessions, keys: keys, policy: policy, csbID: 0x0102_0304)
    let message = try MIKEY.parse(data)
    #expect(message.csbID == 0x0102_0304)
    #expect(message.cryptoSessions == sessions)
    #expect(message.policies == [1: policy, 2: policy])
    #expect(message.keys == keys)

    // Defaults: random CSB ID and RAND, policy number 0 when there are no sessions.
    let a = MIKEY.makeInitiatorMessage(cryptoSessions: [], keys: keys)
    let b = MIKEY.makeInitiatorMessage(cryptoSessions: [], keys: keys)
    #expect(a != b)
    let empty = try MIKEY.parse(a)
    #expect(empty.cryptoSessions.isEmpty && empty.policies == [0: .aesCM128HMACSHA1_80])
    #expect(empty.keys == keys)
  }

  @Test("A built message keys a context that interoperates with the sender")
  func contextFromBuiltMessage() throws {
    let keys = SRTPKeyMaterial.random()
    let session = MIKEY.CryptoSession(policyNumber: 0, ssrc: 0x4242_4242, roc: 2)
    var receiver = try MIKEY.parse(
      MIKEY.makeInitiatorMessage(cryptoSessions: [session], keys: keys)
    ).makeContext()
    var sender = try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80)
    sender.setROC(2, forSSRC: 0x4242_4242)
    let plain = Data([0x80, 0x60, 0, 1, 0, 0, 0, 0, 0x42, 0x42, 0x42, 0x42, 1, 2, 3])
    #expect(try receiver.unprotectRTP(try sender.protectRTP(plain)) == plain)
  }
}

// MARK: - KeyMgmt header and SDP attribute

@Suite("RTSP KeyMgmt header and SDP key-mgmt attribute")
struct KeyMgmtHeaderTests {

  @Test("format produces the RFC 4567 syntax and parses back")
  func formatRoundTrip() throws {
    let mikey = Data([1, 2, 3, 4, 5])
    let value = KeyMgmtHeader.format(uri: "rtsps://cam/stream/trackID=1", mikey: mikey)
    #expect(value == "prot=mikey; uri=\"rtsps://cam/stream/trackID=1\"; data=\"AQIDBAU=\"")
    let parsed = try #require(KeyMgmtHeader.parse(value))
    #expect(parsed.uri == "rtsps://cam/stream/trackID=1")
    #expect(parsed.mikey == mikey)

    let quoted = KeyMgmtHeader.format(uri: "rtsp://h/a\"b", mikey: mikey)
    #expect(quoted.contains("uri=\"rtsp://h/a%22b\""))
  }

  @Test("Spacing, case and quoting variants parse")
  func variants() throws {
    let data = "AQIDBAU="
    let values = [
      "prot=mikey;uri=\"rtsp://h/x\";data=\"\(data)\"",
      "  prot = mikey ;  uri = \"rtsp://h/x\" ; data = \"\(data)\"  ",
      "PROT=MIKEY; URI=\"rtsp://h/x\"; DATA=\(data)",
      "prot=mikey; data=\"AQIDBAU\"; uri=rtsp://h/x",
      "prot=mikey; uri=\"rtsp://h/x\"; data=\"AQID BAU=\"",
    ]
    for value in values {
      let parsed = try #require(KeyMgmtHeader.parse(value), "\(value)")
      #expect(parsed.uri == "rtsp://h/x", "\(value)")
      #expect(parsed.mikey == Data([1, 2, 3, 4, 5]), "\(value)")
    }
    let noURI = try #require(KeyMgmtHeader.parse("prot=mikey; data=\"\(data)\""))
    #expect(noURI.uri == nil)
  }

  @Test("Multiple entries: the first decodable mikey entry wins")
  func multipleEntries() throws {
    let value =
      "prot=sdes; data=\"AAAA\", prot=mikey; uri=\"rtsp://h/a,b;c\"; data=\"!!!\", "
      + "prot=mikey; uri=\"rtsp://h/a,b;c\"; data=\"AQID\", prot=mikey; data=\"BAUG\""
    let parsed = try #require(KeyMgmtHeader.parse(value))
    #expect(parsed.uri == "rtsp://h/a,b;c")
    #expect(parsed.mikey == Data([1, 2, 3]))
  }

  @Test("Values without a usable mikey entry return nil")
  func rejects() {
    for value in [
      "", "prot=mikey", "prot=mikey; uri=\"x\"", "prot=sdes; data=\"AQID\"",
      "prot=mikey; data=\"A\"", "prot=mikey; data=\"@@@@\"", "data=\"AQID\"",
      "prot=mikey; data=\"", ";;;,,,===",
    ] {
      #expect(KeyMgmtHeader.parse(value) == nil, "\(value)")
    }
  }

  @Test("SDP key-mgmt attribute values parse")
  func sdpAttribute() throws {
    let expected = try base64(mediamtxVideoMIKEY)
    #expect(KeyMgmtHeader.parseSDPAttribute("mikey \(mediamtxVideoMIKEY)") == expected)
    #expect(KeyMgmtHeader.parseSDPAttribute("MIKEY\t\(mediamtxVideoMIKEY)\r\n") == expected)
    #expect(KeyMgmtHeader.parseSDPAttribute("a=key-mgmt:mikey \(mediamtxVideoMIKEY)") == expected)
    #expect(KeyMgmtHeader.parseSDPAttribute("key-mgmt:mikey  \(mediamtxVideoMIKEY)") == expected)
    let message = try MIKEY.parse(
      try #require(KeyMgmtHeader.parseSDPAttribute("mikey \(mediamtxAudioMIKEY)")))
    #expect(message.csbID == 0x7BA7_A46B)
    for value in ["", "mikey", "mikey ", "sdes AQID", "mikey @@@", "mikeyAQID"] {
      #expect(KeyMgmtHeader.parseSDPAttribute(value) == nil, "\(value)")
    }
  }
}

@Suite("Server SRTP policy checks")
struct ServerSRTPPolicyTests {
  @Test("SETUP reply profiles: RTP/SAVP with or without /UDP counts as SRTP")
  func replyProfile() {
    #expect(SessionState.repliesWithSAVP("RTP/SAVP;unicast;client_port=5000-5001"))
    #expect(SessionState.repliesWithSAVP(" rtp/savp/udp;multicast"))
    #expect(!SessionState.repliesWithSAVP("RTP/AVP;unicast;client_port=5000-5001"))
    #expect(!SessionState.repliesWithSAVP("RTP/AVP;unicast, RTP/SAVP;unicast"))
    #expect(!SessionState.repliesWithSAVP(""))
  }

  @Test("Server policies without encryption, authentication or a full auth key are refused")
  func weakPoliciesRefused() {
    let standard = SRTPPolicy.aesCM128HMACSHA1_80
    #expect(SessionState.isAcceptableServerSRTPPolicy(standard))
    var shortTag = standard
    shortTag.authTagLength = 4
    #expect(SessionState.isAcceptableServerSRTPPolicy(shortTag))

    var nullCipher = standard
    nullCipher.cipher = .null
    var nullAuth = standard
    nullAuth.auth = .null
    var noRTPAuth = standard
    noRTPAuth.rtpAuthentication = false
    var noRTPEncryption = standard
    noRTPEncryption.rtpEncryption = false
    // A 1-byte HMAC key falls to 256 guesses against one captured packet.
    var shortAuthKey = standard
    shortAuthKey.authKeyLength = 1
    for policy in [nullCipher, nullAuth, noRTPAuth, noRTPEncryption, shortAuthKey] {
      #expect(!SessionState.isAcceptableServerSRTPPolicy(policy))
    }
  }
}
