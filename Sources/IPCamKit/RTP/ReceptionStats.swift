// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Reception statistics and RTCP receiver reports (RFC 3550 section 6.4.2, appendix A)

import Foundation

/// What a receiver report says about one RTP source: packets expected and
/// received, interarrival jitter, and the timing of the source's last sender
/// report (RFC 3550 section 6.4.1).
///
/// It counts the packets the in-order parser accepted, so its sequence
/// tracking agrees with the `loss` the session reports on frames. Reset it when
/// sequence tracking restarts (a seek) or the source's SSRC changes.
struct ReceptionStats: Sendable {
  /// SSRC of the source the statistics describe; nil until its first packet.
  private(set) var sourceSSRC: UInt32?
  private var baseSequence: UInt16 = 0
  private var maxSequence: UInt16 = 0
  /// Sequence-number wraps, shifted left 16 (RFC 3550 appendix A.1 `cycles`).
  private var cycles: UInt32 = 0
  private var received: UInt32 = 0
  private var expectedPrior: UInt32 = 0
  private var receivedPrior: UInt32 = 0
  /// Interarrival jitter estimate in RTP timestamp units (appendix A.8).
  private var jitter: Double = 0
  private var lastArrivalTicks: Int64?
  private var lastRTPTimestamp: UInt32 = 0
  /// The last sender report: its SSRC, the middle 32 bits of its NTP
  /// timestamp, and when it arrived. Kept across a reset, since a report can
  /// arrive before the source's first packet.
  private var lastSenderReport: (ssrc: UInt32, middle: UInt32, arrival: ContinuousClock.Instant)?

  /// Record a packet the in-order parser accepted. `arrivalTicks` is the
  /// arrival time in RTP clock units on any fixed origin. `timingRestarted`
  /// says the packet's RTP timestamp isn't comparable with the previous one's
  /// (the sender's RTP clock restarted), so it adds no jitter sample.
  mutating func recordPacket(
    ssrc: UInt32, sequence: UInt16, rtpTimestamp: UInt32, arrivalTicks: Int64,
    timingRestarted: Bool = false
  ) {
    if timingRestarted { lastArrivalTicks = nil }
    if sourceSSRC != ssrc {
      let senderReport = lastSenderReport
      self = ReceptionStats()
      lastSenderReport = senderReport
      sourceSSRC = ssrc
      baseSequence = sequence
      maxSequence = sequence
    } else if sequence &- maxSequence > 0x8000 {
      // Behind the highest number seen: the in-order parser only accepts
      // that when it resynchronizes to a sender that restarted its sequence
      // numbers, which starts new statistics (RFC 3550 A.1, init_seq).
      let senderReport = lastSenderReport
      self = ReceptionStats()
      lastSenderReport = senderReport
      sourceSSRC = ssrc
      baseSequence = sequence
      maxSequence = sequence
    } else {
      // Ahead of the highest number seen; a smaller value means the 16-bit
      // sequence wrapped.
      if sequence < maxSequence { cycles &+= 1 << 16 }
      maxSequence = sequence
    }
    received &+= 1

    if let lastArrival = lastArrivalTicks {
      let arrivalDelta = arrivalTicks - lastArrival
      let timestampDelta = Int64(Int32(bitPattern: rtpTimestamp &- lastRTPTimestamp))
      let difference = abs(Double(arrivalDelta - timestampDelta))
      jitter += (difference - jitter) / 16
    }
    lastArrivalTicks = arrivalTicks
    lastRTPTimestamp = rtpTimestamp
  }

  /// Start new statistics (a seek's sequence numbers replace the previous
  /// playback's), keeping the last sender report.
  mutating func restart() {
    let senderReport = lastSenderReport
    self = ReceptionStats()
    lastSenderReport = senderReport
  }

  /// Record a sender report (its sender's SSRC and 64-bit NTP timestamp).
  mutating func recordSenderReport(
    ssrc: UInt32, ntpTimestamp: UInt64, arrival: ContinuousClock.Instant
  ) {
    lastSenderReport = (ssrc, UInt32(truncatingIfNeeded: ntpTimestamp >> 16), arrival)
  }

  /// The 24-byte report block for the source, or nil before its first packet.
  /// Advances the interval used for the fraction-lost field (appendix A.3).
  mutating func reportBlock(now: ContinuousClock.Instant) -> Data? {
    guard let sourceSSRC else { return nil }
    let extendedMax = cycles &+ UInt32(maxSequence)
    let expected = extendedMax &- UInt32(baseSequence) &+ 1
    let lost = Int64(expected) - Int64(received)
    let clampedLost = min(max(lost, -0x80_0000), 0x7F_FFFF)

    let expectedInterval = expected &- expectedPrior
    let receivedInterval = received &- receivedPrior
    expectedPrior = expected
    receivedPrior = received
    let lostInterval = Int64(expectedInterval) - Int64(receivedInterval)
    let fraction: UInt8 =
      expectedInterval == 0 || lostInterval <= 0
      ? 0 : UInt8(min(255, (lostInterval << 8) / Int64(expectedInterval)))

    var lastSR: UInt32 = 0
    var delaySinceLastSR: UInt32 = 0
    if let report = lastSenderReport, report.ssrc == sourceSSRC {
      lastSR = report.middle
      let (seconds, attoseconds) = (now - report.arrival).components
      let units = (Double(seconds) + Double(attoseconds) * 1e-18) * 65536
      delaySinceLastSR = UInt32(min(max(units, 0), Double(UInt32.max)))
    }

    var block = Data(capacity: 24)
    block.appendBigEndian(sourceSSRC)
    block.append(fraction)
    let lost24 = UInt32(bitPattern: Int32(clampedLost)) & 0xFF_FFFF
    block.append(UInt8(lost24 >> 16))
    block.append(UInt8((lost24 >> 8) & 0xFF))
    block.append(UInt8(lost24 & 0xFF))
    block.appendBigEndian(extendedMax)
    block.appendBigEndian(UInt32(min(jitter, Double(UInt32.max))))
    block.appendBigEndian(lastSR)
    block.appendBigEndian(delaySinceLastSR)
    return block
  }
}

/// RTCP packets the client sends.
enum RTCPReport {
  /// A compound RTCP packet: a receiver report (PT 201) with `blocks` (at most
  /// 31), then the SDES CNAME every compound packet must carry (RFC 3550
  /// section 6.1).
  static func receiverReport(reporterSSRC: UInt32, blocks: [Data], cname: String) -> Data {
    precondition(blocks.count <= 31, "an RR carries at most 31 report blocks")
    var packet = Data()
    packet.append(0x80 | UInt8(blocks.count))
    packet.append(201)
    packet.appendBigEndian(UInt16(1 + 6 * blocks.count))
    packet.appendBigEndian(reporterSSRC)
    for block in blocks { packet.append(block) }

    let text = Data(cname.utf8.prefix(255))
    // Chunk: SSRC, CNAME item (type 1, length, text), end item, zero padding.
    var chunk = Data()
    chunk.appendBigEndian(reporterSSRC)
    chunk.append(1)
    chunk.append(UInt8(text.count))
    chunk.append(text)
    chunk.append(0)
    while chunk.count % 4 != 0 { chunk.append(0) }
    packet.append(0x81)
    packet.append(202)
    packet.appendBigEndian(UInt16(chunk.count / 4))
    packet.append(chunk)
    return packet
  }
}

extension Data {
  fileprivate mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
}
