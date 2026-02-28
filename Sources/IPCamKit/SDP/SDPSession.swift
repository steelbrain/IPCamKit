// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Replaces upstream sdp_types crate with native Swift SDP model types

import Foundation

/// A parsed SDP session description (RFC 8866).
public struct SDPSession: Sendable {
  /// v= (protocol version, always 0)
  public var version: Int = 0

  /// o= (origin)
  public var origin: String?

  /// s= (session name)
  public var sessionName: String?

  /// c= (connection information)
  public var connectionInfo: String?

  /// t= (timing)
  public var timing: String?

  /// Session-level attributes
  public var attributes: [SDPAttribute] = []

  /// Media descriptions
  public var mediaDescriptions: [SDPMediaDescription] = []

  /// Look up a session-level attribute by name. Returns the first match.
  public func attribute(_ name: String) -> SDPAttribute? {
    attributes.first { $0.name == name }
  }

  /// Look up all session-level attributes with the given name.
  public func attributes(named name: String) -> [SDPAttribute] {
    attributes.filter { $0.name == name }
  }
}

/// A parsed SDP media description.
public struct SDPMediaDescription: Sendable {
  /// Media type: "video", "audio", "application", etc.
  public var media: String

  /// Port (typically 0 in RTSP)
  public var port: UInt16

  /// Protocol: "RTP/AVP", "RTP/SAVP", etc.
  public var proto: String

  /// Format list (payload type numbers as strings)
  public var fmt: String

  /// Connection info specific to this media (overrides session-level)
  public var connectionInfo: String?

  /// Bandwidth info
  public var bandwidth: String?

  /// Media-level attributes
  public var attributes: [SDPAttribute] = []

  /// Look up a media-level attribute by name. Returns the first match.
  public func attribute(_ name: String) -> SDPAttribute? {
    attributes.first { $0.name == name }
  }

  /// Look up all media-level attributes with the given name.
  public func attributes(named name: String) -> [SDPAttribute] {
    attributes.filter { $0.name == name }
  }
}

/// An SDP attribute (a= line).
public struct SDPAttribute: Sendable, Equatable {
  /// Attribute name (the part before ':')
  public var name: String

  /// Attribute value (the part after ':', or nil for property attributes)
  public var value: String?

  public init(name: String, value: String? = nil) {
    self.name = name
    self.value = value
  }
}
