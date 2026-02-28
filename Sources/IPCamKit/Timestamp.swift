// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina (https://github.com/scottlamb/retina) src/lib.rs Timestamp, NtpTimestamp, WallTime

import Foundation

/// An annotated RTP timestamp.
///
/// Couples together:
/// - The stream's starting time (from RTSP RTP-Info header)
/// - The codec-specific clock rate (Hz)
/// - The full timestamp as an Int64 (extended from 32-bit RTP timestamp via wraparound tracking)
///
/// This allows conversion to "normal play time" (NPT): seconds since the start of the stream.
public struct Timestamp: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible
{
  /// A timestamp which must be compared to `start`.
  public let timestamp: Int64

  /// The codec-specified clock rate, in Hz. Must be non-zero.
  public let clockRate: UInt32

  /// The stream's starting time, as specified in the RTSP RTP-Info header.
  public let start: UInt32

  /// Creates a new timestamp unless `timestamp - start` underflows.
  public init?(timestamp: Int64, clockRate: UInt32, start: UInt32) {
    guard clockRate > 0 else { return nil }
    // Check that timestamp - start doesn't underflow Int64
    guard timestamp.subtractingReportingOverflow(Int64(start)).overflow == false else {
      return nil
    }
    self.timestamp = timestamp
    self.clockRate = clockRate
    self.start = start
  }

  /// Elapsed time since the stream start in clock rate units.
  public var elapsed: Int64 {
    timestamp - Int64(start)
  }

  /// Elapsed time since the stream start in seconds (normal play time / NPT).
  public var elapsedSeconds: Double {
    Double(elapsed) / Double(clockRate)
  }

  /// Returns `self + delta` unless it would overflow.
  public func adding(_ delta: UInt32) -> Timestamp? {
    let (newTimestamp, overflow) = timestamp.addingReportingOverflow(Int64(delta))
    guard !overflow else { return nil }
    return Timestamp(timestamp: newTimestamp, clockRate: clockRate, start: start)
  }

  public var description: String {
    let mod32 = UInt32(truncatingIfNeeded: timestamp)
    return "\(timestamp) (mod-2^32: \(mod32)), npt \(String(format: "%.03f", elapsedSeconds))"
  }

  public var debugDescription: String {
    description
  }
}

/// The Unix epoch as an NTP timestamp.
/// NTP epoch is 1900-01-01, Unix epoch is 1970-01-01, difference is 2,208,988,800 seconds.
public let ntpUnixEpoch = NtpTimestamp(rawValue: 2_208_988_800 << 32)

/// A wallclock time in Network Time Protocol format.
///
/// Fixed-point representation: top 32 bits are integer seconds since 1900-01-01,
/// bottom 32 bits are fractional seconds.
public struct NtpTimestamp: Sendable, Equatable, Comparable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }

  /// Convert to a Foundation Date (assumes time is within 68 years of 1970).
  public var date: Date {
    let sinceEpoch = rawValue &- ntpUnixEpoch.rawValue
    let seconds = Double(sinceEpoch >> 32)
    let fraction = Double(sinceEpoch & 0xFFFF_FFFF) / Double(UInt64(1) << 32)
    return Date(timeIntervalSince1970: seconds + fraction)
  }

  public var description: String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  public var debugDescription: String {
    "\(rawValue) /* \(description) */"
  }

  public static func < (lhs: NtpTimestamp, rhs: NtpTimestamp) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// A wall time taken from the local machine's realtime clock, used in error reporting.
public struct WallTime: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  public let date: Date

  public init() {
    self.date = Date()
  }

  public init(date: Date) {
    self.date = date
  }

  public static func now() -> WallTime {
    WallTime()
  }

  public var description: String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  public var debugDescription: String {
    description
  }
}
