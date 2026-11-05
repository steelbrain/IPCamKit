// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Gzip (RFC 1952) decoder for ONVIF compressed metadata (vnd.onvif.metadata.gzip).

import Compression
import Foundation

/// Errors thrown by ``Gzip/decompress(_:maxOutputBytes:)``.
enum GzipError: Error, Sendable, Equatable, CustomStringConvertible {
  /// The input ended before a complete member (header, deflate body or trailer).
  case truncated
  /// A member does not start with the gzip magic bytes `1f 8b`.
  case badMagic
  /// The compression method (CM) is not 8 (deflate).
  case unsupportedMethod(UInt8)
  /// One of the reserved FLG bits 5-7 is set (RFC 1952 section 2.3.1.2 requires an error).
  case reservedFlags(UInt8)
  /// The FHCRC header checksum does not match the header bytes.
  case headerChecksumMismatch
  /// The deflate body is malformed or cut short (the Compression framework reports both
  /// the same way).
  case corruptData
  /// The trailer CRC-32 does not match the decompressed member.
  case checksumMismatch
  /// The trailer ISIZE does not match the decompressed member length (mod 2^32).
  case sizeMismatch
  /// The decompressed output would exceed the caller's limit (in bytes).
  case outputLimitExceeded(Int)
  /// Bytes after the last member that are neither zero padding nor another member.
  case trailingGarbage
  /// The stream has more members than ``Gzip/maxMembers``.
  case tooManyMembers(Int)
  /// The Compression framework failed to set up a decoder.
  case decoderUnavailable

  var description: String {
    switch self {
    case .truncated: return "gzip: unexpected end of input"
    case .badMagic: return "gzip: bad magic bytes"
    case .unsupportedMethod(let cm): return "gzip: unsupported compression method \(cm)"
    case .reservedFlags(let flg): return "gzip: reserved header flags set (FLG=\(flg))"
    case .headerChecksumMismatch: return "gzip: header CRC16 mismatch"
    case .corruptData: return "gzip: corrupt or truncated deflate data"
    case .checksumMismatch: return "gzip: CRC-32 mismatch"
    case .sizeMismatch: return "gzip: ISIZE mismatch"
    case .outputLimitExceeded(let limit):
      return "gzip: decompressed output exceeds \(limit) bytes"
    case .trailingGarbage: return "gzip: trailing garbage after last member"
    case .tooManyMembers(let max): return "gzip: more than \(max) members"
    case .decoderUnavailable: return "gzip: failed to initialize the deflate decoder"
    }
  }
}

/// Gzip (RFC 1952) decoder, used for ONVIF `vnd.onvif.metadata.gzip` payloads.
///
/// Each member header is parsed and validated (including the optional FHCRC), the raw
/// DEFLATE (RFC 1951) body is inflated with Apple's Compression framework, and the CRC-32
/// and ISIZE trailer are verified. Malformed input throws ``GzipError``; it never traps.
enum Gzip {
  private static let flagHeaderCRC: UInt8 = 0x02
  private static let flagExtra: UInt8 = 0x04
  private static let flagName: UInt8 = 0x08
  private static let flagComment: UInt8 = 0x10
  private static let flagReserved: UInt8 = 0xE0

  /// Most members accepted in one stream. A well-formed member costs two or three decoder
  /// setups (tens of microseconds), a hostile one that defeats the trailer check up to about
  /// 25 (a binary search for its end), so this bounds the work a stream of tiny hostile
  /// members can cause; ONVIF metadata documents are a single member.
  static let maxMembers = 1024

  /// Size of the scratch buffer the inflater writes into per step.
  private static let chunkSize = 64 * 1024

