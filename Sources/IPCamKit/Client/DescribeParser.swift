// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/client/parse.rs parse_describe()

import Foundation

/// The most media sections of one SDP that are read; the rest are dropped
/// with one diagnostic. Cameras offer a handful, and every stream keeps its
/// own control URL for the session's lifetime, so a hostile SDP of thousands
/// of tiny media sections would otherwise hold gigabytes.
let maxMediaSections = 64

/// The longest `Content-Base`, `Content-Location` or `a=control` value used,
/// in UTF-8 bytes. A longer one is ignored like an unsafe one: each control
/// URL is built on the base and kept per stream.
let maxControlURLBytes = 8192

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
  response: RTSPResponse,
  onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)? = nil
) throws -> Presentation {
  // Validate content type (warn if missing, error if wrong)
  if let ct = response.contentType {
    let lower = ct.lowercased()
    if !lower.starts(with: "application/sdp") {
      throw RTSPError.invalidSDP("Unexpected Content-Type: \(cutForMessage(ct))")
    }
  }
  // Note: upstream logs a warning for missing Content-Type but still continues

  // Determine base URL from Content-Base or Content-Location header. Some
  // cameras (e.g. Anjvision) send a scheme-less value such as
  // "192.168.1.10:554/stream0/"; resolve those against the request URL's
  // scheme instead of rejecting them. Port of retina 6972ac4.
  // A value with a space or control character is ignored (with a diagnostic):
  // every control URL is built on it and sent on a request line.
  var contentBase: String?
  for name in ["Content-Base", "Content-Location"] {
    // An empty value says nothing; fall through to the next header or the
    // request URL rather than building control URLs on "rtsp://".
    guard let value = response.header(name)?.trimmingCharacters(in: .whitespaces),
      !value.isEmpty
    else {
      continue
    }
    if hasUnsafeURLCharacters(value) {
      onDiagnostic?(
        RTSPDiagnostic(
          severity: .warning,
          message: "Ignoring \(name) with a space or control character: "
            + quotedForMessage(value)))
      continue
    }
    if value.utf8.count > maxControlURLBytes {
      onDiagnostic?(
        RTSPDiagnostic(
          severity: .warning,
          message: "Ignoring \(name) longer than \(maxControlURLBytes) bytes"))
      continue
    }
    contentBase = value
    break
  }
  let baseURL: String
  if let raw = contentBase {
    if hasURIScheme(raw) {
      baseURL = raw
    } else if raw.hasPrefix("/") {
      // A relative Content-Location is relative to the Request-URI (RFC 2326
      // 12.15, RFC 2616 14.14). Only a value starting with "/" is resolved
      // here, keeping the request URL's scheme and authority; "ch0/" can't be
      // told apart from the scheme-less host form below.
      baseURL = joinControl(base: requestURL, control: raw)
    } else {
      let scheme = requestURL.prefix(while: { $0 != ":" })
      baseURL = scheme.isEmpty ? raw : "\(scheme)://\(raw)"
    }
  } else {
    baseURL = requestURL
  }

  // Parse SDP body
  guard !response.body.isEmpty else {
    throw RTSPError.invalidSDP("Empty SDP body")
  }

  let sdp = try SDPParser(mediaLimit: maxMediaSections).parse(response.body)

  // Extract session-level attributes
  var sessionControl = baseURL
  var tool: String?
  var range: String?
  var sessionDirection: MediaDirection?
  var sessionKeyMgmt: String?
  // Only the first ignored session a=control is reported, with a count of
  // the rest: an SDP can repeat the line a hundred thousand times.
  var ignoredSessionControl: String?
  var ignoredSessionControls = 0
  // The last usable session a=control wins; it is joined to the base once,
  // after the loop, as an SDP can repeat the line a hundred thousand times.
  var sessionControlValue: String?

  for attr in sdp.attributes {
    if let parsed = MediaDirection(rawValue: attr.name) {
      sessionDirection = parsed
      continue
    }
    switch attr.name {
    case "control":
      if let value = attr.value?.trimmingCharacters(in: .whitespaces) {
        if hasUnsafeURLCharacters(value) || value.utf8.count > maxControlURLBytes {
          ignoredSessionControls += 1
          if ignoredSessionControl == nil {
            ignoredSessionControl =
              hasUnsafeURLCharacters(value)
              ? "Ignoring session a=control with a space or control character: "
                + quotedForMessage(value)
              : "Ignoring session a=control longer than \(maxControlURLBytes) bytes"
          }
          continue
        }
        sessionControlValue = value
      }
    case "tool":
      tool = attr.value
    case "range":
      range = attr.value?.trimmingCharacters(in: .whitespaces)
    case "key-mgmt":
      sessionKeyMgmt = attr.value?.trimmingCharacters(in: .whitespaces)
    default:
      break
    }
  }

  if let sessionControlValue {
    sessionControl = joinControl(base: baseURL, control: sessionControlValue)
  }
  if let message = ignoredSessionControl {
    let more = ignoredSessionControls - 1
    onDiagnostic?(
      RTSPDiagnostic(
        severity: .warning,
        message: more > 0 ? message + " (and \(more) more session a=control lines)" : message))
  }

  // Parse each media description into a Stream
  var streams: [Stream] = []
  var errors: [String] = []

  // Media sections whose m= line couldn't be parsed were left out by the SDP
  // parser; report them like the streams dropped below.
  for error in sdp.skippedMediaErrors {
    errors.append(error)
    onDiagnostic?(
      RTSPDiagnostic(
        severity: .warning,
        message: "Dropping unparseable media section from SDP: \(error)"))
  }

  for mediaDesc in sdp.mediaDescriptions {
    do {
      var stream = try parseMedia(baseURL: baseURL, mediaDescription: mediaDesc)
      // Session-level direction and key management apply to every media
      // section that doesn't override them (RFC 8866 6.7, RFC 4567).
      if stream.direction == nil { stream.direction = sessionDirection }
      if stream.keyMgmt == nil { stream.keyMgmt = sessionKeyMgmt }
      if range == nil {
        range = mediaDesc.attribute("range")?.value?.trimmingCharacters(in: .whitespaces)
      }
      streams.append(stream)
    } catch {
      // A stream the camera offered that we can't parse (unsupported codec, bad
      // rtpmap, ...) is dropped. If at least one other stream parses the session
      // still starts, so surface the drop rather than losing it silently.
      errors.append("\(error)")
      onDiagnostic?(
        RTSPDiagnostic(
          severity: .warning,
          message:
            "Dropping unparseable \(cutForMessage(mediaDesc.media)) stream from SDP: \(error)"))
    }
  }

  let moreMalformed = sdp.skippedMediaCount - sdp.skippedMediaErrors.count
  if moreMalformed > 0 {
    let message = "Dropping \(moreMalformed) more media sections with a malformed m= line"
    errors.append(message)
    onDiagnostic?(RTSPDiagnostic(severity: .warning, message: message))
  }

  let ignored = sdp.ignoredMediaCount
  if ignored > 0 {
    errors.append("\(ignored) media sections over the limit of \(maxMediaSections)")
    let message = "Ignoring \(ignored) media sections: only the first \(maxMediaSections) are read"
    onDiagnostic?(RTSPDiagnostic(severity: .warning, message: message))
  }

  if sdp.ignoredAttributeCount > 0 {
    onDiagnostic?(
      RTSPDiagnostic(
        severity: .warning,
        message: "Ignoring \(sdp.ignoredAttributeCount) SDP attributes past "
          + "\(SDPParser.maxAttributesPerSection) in a section"))
  }

  guard !streams.isEmpty else {
    throw RTSPError.invalidSDP(
      "No parseable streams in SDP. Errors: \(listForMessage(errors, separator: "; "))")
  }

  return Presentation(
    streams: streams,
    baseURL: baseURL,
    control: sessionControl,
    tool: tool,
    range: range
  )
}

/// Whether `s` begins with a URI scheme (`scheme:` where the scheme starts with
/// an ASCII letter), per RFC 3986. Used to distinguish an absolute Content-Base
/// or control URL from a scheme-less one like "192.168.1.10:554/stream0/" or
/// "camera.local:554/stream/": a `:` followed by a port (digits, then the end or
/// `/`, `?`, `#`) is a host:port, not a scheme, unless `//` follows the colon.
/// Retina uses `Url::parse` succeeding as its test, which takes "camera.local"
/// as a scheme; this check resolves such a value against the request scheme.
func hasURIScheme(_ s: String) -> Bool {
  guard let colon = s.firstIndex(of: ":") else { return false }
  let scheme = s[s.startIndex..<colon]
  guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
  guard
    scheme.allSatisfy({
      $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".")
    })
  else { return false }
  let rest = s[s.index(after: colon)...]
  if rest.hasPrefix("//") { return true }
  let afterPort = rest.drop(while: { $0.isASCII && $0.isNumber })
  if let next = afterPort.first {
    return !(afterPort.count < rest.count && (next == "/" || next == "?" || next == "#"))
  }
  return false  // "host:" or "host:554"
}
