// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/client/mod.rs - RTSP session state machine

import Foundation
import Network

/// Transport mode for RTP data.
public enum Transport: Sendable {
  /// RTP interleaved over RTSP TCP connection.
  case tcp
  /// RTP/RTCP on separate UDP ports.
  case udp
}

/// Video codec type.
public enum VideoCodec: Sendable {
  case h264
  case h265
}

/// Public audio codec type.
public enum PublicAudioCodec: Sendable {
  case aac
  case pcmu
  case pcma
  case g722
  case g723
  case l16
  case other(String)
}

/// Parsed session description returned from `start()`.
public struct SessionDescription: Sendable {
  public let videoCodec: VideoCodec
  public let sps: Data
  public let pps: Data
  /// VPS data (H.265 only, nil for H.264).
  public let vps: Data?
  public let resolution: (width: Int, height: Int)?
  public let clockRate: UInt32

  /// Audio codec, if an audio stream was found.
  public let audioCodec: PublicAudioCodec?
  /// Audio sample rate in Hz, if an audio stream was found.
  public let audioSampleRate: UInt32?
  /// Audio channel count, if known.
  public let audioChannels: UInt16?
  /// Codec-specific extra data (e.g. AudioSpecificConfig for AAC).
  public let audioExtraData: Data?
}

/// RTSP client session that manages the full RTSP lifecycle.
///
/// Usage:
/// ```swift
/// let session = RTSPClientSession(url: "rtsp://host:554/stream")
/// let desc = try await session.start()
/// for try await frame in session.videoFrames() {
///     // Process frame.nalus
/// }
/// await session.stop()
/// ```
public final class RTSPClientSession: Sendable {
  private let url: String
  private let credentials: Credentials?
  private let transport: Transport
  private let userAgent: String
  private let state: SessionState

  public init(
    url: String,
    credentials: Credentials? = nil,
    transport: Transport = .tcp,
    userAgent: String = "IPCamKit"
  ) {
    self.url = url
    self.credentials = credentials
    self.transport = transport
    self.userAgent = userAgent
    self.state = SessionState()
  }

  /// Start the RTSP session (DESCRIBE -> SETUP -> PLAY).
  ///
  /// Returns session info including codec parameters for decoder setup.
  public func start() async throws -> SessionDescription {
    try await state.start(
      url: url,
      credentials: credentials,
      transport: transport,
      userAgent: userAgent
    )
  }

