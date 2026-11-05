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
  /// The most media sections kept; later ones are counted in
  /// `SDPSession.ignoredMediaCount` and not stored. Nil keeps all of them.
  let mediaLimit: Int?

  /// The most errors kept for media sections with a malformed `m=` line.
  static let maxSkippedMediaErrors = 64

  /// With a media limit, the most attributes kept per section (session level
  /// or one media section); later ones are counted in
  /// `SDPSession.ignoredAttributeCount`.
  static let maxAttributesPerSection = 1024

  public init() {
    mediaLimit = nil
  }

  /// A parser that keeps only the first `mediaLimit` media sections, so a
  /// response of thousands of tiny sections isn't stored whole.
  init(mediaLimit: Int) {
    self.mediaLimit = mediaLimit
  }

  /// Parse an SDP session description from raw bytes.
  ///
  /// SDP is UTF-8 (RFC 8866), but some cameras put a legacy encoding such as
  /// GBK in free-text `s=`/`i=` lines. When the body isn't valid UTF-8 it is
  /// decoded as ISO Latin-1, which maps every byte: the ASCII fields the parser
  /// uses come through intact and only the free text is garbled.
  public func parse(_ data: Data) throws -> SDPSession {
    guard
      let text = String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .isoLatin1)
    else {
      throw RTSPError.invalidSDP("Undecodable SDP body")
    }
    return try parse(text)
  }

  /// Parse an SDP session description from a string.
  ///
  /// An `m=` line that can't be parsed (fewer than four fields) drops its media
  /// section, every line up to the next `m=` line, and the rest of the
  /// description is still parsed.
  public func parse(_ text: String) throws -> SDPSession {
    var session = SDPSession()
    var currentMedia: SDPMediaDescription?
    // True from an unparseable or ignored m= line to the next m= line.
    var skippingMedia = false
    // Whether this section's attributes are past the per-section limit.
    func attributesFull(_ count: Int) -> Bool {
      mediaLimit != nil && count >= Self.maxAttributesPerSection
    }

    func process(_ line: Substring) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.count >= 2, trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)] == "="
      else {
        return  // Skip blank lines and malformed lines
      }
      let type = trimmed[trimmed.startIndex]
      if skippingMedia && type != "m" { return }
      let value = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)...])

      switch type {
      case "v":
        session.version = Int(value) ?? 0
      case "o":
        // o= should only appear at session level; some cameras are broken.
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
        } else {
          session.bandwidth = value
        }
      case "t":
        session.timing = value
      case "a":
        if currentMedia != nil {
          if attributesFull(currentMedia!.attributes.count) {
            session.ignoredAttributeCount += 1
          } else {
            currentMedia!.attributes.append(parseAttribute(value))
          }
        } else if attributesFull(session.attributes.count) {
          session.ignoredAttributeCount += 1
        } else {
          session.attributes.append(parseAttribute(value))
        }
      case "m":
        // Flush previous media description
        if let media = currentMedia {
          session.mediaDescriptions.append(media)
        }
        currentMedia = nil
        skippingMedia = true
        do {
          let media = try parseMediaLine(value)
          if let mediaLimit, session.mediaDescriptions.count >= mediaLimit {
            session.ignoredMediaCount += 1
          } else {
            currentMedia = media
            skippingMedia = false
          }
        } catch {
          session.skippedMediaCount += 1
          if session.skippedMediaErrors.count < Self.maxSkippedMediaErrors {
            session.skippedMediaErrors.append("\(error)")
          }
        }
      default:
        break  // Ignore unknown types (i=, u=, e=, p=, z=, k=)
      }
    }

    // A line ends at LF, CR or CRLF, so "\r\r\n" from a sloppy server ends
    // one line too; empty lines are dropped. Lines are read one at a time
    // rather than split into an array first: a 2 MiB body of tiny lines
    // would otherwise take tens of megabytes at once.
    let scalars = text.unicodeScalars
    var lineStart = scalars.startIndex
    var index = scalars.startIndex
    while index < scalars.endIndex {
      let scalar = scalars[index]
      if scalar == "\n" || scalar == "\r" {
        if lineStart < index { process(Substring(scalars[lineStart..<index])) }
        lineStart = scalars.index(after: index)
      }
      index = scalars.index(after: index)
    }
    if lineStart < scalars.endIndex { process(Substring(scalars[lineStart...])) }

    // Flush last media description
    if let media = currentMedia {
      session.mediaDescriptions.append(media)
    }

    return session
  }

  /// Parse an `a=` attribute line value.
  /// Format: `name:value` or just `name` (property attribute).
  ///
  /// The attribute *name* is lowercased so matching is case-insensitive,
  /// consistent with the rest of the stack (RTSP headers, rtpmap encoding,
  /// proto): real camera firmware sometimes emits `a=Control:`/`a=RTPMAP:`.
  /// The *value* keeps its original case (base64 sprop, control URLs, etc.).
  func parseAttribute(_ value: String) -> SDPAttribute {
    if let colonIdx = value.firstIndex(of: ":") {
      let name = String(value[value.startIndex..<colonIdx]).lowercased()
      let attrValue = String(value[value.index(after: colonIdx)...])
      return SDPAttribute(name: name, value: attrValue)
    }
    return SDPAttribute(name: value.lowercased(), value: nil)
  }

  /// Parse an `m=` media line.
  /// Format: `<media> <port> <proto> <fmt> [<fmt>...]`
  func parseMediaLine(_ value: String) throws -> SDPMediaDescription {
    // Fields are space-delimited per RFC 8866, but tolerate tabs / repeated
    // spaces from sloppy cameras. maxSplits 3 keeps the whole fmt list in the
    // last field.
    let parts = value.split(
      maxSplits: 3, omittingEmptySubsequences: true,
      whereSeparator: { $0 == " " || $0 == "\t" })
    guard parts.count >= 4 else {
      throw RTSPError.invalidSDP(
        "Invalid media line: m=\(cutForMessage(value))")
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
