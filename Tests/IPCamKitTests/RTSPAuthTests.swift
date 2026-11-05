// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Tests for RTSP Basic and Digest authentication

import CryptoKit
import Foundation
import Testing

@testable import IPCamKit

@Suite("RTSP Auth Tests")
struct RTSPAuthTests {

  @Test("Basic auth header generation")
  func basicAuth() {
    var auth = RTSPAuthenticator(credentials: Credentials(username: "admin", password: "pass"))
    let header = auth.authorize(method: "DESCRIBE", uri: "rtsp://host/path")
    #expect(header != nil)
    #expect(header!.hasPrefix("Basic "))
    // admin:pass -> base64
    let expected = Data("admin:pass".utf8).base64EncodedString()
    #expect(header! == "Basic \(expected)")
  }

  @Test("Digest auth challenge parsing")
  func digestChallengeParsing() {
    var auth = RTSPAuthenticator(
      credentials: Credentials(username: "admin", password: "password"))
    auth.handleChallenge(
      "Digest realm=\"Surveillance Server\", nonce=\"98481030\"")
    #expect(auth.hasChallenge)

    let header = auth.authorize(method: "DESCRIBE", uri: "rtsp://192.168.1.1/stream")
    #expect(header != nil)
    #expect(header!.hasPrefix("Digest "))
    #expect(header!.contains("username=\"admin\""))
    #expect(header!.contains("realm=\"Surveillance Server\""))
    #expect(header!.contains("nonce=\"98481030\""))
    #expect(header!.contains("response=\""))
  }

  @Test("Digest auth from Longse unauthorized response")
  func longseDigestAuth() throws {
    let resp = try loadResponse("longse_unauthorized.txt")
    #expect(resp.statusCode == 401)

    let wwwAuth = resp.header("WWW-Authenticate")
    #expect(wwwAuth != nil)

    var auth = RTSPAuthenticator(
      credentials: Credentials(username: "admin", password: "test123"))
    auth.handleChallenge(wwwAuth!)
    #expect(auth.hasChallenge)

    let header = auth.authorize(method: "DESCRIBE", uri: "rtsp://host/path")
    #expect(header != nil)
    #expect(header!.contains("realm=\"Surveillance Server\""))
    #expect(header!.contains("nonce=\"98481030\""))
  }

  @Test("Digest auth with qop=auth")
  func digestWithQop() {
    var auth = RTSPAuthenticator(
      credentials: Credentials(username: "user", password: "pass"))
    auth.handleChallenge(
      "Digest realm=\"test\", nonce=\"abc123\", qop=\"auth\", opaque=\"xyz\"")
    #expect(auth.hasChallenge)

    let header = auth.authorize(method: "DESCRIBE", uri: "rtsp://host/path")
    #expect(header != nil)
    #expect(header!.contains("qop=auth"))
    #expect(header!.contains("nc="))
    #expect(header!.contains("cnonce="))
    #expect(header!.contains("opaque=\"xyz\""))
  }

  @Test("Digest nonce-count increments per authorized request")
  func digestNonceCountIncrements() {
    var auth = RTSPAuthenticator(
      credentials: Credentials(username: "user", password: "pass"))
    auth.handleChallenge("Digest realm=\"test\", nonce=\"abc123\", qop=\"auth\"")

    let first = auth.authorize(method: "DESCRIBE", uri: "rtsp://host/path")
    let second = auth.authorize(method: "SETUP", uri: "rtsp://host/path")
    #expect(first!.contains("nc=00000001"))
    #expect(second!.contains("nc=00000002"))
  }

  @Test("Digest qop=auth-int alone is not treated as qop=auth")
  func digestQopAuthIntOnly() {
    var auth = RTSPAuthenticator(
      credentials: Credentials(username: "user", password: "pass"))
    auth.handleChallenge("Digest realm=\"test\", nonce=\"abc123\", qop=\"auth-int\"")

    let header = auth.authorize(method: "DESCRIBE", uri: "rtsp://host/path")
    #expect(header != nil)
    // We don't support auth-int, so we must fall back to the unqualified form
    // rather than claiming qop=auth.
    #expect(!header!.contains("qop="))
    #expect(!header!.contains("nc="))
  }

