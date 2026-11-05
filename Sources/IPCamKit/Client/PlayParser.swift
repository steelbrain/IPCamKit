// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/client/parse.rs parse_play() and parse_options()

import Foundation

/// Parse a PLAY response, updating stream states with RTP-Info data.
///
/// Ports upstream `parse_play()` from parse.rs lines 617-700.
///
/// The RTP-Info header format:
/// `url=<url>;seq=<seq>;rtptime=<rtptime>,url=<url2>;seq=<seq2>;rtptime=<rtptime2>`
///
/// RTP-Info is advisory: a `seq`, `rtptime` or `ssrc` value that doesn't parse
/// is ignored as if the entry hadn't carried it, and the entry's other values
/// still apply. Doesn't throw; the signature keeps `throws` for its callers.
func parsePlay(
  response: RTSPResponse,
  presentation: inout Presentation
) throws {
  // A server may send one RTP-Info line per stream; repeated lines of a list
  // header are one list (RFC 2616 section 4.2).
  let rtpInfoLines = response.headers(named: "RTP-Info")
  guard !rtpInfoLines.isEmpty else {
    return  // No RTP-Info is acceptable
  }
  let rtpInfo = rtpInfoLines.joined(separator: ",")

  // Resolved control URL -> index of the first stream with it, built on the
  // first entry that needs it, so matching costs one lookup per entry rather
  // than a scan of every stream.
  var streamIndexByControl: [String: Int]?

  // A server sends one entry per stream. Entries past twice the stream
  // count (at least 128) are ignored, so a 64 KB header of tiny entries
  // can't cost a URL join and lookup each.
  let maxEntries = 2 * max(presentation.streams.count, maxMediaSections)
  for entry in splitRTPInfo(rtpInfo).prefix(maxEntries) {
    let entry = String(entry).trimmingCharacters(in: .whitespaces)
    if entry.isEmpty { continue }

    // Parse key=value pairs separated by semicolons
    var url: String?
    var seq: UInt16?
    var rtptime: UInt32?
    var ssrc: UInt32?

    for part in splitOutsideQuotes(entry[...], separator: ";") {
      let part = String(part).trimmingCharacters(in: .whitespaces)
      if part.isEmpty { continue }

      let kv = part.split(separator: "=", maxSplits: 1)
      guard kv.count == 2 else { continue }

      let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
      let value = String(kv[1]).trimmingCharacters(in: .whitespaces)

      switch key {
      case "url":
        // RFC 7826 quotes the URL; RFC 2326 doesn't.
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
          url = String(value.dropFirst().dropLast())
        } else {
          url = value
        }
      case "seq":
        // An unparseable seq is treated as missing.
        if let parsedSeq = UInt16(value) {
          seq = parsedSeq
        }
      case "rtptime":
        // Negative or unparseable rtptime values are treated as missing (some
        // cameras send negative ones).
        if let intVal = Int64(value), intVal >= 0 {
          rtptime = UInt32(intVal & 0xFFFF_FFFF)
        }
      case "ssrc":
        // An unparseable ssrc is treated as missing.
        if let ssrcVal = UInt32(value, radix: 16) {
          ssrc = ssrcVal
        }
      default:
        break
      }
    }

    // Find matching stream.
    // Upstream joins the URL with base_url then does exact match (parse.rs line 634).
    let streamIndex: Int?
    if presentation.streams.count == 1 {
      // Single stream: always use it regardless of URL (parse.rs lines 635-644)
      streamIndex = 0
    } else if let url = url {
      if streamIndexByControl == nil {
        var byControl: [String: Int] = [:]
        for (index, stream) in presentation.streams.enumerated() {
          guard let control = stream.control, byControl[control] == nil else { continue }
          byControl[control] = index
        }
        streamIndexByControl = byControl
      }
      let joinedURL = joinControl(base: presentation.baseURL, control: url)
      streamIndex = streamIndexByControl?[joinedURL]
    } else {
      streamIndex = nil
    }

    guard let idx = streamIndex else { continue }

    // Update stream state — only update streams already in setup state.
    // Upstream skips uninit streams (parse.rs lines 659-668).
    switch presentation.streams[idx].state {
    case .uninit:
      // Stream not yet set up — skip (matches upstream behavior)
      continue
    case .setup(var init_):
      if let seq = seq { init_.initialSeq = seq }
      if let rtptime = rtptime { init_.initialRtptime = rtptime }
      if let ssrc = ssrc { init_.ssrc = ssrc }
      presentation.streams[idx].state = .setup(init_)
    case .playing:
      break
    }
  }
}

/// Split an RTP-Info header into per-stream entries.
///
/// A URL may itself contain commas (`url=rtsp://h/s/track1?a=1,2;seq=10`) or be
/// quoted (RFC 7826), so an entry ends only at a comma outside double quotes
/// that is followed, after optional blanks, by `url=`. A header with no `url=`
/// at all is split on every comma.
func splitRTPInfo(_ header: String) -> [Substring] {
  guard header.range(of: "url=", options: .caseInsensitive) != nil else {
    return header.split(separator: ",")
  }
  var entries: [Substring] = []
  var entryStart = header.startIndex
  var inQuotes = false
  var i = header.startIndex
  while i < header.endIndex {
    let ch = header[i]
    let next = header.index(after: i)
    if ch == "\"" {
      inQuotes.toggle()
    } else if ch == ",", !inQuotes {
      let rest = header[next...].drop(while: { $0 == " " || $0 == "\t" })
      if rest.prefix(4).lowercased() == "url=" {
        entries.append(header[entryStart..<i])
        entryStart = next
      }
    }
    i = next
  }
  entries.append(header[entryStart...])
  return entries
}

/// Split `s` on `separator` where it appears outside double quotes.
func splitOutsideQuotes(_ s: Substring, separator: Character) -> [Substring] {
  var parts: [Substring] = []
  var partStart = s.startIndex
  var inQuotes = false
  var i = s.startIndex
  while i < s.endIndex {
    let ch = s[i]
    if ch == "\"" {
      inQuotes.toggle()
    } else if ch == separator, !inQuotes {
      parts.append(s[partStart..<i])
      partStart = s.index(after: i)
    }
    i = s.index(after: i)
  }
  parts.append(s[partStart...])
  return parts
}

/// Parse an OPTIONS response.
///
/// Ports upstream `parse_options()` from parse.rs lines 709-729.
func parseOptions(response: RTSPResponse) -> OptionsResponse {
  var setParamSupported = false
  var getParamSupported = false

  // Repeated `Public` lines are one list (RFC 2616 section 4.2).
  for publicHeader in response.headers(named: "Public") {
    for method in publicHeader.split(separator: ",") {
      let trimmed = method.trimmingCharacters(in: .whitespaces).uppercased()
      switch trimmed {
      case "SET_PARAMETER":
        setParamSupported = true
      case "GET_PARAMETER":
        getParamSupported = true
      default:
        break
      }
    }
  }

  return OptionsResponse(
    setParameterSupported: setParamSupported,
    getParameterSupported: getParamSupported
  )
}
