// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Replaces upstream rtsp_types crate serialization

import Foundation

/// Serializes RTSP requests to bytes for sending over a TCP connection.
public struct RTSPSerializer: Sendable {
  public init() {}

  /// Serialize an RTSP request to bytes.
  ///
  /// Format:
  /// ```
  /// METHOD url RTSP/1.0\r\n
  /// Header-Name: Header-Value\r\n
  /// Content-Length: <body length>\r\n  (if body is non-empty)
  /// \r\n
  /// <body>
  /// ```
  ///
  /// Control characters (below 0x20, or DEL) are stripped from the URL,
  /// version, header names and header values (a value keeps its tabs), so a
  /// value carrying a CR or LF can never start a new header line or request.
  ///
  /// Text is written as UTF-8, except the value of a header that
  /// `RTSPRequest.setHeader(_:value:)` set from a Latin-1 `RTSPHeaderValue`:
  /// that one is written one byte per scalar, so a Digest answer echoes a
  /// GBK `realm` in the bytes the server sent. Control characters are
  /// stripped first either way, and a Latin-1 value holding a scalar above
  /// U+00FF is written as UTF-8.
  public func serialize(_ request: RTSPRequest) -> Data {
    let url = strippingControlCharacters(request.url, keepTab: false)
    let version = strippingControlCharacters(request.version, keepTab: false)
    var data = Data("\(request.method.rawValue) \(url) \(version)\r\n".utf8)

    for (name, value) in request.headers {
      let isLatin1 = request.latin1HeaderNames.contains(name.lowercased())
      let name = strippingControlCharacters(name, keepTab: false)
      let value = strippingControlCharacters(value, keepTab: true)
      data.append(contentsOf: "\(name): ".utf8)
      if isLatin1, let bytes = RTSPHeaderValue.latin1Bytes(value) {
        data.append(bytes)
      } else {
        data.append(contentsOf: value.utf8)
      }
      data.append(contentsOf: "\r\n".utf8)
    }

    if !request.body.isEmpty {
      // Add Content-Length if not already present
      let hasContentLength = request.headers.contains(where: {
        $0.0.lowercased() == "content-length"
      })
      if !hasContentLength {
        data.append(contentsOf: "Content-Length: \(request.body.count)\r\n".utf8)
      }
    }

    data.append(contentsOf: "\r\n".utf8)
    if !request.body.isEmpty {
      data.append(request.body)
    }

    return data
  }

  /// The reply to a request the server sent on the connection
  /// (`RTSPParseResult.serverRequest`): `200 OK` with no body for `OPTIONS` and
  /// `GET_PARAMETER` (keepalive probes), `501 Not Implemented` for anything else.
  /// Echoes `CSeq`, and `Session` when the request carried one.
  func serializeReply(to request: RTSPServerRequest) -> Data {
    let method = request.method.uppercased()
    let status = method == "OPTIONS" || method == "GET_PARAMETER" ? "200 OK" : "501 Not Implemented"
    let version = request.version.hasPrefix("RTSP/") ? request.version : "RTSP/1.0"
    var headers: [(String, String)] = []
    if let cseq = request.header("CSeq") { headers.append(("CSeq", cseq)) }
    if let session = request.header("Session") { headers.append(("Session", session)) }
    var result = "\(strippingControlCharacters(version, keepTab: false)) \(status)\r\n"
    for (name, value) in headers {
      result += "\(name): \(strippingControlCharacters(value, keepTab: true))\r\n"
    }
    result += "\r\n"
    return Data(result.utf8)
  }

  /// `s` without control characters (below 0x20, or DEL), keeping horizontal
  /// tabs when `keepTab` is set. Returns `s` itself in the common clean case.
  private func strippingControlCharacters(_ s: String, keepTab: Bool) -> String {
    func isControl(_ scalar: Unicode.Scalar) -> Bool {
      (scalar.value < 0x20 && !(keepTab && scalar == "\t")) || scalar.value == 0x7F
    }
    guard s.unicodeScalars.contains(where: isControl) else { return s }
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: s.unicodeScalars.lazy.filter { !isControl($0) })
    return String(scalars)
  }

  /// Serialize interleaved data for sending over TCP.
  ///
  /// Format: '$' + channel_id (1 byte) + length (2 bytes BE) + data
  public func serializeInterleaved(_ interleavedData: RTSPInterleavedData) -> Data {
    precondition(
      interleavedData.data.count <= 0xFFFF,
      "interleaved frame is \(interleavedData.data.count) bytes; "
        + "the 16-bit length field caps it at 65535")
    var result = Data(capacity: 4 + interleavedData.data.count)
    result.append(0x24)  // '$'
    result.append(interleavedData.channelId)
    let length = UInt16(interleavedData.data.count)
    result.append(UInt8(length >> 8))
    result.append(UInt8(length & 0xFF))
    result.append(interleavedData.data)
    return result
  }
}
