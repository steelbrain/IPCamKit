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
  10: StaticPayloadType(media: "audio", encoding: "l16", clockRate: 441_000, channels: 2),
  11: StaticPayloadType(media: "audio", encoding: "l16", clockRate: 441_000, channels: 1),
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

  // Validate protocol contains "RTP/"
  let proto = mediaDescription.proto.uppercased()
  guard proto.contains("RTP/") || proto.contains("MP2T/") else {
    throw RTSPError.invalidSDP(
      "Unsupported protocol \(mediaDescription.proto) for \(media)")
  }

  // Get first payload type from fmt field
  let fmtParts = mediaDescription.fmt.split(separator: " ")
  guard let firstFmt = fmtParts.first else {
    throw RTSPError.invalidSDP("Empty fmt in media line")
  }
  guard let payloadType = UInt8(firstFmt.trimmingCharacters(in: .whitespaces)),
    payloadType & 0x80 == 0
  else {
    throw RTSPError.invalidSDP("Invalid payload type: \(firstFmt)")
  }

  // Extract attributes
  var rtpmap: String?
  var fmtp: String?
  var controlURL: String?
  var framerate: Float?

  for attr in mediaDescription.attributes {
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
      if let value = attr.value {
        controlURL = joinControl(base: baseURL, control: value)
      }
    case "framerate":
      if let value = attr.value {
        framerate = Float(value.trimmingCharacters(in: .whitespaces))
      }
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
    let parts = rtpmap.split(separator: "/")
    guard parts.count >= 2 else {
      throw RTSPError.invalidSDP("Invalid rtpmap: \(rtpmap)")
    }
    encodingName = String(parts[0]).lowercased()
    guard let rate = UInt32(parts[1].trimmingCharacters(in: .whitespaces)) else {
      throw RTSPError.invalidSDP("Invalid clock rate in rtpmap: \(rtpmap)")
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

  return Stream(
    media: media,
    encodingName: encodingName,
    rtpPayloadType: payloadType,
    clockRateHz: clockRate,
    channels: channels,
    framerate: framerate,
    control: controlURL,
    formatSpecificParams: fmtp
  )
}

/// Join a control URL to a base URL.
///
/// Join a control URL to a base URL.
///
/// Matches upstream `join_control()` from parse.rs lines 190-209.
/// Uses URL parsing to detect absolute URLs (not just rtsp:// scheme).
/// - `"*"` returns base_url
/// - Absolute URLs (any scheme detected by URL parser) are returned as-is
/// - Relative URLs are appended to base_url with proper "/" handling
func joinControl(base: String, control: String) -> String {
  if control == "*" {
    return base
  }
  // Use URLComponents to detect absolute URLs (matches Url::parse behavior)
  if let parsed = URLComponents(string: control), parsed.scheme != nil {
    return control
  }
  // Join relative URL
  var baseStr = base
  if !baseStr.hasSuffix("/") {
    baseStr += "/"
  }
  return baseStr + control
}
