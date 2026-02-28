// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Replaces upstream rtsp_types crate parsing + tokio.rs Codec

import Foundation

/// Parses RTSP messages from a byte buffer.
///
/// Handles both RTSP responses (status line + headers + optional body)
/// and interleaved data frames ('$' + channel + length + payload).
///
/// Mirrors the parsing logic in upstream tokio.rs Codec::parse_msg.
public struct RTSPParser: Sendable {
  public init() {}

  /// Attempts to parse one RTSP message from the given buffer.
  ///
  /// Returns the parsed message and the number of bytes consumed,
  /// or nil if the buffer doesn't contain a complete message yet.
  ///
  /// Throws on malformed data that can't be recovered from.
  public func parse(_ buffer: inout Data) throws -> (RTSPMessage, Int)? {
    // Skip leading CRLF pairs (same as upstream)
    while buffer.count >= 2 && buffer[buffer.startIndex] == 0x0D
      && buffer[buffer.startIndex + 1] == 0x0A
    {
      buffer.removeFirst(2)
    }

    guard !buffer.isEmpty else { return nil }

    // Interleaved data: '$' + channel_id + 2-byte BE length + data
    if buffer[buffer.startIndex] == 0x24 {  // '$'
      return try parseInterleavedData(&buffer)
    }

    // RTSP response
    return try parseResponse(&buffer)
  }

  /// Parse interleaved data frame.
  /// Format: '$' (1 byte) + channel_id (1 byte) + length (2 bytes BE) + data
  func parseInterleavedData(_ buffer: inout Data) throws -> (RTSPMessage, Int)? {
    guard buffer.count >= 4 else { return nil }

    let channelId = buffer[buffer.startIndex + 1]
    let length = Int(
      UInt16(buffer[buffer.startIndex + 2]) << 8
        | UInt16(buffer[buffer.startIndex + 3]))
    let totalLength = 4 + length

    guard buffer.count >= totalLength else { return nil }

    let payload = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + totalLength))
    buffer.removeFirst(totalLength)

    let msg = RTSPInterleavedData(channelId: channelId, data: payload)
    return (.data(msg), totalLength)
  }

  /// Parse an RTSP response message.
  ///
  /// Format:
  /// ```
  /// RTSP/1.0 <status-code> <reason>\r\n
  /// <header-name>: <header-value>\r\n
  /// ...
  /// \r\n
  /// [body]
  /// ```
  func parseResponse(_ buffer: inout Data) throws -> (RTSPMessage, Int)? {
    // Find the end of headers (double CRLF)
    guard let headerEndRange = findDoubleCRLF(in: buffer) else {
      return nil  // Need more data
    }

    let headerEnd = headerEndRange.upperBound
    let headerData = buffer[buffer.startIndex..<headerEndRange.lowerBound]

    guard let headerString = String(data: Data(headerData), encoding: .utf8) else {
      throw RTSPError.depacketizationError("Invalid UTF-8 in RTSP response headers")
    }

    var lines = headerString.split(
      separator: "\r\n", omittingEmptySubsequences: false
    ).map(String.init)

    guard !lines.isEmpty else {
      throw RTSPError.depacketizationError("Empty RTSP response")
    }

    // Parse status line: "RTSP/1.0 200 OK"
    let statusLine = lines.removeFirst()
    let (version, statusCode, reasonPhrase) = try parseStatusLine(statusLine)

    // Parse headers
    var headers: [(String, String)] = []
    for line in lines {
      if line.isEmpty { continue }
      if let colonIdx = line.firstIndex(of: ":") {
        let name = String(line[line.startIndex..<colonIdx])
        let valueStart = line.index(after: colonIdx)
        let value = String(line[valueStart...]).trimmingCharacters(
          in: CharacterSet(charactersIn: " \t"))
        headers.append((name, value))
      }
    }

    // Determine body length from Content-Length header
    var bodyLength = 0
    let contentLengthKey = headers.first(where: { $0.0.lowercased() == "content-length" })
    if let cl = contentLengthKey, let len = Int(cl.1.trimmingCharacters(in: .whitespaces)) {
      bodyLength = len
    }

    let totalLength = headerEnd - buffer.startIndex + bodyLength
    guard buffer.count >= totalLength else {
      return nil  // Need more data for body
    }

    var body = Data()
    if bodyLength > 0 {
      body = buffer.subdata(in: headerEnd..<(headerEnd + bodyLength))
    }

    buffer.removeFirst(totalLength)

    let response = RTSPResponse(
      statusCode: statusCode,
      reasonPhrase: reasonPhrase,
      version: version,
      headers: headers,
      body: body
    )
    return (.response(response), totalLength)
  }

  /// Parse "RTSP/1.0 200 OK" into components.
  func parseStatusLine(_ line: String) throws -> (String, UInt16, String) {
    // Split into at most 3 parts: version, status code, reason phrase
    let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count >= 2 else {
      throw RTSPError.depacketizationError("Invalid RTSP status line: \(line)")
    }

    let version = String(parts[0])
    guard let statusCode = UInt16(parts[1]) else {
      throw RTSPError.depacketizationError("Invalid status code in: \(line)")
    }
    let reasonPhrase = parts.count >= 3 ? String(parts[2]) : ""

    return (version, statusCode, reasonPhrase)
  }

  /// Find the position of "\r\n\r\n" in the data, returning the range of the double CRLF.
  /// The lowerBound is the start of the first \r\n, the upperBound is after the second \r\n.
  func findDoubleCRLF(in data: Data) -> Range<Int>? {
    let bytes = [UInt8](data)
    guard bytes.count >= 4 else { return nil }
    for i in 0...(bytes.count - 4) {
      if bytes[i] == 0x0D && bytes[i + 1] == 0x0A
        && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A
      {
        return (data.startIndex + i)..<(data.startIndex + i + 4)
      }
    }
    return nil
  }
}
