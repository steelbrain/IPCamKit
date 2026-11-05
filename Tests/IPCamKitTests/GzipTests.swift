// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Tests for the gzip (RFC 1952) decoder used for ONVIF compressed metadata.

import Foundation
import Testing

@testable import IPCamKit

// MARK: - Vectors

// All vectors were produced by CPython's gzip/zlib modules or /usr/bin/gzip, not by the
// decoder under test. Members with FEXTRA/FCOMMENT/FHCRC were assembled by hand around a
// zlib raw-deflate body, with CRC16 = low 16 bits of zlib.crc32(header).

/// gzip.compress(b"Hello, ONVIF metadata!\n", mtime=0)
private let plainVector = "H4sIAAAAAAAA//NIzcnJ11Hw9wvzdFPITS1JTEksSVTkAgBR8ZhrFwAAAA=="
private let plainText = "Hello, ONVIF metadata!\n"

/// gzip.compress(b"", mtime=0)
private let emptyVector = "H4sIAAAAAAAA/wMAAAAAAAAAAAA="

/// GzipFile(filename="metadata.xml") over "<tt:MetadataStream/>\n" (FNAME set).
private let pythonNameVector =
  "H4sICADxU2UA/21ldGFkYXRhLnhtbACzKSmx8k0tSUxJLEkMLilKTczVt+MCALhkr/gVAAAA"

/// `/usr/bin/gzip -k metadata.xml` over the same content (FNAME set, real mtime).
private let gzipToolVector =
  "H4sICAXd6moAA21ldGFkYXRhLnhtbACzKSmx8k0tSUxJLEkMLilKTczVt+MCALhkr/gVAAAA"
private let nameVectorText = "<tt:MetadataStream/>\n"

/// FLG = FTEXT|FHCRC|FEXTRA|FNAME|FCOMMENT, extra "AP\x04\x00abcd", name "name.txt",
/// comment "a comment".
private let allFlagsVector =
  "H4sIH3hWNBIAAwgAQVAEAGFiY2RuYW1lLnR4dABhIGNvbW1lbnQAQFtzzMlRyC8oyczPS8xRyEhNTEktUkjLTM1J"
  + "KVZILEpVKChKLU7NK9HjAgByPGVHKAAAAA=="
private let allFlagsText = "All optional header fields are present.\n"

/// FLG = FHCRC|FNAME with the header CRC16 deliberately off by one bit.
private let badHeaderCRCVector =
  "H4sICnhWNBIAA3gABFZzzMlRyC8oyczPS8xRyEhNTEktUkjLTM1JKVZILEpVKChKLU7NK9HjAgByPGVHKAAAAA=="

/// FLG = FEXTRA with XLEN = 0, content "extra".
private let emptyExtraVector = "H4sIBHhWNBIAAwAAS60oKUoEAGUNP00FAAAA"

/// Compression level 0 (a stored deflate block), content "stored block payload " x 3.
private let storedVector =
  "H4sIAHhWNBIAAwE/AMD/c3RvcmVkIGJsb2NrIHBheWxvYWQgc3RvcmVkIGJsb2NrIHBheWxvYWQgc3RvcmVkIGJs"
  + "b2NrIHBheWxvYWQgV3BH+j8AAAA="

/// gzip.compress(b"first member, ") + gzip.compress(b"second member")
private let concatVector =
  "H4sIAAAAAAAA/0vLLCouUchNzU1KLdJRAADe/wpiDgAAAB+LCAAAAAAAAP8rTk3Oz0tRyE3NTUotAgAkdPqfDQAAAA=="

