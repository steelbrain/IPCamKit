// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Replaces upstream rtsp_types crate parsing + tokio.rs Codec

import Foundation

/// The outcome of one `RTSPParser.parseNext(_:)` call.
enum RTSPParseResult: Sendable {
  /// A response or an interleaved data frame, removed from the buffer.
  case message(RTSPMessage)
  /// A request the server sent to the client (RFC 2326 §10, RFC 7826 §13),
  /// removed from the buffer. Answer it with
  /// `RTSPSerializer.serializeReply(to:)`.
  case serverRequest(RTSPServerRequest)
  /// The buffer doesn't hold a complete message yet. `totalBytes`, when known,
  /// is the `buffer.count` at which the next `parseNext` call can complete the
  /// message (the header block and the `Content-Length` body, or the whole
  /// interleaved frame); parsing before then only repeats work. nil means the
  /// header block itself is still incomplete: parse again after new data.
  case needMore(totalBytes: Int?)
}

/// A request sent by the server on the RTSP connection, e.g. an `OPTIONS` or
/// `GET_PARAMETER` keepalive probe, or an `ANNOUNCE`/`REDIRECT`.
struct RTSPServerRequest: Sendable {
  /// The method token as sent (e.g. `OPTIONS`, `REDIRECT`).
  var method: String
  /// The request URI (`*` or a URL).
  var uri: String
  /// The protocol version (e.g. `RTSP/1.0`).
  var version: String
  var headers: [(String, String)]
  var body: Data

  /// Case-insensitive header lookup. Returns the first matching value.
  func header(_ name: String) -> String? {
    let lowered = name.lowercased()
    return headers.first(where: { $0.0.lowercased() == lowered })?.1
  }

  /// The parsed `CSeq` header, if present and numeric.
  var cseq: UInt32? {
    guard let value = header("CSeq") else { return nil }
    return UInt32(value.trimmingCharacters(in: .whitespaces))
  }
}

/// Parses RTSP messages from a byte buffer.
///
/// Handles RTSP responses (status line + headers + optional body), requests
/// the server sends to the client, and interleaved data frames ('$' + channel
/// + length + payload).
///
/// Mirrors the parsing logic in upstream tokio.rs Codec::parse_msg.
public struct RTSPParser: Sendable {
  /// Maximum RTSP message body (`Content-Length`) we will accept. RTSP bodies —
  /// SDP, `GET_PARAMETER` lists — are KB-scale; this is generous headroom that
  /// still rejects a hostile/absurd `Content-Length` before any of it is
  /// buffered (memory-DoS guard). Kept below `RTSPTransportConnection`'s read
  /// buffer cap so a body this size still frames before the connection trips.
  static let maxBodyBytes = 2 * 1024 * 1024
  /// SP and HT, the blanks RTSP allows around a header field.
  private static let blanks = CharacterSet(charactersIn: " \t")

  /// Maximum size of a header block: the start line, the header lines and the
  /// blank line that ends them. Real RTSP headers are a few hundred bytes; a
  /// peer that sends more without a blank line is rejected rather than having
  /// the block rescanned on every read.
  static let maxHeaderBytes = 64 * 1024

  /// Maximum number of header lines (not counting the start line).
  static let maxHeaderLines = 256

  public init() {}

  /// Attempts to parse one RTSP message from the given buffer.
  ///
  /// Returns the parsed message and its length in bytes, or nil if the buffer
  /// doesn't contain a complete message yet. Requests sent by the server are
  /// consumed and skipped (`RTSPClientSession` answers them itself).
  ///
  /// Throws on malformed data that can't be recovered from.
  public func parse(_ buffer: inout Data) throws -> (RTSPMessage, Int)? {
    while true {
      let (result, length) = try parseFrame(&buffer)
      switch result {
      case .message(let message):
        return (message, length)
      case .serverRequest:
        continue
      case .needMore:
        return nil
      }
    }
  }

