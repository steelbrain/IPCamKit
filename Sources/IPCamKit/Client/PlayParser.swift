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
func parsePlay(
  response: RTSPResponse,
  presentation: inout Presentation
) throws {
  guard let rtpInfo = response.header("RTP-Info") else {
    return  // No RTP-Info is acceptable
  }

  // Split by comma to get per-stream entries
  let entries = rtpInfo.split(separator: ",")

  for entry in entries {
    let entry = String(entry).trimmingCharacters(in: .whitespaces)
    if entry.isEmpty { continue }

    // Parse key=value pairs separated by semicolons
    var url: String?
    var seq: UInt16?
    var rtptime: UInt32?
    var ssrc: UInt32?

    for part in entry.split(separator: ";") {
      let part = String(part).trimmingCharacters(in: .whitespaces)
      if part.isEmpty { continue }

      let kv = part.split(separator: "=", maxSplits: 1)
      guard kv.count == 2 else { continue }

      let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
      let value = String(kv[1]).trimmingCharacters(in: .whitespaces)

      switch key {
      case "url":
        url = value
      case "seq":
        guard let parsedSeq = UInt16(value) else {
          throw RTSPError.sessionSetupFailed(statusCode: 0, reason: "bad seq \"\(value)\"")
        }
        seq = parsedSeq
      case "rtptime":
        // Negative rtptime values are treated as missing (some cameras send them)
        if let intVal = Int64(value), intVal >= 0 {
          rtptime = UInt32(intVal & 0xFFFF_FFFF)
        }
      case "ssrc":
        guard let ssrcVal = UInt32(value, radix: 16) else {
          throw RTSPError.sessionSetupFailed(statusCode: 0, reason: "Unparseable ssrc \(value)")
        }
        ssrc = ssrcVal
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
      let joinedURL = joinControl(base: presentation.baseURL, control: url)
      streamIndex = presentation.streams.firstIndex { stream in
        guard let control = stream.control else { return false }
        return control == joinedURL
      }
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

/// Parse an OPTIONS response.
///
/// Ports upstream `parse_options()` from parse.rs lines 709-729.
func parseOptions(response: RTSPResponse) -> OptionsResponse {
  var setParamSupported = false
  var getParamSupported = false

  if let publicHeader = response.header("Public") {
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