/// gzip.compress(xml, mtime=0) of an 8610-byte ONVIF MetadataStream document with 24
/// VideoAnalytics frames; zlib.crc32(xml) = 0xA7652FDC.
private let onvifXMLVector = [
  "H4sIAAAAAAAA/82aTW/aMBiA7/0VUe4lef0dVFq1lbpN2rRD6Q67pZCWbJAgcD/49yNQE7uHV3ojTbKEhDFOsJ/L",
  "o0fh4up9tUxeq822bptJCqM8Tapm1s7r5nmSPkzvzk16dXl2Ye34R2XLeWnLe7upylWyv67Zjq2dpAtr1+Mse3t7",
  "G7XNa/00ajfP2f6WkGfb2aJalenxBr/qedVeN+VyZ+vZ9rKbutuUqyp5sLNpvaomKcuZOgc4z/kU2DjP969Rnue/",
  "08Pin49/qplNjm/f5pM0P85fr9dVuSmbWXX4eL8o18fRTfvSdAe5ad+TZfW032renc+2624k02RTPy/2s+Iw/dha",
  "264mqeq+yg43uK0aW21+Pn3ZlK+13SXv3Ra7tbtJyj+WZcFP3i7L7fFo0926Sr7Xf6tlvWjbbrejYr/hry+rsjlc",
  "1C04Xv5xUfbpLNnpzMfxAdZx+AnlYLyA4QUyXn7Cy3y8PMDLULzc4WVkvKaIDS/D8DIyXnXCK3y8KsArULzK4RV0",
  "vCY2vBzDy8l4ixNe5eMtArwKxVs4vIqOV8eGV2B4BRkvsBNf4/GVLOBrML6cOb6GzlfFxldifCWdrzzxBd9uUvqA",
  "NWo3Lj8AC7rdjIwNsMIAKzpg0wP2/SZNABj1GzcO8AC/idgAawywJgNm0AP2DacgAIwaToADPMBwPDbABgNs6IBF",
  "D9h3nBIBYNRxQjjAAxzHYgNcYIALOmDdA/Ylp3QAGJWc0A7wAMlBZIABDTigFxzvE475ltNBwxnUctI1nBxgudga",
  "DvCGGxBxXsX5mtNBxhlUc9JlnKRrTseWcYBmHNA7jvchx3zP6aDkDOo56UpO0j2nYys5QEsO6CnH+5Zjvuh0EHMG",
  "FZ10MSfpotOxxRygMQf0mhN9zTHfdCbIOYOaTrmck3TT6dhyDtCcA3rPib7nuG86E/RcgZpOuZ5TdNPp2HoO0J4D",
  "etCJPui4bzoTBF2Bmk65oFMDTBdb0AEadEAvOtkXHfdNVwRFV6Cm067o1ADTxVZ0gBYd0JNO9knHfdMVQdIVqOm0",
  "Szo1wHSxJR2gSQf0ppN903HfdEXQdAVqOu2aTg0wXWxNx9CmY/SmU33TCd90kAdR131EGBtXdXqA62KrOoZWHaNX",
  "neqrTrCAMQ8Zo7Yzrus03XYqtq5j+OO5Ac/nvAd0ImCsQsao74wrO033nYqt7BhadoxedqovO6ECxkXIGDWecW2n",
  "6cZT/6/tusnwbxaXZ/8A3C9lp6IhAAA=",
].joined()
private let onvifXMLSize = 8610
private let onvifXMLCRC: UInt32 = 0xA765_2FDC

// MARK: - Helpers

private func vector(_ base64: String) throws -> Data {
  try #require(Data(base64Encoded: base64))
}

private func text(_ data: Data) -> String? {
  String(data: data, encoding: .utf8)
}

/// Deterministic SplitMix64 generator for fuzz inputs.
private struct SplitMix64 {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func bytes(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8(truncatingIfNeeded: next()) })
  }
}

/// Wraps a raw deflate body in a minimal gzip member (no optional fields).
private func gzipMember(deflate: Data, crc: UInt32, size: UInt32) -> Data {
  var member = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
  member.append(deflate)
  for shift in stride(from: 0, to: 32, by: 8) {
    member.append(UInt8(truncatingIfNeeded: crc >> shift))
  }
  for shift in stride(from: 0, to: 32, by: 8) {
    member.append(UInt8(truncatingIfNeeded: size >> shift))
  }
  return member
}

@Suite("Gzip Tests")
struct GzipTests {

