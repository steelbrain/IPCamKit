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
  public func serialize(_ request: RTSPRequest) -> Data {
    var result = "\(request.method.rawValue) \(request.url) \(request.version)\r\n"

    for (name, value) in request.headers {
      result += "\(name): \(value)\r\n"
    }

    if !request.body.isEmpty {
      // Add Content-Length if not already present
      let hasContentLength = request.headers.contains(where: {
        $0.0.lowercased() == "content-length"
      })
      if !hasContentLength {
        result += "Content-Length: \(request.body.count)\r\n"
      }
    }

    result += "\r\n"

    var data = Data(result.utf8)
    if !request.body.isEmpty {
      data.append(request.body)
    }

    return data
  }

  /// Serialize interleaved data for sending over TCP.
  ///
  /// Format: '$' + channel_id (1 byte) + length (2 bytes BE) + data
  public func serializeInterleaved(_ interleavedData: RTSPInterleavedData) -> Data {
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
