// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Tests for RTSP Basic and Digest authentication

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
}
