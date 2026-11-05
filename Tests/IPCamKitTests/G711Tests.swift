// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Tests for the G.711 mu-law / A-law encoders and decoders against external references.

import Foundation
import Testing

@testable import IPCamKit

// MARK: - Reference data
//
// Captured once with external tools; the tests do not need them at run time.
// - Decode tables: ffmpeg 8.x (`-f mulaw` / `-f alaw` -> `-f s16le`) for codes 0...255.
//   CPython 3.9 `audioop.ulaw2lin` / `alaw2lin` produce identical tables.
// - Encode checksums: FNV-1a 64 over the codes for every Int16 from -32768 to 32767.

/// G.711 mu-law decode table (code -> linear), from ffmpeg.
private let muLawDecodeTable: [Int16] = [
  -32124, -31100, -30076, -29052, -28028, -27004, -25980, -24956,
  -23932, -22908, -21884, -20860, -19836, -18812, -17788, -16764,
  -15996, -15484, -14972, -14460, -13948, -13436, -12924, -12412,
  -11900, -11388, -10876, -10364, -9852, -9340, -8828, -8316,
  -7932, -7676, -7420, -7164, -6908, -6652, -6396, -6140,
  -5884, -5628, -5372, -5116, -4860, -4604, -4348, -4092,
  -3900, -3772, -3644, -3516, -3388, -3260, -3132, -3004,
  -2876, -2748, -2620, -2492, -2364, -2236, -2108, -1980,
  -1884, -1820, -1756, -1692, -1628, -1564, -1500, -1436,
  -1372, -1308, -1244, -1180, -1116, -1052, -988, -924,
  -876, -844, -812, -780, -748, -716, -684, -652,
  -620, -588, -556, -524, -492, -460, -428, -396,
  -372, -356, -340, -324, -308, -292, -276, -260,
  -244, -228, -212, -196, -180, -164, -148, -132,
  -120, -112, -104, -96, -88, -80, -72, -64,
  -56, -48, -40, -32, -24, -16, -8, 0,
  32124, 31100, 30076, 29052, 28028, 27004, 25980, 24956,
  23932, 22908, 21884, 20860, 19836, 18812, 17788, 16764,
  15996, 15484, 14972, 14460, 13948, 13436, 12924, 12412,
  11900, 11388, 10876, 10364, 9852, 9340, 8828, 8316,
  7932, 7676, 7420, 7164, 6908, 6652, 6396, 6140,
  5884, 5628, 5372, 5116, 4860, 4604, 4348, 4092,
  3900, 3772, 3644, 3516, 3388, 3260, 3132, 3004,
  2876, 2748, 2620, 2492, 2364, 2236, 2108, 1980,
  1884, 1820, 1756, 1692, 1628, 1564, 1500, 1436,
  1372, 1308, 1244, 1180, 1116, 1052, 988, 924,
  876, 844, 812, 780, 748, 716, 684, 652,
  620, 588, 556, 524, 492, 460, 428, 396,
  372, 356, 340, 324, 308, 292, 276, 260,
  244, 228, 212, 196, 180, 164, 148, 132,
  120, 112, 104, 96, 88, 80, 72, 64,
  56, 48, 40, 32, 24, 16, 8, 0,
]

/// G.711 A-law decode table (code -> linear), from ffmpeg.
private let aLawDecodeTable: [Int16] = [
  -5504, -5248, -6016, -5760, -4480, -4224, -4992, -4736,
  -7552, -7296, -8064, -7808, -6528, -6272, -7040, -6784,
  -2752, -2624, -3008, -2880, -2240, -2112, -2496, -2368,
  -3776, -3648, -4032, -3904, -3264, -3136, -3520, -3392,
  -22016, -20992, -24064, -23040, -17920, -16896, -19968, -18944,
  -30208, -29184, -32256, -31232, -26112, -25088, -28160, -27136,
  -11008, -10496, -12032, -11520, -8960, -8448, -9984, -9472,
  -15104, -14592, -16128, -15616, -13056, -12544, -14080, -13568,
  -344, -328, -376, -360, -280, -264, -312, -296,
  -472, -456, -504, -488, -408, -392, -440, -424,
  -88, -72, -120, -104, -24, -8, -56, -40,
  -216, -200, -248, -232, -152, -136, -184, -168,
  -1376, -1312, -1504, -1440, -1120, -1056, -1248, -1184,
  -1888, -1824, -2016, -1952, -1632, -1568, -1760, -1696,
  -688, -656, -752, -720, -560, -528, -624, -592,
  -944, -912, -1008, -976, -816, -784, -880, -848,
  5504, 5248, 6016, 5760, 4480, 4224, 4992, 4736,
  7552, 7296, 8064, 7808, 6528, 6272, 7040, 6784,
  2752, 2624, 3008, 2880, 2240, 2112, 2496, 2368,
  3776, 3648, 4032, 3904, 3264, 3136, 3520, 3392,
  22016, 20992, 24064, 23040, 17920, 16896, 19968, 18944,
  30208, 29184, 32256, 31232, 26112, 25088, 28160, 27136,
  11008, 10496, 12032, 11520, 8960, 8448, 9984, 9472,
  15104, 14592, 16128, 15616, 13056, 12544, 14080, 13568,
  344, 328, 376, 360, 280, 264, 312, 296,
  472, 456, 504, 488, 408, 392, 440, 424,
  88, 72, 120, 104, 24, 8, 56, 40,
  216, 200, 248, 232, 152, 136, 184, 168,
  1376, 1312, 1504, 1440, 1120, 1056, 1248, 1184,
  1888, 1824, 2016, 1952, 1632, 1568, 1760, 1696,
  688, 656, 752, 720, 560, 528, 624, 592,
  944, 912, 1008, 976, 816, 784, 880, 848,
]

