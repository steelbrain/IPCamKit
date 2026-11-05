// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/client/parse.rs parse_media() and static payload types

import Foundation

/// Static RTP payload type definition.
struct StaticPayloadType {
  let media: String
  let encoding: String
  let clockRate: UInt32
  let channels: UInt16?
}

/// Static payload types table per RFC 3551.
/// Index is the payload type number (0-34).
let staticPayloadTypes: [Int: StaticPayloadType] = [
  0: StaticPayloadType(media: "audio", encoding: "pcmu", clockRate: 8000, channels: 1),
  3: StaticPayloadType(media: "audio", encoding: "gsm", clockRate: 8000, channels: 1),
  4: StaticPayloadType(media: "audio", encoding: "g723", clockRate: 8000, channels: 1),
  5: StaticPayloadType(media: "audio", encoding: "dvi4", clockRate: 8000, channels: 1),
  6: StaticPayloadType(media: "audio", encoding: "dvi4", clockRate: 16000, channels: 1),
  7: StaticPayloadType(media: "audio", encoding: "lpc", clockRate: 8000, channels: 1),
  8: StaticPayloadType(media: "audio", encoding: "pcma", clockRate: 8000, channels: 1),
  9: StaticPayloadType(media: "audio", encoding: "g722", clockRate: 8000, channels: 1),
  10: StaticPayloadType(media: "audio", encoding: "l16", clockRate: 44_100, channels: 2),
  11: StaticPayloadType(media: "audio", encoding: "l16", clockRate: 44_100, channels: 1),
  12: StaticPayloadType(media: "audio", encoding: "qcelp", clockRate: 8000, channels: 1),
  13: StaticPayloadType(media: "audio", encoding: "cn", clockRate: 8000, channels: 1),
  14: StaticPayloadType(media: "audio", encoding: "mpa", clockRate: 90000, channels: nil),
  15: StaticPayloadType(media: "audio", encoding: "g728", clockRate: 8000, channels: 1),
  16: StaticPayloadType(media: "audio", encoding: "dvi4", clockRate: 11025, channels: 1),
  17: StaticPayloadType(media: "audio", encoding: "dvi4", clockRate: 22050, channels: 1),
  18: StaticPayloadType(media: "audio", encoding: "g729", clockRate: 8000, channels: 1),
  25: StaticPayloadType(media: "video", encoding: "celb", clockRate: 90000, channels: nil),
  26: StaticPayloadType(media: "video", encoding: "jpeg", clockRate: 90000, channels: nil),
  28: StaticPayloadType(media: "video", encoding: "nv", clockRate: 90000, channels: nil),
  31: StaticPayloadType(media: "video", encoding: "h261", clockRate: 90000, channels: nil),
  32: StaticPayloadType(media: "video", encoding: "mpv", clockRate: 90000, channels: nil),
  33: StaticPayloadType(media: "video", encoding: "mp2t", clockRate: 90000, channels: nil),
  34: StaticPayloadType(media: "video", encoding: "h263", clockRate: 90000, channels: nil),
]

