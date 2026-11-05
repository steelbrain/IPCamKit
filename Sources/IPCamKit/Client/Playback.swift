// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Playback control (PLAY options, ONVIF replay), ONVIF feature selection, and
// control-connection tunnels.

import Foundation

/// ONVIF RTSP extensions a session asks the server for. Each one is sent as an
/// RTSP `Require` feature tag on DESCRIBE, SETUP, PLAY and PAUSE. A server that
/// doesn't support one answers `551 Option not supported`: for `.backchannel`,
/// `start()` repeats DESCRIBE without it and reports that via `onDiagnostic`;
/// otherwise it throws `RTSPError.sessionSetupFailed(statusCode: 551, ...)`.
public struct ONVIFFeatures: OptionSet, Sendable, Hashable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  /// ONVIF replay of recordings (`Require: onvif-replay`). Use it with the
  /// replay URI from the ONVIF Replay service (`GetReplayUri`); frames then
  /// carry `ReplayInfo` with the recording time, and `PlayOptions` can seek by
  /// absolute time, change speed or direction, and skip frames.
  public static let replay = ONVIFFeatures(rawValue: 1 << 0)

  /// ONVIF two-way audio (`Require: www.onvif.org/ver20/backchannel`). The
  /// camera's SDP then includes an audio stream marked `a=sendonly`, which the
  /// session sets up so `RTSPClientSession.sendBackchannelAudio` can send to it.
  public static let backchannel = ONVIFFeatures(rawValue: 1 << 1)

  /// The `Require` header value for these features, or nil when empty.
  var requireHeaderValue: String? {
    var tags: [String] = []
    if contains(.replay) { tags.append("onvif-replay") }
    if contains(.backchannel) { tags.append("www.onvif.org/ver20/backchannel") }
    return tags.isEmpty ? nil : tags.joined(separator: ", ")
  }
}

/// Carries the RTSP control connection, and the media interleaved on it,
/// through HTTP or WebSocket when a direct connection to the RTSP port isn't
/// possible (proxies, firewalls, browsers). Tunnels require `Transport.tcp`.
public enum RTSPTunnel: Sendable {
  /// RTSP over HTTP (Apple's QuickTime tunneling): a GET connection carries
  /// server-to-client bytes and a POST connection carries base64-encoded
  /// client-to-server bytes, paired by an `x-sessioncookie` header. `http://`
  /// or `https://`; HTTPS uses the session's `TLSOptions`. The RTSP requests
  /// inside the tunnel still use the session's `rtsp://` URL.
  case http(URL)

  /// RTSP over WebSocket (ONVIF Streaming Specification, subprotocol
  /// `rtsp.onvif.org`). `ws://` or `wss://`; WSS uses the session's
  /// `TLSOptions`. ONVIF devices report this URL as the Media2 service's
  /// `RTSPWebSocketUri` capability.
  case webSocket(URL)

  /// Whether the tunnel URL's scheme is `https` or `wss`.
  var usesTLS: Bool {
    switch self {
    case .http(let url): return url.scheme?.lowercased() == "https"
    case .webSocket(let url): return url.scheme?.lowercased() == "wss"
    }
  }
}

/// A playback position range, sent as the RTSP `Range` header.
public enum PlaybackRange: Sendable, Equatable {
  /// Normal play time in seconds from the start of the presentation
  /// (`npt=10.000-20.000`). `end` nil plays to the end.
  case npt(start: Double, end: Double? = nil)

  /// Absolute UTC wall-clock time (`clock=20250101T120000.000Z-`), the form
  /// ONVIF replay uses to seek in a recording. `end` nil plays to the end.
  case clock(start: Date, end: Date? = nil)

  /// The `Range` header value.
  var headerValue: String {
    switch self {
    case .npt(let start, let end):
      return "npt=" + formatNPT(start) + "-" + (end.map(formatNPT) ?? "")
    case .clock(let start, let end):
      return "clock=" + formatClock(start) + "-" + (end.map(formatClock) ?? "")
    }
  }

