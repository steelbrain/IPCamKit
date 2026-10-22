// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/client/mod.rs - RTSP session state machine

import Foundation
import Network

/// Transport mode for RTP data.
public enum Transport: Sendable {
  /// RTP interleaved over the RTSP TCP connection.
  case tcp
  /// RTP and RTCP on a separate UDP socket pair — an even local RTP port and the
  /// consecutive odd RTCP port — negotiated via `client_port` in SETUP. Works
  /// over both IPv4 and IPv6 peers.
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

/// Diagnostic event emitted by `RTSPClientSession` when a non-fatal anomaly is observed.
///
/// Use the `onDiagnostic` callback on `RTSPClientSession.init` to receive these.
/// `severity == .error` here means real damage (e.g. dropped data) while the stream
/// is still alive — distinct from a thrown `RTSPError`, which means the stream is dead.
public struct RTSPDiagnostic: Sendable {
  public enum Severity: Sendable {
    case info
    case warning
    case error
  }
  public let severity: Severity
  public let message: String

  public init(severity: Severity, message: String) {
    self.severity = severity
    self.message = message
  }
}

/// Video stream details, surfaced when a supported video stream is active.
///
/// `codec` and `clockRate` are always populated. `sps`/`pps`/`vps`/`resolution`
/// are `nil` until the depacketizer has observed parameter sets — for most
/// cameras this happens in-band on the first packet; cameras that ship the
/// parameter sets in SDP `fmtp` will have them set at `start()` time.
public struct VideoStream: Sendable {
  public let codec: VideoCodec
  public let clockRate: UInt32
  public let sps: Data?
  public let pps: Data?
  /// H.265 only; nil for H.264.
  public let vps: Data?
  public let resolution: (width: Int, height: Int)?
}

/// Audio stream details, surfaced when a supported audio stream is active.
///
/// `codec` and `sampleRate` are always populated. `channels` and `extraData`
/// reflect what the camera advertised; they are codec-dependent.
public struct AudioStream: Sendable {
  public let codec: PublicAudioCodec
  public let sampleRate: UInt32
  public let channels: UInt16?
  /// Codec-specific extra data (e.g. AudioSpecificConfig for AAC).
  public let extraData: Data?
}

/// Parsed session description returned from `start()`.
///
/// At least one of `video`, `audio`, or `metadataEncoding` is non-`nil` —
/// a session with zero usable streams is rejected at `start()`.
public struct SessionDescription: Sendable {
  public let video: VideoStream?
  public let audio: AudioStream?

  /// SDP encoding name of the analytics-metadata stream if one was set up
  /// (e.g. `vnd.onvif.metadata`), or `nil` if no metadata stream is active.
  public let metadataEncoding: String?
}

/// RTSP client session that manages the full RTSP lifecycle.
///
/// Usage:
/// ```swift
/// let session = RTSPClientSession(url: "rtsp://host:554/stream")
/// let desc = try await session.start()
/// for try await item in session.frames() {
///     switch item {
///     case .video(let frame): _ = frame.nalus  // raw NAL units
///     case .audio, .metadata, .rtcp: break
///     }
/// }
/// await session.stop()
/// ```
/// `frames()` may be consumed only once per session.
public final class RTSPClientSession: Sendable {
  private let url: String
  private let credentials: Credentials?
  private let transport: Transport
  private let userAgent: String
  private let onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)?
  private let state: SessionState
  /// Test-only override of the keepalive interval. When nil (production), the
  /// interval is derived from the server's advertised session timeout.
  private let keepaliveInterval: Duration?

  public convenience init(
    url: String,
    credentials: Credentials? = nil,
    transport: Transport = .tcp,
    userAgent: String = "IPCamKit",
    onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)? = nil
  ) {
    self.init(
      url: url, credentials: credentials, transport: transport,
      userAgent: userAgent, onDiagnostic: onDiagnostic, keepaliveInterval: nil)
  }

  /// Designated initializer. `keepaliveInterval` is internal and intended for
  /// tests that need a short, deterministic keepalive cadence.
  init(
    url: String,
    credentials: Credentials?,
    transport: Transport,
    userAgent: String,
    onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)?,
    keepaliveInterval: Duration?
  ) {
    self.url = url
    self.credentials = credentials
    self.transport = transport
    self.userAgent = userAgent
    self.onDiagnostic = onDiagnostic
    self.keepaliveInterval = keepaliveInterval
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
      userAgent: userAgent,
      onDiagnostic: onDiagnostic,
      keepaliveInterval: keepaliveInterval
    )
  }

  /// Stream of depacketized video frames.
  ///
  /// Each video frame carries its NAL units as raw NAL bytes, one per element,
  /// with no length prefix (see `PublicVideoFrame.nalus`).
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

/// A decoded frame (video, audio, or metadata) exposed to consumers.
public enum PublicCodecItem: Sendable {
  case video(PublicVideoFrame)
  case audio(PublicAudioFrame)
  case metadata(PublicMetadataFrame)
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

  /// RTP packets lost before this frame: the forward gap in the RTP sequence
  /// number. May be large (or spurious) if a camera's packetizer emits a wildly
  /// forward-jumped sequence number, so treat it as a discontinuity indicator
  /// rather than an exact loss count.
  public let loss: UInt16
}

/// A metadata frame from an RTSP `application` stream (typically ONVIF analytics).
public struct PublicMetadataFrame: Sendable {
  /// Raw payload bytes. For `vnd.onvif.metadata` this is a UTF-8 XML
  /// document with root `tt:MetaDataStream`, optionally GZIP-compressed
  /// (consult the SDP `encodingName` for the exact format).
  public let data: Data

  /// Presentation timestamp in seconds, derived from the RTP timestamp.
  public let timestamp: Double

  /// SDP encoding name (e.g. `vnd.onvif.metadata`).
  public let encodingName: String

  /// RTP packets lost before this frame: the forward gap in the RTP sequence
  /// number. May be large (or spurious) if a camera's packetizer emits a wildly
  /// forward-jumped sequence number, so treat it as a discontinuity indicator
  /// rather than an exact loss count.
  public let loss: UInt16
}

/// A video frame exposed to consumers.
public struct PublicVideoFrame: Sendable {
  /// The frame's NAL units, one raw NAL per element, starting with the NAL
  /// header. No AVCC length prefix or Annex B start code is included: to build
  /// a VideoToolbox sample, write each element's length as a 4-byte big-endian
  /// integer before it. Parameter sets sent in-band appear here as well.
  public let nalus: [Data]

  /// Presentation timestamp derived from RTP timestamp.
  public let timestamp: Double

  /// Whether this is a keyframe (IDR).
  public let isKeyframe: Bool