  @Test("Digest SHA-256 algorithm is honored")
  func digestSHA256() {
    var auth = RTSPAuthenticator(
      credentials: Credentials(username: "user", password: "pass"))
    auth.handleChallenge(
      "Digest realm=\"test\", nonce=\"abc123\", algorithm=SHA-256")

    let header = auth.authorize(method: "DESCRIBE", uri: "rtsp://host/path")
    #expect(header != nil)
    #expect(header!.contains("algorithm=SHA-256"))
    // SHA-256 response is 64 hex chars; MD5 would be 32.
    let hex = "0123456789abcdef"
    if let range = header!.range(of: "response=\"") {
      let rest = header![range.upperBound...]
      let digest = rest.prefix { hex.contains($0) }
      #expect(digest.count == 64)
    } else {
      Issue.record("no response field")
    }
  }

  @Test("Digest omits algorithm when the challenge did not specify one")
  func digestOmitsUnspecifiedAlgorithm() {
    var auth = RTSPAuthenticator(
      credentials: Credentials(username: "user", password: "pass"))
    // Reolink's challenge: no algorithm, no qop. The camera rejects a response
    // carrying `algorithm=MD5`, so it must be left out (absent means MD5).
    auth.handleChallenge("Digest realm=\"BC Streaming Media\", nonce=\"abc123\"")

    let header = auth.authorize(method: "DESCRIBE", uri: "rtsp://host/path")
    #expect(header != nil)
    #expect(!header!.contains("algorithm="))
    // MD5(MD5("user:BC Streaming Media:pass"):abc123:MD5("DESCRIBE:rtsp://host/path"))
    #expect(header!.contains("response=\"0f3905dab57f4f7c52265c53b5003324\""))
  }

  @Test("Digest echoes algorithm when the challenge specified it")
  func digestEchoesSpecifiedAlgorithm() {
    var auth = RTSPAuthenticator(
      credentials: Credentials(username: "user", password: "pass"))
    auth.handleChallenge("Digest realm=\"test\", nonce=\"abc123\", algorithm=MD5")

    let header = auth.authorize(method: "DESCRIBE", uri: "rtsp://host/path")
    #expect(header != nil)
    #expect(header!.contains("algorithm=MD5"))
  }

  @Test("Digest challenge with empty nonce is rejected")
  func digestEmptyNonceRejected() {
    var auth = RTSPAuthenticator(
      credentials: Credentials(username: "user", password: "pass"))
    auth.handleChallenge("Digest realm=\"test\", nonce=\"\"")
    #expect(!auth.hasChallenge)
  }

  @Test("Basic challenge enables pre-emptive auth (finding #10)")
  func basicChallengeEnablesPreemptiveAuth() {
    var auth = RTSPAuthenticator(credentials: Credentials(username: "u", password: "p"))
    #expect(!auth.hasChallenge)
    auth.handleChallenge("Basic realm=\"cam\"")
    #expect(auth.hasChallenge)
    let header = auth.authorize(method: "DESCRIBE", uri: "rtsp://h/p")
    #expect(header?.hasPrefix("Basic ") == true)
  }

  @Test("stale=true counts only for the response that says it")
  func staleOnlyForItsResponse() {
    var auth = RTSPAuthenticator(credentials: Credentials(username: "u", password: "p"))
    auth.handleChallenges(["Digest realm=\"r\", nonce=\"B\", stale=true"])
    let sent = auth.sending
    #expect(auth.retries(afterRejecting: sent))
    // A later 401 for the same nonce without a usable Digest challenge.
    auth.handleChallenges(["Basic realm=\"r\""])
    #expect(!auth.retries(afterRejecting: sent))
    auth.handleChallenges([String]())
    #expect(!auth.retries(afterRejecting: sent))
  }