/// CPython 3.9 `audioop.lin2alaw` over all 65536 inputs (identical to Sun `g711.c`).
private let audioopALawChecksum: UInt64 = 0xF030_666E_B780_CF25

/// CPython 3.9 `audioop.lin2ulaw` over the inputs x >= 0 or x % 4 == 0 (40960 values).
/// audioop is Sun's 14-bit variant (`x >> 2`, then negate); it equals the 16-bit variant
/// (`BIAS 0x84`, `CLIP 32635`) everywhere except negative inputs that are not multiples of
/// 4, where its arithmetic shift rounds the magnitude up.
private let audioopMuLawSubsetChecksum: UInt64 = 0x23CC_3874_5FFF_EB03

/// Sun `g711.c` 16-bit `linear2ulaw` (BIAS 0x84, CLIP 32635), compiled from C, all inputs.
private let sunMuLawChecksum: UInt64 = 0x94D7_5252_14C7_5EB2

/// ffmpeg 8.x `-f s16le -i all.raw -f alaw` / `-f mulaw` over all 65536 inputs.
private let ffmpegALawChecksum: UInt64 = 0xB692_762F_B973_CB11
private let ffmpegMuLawChecksum: UInt64 = 0xA733_78DF_9212_A731

/// Inputs where ffmpeg's encoder picks the other of the two nearest levels.
private let ffmpegALawMismatches = 964
private let ffmpegMuLawMismatches = 851

// MARK: - Helpers

private let allSamples: [Int16] = Array(Int16.min...Int16.max)

private func fnv1a64(_ bytes: some Sequence<UInt8>) -> UInt64 {
  var hash: UInt64 = 0xCBF2_9CE4_8422_2325
  for byte in bytes {
    hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
  }
  return hash
}

/// ffmpeg's encoder (libavcodec/pcm_tablegen.h `build_xlaw_table`): a 16384-entry table
/// indexed by `(sample + 32768) >> 2`, with each threshold at the midpoint between adjacent
/// decoded levels. `mask` is 0xFF for mu-law and 0xD5 for A-law.
private func ffmpegEncodeModel(decodeTable: [Int16], mask: Int) -> [UInt8] {
  var table = [UInt8](repeating: 0, count: 16384)
  var j = 1
  table[8192] = UInt8(mask)
  for i in 0..<127 {
    let v1 = Int(decodeTable[i ^ mask])
    let v2 = Int(decodeTable[(i + 1) ^ mask])
    let v = (v1 + v2 + 4) >> 3
    while j < v {
      table[8192 - j] = UInt8(i ^ (mask ^ 0x80))
      table[8192 + j] = UInt8(i ^ mask)
      j += 1
    }
  }
  while j < 8192 {
    table[8192 - j] = UInt8(127 ^ (mask ^ 0x80))
    table[8192 + j] = UInt8(127 ^ mask)
    j += 1
  }
  table[0] = table[1]
  return allSamples.map { table[(Int($0) + 32768) >> 2] }
}

/// Checks that every input where `ours` and `theirs` differ lies between the two decoded
/// levels, and that those levels are neighbors. Returns the number of differences.
private func compareToNeighborLevels(
  ours: Data, theirs: [UInt8], decodeTable: [Int16]
) -> Int {
  let levels = Set(decodeTable).sorted()
  var rank: [Int16: Int] = [:]
  for (i, level) in levels.enumerated() { rank[level] = i }
  var differences = 0
  for (i, (a, b)) in zip(ours, theirs).enumerated() where a != b {
    differences += 1
    let x = Int(allSamples[i])
    let ourLevel = decodeTable[Int(a)]
    let theirLevel = decodeTable[Int(b)]
    #expect(abs((rank[ourLevel] ?? -9) - (rank[theirLevel] ?? 9)) == 1, "x=\(x)")
    #expect(Int(min(ourLevel, theirLevel)) <= x && x <= Int(max(ourLevel, theirLevel)), "x=\(x)")
  }
  return differences
}