  /// Parses the next message from the front of `buffer`.
  ///
  /// On `.message` and `.serverRequest` the message's bytes are removed from
  /// `buffer`. On `.needMore` only leading CRLF pairs (padding between
  /// messages) may have been removed; `totalBytes` counts from the buffer as
  /// left by this call, and comparing it against the untrimmed buffer instead is
  /// also safe (it can only trigger an early re-parse).
  ///
  /// Each call does work proportional to the header block (at most
  /// `maxHeaderBytes`), not to the buffered body, so a caller should wait until
  /// `buffer.count >= totalBytes` before calling again; that keeps the total
  /// work for a message linear in its size.
  func parseNext(_ buffer: inout Data) throws -> RTSPParseResult {
    try parseFrame(&buffer).0
  }

  /// `parseNext` plus the length of the message it removed (0 on `.needMore`).
  private func parseFrame(_ buffer: inout Data) throws -> (RTSPParseResult, Int) {
    // Skip leading CRLF pairs (same as upstream)
    while buffer.count >= 2 && buffer[buffer.startIndex] == 0x0D
      && buffer[buffer.startIndex + 1] == 0x0A
    {
      buffer.removeFirst(2)
    }

    guard !buffer.isEmpty else { return (.needMore(totalBytes: nil), 0) }

    // Interleaved data: '$' + channel_id + 2-byte BE length + data
    if buffer[buffer.startIndex] == 0x24 {  // '$'
      return parseInterleavedData(&buffer)
    }

    return try parseTextMessage(&buffer)
  }

