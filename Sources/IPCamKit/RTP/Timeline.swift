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
struct Timeline: Sendable {
  /// Current full 64-bit timestamp.
  private var timestamp: Int64

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

    self.timestamp = ts.timestamp
    return ts
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
    _ rtpTimestamp: UInt32
  ) throws -> (Timestamp, Int32) {
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
