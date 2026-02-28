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
/// Requests are sent, not received, in client mode.
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
    if let idx = headers.firstIndex(where: { $0.0.lowercased() == lowered }) {
      headers[idx] = (name, value)
    } else {
      headers.append((name, value))
    }
  }
}