  /// Parse interleaved data frame.
  /// Format: '$' (1 byte) + channel_id (1 byte) + length (2 bytes BE) + data
  private func parseInterleavedData(_ buffer: inout Data) -> (RTSPParseResult, Int) {
    guard buffer.count >= 4 else { return (.needMore(totalBytes: 4), 0) }

    let channelId = buffer[buffer.startIndex + 1]
    let length = Int(
      UInt16(buffer[buffer.startIndex + 2]) << 8
        | UInt16(buffer[buffer.startIndex + 3]))
    let totalLength = 4 + length

    guard buffer.count >= totalLength else { return (.needMore(totalBytes: totalLength), 0) }

    let payload = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + totalLength))
    buffer.removeFirst(totalLength)

    let msg = RTSPInterleavedData(channelId: channelId, data: payload)
    return (.message(.data(msg)), totalLength)
  }

  /// Parse an RTSP response or a request from the server.
  ///
  /// Format:
  /// ```
  /// RTSP/1.0 <status-code> <reason>\r\n      (or: <METHOD> <uri> RTSP/1.0\r\n)
  /// <header-name>: <header-value>\r\n
  /// ...
  /// \r\n
  /// [body]
  /// ```
  ///
  /// The header block is framed and checked at the byte level first, and only
  /// decoded into strings once the whole message (body included) is buffered,
  /// so a call that has to wait for the body stays cheap.
  private func parseTextMessage(_ buffer: inout Data) throws -> (RTSPParseResult, Int) {
    let headerEndRange: Range<Int>
    switch scanForBlankLine(
      in: buffer, limit: Self.maxHeaderBytes, maxLineFeeds: Self.maxHeaderLines + 1)
    {
    case .found(let range):
      headerEndRange = range
    case .tooManyLines:
      throw RTSPError.depacketizationError(
        "RTSP message has more than \(Self.maxHeaderLines) header lines")
    case .notFound:
      if buffer.count >= Self.maxHeaderBytes {
        throw RTSPError.depacketizationError(
          "RTSP header block exceeds \(Self.maxHeaderBytes) bytes")
      }
      return (.needMore(totalBytes: nil), 0)  // Need more data
    }

    let headerBytes = headerEndRange.upperBound - buffer.startIndex
    guard let lines = headerLineRanges(in: buffer, end: headerEndRange.lowerBound) else {
      throw RTSPError.depacketizationError(
        "RTSP message has more than \(Self.maxHeaderLines) header lines")
    }

    // Determine body length from Content-Length header. The value is
    // attacker-controlled, so reject negatives outright.
    var bodyLength = 0
    if let raw = contentLengthValue(in: buffer, lines: lines.dropFirst()) {
      guard let len = Int(raw.trimmingCharacters(in: .whitespaces)), len >= 0 else {
        throw RTSPError.depacketizationError("Invalid Content-Length: \(cutForMessage(raw))")
      }
      // Reject an absurd declared body up front so we never try to buffer it.
      guard len <= Self.maxBodyBytes else {
        throw RTSPError.depacketizationError(
          "Content-Length too large: \(len) (max \(Self.maxBodyBytes))")
      }
      bodyLength = len
    }

    // Both terms are capped (maxHeaderBytes, maxBodyBytes), so this can't overflow.
    let totalLength = headerBytes + bodyLength
    guard buffer.count >= totalLength else {
      return (.needMore(totalBytes: totalLength), 0)  // Need more data for body
    }

    // A control byte in the start line leaves the message unidentifiable.
    if containsControlByte(buffer, in: lines[0]) {
      throw RTSPError.depacketizationError("Control character in RTSP start line")
    }
    let startLine = decodeLine(buffer[lines[0]])
    var headers: [(String, String)] = []
    var latin1HeaderIndices = Set<Int>()
    for field in try headerFields(in: buffer, lines: lines.dropFirst()) {
      let (value, isLatin1) = decodeValue(buffer, field.valueRanges)
      if isLatin1 { latin1HeaderIndices.insert(headers.count) }
      headers.append((field.name, value))
    }

    let requestLine = parseRequestLine(startLine)
    let statusLine = requestLine == nil ? try parseStatusLine(startLine) : nil

    let bodyStart = headerEndRange.upperBound
    let body = bodyLength > 0 ? buffer.subdata(in: bodyStart..<(bodyStart + bodyLength)) : Data()
    buffer.removeFirst(totalLength)

    if let (method, uri, version) = requestLine {
      let request = RTSPServerRequest(
        method: method, uri: uri, version: version, headers: headers, body: body)
      return (.serverRequest(request), totalLength)
    }
    guard let (version, statusCode, reasonPhrase) = statusLine else {
      throw RTSPError.depacketizationError("Invalid RTSP status line: \(cutForMessage(startLine))")
    }
    var response = RTSPResponse(
      statusCode: statusCode,
      reasonPhrase: reasonPhrase,
      version: version,
      headers: headers,
      body: body
    )
    response.latin1HeaderIndices = latin1HeaderIndices
    return (.message(.response(response)), totalLength)
  }

  /// Split the header block `buffer[startIndex..<end]` into line ranges (the
  /// start line first), each without its LF or CRLF terminator. Returns nil for
  /// a block with more than `maxHeaderLines` header lines. Uses `memchr`, so
  /// the cost is per line rather than per byte.
  private func headerLineRanges(in buffer: Data, end: Int) -> [Range<Int>]? {
    let start = buffer.startIndex
    return buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Range<Int>]? in
      guard let base = raw.baseAddress else { return [start..<start] }
      let n = end - start
      var ranges: [Range<Int>] = []
      var lineStart = 0
      while true {
        var lineFeed = n
        if lineStart < n, let hit = memchr(base + lineStart, 0x0A, n - lineStart) {
          lineFeed = base.distance(to: UnsafeRawPointer(hit))
        }
        // Drop the CR of a CRLF (and any extra CRs before it: "\r\r\n" from a
        // sloppy server can't inject anything, as the line ends there anyway).
        var lineEnd = lineFeed
        while lineEnd > lineStart && raw[lineEnd - 1] == 0x0D { lineEnd -= 1 }
        ranges.append((start + lineStart)..<(start + lineEnd))
        if ranges.count > Self.maxHeaderLines + 1 { return nil }
        if lineFeed >= n { return ranges }
        lineStart = lineFeed + 1
      }
    }
  }

  /// Whether the header line at `range` starts with SP or HT, which makes it a
  /// continuation of the previous header's value (RFC 2326 inherits line
  /// folding from RFC 2068 section 2.2).
  private func isContinuationLine(_ buffer: Data, _ range: Range<Int>) -> Bool {
    guard let first = buffer[range].first else { return false }
    return first == 0x20 || first == 0x09
  }

  /// `value` with a continuation line joined on: trimmed, after one space. A
  /// continuation holding only blanks adds nothing.
  private func joinContinuation(_ value: String, _ line: String) -> String {
    let continuation = line.trimmingCharacters(in: .whitespaces)
    if continuation.isEmpty { return value }
    return value.isEmpty ? continuation : value + " " + continuation
  }

  /// Whether `byte` is a control byte: below 0x20 other than HTAB, or DEL.
  private static func isControlByte(_ byte: UInt8) -> Bool {
    (byte < 0x20 && byte != 0x09) || byte == 0x7F
  }

  /// Whether the line at `range` holds a control byte.
  private func containsControlByte(_ buffer: Data, in range: Range<Int>) -> Bool {
    buffer[range].contains(where: Self.isControlByte)
  }

  /// One header field: its name, and the byte ranges of its value (the rest of
  /// its first line after the colon, then each continuation line).
  private struct HeaderField {
    var name: String
    var valueRanges: [Range<Int>]
  }

  /// Group the header lines into fields. A line starting with SP or HT
  /// continues the field before it; one that follows the start line or a
  /// dropped line is dropped too, as is a line without a colon.
  ///
  /// A field with a control byte (below 0x20 other than HT, or DEL) on any of
  /// its lines is dropped, so junk such as a NUL in a header the client never
  /// reads doesn't cost the response, and the value is never echoed into a
  /// later request. The response is rejected instead where dropping could
  /// change how it is framed, as a laxer parser could read such a line
  /// differently:
  /// - a bare CR (one that doesn't end the line) anywhere: other parsers break
  ///   lines there, so the line could hold other fields, a `Content-Length`,
  ///   or the blank line that ends the header block;
  /// - a control byte before the colon, or on a line without one that isn't a
  ///   folded continuation line: the field can't be identified, and may be a
  ///   `Content-Length` (a continuation line, starting with a space or tab,
  ///   belongs to the previous field, which a control byte drops);
  /// - a control byte in a `Content-Length` field, which frames the body.
  private func headerFields(
    in buffer: Data, lines: ArraySlice<Range<Int>>
  ) throws -> [HeaderField] {
    let start = buffer.startIndex
    var kept: [(nameRange: Range<Int>, valueRanges: [Range<Int>], hasControlByte: Bool)] = []
    // Whether the last line that wasn't a continuation started a field.
    var lastLineIsField = false
    try buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> Void in
      for range in lines {
        let lower = range.lowerBound - start
        let upper = range.upperBound - start
        var colon: Int?
        var control: Int?
        for i in lower..<upper {
          let byte = raw[i]
          if byte == 0x3A && colon == nil { colon = i }
          guard Self.isControlByte(byte) else { continue }
          // The CRs ending a line aren't part of its range, so this one is bare.
          if byte == 0x0D {
            throw RTSPError.depacketizationError("Bare CR in an RTSP header line")
          }
          if control == nil { control = i }
        }
        if lower < upper && (raw[lower] == 0x20 || raw[lower] == 0x09) {
          if lastLineIsField {
            kept[kept.count - 1].valueRanges.append(range)
            if control != nil { kept[kept.count - 1].hasControlByte = true }
          }
          continue
        }
        lastLineIsField = false
        guard let colon else {
          if control != nil {
            throw RTSPError.depacketizationError(
              "Control character in an RTSP header line without a colon")
          }
          continue
        }
        if let control, control < colon {
          throw RTSPError.depacketizationError("Control character in an RTSP header name")
        }
        kept.append(
          (
            nameRange: range.lowerBound..<(start + colon),
            valueRanges: [(start + colon + 1)..<range.upperBound],
            hasControlByte: control != nil
          ))
        lastLineIsField = true
      }
    }
    var fields: [HeaderField] = []
    fields.reserveCapacity(kept.count)
    for field in kept {
      // Trim the field name as well as the value: some cameras emit
      // "CSeq : 1" with space before the colon. Lookups lowercase the name
      // but don't trim, so an untrimmed "CSeq " would never match "cseq" and
      // CSeq-based response routing would silently break. Only SP and HT, as
      // `contentLengthValue` skips: a name the framing doesn't take for
      // `Content-Length` mustn't read as one.
      let name = decodeLine(buffer[field.nameRange]).trimmingCharacters(in: Self.blanks)
      if field.hasControlByte {
        if name.lowercased() == "content-length" {
          throw RTSPError.depacketizationError("Control character in RTSP Content-Length")
        }
        continue
      }
      fields.append(HeaderField(name: name, valueRanges: field.valueRanges))
    }
    return fields
  }

  /// A field's value: its pieces (see `HeaderField`) trimmed and joined with
  /// one space, a piece holding only blanks adding nothing. Decoded as UTF-8,
  /// or, if any piece isn't valid UTF-8, all as ISO Latin-1 (`isLatin1`), so
  /// the value maps back to the bytes received with one charset. A Latin-1
  /// value is trimmed of SP and HT only, as U+00A0 there is a byte of the
  /// legacy encoding rather than a space.
  private func decodeValue(_ buffer: Data, _ ranges: [Range<Int>]) -> (String, isLatin1: Bool) {
    var utf8Pieces: [String] = []
    utf8Pieces.reserveCapacity(ranges.count)
    for range in ranges {
      guard let piece = String(data: buffer[range], encoding: .utf8) else {
        utf8Pieces.removeAll()
        break
      }
      utf8Pieces.append(piece)
    }
    if utf8Pieces.count == ranges.count {
      var value = ""
      for piece in utf8Pieces { value = joinContinuation(value, piece) }
      return (value, false)
    }
    var value = ""
    for range in ranges {
      var lower = range.lowerBound
      var upper = range.upperBound
      while lower < upper && (buffer[lower] == 0x20 || buffer[lower] == 0x09) { lower += 1 }
      while upper > lower && (buffer[upper - 1] == 0x20 || buffer[upper - 1] == 0x09) {
        upper -= 1
      }
      guard lower < upper else { continue }
      if !value.isEmpty { value += " " }
      value += RTSPHeaderValue.latin1Text(buffer[lower..<upper])
    }
    return (value, true)
  }

  /// The value of the first `Content-Length` header line, if any, with the
  /// continuation lines that follow it joined on as the header list does.
  /// Matches the field name on bytes (case-insensitive, blanks before the colon
  /// ignored) so the other lines needn't be decoded while the body is still
  /// arriving. A line starting with SP or HT continues the previous header, so
  /// it never counts as a `Content-Length` line itself.
  private func contentLengthValue(in buffer: Data, lines: ArraySlice<Range<Int>>) -> String? {
    let target = Array("content-length".utf8)
    let start = buffer.startIndex
    let match = buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (Int, Range<Int>)? in
      for index in lines.indices {
        let range = lines[index]
        var i = range.lowerBound - start
        let end = range.upperBound - start
        guard end - i > target.count, raw[i] != 0x20, raw[i] != 0x09 else { continue }
        var matches = true
        for expected in target {
          var byte = raw[i]
          if byte >= 0x41 && byte <= 0x5A { byte += 0x20 }  // ASCII lowercase
          if byte != expected {
            matches = false
            break
          }
          i += 1
        }
        guard matches else { continue }
        while i < end && (raw[i] == 0x20 || raw[i] == 0x09) { i += 1 }
        guard i < end, raw[i] == 0x3A else { continue }  // ':'
        return (index, (start + i + 1)..<range.upperBound)
      }
      return nil
    }
    guard let (index, valueRange) = match else { return nil }
    var value = decodeLine(buffer[valueRange]).trimmingCharacters(in: .whitespaces)
    for range in lines[(index + 1)...] {
      guard isContinuationLine(buffer, range) else { break }
      value = joinContinuation(value, decodeLine(buffer[range]))
    }
    return value
  }

  /// Decode one header-block line: UTF-8, or ISO Latin-1 for the odd camera
  /// that sends another legacy encoding (GBK, Shift-JIS) in a reason phrase or
  /// a `Server` value. Latin-1 maps every byte, so this never fails.
  private func decodeLine(_ bytes: Data) -> String {
    String(data: bytes, encoding: .utf8) ?? RTSPHeaderValue.latin1Text(bytes)
  }

  /// Recognize a request line ("OPTIONS * RTSP/1.0"): three fields, the last
  /// an RTSP version and the first a method token. Returns nil for anything
  /// else, which is then parsed as a status line.
  private func parseRequestLine(_ line: String) -> (String, String, String)? {
    let parts = line.split(
      omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
    guard parts.count == 3, parts[2].hasPrefix("RTSP/"), !parts[0].hasPrefix("RTSP/"),
      parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
    else { return nil }
    return (String(parts[0]), String(parts[1]), String(parts[2]))
  }

  /// Parse "RTSP/1.0 200 OK" into components.
  func parseStatusLine(_ line: String) throws -> (String, UInt16, String) {
    // Split into at most 3 parts: version, status code, reason phrase.
    // Separate on runs of spaces/tabs so a doubled space ("RTSP/1.0  200 OK")
    // or the odd tab-delimited camera still reads the code from the right field.
    let parts = line.split(
      maxSplits: 2, omittingEmptySubsequences: true,
      whereSeparator: { $0 == " " || $0 == "\t" })
    guard parts.count >= 2 else {
      throw RTSPError.depacketizationError("Invalid RTSP status line: \(cutForMessage(line))")
    }

    let version = String(parts[0])
    // Read the leading ASCII digits of the code field so trailing junk on the
    // status code doesn't abort an otherwise usable connection.
    let digits = parts[1].prefix(while: { $0.isASCII && $0.isNumber })
    guard let statusCode = UInt16(digits) else {
      throw RTSPError.depacketizationError("Invalid status code in: \(cutForMessage(line))")
    }
    let reasonPhrase = parts.count >= 3 ? String(parts[2]) : ""

    return (version, statusCode, reasonPhrase)
  }

  /// Find the header/body boundary (the blank line) and return its byte range:
  /// `lowerBound` is the start of the terminating line break, `upperBound` the
  /// first body byte. Recognizes `\r\n\r\n` (per RFC) and, for sloppy cameras,
  /// any line feed followed by CRs and a line feed (`\n\n`, `\r\r\n\r\r\n`,
  /// `\n\r\n`): lines may end in LF, CRLF or extra CRs before the LF, and a
  /// line holding only CRs is blank. Only a boundary that ends within the first
  /// `limit` bytes is found. Scans the `Data` in place (no copy), jumping
  /// between line feeds with `memchr`. Each call rescans from the start, so
  /// callers bound how often they call it (the parser caps the scan at
  /// `maxHeaderBytes`).
  func findDoubleCRLF(in data: Data, limit: Int = .max) -> Range<Int>? {
    guard case .found(let range) = scanForBlankLine(in: data, limit: limit, maxLineFeeds: .max)
    else { return nil }
    return range
  }

  enum BlankLineScan {
    case found(Range<Int>)
    case notFound
    /// More than `maxLineFeeds` line feeds came before any blank line.
    case tooManyLines
  }

  /// `findDoubleCRLF`, also giving up after `maxLineFeeds` line feeds that don't
  /// start a blank line, so a block of many short lines costs no more to rescan
  /// than one that is rejected for its line count anyway.
  func scanForBlankLine(in data: Data, limit: Int, maxLineFeeds: Int) -> BlankLineScan {
    let start = data.startIndex
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> BlankLineScan in
      let n = min(raw.count, limit)
      guard n >= 2, let base = raw.baseAddress else { return .notFound }
      var from = 0
      var lineFeeds = 0
      while from < n, let hit = memchr(base + from, 0x0A, n - from) {
        // The line feed at `p` ends a line; the next line is blank if it holds
        // only CRs before its own line feed. The boundary starts at the CRs
        // before `p`. Taking the first such line feed keeps the earliest
        // boundary, as a byte-by-byte scan would.
        let p = base.distance(to: UnsafeRawPointer(hit))
        var next = p + 1
        // Skip a run of CRs 8 bytes at a time: a rescan of a long run would
        // otherwise cost far more than memchr over ordinary text.
        while next + 8 <= n
          && raw.loadUnaligned(fromByteOffset: next, as: UInt64.self) == 0x0D0D_0D0D_0D0D_0D0D
        {
          next += 8
        }
        while next < n && raw[next] == 0x0D { next += 1 }
        if next < n && raw[next] == 0x0A {
          var lower = p
          while lower > 0 && raw[lower - 1] == 0x0D { lower -= 1 }
          return .found((start + lower)..<(start + next + 1))
        }
        lineFeeds += 1
        if lineFeeds > maxLineFeeds { return .tooManyLines }
        from = p + 1
      }
      return .notFound
    }
  }
}