  /// RTP packets lost before this frame: the forward gap in the RTP sequence
  /// number. May be large (or spurious) if a camera's packetizer emits a wildly
  /// forward-jumped sequence number, so treat it as a discontinuity indicator
  /// rather than an exact loss count.
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

/// One demultiplexed data-plane datagram in a UDP session: an RTP or RTCP packet
/// tagged with its stream index. The per-socket readers fan these into a single
/// ordered consumer on the session actor. Control-plane traffic (keepalive /
/// TEARDOWN responses, connection close) is handled directly by the control
/// reader, off this lossy buffer, so it is never dropped under RTP backpressure.
private enum UDPTransportEvent: Sendable {
  case rtp(streamIndex: Int, data: Data)
  case rtcp(streamIndex: Int, data: Data)
}

/// Actor-based internal state for thread-safe session management.
actor SessionState {
  private var connection: RTSPTransportConnection?
  private var presentation: Presentation?
  private var sessionId: String?
  private var cseq: UInt32 = 0
  private var authenticator: RTSPAuthenticator?
  private var depacketizer: VideoDepacketizer?
  private var audioDepacketizer: AudioDepacketizer?
  private var applicationDepacketizer: ApplicationDepacketizer?
  private var url: String?
  private var videoStreamIndex: Int?
  private var audioStreamIndex: Int?
  private var applicationStreamIndex: Int?
  private var audioEncodingName: String?
  private var audioClockRate: UInt32?
  private var audioChannels: UInt16?
  private var applicationEncodingName: String?
  private var channelMappings = ChannelMappings()
  /// UDP socket pairs keyed by stream index (UDP transport only); empty for TCP.
  private var udpPairs: [Int: UDPPair] = [:]
  private var inorderParsers: [Int: InorderParser] = [:]
  private var userAgent: String?
  /// Selected RTP transport; drives SETUP, the receive loop, and parser config.
  private var transport: Transport = .tcp
  /// RTSP server host from the URL; the UDP RTP/RTCP peer fallback when SETUP
  /// omits an explicit `source`.
  private var host: String?
  private var isPlaying = false
  /// True while a `frames()` reader loop owns the connection. A second
  /// concurrent reader would race the same socket and corrupt the RTP pipeline,
  /// so it is rejected.
  private var isStreaming = false
  private var onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)?
  /// Session timeout advertised by the server in the SETUP `Session` header,
  /// in seconds. Drives the keepalive interval while streaming.
  private var sessionTimeoutSec: UInt32 = 60
  /// Whether the server advertised `GET_PARAMETER` in its OPTIONS `Public`
  /// header. When true it is preferred over `OPTIONS` as the keepalive method.
  private var getParameterSupported = false
  /// Control responses awaited by `sendControlRequest`, keyed by CSeq. The
  /// `streamFrames` reader resumes them as matching responses arrive.
  private var pendingResponses: [UInt32: CheckedContinuation<RTSPResponse, Error>] = [:]
  /// Per-CSeq timeout tasks, cancelled as soon as the waiter resolves so a fast
  /// response doesn't leave a sleeping task lingering for the full timeout.
  private var pendingTimeouts: [UInt32: Task<Void, Never>] = [:]
  /// The periodic keepalive task, active only while streaming.
  private var keepaliveTask: Task<Void, Never>?
  /// Why the UDP control connection closed, recorded by the control reader so
  /// the consumer loop can distinguish a clean stop() from a peer drop after the
  /// event stream finishes. nil while the connection is healthy.
  private var udpControlError: RTSPError?
  /// Test-only override of the keepalive interval; nil derives it from the
  /// server's advertised session timeout.
  private var keepaliveIntervalOverride: Duration?
  /// Bound on the UDP multiplexing buffer. RTP, RTCP, and control events queue
  /// here between the socket readers and the actor-isolated consumer; under
  /// normal operation the consumer keeps up and it never fills. If a stalled
  /// consumer ever overruns it, the oldest datagrams are dropped (surfacing as
  /// RTP loss) rather than the buffer growing without bound.
  private static let udpEventBufferCount = 4096