  /// Parse an RTSP `Range` header or SDP `a=range` value in the `npt=` or
  /// `clock=` formats. Returns nil for other formats (e.g. `smpte=`), for
  /// `npt=now-`, for the end-only form (`npt=-10`, which `PlaybackRange` can't
  /// express), and for malformed values. Spaces may surround the value and
  /// the `=` (RFC 7826 `EQUAL`), but not a time or the `-`.
  static func parse(_ value: String) -> PlaybackRange? {
    // A `;time=` suffix (RFC 2326) is not part of the range itself.
    let range = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
    guard let equals = range.firstIndex(of: "=") else { return nil }
    let unit = range[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
    let spec = Substring(range[range.index(after: equals)...].trimmingCharacters(in: .whitespaces))
    let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    switch unit {
    case "npt":
      guard let start = parseNPT(parts[0]) else { return nil }
      let end = parts[1].isEmpty ? nil : parseNPT(parts[1])
      if !parts[1].isEmpty && end == nil { return nil }
      return .npt(start: start, end: end)
    case "clock":
      guard let start = parseClock(parts[0]) else { return nil }
      let end = parts[1].isEmpty ? nil : parseClock(parts[1])
      if !parts[1].isEmpty && end == nil { return nil }
      return .clock(start: start, end: end)
    default:
      return nil
    }
  }
}

/// Which frames the server sends during ONVIF replay (the `Frames` header).
public enum FrameFilter: Sendable, Equatable {
  /// Every frame (no `Frames` header).
  case all
  /// Key frames only (`Frames: intra`), e.g. for fast forward.
  case intra
  /// Key frames at most once per `interval` (`Frames: intra/<milliseconds>`).
  case intraEvery(Duration)
  /// Key frames and predicted frames, but no B-frames (`Frames: predicted`).
  case intraAndPredicted

  /// The `Frames` header value, or nil for `.all`.
  var headerValue: String? {
    switch self {
    case .all:
      return nil
    case .intra:
      return "intra"
    case .intraEvery(let interval):
      let (seconds, attoseconds) = interval.components
      // Clamp instead of overflowing for an absurdly long interval.
      let (wholeMillis, overflow) = max(0, seconds).multipliedReportingOverflow(by: 1000)
      let (milliseconds, sumOverflow) = wholeMillis.addingReportingOverflow(
        max(0, attoseconds) / 1_000_000_000_000_000)
      return "intra/\(overflow || sumOverflow ? Int64.max : milliseconds)"
    case .intraAndPredicted:
      return "predicted"
    }
  }
}

/// Options for an RTSP PLAY request: the initial one from
/// `RTSPClientSession.start(_:)` and later ones from `play(_:)`.
///
/// `scale`, `rateControl`, `frames` and `immediate` are the ONVIF replay
/// headers; most live cameras ignore or reject them.
public struct PlayOptions: Sendable {
  /// Where to play from (`Range`). nil: the first PLAY sends `npt=0.000-`,
  /// later ones send no `Range`, which resumes after a pause.
  public var range: PlaybackRange?

  /// Playback speed and direction (`Scale`): 2 plays twice as fast, -1 plays
  /// backwards at normal speed. nil sends no header (normal speed). The
  /// magnitude must be from 0.000001 to 1000; it is sent with up to six
  /// decimal places. For zero, NaN, an infinity or a value outside that
  /// range, `start(_:)` and `play(_:)` throw `RTSPError.invalidState` before
  /// sending anything.
  public var scale: Double?

  /// `false` sends `Rate-Control: no`: the server sends as fast as the
  /// connection allows instead of in real time, and the session applies
  /// backpressure when `frames()` is consumed slowly. Use with `Transport.tcp`.
  public var rateControl: Bool

  /// Which frames to send (`Frames`).
  public var frames: FrameFilter

  /// `true` sends `Immediate: yes`: a PLAY issued while playing replaces the
  /// current playback at once instead of queueing behind it. Use it to seek.
  public var immediate: Bool

  public init(
    range: PlaybackRange? = nil,
    scale: Double? = nil,
    rateControl: Bool = true,
    frames: FrameFilter = .all,
    immediate: Bool = false
  ) {
    self.range = range
    self.scale = scale
    self.rateControl = rateControl
    self.frames = frames
    self.immediate = immediate
  }

  /// The `scale` magnitudes accepted (see `scale`).
  static let scaleMagnitudes: ClosedRange<Double> = 0.000_001...1000

  /// Throws `RTSPError.invalidState` when `scale` is zero, not finite, or
  /// outside `scaleMagnitudes`.
  func validate() throws {
    // NaN is in no range.
    if let scale, !Self.scaleMagnitudes.contains(scale.magnitude) {
      throw RTSPError.invalidState(
        "PlayOptions.scale must be from 0.000001 to 1000 in magnitude, not \(scale)")
    }
  }