  /// Decompress a gzip (RFC 1952) byte stream; concatenated members are joined.
  ///
  /// - Parameters:
  ///   - data: The gzip stream. May be a slice with a nonzero `startIndex`.
  ///   - maxOutputBytes: Upper bound on the total decompressed size (decompression-bomb
  ///     guard). Inflation stops and throws ``GzipError/outputLimitExceeded(_:)`` as soon as
  ///     the output would exceed it; memory is never reserved for a size the input claims.
  ///     Negative values are treated as zero.
  /// - Returns: The decompressed bytes of all members, concatenated.
  /// - Throws: ``GzipError`` for malformed, truncated or oversized input, or more than
  ///   ``maxMembers`` members. Zero bytes after the last member are accepted as padding; any
  ///   other trailing bytes throw.
  static func decompress(_ data: Data, maxOutputBytes: Int = 16 * 1024 * 1024) throws -> Data {
    let limit = max(0, maxOutputBytes)
    return try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Data in
      var output = Data()
      var offset = 0
      var members = 0
      repeat {
        members += 1
        guard members <= maxMembers else { throw GzipError.tooManyMembers(maxMembers) }
        offset = try decodeMember(input, at: offset, into: &output, limit: limit)
      } while try hasAnotherMember(input, at: offset)
      return output
    }
  }

  /// Whether another member starts at `offset`. Throws if the remaining bytes are neither a
  /// member nor all-zero padding.
  private static func hasAnotherMember(
    _ input: UnsafeRawBufferPointer, at offset: Int
  ) throws -> Bool {
    let rest = UnsafeRawBufferPointer(rebasing: input[offset...])
    if rest.isEmpty { return false }
    if rest.count >= 2 && rest[0] == 0x1F && rest[1] == 0x8B { return true }
    guard rest.allSatisfy({ $0 == 0 }) else { throw GzipError.trailingGarbage }
    return false
  }

  /// Decodes one member starting at `start`, appending its output. Returns the offset just
  /// past the member's trailer.
  private static func decodeMember(
    _ input: UnsafeRawBufferPointer, at start: Int, into output: inout Data, limit: Int
  ) throws -> Int {
    var reader = ByteReader(bytes: input, offset: start)
    guard try reader.byte() == 0x1F, try reader.byte() == 0x8B else {
      throw GzipError.badMagic
    }
    let method = try reader.byte()
    guard method == 8 else { throw GzipError.unsupportedMethod(method) }
    let flags = try reader.byte()
    guard flags & flagReserved == 0 else { throw GzipError.reservedFlags(flags) }
    try reader.skip(6)  // MTIME (4), XFL (1), OS (1)
    if flags & flagExtra != 0 {
      let extraLength = Int(try reader.uint16LE())
      try reader.skip(extraLength)
    }
    if flags & flagName != 0 { try reader.skipZeroTerminated() }
    if flags & flagComment != 0 { try reader.skipZeroTerminated() }
    if flags & flagHeaderCRC != 0 {
      let headerCRC = crc32(UnsafeRawBufferPointer(rebasing: input[start..<reader.offset]))
      let expected = try reader.uint16LE()
      guard expected == UInt16(truncatingIfNeeded: headerCRC) else {
        throw GzipError.headerChecksumMismatch
      }
    }

    let body = UnsafeRawBufferPointer(rebasing: input[reader.offset...])
    let member = try inflateMember(body, budget: limit - output.count, limit: limit)
    try reader.skip(member.deflateLength)

    let expectedCRC = try reader.uint32LE()
    let expectedSize = try reader.uint32LE()
    guard member.crc == expectedCRC else { throw GzipError.checksumMismatch }
    guard UInt32(truncatingIfNeeded: member.output.count) == expectedSize else {
      throw GzipError.sizeMismatch
    }
    output.append(member.output)
    return reader.offset
  }

  /// Inflates the raw DEFLATE stream at the start of `body` and finds where it ends.
  ///
  /// The Compression framework reads input in blocks of up to 64 KiB, so `src_size` after
  /// `COMPRESSION_STATUS_END` does not say where the deflate stream stopped, and without
  /// `COMPRESSION_STREAM_FINALIZE` it can stall short of the end of a complete stream.
  /// The stream's length is therefore found by probing with FINALIZE: a prefix of `body`
  /// inflates completely if and only if it contains the whole stream (shorter prefixes are
  /// truncated streams; longer ones only add ignored bytes), so the length is the shortest
  /// prefix that inflates. The gzip trailer (CRC-32, ISIZE of the output) sits right after
  /// it, which pins that prefix down in two or three probes for well-formed input; a
  /// damaged or ambiguous trailer falls back to a binary search.
  private static func inflateMember(
    _ body: UnsafeRawBufferPointer, budget: Int, limit: Int
  ) throws -> (output: Data, crc: UInt32, deflateLength: Int) {
    guard !body.isEmpty else { throw GzipError.truncated }
    func inflatesCompletely(_ length: Int) throws -> Data? {
      try inflateComplete(
        UnsafeRawBufferPointer(rebasing: body[..<length]), budget: budget, limit: limit)
    }

    // Invariant: the prefix of length `failing` does not inflate completely; `length` does.
    var failing = 0
    var length = body.count
    let output: Data
    if body.count > 8, let complete = try inflatesCompletely(body.count - 8) {
      // Usual case: the member ends the input, so its trailer is the last eight bytes.
      output = complete
      length = body.count - 8
    } else if let complete = try inflatesCompletely(body.count) {
      output = complete
      failing = max(0, body.count - 8)
    } else {
      throw GzipError.corruptData
    }
    let crc = crc32(output)

    // The trailer that must follow the stream, if the member is intact.
    var trailer = [UInt8](repeating: 0, count: 8)
    let size = UInt32(truncatingIfNeeded: output.count)
    for i in 0..<4 {
      trailer[i] = UInt8(truncatingIfNeeded: crc >> (8 * i))
      trailer[4 + i] = UInt8(truncatingIfNeeded: size >> (8 * i))
    }
    var candidatesTried = 0
    var position = failing + 1
    let lastPosition = min(length, body.count - trailer.count)
    while position <= lastPosition && candidatesTried < maxTrailerCandidates {
      defer { position += 1 }
      guard trailer.indices.allSatisfy({ body[position + $0] == trailer[$0] }) else {
        continue
      }
      candidatesTried += 1
      if position < length, try inflatesCompletely(position) == nil {
        failing = position
      } else if position - 1 > failing, try inflatesCompletely(position - 1) != nil {
        length = position - 1
        break  // The stream ends before this point; no later candidate can be the end.
      } else {
        return (output, crc, position)
      }
    }

    while length - failing > 1 {
      let middle = failing + (length - failing) / 2
      if try inflatesCompletely(middle) != nil {
        length = middle
      } else {
        failing = middle
      }
    }
    return (output, crc, length)
  }

  /// Most trailer look-alikes checked before falling back to a binary search, which bounds
  /// the work hostile input can cause by planting fake trailers in the deflate data.
  private static let maxTrailerCandidates = 4

  /// Inflates `input` with `COMPRESSION_STREAM_FINALIZE`. Returns the output if `input`
  /// starts with a complete raw DEFLATE stream (bytes after its end are ignored), or nil if
  /// the stream is truncated or corrupt.
  ///
  /// - Throws: ``GzipError/outputLimitExceeded(_:)`` (reporting `limit`) as soon as the
  ///   output would exceed `budget` bytes.
  private static func inflateComplete(
    _ input: UnsafeRawBufferPointer, budget: Int, limit: Int
  ) throws -> Data? {
    guard let base = input.baseAddress, !input.isEmpty else { return nil }

    let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    defer { stream.deallocate() }
    // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), without a zlib or gzip wrapper.
    guard
      compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        == COMPRESSION_STATUS_OK
    else { throw GzipError.decoderUnavailable }
    defer { compression_stream_destroy(stream) }

    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
    defer { buffer.deallocate() }

    stream.pointee.src_ptr = base.assumingMemoryBound(to: UInt8.self)
    stream.pointee.src_size = input.count
    let finalize = Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue)
    var output = Data()
    while true {
      // Offer at most one byte beyond the budget, so overshooting is detected without ever
      // holding more than the budget.
      let room = budget - output.count
      let offered = room < chunkSize ? room + 1 : chunkSize
      stream.pointee.dst_ptr = buffer
      stream.pointee.dst_size = offered
      let inputBefore = stream.pointee.src_size
      let status = compression_stream_process(stream, finalize)
      let produced = offered - stream.pointee.dst_size
      if produced > 0 {
        guard produced <= room else { throw GzipError.outputLimitExceeded(limit) }
        output.append(buffer, count: produced)
      }
      switch status {
      case COMPRESSION_STATUS_END:
        return output
      case COMPRESSION_STATUS_OK:
        // Calling again without any progress would loop forever.
        if produced == 0 && stream.pointee.src_size == inputBefore { return nil }
      default:
        return nil
      }
    }
  }

  // MARK: - CRC-32

  /// CRC-32 lookup table for the reflected polynomial 0xEDB88320 (ISO 3309, as in gzip).
  private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
    var c = UInt32(n)
    for _ in 0..<8 {
      c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
    }
    return c
  }

  /// CRC-32 as used by gzip and zlib. Pass a previous result as `initial` to continue it.
  static func crc32(_ bytes: UnsafeRawBufferPointer, initial: UInt32 = 0) -> UInt32 {
    crcTable.withUnsafeBufferPointer { table in
      var c = ~initial
      for byte in bytes {
        c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
      }
      return ~c
    }
  }

  /// CRC-32 of `data` (which may be a slice).
  static func crc32(_ data: Data, initial: UInt32 = 0) -> UInt32 {
    data.withUnsafeBytes { crc32($0, initial: initial) }
  }
}

/// Bounds-checked little-endian reader over a byte buffer; reads past the end throw
/// ``GzipError/truncated``.
private struct ByteReader {
  let bytes: UnsafeRawBufferPointer
  var offset: Int

  var remaining: Int { bytes.count - offset }

  mutating func byte() throws -> UInt8 {
    guard remaining >= 1 else { throw GzipError.truncated }
    defer { offset += 1 }
    return bytes[offset]
  }

  mutating func uint16LE() throws -> UInt16 {
    let low = try byte()
    let high = try byte()
    return UInt16(low) | UInt16(high) << 8
  }

  mutating func uint32LE() throws -> UInt32 {
    let low = try uint16LE()
    let high = try uint16LE()
    return UInt32(low) | UInt32(high) << 16
  }

  mutating func skip(_ count: Int) throws {
    guard count >= 0, count <= remaining else { throw GzipError.truncated }
    offset += count
  }

  /// Skips a zero-terminated string (FNAME / FCOMMENT), including the terminator.
  mutating func skipZeroTerminated() throws {
    while try byte() != 0 {}
  }
}
