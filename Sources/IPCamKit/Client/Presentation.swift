// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/client/mod.rs Presentation and Stream types

import Foundation

/// A parsed RTSP presentation (result of DESCRIBE).
public struct Presentation: Sendable {
  /// Streams within this presentation.
  public var streams: [Stream]

  /// Base URL for relative control URLs.
  public let baseURL: String

  /// Session-level control URL.
  public var control: String

  /// Server tool string (from SDP `a=tool:` attribute).
  public var tool: String?

  public init(streams: [Stream], baseURL: String, control: String, tool: String? = nil) {
    self.streams = streams
    self.baseURL = baseURL
    self.control = control
    self.tool = tool
  }
}

/// A parsed media stream from an SDP media description.
public struct Stream: Sendable {
  /// Media type: "video", "audio", "application"
  public let media: String

  /// Encoding name (lowercase): "h264", "pcmu", "mpeg4-generic", etc.
  public let encodingName: String

  /// RTP payload type (0-127)
  public let rtpPayloadType: UInt8

  /// Clock rate in Hz (e.g., 90000 for video, 8000 for audio)
  public let clockRateHz: UInt32

  /// Audio channel count (nil for video)
  public let channels: UInt16?

  /// Framerate from SDP (nil if not specified)
  public let framerate: Float?

  /// Stream-specific control URL
  public let control: String?

  /// Format-specific parameters from SDP `a=fmtp:` attribute
  public let formatSpecificParams: String?

  /// Stream state for SETUP/PLAY tracking
  var state: StreamState = .uninit

  /// Parse video parameters from format-specific params.
  /// Returns nil for non-H.264/H.265 streams or if parsing fails.
  public var videoParameters: VideoParameters? {
    guard let fmtp = formatSpecificParams else { return nil }
    switch encodingName {
    case "h264":
      return (try? H264Parameters.parseFormatSpecificParams(fmtp))?.genericParameters
    case "h265":
      return (try? H265Parameters.parseFormatSpecificParams(fmtp))?.genericParameters
    default:
      return nil
    }
  }

  public init(
    media: String,
    encodingName: String,
    rtpPayloadType: UInt8,
    clockRateHz: UInt32,
    channels: UInt16? = nil,
    framerate: Float? = nil,
    control: String? = nil,
    formatSpecificParams: String? = nil
  ) {
    self.media = media
    self.encodingName = encodingName
    self.rtpPayloadType = rtpPayloadType
    self.clockRateHz = clockRateHz
    self.channels = channels
    self.framerate = framerate
    self.control = control
    self.formatSpecificParams = formatSpecificParams
  }
}

/// Stream state tracking for SETUP/PLAY lifecycle.
enum StreamState: Sendable {
  case uninit
  case setup(StreamStateInit)
  case playing
}

/// Stream state after SETUP but before PLAY.
struct StreamStateInit: Sendable {
  var ssrc: UInt32?
  var initialSeq: UInt16?
  var initialRtptime: UInt32?
  var ctx: StreamContext
}

/// Parsed SETUP response.
public struct SetupResponse: Sendable {
  public var session: SessionHeader
  public var ssrc: UInt32?
  public var channelId: UInt8?
  public var source: String?
  public var serverPort: UInt16?
}

/// Parsed Session header from SETUP response.
public struct SessionHeader: Sendable {
  public var id: String
  public var timeoutSec: UInt32
}

/// Parsed OPTIONS response.
public struct OptionsResponse: Sendable {
  public var setParameterSupported: Bool
  public var getParameterSupported: Bool
}