  func start(
    url: String,
    credentials: Credentials?,
    transport: Transport,
    userAgent: String,
    onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)?,
    keepaliveInterval: Duration? = nil
  ) async throws -> SessionDescription {
    self.onDiagnostic = onDiagnostic
    self.keepaliveIntervalOverride = keepaliveInterval
    self.transport = transport

    // Parse URL
    guard let urlComponents = URLComponents(string: url) else {
      throw RTSPError.connectionFailed("Invalid URL: \(url)")
    }
    let host = unbracketedHost(urlComponents.host ?? "localhost")
    let rawPort = urlComponents.port ?? 554
    guard let port = UInt16(exactly: rawPort) else {
      throw RTSPError.connectionFailed("Invalid port \(rawPort) in URL: \(url)")
    }

    self.host = host
    self.userAgent = userAgent

    // Set up authenticator
    if let creds = credentials {
      authenticator = RTSPAuthenticator(credentials: creds)
    }

    // Connect
    let conn = RTSPTransportConnection()
    try await conn.connect(host: host, port: port)
    connection = conn

    // OPTIONS (best-effort): discover whether the server supports
    // GET_PARAMETER, which is the preferred keepalive method. A server that
    // rejects or omits OPTIONS just leaves us defaulting to OPTIONS keepalive.
    if let optionsResp = try? await sendRequest(method: .options, url: url) {
      getParameterSupported = parseOptions(response: optionsResp).getParameterSupported
    }

    // DESCRIBE
    let describeResp = try await sendRequest(
      method: .describe,
      url: url,
      extraHeaders: [("Accept", "application/sdp")]
    )
    var presMut = try parseDescribe(
      requestURL: url, response: describeResp, onDiagnostic: onDiagnostic)
    presentation = presMut

    self.url = url

    // Find first H.264 or H.265 video stream — optional. Cameras can be
    // configured to expose audio-only or metadata-only RTSP sessions
    // (e.g. Axis with `video=0`), in which case we proceed without video
    // and require at least one of audio/metadata to be set up.
    let videoIdx = presMut.streams.firstIndex(where: {
      $0.media == "video" && isVideoEncodingSupported($0.encodingName)
    })
    var videoSetupSSRC: UInt32?

    if let videoIdx = videoIdx {
      let stream = presMut.streams[videoIdx]
      let setup = try await setupStream(
        controlURL: stream.control ?? url, streamIndex: videoIdx)
      videoSetupSSRC = setup.ssrc
      presMut.streams[videoIdx].state = .setup(
        StreamStateInit(ssrc: setup.ssrc, initialSeq: nil, initialRtptime: nil, ctx: .dummy))
      self.videoStreamIndex = videoIdx
    }

    // Find and SETUP audio stream (optional, best-effort)
    let audioIdx = presMut.streams.firstIndex(where: { s in
      s.media == "audio" && isAudioEncodingSupported(s.encodingName)
    })
    var audioSetupSSRC: UInt32?

    if let audioIdx = audioIdx {
      let audioStream = presMut.streams[audioIdx]
      let audioSetup = try await setupStream(
        controlURL: audioStream.control ?? url, streamIndex: audioIdx)
      audioSetupSSRC = audioSetup.ssrc
      presMut.streams[audioIdx].state = .setup(
        StreamStateInit(ssrc: audioSetup.ssrc, initialSeq: nil, initialRtptime: nil, ctx: .dummy))

      audioStreamIndex = audioIdx
      audioEncodingName = audioStream.encodingName
      audioClockRate = audioStream.clockRateHz
      audioChannels = audioStream.channels
    }

    // Find and SETUP application (metadata) stream — optional, best-effort.
    // If SETUP fails (camera advertises the stream but rejects it, or any
    // transport error), disable metadata locally rather than aborting the
    // session. The channel slot stays assigned (no other streams follow).
    var applicationIdx = presMut.streams.firstIndex(where: { s in
      s.media == "application" && isApplicationEncodingSupported(s.encodingName)
    })
    var applicationSetupSSRC: UInt32?

    if let idx = applicationIdx {
      let applicationStream = presMut.streams[idx]
      do {
        let applicationSetup = try await setupStream(
          controlURL: applicationStream.control ?? url, streamIndex: idx)
        applicationSetupSSRC = applicationSetup.ssrc
        presMut.streams[idx].state = .setup(
          StreamStateInit(
            ssrc: applicationSetup.ssrc, initialSeq: nil,
            initialRtptime: nil, ctx: .dummy))

        applicationStreamIndex = idx
        applicationEncodingName = applicationStream.encodingName
      } catch {
        onDiagnostic?(
          RTSPDiagnostic(
            severity: .warning,
            message:
              "Application SETUP failed: \(error); "
              + "metadata will not be delivered."))
        applicationIdx = nil
      }
    }

    // Require at least one usable stream — a session with no video, audio,
    // or metadata is degenerate (DESCRIBE succeeded but nothing is carrying
    // payload), and sending PLAY would just open the door to packets we
    // can't route.
    if videoStreamIndex == nil && audioStreamIndex == nil && applicationStreamIndex == nil {
      let offered = presMut.streams.map { "\($0.media)/\($0.encodingName)" }
        .joined(separator: ", ")
      throw RTSPError.sessionSetupFailed(
        statusCode: 0,
        reason:
          "No supported video, audio, or metadata stream was set up "
          + "(offered: \(offered.isEmpty ? "<none>" : offered)).")
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

    // Surface (once) any interleaved media the camera streamed on the control
    // channel before its PLAY response completed — those frames were dropped.
    let droppedPrePlay = await conn.droppedInterleavedBeforeResponse
    if droppedPrePlay > 0 {
      onDiagnostic?(
        RTSPDiagnostic(
          severity: .warning,
          message: "Dropped \(droppedPrePlay) interleaved frame(s) on the control channel "
            + "before the PLAY response completed; camera streamed before PLAY."))
    }

    // UDP NAT/firewall hole-punch: now that the server is sending (post-PLAY),
    // poke each local RTP/RTCP port toward its peer so inbound datagrams can
    // traverse a NAT. Best-effort and a no-op on loopback/LAN.
    if transport == .udp {
      for pair in udpPairs.values {
        pair.holePunch()
      }
    }

    // Initialize video depacketizer + timeline + inorder parser. Conditional
    // on a successful video SETUP — when no video stream was set up,
    // `videoStreamIndex` is nil and we skip the entire video pipeline.
    var videoClockRate: UInt32?
    if let videoIdx = videoStreamIndex {
      let stream = presMut.streams[videoIdx]
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
      // If the SDP advertised parameter sets (sprop-*) but the depacketizer
      // couldn't parse them, it silently falls back to in-band parameters;
      // surface that, since the first decodable frame may be delayed.
      if let fmtp = stream.formatSpecificParams,
        fmtp.lowercased().contains("sprop"),
        depacketizer?.videoParameters == nil
      {
        onDiagnostic?(
          RTSPDiagnostic(
            severity: .warning,
            message: "Video fmtp advertised sprop parameter sets but they could not be "
              + "parsed; falling back to in-band parameters."))
      }
      videoClockRate = stream.clockRateHz

      var videoStart: UInt32?
      var videoSeq: UInt16?
      var videoSsrc: UInt32? = videoSetupSSRC

      if case .setup(let init_) = presMut.streams[videoIdx].state {
        videoStart = init_.initialRtptime
        // Adopt the RTP-Info initial sequence so loss before the first received
        // packet is detected. Only ignore the `seq=0;rtptime=0` placeholder some
        // cameras emit instead of a real seed (finding #50).
        if let seq = init_.initialSeq, !(seq == 0 && (init_.initialRtptime ?? 0) == 0) {
          videoSeq = seq
        }
        if let s = init_.ssrc { videoSsrc = s }
      }

      let timeline = try Timeline(start: videoStart, clockRate: stream.clockRateHz)
      inorderParsers[videoIdx] = InorderParser(
        ssrc: videoSsrc, nextSeq: videoSeq, isTcp: transport == .tcp,
        timeline: timeline, onDiagnostic: onDiagnostic)
    }

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
          // See the video seed above (finding #50): only the placeholder is ignored.
          if let seq = init_.initialSeq, !(seq == 0 && (init_.initialRtptime ?? 0) == 0) {
            audioSeq = seq
          }
          if let s = init_.ssrc { resolvedAudioSsrc = s }
        }

        do {
          let audioTimeline = try Timeline(
            start: audioStart, clockRate: audioStream.clockRateHz)
          inorderParsers[audioIdx] = InorderParser(
            ssrc: resolvedAudioSsrc, nextSeq: audioSeq,
            isTcp: transport == .tcp, timeline: audioTimeline,
            onDiagnostic: onDiagnostic)
          resolvedAudioCodec = publicAudioCodec(
            from: audioStream.encodingName)
          resolvedAudioRate = audioStream.clockRateHz
          resolvedAudioChannels = audioStream.channels
        } catch {
          // Audio is best-effort: a broken clock rate must not abort the
          // whole session. Disable audio and carry on (mirrors metadata).
          onDiagnostic?(
            RTSPDiagnostic(
              severity: .warning,
              message:
                "Failed to initialize audio timeline: \(error); "
                + "audio will not be delivered."))
          audioDepacketizer = nil
          audioStreamIndex = nil
          audioEncodingName = nil
          audioClockRate = nil
          audioChannels = nil
        }
      } else {
        // Audio SETUP succeeded but the depacketizer rejected the format
        // (e.g. malformed AAC fmtp). Null the audio state so packets on
        // that interleaved channel are silently dropped instead of
        // misrouted, and so `SessionDescription.audio` is `nil` (matching
        // reality). Mirrors the metadata-init failure path below.
        onDiagnostic?(
          RTSPDiagnostic(
            severity: .warning,
            message:
              "Audio depacketizer init failed for "
              + "\(audioStream.encodingName); audio will not be delivered."))
        audioStreamIndex = nil
        audioEncodingName = nil
        audioClockRate = nil
        audioChannels = nil
      }
    }

    // Initialize application (metadata) depacketizer + inorder parser.
    // Best-effort: if the timeline can't be built (e.g. malformed clock
    // rate in SDP), disable the stream rather than failing the session.
    if let applicationIdx = applicationIdx {
      let applicationStream = presMut.streams[applicationIdx]

      var applicationStart: UInt32?
      var applicationSeq: UInt16?
      var resolvedApplicationSsrc = applicationSetupSSRC

      if case .setup(let init_) = presMut.streams[applicationIdx].state {
        applicationStart = init_.initialRtptime
        // See the video seed above (finding #50): only the placeholder is ignored.
        if let seq = init_.initialSeq, !(seq == 0 && (init_.initialRtptime ?? 0) == 0) {
          applicationSeq = seq
        }
        if let s = init_.ssrc { resolvedApplicationSsrc = s }
      }

      do {
        let applicationTimeline = try Timeline(
          start: applicationStart, clockRate: applicationStream.clockRateHz)
        inorderParsers[applicationIdx] = InorderParser(
          ssrc: resolvedApplicationSsrc, nextSeq: applicationSeq,
          isTcp: transport == .tcp, timeline: applicationTimeline,
          onDiagnostic: onDiagnostic)
        applicationDepacketizer = ApplicationDepacketizer(onDiagnostic: onDiagnostic)
      } catch {
        onDiagnostic?(
          RTSPDiagnostic(
            severity: .warning,
            message:
              "Failed to initialize application stream: \(error); "
              + "metadata will not be delivered."))
        applicationStreamIndex = nil
        applicationEncodingName = nil
      }
    }

    // Post-init gate. The pre-PLAY gate above caught the case where no
    // stream was supported, but audio and metadata depacketizer init run
    // *after* PLAY and can null their own indices on failure (malformed
    // AAC fmtp, broken Timeline clock rate, etc.). Re-check here so the
    // documented "at least one usable stream" invariant holds at the
    // return site too. PLAY has already been sent; the caller will tear
    // down via `stop()` after we throw.
    if videoStreamIndex == nil && audioStreamIndex == nil && applicationStreamIndex == nil {
      throw RTSPError.sessionSetupFailed(
        statusCode: 0,
        reason:
          "All stream depacketizers failed to initialize after PLAY; "
          + "session has no usable streams.")
    }

    isPlaying = true

    // Build session description. `video` is nil when no video stream was
    // set up; consumers branch on `desc.video != nil` to discover availability.
    // `depacketizer` and `videoClockRate` are set in lock-step inside the
    // video-init block above, so the outer `if let` enforces that invariant.
    let video: VideoStream?
    if let depkt = depacketizer, let clockRate = videoClockRate {
      switch depkt {
      case .h264(let d):
        let dims = d.parameters?.genericParameters.pixelDimensions
        video = VideoStream(
          codec: .h264,
          clockRate: clockRate,
          sps: d.parameters?.spsNAL,
          pps: d.parameters?.ppsNAL,
          vps: nil,
          resolution: dims.map { (width: Int($0.width), height: Int($0.height)) }
        )
      case .h265(let d):
        let dims = d.parameters?.genericParameters.pixelDimensions
        video = VideoStream(
          codec: .h265,
          clockRate: clockRate,
          sps: d.parameters?.spsNAL,
          pps: d.parameters?.ppsNAL,
          vps: d.parameters?.vpsNAL,
          resolution: dims.map { (width: Int($0.width), height: Int($0.height)) }
        )
      }
    } else {
      video = nil
    }

    let audio: AudioStream?
    if let codec = resolvedAudioCodec, let rate = resolvedAudioRate {
      audio = AudioStream(
        codec: codec,
        sampleRate: rate,
        channels: resolvedAudioChannels,
        extraData: audioDepacketizer?.audioParameters?.extraData
      )
    } else {
      audio = nil
    }

    return SessionDescription(
      video: video,
      audio: audio,
      metadataEncoding: applicationEncodingName
    )
  }

  func streamFrames(
    continuation: AsyncThrowingStream<PublicCodecItem, Error>.Continuation
  ) async throws {
    guard let conn = connection, isPlaying else {
      continuation.finish()
      return
    }

    // frames() may be consumed by only one reader at a time; a second concurrent
    // reader would race the same connection. The check-and-set is atomic (no
    // await between them on this actor).
    guard !isStreaming else {
      continuation.finish(
        throwing: RTSPError.invalidState("frames() is already being consumed"))
      return
    }
    isStreaming = true
    defer { isStreaming = false }

    startKeepalive()
    defer {
      keepaliveTask?.cancel()
      keepaliveTask = nil
    }

    switch transport {
    case .tcp:
      try await streamFramesTCP(conn: conn, continuation: continuation)
    case .udp:
      try await streamFramesUDP(conn: conn, continuation: continuation)
    }

    continuation.finish()
  }

  /// TCP-interleaved reader loop. Owns the single TCP connection: it
  /// demultiplexes interleaved RTP/RTCP and routes RTSP responses (keepalive /
  /// TEARDOWN) back to their waiters. Runs until the socket closes — by stop()
  /// (clean) or by the peer (propagates the error).
  private func streamFramesTCP(
    conn: RTSPTransportConnection,
    continuation: AsyncThrowingStream<PublicCodecItem, Error>.Continuation
  ) async throws {
    while true {
      let msg: RTSPMessage
      do {
        msg = try await conn.receiveMessage()
      } catch {
        // After stop() set isPlaying = false, the socket close is expected —
        // end cleanly. Otherwise the peer dropped us; propagate the error.
        if !isPlaying { break }
        throw error
      }

      // Route control responses (keepalive / TEARDOWN) to their awaiting sender.
      if case .response(let resp) = msg {
        if let cseq = resp.cseq { resumePending(cseq, .success(resp)) }
        continue
      }

      guard case .data(let interleaved) = msg else { continue }
      guard let mapping = channelMappings.lookup(interleaved.channelId) else {
        // The camera sent interleaved data on a channel we never negotiated.
        // Drop it (can't route it) but surface it once per channel.
        warnStreamOnce(
          "channel.\(interleaved.channelId)", .warning,
          "Interleaved data on unassigned channel \(interleaved.channelId); dropped.")
        continue
      }

      if mapping.channelType == .rtp {
        try routeRTP(
          streamIndex: mapping.streamIndex, data: interleaved.data, continuation: continuation)
      } else if mapping.channelType == .rtcp {
        try routeRTCP(
          streamIndex: mapping.streamIndex, data: interleaved.data, continuation: continuation)
      }
    }
  }

  /// UDP reader loop. RTP and RTCP arrive on per-stream UDP sockets while RTSP
  /// control (keepalive / TEARDOWN responses) stays on the TCP connection, so
  /// the three sources are multiplexed through one ordered event stream and fed
  /// to the same routing pipeline as TCP. Runs until the TCP control connection
  /// closes — by stop() (clean) or by the peer (propagates the error).
  private func streamFramesUDP(
    conn: RTSPTransportConnection,
    continuation: AsyncThrowingStream<PublicCodecItem, Error>.Continuation
  ) async throws {
    udpControlError = nil
    let (events, eventCont) = AsyncStream.makeStream(
      of: UDPTransportEvent.self,
      bufferingPolicy: .bufferingNewest(Self.udpEventBufferCount))

    // Per-stream UDP receivers feed RTP/RTCP datagrams into the event stream.
    // Each socket's DispatchSource is serial, so per-stream packet order holds.
    let diag = onDiagnostic
    for (idx, pair) in udpPairs {
      pair.startReceiving(
        onRTP: { eventCont.yield(.rtp(streamIndex: idx, data: $0)) },
        onRTCP: { eventCont.yield(.rtcp(streamIndex: idx, data: $0)) },
        onError: { error in
          // Surface the terminal receive error so a NAT'd camera whose UDP flow
          // dies isn't a silent stall. (Control stays on TCP; keepalive/TEARDOWN
          // still work.)
          diag?(
            RTSPDiagnostic(
              severity: .warning,
              message: "UDP receive on stream \(idx) stopped: \(error)"))
        })
    }

    // The TCP connection now carries only control responses (no interleaved
    // data). The control reader handles keepalive/TEARDOWN responses directly
    // (off the lossy data buffer) and, on close, records why and ends the event
    // stream so the consumer unblocks even if no more datagrams arrive.
    let controlReader = Task { [weak self] in
      while true {
        let msg: RTSPMessage
        do {
          msg = try await conn.receiveMessage()
        } catch {
          let rtspError = (error as? RTSPError) ?? .connectionFailed("\(error)")
          await self?.recordUDPControlClose(rtspError)
          eventCont.finish()
          return
        }
        if case .response(let resp) = msg, let cseq = resp.cseq {
          await self?.resumePending(cseq, .success(resp))
        }
        // Interleaved data isn't expected on a UDP session; ignore it.
      }
    }

    // The consumer owns teardown: stop the control reader and release the UDP
    // sockets (stop() also closes the pairs — close() is idempotent). The reader
    // task may linger blocked on receiveMessage until stop() closes the TCP
    // connection; that is the documented contract for releasing the session.
    defer {
      controlReader.cancel()
      eventCont.finish()
      for pair in udpPairs.values { pair.close() }
    }

    for await event in events {
      switch event {
      case .rtp(let idx, let data):
        try routeRTP(streamIndex: idx, data: data, continuation: continuation)
      case .rtcp(let idx, let data):
        try routeRTCP(streamIndex: idx, data: data, continuation: continuation)
      }
    }

    // The stream finished, which only happens when the control connection
    // closed. A clean stop() (isPlaying == false) ends here; a peer drop while
    // still playing propagates the recorded transport error.
    if isPlaying, let error = udpControlError {
      throw error
    }
  }

  /// Record the error that closed the UDP session's TCP control connection.
  /// Called by the control reader so the consumer can classify the close.
  private func recordUDPControlClose(_ error: RTSPError) {
    udpControlError = error
  }

  /// One-shot latch keys for per-stream conditions that can recur per packet or
  /// per frame, so a sloppy/hostile camera can't flood `onDiagnostic`.
  private var warnedStreamConditions: Set<String> = []

  /// Emit `message` only the first time `key` is seen this session.
  private func warnStreamOnce(
    _ key: String, _ severity: RTSPDiagnostic.Severity, _ message: @autoclosure () -> String
  ) {
    guard warnedStreamConditions.insert(key).inserted else { return }
    onDiagnostic?(RTSPDiagnostic(severity: severity, message: message()))
  }

  /// Surface (once each) the FU-reassembly anomalies the video depacketizer
  /// tracks — an inconsistent FU NAL header or an RFC-forbidden single-fragment
  /// FU — both tolerated but worth telling the consumer about.
  private func surfaceVideoAnomalies(_ depkt: VideoDepacketizer) {
    let inconsistentFu: Bool
    let singleFragmentFu: Bool
    switch depkt {
    case .h264(let d):
      inconsistentFu = d.seenInconsistentFuANalHdr
      singleFragmentFu = d.seenSingleFragmentFuA
    case .h265(let d):
      inconsistentFu = d.seenInconsistentFuNalHdr
      singleFragmentFu = d.seenSingleFragmentFu
    }
    if inconsistentFu {
      warnStreamOnce(
        "video.fuHeaderInconsistent", .warning,
        "Camera sent FU fragments with an inconsistent NAL header; tolerated.")
    }
    if singleFragmentFu {
      warnStreamOnce(
        "video.singleFragmentFu", .info,
        "Camera sent a single-fragment FU (RFC-forbidden); treated as a complete NAL.")
    }
  }

  /// Route one RTP packet to its stream's depacketizer, yielding any completed
  /// frames. Shared by the TCP and UDP reader loops; a missing parser or
  /// depacketizer (a disabled stream) drops the packet. A malformed wire packet
  /// or a per-frame depacketization failure drops that packet/frame and emits a
  /// rate-limited diagnostic rather than tearing down the whole stream — only
  /// the opt-in `.abortSession` SSRC policy still propagates fatally.
  private func routeRTP(
    streamIndex: Int, data: Data,
    continuation: AsyncThrowingStream<PublicCodecItem, Error>.Continuation
  ) throws {
    guard var parser = inorderParsers[streamIndex] else { return }
    defer { inorderParsers[streamIndex] = parser }

    if let videoIdx = videoStreamIndex, streamIndex == videoIdx {
      guard var depkt = depacketizer else { return }
      defer { depacketizer = depkt }
      guard
        let pkt = try parser.rtp(
          data: data, ctx: .dummy, streamId: streamIndex, streamCtx: .dummy)
      else { return }
      if pkt.payload.isEmpty {
        warnStreamOnce(
          "video.empty", .warning, "Empty video RTP payload from camera; packets skipped.")
      }
      do {
        try depkt.push(pkt)
      } catch {
        warnStreamOnce(
          "video.push", .error, "Video depacketizer push failed; packet dropped: \(error)")
        return
      }
      surfaceVideoAnomalies(depkt)
      while let result = depkt.pull() {
        switch result {
        case .success(.videoFrame(let frame)):
          continuation.yield(.video(convertFrame(frame, depacketizer: depkt)))
        case .failure(let err):
          warnStreamOnce(
            "video.pull", .error, "Video depacketization failed; frame dropped: \(err)")
        default:
          break
        }
      }
    } else if let audioIdx = audioStreamIndex, streamIndex == audioIdx {
      guard var depkt = audioDepacketizer else { return }
      defer { audioDepacketizer = depkt }
      guard
        let pkt = try parser.rtp(
          data: data, ctx: .dummy, streamId: streamIndex, streamCtx: .dummy)
      else { return }
      do {
        try depkt.push(pkt)
      } catch {
        warnStreamOnce(
          "audio.push", .error, "Audio depacketizer push failed; packet dropped: \(error)")
        return
      }
      while let result = depkt.pull() {
        switch result {
        case .success(.audioFrame(let frame)):
          continuation.yield(
            .audio(
              PublicAudioFrame(
                data: frame.data,
                timestamp: frame.timestamp.elapsedSeconds,
                codec: publicAudioCodec(from: audioEncodingName ?? ""),
                sampleRate: audioClockRate ?? 0,
                channels: audioChannels,
                loss: frame.loss)))
        case .failure(let err):
          warnStreamOnce(
            "audio.pull", .error, "Audio depacketization failed; frame dropped: \(err)")
        default:
          break
        }
      }
    } else if let applicationIdx = applicationStreamIndex, streamIndex == applicationIdx {
      guard var depkt = applicationDepacketizer else { return }
      defer { applicationDepacketizer = depkt }
      guard
        let pkt = try parser.rtp(
          data: data, ctx: .dummy, streamId: streamIndex, streamCtx: .dummy)
      else { return }
      do {
        try depkt.push(pkt)
      } catch {
        warnStreamOnce(
          "metadata.push", .error, "Metadata depacketizer push failed; packet dropped: \(error)")
        return
      }
      while let result = depkt.pull() {
        switch result {
        case .success(.metadataFrame(let frame)):
          continuation.yield(
            .metadata(
              PublicMetadataFrame(
                data: frame.data,
                timestamp: frame.timestamp.elapsedSeconds,
                encodingName: applicationEncodingName ?? "",
                loss: frame.loss)))
        case .failure(let err):
          warnStreamOnce(
            "metadata.pull", .error, "Metadata depacketization failed; frame dropped: \(err)")
        default:
          break
        }
      }
    }
  }

  /// Route one RTCP packet to its stream's parser, yielding a public RTCP item
  /// when a sender report is parsed. Shared by both reader loops.
  private func routeRTCP(
    streamIndex: Int, data: Data,
    continuation: AsyncThrowingStream<PublicCodecItem, Error>.Continuation
  ) throws {
    guard var parser = inorderParsers[streamIndex] else { return }
    defer { inorderParsers[streamIndex] = parser }
    if let rtcpPkt = try parser.rtcp(ctx: .dummy, streamId: streamIndex, data: data) {
      continuation.yield(
        .rtcp(
          PublicRTCPPacket(
            timestamp: rtcpPkt.rtpTimestamp?.elapsedSeconds, data: rtcpPkt.raw)))
    }
  }

  func stop() async {
    let wasPlaying = isPlaying
    isPlaying = false
    keepaliveTask?.cancel()
    keepaliveTask = nil

    if connection != nil, sessionId != nil, let url = self.url {
      // TEARDOWN (best-effort). While playing, the reader loop owns the socket,
      // so route the response through it — a competing read here would let the
      // reader consume the TEARDOWN response and hang this call until the
      // server's session timeout (~60s). Before PLAY there is no reader, so the
      // normal request path (which reads its own response) is safe.
      if wasPlaying {
        _ = try? await sendControlRequest(method: .teardown, timeoutSeconds: 5)
      } else {
        _ = try? await sendRequest(method: .teardown, url: url)
      }
    }

    // Closing the socket unblocks the reader's pending receive (it ends cleanly
    // because isPlaying is now false) and lets us fail any outstanding waiter.
    await connection?.close()
    failAllPending(RTSPError.unexpectedDisconnection)
    connection = nil

    // Release any UDP RTP/RTCP sockets (no-op for TCP). close() is idempotent,
    // so the UDP reader loop's defer closing them too is harmless.
    for pair in udpPairs.values {
      pair.close()
    }
    udpPairs.removeAll()
  }

  // MARK: - Control channel (keepalive / TEARDOWN while streaming)

  /// Send a control request on the streaming connection and await its response,
  /// which the `streamFrames` reader loop routes back by CSeq. Used while RTP is
  /// interleaved on the same TCP socket: the reader owns the socket, so we must
  /// not issue a competing read here. Bounded by `timeoutSeconds`.
  private func sendControlRequest(
    method: RTSPMethod,
    extraHeaders: [(String, String)] = [],
    timeoutSeconds: Double = 10
  ) async throws -> RTSPResponse {
    guard let conn = connection, let url = self.url else {
      throw RTSPError.connectionFailed("Not connected")
    }
    let cseq = nextCSeq()
    var request = RTSPRequest(method: method, url: url)
    request.setHeader("CSeq", value: "\(cseq)")
    if let userAgent = userAgent, !userAgent.isEmpty {
      request.setHeader("User-Agent", value: userAgent)
    }
    if let sid = sessionId {
      request.setHeader("Session", value: sid)
    }
    if authenticator?.hasChallenge == true,
      let authHeader = authenticator!.authorize(method: method.rawValue, uri: url)
    {
      request.setHeader("Authorization", value: authHeader)
    }
    for (name, value) in extraHeaders {
      request.setHeader(name, value: value)
    }
    let data = RTSPSerializer().serialize(request)

    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<RTSPResponse, any Error>) in
      // Register the waiter BEFORE the bytes go out so the reader can never see
      // the response before we are ready to receive it.
      pendingResponses[cseq] = continuation
      Task {
        do {
          try await conn.send(data)
        } catch {
          self.resumePending(cseq, .failure(.connectionFailed("control send failed: \(error)")))
        }
      }
      pendingTimeouts[cseq] = Task {
        try? await Task.sleep(for: .seconds(timeoutSeconds))
        self.resumePending(cseq, .failure(.timeout))
      }
    }
  }

  /// Resume (exactly once) the waiter for `cseq`, if still pending. The
  /// remove-then-resume is actor-isolated, so the reader, a send failure, and
  /// the timeout can race safely — the first to run wins, the rest no-op.
  private func resumePending(_ cseq: UInt32, _ result: Result<RTSPResponse, RTSPError>) {
    // Cancel the (now-moot) timeout task; its only action after the sleep is a
    // no-op resumePending, so cancelling is always safe.
    pendingTimeouts.removeValue(forKey: cseq)?.cancel()
    guard let continuation = pendingResponses.removeValue(forKey: cseq) else { return }
    switch result {
    case .success(let response): continuation.resume(returning: response)
    case .failure(let error): continuation.resume(throwing: error)
    }
  }

  /// Fail every outstanding control waiter (e.g. when the connection is torn
  /// down), so no `sendControlRequest` is left suspended.
  private func failAllPending(_ error: RTSPError) {
    for task in pendingTimeouts.values { task.cancel() }
    pendingTimeouts.removeAll()
    let waiters = pendingResponses
    pendingResponses.removeAll()
    for (_, continuation) in waiters {
      continuation.resume(throwing: error)
    }
  }

  /// Start the periodic keepalive at roughly half the server's advertised
  /// session timeout, preferring GET_PARAMETER when the server advertised it,
  /// else OPTIONS. Runs until the reader loop ends or `stop()` cancels it.
  private func startKeepalive() {
    keepaliveTask?.cancel()
    let period = keepaliveIntervalOverride ?? .seconds(max(1.0, Double(sessionTimeoutSec) / 2.0))
    let method: RTSPMethod = getParameterSupported ? .getParameter : .options
    keepaliveTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: period)
        guard !Task.isCancelled, let self else { return }
        await self.sendKeepalive(method: method)
      }
    }
  }

  /// Send one keepalive request, surfacing the outcome as a diagnostic. Failures
  /// are non-fatal — the stream keeps running and the next tick retries.
  private func sendKeepalive(method: RTSPMethod) async {
    guard isPlaying else { return }
    do {
      _ = try await sendControlRequest(method: method, timeoutSeconds: 10)
      onDiagnostic?(
        RTSPDiagnostic(
          severity: .info, message: "RTSP keepalive (\(method.rawValue)) acknowledged"))
    } catch {
      onDiagnostic?(
        RTSPDiagnostic(
          severity: .warning, message: "RTSP keepalive (\(method.rawValue)) failed: \(error)"))
    }
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

    if authenticator?.hasChallenge == true {
      if let authHeader = authenticator!.authorize(method: method.rawValue, uri: url) {
        request.setHeader("Authorization", value: authHeader)
      }
    }

    for (name, value) in extraHeaders {
      request.setHeader(name, value: value)
    }

    let resp = try await conn.sendRequest(request)

    // Handle 401 Unauthorized — retry with auth.
    if resp.statusCode == 401 {
      if var auth = authenticator {
        // Feed every challenge (a server may offer Basic and Digest on separate
        // WWW-Authenticate lines) so Digest wins regardless of ordering.
        for challenge in resp.headers(named: "WWW-Authenticate") {
          auth.handleChallenge(challenge)
        }
        authenticator = auth
        if auth.hasChallenge {
          // Rebuild the retry the same way the first attempt did: a 401 on
          // SETUP/PLAY requires the Session (and User-Agent) headers preserved,
          // or the retry is rejected. Authorization is set last so a freshly
          // computed digest isn't clobbered by a caller-supplied extra header.
          var retryRequest = RTSPRequest(method: method, url: url)
          retryRequest.setHeader("CSeq", value: "\(nextCSeq())")
          if let userAgent = userAgent, !userAgent.isEmpty {
            retryRequest.setHeader("User-Agent", value: userAgent)
          }
          if let sid = sessionId {
            retryRequest.setHeader("Session", value: sid)
          }
          for (name, value) in extraHeaders {
            retryRequest.setHeader(name, value: value)
          }
          if let authHeader = auth.authorize(method: method.rawValue, uri: url) {
            retryRequest.setHeader("Authorization", value: authHeader)
          }
          // Persist after authorize so the advanced nonce-count survives.
          authenticator = auth
          let retryResp = try await conn.sendRequest(retryRequest)
          if retryResp.statusCode == 401 {
            if auth.hasBasicChallenge,
              let basicResp = try await retryWithBasicFallback(
                auth: &auth, method: method, url: url, extraHeaders: extraHeaders)
            {
              authenticator = auth
              return basicResp
            }
            throw RTSPError.authenticationFailed
          }
          guard retryResp.statusCode >= 200 && retryResp.statusCode < 300 else {
            throw RTSPError.sessionSetupFailed(
              statusCode: Int(retryResp.statusCode), reason: retryResp.reasonPhrase)
          }
          return retryResp
        }
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

  /// Retry once with Basic auth after a Digest retry was rejected by a server
  /// that advertised both schemes. This handles cameras that claim Digest
  /// support but only accept Basic for RTSP.
  private func retryWithBasicFallback(
    auth: inout RTSPAuthenticator,
    method: RTSPMethod,
    url: String,
    extraHeaders: [(String, String)]
  ) async throws -> RTSPResponse? {
    guard let conn = connection,
      let authHeader = auth.authorizeBasicFallback()
    else { return nil }

    var request = RTSPRequest(method: method, url: url)
    request.setHeader("CSeq", value: "\(nextCSeq())")
    if let userAgent = userAgent, !userAgent.isEmpty {
      request.setHeader("User-Agent", value: userAgent)
    }
    if let sid = sessionId {
      request.setHeader("Session", value: sid)
    }
    for (name, value) in extraHeaders {
      request.setHeader(name, value: value)
    }
    request.setHeader("Authorization", value: authHeader)

    let resp = try await conn.sendRequest(request)
    if resp.statusCode == 401 {
      return nil
    }
    guard resp.statusCode >= 200 && resp.statusCode < 300 else {
      throw RTSPError.sessionSetupFailed(
        statusCode: Int(resp.statusCode), reason: resp.reasonPhrase)
    }
    return resp
  }

  private func nextCSeq() -> UInt32 {
    cseq += 1
    return cseq
  }

  /// SETUP one stream using the selected transport. Returns the parsed SETUP
  /// response; both paths roll the session id forward and, as a side effect,
  /// record where the stream's data will arrive (a TCP interleaved channel or a
  /// bound UDP socket pair in `udpPairs`).
  private func setupStream(
    controlURL: String, streamIndex: Int
  ) async throws -> SetupResponse {
    switch transport {
    case .tcp:
      return try await setupStreamTCP(controlURL: controlURL, streamIndex: streamIndex)
    case .udp:
      return try await setupStreamUDP(controlURL: controlURL, streamIndex: streamIndex)
    }
  }

  /// Adopt the session id and timeout from a SETUP response, warning when the
  /// camera renumbers the session mid-handshake.
  private func adoptSession(_ setup: SetupResponse) {
    if let prev = sessionId, prev != setup.session.id {
      onDiagnostic?(
        RTSPDiagnostic(
          severity: .warning,
          message:
            "Camera issued a new Session ID at SETUP "
            + "(\(prev) -> \(setup.session.id)); rolling forward."))
    }
    sessionId = setup.session.id
    sessionTimeoutSec = setup.session.timeoutSec
  }

  /// SETUP one stream over TCP-interleaved transport, assigning its channel
  /// pair. We request the next free even channel, but adopt the server's
  /// interleaved channel when it renumbers to a different free even channel so
  /// routing matches where the data actually arrives (the `Session` header is
  /// added by `sendRequest`).
  private func setupStreamTCP(
    controlURL: String, streamIndex: Int
  ) async throws -> SetupResponse {
    let requested = channelMappings.nextUnassigned() ?? 0
    let headers = [
      (
        "Transport",
        "RTP/AVP/TCP;unicast;interleaved=\(requested)-\(Int(requested) + 1)"
      )
    ]
    let resp = try await sendRequest(
      method: .setup, url: controlURL, extraHeaders: headers)
    let setup = try parseSetup(response: resp)
    adoptSession(setup)

    let channel: UInt8
    if let server = setup.channelId, server % 2 == 0,
      channelMappings.lookup(server) == nil
    {
      channel = server
    } else {
      channel = requested
    }
    try channelMappings.assign(channelId: channel, streamIndex: streamIndex)
    return setup
  }

  /// SETUP one stream over a UDP socket pair. Binds a local even/odd RTP/RTCP
  /// pair, advertises it via `client_port`, then connects the sockets to the
  /// server's `server_port` (RTCP = RTP + 1, enforced by `parseSetup`). The
  /// connected pair is recorded in `udpPairs`; on any failure its sockets are
  /// released before rethrowing.
  ///
  /// The local socket family (IPv4 / IPv6) is taken from the resolved control
  /// connection so it matches the server, and the RTP/RTCP peer is chosen from a
  /// candidate of the same family — IPv4 and IPv6 peers (including `[::1]`) both
  /// work.
  private func setupStreamUDP(
    controlURL: String, streamIndex: Int
  ) async throws -> SetupResponse {
    // Pick the local socket family from the resolved control-connection peer
    // (the same host the server's RTP/RTCP will come from). Fall back to the URL
    // host's family, then IPv4. Resolved before SETUP since `bind()` needs it.
    let resolved = await connection?.resolvedRemote()
    let peerIsIPv6: Bool
    if let resolved {
      peerIsIPv6 = resolved.isIPv6
    } else if let host, UDPPair.isNumericIPv6(host) {
      peerIsIPv6 = true
    } else {
      peerIsIPv6 = false
    }
    let family: UDPAddressFamily = peerIsIPv6 ? .ipv6 : .ipv4

    let pair = try await UDPPair.bind(family: family)
    do {
      let headers = [
        ("Transport", "RTP/AVP;unicast;client_port=\(pair.rtpPort)-\(pair.rtcpPort)")
      ]
      let resp = try await sendRequest(
        method: .setup, url: controlURL, extraHeaders: headers)
      let setup = try parseSetup(response: resp)
      adoptSession(setup)

      guard let serverRTPPort = setup.serverPort else {
        throw RTSPError.sessionSetupFailed(
          statusCode: Int(resp.statusCode),
          reason: "UDP SETUP response omitted server_port")
      }
      // Choose the RTP/RTCP peer. Prefer the server-advertised `source`, then
      // the resolved control-connection peer, then the URL host — but only a
      // numeric literal matching the bound socket family, since this path does
      // not resolve hostnames. The control connection's resolved peer is always
      // a numeric literal of the right family, so it backstops a hostname URL
      // (or a `source` given as a name / wrong family).
      let matchesFamily = peerIsIPv6 ? UDPPair.isNumericIPv6 : UDPPair.isNumericIPv4
      let peerHost =
        [setup.source, resolved?.host, host]
        .compactMap { $0 }
        .first(where: matchesFamily) ?? resolved?.host ?? family.loopback
      try await pair.connect(peerHost: peerHost, peerRTPPort: serverRTPPort)

      udpPairs[streamIndex] = pair
      return setup
    } catch {
      pair.close()
      throw error
    }
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

// MARK: - URL helpers (free functions, testable)

/// Strip the surrounding brackets from an IPv6 literal URL host.
///
/// Foundation's URL parser surfaces a bracketed IPv6 host verbatim
/// (`rtsp://[::1]:554/…` → `[::1]`), but `NWEndpoint.Host` expects the bare
/// address (e.g. `::1`, or `fe80::1%en0` with a zone id) and rejects the
/// bracketed form. A non-bracketed host (IPv4 / hostname) is returned unchanged.
func unbracketedHost(_ host: String) -> String {
  guard host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 else {
    return host
  }
  return String(host.dropFirst().dropLast())
}

// MARK: - Encoding-support predicates (free functions, testable)

/// True iff `RTSPClientSession` can depacketize a video stream advertising
/// this SDP `a=rtpmap` encoding name.
func isVideoEncodingSupported(_ name: String) -> Bool {
  switch name {
  case "h264", "h265":
    return true
  default:
    return false
  }
}

/// True iff `RTSPClientSession` can depacketize an audio stream advertising
/// this SDP `a=rtpmap` encoding name.
func isAudioEncodingSupported(_ name: String) -> Bool {
  switch name {
  case "mpeg4-generic", "pcmu", "pcma", "l16", "g722", "g723",
    "u8", "dvi4", "g726-16", "g726-24", "g726-32", "g726-40":
    return true
  default:
    return false
  }
}

/// True iff `RTSPClientSession` can depacketize an analytics-metadata stream
/// advertising this SDP `a=rtpmap` encoding name.
func isApplicationEncodingSupported(_ name: String) -> Bool {
  switch name {
  case "vnd.onvif.metadata":
    return true
  default:
    return false
  }
}
