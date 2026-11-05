// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Replaces upstream rtsp_types crate with native Swift RTSP message types

import Foundation

/// RTSP request methods.
public enum RTSPMethod: String, Sendable {
  case options = "OPTIONS"
  case describe = "DESCRIBE"
  case announce = "ANNOUNCE"
  case setup = "SETUP"
  case play = "PLAY"
  case pause = "PAUSE"
  case record = "RECORD"
  case teardown = "TEARDOWN"
  case getParameter = "GET_PARAMETER"
  case setParameter = "SET_PARAMETER"
}

/// An RTSP request message.
public struct RTSPRequest: Sendable {
  public var method: RTSPMethod
  public var url: String
  public var version: String
  public var headers: [(String, String)]
  public var body: Data
  /// Lowercased names of the headers whose values `RTSPSerializer` writes as
  /// ISO Latin-1 bytes instead of UTF-8. Set by `setHeader(_:value:)` with a
  /// Latin-1 `RTSPHeaderValue`, cleared by setting the header to a `String`.
  var latin1HeaderNames: Set<String> = []

  public init(
    method: RTSPMethod,
    url: String,
    version: String = "RTSP/1.0",
    headers: [(String, String)] = [],
    body: Data = Data()
  ) {
    self.method = method
    self.url = url
    self.version = version
    self.headers = headers
    self.body = body
  }
}

/// An RTSP response message.
public struct RTSPResponse: Sendable {
  public var statusCode: UInt16
  public var reasonPhrase: String
  public var version: String
  public var headers: [(String, String)]
  public var body: Data
  /// Indices into `headers` of the values the parser decoded as ISO Latin-1
  /// because their bytes were not valid UTF-8. `headerValues(named:)` reports
  /// them, so a value that is hashed or echoed (a Digest `realm`) can be turned
  /// back into the bytes the server sent.
  var latin1HeaderIndices: Set<Int> = []

  public init(
    statusCode: UInt16,
    reasonPhrase: String,
    version: String = "RTSP/1.0",
    headers: [(String, String)] = [],
    body: Data = Data()
  ) {
    self.statusCode = statusCode
    self.reasonPhrase = reasonPhrase
    self.version = version
    self.headers = headers
    self.body = body
  }
}

/// A header value together with the charset that maps it back to bytes.
///
/// The parser decodes a header value as UTF-8, or as ISO Latin-1 when its
/// bytes are not valid UTF-8 (a camera sending GBK or Shift-JIS). Latin-1 maps
/// each byte to the scalar of the same number, so `bytes` of a Latin-1 value is
/// exactly what the server sent.
struct RTSPHeaderValue: Sendable, Equatable {
  var text: String
  /// `text` stands for its ISO Latin-1 encoding (every scalar is at most
  /// U+00FF) rather than its UTF-8 encoding.
  var isLatin1: Bool

  init(_ text: String, isLatin1: Bool = false) {
    self.text = text
    self.isLatin1 = isLatin1
  }

  /// The bytes `text` stands for: one byte per scalar when `isLatin1`, else
  /// UTF-8. A Latin-1 value holding a scalar above U+00FF (never produced by the
  /// parser) falls back to UTF-8.
  var bytes: Data {
    if isLatin1, let bytes = Self.latin1Bytes(text) { return bytes }
    return Data(text.utf8)
  }

  /// `bytes` decoded as ISO Latin-1: each byte becomes the scalar U+0000 to
  /// U+00FF with the same number.
  static func latin1Text<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: bytes.lazy.map { Unicode.Scalar($0) })
    return String(scalars)
  }

  /// `text` encoded as ISO Latin-1, or nil if a scalar is above U+00FF.
  static func latin1Bytes(_ text: String) -> Data? {
    var bytes = Data()
    bytes.reserveCapacity(text.unicodeScalars.count)
    for scalar in text.unicodeScalars {
      guard scalar.value <= 0xFF else { return nil }
      bytes.append(UInt8(scalar.value))
    }
    return bytes
  }
}

/// RTSP interleaved data (RTP/RTCP over TCP).
/// Format: '$' + 1-byte channel + 2-byte big-endian length + data
public struct RTSPInterleavedData: Sendable {
  public var channelId: UInt8
  public var data: Data

  public init(channelId: UInt8, data: Data) {
    self.channelId = channelId
    self.data = data
  }
}

/// A received RTSP message: either a response or interleaved data.
/// Requests a server sends to the client (RFC 2326 §10, e.g. an `OPTIONS`
/// keepalive) are not represented here; `RTSPParser.parse(_:)` skips them.
public enum RTSPMessage: Sendable {
  case response(RTSPResponse)
  case data(RTSPInterleavedData)
}

// MARK: - Header Access

extension RTSPResponse {
  /// Case-insensitive header lookup. Returns the first matching value.
  public func header(_ name: String) -> String? {
    let lowered = name.lowercased()
    return headers.first(where: { $0.0.lowercased() == lowered })?.1
  }

  /// Case-insensitive header lookup. Returns all matching values.
  public func headers(named name: String) -> [String] {
    let lowered = name.lowercased()
    return headers.filter { $0.0.lowercased() == lowered }.map(\.1)
  }

  /// `headers(named:)`, with each value marked as ISO Latin-1 when the parser
  /// decoded it that way (see `RTSPHeaderValue`).
  func headerValues(named name: String) -> [RTSPHeaderValue] {
    let lowered = name.lowercased()
    return headers.indices.compactMap { index -> RTSPHeaderValue? in
      let (headerName, value) = headers[index]
      guard headerName.lowercased() == lowered else { return nil }
      let isLatin1 =
        latin1HeaderIndices.contains(index)
        && value.unicodeScalars.allSatisfy { $0.value <= 0xFF }
      return RTSPHeaderValue(value, isLatin1: isLatin1)
    }
  }

  /// Parses the CSeq header value, trimming whitespace.
  public var cseq: UInt32? {
    guard let value = header("CSeq") else { return nil }
    return UInt32(value.trimmingCharacters(in: .whitespaces))
  }

  /// Parses the Content-Length header value.
  public var contentLength: Int? {
    guard let value = header("Content-Length") else { return nil }
    return Int(value.trimmingCharacters(in: .whitespaces))
  }

  /// The Content-Type header value, trimmed.
  public var contentType: String? {
    header("Content-Type")?.trimmingCharacters(in: .whitespaces)
  }
}

extension RTSPRequest {
  /// Case-insensitive header lookup.
  public func header(_ name: String) -> String? {
    let lowered = name.lowercased()
    return headers.first(where: { $0.0.lowercased() == lowered })?.1
  }

  /// Sets or replaces a header (case-insensitive match for replacement).
  public mutating func setHeader(_ name: String, value: String) {
    let lowered = name.lowercased()
    latin1HeaderNames.remove(lowered)
    if let idx = headers.firstIndex(where: { $0.0.lowercased() == lowered }) {
      headers[idx] = (name, value)
    } else {
      headers.append((name, value))
    }
  }

  /// Sets or replaces a header whose value may stand for ISO Latin-1 bytes
  /// (an `Authorization` answering a challenge the parser decoded as Latin-1):
  /// the serializer then writes those bytes rather than the UTF-8 encoding.
  mutating func setHeader(_ name: String, value: RTSPHeaderValue) {
    setHeader(name, value: value.text)
    if value.isLatin1 { latin1HeaderNames.insert(name.lowercased()) }
  }
}