  /// Stream of depacketized video frames.
  ///
  /// Each frame contains NAL units in AVCC format (4-byte length prefix).
  /// SPS/PPS changes are signaled via `sps`/`pps` properties on the frame.
  public func frames() -> AsyncThrowingStream<PublicCodecItem, Error> {
    AsyncThrowingStream { continuation in
      Task {
        do {
          try await state.streamFrames(continuation: continuation)
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  /// Graceful disconnect (TEARDOWN).
  public func stop() async {
    await state.stop()
  }
}

/// A decoded frame (video or audio) exposed to consumers.
public enum PublicCodecItem: Sendable {
  case video(PublicVideoFrame)
  case audio(PublicAudioFrame)
  case rtcp(PublicRTCPPacket)
}

public struct PublicRTCPPacket: Sendable {
  public let timestamp: Double?
  public let data: Data
}

public struct PublicAudioFrame: Sendable {
  /// Raw audio data (codec-specific).
  public let data: Data

  /// Presentation timestamp in seconds.
  public let timestamp: Double

  /// The audio codec for this frame.
  public let codec: PublicAudioCodec

  /// Sample rate in Hz.
  public let sampleRate: UInt32

  /// Channel count, if known.
  public let channels: UInt16?

  /// Number of RTP packets lost before this frame.
  public let loss: UInt16
}

/// A video frame exposed to consumers.
public struct PublicVideoFrame: Sendable {
  /// NAL units in AVCC format (4-byte big-endian length prefix + NAL bytes).
  public let nalus: [Data]

  /// Presentation timestamp derived from RTP timestamp.
  public let timestamp: Double

  /// Whether this is a keyframe (IDR).
  public let isKeyframe: Bool

  /// Number of RTP packets lost before this frame.
  public let loss: UInt16

  /// SPS data if parameters changed with this frame.
  public let sps: Data?

  /// PPS data if parameters changed with this frame.
  public let pps: Data?

  /// VPS data if parameters changed with this frame (H.265 only).
  public let vps: Data?
}

/// Dispatch enum for video depacketizers (H.264 or H.265).
enum VideoDepacketizer: Sendable {
  case h264(H264Depacketizer)
  case h265(H265Depacketizer)

  mutating func push(_ pkt: ReceivedRTPPacket) throws {
    switch self {
    case .h264(var d):
      try d.push(pkt)
      self = .h264(d)
    case .h265(var d):
      try d.push(pkt)
      self = .h265(d)
    }
  }

  mutating func pull() -> Result<CodecItem, DepacketizeError>? {
    switch self {
    case .h264(var d):
      let result = d.pull()
      self = .h264(d)
      return result
    case .h265(var d):
      let result = d.pull()
      self = .h265(d)
      return result
    }
  }

  var videoParameters: VideoParameters? {
    switch self {
    case .h264(let d): return d.parameters?.genericParameters
    case .h265(let d): return d.parameters?.genericParameters
    }
  }
}

// MARK: - Internal Session State

/// Actor-based internal state for thread-safe session management.
actor SessionState {
  private var connection: RTSPTransportConnection?
  private var presentation: Presentation?
  private var sessionId: String?
  private var cseq: UInt32 = 0
  private var authenticator: RTSPAuthenticator?
  private var depacketizer: VideoDepacketizer?
  private var audioDepacketizer: AudioDepacketizer?
  private var url: String?
  private var videoStreamIndex: Int?
  private var audioStreamIndex: Int?
  private var audioEncodingName: String?
  private var audioClockRate: UInt32?
  private var audioChannels: UInt16?
  private var channelMappings = ChannelMappings()
  private var inorderParsers: [Int: InorderParser] = [:]
  private var userAgent: String?
  private var isPlaying = false

  func start(
    url: String,
    credentials: Credentials?,
    transport: Transport,
    userAgent: String
  ) async throws -> SessionDescription {
    // Parse URL
    guard let urlComponents = URLComponents(string: url) else {
      throw RTSPError.connectionFailed("Invalid URL: \(url)")
    }
    let host = urlComponents.host ?? "localhost"
    let port = UInt16(urlComponents.port ?? 554)

    self.userAgent = userAgent

    // Set up authenticator
    if let creds = credentials {
      authenticator = RTSPAuthenticator(credentials: creds)
    }

    // Connect
    let conn = RTSPTransportConnection()
    try await conn.connect(host: host, port: port)
    connection = conn

    // DESCRIBE
    let describeResp = try await sendRequest(
      method: .describe,
      url: url,
      extraHeaders: [("Accept", "application/sdp")]
    )
    var presMut = try parseDescribe(requestURL: url, response: describeResp)
    presentation = presMut

    // Find first H.264 or H.265 video stream
    guard
      let videoIdx = presMut.streams.firstIndex(where: {
        $0.media == "video" && ($0.encodingName == "h264" || $0.encodingName == "h265")
      })
    else {
      throw RTSPError.sessionSetupFailed(
        statusCode: 0, reason: "No H.264/H.265 video stream found")
    }

    let stream = presMut.streams[videoIdx]
    self.url = url
    self.videoStreamIndex = videoIdx

    // SETUP
    let setupURL = stream.control ?? url
    var setupHeaders: [(String, String)] = []
    if transport == .tcp {
      let channelId = channelMappings.nextUnassigned() ?? 0
      setupHeaders.append(
        (
          "Transport",
          "RTP/AVP/TCP;unicast;interleaved=\(channelId)-\(channelId + 1)"
        ))
      try channelMappings.assign(channelId: channelId, streamIndex: videoIdx)
    } else {
      setupHeaders.append(("Transport", "RTP/AVP;unicast"))
    }

    let setupResp = try await sendRequest(
      method: .setup, url: setupURL, extraHeaders: setupHeaders)
    let setup = try parseSetup(response: setupResp)
    sessionId = setup.session.id
    presMut.streams[videoIdx].state = .setup(
      StreamStateInit(ssrc: setup.ssrc, initialSeq: nil, initialRtptime: nil, ctx: .dummy))

    // Find and SETUP audio stream (optional, best-effort)
    let audioIdx = presMut.streams.firstIndex(where: { s in
      s.media == "audio" && isAudioEncodingSupported(s.encodingName)
    })
    var audioSetupSSRC: UInt32?

    if let audioIdx = audioIdx {
      let audioStream = presMut.streams[audioIdx]
      let audioSetupURL = audioStream.control ?? url
      var audioSetupHeaders: [(String, String)] = []
      if transport == .tcp {
        let audioChannelId = channelMappings.nextUnassigned() ?? 2
        audioSetupHeaders.append(
          (
            "Transport",
            "RTP/AVP/TCP;unicast;interleaved=\(audioChannelId)-\(audioChannelId + 1)"
          ))
        try channelMappings.assign(
          channelId: audioChannelId, streamIndex: audioIdx)
      } else {
        audioSetupHeaders.append(("Transport", "RTP/AVP;unicast"))
      }
      if let sid = sessionId {
        audioSetupHeaders.append(("Session", sid))
      }
      let audioSetupResp = try await sendRequest(
        method: .setup, url: audioSetupURL,
        extraHeaders: audioSetupHeaders)
      let audioSetup = try parseSetup(response: audioSetupResp)
      sessionId = audioSetup.session.id
      audioSetupSSRC = audioSetup.ssrc
      presMut.streams[audioIdx].state = .setup(
        StreamStateInit(ssrc: audioSetup.ssrc, initialSeq: nil, initialRtptime: nil, ctx: .dummy))

      audioStreamIndex = audioIdx
      audioEncodingName = audioStream.encodingName
      audioClockRate = audioStream.clockRateHz
      audioChannels = audioStream.channels
    }

    // PLAY
    var playHeaders: [(String, String)] = []
    if let sid = sessionId {
      playHeaders.append(("Session", sid))
    }
    playHeaders.append(("Range", "npt=0.000-"))

    let playResp = try await sendRequest(
      method: .play, url: url, extraHeaders: playHeaders)

    try parsePlay(response: playResp, presentation: &presMut)
    presentation = presMut

    // Initialize video depacketizer
    if stream.encodingName == "h265" {
      depacketizer = .h265(
        try H265Depacketizer(
          clockRate: stream.clockRateHz,
          formatSpecificParams: stream.formatSpecificParams))
    } else {
      depacketizer = .h264(
        try H264Depacketizer(
          clockRate: stream.clockRateHz,
          formatSpecificParams: stream.formatSpecificParams))
    }

    // Initialize video timeline and inorder parser
    var videoStart: UInt32?
    var videoSeq: UInt16?
    var videoSsrc: UInt32? = setup.ssrc

    if case .setup(let init_) = presMut.streams[videoIdx].state {
      videoStart = init_.initialRtptime
      if let seq = init_.initialSeq, seq != 0, seq != 1 {
        videoSeq = seq
      }
      if let s = init_.ssrc { videoSsrc = s }
    }

    let timeline = try Timeline(start: videoStart, clockRate: stream.clockRateHz)
    inorderParsers[videoIdx] = InorderParser(
      ssrc: videoSsrc, nextSeq: videoSeq, isTcp: transport == .tcp,
      timeline: timeline)

    // Initialize audio depacketizer and inorder parser
    var resolvedAudioCodec: PublicAudioCodec?
    var resolvedAudioRate: UInt32?
    var resolvedAudioChannels: UInt16?

    if let audioIdx = audioIdx {
      let audioStream = presMut.streams[audioIdx]
      if let depkt = try? AudioDepacketizer.create(
        encodingName: audioStream.encodingName,
        clockRate: audioStream.clockRateHz,
        channels: audioStream.channels,
        formatSpecificParams: audioStream.formatSpecificParams)
      {
        audioDepacketizer = depkt

        var audioStart: UInt32?
        var audioSeq: UInt16?
        var resolvedAudioSsrc = audioSetupSSRC

        if case .setup(let init_) = presMut.streams[audioIdx].state {
          audioStart = init_.initialRtptime
          if let seq = init_.initialSeq, seq != 0, seq != 1 {
            audioSeq = seq
          }
          if let s = init_.ssrc { resolvedAudioSsrc = s }
        }

        let audioTimeline = try Timeline(
          start: audioStart, clockRate: audioStream.clockRateHz)
        inorderParsers[audioIdx] = InorderParser(
          ssrc: resolvedAudioSsrc, nextSeq: audioSeq,
          isTcp: transport == .tcp, timeline: audioTimeline)
        resolvedAudioCodec = publicAudioCodec(
          from: audioStream.encodingName)
        resolvedAudioRate = audioStream.clockRateHz
        resolvedAudioChannels = audioStream.channels
      }
    }

    isPlaying = true

    // Build session description
    let isH265 = stream.encodingName == "h265"
    let sps: Data
    let pps: Data
    var vps: Data?
    let dims: (width: UInt16, height: UInt16)?
    if let depkt = depacketizer {
      switch depkt {
      case .h264(let d):
        sps = d.parameters?.spsNAL ?? Data()
        pps = d.parameters?.ppsNAL ?? Data()
        dims = d.parameters?.genericParameters.pixelDimensions
      case .h265(let d):
        sps = d.parameters?.spsNAL ?? Data()
        pps = d.parameters?.ppsNAL ?? Data()
        vps = d.parameters?.vpsNAL
        dims = d.parameters?.genericParameters.pixelDimensions
      }
    } else {
      sps = Data()
      pps = Data()
      dims = nil
    }
    let resolution = dims.map {
      (width: Int($0.width), height: Int($0.height))
    }

    return SessionDescription(
      videoCodec: isH265 ? .h265 : .h264,
      sps: sps,
      pps: pps,
      vps: vps,
      resolution: resolution,
      clockRate: stream.clockRateHz,
      audioCodec: resolvedAudioCodec,
      audioSampleRate: resolvedAudioRate,
      audioChannels: resolvedAudioChannels,
      audioExtraData: audioDepacketizer?.audioParameters?.extraData
    )
  }

  func streamFrames(
    continuation: AsyncThrowingStream<PublicCodecItem, Error>.Continuation
  ) async throws {
    guard let conn = connection, isPlaying else {
      continuation.finish()
      return
    }

    while isPlaying {
      let msg = try await conn.receiveMessage()

      guard case .data(let interleaved) = msg else { continue }
      guard let mapping = channelMappings.lookup(interleaved.channelId) else { continue }

      if mapping.channelType == .rtp {
        guard var parser = inorderParsers[mapping.streamIndex] else { continue }

        if let videoIdx = videoStreamIndex, mapping.streamIndex == videoIdx {
          guard var depkt = depacketizer else { continue }
          if let pkt = try parser.rtp(
            data: interleaved.data, ctx: .dummy,
            streamId: mapping.streamIndex, streamCtx: .dummy)
          {
            do {
              try depkt.push(pkt)
            } catch {
              throw RTSPError.depacketizationError("Video push failed: \(error)")
            }
            while let result = depkt.pull() {
              switch result {
              case .success(.videoFrame(let frame)):
                let publicFrame = convertFrame(frame, depacketizer: depkt)
                continuation.yield(.video(publicFrame))
              case .failure(let err):
                throw RTSPError.depacketizationError("Video depacketization failed: \(err)")
              default:
                break
              }
            }
          }
          depacketizer = depkt
        } else if let audioIdx = audioStreamIndex, mapping.streamIndex == audioIdx {
          guard var depkt = audioDepacketizer else { continue }
          if let pkt = try parser.rtp(
            data: interleaved.data, ctx: .dummy,
            streamId: mapping.streamIndex, streamCtx: .dummy)
          {
            try depkt.push(pkt)
            while let result = depkt.pull() {
              switch result {
              case .success(.audioFrame(let frame)):
                let publicFrame = PublicAudioFrame(
                  data: frame.data,
                  timestamp: frame.timestamp.elapsedSeconds,
                  codec: publicAudioCodec(
                    from: audioEncodingName ?? ""),
                  sampleRate: audioClockRate ?? 0,
                  channels: audioChannels,
                  loss: frame.loss
                )
                continuation.yield(.audio(publicFrame))
              case .failure(let err):
                throw RTSPError.depacketizationError("Audio depacketization failed: \(err)")
              default:
                break
              }
            }
          }
          audioDepacketizer = depkt
        }

        inorderParsers[mapping.streamIndex] = parser
      } else if mapping.channelType == .rtcp {
        guard var parser = inorderParsers[mapping.streamIndex] else { continue }
        if let rtcpPkt = try parser.rtcp(
          ctx: .dummy, streamId: mapping.streamIndex, data: interleaved.data)
        {
          continuation.yield(
            .rtcp(
              PublicRTCPPacket(timestamp: rtcpPkt.rtpTimestamp?.elapsedSeconds, data: rtcpPkt.raw)))
        }
        inorderParsers[mapping.streamIndex] = parser
      }
    }

    continuation.finish()
  }

  func stop() async {
    isPlaying = false
    if let _ = connection, let sid = sessionId, let url = self.url {
      // Send TEARDOWN (best-effort) using sendRequest to include Auth and other headers
      _ = try? await sendRequest(method: .teardown, url: url, extraHeaders: [("Session", sid)])
    }
    await connection?.close()
    connection = nil
  }

  // MARK: - Private Helpers

  private func sendRequest(
    method: RTSPMethod,
    url: String,
    extraHeaders: [(String, String)] = []
  ) async throws -> RTSPResponse {
    guard let conn = connection else {
      throw RTSPError.connectionFailed("Not connected")
    }

    var request = RTSPRequest(method: method, url: url)
    request.setHeader("CSeq", value: "\(nextCSeq())")

    if let userAgent = userAgent, !userAgent.isEmpty {
      request.setHeader("User-Agent", value: userAgent)
    }

    if let sid = sessionId {
      request.setHeader("Session", value: sid)
    }

    if let auth = authenticator, auth.hasChallenge {
      if let authHeader = auth.authorize(method: method.rawValue, uri: url) {
        request.setHeader("Authorization", value: authHeader)
      }
    }

    for (name, value) in extraHeaders {
      request.setHeader(name, value: value)
    }

    let resp = try await conn.sendRequest(request)

    // Handle 401 Unauthorized — retry with auth
    if resp.statusCode == 401 {
      if var auth = authenticator,
        let wwwAuth = resp.header("WWW-Authenticate")
      {
        auth.handleChallenge(wwwAuth)
        authenticator = auth

        var retryRequest = RTSPRequest(method: method, url: url)
        retryRequest.setHeader("CSeq", value: "\(nextCSeq())")
        if let authHeader = auth.authorize(method: method.rawValue, uri: url) {
          retryRequest.setHeader("Authorization", value: authHeader)
        }
        for (name, value) in extraHeaders {
          retryRequest.setHeader(name, value: value)
        }
        let retryResp = try await conn.sendRequest(retryRequest)
        if retryResp.statusCode == 401 {
          throw RTSPError.authenticationFailed
        }
        return retryResp
      }
      throw RTSPError.authenticationFailed
    }

    guard resp.statusCode >= 200 && resp.statusCode < 300 else {
      throw RTSPError.sessionSetupFailed(
        statusCode: Int(resp.statusCode),
        reason: resp.reasonPhrase
      )
    }

    return resp
  }

  private func nextCSeq() -> UInt32 {
    cseq += 1
    return cseq
  }

  private func convertFrame(
    _ frame: VideoFrame, depacketizer: VideoDepacketizer
  ) -> PublicVideoFrame {
    // Split AVCC data into individual NALs
    var nalus: [Data] = []
    var offset = frame.data.startIndex
    while offset + 4 <= frame.data.endIndex {
      let len =
        Int(frame.data[offset]) << 24
        | Int(frame.data[offset + 1]) << 16
        | Int(frame.data[offset + 2]) << 8
        | Int(frame.data[offset + 3])
      offset += 4
      if offset + len <= frame.data.endIndex {
        nalus.append(Data(frame.data[offset..<(offset + len)]))
      }
      offset += len
    }

    var sps: Data?
    var pps: Data?
    var vps: Data?
    if frame.hasNewParameters {
      switch depacketizer {
      case .h264(let d):
        sps = d.parameters?.spsNAL
        pps = d.parameters?.ppsNAL
      case .h265(let d):
        sps = d.parameters?.spsNAL
        pps = d.parameters?.ppsNAL
        vps = d.parameters?.vpsNAL
      }
    }

    return PublicVideoFrame(
      nalus: nalus,
      timestamp: frame.timestamp.elapsedSeconds,
      isKeyframe: frame.isRandomAccessPoint,
      loss: frame.loss,
      sps: sps,
      pps: pps,
      vps: vps
    )
  }

  private func isAudioEncodingSupported(_ name: String) -> Bool {
    switch name {
    case "mpeg4-generic", "pcmu", "pcma", "l16", "g722", "g723",
      "u8", "dvi4", "g726-16", "g726-24", "g726-32", "g726-40":
      return true
    default:
      return false
    }
  }

  private func publicAudioCodec(from encoding: String) -> PublicAudioCodec {
    switch encoding {
    case "mpeg4-generic": return .aac
    case "pcmu": return .pcmu
    case "pcma": return .pcma
    case "g722": return .g722
    case "g723": return .g723
    case "l16": return .l16
    default: return .other(encoding)
    }
  }
}
