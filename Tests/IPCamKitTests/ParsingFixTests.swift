// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Regression tests for the RTSP/SDP parsing and authentication audit fixes.

import CryptoKit
import Foundation
import Testing

@testable import IPCamKit

@Suite("Parsing audit fixes")
struct ParsingFixTests {
  let parser = RTSPParser()

  private func setupResponse(session: String, transport: String) -> RTSPResponse {
    RTSPResponse(
      statusCode: 200, reasonPhrase: "OK",
      headers: [("Session", session), ("Transport", transport)])
  }

  private func message(_ text: String) -> String {
    do {
      _ = try parseSetup(
        response: setupResponse(session: text, transport: "RTP/AVP/TCP;interleaved=0-1"))
      return ""
    } catch {
      return "\(error)"
    }
  }

  // MARK: - Finding 1: empty Session header

  @Test("SETUP with an empty Session id throws instead of trapping")
  func emptySessionId() {
    for value in ["", " ", ";", " ;timeout=60", ";timeout=60"] {
      let resp = setupResponse(session: value, transport: "RTP/AVP/TCP;interleaved=0-1")
      #expect(throws: RTSPError.self) { _ = try parseSetup(response: resp) }
      #expect(message(value).contains("Empty Session id"))
    }
    let ok = setupResponse(session: "abc ; timeout=30", transport: "RTP/AVP/TCP;interleaved=0-1")
    let setup = try? parseSetup(response: ok)
    #expect(setup?.session.id == "abc")
    #expect(setup?.session.timeoutSec == 30)
  }

  // MARK: - Finding 2: header block cap

  @Test("A header block with no blank line within 64 KiB is rejected")
  func headerBlockCap() {
    var data = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\n".utf8)
    let line = Data("X-Pad: \(String(repeating: "a", count: 100))\r\n".utf8)
    while data.count <= 65 * 1024 { data.append(line) }
    #expect(throws: RTSPError.self) { _ = try parser.parse(&data) }
  }

  @Test("A complete header block over 64 KiB is rejected")
  func completeHeaderBlockCap() {
    var data = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\n".utf8)
    let line = Data("X-Pad: \(String(repeating: "a", count: 1000))\r\n".utf8)
    for _ in 0..<70 { data.append(line) }
    data.append(Data("\r\n".utf8))
    #expect(throws: RTSPError.self) { _ = try parser.parse(&data) }
  }

  @Test("More than 256 header lines are rejected")
  func headerCountCap() {
    var text = "RTSP/1.0 200 OK\r\nCSeq: 1\r\n"
    for i in 0..<300 { text += "X-\(i): v\r\n" }
    text += "\r\n"
    var data = Data(text.utf8)
    #expect(throws: RTSPError.self) { _ = try parser.parse(&data) }
  }