  /// The PLAY headers for these options. `isInitial` selects the default
  /// `Range: npt=0.000-` when `range` is nil. Throws as `validate()` does.
  func headers(isInitial: Bool) throws -> [(String, String)] {
    try validate()
    var headers: [(String, String)] = []
    if let range {
      headers.append(("Range", range.headerValue))
    } else if isInitial {
      headers.append(("Range", "npt=0.000-"))
    }
    if let scale {
      headers.append(("Scale", formatScale(scale)))
    }
    if !rateControl {
      headers.append(("Rate-Control", "no"))
    }
    if let frames = frames.headerValue {
      headers.append(("Frames", frames))
    }
    if immediate {
      headers.append(("Immediate", "yes"))
    }
    return headers
  }
}

/// Recording position of a replayed frame, from the ONVIF replay RTP header
/// extension the server attaches to each packet.
public struct ReplayInfo: Sendable, Equatable {
  /// Absolute UTC time at which the frame was recorded.
  public let time: Date

  /// The frame starts at a clean point (a key frame you can start decoding at).
  public let isCleanPoint: Bool

  /// The frame ends a contiguous section of the recording; the next frame, if
  /// any, belongs to a later section.
  public let isEndOfSection: Bool

  /// Data is missing between the previous frame and this one.
  public let isDiscontinuity: Bool

  /// The server marked this as the last frame of the playback (the `T` flag).
  public let isTerminal: Bool

  public init(
    time: Date, isCleanPoint: Bool, isEndOfSection: Bool, isDiscontinuity: Bool,
    isTerminal: Bool
  ) {
    self.time = time
    self.isCleanPoint = isCleanPoint
    self.isEndOfSection = isEndOfSection
    self.isDiscontinuity = isDiscontinuity
    self.isTerminal = isTerminal
  }
}

/// The ONVIF two-way audio stream the session set up, describing the audio
/// format `RTSPClientSession.sendBackchannelAudio` expects.
public struct BackchannelStream: Sendable {
  /// Codec the camera accepts. Send audio already encoded in it; for G.711
  /// (`.pcmu`/`.pcma`) `G711` encodes 16-bit PCM.
  public let codec: PublicAudioCodec
  /// RTP clock rate in Hz (the sample rate, except G.722 whose RTP clock is
  /// 8000 per RFC 3551).
  public let clockRate: UInt32
  /// Channel count, if the SDP gave one.
  public let channels: UInt16?
  /// RTP payload type the session sends with.
  public let payloadType: UInt8
  /// SDP `fmtp` parameters (e.g. the AAC `config`), if any.
  public let formatSpecificParams: String?
}

/// SDP media direction attribute.
public enum MediaDirection: String, Sendable {
  /// `a=sendonly`. In an ONVIF backchannel SDP this marks the stream the
  /// client sends to the camera.
  case sendOnly = "sendonly"
  /// `a=recvonly`: the client receives this stream.
  case receiveOnly = "recvonly"
  /// `a=sendrecv`.
  case sendReceive = "sendrecv"
  /// `a=inactive`.
  case inactive = "inactive"
}

// MARK: - Formatting helpers

/// Seconds as `12.345`.
private func formatNPT(_ seconds: Double) -> String {
  // `seconds > 0` also turns -0.0 (which `%.3f` writes as `-0.000`) into 0.
  String(format: "%.3f", seconds.isFinite && seconds > 0 ? seconds : 0)
}

/// Parse an npt time as RFC 2326 and RFC 7826 write it: seconds
/// (`1*DIGIT [ "." *DIGIT ]`, e.g. `12.5`) or `hh:mm:ss[.frac]` with any
/// number of hour digits and one or two digits of minutes and seconds, each
/// 0-59. Digits only: no sign, exponent, hex or spelled-out value.
private func parseNPT(_ value: Substring) -> Double? {
  func isDigits(_ part: Substring) -> Bool {
    !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
  }
  // `1*DIGIT [ "." *DIGIT ]`, with at most `maxWholeDigits` before the point.
  func decimal(_ part: Substring, maxWholeDigits: Int = .max) -> Double? {
    let pieces = part.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard isDigits(pieces[0]), pieces[0].count <= maxWholeDigits else { return nil }
    guard pieces.count == 2, !pieces[1].isEmpty else { return Double(pieces[0]) }
    guard isDigits(pieces[1]) else { return nil }
    return Double(part)
  }
  if value.contains(":") {
    // At most 3 parts kept: a 4th means the value is malformed.
    let parts = Array(value.lazySplit(separator: ":", omittingEmptySubsequences: false).prefix(4))
    // Minutes and whole seconds are checked as digits: 59.9999999999999999
    // seconds is valid, though as a Double it is 60.
    guard parts.count == 3, isDigits(parts[0]), let h = Double(parts[0]),
      isDigits(parts[1]), parts[1].count <= 2, let m = Double(parts[1]), m < 60,
      let s = decimal(parts[2], maxWholeDigits: 2),
      let wholeSeconds = Int(parts[2].prefix { $0 != "." }), wholeSeconds < 60
    else { return nil }
    let seconds = h * 3600 + m * 60 + s
    return seconds.isFinite ? seconds : nil
  }
  guard let seconds = decimal(value), seconds.isFinite else { return nil }
  return seconds
}

/// UTC time as `20250101T120000.000Z` (ISO 8601 basic format, RFC 2326 `clock=`).
/// Dates outside 1970...9999 (and non-finite ones) are clamped into that range,
/// which the four-digit year can express.
func formatClock(_ date: Date) -> String {
  let raw = date.timeIntervalSince1970
  let interval = raw.isFinite ? min(max(raw, 0), maxClockInterval) : 0
  var whole = interval.rounded(.down)
  var millis = Int(((interval - whole) * 1000).rounded())
  if millis >= 1000 {
    whole += 1
    millis -= 1000
  }
  var time = time_t(whole)
  var parts = tm()
  gmtime_r(&time, &parts)
  return String(
    format: "%04d%02d%02dT%02d%02d%02d.%03dZ",
    Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1, Int(parts.tm_mday),
    Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec), millis)
}