  @Test("nc keeps counting when a 401 repeats the nonce in use")
  func ncKeptForSameNonce() {
    var auth = RTSPAuthenticator(credentials: Credentials(username: "u", password: "p"))
    auth.handleChallenges(["Digest realm=\"r\", nonce=\"n1\", qop=\"auth\""])
    #expect(auth.authorize(method: "PAUSE", uri: "rtsp://h/")?.contains("nc=00000001") == true)
    // Two in-flight requests refused for the same new nonce.
    auth.handleChallenges(["Digest realm=\"r\", nonce=\"n2\", qop=\"auth\""])
    #expect(auth.authorize(method: "PAUSE", uri: "rtsp://h/")?.contains("nc=00000001") == true)
    auth.handleChallenges(["Digest realm=\"r\", nonce=\"n2\", qop=\"auth\""])
    #expect(auth.authorize(method: "PLAY", uri: "rtsp://h/")?.contains("nc=00000002") == true)
    auth.handleChallenges(["Digest realm=\"r\", nonce=\"n3\", qop=\"auth\""])
    #expect(auth.authorize(method: "PLAY", uri: "rtsp://h/")?.contains("nc=00000001") == true)
  }

  @Test("Basic fallback overrides a broken Digest challenge")
  func basicFallbackOverridesDigest() {
    var auth = RTSPAuthenticator(credentials: Credentials(username: "u", password: "p"))
    auth.handleChallenge("Basic realm=\"cam\"")
    auth.handleChallenge("Digest realm=\"cam\", nonce=\"abc123\"")

    #expect(auth.authorize(method: "DESCRIBE", uri: "rtsp://h/p")?.hasPrefix("Digest ") == true)
    #expect(auth.authorizeBasicFallback()?.hasPrefix("Basic ") == true)
    #expect(auth.authorize(method: "SETUP", uri: "rtsp://h/track1")?.hasPrefix("Basic ") == true)
  }

  @Test("Digest quoted-string fields are escaped (finding #38)")
  func digestEscapesQuotedFields() {
    var auth = RTSPAuthenticator(
      credentials: Credentials(username: "ad\"min", password: "p"))
    auth.handleChallenge("Digest realm=\"test\", nonce=\"abc123\"")
    let header = auth.authorize(method: "DESCRIBE", uri: "rtsp://h/p")
    #expect(header != nil)
    // The quote in the username must be backslash-escaped, not left raw (which
    // would truncate the field and corrupt the whole header).
    #expect(header!.contains("username=\"ad\\\"min\""))
  }

  @Test("Control characters in a challenge value are rejected (no header injection)")
  func digestRejectsControlCharsInChallenge() {
    var auth = RTSPAuthenticator(
      credentials: Credentials(username: "user", password: "pass"))
    // A server-injected bare CR in the nonce must not reach the header; dropping
    // the nonce leaves the challenge unusable.
    auth.handleChallenge("Digest realm=\"r\", nonce=\"ab\rcd\"")
    #expect(!auth.hasChallenge)
  }

  @Test("Digest challenge value with an escaped quote is decoded (finding #40)")
  func digestUnquotesEscapedQuote() {
    var auth = RTSPAuthenticator(
      credentials: Credentials(username: "user", password: "pass"))
    // nonce carries an escaped quote on the wire: ab"cd
    auth.handleChallenge("Digest realm=\"r\", nonce=\"ab\\\"cd\"")
    #expect(auth.hasChallenge)
    let header = auth.authorize(method: "DESCRIBE", uri: "rtsp://h/p")
    #expect(header != nil)
    // Re-emitted escaped: nonce="ab\"cd". (Hash input uses the raw decoded value.)
    #expect(header!.contains("nonce=\"ab\\\"cd\""))
  }