  @Test("A large but legal header block still parses")
  func largeLegalHeaderBlock() throws {
    var text = "RTSP/1.0 200 OK\r\nCSeq: 9\r\n"
    for i in 0..<200 { text += "X-\(i): \(String(repeating: "v", count: 200))\r\n" }
    text += "\r\n"
    var data = Data(text.utf8)
    let result = try parser.parse(&data)
    guard case .response(let resp) = result?.0 else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.cseq == 9)
    #expect(resp.headers.count == 201)
  }

  @Test("parseNext reports the bytes a body still needs")
  func parseNextReportsBodyBytes() throws {
    let head = "RTSP/1.0 200 OK\r\nCSeq: 1\r\ncontent-LENGTH : 10\r\n\r\n"
    var data = Data((head + "abc").utf8)
    guard case .needMore(let total) = try parser.parseNext(&data) else {
      Issue.record("Expected needMore")
      return
    }
    #expect(total == head.utf8.count + 10)
    #expect(data.count == head.utf8.count + 3)  // nothing consumed
    data.append(Data("defghij".utf8))
    guard case .message(.response(let resp)) = try parser.parseNext(&data) else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.body == Data("abcdefghij".utf8))
    #expect(data.isEmpty)
  }

  @Test("parseNext needMore: nil for a partial header block, frame size for '$'")
  func parseNextNeedMoreValues() throws {
    var partial = Data("\r\n\r\nRTSP/1.0 200 OK\r\nCSeq: 1\r\n".utf8)
    guard case .needMore(let none) = try parser.parseNext(&partial) else {
      Issue.record("Expected needMore")
      return
    }
    #expect(none == nil)
    // Leading CRLF padding may be dropped; the partial message is kept.
    #expect(partial == Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\n".utf8))

    var short = Data([0x24, 0x00])
    guard case .needMore(let four) = try parser.parseNext(&short) else {
      Issue.record("Expected needMore")
      return
    }
    #expect(four == 4)

    var frame = Data([0x0D, 0x0A, 0x24, 0x01, 0x00, 0x08, 0xAA])
    guard case .needMore(let whole) = try parser.parseNext(&frame) else {
      Issue.record("Expected needMore")
      return
    }
    #expect(whole == 12)
    #expect(frame.count == 5)
  }

  @Test("A 2 MB body streamed 1 KiB per read is parsed a bounded number of times")
  func gatedParseIsBounded() throws {
    // The connection's read loop, gated on needMore(totalBytes:).
    var head = "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 2000000\r\n"
    for i in 0..<200 { head += "X-\(i): \(String(repeating: "v", count: 250))\r\n" }
    head += "\r\n"
    var wire = Data(head.utf8)
    wire.append(Data(repeating: 0x41, count: 2_000_000))
    var buffer = Data()
    var needed: Int?
    var parses = 0
    var offset = 0
    var response: RTSPResponse?
    while response == nil, offset < wire.count {
      let end = min(offset + 1024, wire.count)
      buffer.append(wire[offset..<end])
      offset = end
      if let needed, buffer.count < needed { continue }
      parses += 1
      switch try parser.parseNext(&buffer) {
      case .message(.response(let r)): response = r
      case .needMore(let total): needed = total
      default: Issue.record("Unexpected result")
      }
    }
    #expect(response?.body.count == 2_000_000)
    // One parse per read while the header block arrives (needMore(nil)), then
    // one when it completes and one when the body has fully arrived.
    #expect(parses <= head.utf8.count / 1024 + 3)
  }

  // MARK: - Finding 3: requests from the server

  @Test("A server OPTIONS request before a response is skipped by parse(_:)")
  func serverRequestSkippedByParse() throws {
    var data = Data(
      ("OPTIONS * RTSP/1.0\r\nCSeq: 5\r\nSession: abc\r\n\r\n"
        + "RTSP/1.0 200 OK\r\nCSeq: 2\r\n\r\n").utf8)
    let result = try parser.parse(&data)
    guard case .response(let resp) = result?.0 else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.cseq == 2)
    #expect(data.isEmpty)
  }

  @Test("A server SET_PARAMETER request with a body is skipped by parse(_:)")
  func serverRequestWithBodySkipped() throws {
    var data = Data(
      ("SET_PARAMETER rtsp://h/s RTSP/1.0\r\nCSeq: 7\r\nContent-Length: 11\r\n\r\n"
        + "barparam: x"
        + "RTSP/1.0 200 OK\r\nCSeq: 3\r\n\r\n").utf8)
    let result = try parser.parse(&data)
    guard case .response(let resp) = result?.0 else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.cseq == 3)
    #expect(data.isEmpty)
  }

  @Test("parseNext returns a server request, then the response after it")
  func parseNextServerRequest() throws {
    var data = Data(
      ("OPTIONS * RTSP/1.0\r\nCSeq: 5\r\nSession: abc;timeout=60\r\n\r\n"
        + "SET_PARAMETER rtsp://h/s RTSP/1.0\r\nCSeq: 6\r\nContent-Length: 4\r\n\r\nk: v"
        + "RTSP/1.0 200 OK\r\nCSeq: 2\r\n\r\n").utf8)
    guard case .serverRequest(let options) = try parser.parseNext(&data) else {
      Issue.record("Expected server request")
      return
    }
    #expect(options.method == "OPTIONS")
    #expect(options.uri == "*")
    #expect(options.version == "RTSP/1.0")
    #expect(options.cseq == 5)
    #expect(options.header("session") == "abc;timeout=60")
    guard case .serverRequest(let setParameter) = try parser.parseNext(&data) else {
      Issue.record("Expected server request")
      return
    }
    #expect(setParameter.method == "SET_PARAMETER")
    #expect(setParameter.uri == "rtsp://h/s")
    #expect(setParameter.body == Data("k: v".utf8))
    guard case .message(.response(let resp)) = try parser.parseNext(&data) else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.cseq == 2)
    #expect(data.isEmpty)
  }

  @Test("Status lines are not mistaken for request lines")
  func statusLineNotRequest() throws {
    for line in ["RTSP/1.0 200 OK", "RTSP/1.0 451 RTSP/1.0", "HTTP/1.0 200 OK"] {
      var data = Data("\(line)\r\nCSeq: 1\r\n\r\n".utf8)
      guard case .message(.response(let resp)) = try parser.parseNext(&data) else {
        Issue.record("Expected response for \(line)")
        continue
      }
      #expect(resp.cseq == 1)
    }
  }

  private func reply(_ text: String) throws -> String {
    var data = Data(text.utf8)
    guard case .serverRequest(let request) = try parser.parseNext(&data) else {
      Issue.record("Expected server request")
      return ""
    }
    return String(decoding: RTSPSerializer().serializeReply(to: request), as: UTF8.self)
  }

  @Test("Replies to server requests: 200 for OPTIONS/GET_PARAMETER, else 501")
  func serverRequestReplies() throws {
    #expect(
      try reply("OPTIONS * RTSP/1.0\r\nCSeq: 5\r\nSession: abc\r\n\r\n")
        == "RTSP/1.0 200 OK\r\nCSeq: 5\r\nSession: abc\r\n\r\n")
    #expect(
      try reply("GET_PARAMETER rtsp://h/s RTSP/1.0\r\nCSeq: 6\r\n\r\n")
        == "RTSP/1.0 200 OK\r\nCSeq: 6\r\n\r\n")
    #expect(
      try reply("ANNOUNCE rtsp://h/s RTSP/1.0\r\nCSeq: 7\r\nContent-Length: 1\r\n\r\nx")
        == "RTSP/1.0 501 Not Implemented\r\nCSeq: 7\r\n\r\n")
    #expect(
      try reply("REDIRECT rtsp://h/s RTSP/1.0\r\nCSeq: 8\r\nSession: s\r\n\r\n")
        == "RTSP/1.0 501 Not Implemented\r\nCSeq: 8\r\nSession: s\r\n\r\n")
  }

  // MARK: - Finding 4: error text

  @Test("RTSPError.localizedDescription carries the description")
  func localizedDescription() {
    let error: any Error = RTSPError.invalidSDP("bad thing")
    #expect(error.localizedDescription == "Invalid SDP: bad thing")
  }

  @Test("DESCRIBE failure keeps each dropped stream's error text")
  func describeErrorText() {
    let sdp = ["v=0", "o=- 0 0 IN IP4 0.0.0.0", "s=S", "m=audio 0 RTP/AVP 99"]
      .joined(separator: "\r\n")
    let resp = RTSPResponse(
      statusCode: 200, reasonPhrase: "OK",
      headers: [("Content-Type", "application/sdp")], body: Data(sdp.utf8))
    do {
      _ = try parseDescribe(requestURL: "rtsp://h/p", response: resp)
      Issue.record("Expected an error")
    } catch {
      #expect("\(error)".contains("No rtpmap for dynamic payload type 99"))
    }
  }

  // MARK: - Finding 5: single server_port

  @Test("SETUP accepts a single server_port")
  func singleServerPort() throws {
    let resp = setupResponse(
      session: "1", transport: "RTP/AVP;unicast;client_port=5000-5001;server_port=6970")
    #expect(try parseSetup(response: resp).serverPort == 6970)
    let pair = setupResponse(
      session: "1", transport: "RTP/AVP;unicast;client_port=5000-5001;server_port=6970-6971")
    #expect(try parseSetup(response: pair).serverPort == 6970)
    // RTCP is port + 1, which must still fit in 16 bits.
    let top = setupResponse(session: "1", transport: "RTP/AVP;unicast;server_port=65535")
    #expect(throws: RTSPError.self) { _ = try parseSetup(response: top) }
    let gap = setupResponse(session: "1", transport: "RTP/AVP;unicast;server_port=6970-6975")
    #expect(throws: RTSPError.self) { _ = try parseSetup(response: gap) }
  }

  @Test(
    "SETUP rejects an interleaved, server_port or multicast port with an empty or extra part",
    arguments: [
      "interleaved=-1", "interleaved=0-", "interleaved=0-1-2", "interleaved=-",
      "server_port=-6971", "server_port=6970-", "server_port=6970-6971-6972",
      "destination=232.0.0.1;port=-5001", "destination=232.0.0.1;port=5000-",
      "destination=232.0.0.1;port=5000-5001-5002",
    ])
  func setupRejectsMalformedPortPairs(_ parameter: String) {
    let resp = setupResponse(session: "1", transport: "RTP/AVP;unicast;\(parameter)")
    #expect(throws: RTSPError.self) { _ = try parseSetup(response: resp) }
  }

  // MARK: - Finding 6: RTP-Info

  private func twoStreamPresentation(_ c0: String, _ c1: String) -> Presentation {
    var p = Presentation(
      streams: [
        Stream(
          media: "video", encodingName: "h264", rtpPayloadType: 96, clockRateHz: 90000,
          control: c0),
        Stream(
          media: "audio", encodingName: "pcmu", rtpPayloadType: 0, clockRateHz: 8000,
          control: c1),
      ],
      baseURL: "rtsp://h/s/", control: "rtsp://h/s/")
    initStreamsForPlay(&p)
    return p
  }

  private func seqs(_ p: Presentation) -> [UInt16?] {
    p.streams.map { stream -> UInt16? in
      if case .setup(let s) = stream.state { return s.initialSeq }
      return nil
    }
  }

  @Test("RTP-Info url containing a comma keeps both streams' seq")
  func rtpInfoCommaInURL() throws {
    var p = twoStreamPresentation("rtsp://h/s/track1?a=1,2", "rtsp://h/s/track2")
    let resp = RTSPResponse(
      statusCode: 200, reasonPhrase: "OK",
      headers: [
        (
          "RTP-Info",
          "url=rtsp://h/s/track1?a=1,2;seq=10;rtptime=100,url=rtsp://h/s/track2;seq=20;rtptime=200"
        )
      ])
    try parsePlay(response: resp, presentation: &p)
    #expect(seqs(p) == [10, 20])
  }

  @Test("RTP-Info and Public split over several header lines are one list")
  func listHeadersOnSeveralLines() throws {
    var p = twoStreamPresentation("rtsp://h/s/track1", "rtsp://h/s/track2")
    let resp = RTSPResponse(
      statusCode: 200, reasonPhrase: "OK",
      headers: [
        ("RTP-Info", "url=rtsp://h/s/track1;seq=10;rtptime=100"),
        ("RTP-Info", "url=rtsp://h/s/track2;seq=20;rtptime=200"),
      ])
    try parsePlay(response: resp, presentation: &p)
    #expect(seqs(p) == [10, 20])
    let options = parseOptions(
      response: RTSPResponse(
        statusCode: 200, reasonPhrase: "OK",
        headers: [("Public", "OPTIONS, DESCRIBE"), ("Public", "GET_PARAMETER, SET_PARAMETER")]))
    #expect(options.getParameterSupported)
    #expect(options.setParameterSupported)
  }

  @Test("RTP-Info quoted url values (RFC 7826) are unquoted")
  func rtpInfoQuotedURL() throws {
    var p = twoStreamPresentation("rtsp://h/s/track1", "rtsp://h/s/track2")
    let resp = RTSPResponse(
      statusCode: 200, reasonPhrase: "OK",
      headers: [
        (
          "RTP-Info",
          "url=\"rtsp://h/s/track1\";seq=10;rtptime=100, url=\"rtsp://h/s/track2\";seq=20"
        )
      ])
    try parsePlay(response: resp, presentation: &p)
    #expect(seqs(p) == [10, 20])
  }

  @Test("RTP-Info without url keeps splitting on commas")
  func rtpInfoNoURL() throws {
    var p = twoStreamPresentation("rtsp://h/s/track1", "rtsp://h/s/track2")
    p.streams.removeLast()
    let resp = RTSPResponse(
      statusCode: 200, reasonPhrase: "OK",
      headers: [("RTP-Info", "seq=1;rtptime=2,seq=3;rtptime=4")])
    try parsePlay(response: resp, presentation: &p)
    guard case .setup(let s) = p.streams[0].state else {
      Issue.record("Expected setup state")
      return
    }
    #expect(s.initialSeq == 3)
    #expect(s.initialRtptime == 4)
  }

  // MARK: - Finding 7: Digest algorithm selection

  @Test("An unsupported Digest algorithm never replaces a supported one")
  func digestIgnoresUnsupportedAlgorithm() {
    var auth = RTSPAuthenticator(credentials: Credentials(username: "user", password: "pass"))
    auth.handleChallenge("Digest realm=\"BC Streaming Media\", nonce=\"abc123\"")
    auth.handleChallenge(
      "Digest realm=\"BC Streaming Media\", nonce=\"zzz\", algorithm=SHA-512-256")
    let header = auth.authorize(method: "DESCRIBE", uri: "rtsp://host/path") ?? ""
    #expect(!header.contains("SHA-512-256"))
    #expect(header.contains("nonce=\"abc123\""))
    #expect(header.contains("response=\"0f3905dab57f4f7c52265c53b5003324\""))
  }

  @Test("Only an unsupported Digest algorithm leaves no usable challenge")
  func digestOnlyUnsupported() {
    var auth = RTSPAuthenticator(credentials: Credentials(username: "user", password: "pass"))
    auth.handleChallenge("Digest realm=\"r\", nonce=\"n\", algorithm=SHA-512-256")
    #expect(!auth.hasChallenge)
    auth.handleChallenge("Basic realm=\"r\"")
    #expect(auth.authorize(method: "DESCRIBE", uri: "rtsp://h/p")?.hasPrefix("Basic ") == true)
  }

  @Test("The first supported Digest challenge in one 401 wins")
  func digestFirstSupportedWins() {
    var auth = RTSPAuthenticator(credentials: Credentials(username: "user", password: "pass"))
    auth.handleChallenges([
      "Digest realm=\"r\", nonce=\"skip\", algorithm=SHA-512-256",
      "Basic realm=\"r\"",
      "Digest realm=\"r\", nonce=\"first\", algorithm=SHA-256",
      "Digest realm=\"r\", nonce=\"second\", algorithm=MD5",
    ])
    #expect(auth.hasBasicChallenge)
    let header = auth.authorize(method: "DESCRIBE", uri: "rtsp://h/p") ?? ""
    #expect(header.contains("algorithm=SHA-256"))
    #expect(header.contains("nonce=\"first\""))
    // The Basic fallback recorded from the same response still works.
    #expect(auth.authorizeBasicFallback()?.hasPrefix("Basic ") == true)
  }

  @Test("A later 401's Digest challenge replaces the earlier one and resets nc")
  func digestLaterChallengeReplaces() {
    var auth = RTSPAuthenticator(credentials: Credentials(username: "user", password: "pass"))
    auth.handleChallenges(["Digest realm=\"r\", nonce=\"old\", qop=\"auth\""])
    _ = auth.authorize(method: "DESCRIBE", uri: "rtsp://h/p")
    let second = auth.authorize(method: "SETUP", uri: "rtsp://h/p") ?? ""
    #expect(second.contains("nc=00000002"))
    // Stale nonce: the next 401 offers two fresh challenges; its first wins.
    auth.handleChallenges([
      "Digest realm=\"r\", nonce=\"new1\", qop=\"auth\", stale=true",
      "Digest realm=\"r\", nonce=\"new2\", qop=\"auth\", stale=true",
    ])
    let header = auth.authorize(method: "PLAY", uri: "rtsp://h/p") ?? ""
    #expect(header.contains("nonce=\"new1\""))
    #expect(header.contains("nc=00000001"))
  }

  @Test("handleChallenge on a later single header replaces the Digest state")
  func singleHandleChallengeReplaces() {
    var auth = RTSPAuthenticator(credentials: Credentials(username: "user", password: "pass"))
    auth.handleChallenge("Digest realm=\"r\", nonce=\"old\"")
    _ = auth.authorize(method: "DESCRIBE", uri: "rtsp://h/p")
    auth.handleChallenge("Digest realm=\"r\", nonce=\"new\"")
    #expect(auth.authorize(method: "SETUP", uri: "rtsp://h/p")?.contains("nonce=\"new\"") == true)
  }

  // MARK: - Finding 8: control characters in server-supplied values

  @Test("A control byte that could change framing rejects the response")
  func headerControlBytesRejected() {
    let bad = [
      // A bare CR: other parsers break the line there.
      "RTSP/1.0 200 OK\r\nCSeq: 1\r\nSession: abc\rX-Injected: 1\r\n\r\n",
      "RTSP/1.0 200 OK\r\nCSeq: 1\r\nX-A: v\rContent-Length: 4\r\n\r\nbody",
      "RTSP/1.0 200 OK\r\nCSeq: 1\r\nX-A: v\r\n \rX\r\n\r\n",
      // A control byte in a field name, or on a line without a colon.
      "RTSP/1.0 200 OK\r\nCSeq: 1\r\nX-\u{1}: v\r\n\r\n",
      "RTSP/1.0 200 OK\r\nCSeq: 1\r\n\u{0}Content-Length: 4\r\n\r\nbody",
      "RTSP/1.0 200 OK\r\nCSeq: 1\r\njunk\u{0}line\r\n\r\n",
      // A control byte in Content-Length, on its line or a folded one.
      "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 4\u{0}\r\n\r\nbody",
      "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 4\r\n \u{7F}\r\n\r\nbody",
      "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 0\r\ncontent-length: 0\u{0}\r\n\r\n",
      // A control byte in the start line.
      "RTSP/1.0 200 O\u{0}K\r\nCSeq: 1\r\n\r\n",
    ]
    for text in bad {
      var data = Data(text.utf8)
      #expect(throws: RTSPError.self, "\(text.debugDescription)") { _ = try parser.parse(&data) }
    }
  }

  @Test("A header with a control byte is dropped and the rest of the response is used")
  func headerControlBytesDropped() throws {
    let text: String =
      "RTSP/1.0 200 OK\r\nCSeq: 7\r\nServer: Cam\u{0}OS\r\nSession: a\u{7F}b\r\n"
      + "Content-Base: rtsp://h/\u{0}x/\r\nX-Fold: ok\r\n \u{1}more\r\n\t tail\r\n"
      + "RTP-Info: url=rtsp://h/s;seq=5\r\n \u{0}\r\n \r\nnot a header\r\n \u{0}orphan\r\n"
      + "Content-Length: 4\r\n\r\nbody"
    var data = Data(text.utf8)
    let resp = try parseResponse(&data)
    let names: [String] = resp.headers.map { $0.0 }
    #expect(names == ["CSeq", "Content-Length"])
    #expect(resp.cseq == 7)
    #expect(resp.header("Session") == nil)
    #expect(resp.body == Data("body".utf8))
    #expect(data.isEmpty)

    // The same bytes without the control bytes keep every header.
    let clean: String =
      "RTSP/1.0 200 OK\r\nCSeq: 7\r\nServer: CamOS\r\nSession: ab\r\n"
      + "X-Fold: ok\r\n more\r\n\r\n"
    var cleanData = Data(clean.utf8)
    let cleanResp = try parseResponse(&cleanData)
    #expect(cleanResp.header("Session") == "ab")
    #expect(cleanResp.header("X-Fold") == "ok more")
  }

  @Test("Extra CRs before a line feed are tolerated, not taken as injection")
  func extraCRBeforeLineFeed() throws {
    var data = Data("RTSP/1.0 200 OK\r\r\nCSeq: 3\r\r\nSession: abc\r\r\n\r\n".utf8)
    let result = try parser.parse(&data)
    guard case .response(let resp) = result?.0 else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.reasonPhrase == "OK")
    #expect(resp.cseq == 3)
    #expect(resp.header("Session") == "abc")
  }

  @Test("A tab inside a header value is allowed")
  func headerTabAllowed() throws {
    var data = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\nX-Note: a\tb\r\n\r\n".utf8)
    let result = try parser.parse(&data)
    guard case .response(let resp) = result?.0 else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.header("X-Note") == "a\tb")
  }

  private func describe(
    sdp: [String], headers: [(String, String)] = [], requestURL: String = "rtsp://h/p",
    onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)? = nil
  ) throws -> Presentation {
    let resp = RTSPResponse(
      statusCode: 200, reasonPhrase: "OK",
      headers: [("Content-Type", "application/sdp")] + headers,
      body: Data(sdp.joined(separator: "\r\n").utf8))
    return try parseDescribe(requestURL: requestURL, response: resp, onDiagnostic: onDiagnostic)
  }

  private let sdpHead = ["v=0", "o=- 0 0 IN IP4 0.0.0.0", "s=S"]

  @Test("An empty Content-Base falls back to the request URL")
  func emptyContentBase() throws {
    let p = try describe(
      sdp: sdpHead + ["m=audio 0 RTP/AVP 0", "a=control:trackID=1", ""],
      headers: [("Content-Base", "")])
    #expect(p.baseURL == "rtsp://h/p")
    #expect(p.streams.first?.control == "rtsp://h/p/trackID=1")
  }

  @Test("A media a=control with a space or control character drops the stream")
  func badMediaControlDropsStream() throws {
    for bad in ["track1 X-Injected: 1", "track1\u{1}", "track\u{7F}1"] {
      let p = try describe(
        sdp: sdpHead + [
          "m=video 0 RTP/AVP 96", "a=rtpmap:96 H264/90000", "a=control:\(bad)",
          "m=audio 0 RTP/AVP 0", "a=control:track2",
        ])
      #expect(p.streams.count == 1)
      #expect(p.streams.first?.control == "rtsp://h/p/track2")
    }
  }

  @Test("A session a=control or Content-Base with a space is ignored")
  func badSessionControlAndContentBaseIgnored() throws {
    let p = try describe(
      sdp: sdpHead + ["a=control:rtsp://h/p x", "m=audio 0 RTP/AVP 0", "a=control:track2"],
      headers: [("Content-Base", "rtsp://h/a b/")])
    #expect(p.baseURL == "rtsp://h/p")
    #expect(p.control == "rtsp://h/p")
    #expect(p.streams.first?.control == "rtsp://h/p/track2")
  }

  @Test("Only the first 64 media sections are read; the rest and extra bad m= lines warn once each")
  func mediaSectionCap() throws {
    final class Box: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [String] = []
      func add(_ d: RTSPDiagnostic) { lock.withLock { stored.append(d.message) } }
      var messages: [String] { lock.withLock { stored } }
    }
    let box = Box()
    var lines = sdpHead
    for i in 0..<100 { lines += ["m=bogus", "m=audio 0 RTP/AVP 0", "a=control:t\(i)"] }
    let p = try describe(sdp: lines, onDiagnostic: { box.add($0) })
    #expect(p.streams.count == maxMediaSections)
    #expect(p.streams.last?.control == "rtsp://h/p/t63")
    // 64 unparseable m= lines reported one by one, one note for the other
    // 36, and one for the 36 good sections past the limit.
    #expect(box.messages.count == maxMediaSections + 2)
    #expect(
      box.messages.suffix(2) == [
        "Dropping 36 more media sections with a malformed m= line",
        "Ignoring 36 media sections: only the first 64 are read",
      ])
  }

  @Test("A Content-Base, Content-Location or a=control over 8 KiB is ignored")
  func longControlURLIgnored() throws {
    let longest = "rtsp://h/" + String(repeating: "a", count: maxControlURLBytes - 10) + "/"
    let tooLong = "rtsp://h/" + String(repeating: "b", count: maxControlURLBytes - 9) + "/"
    #expect(longest.utf8.count == maxControlURLBytes)
    #expect(tooLong.utf8.count == maxControlURLBytes + 1)
    let media = ["m=audio 0 RTP/AVP 0", "a=control:track2"]

    var p = try describe(sdp: sdpHead + media, headers: [("Content-Base", longest)])
    #expect(p.baseURL == longest)
    p = try describe(sdp: sdpHead + media, headers: [("Content-Base", tooLong)])
    #expect(p.baseURL == "rtsp://h/p")
    p = try describe(
      sdp: sdpHead + media,
      headers: [("Content-Base", tooLong), ("Content-Location", "rtsp://h/loc/")])
    #expect(p.baseURL == "rtsp://h/loc/")
    p = try describe(sdp: sdpHead + media, headers: [("Content-Location", tooLong)])
    #expect(p.baseURL == "rtsp://h/p")

    p = try describe(sdp: sdpHead + ["a=control:\(longest)"] + media)
    #expect(p.control == longest)
    p = try describe(sdp: sdpHead + ["a=control:\(tooLong)"] + media)
    #expect(p.control == "rtsp://h/p")

    let video = ["m=video 0 RTP/AVP 96", "a=rtpmap:96 H264/90000"]
    p = try describe(sdp: sdpHead + video + ["a=control:\(longest)"] + media)
    #expect(p.streams.map(\.control) == [longest, "rtsp://h/p/track2"])
    p = try describe(sdp: sdpHead + video + ["a=control:\(tooLong)"] + media)
    #expect(p.streams.map(\.control) == ["rtsp://h/p/track2"])
  }

  @Test("Ignored session a=control lines give one diagnostic")
  func repeatedBadSessionControl() throws {
    let log = DiagnosticLog()
    var lines = sdpHead
    lines += Array(repeating: "a=control:a b", count: 1_000)
    lines += ["a=control:rtsp://h/agg/", "m=audio 0 RTP/AVP 0", "a=control:track2"]
    let p = try describe(sdp: lines, onDiagnostic: { log.add($0.message) })
    #expect(p.control == "rtsp://h/agg/")
    #expect(
      log.all == [
        "Ignoring session a=control with a space or control character: \"a b\" "
          + "(and 999 more session a=control lines)"
      ])
  }

  @Test("Messages show at most 80 characters of a server value")
  func longValuesTruncatedInMessages() throws {
    let log = DiagnosticLog()
    let junk = String(repeating: "\u{1}", count: 100_000)
    let p = try describe(
      sdp: sdpHead + [
        "a=control:\(junk)", "m=audio 0 RTP/AVP 0", "a=control:x\(junk)",
        "m=audio 0 RTP/AVP 0", "a=control:t", "m=" + String(repeating: "v", count: 100_000),
      ],
      headers: [("Content-Base", "rtsp://h/" + junk)], onDiagnostic: { log.add($0.message) })
    #expect(p.streams.map(\.control) == ["rtsp://h/p/t"])
    #expect(log.all.count == 4)
    for message in log.all {
      #expect(message.utf8.count < 1_000, "\(message.prefix(100))")
      #expect(message.contains("…"))
    }
    do {
      _ = try describe(sdp: sdpHead + ["m=audio 0 RTP/AVP 0", "a=control:\(junk)"])
      Issue.record("no stream left, so DESCRIBE should fail")
    } catch {
      #expect("\(error)".utf8.count < 1_000)
    }
    // Each m= field, and a value whose length is in combining marks (one
    // Character), is cut too.
    let long = String(repeating: "v", count: 100_000)
    let marks = "x" + String(repeating: "\u{301}", count: 30_000)
    for line in [
      "m=audio 0 \(long) 0", "m=audio 0 RTP/AVP \(long)", "m=\(long) 0 BOGUS 0", "m=\(marks)",
      "m=\(marks) 0 BOGUS 0",
    ] {
      let log = DiagnosticLog()
      let lines = sdpHead + [line, "m=audio 0 RTP/AVP 0", "a=control:t"]
      _ = try? describe(sdp: lines, onDiagnostic: { log.add($0.message) })
      #expect(!log.all.isEmpty, "\(line.prefix(30))")
      for message in log.all {
        #expect(message.utf8.count < 1_000, "\(line.prefix(30)): \(message.prefix(100))")
      }
    }
    let before = log.all.count
    _ = try describe(
      sdp: sdpHead + ["m=audio 0 RTP/AVP 0", "a=control:t"],
      headers: [("Content-Base", "rtsp://h/a" + String(repeating: "\u{301}", count: 30_000) + " ")],
      onDiagnostic: { log.add($0.message) })
    #expect(log.all.count == before + 1)
    #expect(log.all.allSatisfy { $0.utf8.count < 1_000 })
  }

  @Test("The blank-line scan matches a byte-by-byte scan, CR runs included")
  func blankLineScanMatchesReference() {
    // Reference: the first LF followed by only CRs and then an LF; the range
    // starts at the CRs before the first LF.
    func reference(_ bytes: [UInt8]) -> Range<Int>? {
      for p in bytes.indices where bytes[p] == 0x0A {
        var next = p + 1
        while next < bytes.count && bytes[next] == 0x0D { next += 1 }
        if next < bytes.count && bytes[next] == 0x0A {
          var lower = p
          while lower > 0 && bytes[lower - 1] == 0x0D { lower -= 1 }
          return lower..<(next + 1)
        }
      }
      return nil
    }
    let parser = RTSPParser()
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<3000 {
      let length = Int.random(in: 0...60, using: &generator)
      let bytes: [UInt8] = (0..<length).map { _ in
        [0x0D, 0x0D, 0x0D, 0x0A, 0x61].randomElement(using: &generator)!
      }
      let expected = reference(bytes)
      switch parser.scanForBlankLine(in: Data(bytes), limit: 1 << 16, maxLineFeeds: .max) {
      case .found(let range): #expect(range == expected, "\(bytes)")
      case .notFound: #expect(expected == nil, "\(bytes)")
      case .tooManyLines: Issue.record("tooManyLines for \(bytes)")
      }
    }
  }

  @Test("Long header values are cut in SETUP, DESCRIBE, framing, WebSocket and multicast errors")
  func longHeaderValuesCut() async throws {
    let long = String(repeating: "x", count: 20_000)
    var messages: [String] = []
    for transport in [
      "RTP/AVP/TCP;unicast;interleaved=0-y\(long)", "RTP/AVP;unicast;server_port=x\(long)",
      "RTP/AVP;multicast;port=x\(long)",
    ] {
      do {
        _ = try parseSetup(response: setupResponse(session: "s", transport: transport))
        Issue.record("\(transport.prefix(30)) parsed")
      } catch { messages.append("\(error)") }
    }
    let describe = RTSPResponse(
      statusCode: 200, reasonPhrase: "OK", headers: [("Content-Type", "text/\(long)")])
    do {
      _ = try parseDescribe(requestURL: "rtsp://127.0.0.1/s", response: describe)
      Issue.record("Content-Type accepted")
    } catch { messages.append("\(error)") }
    var raw = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: x\(long)\r\n\r\n".utf8)
    do {
      _ = try RTSPParser().parse(&raw)
      Issue.record("Content-Length accepted")
    } catch { messages.append("\(error)") }
    for extra in ["Sec-WebSocket-Protocol: \(long)", "Sec-WebSocket-Extensions: \(long)"] {
      let text =
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        + "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\(extra)\r\n\r\n"
      let (head, _) = try #require(try HTTPResponseHead.parse(Data(text.utf8)))
      do {
        try WebSocketTransport.validateUpgrade(head, key: "dGhlIHNhbXBsZSBub25jZQ==")
        Issue.record("\(extra.prefix(24)) accepted")
      } catch { messages.append("\(error)") }
    }
    for (group, source) in [(long, nil), ("239.255.1.1", long)] as [(String, String?)] {
      do {
        _ = try await MulticastPair.join(
          group: group, rtpPort: 40_000, rtcpPort: 40_001, source: source)
        Issue.record("multicast join accepted")
      } catch { messages.append("\(error)") }
    }
    #expect(messages.count == 9)
    for message in messages {
      #expect(message.unicodeScalars.count < 300, "\(message.prefix(60))")
    }
  }

  @Test(
    "A long Session id or multicast Transport is cut in start() messages",
    .timeLimit(.minutes(1)))
  func longSessionTextCut() async throws {
    let long = String(repeating: "x", count: 20_000)
    let server = FakeRTSPServer(
      sdp: makeTestSDP(media: [h264VideoMediaSDP(), pcmuAudioMediaSDP()]))
    server.transformResponse = { request, response in
      guard request.method == "SETUP", request.url.hasSuffix("/audio") else { return response }
      var renumbered = response
      renumbered.headers.removeAll { $0.name.lowercased() == "session" }
      renumbered.headers.append((name: "Session", value: "\(long);timeout=60"))
      return renumbered
    }
    try await server.start()
    defer { server.stop() }
    let log = DiagnosticLog()
    let session = RTSPClientSession(
      url: server.url, transport: .tcp, onDiagnostic: { log.add($0.message) })
    let started = await outcome { try await session.start() }
    await session.stop()
    #expect(log.all.filter { $0.contains("new Session ID") }.count == 1)
    for message in log.all {
      #expect(message.unicodeScalars.count < 300, "\(message.prefix(60))")
    }
    if case .failure(let error) = started {
      #expect("\(error)".unicodeScalars.count < 300, "\(String(describing: error).prefix(60))")
    }

    let multicast = FakeRTSPServer(sdp: makeTestSDP(media: [h264VideoMediaSDP()]))
    multicast.onRequest = { request in
      guard request.method == "SETUP" else { return nil }
      return FakeRTSPResponse(
        headers: [("Session", "s1"), ("Transport", "RTP/AVP;multicast;\(long)")])
    }
    try await multicast.start()
    defer { multicast.stop() }
    let multicastSession = RTSPClientSession(url: multicast.url, transport: .multicast)
    let multicastStarted = await outcome { try await multicastSession.start() }
    await multicastSession.stop()
    guard case .failure(let error) = multicastStarted else {
      Issue.record("multicast start() succeeded")
      return
    }
    #expect("\(error)".contains("omitted destination"))
    #expect("\(error)".unicodeScalars.count < 300, "\(String(describing: error).prefix(60))")
  }

  @Test("An AAC config= value decodes as hex in either case and rejects anything else")
  func aacConfigHex() throws {
    let base = "streamtype=5;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config="
    for config in ["1188", "11a8", "11A8"] {
      _ = try parseAACFormatSpecificParams(clockRate: 48_000, formatSpecificParams: base + config)
    }
    for config in ["118", "11g8", "+188", "11 8", "１188"] {
      #expect(throws: (any Error).self, "\(config)") {
        _ = try parseAACFormatSpecificParams(clockRate: 48_000, formatSpecificParams: base + config)
      }
    }
    #expect(aacRTPTicksPerAU(configHex: "1188", clockRate: 48_000) == 1024)
  }

  @Test("lazySplit gives the pieces split(separator:) gives")
  func lazySplitMatchesSplit() {
    var generator = SystemRandomNumberGenerator()
    let alphabet: [Character] = ["a", ";", ";", "b", " "]
    for _ in 0..<2000 {
      let length = Int.random(in: 0...12, using: &generator)
      let text = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
      for omitting in [true, false] {
        #expect(
          Array(text.lazySplit(separator: ";", omittingEmptySubsequences: omitting))
            == text.split(separator: ";", omittingEmptySubsequences: omitting), "\(text)")
      }
    }
  }

  /// Values from the SDP body (up to 2 MiB) used to be split into an array of
  /// every piece first, 40 to 80 times the value's size in memory.
  @Test("Long SDP values made of separators parse without splitting them whole")
  func longSeparatorRuns() throws {
    let run = 1_000_000
    #expect(PlaybackRange.parse("npt=" + String(repeating: "-", count: run)) == nil)
    #expect(PlaybackRange.parse("npt=" + String(repeating: ":", count: run) + "-") == nil)
    #expect(PlaybackRange.parse("npt=1:2:3-") == .npt(start: 3723, end: nil))
    #expect(PlaybackRange.parse("npt=1:2:3:4-") == nil)
    let fmt = try describe(
      sdp: sdpHead + ["m=audio 0 RTP/AVP 8" + String(repeating: " 1", count: run), "a=control:t"])
    #expect(fmt.streams.first?.rtpPayloadType == 8)
    let rtpmap = try describe(
      sdp: sdpHead + [
        "m=audio 0 RTP/AVP 96", "a=rtpmap:96 L16/8000/2" + String(repeating: "/1", count: run),
        "a=control:t",
      ])
    #expect(rtpmap.streams.first?.channels == 2)
    // fmtp lists are read one parameter at a time.
    let separators = String(repeating: ";", count: run)
    #expect(throws: (any Error).self) {
      _ = try H264Parameters.parseFormatSpecificParams("packetization-mode=1" + separators)
    }
    try H264Parameters.validatePacketizationMode(separators + "packetization-mode=1")
    try H265Parameters.validateTransmissionMode(String(repeating: "a=1;", count: run / 4))
    #expect(throws: (any Error).self) {
      _ = try H265Parameters.parseFormatSpecificParams(separators)
    }
    #expect(
      SessionState.advertisesParameterSets(separators + "sprop-parameter-sets=Z0IAH5Y=,aM4G4g=="))
  }

  @Test("start()'s error lists offered streams with long names cut", .timeLimit(.minutes(1)))
  func offeredStreamsCutInStartError() async throws {
    let long = String(repeating: "x", count: 100_000)
    let sdp = makeTestSDP(media: [
      "m=\(long) 0 RTP/AVP 96\r\na=rtpmap:96 \(long)/90000\r\na=control:t\r\n"
    ])
    let server = FakeRTSPServer(sdp: sdp)
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url, transport: .tcp)
    let started = await outcome { try await session.start() }
    await session.stop()
    guard case .failure(let error) = started else {
      Issue.record("start() succeeded")
      return
    }
    let text = "\(error)"
    #expect(text.contains("offered: "), "\(text.prefix(200))")
    #expect(text.utf8.count < 1_000, "\(text.prefix(200))")
    // An rtpmap value is cut in its own error too.
    let p = try? describe(
      sdp: sdpHead + ["m=audio 0 RTP/AVP 96", "a=rtpmap:96 \(long)", "a=control:t"])
    #expect(p == nil)
    do {
      _ = try describe(sdp: sdpHead + ["m=audio 0 RTP/AVP 96", "a=rtpmap:96 \(long)"])
    } catch {
      #expect("\(error)".utf8.count < 1_000)
    }
  }

  /// Each a=control line used to be joined to the base as it was read: an
  /// 8 KB base times 150,000 lines took 20 s (release) on the session actor.
  @Test(
    "Repeated a=control lines under a long Content-Base are joined once",
    .timeLimit(.minutes(1)), arguments: [false, true])
  func repeatedControlLinesJoinedOnce(mediaLevel: Bool) throws {
    let host = String(repeating: "a", count: 8_100)
    let base = "rtsp://\(host)"
    let repeated = Array(repeating: "a=control:/x", count: 150_000)
    var lines = sdpHead
    if mediaLevel {
      lines += ["m=audio 0 RTP/AVP 0"] + repeated
    } else {
      lines += repeated + ["m=audio 0 RTP/AVP 0", "a=control:/t"]
    }
    let started = ContinuousClock.now
    let p = try describe(sdp: lines, headers: [("Content-Base", base)])
    let elapsed = ContinuousClock.now - started
    #expect(elapsed < .seconds(4), "parseDescribe took \(elapsed)")
    #expect((mediaLevel ? p.streams.first?.control : p.control) == base + "/x")
  }

  @Test("RTP-Info entries past twice the stream count (at least 128) are ignored")
  func rtpInfoEntryCap() throws {
    var p = twoStreamPresentation("rtsp://h/s/track1", "rtsp://h/s/track2")
    let junk = Array(repeating: "url=/x;seq=1", count: 126)
    let resp = RTSPResponse(
      statusCode: 200, reasonPhrase: "OK",
      headers: [
        ("RTP-Info", (junk + ["url=track1;seq=10", "url=track2;seq=20"]).joined(separator: ","))
      ])
    try parsePlay(response: resp, presentation: &p)
    var seqs = p.streams.map { stream -> UInt16? in
      if case .setup(let s) = stream.state { return s.initialSeq }
      return nil
    }
    #expect(seqs == [10, 20])
    p = twoStreamPresentation("rtsp://h/s/track1", "rtsp://h/s/track2")
    let late = RTSPResponse(
      statusCode: 200, reasonPhrase: "OK",
      headers: [
        (
          "RTP-Info",
          (junk + ["url=/x;seq=1", "url=/x;seq=1", "url=track1;seq=10"]).joined(separator: ",")
        )
      ])
    try parsePlay(response: late, presentation: &p)
    seqs = p.streams.map { stream -> UInt16? in
      if case .setup(let s) = stream.state { return s.initialSeq }
      return nil
    }
    #expect(seqs.first != 10)
  }

  @Test("The session's SDP parser stores at most 1024 attributes per section")
  func sdpAttributeCap() throws {
    let log = DiagnosticLog()
    let lines =
      sdpHead + Array(repeating: "a=x", count: 5_000) + ["a=control:rtsp://h/agg/"]
      + ["m=audio 0 RTP/AVP 0"] + Array(repeating: "a=y", count: 2_000) + ["a=control:t"]
    let p = try describe(sdp: lines, onDiagnostic: { log.add($0.message) })
    // Both a=control lines come after their section's first 1024 attributes.
    #expect(p.control == "rtsp://h/p")
    #expect(p.streams.first?.control == nil)
    #expect(log.all.contains("Ignoring 4954 SDP attributes past 1024 in a section"), "\(log.all)")
    let sdp = try SDPParser(mediaLimit: maxMediaSections).parse(
      "v=0\r\ns=x\r\n" + String(repeating: "a=x\n", count: 100_000))
    #expect(sdp.attributes.count == SDPParser.maxAttributesPerSection)
    #expect(sdp.ignoredAttributeCount == 100_000 - SDPParser.maxAttributesPerSection)
    // The public parser keeps them all.
    let all = try SDPParser().parse("v=0\r\n" + String(repeating: "a=x\n", count: 5_000))
    #expect(all.attributes.count == 5_000)
  }

  @Test("The session's SDP parser stores at most 64 media sections and 64 m= errors")
  func sdpParserStorageCap() throws {
    let valid = "v=0\r\ns=x\r\n" + String(repeating: "m=a 0 b c\r\na=x\r\n", count: 50_000)
    var sdp = try SDPParser(mediaLimit: maxMediaSections).parse(valid)
    #expect(sdp.mediaDescriptions.count == maxMediaSections)
    #expect(sdp.ignoredMediaCount == 50_000 - maxMediaSections)
    let malformed = "v=0\r\ns=x\r\n" + String(repeating: "m=\r\n", count: 50_000)
    sdp = try SDPParser(mediaLimit: maxMediaSections).parse(malformed)
    #expect(sdp.skippedMediaErrors.count == SDPParser.maxSkippedMediaErrors)
    #expect(sdp.skippedMediaCount == 50_000)
    // The public parser keeps every well-formed section.
    #expect(try SDPParser().parse(valid).mediaDescriptions.count == 50_000)
  }

  @Test("A 2 MiB DESCRIBE with a 60 KB Content-Base keeps a bounded presentation")
  func describeAmplificationBounded() throws {
    let base = "rtsp://127.0.0.1/" + String(repeating: "a", count: 60_000) + "/"
    var sdp = "v=0\r\ns=x\r\nt=0 0\r\n"
    let section = "m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=control:t\r\n"
    sdp += String(
      repeating: section,
      count: (RTSPParser.maxBodyBytes - sdp.utf8.count) / section.utf8.count)
    var raw = Data(
      ("RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Type: application/sdp\r\n"
        + "Content-Base: \(base)\r\nContent-Length: \(sdp.utf8.count)\r\n\r\n").utf8)
    raw += Data(sdp.utf8)
    guard case .response(let resp)? = try RTSPParser().parse(&raw)?.0 else {
      Issue.record("response didn't parse")
      return
    }
    let p = try parseDescribe(requestURL: "rtsp://127.0.0.1/s", response: resp)
    #expect(p.streams.count == maxMediaSections)
    #expect(p.baseURL == "rtsp://127.0.0.1/s")
    let controlBytes = p.streams.reduce(0) { $0 + ($1.control?.utf8.count ?? 0) }
    #expect(controlBytes < 64 * 1024)
  }

  @Test("Serializer never writes a control character from a header value")
  func serializerStripsControlCharacters() {
    var request = RTSPRequest(method: .play, url: "rtsp://h/p\r\nX-Bad: 1")
    request.setHeader("CSeq", value: "1")
    request.setHeader("Session", value: "abc\rX-Injected: 1")
    request.setHeader("X-Tab", value: "a\tb")
    let text = String(decoding: RTSPSerializer().serialize(request), as: UTF8.self)
    let lines = text.components(separatedBy: "\r\n")
    #expect(lines.first == "PLAY rtsp://h/pX-Bad: 1 RTSP/1.0")
    #expect(lines.contains("Session: abcX-Injected: 1"))
    #expect(lines.contains("X-Tab: a\tb"))
    // Every CR is part of a CRLF line ending.
    #expect(text.replacingOccurrences(of: "\r\n", with: "").contains("\r") == false)
  }

  // MARK: - Finding 9: joinControl / hasURIScheme

  @Test("joinControl resolves absolute paths and trims the control value")
  func joinControlFixes() {
    #expect(
      joinControl(base: "rtsp://h/live/", control: "/other/track1") == "rtsp://h/other/track1")
    #expect(
      joinControl(base: "rtsp://u:p@[::1]:554/live", control: "/x") == "rtsp://u:p@[::1]:554/x")
    #expect(joinControl(base: "rtsp://h/live/", control: " trackID=1") == "rtsp://h/live/trackID=1")
    #expect(joinControl(base: "rtsp://h/live", control: "trackID=1") == "rtsp://h/live/trackID=1")
    #expect(joinControl(base: "rtsp://h/live/", control: " * ") == "rtsp://h/live/")
    #expect(joinControl(base: "rtsp://h/live/", control: "rtsp://o/t") == "rtsp://o/t")
    // Dahua query-string bases still concatenate.
    let dahua = "rtsp://h/cam/realmonitor?channel=1&subtype=0/"
    #expect(joinControl(base: dahua, control: "trackID=0") == dahua + "trackID=0")
    #expect(joinControl(base: dahua, control: "/x") == "rtsp://h/x")
  }

  @Test("hasURIScheme does not mistake host:port for a scheme")
  func hasURISchemeHostPort() {
    #expect(hasURIScheme("rtsp://h/"))
    #expect(hasURIScheme("RTSPS://h/"))
    #expect(!hasURIScheme("camera.local:554/stream/"))
    #expect(!hasURIScheme("camera:554"))
    #expect(!hasURIScheme("192.168.1.10:554/stream0/"))
    #expect(!hasURIScheme("stream0/"))
  }

  @Test("A scheme-less Content-Base with a hostname resolves against the request scheme")
  func schemeLessHostnameContentBase() throws {
    let p = try describe(
      sdp: sdpHead + ["m=audio 0 RTP/AVP 0", "a=control:trackID=1"],
      headers: [("Content-Base", "camera.local:554/stream/")])
    #expect(p.baseURL == "rtsp://camera.local:554/stream/")
    #expect(p.streams.first?.control == "rtsp://camera.local:554/stream/trackID=1")
  }

  // MARK: - Finding 10: non-UTF-8 bytes

  @Test("SDP with GBK bytes in s= and i= lines still parses")
  func nonUTF8SDP() throws {
    var body = Data("v=0\r\no=- 0 0 IN IP4 0.0.0.0\r\ns=".utf8)
    body.append(contentsOf: [0xC9, 0xE3, 0xCF, 0xF1, 0xBB, 0xFA])  // GBK "camera"
    body.append(Data("\r\ni=".utf8))
    body.append(contentsOf: [0xC9, 0xE3, 0xCF])
    body.append(Data("\r\nm=audio 0 RTP/AVP 0\r\na=control:trackID=1\r\n".utf8))
    let resp = RTSPResponse(
      statusCode: 200, reasonPhrase: "OK",
      headers: [("Content-Type", "application/sdp")], body: body)
    let p = try parseDescribe(requestURL: "rtsp://h/p", response: resp)
    #expect(p.streams.count == 1)
    #expect(p.streams.first?.control == "rtsp://h/p/trackID=1")
  }

  @Test("Non-UTF-8 bytes in the status line or a header value still parse")
  func nonUTF8Headers() throws {
    var data = Data("RTSP/1.0 200 ".utf8)
    data.append(contentsOf: [0xB3, 0xC9, 0xB9, 0xA6])  // GBK reason phrase
    data.append(Data("\r\nCSeq: 4\r\nServer: ".utf8))
    data.append(contentsOf: [0xC9, 0xE3, 0xCF, 0xF1])
    data.append(Data("\r\n\r\n".utf8))
    let result = try parser.parse(&data)
    guard case .response(let resp) = result?.0 else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.statusCode == 200)
    #expect(resp.cseq == 4)
    #expect(resp.header("Server")?.isEmpty == false)
  }

  // MARK: - Folded header lines (RFC 2326 via RFC 2068 2.2)

  private func parseResponse(_ data: inout Data) throws -> RTSPResponse {
    let result = try parser.parse(&data)
    guard case .response(let resp) = result?.0 else {
      throw RTSPError.depacketizationError("Expected a response")
    }
    return resp
  }

  @Test("A folded header line continues the previous header's value")
  func foldedHeaderLine() throws {
    let text: String =
      "RTSP/1.0 401 Unauthorized\r\nCSeq: 2\r\n"
      + "WWW-Authenticate: Digest realm=\"cam\",\r\n nonce=\"abc\",\r\n\t  qop=\"auth\"\r\n"
      + "X-Note: a\r\n b: c\r\nSession: s1\r\n\r\n"
    var data = Data(text.utf8)
    let resp = try parseResponse(&data)
    let names: [String] = resp.headers.map { $0.0 }
    #expect(names == ["CSeq", "WWW-Authenticate", "X-Note", "Session"])
    let challenge = try #require(resp.header("WWW-Authenticate"))
    #expect(challenge == "Digest realm=\"cam\", nonce=\"abc\", qop=\"auth\"")
    // A continuation holding a colon is part of the value, not a header.
    #expect(resp.header("X-Note") == "a b: c")
    #expect(resp.cseq == 2)
    #expect(resp.header("Session") == "s1")

    var auth = RTSPAuthenticator(credentials: Credentials(username: "u", password: "p"))
    auth.handleChallenge(challenge)
    let authorization: String = auth.authorize(method: "DESCRIBE", uri: "rtsp://h/p") ?? ""
    #expect(authorization.contains("nonce=\"abc\""))
    #expect(authorization.contains("qop=auth"))
  }

  @Test("A continuation line with no header before it is dropped")
  func continuationWithoutHeader() throws {
    var data = Data(
      "RTSP/1.0 200 OK\r\n X-Stray: 1\r\n\t\r\nCSeq: 5\r\nno colon\r\n X-More: 2\r\n \r\n\r\n"
        .utf8)
    let resp = try parseResponse(&data)
    let names: [String] = resp.headers.map { $0.0 }
    #expect(names == ["CSeq"])
    #expect(resp.cseq == 5)
    #expect(data.isEmpty)
  }

  @Test("Content-Length framing follows header folding")
  func foldedContentLength() throws {
    // A folded Content-Length value still frames the body.
    let text: String =
      "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length:\r\n 4\r\n\r\nbody"
      + "RTSP/1.0 200 OK\r\nCSeq: 2\r\n\r\n"
    var data = Data(text.utf8)
    let first = try parseResponse(&data)
    #expect(first.header("Content-Length") == "4")
    #expect(first.body == Data("body".utf8))
    let second = try parseResponse(&data)
    #expect(second.cseq == 2)

    // An indented "Content-Length:" line continues the previous value, so it
    // does not declare a body.
    var indented = Data("RTSP/1.0 200 OK\r\nCSeq: 3\r\nX-A: v\r\n Content-Length: 4\r\n\r\n".utf8)
    let resp = try parseResponse(&indented)
    #expect(resp.header("X-A") == "v Content-Length: 4")
    #expect(resp.header("Content-Length") == nil)
    #expect(resp.body.isEmpty)
  }

  // MARK: - SDP line endings

  @Test("SDP lines ending in CR CR LF, a lone CR, LF or CRLF are all split")
  func sdpLineEndings() throws {
    let lines: [String] =
      sdpHead + [
        "a=control:*", "m=video 0 RTP/AVP 96", "a=rtpmap:96 H264/90000",
        "a=control:trackID=0", "m=audio 0 RTP/AVP 0", "a=control:trackID=1",
      ]
    for ending in ["\r\r\n", "\r", "\n", "\r\n"] {
      let text: String = lines.joined(separator: ending) + ending
      let sdp = try SDPParser().parse(text)
      let label = ending.debugDescription
      #expect(sdp.sessionName == "S", "\(label)")
      let media: [String] = sdp.mediaDescriptions.map(\.media)
      #expect(media == ["video", "audio"], "\(label)")
      let control = sdp.mediaDescriptions.last?.attribute("control")?.value
      #expect(control == "trackID=1", "\(label)")
      let rtpmap = sdp.mediaDescriptions.first?.attribute("rtpmap")?.value
      #expect(rtpmap == "96 H264/90000", "\(label)")
    }

    let body: String = lines.map { $0 + "\r\r\n" }.joined()
    let resp = RTSPResponse(
      statusCode: 200, reasonPhrase: "OK",
      headers: [("Content-Type", "application/sdp")], body: Data(body.utf8))
    let p = try parseDescribe(requestURL: "rtsp://h/p", response: resp)
    let controls: [String?] = p.streams.map(\.control)
    #expect(controls == ["rtsp://h/p/trackID=0", "rtsp://h/p/trackID=1"])
  }

  // MARK: - Malformed m= line

  @Test("A malformed m= line drops only its own media section")
  func malformedMediaLineDropsSection() throws {
    let sdp: [String] =
      sdpHead + [
        "m=video 0 RTP/AVP 96", "a=rtpmap:96 H264/90000", "a=control:trackID=0",
        "m=audio 0 RTP/AVP", "c=IN IP4 10.0.0.9", "b=AS:64", "a=control:bad",
        "a=rtpmap:0 PCMU/8000",
        "m=audio 0 RTP/AVP 0", "a=control:trackID=2",
      ]
    let log = DiagnosticLog()
    let p = try describe(sdp: sdp, onDiagnostic: { log.add($0.message) })
    let controls: [String?] = p.streams.map(\.control)
    #expect(controls == ["rtsp://h/p/trackID=0", "rtsp://h/p/trackID=2"])
    // The skipped section's a=control did not become the session control.
    #expect(p.control == "rtsp://h/p")
    let dropped = log.all.filter { $0.contains("Invalid media line: m=audio 0 RTP/AVP") }
    #expect(dropped.count == 1)

    let session = try SDPParser().parse(sdp.joined(separator: "\r\n"))
    let formats: [String] = session.mediaDescriptions.map(\.fmt)
    #expect(formats == ["96", "0"])
    #expect(session.attributes.isEmpty)
    #expect(session.connectionInfo == nil)
    #expect(session.bandwidth == nil)
  }

  @Test("An SDP whose every m= line is malformed fails like one with no media")
  func everyMediaLineMalformed() {
    var noMedia = ""
    do {
      _ = try describe(sdp: sdpHead)
    } catch {
      noMedia = "\(error)"
    }
    #expect(noMedia.contains("No parseable streams in SDP"))

    do {
      let sdp: [String] = sdpHead + ["m=audio 0 RTP/AVP", "a=control:x", "m=video"]
      _ = try describe(sdp: sdp)
      Issue.record("Expected an error")
    } catch {
      let text = "\(error)"
      #expect(text.contains("No parseable streams in SDP"))
      #expect(text.contains("Invalid media line: m=audio 0 RTP/AVP"))
      #expect(text.contains("Invalid media line: m=video"))
    }
  }

  // MARK: - Relative Content-Location

  @Test("An absolute-path Content-Location resolves against the request URL")
  func absolutePathContentLocation() throws {
    let sdp: [String] = sdpHead + ["m=audio 0 RTP/AVP 0", "a=control:trackID=1"]
    let request = "rtsp://10.0.0.5:554/live/ch0"
    let p = try describe(
      sdp: sdp, headers: [("Content-Location", "/live/ch0/")], requestURL: request)
    #expect(p.baseURL == "rtsp://10.0.0.5:554/live/ch0/")
    #expect(p.streams.first?.control == "rtsp://10.0.0.5:554/live/ch0/trackID=1")

    // An empty Content-Base still falls through to Content-Location.
    let emptyBase = try describe(
      sdp: sdp, headers: [("Content-Base", ""), ("Content-Location", "/other/")],
      requestURL: "rtsp://10.0.0.5/live/ch0?x=1")
    #expect(emptyBase.baseURL == "rtsp://10.0.0.5/other/")

    // Content-Base takes the same path, so the same form resolves there too.
    let base = try describe(
      sdp: sdp, headers: [("Content-Base", "/live/ch0/")], requestURL: request)
    #expect(base.baseURL == "rtsp://10.0.0.5:554/live/ch0/")

    // A network-path reference keeps only the request URL's scheme.
    let network = try describe(
      sdp: sdp, headers: [("Content-Location", "//10.0.0.6:8554/cam/")], requestURL: request)
    #expect(network.baseURL == "rtsp://10.0.0.6:8554/cam/")

    // A value without a leading "/" is still read as the scheme-less host form.
    let hostForm = try describe(
      sdp: sdp, headers: [("Content-Location", "ch0/")], requestURL: request)
    #expect(hostForm.baseURL == "rtsp://ch0/")
  }

  // MARK: - Several challenges in one WWW-Authenticate (RFC 7235 4.1)

  @Test("A session answers 'Basic, Digest' in one WWW-Authenticate with Digest")
  func sessionPicksDigestFromCombinedChallenge() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    let challenge = "Basic realm=\"fake\", Digest realm=\"fake\", nonce=\"n1\""
    server.onRequest = { request in
      guard request.method == "DESCRIBE", request.header("Authorization") == nil else {
        return nil
      }
      return FakeRTSPResponse(statusCode: 401, headers: [("WWW-Authenticate", challenge)])
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "user", password: "pass"),
      transport: .tcp)
    let started = await outcome { try await session.start() }
    await session.stop()
    if case .failure(let error) = started { Issue.record("start() failed: \(error)") }
    let describes = server.requests(method: "DESCRIBE")
    #expect(describes.count == 2)
    let authorization: String = describes.last?.header("Authorization") ?? ""
    #expect(authorization.hasPrefix("Digest username=\"user\", realm=\"fake\", nonce=\"n1\""))
  }

  @Test("A session sends rejected Basic credentials only once")
  func sessionBasicOnlyRejectedOnce() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      guard request.method == "DESCRIBE" else { return nil }
      return FakeRTSPResponse(
        statusCode: 401, headers: [("WWW-Authenticate", "Basic realm=\"fake\"")])
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "user", password: "pass"),
      transport: .tcp)
    let started = await outcome { try await session.start() }
    await session.stop()
    guard case .failure(let error) = started, case RTSPError.authenticationFailed = error else {
      Issue.record("Expected authenticationFailed, got \(started)")
      return
    }
    let describes = server.requests(method: "DESCRIBE")
    #expect(describes.map { $0.header("Authorization") != nil } == [false, true])
  }

  @Test("A session falls back to Basic once after a rejected Digest")
  func sessionDigestRejectedFallsBackToBasic() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    let challenge = "Basic realm=\"fake\", Digest realm=\"fake\", nonce=\"n1\""
    server.onRequest = { request in
      guard request.method == "DESCRIBE",
        request.header("Authorization")?.hasPrefix("Basic ") != true
      else { return nil }
      return FakeRTSPResponse(statusCode: 401, headers: [("WWW-Authenticate", challenge)])
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "user", password: "pass"),
      transport: .tcp)
    let started = await outcome { try await session.start() }
    await session.stop()
    if case .failure(let error) = started { Issue.record("start() failed: \(error)") }
    let schemes = server.requests(method: "DESCRIBE").map {
      $0.header("Authorization")?.split(separator: " ").first.map(String.init)
    }
    #expect(schemes == [nil, "Digest", "Basic"])
  }

  /// The scheme of each `method` request's Authorization (nil without one).
  private func authSchemes(_ server: FakeRTSPServer, _ method: String) -> [String?] {
    server.requests(method: method).map {
      $0.header("Authorization")?.split(separator: " ").first.map(String.init)
    }
  }

  /// DESCRIBE is accepted only with Basic, after a 401 offering
  /// `describeChallenge`; every SETUP is refused with `setupChallenge`.
  @Test(
    "Refused Basic credentials aren't sent again for the same request",
    .timeLimit(.minutes(1)),
    arguments: [
      ("Basic", "Basic", [nil, "Basic"], ["Basic"]),
      // Basic was forced after a refused Digest, and stays forced.
      ("Basic+Digest", "Basic+Digest", [nil, "Digest", "Basic"], ["Basic"]),
      // Digest is new to the session: tried once, with no Basic fallback.
      ("Basic", "Basic+Digest", [nil, "Basic"], ["Basic", "Digest"]),
    ] as [(String, String, [String?], [String?])])
  func refusedBasicNotResent(
    describeChallenge: String, setupChallenge: String, describes: [String?], setups: [String?]
  ) async throws {
    @Sendable func header(_ schemes: String) -> String {
      schemes == "Basic"
        ? "Basic realm=\"fake\"" : "Basic realm=\"fake\", Digest realm=\"fake\", nonce=\"n1\""
    }
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      let basic = request.header("Authorization")?.hasPrefix("Basic ") == true
      switch request.method {
      case "DESCRIBE" where !basic:
        return FakeRTSPResponse(
          statusCode: 401, headers: [("WWW-Authenticate", header(describeChallenge))])
      case "SETUP":
        return FakeRTSPResponse(
          statusCode: 401, headers: [("WWW-Authenticate", header(setupChallenge))])
      default:
        return nil
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "user", password: "pass"),
      transport: .tcp)
    let started = await outcome { try await session.start() }
    await session.stop()
    if case .success = started { Issue.record("start() succeeded") }
    #expect(authSchemes(server, "DESCRIBE") == describes)
    #expect(authSchemes(server, "SETUP") == setups)
  }

  @Test(
    "Credentials refused on OPTIONS end start() without a DESCRIBE",
    .timeLimit(.minutes(1)),
    arguments: [
      ("Basic realm=\"fake\"", ["OPTIONS:-", "OPTIONS:Basic"]),
      (
        "Basic realm=\"fake\", Digest realm=\"fake\", nonce=\"n1\"",
        ["OPTIONS:-", "OPTIONS:Digest", "OPTIONS:Basic"]
      ),
    ])
  func refusedOnOptions(challenge: String, expected: [String]) async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { _ in
      FakeRTSPResponse(statusCode: 401, headers: [("WWW-Authenticate", challenge)])
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "user", password: "pass"),
      transport: .tcp)
    let started = await outcome { try await session.start() }
    await session.stop()
    guard case .failure(let error) = started, case RTSPError.authenticationFailed = error else {
      Issue.record("Expected authenticationFailed, got \(started)")
      return
    }
    let sent = server.requests.map {
      $0.method + ":"
        + ($0.header("Authorization")?.split(separator: " ").first.map(String.init) ?? "-")
    }
    #expect(sent == expected)
  }

  @Test(
    "A refused Digest is retried only with a new nonce or stale=true",
    .timeLimit(.minutes(1)),
    arguments: [
      ("SETUP", "Digest realm=\"fake\", nonce=\"n1\"", 1),
      ("PAUSE", "Digest realm=\"fake\", nonce=\"n1\"", 1),
      ("PAUSE", "Digest realm=\"fake\", nonce=\"n2\"", 2),
      ("PAUSE", "Digest realm=\"fake\", nonce=\"n1\", stale=true", 2),
    ])
  func refusedDigestRetriedOnlyForNewNonce(
    method: String, challenge: String, sent: Int
  )
    async throws
  {
    // DESCRIBE is answered with Digest nonce n1; `method` with n1 is refused.
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      let authorization = request.header("Authorization") ?? ""
      if request.method == "DESCRIBE", authorization.isEmpty {
        return FakeRTSPResponse(
          statusCode: 401, headers: [("WWW-Authenticate", "Digest realm=\"fake\", nonce=\"n1\"")])
      }
      guard request.method == method, !authorization.contains("nonce=\"n2\"") else { return nil }
      return FakeRTSPResponse(statusCode: 401, headers: [("WWW-Authenticate", challenge)])
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "user", password: "pass"),
      transport: .tcp)
    _ = await outcome { try await session.start() }
    if method == "PAUSE" { _ = await outcome { try await session.pause() } }
    await session.stop()
    #expect(authSchemes(server, method) == Array(repeating: "Digest", count: sent))
  }

  /// The nonce an Authorization header answers, or nil without Digest.
  private func digestNonce(_ request: FakeRTSPRequest) -> String? {
    guard let authorization = request.header("Authorization"),
      let range = authorization.range(of: "nonce=\"")
    else { return nil }
    return String(authorization[range.upperBound...].prefix { $0 != "\"" })
  }

  /// Every `method` request is refused until it answers nonce n3: the 401
  /// that refuses nonce nX offers n(X+1), with `stale=true` when `stale`.
  @Test(
    "A retry refused with stale=true and a new nonce is answered once more",
    .timeLimit(.minutes(1)),
    arguments: [
      ("SETUP", true, ["n1", "n2", "n3"]),
      ("SETUP", false, ["n1", "n2"]),
      ("PAUSE", true, ["n1", "n2", "n3"]),
      ("PAUSE", false, ["n1", "n2"]),
    ])
  func staleRetryAnsweredOnceMore(method: String, stale: Bool, nonces: [String]) async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { [self] request in
      let nonce = digestNonce(request)
      if request.method == "DESCRIBE", nonce == nil {
        return FakeRTSPResponse(
          statusCode: 401, headers: [("WWW-Authenticate", "Digest realm=\"fake\", nonce=\"n1\"")])
      }
      guard request.method == method, let nonce, nonce != "n3",
        let number = Int(nonce.dropFirst())
      else { return nil }
      return FakeRTSPResponse(
        statusCode: 401,
        headers: [
          (
            "WWW-Authenticate",
            "Digest realm=\"fake\", nonce=\"n\(number + 1)\"" + (stale ? ", stale=true" : "")
          )
        ])
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "user", password: "pass"),
      transport: .tcp)
    var result = await outcome { _ = try await session.start() }
    if method == "PAUSE" { result = await outcome { try await session.pause() } }
    await session.stop()
    #expect(server.requests(method: method).map(digestNonce) == nonces)
    if stale {
      #expect(throws: Never.self) { try result.get() }
    } else if method == "SETUP" {
      guard case .failure(let error) = result, case RTSPError.authenticationFailed = error else {
        Issue.record("Expected authenticationFailed, got \(result)")
        return
      }
    } else {
      #expect(throws: (any Error).self) { try result.get() }
    }
  }

  @Test("A refused PAUSE's last challenge is the one the next request answers")
  func lastControlChallengeTakenIn() async throws {
    // PAUSE is refused with n2, its retry with n3; PLAY is refused unless it
    // answers n3.
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { [self] request in
      let nonce = digestNonce(request)
      if request.method == "DESCRIBE", nonce == nil {
        return FakeRTSPResponse(
          statusCode: 401, headers: [("WWW-Authenticate", "Digest realm=\"fake\", nonce=\"n1\"")])
      }
      if request.method == "PAUSE" {
        let next = nonce == "n1" ? "n2" : "n3"
        return FakeRTSPResponse(
          statusCode: 401,
          headers: [("WWW-Authenticate", "Digest realm=\"fake\", nonce=\"\(next)\"")])
      }
      if request.method == "PLAY", server.requests(method: "PAUSE").count > 0, nonce != "n3" {
        return FakeRTSPResponse(
          statusCode: 401, headers: [("WWW-Authenticate", "Digest realm=\"fake\", nonce=\"n4\"")])
      }
      return nil
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "user", password: "pass"),
      transport: .tcp)
    _ = try await session.start()
    let paused = await outcome { try await session.pause() }
    #expect(throws: (any Error).self) { try paused.get() }
    let played = await outcome { try await session.play(PlayOptions()) }
    await session.stop()
    #expect(throws: Never.self) { try played.get() }
    #expect(server.requests(method: "PAUSE").map(digestNonce) == ["n1", "n2"])
    #expect(server.requests(method: "PLAY").map(digestNonce).last == "n3")
  }

  @Test("A Basic offer first made on the retry's 401 still gets Basic once")
  func basicOfferedOnRetryFallsBack() async throws {
    // DESCRIBE offers only Digest; the Digest retry is refused with a 401
    // that also offers Basic, and only Basic is accepted.
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      let authorization = request.header("Authorization") ?? ""
      guard request.method == "DESCRIBE", !authorization.hasPrefix("Basic ") else { return nil }
      let challenge =
        authorization.isEmpty
        ? "Digest realm=\"fake\", nonce=\"n1\""
        : "Digest realm=\"fake\", nonce=\"n1\", Basic realm=\"fake\""
      return FakeRTSPResponse(statusCode: 401, headers: [("WWW-Authenticate", challenge)])
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "user", password: "pass"),
      transport: .tcp)
    let started = await outcome { try await session.start() }
    await session.stop()
    #expect(throws: Never.self) { try started.get() }
    #expect(authSchemes(server, "DESCRIBE") == [nil, "Digest", "Basic"])
  }

  @Test("Basic offered only on an earlier request's 401 isn't this request's fallback")
  func basicFallbackNeedsThisRequestsOffer() async throws {
    // OPTIONS: Digest A and Basic offered, Digest accepted. DESCRIBE: every
    // Digest refused with a new nonce, offering Digest only.
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      func challenge(_ nonce: String, basic: Bool) -> FakeRTSPResponse {
        var headers = [("WWW-Authenticate", "Digest realm=\"cam\", nonce=\"\(nonce)\"")]
        if basic { headers.append(("WWW-Authenticate", "Basic realm=\"cam\"")) }
        return FakeRTSPResponse(statusCode: 401, headers: headers)
      }
      guard let authorization = request.header("Authorization") else {
        return challenge("A", basic: true)
      }
      if authorization.hasPrefix("Basic") { return FakeRTSPResponse(statusCode: 401) }
      if request.method == "OPTIONS" { return nil }
      return challenge(authorization.contains("nonce=\"A\"") ? "B" : "C", basic: false)
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "admin", password: "secret"),
      transport: .tcp)
    let result = await outcome { try await session.start() }
    await session.stop()
    #expect(throws: RTSPError.self) { try result.get() }
    // DESCRIBE answers OPTIONS' challenge, then B's; C refuses the password.
    #expect(authSchemes(server, "DESCRIBE") == ["Digest", "Digest"])
  }

  @Test("A Digest refused with the same nonce still falls back to Basic once")
  func sameNonceDigestFallsBackToBasic() async throws {
    // Digest is accepted for OPTIONS; DESCRIBE accepts only Basic.
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    let challenge = "Digest realm=\"fake\", nonce=\"fixed\", Basic realm=\"fake\""
    server.onRequest = { request in
      let authorization = request.header("Authorization") ?? ""
      let refused =
        authorization.isEmpty
        || (request.method == "DESCRIBE" && !authorization.hasPrefix("Basic "))
      return refused
        ? FakeRTSPResponse(statusCode: 401, headers: [("WWW-Authenticate", challenge)]) : nil
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "user", password: "pass"),
      transport: .tcp)
    let started = await outcome { try await session.start() }
    await session.stop()
    if case .failure(let error) = started { Issue.record("start() failed: \(error)") }
    #expect(authSchemes(server, "OPTIONS") == [nil, "Digest"])
    #expect(authSchemes(server, "DESCRIBE") == ["Digest", "Basic"])
  }

  @Test("A Basic fallback answered with a non-auth error still keeps Basic")
  func basicKeptAfterNonAuthFailure() async throws {
    // OPTIONS needs no credentials; everything else needs Basic, and the
    // backchannel feature tag isn't supported (DESCRIBE with it gets 551).
    var configuration = FakeRTSPServer.Configuration(sdp: h264VideoOnlySDP())
    configuration.supportedFeatureTags = ["onvif-replay"]
    let server = FakeRTSPServer(configuration: configuration)
    server.onRequest = { request in
      guard request.method != "OPTIONS",
        request.header("Authorization")?.hasPrefix("Basic ") != true
      else { return nil }
      return FakeRTSPResponse(
        statusCode: 401,
        headers: [
          ("WWW-Authenticate", "Digest realm=\"fake\", nonce=\"n1\""),
          ("WWW-Authenticate", "Basic realm=\"fake\""),
        ])
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "user", password: "pass"),
      transport: .tcp, onvif: .backchannel)
    let started = await outcome { try await session.start() }
    await session.stop()
    if case .failure(let error) = started { Issue.record("start() failed: \(error)") }
    #expect(authSchemes(server, "DESCRIBE") == [nil, "Digest", "Basic", "Basic"])
  }

  @Test(
    "A list with one entry per media section names three and counts the rest",
    .timeLimit(.minutes(1)))
  func perSectionListsShortened() async throws {
    let long = String(repeating: "B", count: 500)
    // 64 sections of an unsupported media type: start() names what was offered.
    let unsupported = FakeRTSPServer(
      sdp: makeTestSDP(
        media: (0..<64).map {
          "m=\(long)\($0) 0 RTP/AVP 96\r\na=rtpmap:96 \(long)\($0)/90000\r\na=control:t\($0)\r\n"
        }))
    try await unsupported.start()
    defer { unsupported.stop() }
    let session = RTSPClientSession(url: unsupported.url, transport: .tcp)
    let started = await outcome { try await session.start() }
    await session.stop()
    guard case .failure(let error) = started else {
      Issue.record("start() succeeded")
      return
    }
    #expect("\(error)".contains("and 61 more"), "\(String(describing: error).prefix(80))")
    #expect("\(error)".unicodeScalars.count < 1000)

    // 64 malformed m= lines and 64 sections whose rtpmap doesn't parse.
    let sections =
      (0..<64).map { "m=video\(long)\($0)\r\n" }
      + (0..<64).map { "m=video 0 RTP/AVP 96\r\na=rtpmap:96 \(long)\($0)\r\n" }
    let describe = RTSPResponse(
      statusCode: 200, reasonPhrase: "OK", headers: [("Content-Type", "application/sdp")],
      body: Data(makeTestSDP(media: sections).utf8))
    do {
      _ = try parseDescribe(requestURL: "rtsp://127.0.0.1/s", response: describe)
      Issue.record("parseDescribe succeeded")
    } catch {
      #expect("\(error)".contains("more"), "\(String(describing: error).prefix(80))")
      #expect("\(error)".unicodeScalars.count < 1000)
    }

    // A backchannel offered in 63 codecs that can't be sent.
    let backchannel = FakeRTSPServer(
      sdp: makeTestSDP(
        media: [h264VideoMediaSDP()]
          + (0..<63).map {
            "m=audio 0 RTP/AVP 97\r\na=rtpmap:97 \(long)\($0)/8000\r\n"
              + "a=control:b\($0)\r\na=sendonly\r\n"
          }))
    try await backchannel.start()
    defer { backchannel.stop() }
    let log = DiagnosticLog()
    let talking = RTSPClientSession(
      url: backchannel.url, transport: .tcp, onvif: .backchannel,
      onDiagnostic: { log.add($0.message) })
    let talkStarted = await outcome { try await talking.start() }
    await talking.stop()
    if case .failure(let error) = talkStarted { Issue.record("start() failed: \(error)") }
    let codecs = log.all.filter { $0.contains("backchannel codecs") }
    #expect(codecs.count == 1 && codecs.allSatisfy { $0.contains("and 60 more") })
    for message in log.all {
      #expect(message.unicodeScalars.count < 1000, "\(message.prefix(60))")
    }
  }

  @Test(
    "Long reason phrases and fmtp values are cut in warnings and errors", .timeLimit(.minutes(1)))
  func longServerTextCutInWarnings() async throws {
    // A status line that doesn't parse is quoted cut, in RTSP and in the
    // HTTP tunnel's GET reply.
    let marks = String(repeating: "\u{301}", count: 3_000)
    for line in [
      "RTSP/1.0 x00 " + marks, "RTSP/1.0" + marks, "HTTP/1.1 4x4 a" + marks,
    ] {
      var raw = Data((line + "\r\nCSeq: 1\r\n\r\n").utf8)
      do {
        if line.hasPrefix("HTTP") {
          _ = try HTTPResponseHead.parse(raw)
        } else {
          _ = try RTSPParser().parse(&raw)
        }
        Issue.record("\(line.prefix(14)) parsed")
      } catch {
        #expect("\(error)".unicodeScalars.count < 150, "\(line.prefix(14))")
      }
    }

    let long = String(repeating: "x", count: 3_000)
    let server = FakeRTSPServer(
      sdp: makeTestSDP(media: [
        h264VideoMediaSDP(), pcmuAudioMediaSDP(), onvifMetadataMediaSDP(),
      ]))
    server.onRequest = { request in
      guard request.method == "SETUP",
        request.url.hasSuffix("/audio") || request.url.hasSuffix("/metadata")
      else {
        return nil
      }
      return FakeRTSPResponse(statusCode: 454, reason: long)
    }
    try await server.start()
    defer { server.stop() }
    let log = DiagnosticLog()
    let session = RTSPClientSession(
      url: server.url, transport: .tcp, onDiagnostic: { log.add($0.message) })
    let started = await outcome { try await session.start() }
    await session.stop()
    if case .failure(let error) = started { Issue.record("start() failed: \(error)") }
    let setupWarnings = log.all.filter { $0.contains("SETUP failed") }
    #expect(setupWarnings.count == 2, "\(log.all.map { $0.prefix(80) })")
    for message in log.all {
      #expect(message.utf8.count < 300, "\(message.prefix(80))")
    }
    for fmtp in ["mode=\(long)", "mode=AAC-hbr;sizelength=\(long)", "\(long);mode=AAC-hbr"] {
      #expect(throws: (any Error).self) {
        do {
          _ = try RTPAudioPacketizer(
            encodingName: "MPEG4-GENERIC", clockRate: 16000, channels: 1, payloadType: 97,
            formatSpecificParams: fmtp, ssrc: 1, sequenceNumber: 0, timestamp: 0)
        } catch {
          #expect("\(error)".utf8.count < 300, "\(String(describing: error).prefix(80))")
          throw error
        }
      }
    }
  }

  @Test("An OPTIONS 401 without a usable challenge leaves DESCRIBE its turn")
  func optionsWithoutChallengeIgnored() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      request.method == "OPTIONS" ? FakeRTSPResponse(statusCode: 401) : nil
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "user", password: "pass"),
      transport: .tcp)
    let started = await outcome { try await session.start() }
    await session.stop()
    if case .failure(let error) = started { Issue.record("start() failed: \(error)") }
    #expect(server.requests(method: "DESCRIBE").count == 1)
  }

  @Test("A request refused with Basic is retried once when the server now offers Digest")
  func refusedBasicRetriedWithNewDigest() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      let authorization = request.header("Authorization") ?? ""
      switch request.method {
      case "DESCRIBE" where authorization.isEmpty:
        return FakeRTSPResponse(
          statusCode: 401, headers: [("WWW-Authenticate", "Basic realm=\"fake\"")])
      case "SETUP" where !authorization.hasPrefix("Digest "):
        return FakeRTSPResponse(
          statusCode: 401,
          headers: [
            ("WWW-Authenticate", "Basic realm=\"fake\", Digest realm=\"fake\", nonce=\"n1\"")
          ])
      default:
        return nil
      }
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "user", password: "pass"),
      transport: .tcp)
    let started = await outcome { try await session.start() }
    await session.stop()
    if case .failure(let error) = started { Issue.record("start() failed: \(error)") }
    #expect(authSchemes(server, "SETUP") == ["Basic", "Digest"])
  }

  @Test(
    "A control request refused with Basic isn't retried with the same Basic",
    .timeLimit(.minutes(1)))
  func refusedBasicControlRequestNotResent() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      let unauthorized = FakeRTSPResponse(
        statusCode: 401, headers: [("WWW-Authenticate", "Basic realm=\"fake\"")])
      if request.method == "DESCRIBE", request.header("Authorization") == nil {
        return unauthorized
      }
      return request.method == "PAUSE" ? unauthorized : nil
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "user", password: "pass"),
      transport: .tcp)
    _ = try await session.start()
    let paused = await outcome { try await session.pause() }
    await session.stop()
    if case .success = paused { Issue.record("pause() succeeded") }
    #expect(authSchemes(server, "PAUSE") == ["Basic"])
  }

  // MARK: - RTP-Info is advisory

  @Test("An unparseable seq, rtptime or ssrc in RTP-Info is ignored, not fatal")
  func rtpInfoBadValuesIgnored() throws {
    var p = twoStreamPresentation("rtsp://h/s/track1", "rtsp://h/s/track2")
    let resp = RTSPResponse(
      statusCode: 200, reasonPhrase: "OK",
      headers: [
        (
          "RTP-Info",
          "url=rtsp://h/s/track1;seq=bogus;rtptime=100;ssrc=zz,"
            + "url=rtsp://h/s/track2;seq=20;rtptime=x;ssrc=1A2B"
        )
      ])
    try parsePlay(response: resp, presentation: &p)
    #expect(seqs(p) == [nil, 20])
    guard case .setup(let first) = p.streams[0].state,
      case .setup(let second) = p.streams[1].state
    else {
      Issue.record("Expected setup state")
      return
    }
    #expect(first.initialRtptime == 100)
    #expect(first.ssrc == nil)
    #expect(second.initialRtptime == nil)
    #expect(second.ssrc == 0x1A2B)
  }

  @Test("start() succeeds when the PLAY response's RTP-Info has a malformed seq")
  func startWithMalformedRTPInfoSeq() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    let control = server.controlURL("video")
    server.transformResponse = { request, response in
      guard request.method == "PLAY" else { return response }
      var response = response
      response.setHeader("RTP-Info", "url=\(control);seq=12x;rtptime=90000")
      return response
    }
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url, transport: .tcp)
    let started = await outcome { try await session.start() }
    await session.stop()
    if case .failure(let error) = started { Issue.record("start() failed: \(error)") }
    let play = server.exchanges.first { $0.request.method == "PLAY" }
    #expect(play?.response.header("RTP-Info")?.contains("seq=12x") == true)
  }

  @Test("RTP-Info matching stays linear in streams and entries")
  func rtpInfoMatchingIsLinear() throws {
    let streamCount = 20_000
    var streams: [IPCamKit.Stream] = []
    streams.reserveCapacity(streamCount)
    for index in 0..<streamCount {
      let stream = IPCamKit.Stream(
        media: "video", encodingName: "h264", rtpPayloadType: 96, clockRateHz: 90000,
        control: "rtsp://h/s/t\(index)")
      streams.append(stream)
    }
    var p = Presentation(streams: streams, baseURL: "rtsp://h/s/", control: "rtsp://h/s/")
    initStreamsForPlay(&p)
    // 10K entries naming the last 10K streams: a scan of the streams per entry
    // would walk past at least 10K of them each time.
    let entries: [String] = (10_000..<streamCount).map { "url=t\($0);seq=\($0)" }
    let resp = RTSPResponse(
      statusCode: 200, reasonPhrase: "OK",
      headers: [("RTP-Info", entries.joined(separator: ","))])
    let elapsed: Duration = try ContinuousClock().measure {
      try parsePlay(response: resp, presentation: &p)
    }
    #expect(elapsed < .seconds(1), "parsePlay took \(elapsed)")
    let matched: [UInt16?] = [0, 9_999, 10_000, 19_999].map { index -> UInt16? in
      if case .setup(let s) = p.streams[index].state { return s.initialSeq }
      return nil
    }
    #expect(matched == [nil, nil, 10_000, 19_999])
  }

  @Test("RTP-Info with duplicate control URLs updates the first matching stream")
  func rtpInfoDuplicateControlFirstMatch() throws {
    var p = twoStreamPresentation("rtsp://h/s/track1", "rtsp://h/s/track1")
    let resp = RTSPResponse(
      statusCode: 200, reasonPhrase: "OK",
      headers: [("RTP-Info", "url=track1;seq=10,url=rtsp://h/s/track1;seq=11")])
    try parsePlay(response: resp, presentation: &p)
    #expect(seqs(p) == [11, nil])
  }

  // MARK: - Latin-1 header values in Digest

  private func md5Hex(_ bytes: Data) -> String {
    Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  @Test("Digest over a GBK realm hashes and echoes the bytes the server sent")
  func latin1DigestRealm() throws {
    let realm: [UInt8] = [0xC9, 0xE3, 0xCF, 0xF1, 0xBB, 0xFA]  // GBK "camera"
    let opaque: [UInt8] = [0x81, 0x40, 0x5A]  // a GBK character in the C1 range
    var data = Data("RTSP/1.0 401 Unauthorized\r\nCSeq: 2\r\n".utf8)
    data.append(Data("WWW-Authenticate: Digest realm=\"".utf8))
    data.append(contentsOf: realm)
    data.append(Data("\", nonce=\"abc\", opaque=\"".utf8))
    data.append(contentsOf: opaque)
    data.append(Data("\"\r\n\r\n".utf8))
    let resp = try parseResponse(&data)

    let values: [RTSPHeaderValue] = resp.headerValues(named: "WWW-Authenticate")
    #expect(values.count == 1)
    #expect(values.first?.isLatin1 == true)
    var challengeBytes = Data("Digest realm=\"".utf8)
    challengeBytes.append(contentsOf: realm)
    challengeBytes.append(Data("\", nonce=\"abc\", opaque=\"".utf8))
    challengeBytes.append(contentsOf: opaque)
    challengeBytes.append(Data("\"".utf8))
    #expect(values.first?.bytes == challengeBytes)

    // A non-ASCII username stays UTF-8 next to the server's GBK bytes.
    var auth = RTSPAuthenticator(credentials: Credentials(username: "jos\u{E9}", password: "pass"))
    auth.handleChallenges(values)
    let header: RTSPHeaderValue? = auth.authorizationHeader(method: "DESCRIBE", uri: "rtsp://h/p")
    let authorization = try #require(header)
    #expect(authorization.isLatin1)

    var request = RTSPRequest(method: .describe, url: "rtsp://h/p")
    request.setHeader("CSeq", value: "3")
    request.setHeader("Authorization", value: authorization)
    let wire = RTSPSerializer().serialize(request)

    var ha1Input = Data("jos\u{E9}:".utf8)
    ha1Input.append(contentsOf: realm)
    ha1Input.append(Data(":pass".utf8))
    let ha1 = md5Hex(ha1Input)
    let ha2 = md5Hex(Data("DESCRIBE:rtsp://h/p".utf8))
    let response = md5Hex(Data("\(ha1):abc:\(ha2)".utf8))
    var expected = Data("DESCRIBE rtsp://h/p RTSP/1.0\r\nCSeq: 3\r\n".utf8)
    expected.append(Data("Authorization: Digest username=\"jos\u{E9}\", realm=\"".utf8))
    expected.append(contentsOf: realm)
    expected.append(Data("\", nonce=\"abc\", uri=\"rtsp://h/p\", response=\"\(response)\"".utf8))
    expected.append(Data(", opaque=\"".utf8))
    expected.append(contentsOf: opaque)
    expected.append(Data("\"\r\n\r\n".utf8))
    #expect(wire == expected)

    // Setting the header from a String again goes back to UTF-8.
    request.setHeader("Authorization", value: "Basic eA==")
    let reset = String(data: RTSPSerializer().serialize(request), encoding: .utf8)
    #expect(reset?.contains("Authorization: Basic eA==\r\n") == true)
  }

  @Test("A UTF-8 realm is still hashed and echoed as UTF-8")
  func utf8DigestRealm() throws {
    let raw: String =
      "RTSP/1.0 401 Unauthorized\r\nCSeq: 2\r\n"
      + "WWW-Authenticate: Digest realm=\"caf\u{E9}\", nonce=\"abc\"\r\n\r\n"
    var data = Data(raw.utf8)
    let resp = try parseResponse(&data)
    let values: [RTSPHeaderValue] = resp.headerValues(named: "WWW-Authenticate")
    #expect(values.first?.isLatin1 == false)
    var auth = RTSPAuthenticator(credentials: Credentials(username: "user", password: "pass"))
    auth.handleChallenges(values)
    let header: RTSPHeaderValue? = auth.authorizationHeader(method: "DESCRIBE", uri: "rtsp://h/p")
    let authorization = try #require(header)
    #expect(!authorization.isLatin1)
    var request = RTSPRequest(method: .describe, url: "rtsp://h/p")
    request.setHeader("Authorization", value: authorization)
    let wire = RTSPSerializer().serialize(request)
    let ha1 = md5Hex(Data("user:caf\u{E9}:pass".utf8))
    let ha2 = md5Hex(Data("DESCRIBE:rtsp://h/p".utf8))
    let response = md5Hex(Data("\(ha1):abc:\(ha2)".utf8))
    let text = String(data: wire, encoding: .utf8) ?? ""
    #expect(text.contains("realm=\"caf\u{E9}\", nonce=\"abc\""))
    #expect(text.contains("response=\"\(response)\""))
  }

  // MARK: - Blank line after CR CR LF or LF line endings

  /// Every response in `data`, fed to the parser one byte at a time.
  private func parseByteByByte(_ data: Data) throws -> [RTSPResponse] {
    var buffer = Data()
    var responses: [RTSPResponse] = []
    for byte in data {
      buffer.append(byte)
      while case .message(.response(let response)) = try parser.parseNext(&buffer) {
        responses.append(response)
      }
    }
    #expect(buffer.isEmpty)
    return responses
  }

  @Test("A blank line after CR CR LF or LF line endings ends the header block")
  func blankLineAfterSloppyLineEndings() throws {
    let blocks: [String] = [
      "RTSP/1.0 200 OK\r\r\nCSeq: 1\r\r\nSession: s1\r\r\nContent-Length: 4\r\r\n\r\r\nbody",
      "RTSP/1.0 200 OK\nCSeq: 1\nSession: s1\nContent-Length: 4\n\r\nbody",
      "RTSP/1.0 200 OK\r\nCSeq: 1\r\nSession: s1\r\nContent-Length: 4\r\n\r\r\nbody",
      "RTSP/1.0 200 OK\nCSeq: 1\nSession: s1\nContent-Length: 4\r\r\n\r\r\r\nbody",
    ]
    for block in blocks {
      let next = "RTSP/1.0 200 OK\r\nCSeq: 2\r\n\r\n"
      let bytes = Data((block + next).utf8)
      var data = bytes
      let first = try parseResponse(&data)
      #expect(first.cseq == 1, "\(block.debugDescription)")
      #expect(first.header("Session") == "s1", "\(block.debugDescription)")
      #expect(first.body == Data("body".utf8), "\(block.debugDescription)")
      let second = try parseResponse(&data)
      #expect(second.cseq == 2, "\(block.debugDescription)")
      #expect(data.isEmpty)

      let chunked = try parseByteByByte(bytes)
      let cseqs: [UInt32?] = chunked.map(\.cseq)
      #expect(cseqs == [1, 2], "\(block.debugDescription)")
      #expect(chunked.first?.header("Session") == "s1")
      #expect(chunked.first?.body == Data("body".utf8))
    }
  }

  @Test("A line of only CRs ends the header block; extra CRs ending a line do not")
  func blankLineBoundaryShapes() {
    // The boundary runs from the CR ending "CSeq: 1" to the LF after the CRs.
    let crOnly = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\r\r\nrest".utf8)
    let range: Range<Int>? = parser.findDoubleCRLF(in: crOnly)
    #expect(range == 24..<30)
    let text = Data("RTSP/1.0 200 OK\r\nX: a\r\r\nb\r\n".utf8)
    #expect(parser.findDoubleCRLF(in: text) == nil)
  }

  @Test(
    "A header name the framing doesn't take for Content-Length isn't listed as one",
    arguments: ["\u{A0}", "\u{3000}"])
  func contentLengthNameAgreesWithFraming(_ space: String) throws {
    var data = Data(
      ("RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length\(space): 5\r\n\r\n"
        + "RTSP/1.0 200 OK\r\nCSeq: 2\r\n\r\n").utf8)
    guard case .response(let response) = try #require(try parser.parse(&data)).0 else {
      Issue.record("expected a response")
      return
    }
    #expect(response.header("Content-Length") == nil)
    #expect(response.body.isEmpty)
    guard case .response(let next) = try #require(try parser.parse(&data)).0 else {
      Issue.record("expected a second response")
      return
    }
    #expect(next.cseq == 2)
  }

  // MARK: - Folded header lines in HTTP response heads

  @Test("HTTP response heads join folded header lines as RTSP responses do")
  func httpResponseHeadFolding() throws {
    let text: String =
      "HTTP/1.0 401 Unauthorized\r\n X-Stray: 1\r\n"
      + "WWW-Authenticate: Digest realm=\"cam\",\r\n nonce=\"abc\",\r\n\t  qop=\"auth\"\r\n"
      + "X-Note: a\r\n \r\n b: c\r\nno colon\r\n X-More: 2\r\nX-Empty:\r\n v\r\n"
      + "Content-Length: 0\r\n\r\n"
    let parsed = try #require(try HTTPResponseHead.parse(Data(text.utf8)))
    let head = parsed.head
    let names: [String] = head.headers.map { $0.0 }
    #expect(names == ["WWW-Authenticate", "X-Note", "X-Empty", "Content-Length"])
    #expect(head.header("WWW-Authenticate") == "Digest realm=\"cam\", nonce=\"abc\", qop=\"auth\"")
    #expect(head.header("X-Note") == "a b: c")
    #expect(head.header("X-Empty") == "v")
    #expect(parsed.length == text.utf8.count)
  }
}