/// 9999-12-31T23:59:59.999Z, the latest time `formatClock` can write.
private let maxClockInterval: TimeInterval = 253_402_300_799.999

/// Parse `YYYYMMDDThhmmss[.fraction]Z` (RFC 7826 `utc-time`): a date that
/// exists in the proleptic Gregorian calendar in years 0001-9999, seconds
/// 00-59 (60 only at 23:59, for a leap second, read as the next midnight),
/// and up to 9 fraction digits. `T` and `Z` may be lowercase.
func parseClock(_ value: Substring) -> Date? {
  guard value.hasSuffix("Z") || value.hasSuffix("z") else { return nil }
  let pieces = value.dropLast().split(
    separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
  let main = Array(pieces[0].unicodeScalars)
  guard main.count == 15, main[8] == "T" || main[8] == "t" else { return nil }
  let digits = main[..<8] + main[9...]
  guard digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
  let numbers = digits.map { Int($0.value) - 48 }
  func field(_ offset: Int, _ length: Int) -> Int {
    numbers[offset..<offset + length].reduce(0) { $0 * 10 + $1 }
  }
  let (year, month, day) = (field(0, 4), field(4, 2), field(6, 2))
  let (hour, minute, second) = (field(8, 2), field(10, 2), field(12, 2))
  let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  let daysInMonth = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  // The calendar has no year 0 (1 BC is followed by AD 1).
  guard year >= 1, (1...12).contains(month), (1...daysInMonth[month - 1]).contains(day),
    (0...23).contains(hour), (0...59).contains(minute),
    (0...59).contains(second) || (second == 60 && hour == 23 && minute == 59)
  else { return nil }
  var fraction = 0.0
  if pieces.count == 2 {
    let frac = pieces[1]
    guard !frac.isEmpty, frac.count <= 9, frac.allSatisfy({ $0.isASCII && $0.isNumber }),
      let parsed = Double("0." + frac)
    else { return nil }
    fraction = parsed
  }
  // Days since 1970-01-01 (H. Hinnant's days_from_civil): `timegm` fails
  // for years before 1900.
  let shiftedYear = month <= 2 ? year - 1 : year
  let era = shiftedYear / 400
  let yearOfEra = shiftedYear - era * 400
  let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
  let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
  let days = era * 146_097 + dayOfEra - 719_468
  let seconds = days * 86_400 + hour * 3600 + minute * 60 + second
  return Date(timeIntervalSince1970: Double(seconds) + fraction)
}

/// A scale such as `2.0`, `-1.0` or `0.25`: six decimal places without the
/// trailing zeros, keeping one digit after the point, which fits both
/// `[ "-" ] 1*DIGIT [ "." *DIGIT ]` (RFC 2326) and `[ "-" ] 1*DIGIT
/// [ "." 1*DIGIT ]` (RFC 7826). `PlayOptions.validate()` keeps the magnitude
/// within 0.000001...1000, so the value is never `0.0` and stays short.
private func formatScale(_ scale: Double) -> String {
  var text = String(format: "%.6f", scale)
  while text.hasSuffix("0") && !text.hasSuffix(".0") { text.removeLast() }
  return text
}
