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
    let auth = RTSPAuthenticator(credentials: Credentials(username: "admin", password: "pass"))
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
}