/// Parse a media description from an SDP media section into a Stream.
///
/// Ports upstream `parse_media()` from parse.rs lines 221-385.
func parseMedia(
  baseURL: String,
  mediaDescription: SDPMediaDescription
) throws -> Stream {
  let media = mediaDescription.media
  // For messages: the media type as the server wrote it, cut short.
  let shownMedia = cutForMessage(media)

  // Validate protocol contains "RTP/"
  let proto = mediaDescription.proto.uppercased()
  guard proto.contains("RTP/") || proto.contains("MP2T/") else {
    throw RTSPError.invalidSDP(
      "Unsupported protocol \(cutForMessage(mediaDescription.proto)) for \(shownMedia)")
  }

  // Get first payload type from fmt field (tolerate tab/space separators).
  // Only the first is used; the list itself isn't split (it can be 2 MiB).
  let firstFmt = mediaDescription.fmt.drop(while: { $0 == " " || $0 == "\t" })
    .prefix(while: { $0 != " " && $0 != "\t" })
  guard !firstFmt.isEmpty else {
    throw RTSPError.invalidSDP("Empty fmt in media line")
  }
  guard let payloadType = UInt8(firstFmt.trimmingCharacters(in: .whitespaces)),
    payloadType & 0x80 == 0
  else {
    throw RTSPError.invalidSDP("Invalid payload type: \(cutForMessage(firstFmt))")
  }

  // Extract attributes
  var rtpmap: String?
  var fmtp: String?
  var controlValue: String?
  var framerate: Float?
  var direction: MediaDirection?
  var keyMgmt: String?

  for attr in mediaDescription.attributes {
    if let parsed = MediaDirection(rawValue: attr.name) {
      direction = parsed
      continue
    }
    switch attr.name {
    case "rtpmap":
      if let value = attr.value {
        // Match only the rtpmap for our payload type
        let parts = value.split(separator: " ", maxSplits: 1)
        if parts.count >= 2 {
          let pt = parts[0].trimmingCharacters(in: .whitespaces)
          if pt == String(payloadType) {
            rtpmap = String(parts[1]).trimmingCharacters(in: .whitespaces)
          }
        }
      }
    case "fmtp":
      if let value = attr.value {
        // Match only the fmtp for our payload type
        let parts = value.split(separator: " ", maxSplits: 1)
        if parts.count >= 2 {
          let pt = parts[0].trimmingCharacters(in: .whitespaces)
          if pt == String(payloadType) {
            fmtp = String(parts[1]).trimmingCharacters(in: .whitespaces)
          }
        }
      }
    case "control":
      if let value = attr.value?.trimmingCharacters(in: .whitespaces) {
        // The control URL goes on SETUP's request line; a space or control
        // character there would split or inject into the request.
        guard !hasUnsafeURLCharacters(value) else {
          throw RTSPError.invalidSDP(
            "Invalid control URL \(quotedForMessage(value)) for \(shownMedia)")
        }
        guard value.utf8.count <= maxControlURLBytes else {
          throw RTSPError.invalidSDP(
            "Control URL for \(shownMedia) is longer than \(maxControlURLBytes) bytes")
        }
        // The last a=control wins; it is joined to the base once, below.
        controlValue = value
      }
    case "framerate":
      if let value = attr.value {
        framerate = Float(value.trimmingCharacters(in: .whitespaces))
      }
    case "key-mgmt":
      keyMgmt = attr.value?.trimmingCharacters(in: .whitespaces)
    default:
      break
    }
  }

  // Resolve encoding, clock rate, and channels
  var encodingName: String
  var clockRate: UInt32
  var channels: UInt16?

  if let rtpmap = rtpmap {
    // Parse rtpmap: "encoding/clockRate[/channels]"
    // encoding/clockRate[/channels]: nothing after a 3rd part is read.
    let parts = Array(rtpmap.lazySplit(separator: "/").prefix(3))
    guard parts.count >= 2 else {
      throw RTSPError.invalidSDP("Invalid rtpmap: \(cutForMessage(rtpmap))")
    }
    encodingName = String(parts[0]).lowercased()
    guard let rate = UInt32(parts[1].trimmingCharacters(in: .whitespaces)) else {
      throw RTSPError.invalidSDP("Invalid clock rate in rtpmap: \(cutForMessage(rtpmap))")
    }
    clockRate = rate
    if parts.count >= 3 {
      channels = UInt16(parts[2].trimmingCharacters(in: .whitespaces))
    }
  } else if let staticType = staticPayloadTypes[Int(payloadType)] {
    // Use static payload type lookup
    encodingName = staticType.encoding
    clockRate = staticType.clockRate
    channels = staticType.channels
  } else {
    throw RTSPError.invalidSDP(
      "No rtpmap for dynamic payload type \(payloadType)")
  }

  var stream = Stream(
    media: media,
    encodingName: encodingName,
    rtpPayloadType: payloadType,
    clockRateHz: clockRate,
    channels: channels,
    framerate: framerate,
    control: controlValue.map { joinControl(base: baseURL, control: $0) },
    formatSpecificParams: fmtp,
    direction: direction
  )
  stream.keyMgmt = keyMgmt
  return stream
}

