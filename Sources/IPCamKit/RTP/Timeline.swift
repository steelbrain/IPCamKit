// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/client/timeline.rs - RTP timestamp wraparound tracking

import Foundation

/// Tracks RTP timestamps, extending 32-bit values to 64-bit via wraparound detection.
///
/// Handles:
/// - Normal monotonic advancement
/// - 32-bit wraparound at 2^32
/// - Optional enforcement of maximum forward time jumps
/// - Backward timestamp placement (for RTCP SR)
/// - Rebasing onto a new RTP source (SSRC change, seek) without a jump
struct Timeline: Sendable {
  /// Current full 64-bit timestamp.
  private var timestamp: Int64

  /// Added (mod 2^32) to every incoming RTP timestamp. Non-zero after
  /// `rebase(continuingWith:)` maps a new source's unrelated timestamp base
  /// onto this timeline.
  private var offset: UInt32 = 0

  /// True once `advanceTo` has accepted a timestamp.
  private(set) var hasAdvanced = false

  /// The last few distinct advanced timestamps, oldest first (at most
  /// `recentLimit`), since the last rebase. The smallest gap between them is
  /// the frame interval, even with B-frames sent in decoding order.
  private var recent: [Int64] = []
  private static let recentLimit = 8

  /// The highest advanced timestamp (valid once `hasAdvanced`). With B-frames,
  /// sent in decoding order, the latest timestamp can be below it.
  private var highest: Int64 = 0

  /// The latest end of a frame delivered from this timeline (`noteFrameEnd`),
  /// or `Int64.min` before any. Audio reaches past `highest`: each frame lasts
  /// past its own timestamp, and the access units of an aggregated AAC packet
  /// are timestamped after the packet. Rebasing keeps it, since what was
  /// delivered stays delivered.
  private var coveredUntil = Int64.min

  /// Clock rate in Hz.
  let clockRate: UInt32

  /// Starting RTP timestamp (from RTP-Info header).
  private var start: UInt32?

  /// Maximum allowed forward jump in clock rate units (nil = no enforcement).
  private let maxForwardJump: Int32?

  /// Create a new timeline.
  ///
  /// - Parameters:
  ///   - start: Initial RTP timestamp from RTP-Info, or nil if unknown
  ///   - clockRate: Codec clock rate in Hz (must be > 0)
  ///   - enforceMaxJumpSecs: If set, reject timestamps that jump forward
  ///     more than this many seconds or backward at all
  init(start: UInt32?, clockRate: UInt32, enforceMaxJumpSecs: UInt32? = nil) throws {
    guard clockRate > 0 else {
      throw RTSPError.depacketizationError("clock rate must be non-zero")
    }
    self.clockRate = clockRate
    self.start = start
    self.timestamp = Int64(start ?? 0)

    if let maxSecs = enforceMaxJumpSecs, maxSecs > 0 {
      let jumpUnits = Int64(maxSecs) * Int64(clockRate)
      guard jumpUnits <= Int64(Int32.max) else {
        throw RTSPError.depacketizationError(
          "max_forward_jump overflow: \(maxSecs) * \(clockRate) > i32::MAX")
      }
      self.maxForwardJump = Int32(jumpUnits)
    } else {
      self.maxForwardJump = nil
    }
  }

  /// Advance the timeline to a new RTP timestamp.
  ///
  /// Extends the 32-bit RTP timestamp to 64-bit by detecting wraparound.
  /// If enforcement is enabled, rejects backward jumps and excessive forward jumps.
  ///
  /// Returns the full Timestamp.
  mutating func advanceTo(_ rtpTimestamp: UInt32) throws -> Timestamp {
    let (ts, delta) = try timestampAndDelta(rtpTimestamp)

    if let maxJump = maxForwardJump {
      // Upstream uses exclusive upper bound: 0..<max_forward_jump
      guard delta >= 0, delta < maxJump else {
        throw RTSPError.depacketizationError(
          "timestamp jump of \(delta) rejected (max forward: \(maxJump))")
      }
    }

    if recent.last != ts.timestamp {
      if recent.count == Self.recentLimit { recent.removeFirst() }
      recent.append(ts.timestamp)
    }
    highest = hasAdvanced ? max(highest, ts.timestamp) : ts.timestamp
    self.timestamp = ts.timestamp
    hasAdvanced = true
    return ts
  }

  /// Seconds after `start` one step past the highest advanced timestamp, or
  /// at the end of the last delivered frame (`noteFrameEnd`) when that is
  /// later: where the stream's next frame would have been. The step is the
  /// frame interval: the smallest gap between the last 8 distinct timestamps,
  /// at least one tick (so the next frame never repeats the highest
  /// timestamp) and at most half a second (so a stream that sends rarely,
  /// like metadata on events, doesn't push a seek's common start far ahead).
  /// nil before the first `advanceTo`.
  var nextElapsedSeconds: Double? {
    guard hasAdvanced, let start else { return nil }
    let sorted = recent.sorted()
    let gap = zip(sorted, sorted.dropFirst()).map { $1 - $0 }.min() ?? 0
    let step = max(1, min(gap, Int64(clockRate) / 2))
    return Double(max(highest + step, coveredUntil) - Int64(start)) / Double(clockRate)
  }

  /// Record that a frame delivered from this timeline ends at `end` (its
  /// `Timestamp.timestamp` plus its duration in ticks). Rebasing and
  /// `nextElapsedSeconds` then place the next frame no earlier than the
  /// latest such end, so frames that last past their packet's timestamp
  /// (audio) aren't overlapped by the frames that follow.
  mutating func noteFrameEnd(_ end: Int64) {
    if end > coveredUntil { coveredUntil = end }
  }