  // MARK: CRC-32

  @Test("CRC-32 check value and chaining")
  func crc32() {
    let check = Data("123456789".utf8)
    #expect(Gzip.crc32(check) == 0xCBF4_3926)
    #expect(Gzip.crc32(Data()) == 0)
    let first = Gzip.crc32(check.prefix(4))
    #expect(Gzip.crc32(check.dropFirst(4), initial: first) == 0xCBF4_3926)
  }

  // MARK: Valid input

  @Test("Plain member")
  func plain() throws {
    #expect(text(try Gzip.decompress(vector(plainVector))) == plainText)
  }

  @Test("Empty member decodes to empty output")
  func emptyMember() throws {
    #expect(try Gzip.decompress(vector(emptyVector)).isEmpty)
    #expect(try Gzip.decompress(vector(emptyVector), maxOutputBytes: 0).isEmpty)
  }

  @Test("FNAME members from python and /usr/bin/gzip")
  func fileName() throws {
    #expect(text(try Gzip.decompress(vector(pythonNameVector))) == nameVectorText)
    #expect(text(try Gzip.decompress(vector(gzipToolVector))) == nameVectorText)
  }

  @Test("All optional header fields: FTEXT, FHCRC, FEXTRA, FNAME, FCOMMENT")
  func allFlags() throws {
    #expect(text(try Gzip.decompress(vector(allFlagsVector))) == allFlagsText)
  }

  @Test("FEXTRA with zero length")
  func emptyExtra() throws {
    #expect(text(try Gzip.decompress(vector(emptyExtraVector))) == "extra")
  }

  @Test("Stored (uncompressed) deflate block")
  func storedBlock() throws {
    let expected = String(repeating: "stored block payload ", count: 3)
    #expect(text(try Gzip.decompress(vector(storedVector))) == expected)
  }

  @Test("Concatenated members are joined")
  func concatenated() throws {
    #expect(text(try Gzip.decompress(vector(concatVector))) == "first member, second member")
  }

  @Test("ONVIF metadata document of several KB")
  func onvifDocument() throws {
    let xml = try Gzip.decompress(vector(onvifXMLVector))
    #expect(xml.count == onvifXMLSize)
    #expect(Gzip.crc32(xml) == onvifXMLCRC)
    let string = try #require(text(xml))
    #expect(string.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tt:MetadataStream"))
    #expect(string.hasSuffix("</tt:MetadataStream>\n"))
  }

  @Test("Input that is a slice with a nonzero startIndex")
  func sliceInput() throws {
    let backing = Data([0xAA, 0xBB, 0xCC]) + (try vector(concatVector)) + Data([0xDD])
    let slice = backing[3..<(backing.count - 1)]
    #expect(slice.startIndex == 3)
    #expect(text(try Gzip.decompress(slice)) == "first member, second member")
  }

  @Test("Zero padding after the last member is tolerated")
  func zeroPadding() throws {
    let padded = try vector(plainVector) + Data(repeating: 0, count: 9)
    #expect(text(try Gzip.decompress(padded)) == plainText)
  }