  private func md5Hex(_ text: String) -> String {
    Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  @Test("Several challenges in one WWW-Authenticate: Digest wins in either order")
  func digestWinsWithinOneHeader() {
    let headers: [String] = [
      "Basic realm=\"cam\", Digest realm=\"cam\", nonce=\"abc\"",
      "Digest realm=\"cam\", nonce=\"abc\", Basic realm=\"cam\"",
      "Basic realm=\"cam\",Digest realm=\"cam\",nonce=\"abc\"",
    ]
    let ha1 = md5Hex("u:cam:p")
    let ha2 = md5Hex("DESCRIBE:rtsp://h/p")
    let response = md5Hex("\(ha1):abc:\(ha2)")
    for header in headers {
      var auth = RTSPAuthenticator(credentials: Credentials(username: "u", password: "p"))
      auth.handleChallenges([header])
      #expect(auth.usesDigest, "\(header)")
      #expect(auth.hasBasicChallenge, "\(header)")
      let authorization: String = auth.authorize(method: "DESCRIBE", uri: "rtsp://h/p") ?? ""
      #expect(authorization.hasPrefix("Digest "), "\(header)")
      #expect(authorization.contains("realm=\"cam\", nonce=\"abc\""), "\(header)")
      #expect(authorization.contains("response=\"\(response)\""), "\(header)")
      // The Digest -> Basic fallback works from the same header.
      let fallback: String? = auth.authorizeBasicFallback()
      #expect(fallback?.hasPrefix("Basic ") == true, "\(header)")
    }
  }

  @Test("Quoted commas and scheme names don't split challenges; other schemes are skipped")
  func challengeSplittingHonorsQuotes() {
    var auth = RTSPAuthenticator(credentials: Credentials(username: "u", password: "p"))
    // Wire text: Negotiate abc==, Basic realm="x, Digest y=\"z\"",
    //   Digest realm = "cam, Basic", nonce="n, Basic m", stale=FALSE
    let header: String =
      "Negotiate abc==, Basic realm=\"x, Digest y=\\\"z\\\"\", "
      + "Digest realm = \"cam, Basic\", nonce=\"n, Basic m\", stale=FALSE"
    auth.handleChallenges([header])
    #expect(auth.usesDigest)
    #expect(auth.hasBasicChallenge)
    let authorization: String = auth.authorize(method: "DESCRIBE", uri: "rtsp://h/p") ?? ""
    #expect(authorization.contains("realm=\"cam, Basic\", nonce=\"n, Basic m\""))
    let ha1 = md5Hex("u:cam, Basic:p")
    let ha2 = md5Hex("DESCRIBE:rtsp://h/p")
    let response = md5Hex("\(ha1):n, Basic m:\(ha2)")
    #expect(authorization.contains("response=\"\(response)\""))

    // A quoted ", Basic ..." inside a Digest value offers no Basic.
    var quoted = RTSPAuthenticator(credentials: Credentials(username: "u", password: "p"))
    quoted.handleChallenges(["Digest realm=\"a, Basic b=\\\"c\\\", d\", nonce=\"abc\""])
    #expect(quoted.usesDigest)
    #expect(!quoted.hasBasicChallenge)
    let echoed: String = quoted.authorize(method: "DESCRIBE", uri: "rtsp://h/p") ?? ""
    #expect(echoed.contains("realm=\"a, Basic b=\\\"c\\\", d\""))
  }

  @Test("Challenges split into scheme and parameters per RFC 7235")
  func splitChallengesShapes() {
    let split = RTSPAuthenticator.splitChallenges(
      "Basic, Digest realm=\"r\", qop=\"auth,auth-int\", Negotiate a1b2==, NTLM")
    let schemes: [String] = split.map { $0.scheme }
    #expect(schemes == ["Basic", "Digest", "Negotiate", "NTLM"])
    let params: [[String]] = split.map { $0.params }
    #expect(params == [[], ["realm=\"r\"", "qop=\"auth,auth-int\""], ["a1b2=="], []])
    // Parameters before any scheme belong to no challenge.
    #expect(RTSPAuthenticator.splitChallenges("realm=\"r\", nonce=\"n\"").isEmpty)
  }

  @Test("An unquoted qop list doesn't split the Digest challenge")
  func unquotedQopList() throws {
    let value = "Digest realm=\"cam\", qop=auth,auth-int, nonce=\"abc\", Negotiate"
    let challenges = RTSPAuthenticator.splitChallenges(value)
    #expect(challenges.map(\.scheme) == ["Digest", "Negotiate"])
    var auth = RTSPAuthenticator(credentials: Credentials(username: "u", password: "p"))
    auth.handleChallenges([value])
    #expect(auth.usesDigest)
    let authorization = auth.authorize(method: "DESCRIBE", uri: "rtsp://h/p")
    let header = try #require(authorization)
    #expect(header.contains("nonce=\"abc\""))
    #expect(header.contains("qop=auth"))
  }

}