@Suite("G711 Tests")
struct G711Tests {

  // MARK: Decoding

  @Test("Decode tables match ffmpeg for all 256 codes")
  func decodeTables() {
    let codes = Data(0...255)
    #expect(G711.decodeMuLaw(codes) == muLawDecodeTable)
    #expect(G711.decodeALaw(codes) == aLawDecodeTable)
  }

  @Test("Decoding accepts empty input and slices")
  func decodeEmptyAndSlice() {
    #expect(G711.decodeMuLaw(Data()).isEmpty)
    #expect(G711.decodeALaw(Data()).isEmpty)
    let backing = Data([0x00, 0x11, 0xFF, 0xD5, 0x80])
    let slice = backing[2..<5]
    #expect(slice.startIndex == 2)
    #expect(G711.decodeMuLaw(slice) == [0, muLawDecodeTable[0xD5], 32124])
    #expect(G711.decodeALaw(slice) == [aLawDecodeTable[0xFF], 8, aLawDecodeTable[0x80]])
  }

  // MARK: Encoding against references

  @Test("A-law encoder matches CPython audioop for every Int16")
  func aLawMatchesAudioop() {
    #expect(fnv1a64(G711.encodeALaw(allSamples)) == audioopALawChecksum)
  }

  @Test("mu-law encoder matches audioop where the Sun variants agree, and Sun g711.c")
  func muLawMatchesReferences() {
    let encoded = G711.encodeMuLaw(allSamples)
    #expect(fnv1a64(encoded) == sunMuLawChecksum)
    let subset = zip(allSamples, encoded).filter { $0.0 >= 0 || $0.0 % 4 == 0 }.map(\.1)
    #expect(subset.count == 40960)
    #expect(fnv1a64(subset) == audioopMuLawSubsetChecksum)
    // Sign-magnitude: -x encodes like x with the sign bit cleared.
    for x in 1...Int16.max {
      #expect(G711.muLaw(from: -x) == G711.muLaw(from: x) & 0x7F)
    }
  }

  @Test("Differences from ffmpeg are only neighbor levels at decision thresholds")
  func comparedToFFmpeg() {
    let aLawModel = ffmpegEncodeModel(decodeTable: aLawDecodeTable, mask: 0xD5)
    let muLawModel = ffmpegEncodeModel(decodeTable: muLawDecodeTable, mask: 0xFF)
    // The model reproduces ffmpeg's real output exactly...
    #expect(fnv1a64(aLawModel) == ffmpegALawChecksum)
    #expect(fnv1a64(muLawModel) == ffmpegMuLawChecksum)
    // ...and it differs from the G.711 decision levels on a known set of inputs.
    let aLawDiffs = compareToNeighborLevels(
      ours: G711.encodeALaw(allSamples), theirs: aLawModel, decodeTable: aLawDecodeTable)
    let muLawDiffs = compareToNeighborLevels(
      ours: G711.encodeMuLaw(allSamples), theirs: muLawModel, decodeTable: muLawDecodeTable)
    #expect(aLawDiffs == ffmpegALawMismatches)
    #expect(muLawDiffs == ffmpegMuLawMismatches)
  }

  @Test("Spot values")
  func spotValues() {
    let samples: [Int16] = [0, -1, 1, 100, -100, 511, 512, -512, 4096, 32635, 32767, -32768]
    #expect(
      [UInt8](G711.encodeMuLaw(samples))
        == [0xFF, 0x7F, 0xFF, 0xF2, 0x72, 0xDB, 0xDB, 0x5B, 0xAF, 0x80, 0x80, 0x00])
    // 512 and 4096 are G.711 A-law decision values (64 and 512 on the 13-bit scale), so
    // they start a new segment: 0xF5 decodes to 528 and 0x85 to 4224 (ffmpeg: 0xCA, 0x9A).
    #expect(
      [UInt8](G711.encodeALaw(samples))
        == [0xD5, 0x55, 0xD5, 0xD3, 0x53, 0xCA, 0xF5, 0x4A, 0x85, 0xAA, 0xAA, 0x2A])
    #expect(G711.encodeMuLaw([]).isEmpty)
    #expect(G711.encodeALaw([]).isEmpty)
  }

  @Test("Every decoded level re-encodes to itself")
  func levelsAreStable() {
    for code in UInt8.min...UInt8.max {
      let mu = muLawDecodeTable[Int(code)]
      #expect(G711.decodeMuLaw(G711.encodeMuLaw([mu])) == [mu], "mu-law code \(code)")
      let a = aLawDecodeTable[Int(code)]
      #expect(G711.encodeALaw([a]) == Data([code]), "A-law code \(code)")
    }
  }
}
