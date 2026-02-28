// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/client/parse.rs parse_describe()

import Foundation

/// Parse a DESCRIBE response into a Presentation.
///
/// Ports upstream `parse_describe()` from parse.rs lines 414-499.
///
/// - Parameters:
///   - requestURL: The original DESCRIBE request URL
///   - response: The parsed RTSP response
/// - Returns: A Presentation with all parsed streams
func parseDescribe(
  requestURL: String,
  response: RTSPResponse
) throws -> Presentation {
  // Validate content type (warn if missing, error if wrong)
  if let ct = response.contentType {
    let lower = ct.lowercased()
    if !lower.starts(with: "application/sdp") {
      throw RTSPError.invalidSDP("Unexpected Content-Type: \(ct)")
    }
  }
  // Note: upstream logs a warning for missing Content-Type but still continues

  // Determine base URL from Content-Base or Content-Location header
  let baseURL =
    response.header("Content-Base")?.trimmingCharacters(in: .whitespaces)
    ?? response.header("Content-Location")?.trimmingCharacters(in: .whitespaces)
    ?? requestURL

  // Parse SDP body
  guard !response.body.isEmpty else {
    throw RTSPError.invalidSDP("Empty SDP body")
  }

  let sdpParser = SDPParser()
  let sdp = try sdpParser.parse(response.body)

  // Extract session-level attributes
  var sessionControl = baseURL
  var tool: String?

  for attr in sdp.attributes {
    switch attr.name {
    case "control":
      if let value = attr.value {
        sessionControl = joinControl(base: baseURL, control: value)
      }
    case "tool":
      tool = attr.value
    default:
      break
    }
  }

  // Parse each media description into a Stream
  var streams: [Stream] = []
  var errors: [String] = []

  for mediaDesc in sdp.mediaDescriptions {
    do {
      let stream = try parseMedia(baseURL: baseURL, mediaDescription: mediaDesc)
      streams.append(stream)
    } catch {
      errors.append(error.localizedDescription)
    }
  }

  guard !streams.isEmpty else {
    throw RTSPError.invalidSDP(
      "No parseable streams in SDP. Errors: \(errors.joined(separator: "; "))")
  }

  return Presentation(
    streams: streams,
    baseURL: baseURL,
    control: sessionControl,
    tool: tool
  )
}