  /// Seconds after `start` that `rtpTimestamp` falls at with the current
  /// mapping (within 2^31 ticks of the latest timestamp), without advancing.
  /// Nil before the first `advanceTo`.
  func elapsedSeconds(at rtpTimestamp: UInt32) -> Double? {
    guard hasAdvanced, let start else { return nil }
    let delta = Int32(bitPattern: (rtpTimestamp &+ offset) &- UInt32(truncatingIfNeeded: timestamp))
    return Double(timestamp + Int64(delta) - Int64(start)) / Double(clockRate)
  }

  /// Map `rtpTimestamp` to `seconds` after `start`; later timestamps follow
  /// from there. Used after a seek to put every stream's new playback at the
  /// same time. A timeline with no `start` yet gets one `seconds` before
  /// `rtpTimestamp`. The latest timestamp moves to that point, however far
  /// ahead, so the next `advanceTo(rtpTimestamp)` is a step of 0. Returns
  /// false (and changes nothing) when `seconds` is behind the highest
  /// timestamp or the end of the last delivered frame (`noteFrameEnd`), or
  /// beyond 2^53 ticks.
  @discardableResult
  mutating func rebase(mapping rtpTimestamp: UInt32, toElapsedSeconds seconds: Double) -> Bool {
    guard seconds.isFinite, seconds >= 0 else { return false }
    let ticks = (seconds * Double(clockRate)).rounded(.up)
    guard ticks < Double(Int64(1) << 53) else { return false }
    guard let start else {
      // Nothing placed yet (`start` is set by the first timestamp placed).
      let newStart = rtpTimestamp &- UInt32(truncatingIfNeeded: Int64(ticks))
      offset = 0
      self.start = newStart
      timestamp = Int64(newStart) + Int64(ticks)
      return true
    }
    let target = Int64(start) + Int64(ticks)
    guard target >= max(hasAdvanced ? max(timestamp, highest) : timestamp, coveredUntil) else {
      return false
    }
    offset = UInt32(truncatingIfNeeded: target) &- rtpTimestamp
    timestamp = target
    highest = target
    recent.removeAll()
    return true
  }

  /// Continue the timeline with a new RTP source whose timestamps have an
  /// unrelated (random) base, such as a camera that changed its SSRC.
  ///
  /// The new source's `rtpTimestamp` maps to one tick after the highest
  /// advanced timestamp, or to the end of the last delivered frame
  /// (`noteFrameEnd`) when that is later, and its later timestamps follow
  /// from there, so the timeline neither jumps nor goes backwards. `start` is
  /// unchanged. One tick rather than zero keeps the new source's first frame
  /// distinct from the old source's last one; the frame end keeps it from
  /// overlapping audio already delivered (an aggregated AAC packet's access
  /// units run past its timestamp, and every audio frame lasts past its own).
  /// A no-op before the first `advanceTo`: until then there is nothing to
  /// continue from, and an RTP-Info `start` still applies.
  mutating func rebase(continuingWith rtpTimestamp: UInt32) {
    guard hasAdvanced else { return }
    offset = UInt32(truncatingIfNeeded: max(highest &+ 1, coveredUntil)) &- rtpTimestamp
    // The one-tick gap to the new source isn't a frame interval.
    recent.removeAll()
  }

  /// Whether `rtpTimestamp` is more than `seconds` behind the latest advanced
  /// timestamp (false before the first `advanceTo`). Small steps back are
  /// normal (B-frames are sent in decoding order); a large one means the
  /// sender's RTP clock restarted.
  func isBehind(_ rtpTimestamp: UInt32, bySeconds seconds: UInt32) -> Bool {
    guard hasAdvanced else { return false }
    let delta = Int32(bitPattern: (rtpTimestamp &+ offset) &- UInt32(truncatingIfNeeded: timestamp))
    return Int64(delta) < -Int64(seconds) * Int64(clockRate)
  }

  /// Place a timestamp without advancing the timeline.
  ///
  /// Used for RTCP Sender Report timestamps which may be behind the current time.
  /// Does not enforce forward-only constraints. Will set start if unset.
  mutating func place(_ rtpTimestamp: UInt32) throws -> Timestamp {
    let (ts, _) = try timestampAndDelta(rtpTimestamp)
    return ts
  }

  /// Compute the full timestamp and delta from the current position.
  ///
  /// If start is nil (no initial rtptime from RTP-Info), sets start and
  /// self.timestamp to the incoming rtpTimestamp first, making delta = 0.
  /// This matches upstream ts_and_delta behavior.
  private mutating func timestampAndDelta(
    _ wireTimestamp: UInt32
  ) throws -> (Timestamp, Int32) {
    let rtpTimestamp = wireTimestamp &+ offset
    // If start is unset, initialize it to this timestamp
    let effectiveStart: UInt32
    if let s = start {
      effectiveStart = s
    } else {
      start = rtpTimestamp
      timestamp = Int64(rtpTimestamp)
      effectiveStart = rtpTimestamp
    }

    // Compute delta using wrapping subtraction, treating as signed 32-bit
    let delta = Int32(bitPattern: rtpTimestamp &- UInt32(truncatingIfNeeded: self.timestamp))

    // Extend to 64-bit
    let (newTimestamp, overflow) = self.timestamp.addingReportingOverflow(Int64(delta))
    guard !overflow else {
      throw RTSPError.depacketizationError("timestamp overflow")
    }

    guard
      let ts = Timestamp(
        timestamp: newTimestamp,
        clockRate: clockRate,
        start: effectiveStart
      )
    else {
      throw RTSPError.depacketizationError("timestamp underflow")
    }

    return (ts, delta)
  }
}
