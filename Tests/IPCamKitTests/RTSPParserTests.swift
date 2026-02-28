// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Tests for RTSP message parsing, serialization, and interleaved data framing.
// Ports longse_cseq test from upstream src/client/parse.rs + basic parsing tests.

import Foundation
import Testing

@testable import IPCamKit

@Suite("RTSP Parser Tests")
struct RTSPParserTests {
  let parser = RTSPParser()
  let serializer = RTSPSerializer()

  // MARK: - Response Parsing

  @Test("Parse simple 200 OK response")
  func parseSimpleResponse() throws {
    var data = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n".utf8)
    let result = try parser.parse(&data)
    guard case .response(let resp) = result?.0 else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.statusCode == 200)
    #expect(resp.reasonPhrase == "OK")
    #expect(resp.version == "RTSP/1.0")
    #expect(resp.cseq == 1)
    #expect(data.isEmpty)
  }

  @Test("Parse response with body")
  func parseResponseWithBody() throws {
    let bodyContent = "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\n"
    let bodyByteCount = bodyContent.utf8.count
    let response =
      "RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Length: \(bodyByteCount)\r\n\r\n"
      + bodyContent
    var data = Data(response.utf8)
    let result = try parser.parse(&data)
    guard case .response(let resp) = result?.0 else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.statusCode == 200)
    #expect(resp.body == Data(bodyContent.utf8))
    #expect(resp.contentLength == bodyByteCount)
    #expect(data.isEmpty)
  }

  @Test("Parse 401 Unauthorized response")
  func parse401() throws {
    var data = Data(
      ("RTSP/1.0 401 Unauthorized\r\n"
        + "CSeq: 1\r\n"
        + "WWW-Authenticate: Digest realm=\"test\", nonce=\"abc123\"\r\n"
        + "\r\n").utf8)
    let result = try parser.parse(&data)
    guard case .response(let resp) = result?.0 else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.statusCode == 401)
    #expect(resp.reasonPhrase == "Unauthorized")
    let auth = resp.header("WWW-Authenticate")
    #expect(auth != nil)
    #expect(auth!.contains("Digest"))
  }

  /// Port of upstream `longse_cseq` test from parse.rs.
  /// Tests parsing CSeq with trailing whitespace (Longse CMSEKL800 camera quirk).
  @Test("Parse CSeq with trailing whitespace (Longse camera quirk)")
  func longseCSeq() throws {
    let raw = try loadTestData("longse_unauthorized.txt")
    var data = raw
    let result = try parser.parse(&data)
    guard case .response(let resp) = result?.0 else {
      Issue.record("Expected response")
      return
    }
    // The Longse camera sends "CSeq: 1 " with trailing space
    #expect(resp.cseq == 1)
    #expect(resp.statusCode == 401)
  }

  @Test("Parse OPTIONS response with multiple headers")
  func parseOptionsResponse() throws {
    let raw = try loadTestData("dahua_options.txt")
    var data = raw
    let result = try parser.parse(&data)
    guard case .response(let resp) = result?.0 else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.statusCode == 200)
    let publicHeader = resp.header("Public")
    #expect(publicHeader != nil)
    #expect(publicHeader!.contains("OPTIONS"))
    #expect(publicHeader!.contains("DESCRIBE"))
    #expect(publicHeader!.contains("TEARDOWN"))
  }

  @Test("Incomplete response returns nil")
  func incompleteResponse() throws {
    var data = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\n".utf8)
    let result = try parser.parse(&data)
    #expect(result == nil)
  }

  @Test("Skip leading CRLF pairs")
  func skipLeadingCRLF() throws {
    var data = Data("\r\n\r\nRTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n".utf8)
    let result = try parser.parse(&data)
    guard case .response(let resp) = result?.0 else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.statusCode == 200)
  }

  // MARK: - Interleaved Data Parsing

  @Test("Parse interleaved data frame")
  func parseInterleavedData() throws {
    let payload = Data([0x80, 0x60, 0x00, 0x01])
    var data = Data([0x24, 0x00])  // '$' + channel 0
    data.append(UInt8(0x00))  // length high byte
    data.append(UInt8(0x04))  // length low byte
    data.append(payload)

    var buffer = data
    let result = try parser.parse(&buffer)
    guard case .data(let interleaved) = result?.0 else {
      Issue.record("Expected interleaved data")
      return
    }
    #expect(interleaved.channelId == 0)
    #expect(interleaved.data == payload)
    #expect(buffer.isEmpty)
  }

  @Test("Interleaved data with CRLF prefix")
  func interleavedWithCRLFPrefix() throws {
    var data = Data([0x0D, 0x0A])  // CRLF
    data.append(contentsOf: [0x24, 0x00, 0x00, 0x04])  // $ + chan + len
    data.append(contentsOf: [0x61, 0x73, 0x64, 0x66])  // "asdf"

    var buffer = data
    let result = try parser.parse(&buffer)
    guard case .data(let interleaved) = result?.0 else {
      Issue.record("Expected interleaved data")
      return
    }
    #expect(interleaved.channelId == 0)
    #expect(interleaved.data == Data("asdf".utf8))
  }

  @Test("Incomplete interleaved data returns nil")
  func incompleteInterleavedData() throws {
    var data = Data([0x24, 0x00, 0x00, 0x08, 0x01, 0x02])  // Need 8 bytes but only have 2
    let result = try parser.parse(&data)
    #expect(result == nil)
  }

  // MARK: - Serialization

  @Test("Serialize RTSP request")
  func serializeRequest() throws {
    let request = RTSPRequest(
      method: .describe,
      url: "rtsp://192.168.1.1:554/stream",
      headers: [
        ("CSeq", "1"),
        ("Accept", "application/sdp"),
        ("User-Agent", "IPCamKit/1.0"),
      ]
    )
    let data = serializer.serialize(request)
    let str = String(data: data, encoding: .utf8)!
    #expect(str.hasPrefix("DESCRIBE rtsp://192.168.1.1:554/stream RTSP/1.0\r\n"))
    #expect(str.contains("CSeq: 1\r\n"))
    #expect(str.contains("Accept: application/sdp\r\n"))
    #expect(str.hasSuffix("\r\n\r\n"))
  }

  @Test("Serialize request with body includes Content-Length")
  func serializeRequestWithBody() throws {
    let body = Data("test body".utf8)
    let request = RTSPRequest(
      method: .announce,
      url: "rtsp://host/path",
      headers: [("CSeq", "5")],
      body: body
    )
    let data = serializer.serialize(request)
    let str = String(data: data, encoding: .utf8)!
    #expect(str.contains("Content-Length: 9\r\n"))
  }

  @Test("Serialize interleaved data")
  func serializeInterleavedData() {
    let payload = Data([0x80, 0x60, 0x00, 0x01])
    let interleaved = RTSPInterleavedData(channelId: 2, data: payload)
    let data = serializer.serializeInterleaved(interleaved)
    #expect(data[0] == 0x24)  // '$'
    #expect(data[1] == 2)  // channel
    #expect(data[2] == 0)  // length high
    #expect(data[3] == 4)  // length low
    #expect(data[4...] == payload[...])
  }

  // MARK: - Header Access

  @Test("Case-insensitive header lookup")
  func caseInsensitiveHeaders() {
    let resp = RTSPResponse(
      statusCode: 200,
      reasonPhrase: "OK",
      headers: [
        ("Content-Type", "application/sdp"),
        ("content-length", "100"),
      ]
    )
    #expect(resp.header("content-type") == "application/sdp")
    #expect(resp.header("Content-Length") == "100")
    #expect(resp.header("CONTENT-TYPE") == "application/sdp")
    #expect(resp.header("nonexistent") == nil)
  }

  // MARK: - Helpers

  func loadTestData(_ filename: String) throws -> Data {
    let url = Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "TestData")
    guard let url else {
      Issue.record("Test data file not found: \(filename)")
      return Data()
    }
    return try Data(contentsOf: url)
  }
}