  @Test("Output limit: exact size passes, one byte less throws")
  func outputLimitBoundary() throws {
    let gz = try vector(onvifXMLVector)
    #expect(try Gzip.decompress(gz, maxOutputBytes: onvifXMLSize).count == onvifXMLSize)
    #expect(throws: GzipError.outputLimitExceeded(onvifXMLSize - 1)) {
      try Gzip.decompress(gz, maxOutputBytes: onvifXMLSize - 1)
    }
    #expect(throws: GzipError.outputLimitExceeded(0)) {
      try Gzip.decompress(vector(plainVector), maxOutputBytes: -5)
    }
    // The limit covers all members together, not each one.
    #expect(throws: GzipError.outputLimitExceeded(20)) {
      try Gzip.decompress(vector(concatVector), maxOutputBytes: 20)
    }
  }

  @Test("Decompression bomb stops at the limit")
  func decompressionBomb() throws {
    // 20 MiB of zeros deflates to ~20 KB; the trailer is never reached, so it is left zero.
    let zeros = Data(count: 20 * 1024 * 1024)
    let deflate = try (zeros as NSData).compressed(using: .zlib) as Data
    let bomb = gzipMember(deflate: deflate, crc: 0, size: 0)
    #expect(bomb.count < 64 * 1024)
    #expect(throws: GzipError.outputLimitExceeded(64 * 1024)) {
      try Gzip.decompress(bomb, maxOutputBytes: 64 * 1024)
    }
    #expect(throws: GzipError.outputLimitExceeded(16 * 1024 * 1024)) {
      try Gzip.decompress(bomb)
    }
  }

  @Test("Large member produced by another encoder round-trips")
  func largeMember() throws {
    var rng = SplitMix64(state: 7)
    // Mix compressible and random data so the body has several deflate blocks.
    var original = Data()
    for i in 0..<64 {
      original.append(i % 2 == 0 ? rng.bytes(3000) : Data(repeating: UInt8(i), count: 5000))
    }
    let deflate = try (original as NSData).compressed(using: .zlib) as Data
    let gz = gzipMember(
      deflate: deflate, crc: Gzip.crc32(original), size: UInt32(original.count))
    #expect(try Gzip.decompress(gz) == original)
  }

  @Test("Large concatenated members with zero padding")
  func largeConcatenated() throws {
    // Members larger than the Compression framework's 64 KiB input block.
    var rng = SplitMix64(state: 99)
    var stream = Data()
    var expected = Data()
    for i in 0..<3 {
      var original = rng.bytes(70_000 + i * 1000)
      original.append(Data(repeating: 0x41, count: 50_000))
      let deflate = try (original as NSData).compressed(using: .zlib) as Data
      #expect(deflate.count > 64 * 1024)
      stream.append(
        gzipMember(deflate: deflate, crc: Gzip.crc32(original), size: UInt32(original.count)))
      expected.append(original)
    }
    stream.append(Data(repeating: 0, count: 100))
    #expect(try Gzip.decompress(stream) == expected)
  }

  @Test("Many small members and empty members")
  func manyMembers() throws {
    var stream = Data()
    var expected = Data()
    for i in 0..<300 {
      let original = Data("member \(i);".utf8)
      let deflate = try (original as NSData).compressed(using: .zlib) as Data
      stream.append(
        gzipMember(deflate: deflate, crc: Gzip.crc32(original), size: UInt32(original.count)))
      stream.append(try vector(emptyVector))
      expected.append(original)
    }
    #expect(try Gzip.decompress(stream) == expected)

    // An empty member's trailer is eight zero bytes, the same as padding.
    let padded = try vector(emptyVector) + vector(emptyVector) + Data(repeating: 0, count: 20)
    #expect(try Gzip.decompress(padded).isEmpty)
    // Padding is only accepted after the last member.
    #expect(throws: GzipError.trailingGarbage) {
      try Gzip.decompress(vector(emptyVector) + Data(count: 20) + vector(emptyVector))
    }
  }

  @Test("Member count is capped")
  func memberCap() throws {
    let one = try vector(emptyVector)
    let atCap = Data((0..<Gzip.maxMembers).flatMap { _ in one })
    #expect(try Gzip.decompress(atCap).isEmpty)
    #expect(throws: GzipError.tooManyMembers(Gzip.maxMembers)) {
      try Gzip.decompress(atCap + one)
    }
  }

  // MARK: Malformed input

  @Test("Bad magic, method and reserved flags")
  func badHeaderFields() throws {
    var gz = try vector(plainVector)
    gz[1] = 0x8C
    #expect(throws: GzipError.badMagic) { try Gzip.decompress(gz) }

    gz = try vector(plainVector)
    gz[2] = 7
    #expect(throws: GzipError.unsupportedMethod(7)) { try Gzip.decompress(gz) }

    gz = try vector(plainVector)
    gz[3] = 0x20
    #expect(throws: GzipError.reservedFlags(0x20)) { try Gzip.decompress(gz) }
  }

  @Test("Header CRC16 mismatch")
  func headerCRCMismatch() throws {
    #expect(throws: GzipError.headerChecksumMismatch) {
      try Gzip.decompress(vector(badHeaderCRCVector))
    }
  }

  @Test("Trailer CRC-32 and ISIZE mismatches")
  func trailerMismatch() throws {
    let gz = try vector(plainVector)
    var badCRC = gz
    badCRC[badCRC.count - 8] ^= 0x01
    #expect(throws: GzipError.checksumMismatch) { try Gzip.decompress(badCRC) }

    var badSize = gz
    badSize[badSize.count - 4] ^= 0x01
    #expect(throws: GzipError.sizeMismatch) { try Gzip.decompress(badSize) }
  }

  @Test("Every truncation of a valid member throws")
  func truncation() throws {
    for vectorString in [plainVector, allFlagsVector, onvifXMLVector, concatVector] {
      let gz = try vector(vectorString)
      for length in 0..<gz.count {
        // Cutting concatVector right after its 34-byte first member leaves a valid stream.
        if vectorString == concatVector && length == 34 {
          #expect(text(try Gzip.decompress(gz.prefix(length))) == "first member, ")
          continue
        }
        #expect(throws: GzipError.self, "length \(length)") {
          try Gzip.decompress(gz.prefix(length))
        }
      }
    }
    // allFlagsVector: 41-byte header, 42-byte deflate body, 8-byte trailer. A cut header
    // or trailer is reported as truncation; a cut deflate body is indistinguishable from a
    // corrupt one with the Compression framework.
    let gz = try vector(allFlagsVector)
    #expect(gz.count == 91)
    for length in [0, 1, 5, 12, 20, 30, 40, 41, 83, 86, 90] {
      #expect(throws: GzipError.truncated, "length \(length)") {
        try Gzip.decompress(gz.prefix(length))
      }
    }
    for length in [42, 60, 82] {
      #expect(throws: GzipError.corruptData, "length \(length)") {
        try Gzip.decompress(gz.prefix(length))
      }
    }
  }

  @Test("Trailing garbage after the last member throws")
  func trailingGarbage() throws {
    #expect(throws: GzipError.trailingGarbage) {
      try Gzip.decompress(vector(plainVector) + Data([0x00, 0x42]))
    }
    #expect(throws: GzipError.trailingGarbage) {
      try Gzip.decompress(vector(plainVector) + Data([0x1F]))
    }
    // A second member that is itself broken reports its own error.
    #expect(throws: GzipError.truncated) {
      try Gzip.decompress(vector(plainVector) + Data([0x1F, 0x8B, 0x08]))
    }
  }

  @Test("Random garbage throws without trapping")
  func randomGarbage() throws {
    var rng = SplitMix64(state: 0x1234_5678)
    for _ in 0..<2000 {
      let length = Int(rng.next() % 96)
      let garbage = rng.bytes(length)
      #expect(throws: GzipError.self) { try Gzip.decompress(garbage) }
      // Valid header followed by random bytes: the deflate body or trailer must fail.
      let headed = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]) + garbage
      #expect(throws: GzipError.self) { try Gzip.decompress(headed) }
    }
  }

  @Test("Single bit flips either throw or decode to the original")
  func bitFlips() throws {
    for (vectorString, original) in [
      (plainVector, Data(plainText.utf8)), (allFlagsVector, Data(allFlagsText.utf8)),
    ] {
      let gz = try vector(vectorString)
      for index in 0..<gz.count {
        for bit in 0..<8 {
          var mutated = gz
          mutated[index] ^= UInt8(1 << bit)
          if let output = try? Gzip.decompress(mutated) {
            // Only bytes the decoder legitimately ignores (MTIME, XFL, OS, FTEXT, name or
            // comment text) may change without an error.
            #expect(output == original, "byte \(index) bit \(bit)")
          }
        }
      }
    }
  }
}
