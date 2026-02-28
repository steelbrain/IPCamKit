// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Replaces upstream sdp_types crate with native Swift SDP parser

import Foundation

/// Parses SDP session descriptions per RFC 8866.
///
/// SDP is a simple text format with lines of the form `<type>=<value>`.
/// Session-level attributes precede media descriptions.
/// Each `m=` line starts a new media description.
public struct SDPParser: Sendable {
  public init() {}

  /// Parse an SDP session description from raw bytes.
  public func parse(_ data: Data) throws -> SDPSession {
    guard let text = String(data: data, encoding: .utf8) else {
      throw RTSPError.invalidSDP("Invalid UTF-8 in SDP")
    }
    return try parse(text)
  }

  /// Parse an SDP session description from a string.
  public func parse(_ text: String) throws -> SDPSession {
    var session = SDPSession()
    var currentMedia: SDPMediaDescription?
    // Split on both \r\n and \n for robustness
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.count >= 2, trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)] == "="
      else {
        continue  // Skip blank lines and malformed lines
      }
      let type = trimmed[trimmed.startIndex]
      let value = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)...])

      switch type {
      case "v":
        session.version = Int(value) ?? 0
      case "o":
        if currentMedia != nil {
          // o= should only appear at session level; some cameras are broken
        }
        session.origin = value
      case "s":
        session.sessionName = value
      case "c":
        if currentMedia != nil {
          currentMedia!.connectionInfo = value
        } else {
          session.connectionInfo = value
        }
      case "b":
        if currentMedia != nil {
          currentMedia!.bandwidth = value
        }
      case "t":
        session.timing = value
      case "a":
        let attr = parseAttribute(value)
        if currentMedia != nil {
          currentMedia!.attributes.append(attr)
        } else {
          session.attributes.append(attr)
        }
      case "m":
        // Flush previous media description
        if let media = currentMedia {
          session.mediaDescriptions.append(media)
        }
        currentMedia = try parseMediaLine(value)
      default:
        break  // Ignore unknown types (i=, u=, e=, p=, z=, k=)
      }
    }

    // Flush last media description
    if let media = currentMedia {
      session.mediaDescriptions.append(media)
    }

    return session
  }

  /// Parse an `a=` attribute line value.
  /// Format: `name:value` or just `name` (property attribute).
  func parseAttribute(_ value: String) -> SDPAttribute {
    if let colonIdx = value.firstIndex(of: ":") {
      let name = String(value[value.startIndex..<colonIdx])
      let attrValue = String(value[value.index(after: colonIdx)...])
      return SDPAttribute(name: name, value: attrValue)
    }
    return SDPAttribute(name: value, value: nil)
  }

  /// Parse an `m=` media line.
  /// Format: `<media> <port> <proto> <fmt> [<fmt>...]`
  func parseMediaLine(_ value: String) throws -> SDPMediaDescription {
    let parts = value.split(separator: " ", maxSplits: 3)
    guard parts.count >= 4 else {
      throw RTSPError.invalidSDP("Invalid media line: m=\(value)")
    }

    let media = String(parts[0])
    let port = UInt16(parts[1]) ?? 0
    let proto = String(parts[2])
    let fmt = String(parts[3])

    return SDPMediaDescription(
      media: media,
      port: port,
      proto: proto,
      fmt: fmt
    )
  }
}