/// Join a control URL to a base URL.
///
/// Matches upstream `join_control()` from parse.rs lines 190-209.
/// - The control value is trimmed of surrounding blanks.
/// - `"*"` returns base_url
/// - Absolute URLs (any scheme, see `hasURIScheme`) are returned as-is
/// - An absolute path (`/other/track1`) replaces the base URL's path, and a
///   network-path reference (`//host/path`) keeps only its scheme (RFC 3986 5.2)
/// - Other relative URLs are appended to base_url with proper "/" handling.
///   RTSP treats the base as a directory, and plain appending keeps Dahua's
///   query-string bases (`.../realmonitor?channel=1&subtype=0/` + `trackID=0`)
///   working, which RFC 3986 merging would not.
func joinControl(base: String, control rawControl: String) -> String {
  let control = rawControl.trimmingCharacters(in: .whitespaces)
  if control == "*" {
    return base
  }
  if hasURIScheme(control) {
    return control
  }
  if control.hasPrefix("/"), hasURIScheme(base), let colon = base.firstIndex(of: ":"),
    base[colon...].hasPrefix("://")
  {
    if control.hasPrefix("//") {
      return base[..<colon] + ":" + control
    }
    // Scanned as bytes: a base can be 8 KB, and Character iteration is slow.
    let authority = base.utf8[base.utf8.index(colon, offsetBy: 3)...]
    let authorityEnd =
      authority.firstIndex(where: {
        $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "#")
      })
      ?? base.endIndex
    return String(base[..<authorityEnd]) + control
  }
  // Join relative URL
  var baseStr = base
  if !baseStr.hasSuffix("/") {
    baseStr += "/"
  }
  return baseStr + (control.hasPrefix("/") ? control.dropFirst() : control[...])
}

/// Whether a server-supplied URL (a `Content-Base` or an `a=control` value)
/// holds a space, control character or DEL, any of which would split or inject
/// into the request line it ends up on.
func hasUnsafeURLCharacters(_ value: String) -> Bool {
  value.unicodeScalars.contains { $0.value <= 0x20 || $0.value == 0x7F }
}

/// A server-supplied `value` for a diagnostic or error message: its first 80
/// Unicode scalars, quoted and escaped, then `…` if there are more. A
/// megabyte of control characters would otherwise make a 6 MB message.
func quotedForMessage(_ value: some StringProtocol) -> String {
  let scalars = value.unicodeScalars
  let shown = String(String.UnicodeScalarView(scalars.prefix(80))).debugDescription
  return scalars.dropFirst(80).isEmpty ? shown : shown + "…"
}

/// A server-supplied token (an `m=` line field) for a diagnostic or error
/// message: its first 80 Unicode scalars, then `…` if there are more.
/// Scalars rather than Characters: one Character can hold any number of
/// combining marks.
func cutForMessage(_ value: some StringProtocol) -> String {
  let scalars = value.unicodeScalars
  let shown = String(String.UnicodeScalarView(scalars.prefix(80)))
  return scalars.dropFirst(80).isEmpty ? shown : shown + "…"
}

/// Per-section entries (each already cut) for one diagnostic or error
/// message: the first three joined by `separator`, then `and N more`. An SDP
/// of 64 media sections would otherwise make a 10 KB message.
func listForMessage(_ items: [String], separator: String = ", ") -> String {
  guard items.count > 3 else { return items.joined(separator: separator) }
  return items.prefix(3).joined(separator: separator) + separator + "and \(items.count - 3) more"
}
