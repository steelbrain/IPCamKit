// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/client/mod.rs - RTSP session state machine

import Foundation
import Network

/// Transport mode for RTP data.
public enum Transport: Sendable {
  /// RTP interleaved over the RTSP TCP connection. For an `rtsps://` URL (or an
  /// HTTPS/WSS tunnel) that connection is TLS, so the media is encrypted along
  /// with the control messages.
  case tcp
  /// RTP and RTCP on a separate UDP socket pair — an even local RTP port and the
  /// consecutive odd RTCP port — negotiated via `client_port` in SETUP. Works
  /// over both IPv4 and IPv6 peers. With an `rtsps://` URL the media is SRTP
  /// (`RTP/SAVP`), keyed with MIKEY over the TLS-protected RTSP session.
  case udp
  /// RTP and RTCP from a multicast group the server picks at SETUP
  /// (`Transport: RTP/AVP;multicast`), shared by every client watching the
  /// stream. On iOS, tvOS and visionOS receiving multicast requires the
  /// `com.apple.developer.networking.multicast` entitlement.
  case multicast
}

/// Video codec type.
public enum VideoCodec: Sendable {
  case h264
  case h265
}

/// Public audio codec type.
public enum PublicAudioCodec: Sendable, Hashable {
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
/// come from the SDP's `sprop-*` parameter sets and are `nil` when the SDP has
/// none (or they don't parse). The description doesn't change after
/// `start()`: parameter sets sent in band reach the consumer through
/// `PublicVideoFrame.sps`/`pps`/`vps`.
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
///
/// `sampleRate` is the stream's RTP clock rate from the SDP, except for
/// G.722: its RTP clock rate is 8000 (RFC 3551) but it samples at 16 kHz, and
/// `sampleRate` is 16000. For HE-AAC whose RTP clock runs at the core AAC
/// rate, the decoded output rate (from the AudioSpecificConfig in
/// `extraData`) is twice that.
public struct AudioStream: Sendable {
  public let codec: PublicAudioCodec
  public let sampleRate: UInt32
  public let channels: UInt16?
  /// Codec-specific extra data (the AudioSpecificConfig for AAC); nil for
  /// codecs without any.
  public let extraData: Data?
}

/// Parsed session description returned from `start()`.
///
/// At least one of `video`, `audio`, `metadataEncoding` or `backchannel` is
/// non-`nil`; a session with zero usable streams is rejected at `start()`. A
/// session whose only usable stream is the ONVIF backchannel has `video`,
/// `audio` and `metadataEncoding` all nil.
public struct SessionDescription: Sendable {
  public let video: VideoStream?
  public let audio: AudioStream?

  /// SDP encoding name of the analytics-metadata stream if one was set up
  /// (e.g. `vnd.onvif.metadata`), or `nil` if no metadata stream is active.
  public let metadataEncoding: String?

  /// The two-way audio stream, when `ONVIFFeatures.backchannel` was requested
  /// and the camera offered one the session could set up.
  public let backchannel: BackchannelStream?

  /// The presentation's time range from the SDP `a=range` attribute, e.g. the
  /// span of an ONVIF recording (`.clock`), when present in a supported format.
  public let range: PlaybackRange?
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
/// One `frames()` sequence may be iterated at a time. Once its consumer stops
/// (its task is cancelled, or it breaks out of the loop and the sequence is
/// released), a new `frames()` call picks up the stream from that point.
///
/// An `rtsps://` URL (default port 322) connects over TLS; `tls` selects how the
/// server's certificate is verified. `tunnel` carries the connection over HTTP
/// or WebSocket, and `onvif` asks for ONVIF replay and two-way audio.
public final class RTSPClientSession: Sendable {
  private let url: String
  private let credentials: Credentials?
  private let transport: Transport
  private let tls: TLSOptions
  private let tunnel: RTSPTunnel?
  private let onvif: ONVIFFeatures
  private let userAgent: String
  private let onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)?
  private let state: SessionState
  /// Test-only override of the keepalive interval. When nil (production), the
  /// interval is derived from the server's advertised session timeout.
  private let keepaliveInterval: Duration?
  /// Test-only override of the RTCP receiver-report interval (default ~5 s).
  private let receiverReportInterval: Duration?
  /// How long each request during `start()` waits for its response.
  private let setupResponseTimeout: Duration

  /// - Parameters:
  ///   - url: `rtsp://` or `rtsps://` (TLS) stream URL. With `tunnel`, this is
  ///     still the RTSP URL used inside the tunnel.
  ///   - tls: Server-certificate verification for `rtsps://` URLs and for
  ///     HTTPS/WSS tunnels; ignored otherwise. The default uses the system's
  ///     trust evaluation, which rejects self-signed certificates; see
  ///     `TLSOptions.ServerTrust`.
  ///   - tunnel: Carry RTSP over HTTP(S) or WebSocket instead of a direct TCP
  ///     connection. Requires `transport: .tcp`.
  ///   - onvif: ONVIF extensions to request (replay, two-way audio).
  public convenience init(
    url: String,
    credentials: Credentials? = nil,
    transport: Transport = .tcp,
    tls: TLSOptions = .default,
    tunnel: RTSPTunnel? = nil,
    onvif: ONVIFFeatures = [],
    userAgent: String = "IPCamKit",
    onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)? = nil
  ) {
    self.init(
      url: url, credentials: credentials, transport: transport, tls: tls, tunnel: tunnel,
      onvif: onvif, userAgent: userAgent, onDiagnostic: onDiagnostic, keepaliveInterval: nil)
  }

  /// Designated initializer. `keepaliveInterval`, `receiverReportInterval`
  /// and `setupResponseTimeout` are internal, for tests that need a short,
  /// deterministic cadence.
  init(
    url: String,
    credentials: Credentials?,
    transport: Transport,
    tls: TLSOptions = .default,
    tunnel: RTSPTunnel? = nil,
    onvif: ONVIFFeatures = [],
    userAgent: String,
    onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)?,
    keepaliveInterval: Duration?,
    receiverReportInterval: Duration? = nil,
    setupResponseTimeout: Duration = .seconds(15)
  ) {
    self.url = url
    self.credentials = credentials
    self.transport = transport
    self.tls = tls
    self.tunnel = tunnel
    self.onvif = onvif
    self.userAgent = userAgent
    self.onDiagnostic = onDiagnostic
    self.keepaliveInterval = keepaliveInterval
    self.receiverReportInterval = receiverReportInterval
    self.setupResponseTimeout = setupResponseTimeout
    self.state = SessionState()
  }

  /// Start the RTSP session (DESCRIBE -> SETUP -> PLAY).
  ///
  /// `play` sets the first PLAY's headers; the default plays from the start
  /// (`Range: npt=0.000-`). For ONVIF replay pass e.g.
  /// `PlayOptions(range: .clock(start: date))`. A `play.scale` out of range
  /// throws `RTSPError.invalidState` before connecting.
  ///
  /// Cancelling the task awaiting `start()` closes the connection at once,
  /// without TEARDOWN, as `stop()` during `start()` does, and `start()` throws
  /// `CancellationError`; in a task already cancelled it throws that without
  /// connecting. Either way the session is stopped. Cancelling the task after
  /// `start()` has returned doesn't affect the session.
  ///
  /// Returns session info including codec parameters for decoder setup.
  public func start(_ play: PlayOptions = PlayOptions()) async throws -> SessionDescription {
    try play.validate()
    let state = self.state
    return try await withTaskCancellationHandler {
      try await state.start(
        url: url,
        credentials: credentials,
        transport: transport,
        tls: tls,
        tunnel: tunnel,
        onvif: onvif,
        userAgent: userAgent,
        onDiagnostic: onDiagnostic,
        keepaliveInterval: keepaliveInterval,
        receiverReportInterval: receiverReportInterval,
        setupResponseTimeout: setupResponseTimeout,
        play: play
      )
    } onCancel: {
      Task { await state.cancelStart() }
    }
  }

  /// Send another PLAY: seek (`range`, usually with `immediate: true`), change
  /// speed or direction (`scale`), or resume after `pause()` (no `range`).
  /// Frames keep arriving through the same `frames()` sequence; those already
  /// waiting in it when this is called are delivered first. After a seek,
  /// video, audio and metadata reassembly restarts at the new position, and
  /// packets still in flight from the previous playback are discarded when
  /// they carry the ONVIF replay header extension (which names the PLAY they
  /// belong to). Packets without it are held until the server answers; those
  /// before their stream's first new sequence number (the response's
  /// RTP-Info) are discarded then, and without RTP-Info they can't be told
  /// apart and are delivered. If the server rejects the seek, the held packets
  /// are delivered when this throws, and the previous playback continues (up
  /// to 4096 packets or 8 MiB; beyond that, packets with the replay extension
  /// count as `loss` and the others go to the new playback).
  ///
  /// Throws `RTSPError.invalidState` before `start()`, after `stop()`, or,
  /// without sending anything, for a `scale` out of range;
  /// `RTSPError.sessionSetupFailed` if the server rejects the request (any
  /// non-2xx status except 401); `RTSPError.authenticationFailed` for a 401
  /// that refuses the retries, or that isn't answered (no credentials, a
  /// retry that would repeat the credentials just refused, or a seek that a
  /// later seek replaced);
  /// `RTSPError.timeout` with no response within 10 seconds; and
  /// `RTSPError.unexpectedDisconnection` or `.connectionFailed` when the
  /// connection is gone.
  ///
  /// When the calling task is cancelled, this throws `CancellationError` at
  /// once. A PLAY not yet sent isn't sent. One already sent can't be taken
  /// back, so the session follows the server's answer as if the caller had
  /// waited (an accepted seek moves the playback, a rejected one is rolled
  /// back), except that a 401 to it isn't answered.
  public func play(_ options: PlayOptions) async throws {
    try options.validate()
    try await state.play(options)
  }

  /// Pause playback (RTSP PAUSE). Keepalives continue, so the session stays
  /// open; resume with `play(PlayOptions())`. While the PAUSE awaits its
  /// response, and from its success until a PLAY sent after it succeeds,
  /// RTCP receiver reports stop over TCP (some servers close a paused
  /// connection that carries interleaved data) and `sendBackchannelAudio`
  /// throws; a `pause()` that throws an `RTSPError` leaves the session as it
  /// was. Throws, and handles cancellation, as `play(_:)` does: a PAUSE sent
  /// before the caller was cancelled still pauses the session once the
  /// server accepts it.
  public func pause() async throws {
    try await state.pause()
  }

  /// Send encoded audio to the camera over the ONVIF backchannel set up by
  /// `ONVIFFeatures.backchannel` (see `SessionDescription.backchannel` for the
  /// codec). `payload` must already be in that codec: G.711 bytes (`G711`
  /// encodes them), 16-bit big-endian PCM for L16, packed G.726, G.722, or one
  /// raw AAC access unit (no ADTS header) for `mpeg4-generic`. The session
  /// packetizes it into RTP, advancing the RTP timestamp by `samples` (per
  /// channel, at the RTP clock rate) or by the duration implied by the codec.
  /// Send in real time, in order, from one task.
  ///
  /// Pass `startsTalkspurt: true` for the first chunk after a pause (e.g. when
  /// push-to-talk is pressed again): the RTP timestamp moves forward by the
  /// time that passed beyond the audio already sent, so the camera reproduces
  /// the pause instead of treating the new audio as late, and the chunk's
  /// first packet carries the RTP marker bit, as does the very first chunk's.
  /// For AAC the marker keeps its RFC 3640 meaning (the last packet of each
  /// access unit) and only the timestamp moves.
  ///
  /// Throws `RTSPError.invalidState` when no backchannel was set up, the
  /// session isn't playing (including while paused, and when it pauses or
  /// stops while the audio is being sent), or `payload` doesn't fit the codec
  /// (empty, not a whole number of samples, or an AAC access unit too large
  /// for the AU-size field). When sending fails it throws the `RTSPError`
  /// the connection failed with (`connectionFailed`, for example). When the
  /// calling task is cancelled it throws `CancellationError` and sends no
  /// more of `payload`; the RTP timestamp still moves past the whole chunk
  /// once any of it was sent.
  public func sendBackchannelAudio(
    _ payload: Data, samples: UInt32? = nil, startsTalkspurt: Bool = false
  ) async throws {
    try await state.sendBackchannelAudio(
      payload, samples: samples, startsTalkspurt: startsTalkspurt)
  }

  /// Stream of depacketized frames (video, audio, metadata, RTCP).
  ///
  /// Each video frame carries its NAL units as raw NAL bytes, one per element,
  /// with no length prefix (see `PublicVideoFrame.nalus`).
  /// SPS/PPS changes are signaled via `sps`/`pps` properties on the frame.
  ///
  /// Delivery is bounded: when 256 items or 32 MiB are waiting for the
  /// consumer, the session stops reading the TCP connection until the
  /// consumer catches up (with UDP or multicast, datagrams wait instead, at
  /// most 4096 of them and 8 MiB, past which the oldest are dropped),
  /// so a slow consumer, or a server sending faster than real time
  /// (`PlayOptions.rateControl = false`), can't exhaust memory. While a
  /// control request awaits its response the session keeps reading, and
  /// drops the oldest items beyond 4096 or 64 MiB. Before the first
  /// `frames()` call, the newest 256 items (up to 32 MiB) are kept for it.
  public func frames() -> AsyncThrowingStream<PublicCodecItem, Error> {
    let token = FrameConsumerToken(state: state, owner: self)
    return AsyncThrowingStream(unfolding: { try await token.state.nextFrame(consumer: token.id) })
  }

  /// Graceful disconnect (TEARDOWN). Called during `start()`, it closes the
  /// connection at once (without TEARDOWN) and `start()` throws
  /// `RTSPError.invalidState`. Cancelling the task awaiting `start()` does the
  /// same, except that `start()` throws `CancellationError`.
  public func stop() async {
    await state.stop()
  }

  /// A session released without `stop()` (and with no `frames()` sequence
  /// left) stops itself, so its connection, sockets and keepalives don't
  /// outlive it.
  deinit {
    let state = self.state
    Task { await state.stop() }
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

  /// Sample rate in Hz, as `AudioStream.sampleRate`: the RTP clock rate,
  /// except 16000 for G.722 (see `AudioStream`).
  public let sampleRate: UInt32

  /// Channel count, if known.
  public let channels: UInt16?

  /// RTP packets lost before this frame: the forward gap in the RTP sequence
  /// number, plus one for each packet or AAC access unit dropped since the
  /// previous frame because it could not be depacketized, plus one for each
  /// audio frame the session dropped before the consumer got it (queue
  /// limits, or no `frames()` consumer). May be large (or
  /// spurious) if a camera's packetizer emits a wildly forward-jumped sequence
  /// number, so treat it as a discontinuity indicator rather than an exact
  /// loss count.
  public let loss: UInt16

  /// Recording time and flags during ONVIF replay; nil when the server sent no
  /// replay header extension (live streams).
  public let replay: ReplayInfo?
}

/// A metadata frame from an RTSP `application` stream (typically ONVIF analytics).
public struct PublicMetadataFrame: Sendable {
  /// Raw payload bytes. For `vnd.onvif.metadata` this is a UTF-8 XML
  /// document with root `tt:MetadataStream`; for `vnd.onvif.metadata.gzip`
  /// it is that document gzip-compressed, and for the EXI encodings it is
  /// EXI (see `encodingName`).
  public let data: Data

  /// Presentation timestamp in seconds, derived from the RTP timestamp.
  public let timestamp: Double

  /// SDP encoding name (e.g. `vnd.onvif.metadata`).
  public let encodingName: String

  /// RTP packets lost before this frame: the forward gap in the RTP sequence
  /// number, plus one for each metadata frame the session dropped before the
  /// consumer got it (queue limits, or no `frames()` consumer). May be large
  /// (or spurious) if a camera's packetizer emits a wildly forward-jumped
  /// sequence number, so treat it as a discontinuity indicator rather than an
  /// exact loss count.
  public let loss: UInt16

  /// The XML document: `data` itself for `vnd.onvif.metadata`, decompressed
  /// `data` for `vnd.onvif.metadata.gzip`. nil for the EXI encodings
  /// (`vnd.onvif.metadata.exi.onvif` / `.exi.ext`), which IPCamKit passes
  /// through undecoded, and when gzip decompression fails (reported once via
  /// `onDiagnostic`).
  public let xml: Data?

  /// Recording time and flags during ONVIF replay; nil for live streams.
  public let replay: ReplayInfo?
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

  /// Whether decoding can start at this frame: an H.264 IDR picture, or an
  /// H.265 IRAP picture (IDR, CRA or BLA). After a CRA or BLA, leading
  /// pictures that reference earlier frames (RASL) may not decode when
  /// decoding starts there.
  public let isKeyframe: Bool

  /// RTP packets lost before this frame: the forward gap in the RTP sequence
  /// number, plus one for each access unit dropped since the previous frame
  /// because it could not be reassembled or because the session dropped the
  /// frame before the consumer got it (queue limits, or no `frames()`
  /// consumer). May be large (or spurious) if a
  /// camera's packetizer emits a wildly forward-jumped sequence number, so
  /// treat it as a discontinuity indicator rather than an exact loss count.
  public let loss: UInt16

  /// The SPS, when this frame's parameter sets differ from the last ones
  /// delivered (at first, `VideoStream.sps`/`pps`/`vps` from `start()`), so
  /// the decoder must be reconfigured; otherwise nil. Also set for the first
  /// frame after a seek or after dropped frames if the parameter sets
  /// changed meanwhile, and for the first video frame of every `frames()`
  /// sequence after the first. `sps`, `pps` and `vps` are set together.
  public let sps: Data?

  /// The PPS, when the parameter sets changed with this frame (see `sps`).
  public let pps: Data?

  /// The VPS, when the parameter sets changed with this frame (H.265 only;
  /// see `sps`).
  public let vps: Data?

  /// Recording time and flags during ONVIF replay; nil when the server sent no
  /// replay header extension (live streams).
  public let replay: ReplayInfo?
}

/// Dispatch enum for video depacketizers (H.264 or H.265).
enum VideoDepacketizer: Sendable {
  case h264(H264Depacketizer)
  case h265(H265Depacketizer)

  /// Write the depacketizer back even when `push` throws: a failing packet
  /// can first complete the previous frame (its new timestamp ends it), and
  /// the depacketizer's recovery state must persist too. `self` is consumed
  /// so the payload is the only reference to its buffers and is changed in
  /// place, not copied on every packet.
  mutating func push(_ pkt: ReceivedRTPPacket) throws {
    switch consume self {
    case .h264(var d):
      defer { self = .h264(d) }
      try d.push(pkt)
    case .h265(var d):
      defer { self = .h265(d) }
      try d.push(pkt)
    }
  }

  mutating func pull() -> Result<CodecItem, DepacketizeError>? {
    switch consume self {
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

  /// Take `other`'s stored parameter sets (same codec only), as a
  /// replacement depacketizer after a seek.
  mutating func adoptParameters(from other: VideoDepacketizer) {
    switch (self, other) {
    case (.h264(var d), .h264(let o)):
      d.adoptParameters(from: o)
      self = .h264(d)
    case (.h265(var d), .h265(let o)):
      d.adoptParameters(from: o)
      self = .h265(d)
    default:
      break
    }
  }

  /// The parameter-set NAL units currently in effect, nil before any.
  var parameterSets: VideoParameterSetNALs? {
    switch self {
    case .h264(let d):
      guard let p = d.parameters else { return nil }
      return VideoParameterSetNALs(sps: p.spsNAL, pps: p.ppsNAL)
    case .h265(let d):
      guard let p = d.parameters else { return nil }
      return VideoParameterSetNALs(sps: p.spsNAL, pps: p.ppsNAL, vps: p.vpsNAL)
    }
  }
}

// MARK: - Internal Session State

/// One demultiplexed data-plane datagram in a UDP session: an RTP or RTCP packet
/// tagged with its stream index and its place in the queue (`arrival`, from
/// 1). The per-socket readers fan these into a single ordered consumer on the
/// session actor. Control-plane traffic (keepalive / TEARDOWN responses,
/// connection close) is handled directly by the control reader, off this lossy
/// buffer, so it is never dropped under RTP backpressure.
enum UDPTransportEvent: Sendable {
  case rtp(streamIndex: Int, data: Data, arrival: UInt64)
  case rtcp(streamIndex: Int, data: Data, arrival: UInt64)

  var arrival: UInt64 {
    switch self {
    case .rtp(_, _, let arrival), .rtcp(_, _, let arrival): arrival
    }
  }

  var byteCount: Int {
    switch self {
    case .rtp(_, let data, _), .rtcp(_, let data, _): data.count
    }
  }
}

/// Holds a UDP session's datagrams between the socket readers and the
/// session's reader, numbered in the order they're queued so a response on
/// the control connection can be placed among them. At most `maxCount`
/// datagrams and `maxBytes` bytes wait: past either, the oldest are dropped
/// (surfacing as RTP loss), so a consumer that falls behind costs bounded
/// memory whatever the datagrams' size.
final class DatagramQueue: @unchecked Sendable {
  private let lock = NSLock()
  private let maxCount: Int
  private let maxBytes: Int
  private var count: UInt64 = 0
  /// Waiting datagrams from `head` on. A taken or dropped datagram's slot is
  /// set to nil at once, so its bytes are freed before the array is compacted.
  private var items: [UDPTransportEvent?] = []
  private var head = 0
  private var bytes = 0
  private var finished = false
  private var waiter: CheckedContinuation<UDPTransportEvent?, Never>?

  init(maxCount: Int, maxBytes: Int) {
    self.maxCount = maxCount
    self.maxBytes = maxBytes
  }

  /// Number and queue a datagram in one step, so numbers follow queue order.
  func enqueue(_ event: (UInt64) -> UDPTransportEvent) {
    lock.withLock {
      guard !finished else { return }
      count += 1
      let numbered = event(count)
      if let waiter {
        self.waiter = nil
        waiter.resume(returning: numbered)
        return
      }
      items.append(numbered)
      bytes += numbered.byteCount
      while items.count - head > maxCount || (bytes > maxBytes && items.count - head > 1) {
        bytes -= items[head]?.byteCount ?? 0
        items[head] = nil
        head += 1
      }
      if head >= 1024, head * 2 >= items.count {
        items.removeFirst(head)
        head = 0
      }
    }
  }

  /// The oldest waiting datagram; after `finish()`, nil once none is left.
  func next() async -> UDPTransportEvent? {
    await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<UDPTransportEvent?, Never>) in
        lock.withLock {
          if head < items.count, let event = items[head] {
            items[head] = nil
            bytes -= event.byteCount
            head += 1
            if head == items.count {
              items.removeAll(keepingCapacity: true)
              head = 0
            }
            continuation.resume(returning: event)
          } else if finished {
            continuation.resume(returning: nil)
          } else {
            waiter = continuation
          }
        }
      }
    } onCancel: {
      finish()
    }
  }

  /// No more datagrams are queued; the waiting ones are still taken.
  func finish() {
    lock.withLock {
      finished = true
      waiter?.resume(returning: nil)
      waiter = nil
    }
  }

  /// How many datagrams have been queued so far.
  var queued: UInt64 { lock.withLock { count } }
}

/// A per-stream source of RTP/RTCP datagrams: a unicast `UDPPair` or a joined
/// `MulticastPair`.
protocol RTPDatagramSource: AnyObject, Sendable {
  func startReceiving(
    onRTP: @escaping @Sendable (Data) -> Void,
    onRTCP: @escaping @Sendable (Data) -> Void,
    onError: (@Sendable (Error) -> Void)?)
  func close()
}

extension UDPPair: RTPDatagramSource {}
extension MulticastPair: RTPDatagramSource {}

/// Identifies one `frames()` sequence. The stream's unfolding closure holds the
/// token, so when the sequence and its iterator are released (the consumer
/// broke out of its loop, or was cancelled) the session learns the consumer is
/// gone and stops buffering for it.
///
/// The token also keeps the session object alive while the sequence exists, so
/// the session's own `deinit` (which stops it) can't run under a consumer.
final class FrameConsumerToken: Sendable {
  let id = UUID()
  let state: SessionState
  private let owner: RTSPClientSession?

  init(state: SessionState, owner: RTSPClientSession? = nil) {
    self.state = state
    self.owner = owner
  }

  deinit {
    // Free the consumer slot now, so a `frames()` call right after `break`
    // succeeds; the actor-side cleanup follows.
    state.consumerSlot.release(id)
    let state = self.state
    let id = self.id
    Task { await state.releaseConsumer(id) }
  }
}

/// Which `frames()` sequence currently consumes the session. Kept outside the
/// actor so a released sequence frees it synchronously.
final class FrameConsumerSlot: @unchecked Sendable {
  private let lock = NSLock()
  private var owner: UUID?

  /// Take the slot for `id`; false while another consumer holds it.
  func claim(_ id: UUID) -> Bool {
    lock.withLock {
      guard owner == nil || owner == id else { return false }
      owner = id
      return true
    }
  }

  func release(_ id: UUID) {
    lock.withLock {
      if owner == id { owner = nil }
    }
  }
}

/// FIFO of frames waiting for the `frames()` consumer.
struct FrameQueue {
  /// Queued items from `head` on. A taken or dropped item's slot is set to
  /// nil at once, so its payload is freed before the array is compacted.
  private var items: [PublicCodecItem?] = []
  private var head = 0
  /// Payload bytes of the queued items.
  private(set) var bytes = 0

  var count: Int { items.count - head }
  var isEmpty: Bool { count == 0 }

  mutating func append(_ item: PublicCodecItem) {
    items.append(item)
    bytes += Self.size(of: item)
  }

  mutating func popFirst() -> PublicCodecItem? {
    guard head < items.count, let item = items[head] else { return nil }
    items[head] = nil
    head += 1
    bytes -= Self.size(of: item)
    if head == items.count {
      items.removeAll(keepingCapacity: true)
      head = 0
    } else if head >= 64 && head * 2 >= items.count {
      items.removeFirst(head)
      head = 0
    }
    return item
  }

  /// Empty the queue, returning what it held.
  @discardableResult
  mutating func removeAll() -> [PublicCodecItem] {
    let removed = items[head...].compactMap { $0 }
    items.removeAll()
    head = 0
    bytes = 0
    return removed
  }

  private static func sameBytes(_ a: Data, _ b: Data) -> Bool {
    a.count == b.count
      && a.withUnsafeBytes { x in b.withUnsafeBytes { y in x.baseAddress == y.baseAddress } }
  }

  private static func size(of item: PublicCodecItem) -> Int {
    switch item {
    case .video(let frame): return frame.nalus.reduce(0) { $0 + $1.count }
    case .audio(let frame): return frame.data.count
    case .metadata(let frame):
      // Plain XML metadata's `xml` is `data` itself.
      guard let xml = frame.xml, !Self.sameBytes(xml, frame.data) else { return frame.data.count }
      return frame.data.count + xml.count
    case .rtcp(let packet): return packet.data.count
    }
  }
}

/// Actor-based internal state for thread-safe session management.
actor SessionState {
  /// Lifecycle: `start()` runs once, from `.idle`.
  private enum Phase {
    case idle, starting, running, stopped
  }
  private var phase = Phase.idle
  /// Set by a `stop()` that arrives while `start()` runs; `start()` checks it
  /// after every suspension and abandons the setup.
  private var stopRequested = false
  /// True while a `stop()` tears the session down; later calls wait for it.
  private var stopInProgress = false
  private var stopWaiters: [CheckedContinuation<Void, Never>] = []
  private var connection: RTSPTransportConnection?
  private var presentation: Presentation?
  /// Aggregate control URL for PLAY, PAUSE, TEARDOWN and keepalives: the SDP's
  /// session-level `a=control` resolved against the base URL (RFC 2326 C.1.1).
  private var aggregateURL: String?
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
  /// Interleaved RTP channel of each stream (TCP transport only).
  private var interleavedChannels: [Int: UInt8] = [:]
  /// UDP socket pairs keyed by stream index (UDP transport only); empty for TCP.
  private var udpPairs: [Int: UDPPair] = [:]
  /// Joined multicast groups keyed by stream index (multicast transport only).
  private var multicastPairs: [Int: MulticastPair] = [:]
  private var inorderParsers: [Int: InorderParser] = [:]
  private var userAgent: String?
  /// Selected RTP transport; drives SETUP, the receive loop, and parser config.
  private var transport: Transport = .tcp
  /// ONVIF features requested in `Require`; `.backchannel` is dropped if the
  /// server rejects it at DESCRIBE.
  private var onvif: ONVIFFeatures = []
  /// True for an `rtsps://` session over UDP or multicast: media is SRTP keyed
  /// with MIKEY in the SETUP exchange.
  private var usesSRTP = false
  /// SRTP contexts for the server's packets (keys from its MIKEY message).
  private var srtpInbound: [Int: SRTPContext] = [:]
  /// SRTP contexts for packets the client sends (keys from the client's MIKEY
  /// offer); used by the backchannel.
  private var srtpOutbound: [Int: SRTPContext] = [:]
  /// RTSP server host from the URL; the UDP RTP/RTCP peer fallback when SETUP
  /// omits an explicit `source`.
  private var host: String?
  /// True from a successful PLAY until `stop()`, including while paused.
  private var isPlaying = false
  /// PAUSE requests sent and not answered yet.
  private var pendingPauseCSeqs: Set<UInt32> = []
  /// The playback state after the successful PLAY or PAUSE with the highest
  /// CSeq: the server handles requests in CSeq order, so a PLAY answered
  /// after a later PAUSE was sent doesn't resume the session.
  private var confirmedPause: (cseq: UInt32, paused: Bool) = (0, false)
  /// True while a PAUSE is outstanding, and from a successful PAUSE until a
  /// PLAY sent after it succeeds. Nothing is sent on the RTP channels
  /// meanwhile: servers may close a connection that carries interleaved data
  /// while the session isn't playing.
  private var isPaused: Bool { !pendingPauseCSeqs.isEmpty || confirmedPause.paused }
  private var onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)?
  /// Session timeout advertised by the server in the SETUP `Session` header,
  /// in seconds. Drives the keepalive interval while streaming.
  private var sessionTimeoutSec: UInt32 = 60
  /// Whether the server advertised `GET_PARAMETER` in its OPTIONS `Public`
  /// header. When true it is preferred over `OPTIONS` as the keepalive method.
  private var getParameterSupported = false
  /// Control responses awaited by `sendControlRequest`, keyed by CSeq. The
  /// reader loop resumes them as matching responses arrive.
  private var pendingResponses: [UInt32: CheckedContinuation<RTSPResponse, Error>] = [:]
  /// Per-CSeq timeout tasks, cancelled as soon as the waiter resolves so a fast
  /// response doesn't leave a sleeping task lingering for the full timeout.
  private var pendingTimeouts: [UInt32: Task<Void, Never>] = [:]
  /// The send of the latest request or interleaved frame through the reader.
  /// Each send waits for the one before it, so requests reach the server in
  /// CSeq order (which `confirmedPause` relies on), and no receiver report or
  /// backchannel packet checked before a PAUSE or TEARDOWN follows it,
  /// whatever the priorities of their callers.
  private var lastControlSend: Task<Void, Never>?
  /// Low bytes of the CSeqs of the latest PLAY requests (see `nextCSeq(for:)`).
  private var recentPlayCSeqLowBytes: [UInt8] = []
  /// CSeqs of in-flight seek PLAY requests sent through the reader. Their
  /// response is applied (`applySeekResponse`) by the reader at the point it
  /// arrives, before any packet that follows it.
  private var seekPlayCSeqs: Set<UInt32> = []
  /// The periodic keepalive task, active only while the reader runs.
  private var keepaliveTask: Task<Void, Never>?
  /// Why the UDP control connection closed, recorded by the control reader so
  /// the consumer loop can distinguish a clean stop() from a peer drop after the
  /// event stream finishes. nil while the connection is healthy.
  private var udpControlError: RTSPError?
  /// Test-only override of the keepalive interval; nil derives it from the
  /// server's advertised session timeout.
  private var keepaliveIntervalOverride: Duration?

  // MARK: RTCP receiver reports

  /// Origin for arrival times in the jitter estimate.
  private let clockOrigin = ContinuousClock.now
  /// SSRC the client reports (and keys SRTCP) with.
  private let reporterSSRC = UInt32.random(in: .min ... .max)
  /// SDES CNAME of the reports: random, so it identifies nothing about the host.
  private let rtcpCNAME = UUID().uuidString
  /// Reception statistics per receive stream.
  private var receptionStats: [Int: ReceptionStats] = [:]
  /// Sends receiver reports while the reader runs.
  private var receiverReportTask: Task<Void, Never>?
  /// Test-only override of the receiver-report interval; nil means about 5 s
  /// (RFC 3550's minimum), randomized by ±50% as section 6.2 asks.
  private var receiverReportIntervalOverride: Duration?
  /// Bounds on the UDP multiplexing buffer (`DatagramQueue`). RTP and RTCP
  /// datagrams queue here between the socket readers and the actor-isolated
  /// consumer. When the `frames()` consumer falls behind, the reader stops
  /// draining it and the oldest datagrams are dropped (surfacing as RTP loss)
  /// past either bound: a multicast datagram can be 64 KiB.
  private static let udpEventBufferCount = 4096
  private static let udpEventBufferBytes = 8 << 20

  // MARK: Frame delivery

  /// Frames produced by the reader that the consumer hasn't taken yet.
  private var frameQueue = FrameQueue()
  /// The consumer suspended in `nextFrame`, if any (only while the queue is empty).
  private var frameWaiter: CheckedContinuation<PublicCodecItem?, Error>?
  /// The consumer `frameWaiter` belongs to.
  private var frameWaiterOwner: UUID?
  /// The current `frames()` consumer; nil before the first and after it's released.
  private var frameConsumer: UUID?
  /// Mirror of `frameConsumer` that `FrameConsumerToken` can clear without
  /// the actor.
  nonisolated let consumerSlot = FrameConsumerSlot()
  /// True until the first consumer goes away: frames that arrive between
  /// `start()` and the first `frames()` call are queued for it (the newest
  /// `frameQueueLimit` items, up to `frameQueueByteLimit` bytes) so its first
  /// keyframe isn't lost. The reader doesn't wait for this queue: a session
  /// whose `frames()` is never iterated keeps reading its connection.
  private var queueForFirstConsumer = true
  /// The reader loop (receive, demultiplex, depacketize), started when
  /// `start()` succeeds and running until the connection closes. It owns the
  /// connection from then on: every later request goes through it.
  private var readerTask: Task<Void, Never>?
  private var readerFinished = false
  /// The error that ended the reader, delivered to the consumer after the
  /// frames queued before it.
  private var readerError: Error?
  /// The reader suspended because the queue is full.
  private var readerSpaceWaiter: CheckedContinuation<Void, Never>?
  /// Frames dropped before reaching the consumer (queue limits, no consumer)
  /// since the last one of their kind it was given; added to the next one's
  /// `loss` so the gap shows.
  private var droppedVideoFrames = 0
  /// Whether a `frames()` consumer has claimed the slot before.
  private var hadFrameConsumer = false
  private var droppedAudioFrames = 0
  private var droppedMetadataFrames = 0
  /// The parameter sets the consumer was last given: the description's, then
  /// each video frame's `sps`/`pps`/`vps` (see `handOff`).
  private var reportedVideoParameters: VideoParameterSetNALs?
  /// Queue length, and payload bytes, at which the reader stops reading until
  /// the consumer catches up.
  private static let frameQueueLimit = 256
  private static let frameQueueByteLimit = 32 << 20
  /// Hard bounds while the reader must keep reading past the limits above (to
  /// receive a control response); beyond them the oldest frames are dropped.
  private static let frameQueueHardLimit = 4096
  private static let frameQueueHardByteLimit = 64 << 20

  // MARK: Backchannel

  private var backchannelStreamIndex: Int?
  private var backchannelPacketizer: RTPAudioPacketizer?
  private var backchannel: BackchannelStream?
  /// When the backchannel's first send or latest talkspurt began, and the
  /// RTP clock ticks of audio sent since; measures the silence before the
  /// next talkspurt.
  private var backchannelClockAnchor: (instant: ContinuousClock.Instant, sentTicks: UInt64)?

  // MARK: Replay

  /// Replay header extensions of recent packets, per stream.
  private var replayTrackers: [Int: ReplayTracker] = [:]
  /// Low bytes of the CSeqs of the latest seek PLAY and of every PLAY sent
  /// after it (a resume, a speed change, an authentication retry), or nil when
  /// not filtering. Replay packets tagged with another CSeq belong to a
  /// playback the seek replaced and are dropped, per stream, until that
  /// stream's first packet with an accepted CSeq arrives.
  private var acceptedReplayCSeqs: Set<UInt8>?
  /// Streams still waiting for their first packet of the current playback.
  private var replayFilteredStreams: Set<Int> = []
  /// Streams whose packets have carried the replay header extension. Servers
  /// may tag only the first packet of each access unit; while such a stream
  /// is filtered, its untagged packets are dropped with the tagged ones.
  private var replayTaggedStreams: Set<Int> = []
  /// CSeq of the latest seek PLAY, so a failed older seek doesn't end the
  /// filtering a newer one started.
  private var latestSeekCSeq: UInt32?
  /// Whether the latest seek PLAY's response has arrived.
  private var seekResponseReceived = false
  /// Seconds into the streams where the latest seek's new playback starts
  /// (see `resetReceivePipelines`); nil before any stream had a timestamp.
  private var seekStartTarget: Double?
  /// CSeqs of seek PLAYs a later seek replaced while they awaited their
  /// response.
  private var supersededSeekCSeqs: Set<UInt32> = []
  /// The latest of those the server accepted. If the seek that replaced it
  /// fails, the server plays from its position (see `adoptSupersededSeek`).
  private var acceptedSupersededSeek: (cseq: UInt32, response: RTSPResponse)?
  /// The latest PLAY requests sent (CSeq, and whether a seek), oldest first.
  private var sentPlays: [(cseq: UInt32, isSeek: Bool)] = []
  /// What a rejected seek restores (see `SeekRollback`); nil when no seek is
  /// awaiting its response.
  private var seekRollback: SeekRollback?
  private static let seekRollbackPacketLimit = 4096
  private static let seekRollbackByteLimit = 8 << 20
  /// Packets dropped since the seek response arrived that carry an older CSeq
  /// or start an access unit without a tag (not those continuing a stale
  /// tagged one). A server that never tags packets with the new CSeq would
  /// otherwise lose everything, so filtering stops after
  /// `staleReplayDropLimit`.
  private var staleReplayDrops = 0
  private static let staleReplayDropLimit = 1000
  /// The RTP timestamp of each stream's last packet carrying an older CSeq:
  /// untagged packets with it continue that stale access unit.
  private var staleReplayTimestamps: [Int: UInt32] = [:]
  /// The RTP timestamp of each stream's last packet with the replay
  /// extension, filtered or not: a seek starts `staleReplayTimestamps` from
  /// it, as the frame in flight then is stale too.
  private var lastTaggedTimestamps: [Int: UInt32] = [:]

  func start(
    url: String,
    credentials: Credentials?,
    transport: Transport,
    tls: TLSOptions = .default,
    tunnel: RTSPTunnel? = nil,
    onvif: ONVIFFeatures = [],
    userAgent: String,
    onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)?,
    keepaliveInterval: Duration? = nil,
    receiverReportInterval: Duration? = nil,
    setupResponseTimeout: Duration = .seconds(15),
    play: PlayOptions = PlayOptions()
  ) async throws -> SessionDescription {
    guard phase == .idle else {
      throw RTSPError.invalidState(
        "start() runs once per session; create a new RTSPClientSession to reconnect")
    }
    // A task already cancelled doesn't connect; the session ends as after any
    // failed start().
    guard !Task.isCancelled else {
      phase = .stopped
      throw CancellationError()
    }
    phase = .starting
    self.setupResponseTimeout = setupResponseTimeout
    do {
      let description = try await establish(
        url: url, credentials: credentials, transport: transport, tls: tls, tunnel: tunnel,
        onvif: onvif, userAgent: userAgent, onDiagnostic: onDiagnostic,
        keepaliveInterval: keepaliveInterval, receiverReportInterval: receiverReportInterval,
        play: play)
      try checkNotStopped()
      // From here the reader owns the connection: it receives media (queued
      // for the first `frames()` consumer), routes control responses, and
      // runs the keepalives and receiver reports, whether or not `frames()`
      // is iterated.
      phase = .running
      readerTask = Task { await self.runReader() }
      return description
    } catch {
      await abandonStart()
      if Task.isCancelled { throw CancellationError() }
      if stopRequested {
        throw RTSPError.invalidState("stop() was called while start() was running")
      }
      throw error
    }
  }

  /// The task awaiting `start()` was cancelled: while `start()` runs, end it
  /// as `stop()` would (close the connection at once; `start()` then sees the
  /// cancellation and throws `CancellationError`). A session already running
  /// or stopped is left alone.
  func cancelStart() async {
    guard phase == .starting else { return }
    await stop()
  }

  /// Throw if `stop()` arrived, or the task awaiting `start()` was cancelled,
  /// while `start()` was suspended. Used only on the `start()` path.
  private func checkNotStopped() throws {
    if Task.isCancelled { throw CancellationError() }
    if stopRequested {
      throw RTSPError.invalidState("stop() was called while start() was running")
    }
  }

  /// Release everything a failed or stopped `start()` opened. After a genuine
  /// failure (not `stop()` or cancellation), a session the server already
  /// created gets a best-effort TEARDOWN, bounded to 2 seconds; cancelling
  /// the task during that TEARDOWN closes the connection at once.
  private func abandonStart() async {
    phase = .stopped
    isPlaying = false
    let conn = connection
    if !stopRequested, !Task.isCancelled, let conn, sessionId != nil,
      let url = aggregateURL ?? self.url
    {
      let deadline = Task {
        try? await Task.sleep(for: .seconds(2))
        await conn.close()
      }
      _ = await withTaskCancellationHandler {
        try? await sendRequest(method: .teardown, url: url)
      } onCancel: {
        Task { await conn.close() }
      }
      deadline.cancel()
    }
    await conn?.close()
    connection = nil
    failAllPending(.unexpectedDisconnection)
    for pair in udpPairs.values { pair.close() }
    udpPairs.removeAll()
    for pair in multicastPairs.values { pair.close() }
    multicastPairs.removeAll()
    backchannelPacketizer = nil
  }

  private func establish(
    url requestedURL: String,
    credentials explicitCredentials: Credentials?,
    transport: Transport,
    tls: TLSOptions,
    tunnel: RTSPTunnel?,
    onvif: ONVIFFeatures,
    userAgent: String,
    onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)?,
    keepaliveInterval: Duration?,
    receiverReportInterval: Duration?,
    play: PlayOptions
  ) async throws -> SessionDescription {
    self.onDiagnostic = onDiagnostic
    self.keepaliveIntervalOverride = keepaliveInterval
    self.receiverReportIntervalOverride = receiverReportInterval
    self.transport = transport
    self.onvif = onvif

    // `user:password@` in the URL is used for authentication (unless
    // credentials were passed) and never sent: the request line and the
    // Digest `uri` carry the URL without it.
    // Checked before the userinfo is split off, which would percent-encode a
    // space instead of rejecting it.
    try checkURLCharacters(requestedURL)
    try checkAmbiguousUserInfo(requestedURL)
    // The URL's user name and password are decoded only when no credentials
    // were passed; otherwise they are only removed.
    let credentials = try explicitCredentials ?? credentialsInUserInfo(requestedURL)
    // The request line must be ASCII: a Unicode host name goes as `xn--…`.
    let url = withoutFragment(asciiURL(removingUserInfo(requestedURL)))
    let endpoint = try rtspEndpoint(for: url, shownAs: requestedURL)
    if tunnel != nil && transport != .tcp {
      throw RTSPError.invalidState(
        "RTSP over an HTTP or WebSocket tunnel carries media on the tunnel; use Transport.tcp")
    }
    // Through a tunnel, the tunnel URL alone decides whether the connection
    // is encrypted. An rtsps:// URL asks for TLS, so the tunnel must provide it.
    if endpoint.usesTLS, let tunnel, !tunnel.usesTLS {
      throw RTSPError.invalidState(
        "An rtsps:// URL through a tunnel needs an https:// or wss:// tunnel URL; "
          + "http:// and ws:// would send it unencrypted")
    }
    // RTSPS over UDP or multicast sends media as SRTP (RTP/SAVP), keyed with
    // MIKEY in the TLS-protected SETUP exchange; plain RTP/AVP would carry the
    // media unencrypted.
    usesSRTP = tunnel == nil && endpoint.usesTLS && transport != .tcp

    self.host = endpoint.host
    // A CR or LF here would end the header early and let the rest of the
    // value be read as more headers.
    self.userAgent = String(
      String.UnicodeScalarView(
        userAgent.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))

    // Set up authenticator
    if let creds = credentials {
      authenticator = RTSPAuthenticator(credentials: creds)
    }

    // Connect: directly (over TLS for rtsps://) or through a tunnel. The
    // connection is recorded first so a concurrent stop() can close it, which
    // cancels the connect in progress.
    let conn = RTSPTransportConnection()
    connection = conn
    switch tunnel {
    case .http(let tunnelURL)?:
      try await conn.connectHTTPTunnel(
        url: tunnelURL, tls: tls, credentials: credentials, userAgent: userAgent)
    case .webSocket(let tunnelURL)?:
      try await conn.connectWebSocket(
        url: tunnelURL, tls: tls, credentials: credentials, userAgent: userAgent)
    case nil:
      try await conn.connect(
        host: endpoint.host, port: endpoint.port, tls: endpoint.usesTLS ? tls : nil)
    }
    try checkNotStopped()

    // OPTIONS (best-effort): discover whether the server supports
    // GET_PARAMETER, which is the preferred keepalive method. A server that
    // rejects or omits OPTIONS just leaves us defaulting to OPTIONS keepalive.
    // A server that doesn't answer at all fails start() here, and so does one
    // that refused the credentials sent (there was a usable challenge):
    // DESCRIBE would only send them again.
    do {
      let optionsResp = try await sendRequest(method: .options, url: url)
      getParameterSupported = parseOptions(response: optionsResp).getParameterSupported
    } catch RTSPError.timeout {
      throw RTSPError.timeout
    } catch RTSPError.authenticationFailed where authenticator?.hasChallenge == true {
      throw RTSPError.authenticationFailed
    } catch {}
    try checkNotStopped()

    // DESCRIBE. A camera without two-way audio may reject the backchannel
    // feature tag (551 Option not supported); carry on without it.
    let describeResp: RTSPResponse
    do {
      describeResp = try await sendRequest(
        method: .describe, url: url, extraHeaders: [("Accept", "application/sdp")])
    } catch RTSPError.sessionSetupFailed(let status, _)
      where status == 551 && self.onvif.contains(.backchannel)
    {
      // With `onvif-replay` also required, the 551 may be about that tag: only
      // a retry that succeeds without the backchannel shows it was this one.
      self.onvif.remove(.backchannel)
      describeResp = try await sendRequest(
        method: .describe, url: url, extraHeaders: [("Accept", "application/sdp")])
      onDiagnostic?(
        RTSPDiagnostic(
          severity: .warning,
          message: "Server rejected Require: www.onvif.org/ver20/backchannel (551); "
            + "continuing without two-way audio."))
    }
    try checkNotStopped()
    var presMut = try parseDescribe(
      requestURL: url, response: describeResp, onDiagnostic: onDiagnostic)
    presentation = presMut

    self.url = url
    aggregateURL = presMut.control

    // ONVIF backchannel streams are audio marked `a=sendonly` (from the
    // client's point of view) next to `a=recvonly` receive streams. A camera
    // that ignores the backchannel tag may mark every stream sendonly in the
    // RFC 3264 sense; none of those is a backchannel.
    let backchannelCandidates: [Int]
    if self.onvif.contains(.backchannel),
      !presMut.streams.allSatisfy({ $0.direction == .sendOnly })
    {
      backchannelCandidates = presMut.streams.indices.filter {
        presMut.streams[$0].media == "audio" && presMut.streams[$0].direction == .sendOnly
      }
    } else {
      backchannelCandidates = []
    }
    let backchannelSet = Set(backchannelCandidates)
    let receivable = presMut.streams.indices.filter { !backchannelSet.contains($0) }

    // Find first H.264 or H.265 video stream — optional. Cameras can be
    // configured to expose audio-only or metadata-only RTSP sessions
    // (e.g. Axis with `video=0`), in which case we proceed without video
    // and require at least one of audio/metadata to be set up.
    let videoIdx = receivable.first(where: {
      presMut.streams[$0].media == "video"
        && isVideoEncodingSupported(presMut.streams[$0].encodingName)
    })
    var videoSetupSSRC: UInt32?

    if let videoIdx = videoIdx {
      let stream = presMut.streams[videoIdx]
      let setup = try await setupStream(
        controlURL: stream.control ?? url, streamIndex: videoIdx)
      try checkNotStopped()
      videoSetupSSRC = setup.ssrc
      presMut.streams[videoIdx].state = .setup(
        StreamStateInit(ssrc: setup.ssrc, initialSeq: nil, initialRtptime: nil, ctx: .dummy))
      self.videoStreamIndex = videoIdx
    }

    // Find and SETUP audio stream (optional, best-effort). Without
    // `.backchannel` an ONVIF camera may still list its backchannel (audio
    // `a=sendonly` next to `a=recvonly` streams); another audio stream is
    // preferred to it.
    let isSupportedAudio = { (index: Int) in
      presMut.streams[index].media == "audio"
        && isAudioEncodingSupported(presMut.streams[index].encodingName)
    }
    let mixedDirections = !presMut.streams.allSatisfy { $0.direction == .sendOnly }
    var audioIdx =
      receivable.first {
        isSupportedAudio($0) && !(mixedDirections && presMut.streams[$0].direction == .sendOnly)
      } ?? receivable.first(where: isSupportedAudio)
    var audioSetupSSRC: UInt32?

    if let idx = audioIdx {
      let audioStream = presMut.streams[idx]
      do {
        let audioSetup = try await setupStream(
          controlURL: audioStream.control ?? url, streamIndex: idx)
        audioSetupSSRC = audioSetup.ssrc
        presMut.streams[idx].state = .setup(
          StreamStateInit(
            ssrc: audioSetup.ssrc, initialSeq: nil, initialRtptime: nil, ctx: .dummy))

        audioStreamIndex = idx
        audioEncodingName = audioStream.encodingName
        audioClockRate = audioStream.clockRateHz
        audioChannels = audioStream.channels
      } catch {
        try checkNotStopped()
        // The SETUP got no answer and its deadline closed the connection:
        // nothing more can be set up.
        if setupResponseTimedOut { throw RTSPError.timeout }
        // Like metadata, audio is optional: carry on with the other streams.
        onDiagnostic?(
          RTSPDiagnostic(
            severity: .warning,
            message: "Audio SETUP failed: \(error); audio will not be delivered."))
        audioIdx = nil
      }
      try checkNotStopped()
    }

    // Find and SETUP application (metadata) stream — optional, best-effort.
    // If SETUP fails (camera advertises the stream but rejects it, or any
    // transport error), disable metadata locally rather than aborting the
    // session. The channel slot stays assigned (no other streams follow).
    var applicationIdx = receivable.first(where: {
      presMut.streams[$0].media == "application"
        && isApplicationEncodingSupported(presMut.streams[$0].encodingName)
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
        try checkNotStopped()
        // The SETUP got no answer and its deadline closed the connection:
        // nothing more can be set up.
        if setupResponseTimedOut { throw RTSPError.timeout }
        onDiagnostic?(
          RTSPDiagnostic(
            severity: .warning,
            message:
              "Application SETUP failed: \(error); "
              + "metadata will not be delivered."))
        applicationIdx = nil
      }
      try checkNotStopped()
    }

    // Two-way audio (best-effort): SETUP the first backchannel stream in a
    // codec the packetizer supports.
    if self.onvif.contains(.backchannel) {
      try await setupBackchannel(candidates: backchannelCandidates, presentation: presMut)
      try checkNotStopped()
    }

    // Require at least one usable stream — a session with no video, audio,
    // metadata, or backchannel is degenerate (DESCRIBE succeeded but nothing
    // is carrying payload), and sending PLAY would just open the door to
    // packets we can't route.
    if videoStreamIndex == nil && audioStreamIndex == nil && applicationStreamIndex == nil
      && backchannelStreamIndex == nil
    {
      let offered = listForMessage(
        presMut.streams.map { "\(cutForMessage($0.media))/\(cutForMessage($0.encodingName))" })
      throw RTSPError.sessionSetupFailed(
        statusCode: 0,
        reason:
          "No supported video, audio, or metadata stream was set up "
          + "(offered: \(offered.isEmpty ? "<none>" : offered)).")
    }

    // PLAY, on the aggregate control URL.
    let playResp = try await sendRequest(
      method: .play, url: presMut.control, extraHeaders: play.headers(isInitial: true))
    try checkNotStopped()

    try parsePlay(response: playResp, presentation: &presMut)
    presentation = presMut

    // UDP NAT/firewall hole-punch: now that the server is sending (post-PLAY),
    // poke each local RTP/RTCP port toward its peer so inbound datagrams can
    // traverse a NAT. Best-effort and a no-op on loopback/LAN.
    // The RTCP port sends an RTCP receiver report without report blocks (as
    // SRTCP for RTSPS), a valid packet where an empty one would be a decode
    // error for the server. No suspension point separates this from the
    // stop() check after PLAY, so nothing is sent once stop() was called.
    if transport == .udp {
      for (index, pair) in udpPairs {
        var punch = RTCPReport.receiverReport(
          reporterSSRC: reporterSSRC, blocks: [], cname: rtcpCNAME)
        if var context = srtpOutbound[index] {
          // An SRTP session never sends plaintext RTCP: without SRTCP, the
          // stream gets no hole punch.
          do {
            punch = try context.protectRTCP(punch)
            srtpOutbound[index] = context
          } catch {
            warnStreamOnce(
              "rtcp.punch.\(index)", .warning,
              "The UDP hole punch on stream \(index) was not sent: protecting its RTCP "
                + "receiver report failed: \(error)")
            continue
          }
        }
        pair.holePunch(rtcpPacket: punch)
      }
    }

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

    // Initialize video depacketizer + timeline + inorder parser. Conditional
    // on a successful video SETUP — when no video stream was set up,
    // `videoStreamIndex` is nil and we skip the entire video pipeline.
    var videoClockRate: UInt32?
    if let videoIdx = videoStreamIndex {
      let stream = presMut.streams[videoIdx]
      depacketizer = try makeVideoDepacketizer(for: stream)
      // The consumer starts with the description's (SDP) parameter sets.
      reportedVideoParameters = depacketizer?.parameterSets
      // If the SDP advertised parameter sets (sprop-*) but the depacketizer
      // couldn't parse them, it silently falls back to in-band parameters;
      // surface that, since the first decodable frame may be delayed.
      if let fmtp = stream.formatSpecificParams,
        Self.advertisesParameterSets(fmtp),
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
        // Adopt the RTP-Info initial sequence so loss before the first received
        // packet is detected, and its rtptime as the timeline start. The
        // `seq=0;rtptime=0` placeholder some cameras send instead of a real
        // seed is ignored entirely, as after a seek (finding #50).
        if !Self.isPlaceholderRTPInfo(init_) {
          videoStart = init_.initialRtptime
          videoSeq = init_.initialSeq
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
          // See the video seed above (finding #50).
          if !Self.isPlaceholderRTPInfo(init_) {
            audioStart = init_.initialRtptime
            audioSeq = init_.initialSeq
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
          resolvedAudioRate = Self.audioSampleRate(
            encoding: audioStream.encodingName, clockRate: audioStream.clockRateHz)
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
              + "\(cutForMessage(audioStream.encodingName)); audio will not be delivered."))
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
        // See the video seed above (finding #50).
        if !Self.isPlaceholderRTPInfo(init_) {
          applicationStart = init_.initialRtptime
          applicationSeq = init_.initialSeq
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
        applicationDepacketizer = ApplicationDepacketizer(
          encodingName: applicationEncodingName, onDiagnostic: onDiagnostic)
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
    // return site too. PLAY has already been sent; `abandonStart()` sends
    // TEARDOWN and closes the connection when this throws.
    if videoStreamIndex == nil && audioStreamIndex == nil && applicationStreamIndex == nil
      && backchannelStreamIndex == nil
    {
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
        extraData: audioDepacketizer?.audioParameters.flatMap {
          $0.extraData.isEmpty ? nil : $0.extraData
        }
      )
    } else {
      audio = nil
    }

    return SessionDescription(
      video: video,
      audio: audio,
      metadataEncoding: applicationEncodingName,
      backchannel: backchannel,
      range: presMut.range.flatMap(PlaybackRange.parse)
    )
  }

  /// A fresh depacketizer for the video stream (also used to restart
  /// reassembly after a seek).
  private func makeVideoDepacketizer(for stream: Stream) throws -> VideoDepacketizer {
    if stream.encodingName == "h265" {
      return .h265(
        try H265Depacketizer(
          clockRate: stream.clockRateHz, formatSpecificParams: stream.formatSpecificParams))
    }
    return .h264(
      try H264Depacketizer(
        clockRate: stream.clockRateHz, formatSpecificParams: stream.formatSpecificParams))
  }

  // MARK: - Backchannel (ONVIF two-way audio)

  /// SETUP the first backchannel candidate whose codec the packetizer
  /// supports. Failures are reported via `onDiagnostic` and leave the session
  /// without two-way audio; only a timeout, which closed the connection, is
  /// thrown.
  private func setupBackchannel(candidates: [Int], presentation pres: Presentation) async throws {
    guard !candidates.isEmpty else {
      onDiagnostic?(
        RTSPDiagnostic(
          severity: .warning,
          message: "Camera offered no backchannel stream (a=sendonly audio); "
            + "two-way audio is unavailable."))
      return
    }
    let supported = candidates.filter {
      RTPAudioPacketizer.isSupported(encodingName: pres.streams[$0].encodingName)
    }
    guard !supported.isEmpty else {
      let offered = listForMessage(
        candidates.map { cutForMessage(pres.streams[$0].encodingName) })
      onDiagnostic?(
        RTSPDiagnostic(
          severity: .warning,
          message: "Camera's backchannel codecs (\(offered)) are not supported; "
            + "two-way audio is unavailable."))
      return
    }
    guard transport != .multicast else {
      onDiagnostic?(
        RTSPDiagnostic(
          severity: .warning,
          message: "Two-way audio needs a unicast transport; the backchannel is not set up "
            + "with Transport.multicast."))
      return
    }
    // One SSRC per participant (RFC 3550 section 8): the backchannel's RTP
    // and the receiver reports share it.
    let ssrc = reporterSSRC
    // Built before the SETUP, so a format it can't send sets up nothing; the
    // next supported stream is tried instead.
    var chosen: (index: Int, packetizer: RTPAudioPacketizer)?
    var firstError: (any Error)?
    for candidate in supported {
      let stream = pres.streams[candidate]
      do {
        chosen = (
          candidate,
          try RTPAudioPacketizer(
            encodingName: stream.encodingName, clockRate: stream.clockRateHz,
            channels: stream.channels, payloadType: stream.rtpPayloadType,
            formatSpecificParams: stream.formatSpecificParams, ssrc: ssrc,
            sequenceNumber: .random(in: .min ... .max), timestamp: .random(in: .min ... .max))
        )
        break
      } catch {
        firstError = firstError ?? error
      }
    }
    guard let chosen else {
      onDiagnostic?(
        RTSPDiagnostic(
          severity: .warning,
          message:
            "Camera's backchannel format can't be sent (\(firstError.map { "\($0)" } ?? "")); "
            + "two-way audio is unavailable."))
      return
    }
    let idx = chosen.index
    let packetizer = chosen.packetizer
    let stream = pres.streams[idx]
    do {
      _ = try await setupStream(
        controlURL: stream.control ?? pres.control, streamIndex: idx, outboundSSRC: ssrc)
      backchannelPacketizer = packetizer
      backchannelStreamIndex = idx
      backchannel = BackchannelStream(
        codec: publicAudioCodec(from: stream.encodingName), clockRate: stream.clockRateHz,
        channels: stream.channels, payloadType: stream.rtpPayloadType,
        formatSpecificParams: stream.formatSpecificParams)
    } catch {
      backchannelPacketizer = nil
      // The SETUP's deadline closed the connection (see audio's SETUP).
      if setupResponseTimedOut { throw RTSPError.timeout }
      onDiagnostic?(
        RTSPDiagnostic(
          severity: .warning,
          message: "Backchannel SETUP failed: \(error); two-way audio is unavailable."))
    }
  }

  func sendBackchannelAudio(
    _ payload: Data, samples: UInt32?, startsTalkspurt: Bool = false
  ) async throws {
    guard isPlaying, !isPaused, let conn = connection, let idx = backchannelStreamIndex,
      var packetizer = backchannelPacketizer
    else {
      throw RTSPError.invalidState(
        backchannelStreamIndex == nil
          ? "No backchannel was set up (see SessionDescription.backchannel)"
          : isPaused
            ? "The session is paused; call play() to resume it"
            : "The session is not playing")
    }
    let now = ContinuousClock.now
    var anchor = backchannelClockAnchor ?? (now, 0)
    if startsTalkspurt {
      // Where the RTP clock would be had audio kept flowing in real time;
      // skip forward to it if the audio sent so far ends earlier.
      packetizer.startTalkspurt(
        skippingTicks: Self.talkspurtSkip(
          elapsed: now - anchor.instant, clockRate: packetizer.clockRate,
          sentTicks: anchor.sentTicks))
      anchor = (now, 0)
    }
    let start = packetizer.nextTimestamp
    let packets: [Data]
    do {
      packets = try packetizer.packetize(payload, samples: samples)
    } catch {
      throw RTSPError.invalidState("Backchannel audio rejected: \(error)")
    }
    // A caller cancelled before anything was sent leaves the packetizer and
    // the clock anchor as they were.
    try Task.checkCancellation()
    anchor.sentTicks &+= UInt64(packetizer.nextTimestamp &- start)
    backchannelClockAnchor = anchor
    backchannelPacketizer = packetizer
    do {
      try await sendBackchannelPackets(packets, streamIndex: idx, on: conn)
    } catch let error as RTSPError {
      throw error
    } catch let error as CancellationError {
      throw error
    } catch {
      throw RTSPError.connectionFailed(
        "Sending backchannel audio failed: \(error)",
        underlying: (error as? RTSPError)?.underlyingNetworkError)
    }
  }

  private func sendBackchannelPackets(
    _ packets: [Data], streamIndex idx: Int, on conn: RTSPTransportConnection
  ) async throws {
    for (number, packet) in packets.enumerated() {
      // A cancelled caller sends no more of the chunk. The first packet goes
      // regardless: the caller checked just before taking its sequence number.
      if number > 0 { try Task.checkCancellation() }
      // pause() or stop() may run while an earlier packet is being sent;
      // nothing may follow PAUSE on the connection.
      guard isPlaying, !isPaused else {
        throw RTSPError.invalidState(
          isPaused
            ? "The session was paused while sending backchannel audio"
            : "The session stopped while sending backchannel audio")
      }
      switch transport {
      case .tcp:
        guard let channel = interleavedChannels[idx] else {
          throw RTSPError.invalidState("The backchannel has no interleaved channel")
        }
        var frame = Data([0x24, channel, UInt8(packet.count >> 8), UInt8(packet.count & 0xFF)])
        frame.append(packet)
        try await sendInOrder(frame, on: conn)
      case .udp:
        guard let pair = udpPairs[idx] else {
          throw RTSPError.invalidState("The backchannel socket is closed")
        }
        var datagram = packet
        if var context = srtpOutbound[idx] {
          datagram = try context.protectRTP(packet)
          srtpOutbound[idx] = context
        }
        try await pair.sendRTP(datagram)
      case .multicast:
        throw RTSPError.invalidState("Two-way audio is not available with Transport.multicast")
      }
    }
  }

  // MARK: - Playback control

  /// The PLAY and what follows from its answer run in a task of their own,
  /// which the caller waits for unless it is cancelled (see
  /// `valueUnlessCancelled`): RTSP can't take back a request that was sent,
  /// and the session must follow the server's answer (an accepted seek moves
  /// the playback; a rejected one is rolled back) whether or not anyone waits.
  /// The CSeq is taken and the request queued in one actor turn of that task,
  /// so requests go out in CSeq order.
  func play(_ options: PlayOptions) async throws {
    try Task.checkCancellation()
    try await valueUnlessCancelled(of: Task { try await self.sendPlay(options) })
  }

  /// The PAUSE, run as `play(_:)` runs its PLAY.
  func pause() async throws {
    try Task.checkCancellation()
    try await valueUnlessCancelled(of: Task { try await self.sendPause() })
  }

  private func sendPlay(_ options: PlayOptions) async throws {
    // The caller was cancelled before this task ran: nothing is sent.
    try Task.checkCancellation()
    guard phase == .running, isPlaying, connection != nil else {
      throw RTSPError.invalidState("play() requires a started session")
    }
    let isSeek = options.range != nil || options.immediate
    let cseq = nextCSeq(for: .play)
    if isSeek {
      // Kept until the response: a rejected seek puts the receive pipelines
      // back. An earlier seek still awaiting its response keeps its snapshot,
      // the state before either seek.
      if seekRollback == nil {
        seekRollback = SeekRollback(
          parsers: inorderParsers, video: depacketizer, audio: audioDepacketizer,
          application: applicationDepacketizer, replayTrackers: replayTrackers,
          receptionStats: receptionStats)
      }
      resetReceivePipelines()
      // An earlier seek still awaiting its response was replaced: its
      // response must not reseed sequence tracking for this one, but if the
      // server accepts it and rejects this one, its playback is the one that
      // continues.
      supersededSeekCSeqs.formUnion(seekPlayCSeqs)
      seekPlayCSeqs.removeAll()
      acceptedReplayCSeqs = [UInt8(truncatingIfNeeded: cseq)]
      replayFilteredStreams = Set(inorderParsers.keys)
      latestSeekCSeq = cseq
    }
    do {
      let resp = try await sessionRequest(
        method: .play, extraHeaders: options.headers(isInitial: false), isSeekPlay: isSeek,
        cseq: cseq)
      recordPlaybackState(cseq: resp.cseq ?? cseq, paused: false)
    } catch {
      // The playback before this PLAY continues. A failed seek stops the
      // filtering it started and restores the receive pipelines, unless a
      // newer seek has taken over since.
      if isSeek && latestSeekCSeq == cseq {
        rollBackSeek()
      }
      throw error
    }
  }

  private func sendPause() async throws {
    // The caller was cancelled before this task ran: nothing is sent.
    try Task.checkCancellation()
    guard phase == .running, isPlaying, connection != nil else {
      throw RTSPError.invalidState("pause() requires a started session")
    }
    // Paused before PAUSE goes out, so no receiver report or backchannel
    // packet follows it on the connection.
    let cseq = nextCSeq()
    pendingPauseCSeqs.insert(cseq)
    defer { pendingPauseCSeqs.remove(cseq) }
    let resp = try await sessionRequest(
      method: .pause, extraHeaders: [], isSeekPlay: false, cseq: cseq)
    recordPlaybackState(cseq: resp.cseq ?? cseq, paused: true)
  }

  /// Note a successful PLAY or PAUSE, unless one sent later already succeeded.
  private func recordPlaybackState(cseq: UInt32, paused: Bool) {
    if cseq >= confirmedPause.cseq { confirmedPause = (cseq, paused) }
  }

  /// The receive pipelines before a seek reset them, and the packets held
  /// while the seek PLAY was outstanding: the previous playback's, dropped as
  /// stale by their replay CSeq, and those of streams without replay tags,
  /// which can't be told apart from the new playback's until the response.
  /// A rejected seek restores the streams that took no packet since, and
  /// runs the held packets through them, so the playback that continues
  /// loses nothing and its timestamps don't jump. An accepted seek drops the
  /// stale packets and runs the untagged ones through the new pipelines.
  private struct SeekRollback {
    var parsers: [Int: InorderParser]
    var video: VideoDepacketizer?
    var audio: AudioDepacketizer?
    var application: ApplicationDepacketizer?
    var replayTrackers: [Int: ReplayTracker]
    var receptionStats: [Int: ReceptionStats]
    /// Streams that accepted a packet after the reset; they keep their state.
    var touched: Set<Int> = []
    var held: [HeldPacket] = []
    var heldBytes = 0
    /// Whether packets of untagged streams are still held: false once the
    /// hold limits were reached, after which they go straight to the new
    /// pipelines.
    var holdsUntagged = true

    struct HeldPacket {
      var streamIndex: Int
      var data: Data
      /// Tagged with the CSeq of a PLAY the seek replaced.
      var stale: Bool
    }

    mutating func hold(_ data: Data, streamIndex: Int, stale: Bool) -> Bool {
      guard held.count < SessionState.seekRollbackPacketLimit,
        heldBytes + data.count <= SessionState.seekRollbackByteLimit
      else { return false }
      held.append(HeldPacket(streamIndex: streamIndex, data: data, stale: stale))
      heldBytes += data.count
      return true
    }

    /// Take the held packets of untagged streams out, in arrival order.
    mutating func takeUntagged() -> [HeldPacket] {
      let untagged = held.filter { !$0.stale }
      held.removeAll { !$0.stale }
      heldBytes = held.reduce(0) { $0 + $1.data.count }
      return untagged
    }
  }

  /// A seek PLAY failed: stop its filtering and put back the pipelines, or,
  /// when the server accepted a seek this one replaced, start that seek's
  /// playback instead.
  private func rollBackSeek() {
    if let accepted = acceptedSupersededSeek {
      adoptSupersededSeek(accepted)
      return
    }
    acceptedReplayCSeqs = nil
    replayFilteredStreams.removeAll()
    guard var rollback = seekRollback else { return }
    seekRollback = nil
    var restored: Set<Int> = []
    for (idx, parser) in rollback.parsers where !rollback.touched.contains(idx) {
      inorderParsers[idx] = parser
      // Moved, not copied: the held packets below go through them.
      if idx == videoStreamIndex {
        depacketizer = rollback.video
        rollback.video = nil
      } else if idx == audioStreamIndex {
        audioDepacketizer = rollback.audio
        rollback.audio = nil
      } else if idx == applicationStreamIndex {
        applicationDepacketizer = rollback.application
        rollback.application = nil
      }
      replayTrackers[idx] = rollback.replayTrackers[idx]
      receptionStats[idx] = rollback.receptionStats[idx]
      restored.insert(idx)
    }
    routeHeldPackets(
      rollback.held.filter { restored.contains($0.streamIndex) }, firstSequences: [:])
  }

  /// The server accepted a seek that a later seek replaced, and the later one
  /// failed: the server plays from the earlier seek's position. Its playback
  /// starts in fresh pipelines, as if it had been the latest seek: the held
  /// packets tagged with its CSeq, or a later PLAY's that isn't a seek (a
  /// speed change or resume applies to its position), go through, older ones
  /// are dropped, and its response's RTP-Info applies.
  private func adoptSupersededSeek(_ accepted: (cseq: UInt32, response: RTSPResponse)) {
    acceptedSupersededSeek = nil
    supersededSeekCSeqs.removeAll()
    let held = seekRollback?.held ?? []
    seekRollback = nil
    resetReceivePipelines()
    let laterPlays = sentPlays.filter { $0.cseq > accepted.cseq && !$0.isSeek }
    acceptedReplayCSeqs = Set(
      [UInt8(truncatingIfNeeded: accepted.cseq)]
        + laterPlays.map { UInt8(truncatingIfNeeded: $0.cseq) })
    replayFilteredStreams = Set(inorderParsers.keys)
    latestSeekCSeq = accepted.cseq
    // After stop(), held packets mustn't become frames, as in routeHeldPackets.
    for packet in held where packet.stale && isPlaying {
      do {
        try receiveRTP(streamIndex: packet.streamIndex, data: packet.data)
      } catch {
        warnStreamOnce(
          "seek.held", .warning, "A packet held during a seek failed: \(error)")
      }
    }
    applySeekResponse(accepted.response, heldUntagged: held.filter { !$0.stale })
  }

  /// Send a request on the aggregate control URL through the reader, which
  /// owns the connection while the session runs. Throws `sessionSetupFailed`
  /// for a non-2xx response.
  private func sessionRequest(
    method: RTSPMethod, extraHeaders: [(String, String)], isSeekPlay: Bool,
    cseq: UInt32? = nil
  ) async throws -> RTSPResponse {
    guard readerTask != nil, !readerFinished else {
      throw RTSPError.unexpectedDisconnection
    }
    let resp = try await controlRequest(
      method: method, extraHeaders: extraHeaders, isSeekPlay: isSeekPlay, cseq: cseq)
    guard resp.statusCode >= 200 && resp.statusCode < 300 else {
      if resp.statusCode == 401 { throw RTSPError.authenticationFailed }
      throw RTSPError.sessionSetupFailed(
        statusCode: Int(resp.statusCode), reason: cutForMessage(resp.reasonPhrase))
    }
    return resp
  }

  /// Restart reassembly for a seek: packets of the previous playback that are
  /// still in flight must not be merged with the new position's. Sequence
  /// tracking restarts from the next packet (or the PLAY response's RTP-Info);
  /// the timeline continues, so `timestamp`s stay comparable across the seek.
  private func resetReceivePipelines() {
    // Every stream's new playback starts where the furthest-ahead stream's
    // next frame would have been, so none goes backwards and all stay aligned
    // (the response's RTP-Info, when it names a stream's `rtptime`, places
    // that stream there too).
    // Before any stream has a timestamp, the new playback starts at 0, where
    // the first one would have.
    let target = inorderParsers.values.compactMap(\.nextElapsedSeconds).max() ?? 0
    seekStartTarget = target
    for idx in Array(inorderParsers.keys) {
      inorderParsers[idx]?.restartSequenceTracking(continuingAt: target)
    }
    if let idx = videoStreamIndex, let stream = presentation?.streams[idx] {
      // The stream keeps the parameter sets it was using (in-band ones may
      // differ from the SDP's): frames before the next in-band set refer to
      // them, and only a different set is a change.
      var fresh = try? makeVideoDepacketizer(for: stream)
      if let old = depacketizer { fresh?.adoptParameters(from: old) }
      depacketizer = fresh
    }
    if let idx = audioStreamIndex, let stream = presentation?.streams[idx] {
      audioDepacketizer = try? AudioDepacketizer.create(
        encodingName: stream.encodingName, clockRate: stream.clockRateHz,
        channels: stream.channels, formatSpecificParams: stream.formatSpecificParams)
    }
    if applicationStreamIndex != nil {
      applicationDepacketizer = ApplicationDepacketizer(
        encodingName: applicationEncodingName, onDiagnostic: onDiagnostic)
    }
    replayTrackers.removeAll()
    // Restarted rather than removed: the last sender report stays, so the
    // receiver reports after the seek keep their LSR and DLSR.
    for idx in Array(receptionStats.keys) {
      receptionStats[idx]?.restart()
    }
    seekResponseReceived = false
    staleReplayDrops = 0
    staleReplayTimestamps = lastTaggedTimestamps
  }

  /// Apply a seek PLAY's response: seed each stream's sequence tracking from
  /// its RTP-Info, unless that stream's new playback already arrived (ahead of
  /// the response) and seeded it.
  private func applySeekResponse(_ resp: RTSPResponse) {
    // Held packets of untagged streams go through the new pipelines after
    // the RTP-Info is applied; the stale ones are dropped.
    let held = seekRollback?.takeUntagged() ?? []
    seekRollback = nil
    acceptedSupersededSeek = nil
    supersededSeekCSeqs.removeAll()
    applySeekResponse(resp, heldUntagged: held)
  }

  private func applySeekResponse(
    _ resp: RTSPResponse, heldUntagged held: [SeekRollback.HeldPacket]
  ) {
    seekResponseReceived = true
    var firstSequences: [Int: UInt16] = [:]
    defer { routeHeldPackets(held, firstSequences: firstSequences) }
    guard var pres = presentation else { return }
    for idx in pres.streams.indices {
      if case .setup = pres.streams[idx].state {
        pres.streams[idx].state = .setup(
          StreamStateInit(ssrc: nil, initialSeq: nil, initialRtptime: nil, ctx: .dummy))
      }
    }
    guard (try? parsePlay(response: resp, presentation: &pres)) != nil else { return }
    var infos: [Int: StreamStateInit] = [:]
    for idx in inorderParsers.keys {
      guard case .setup(let info) = pres.streams[idx].state,
        info.initialSeq != nil || info.initialRtptime != nil,
        !Self.isPlaceholderRTPInfo(info)
      else { continue }
      infos[idx] = info
    }
    // All streams' new playback starts at one time (RTP-Info `rtptime` names
    // each stream's timestamp at the new position). A stream whose new packets
    // came ahead of this response has already placed its `rtptime` on its
    // timeline, and the others follow it. Otherwise every stream starts at the
    // seek's common start (`seekStartTarget`), where the first packets of
    // streams RTP-Info doesn't name go too.
    let started = infos.compactMap { idx, info -> Double? in
      guard let parser = inorderParsers[idx], let rtptime = info.initialRtptime,
        parser.seekPlaybackStarted(seq: info.initialSeq, ssrc: info.ssrc)
      else { return nil }
      return parser.timeline.elapsedSeconds(at: rtptime)
    }
    let target =
      started.max() ?? seekStartTarget
      ?? inorderParsers.values.compactMap(\.nextElapsedSeconds).max()
    for (idx, info) in infos {
      let applied = inorderParsers[idx]?.applySeekRTPInfo(
        seq: info.initialSeq, rtptime: info.initialRtptime, ssrc: info.ssrc,
        elapsedSeconds: target)
      // Statistics already counting the previous playback's last packets
      // would report the jump to the new sequence numbers as loss.
      if applied == true {
        receptionStats[idx]?.restart()
        firstSequences[idx] = info.initialSeq
      }
    }
  }

  /// Record that a PLAY with `cseq` is going out. While a seek's filtering is
  /// active, the packets of any later PLAY (resume, speed change, a retry)
  /// are current too.
  private func didSendPlay(cseq: UInt32, isSeek: Bool = false) {
    sentPlays.append((cseq, isSeek))
    if sentPlays.count > 16 { sentPlays.removeFirst() }
    acceptedReplayCSeqs?.insert(UInt8(truncatingIfNeeded: cseq))
  }

  /// Whether a packet on `streamIndex` belongs to a playback an earlier seek
  /// replaced. `ext` is the packet's replay header extension, if any. An
  /// untagged packet on a stream that carries the extension is stale until
  /// the stream's first packet tagged with an accepted CSeq: it continues an
  /// access unit whose tagged first packet was stale.
  private func isStaleReplayPacket(
    _ ext: ONVIFReplayExtension?, streamIndex: Int, timestamp: UInt32?
  ) -> Bool {
    if ext != nil {
      replayTaggedStreams.insert(streamIndex)
      lastTaggedTimestamps[streamIndex] = timestamp
    }
    guard let accepted = acceptedReplayCSeqs, replayFilteredStreams.contains(streamIndex) else {
      return false
    }
    if let ext {
      if accepted.contains(ext.cseq) {
        replayFilteredStreams.remove(streamIndex)
        if replayFilteredStreams.isEmpty { acceptedReplayCSeqs = nil }
        return false
      }
    } else if !replayTaggedStreams.contains(streamIndex) {
      return false
    }
    if ext != nil { staleReplayTimestamps[streamIndex] = timestamp }
    guard seekResponseReceived else { return true }
    // An untagged packet with the RTP timestamp of the stream's last stale
    // tagged packet continues that access unit, however large, and isn't
    // counted. Any other untagged packet starts an access unit without a tag
    // (a server that stopped tagging after the seek) and counts.
    if ext == nil, let timestamp, staleReplayTimestamps[streamIndex] == timestamp {
      return true
    }
    staleReplayDrops += 1
    if staleReplayDrops > Self.staleReplayDropLimit {
      acceptedReplayCSeqs = nil
      replayFilteredStreams.removeAll()
      // Once per seek: the count starts over with the next one.
      onDiagnostic?(
        RTSPDiagnostic(
          severity: .warning,
          message: "Replay packets still carry an earlier PLAY's CSeq "
            + "\(Self.staleReplayDropLimit) packets after a seek; no longer filtering replay "
            + "packets by CSeq."))
      return false
    }
    return true
  }

  // MARK: - Frame delivery

  func nextFrame(consumer: UUID) async throws -> PublicCodecItem? {
    guard consumerSlot.claim(consumer) else {
      throw RTSPError.invalidState("frames() is already being consumed")
    }
    // Before start() succeeds there is no reader and nothing to wait for.
    guard readerTask != nil else {
      consumerSlot.release(consumer)
      return nil
    }
    if let waiter = frameWaiter {
      guard frameWaiterOwner != consumer else {
        throw RTSPError.invalidState("One frames() sequence is being iterated from two tasks")
      }
      // A previous consumer released the slot while suspended; end its wait.
      frameWaiter = nil
      frameWaiterOwner = nil
      waiter.resume(returning: nil)
    }
    if frameConsumer != consumer {
      // A later frames() sequence may feed a new decoder, so its first video
      // frame carries the parameter sets; the first one starts from the
      // description's.
      if hadFrameConsumer { reportedVideoParameters = nil }
      hadFrameConsumer = true
    }
    frameConsumer = consumer
    if Task.isCancelled {
      releaseConsumer(consumer)
      return nil
    }
    if let item = frameQueue.popFirst() {
      wakeReader()
      return handOff(item)
    }
    if readerFinished {
      if let error = readerError {
        readerError = nil
        throw error
      }
      return nil
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        frameWaiter = continuation
        frameWaiterOwner = consumer
      }
    } onCancel: {
      self.consumerSlot.release(consumer)
      Task { await self.releaseConsumer(consumer) }
    }
  }

  /// The consumer stopped iterating (cancelled, or its iterator was released).
  /// Frames are dropped until another `frames()` consumer arrives; the reader
  /// keeps running so keepalives and control requests still work.
  func releaseConsumer(_ consumer: UUID) {
    consumerSlot.release(consumer)
    if frameWaiterOwner == consumer, let waiter = frameWaiter {
      frameWaiter = nil
      frameWaiterOwner = nil
      waiter.resume(returning: nil)
    }
    guard frameConsumer == consumer else { return }
    frameConsumer = nil
    queueForFirstConsumer = false
    for item in frameQueue.removeAll() { noteDropped(item) }
    wakeReader()
  }

  /// Hand a frame to the consumer, or queue it.
  private func deliver(_ item: PublicCodecItem) {
    guard frameConsumer != nil || queueForFirstConsumer else {
      noteDropped(item)
      return
    }
    if let waiter = frameWaiter {
      frameWaiter = nil
      frameWaiterOwner = nil
      waiter.resume(returning: handOff(item))
      return
    }
    frameQueue.append(item)
    // Before the first consumer, keep the newest frames for it. With a
    // consumer, the reader stops at the soft limits unless a control response
    // is awaited; the hard limits bound the queue while it is.
    let firstConsumer = frameConsumer == nil
    let countLimit = firstConsumer ? Self.frameQueueLimit : Self.frameQueueHardLimit
    let byteLimit = firstConsumer ? Self.frameQueueByteLimit : Self.frameQueueHardByteLimit
    var dropped = false
    while frameQueue.count > countLimit || (frameQueue.bytes > byteLimit && frameQueue.count > 1) {
      if let item = frameQueue.popFirst() { noteDropped(item) }
      dropped = true
    }
    if dropped && !firstConsumer {
      warnStreamOnce(
        "frames.overflow", .warning,
        "frames() consumer fell more than \(Self.frameQueueHardLimit) items or "
          + "\(Self.frameQueueHardByteLimit >> 20) MiB behind while a control request was "
          + "pending; dropping the oldest frames.")
    }
  }

  /// Suspend the reader while the consumer has a full queue. It keeps reading
  /// before the first consumer, while a control response is awaited (that
  /// response arrives on the same connection), once the consumer is gone,
  /// and after `stop()`.
  private func waitForConsumer() async {
    while frameConsumer != nil,
      frameQueue.count >= Self.frameQueueLimit || frameQueue.bytes >= Self.frameQueueByteLimit,
      pendingResponses.isEmpty, isPlaying
    {
      await withCheckedContinuation { readerSpaceWaiter = $0 }
    }
  }

  private func wakeReader() {
    readerSpaceWaiter?.resume()
    readerSpaceWaiter = nil
  }

  /// The reader loop: receives on the connection (and UDP/multicast sockets)
  /// until the connection closes, by `stop()` (clean) or by the peer (the
  /// error is delivered to the consumer after the frames queued before it).
  private func runReader() async {
    guard let conn = connection else {
      finishReader(error: nil)
      return
    }
    startKeepalive()
    startReceiverReports()
    var failure: Error?
    do {
      switch transport {
      case .tcp:
        try await readInterleaved(conn: conn)
      case .udp, .multicast:
        try await readDatagrams(conn: conn)
      }
    } catch {
      failure = error
    }
    keepaliveTask?.cancel()
    keepaliveTask = nil
    receiverReportTask?.cancel()
    receiverReportTask = nil
    finishReader(error: failure)
  }

  private func finishReader(error: Error?) {
    readerFinished = true
    readerError = error
    failAllPending(.unexpectedDisconnection)
    if let waiter = frameWaiter {
      frameWaiter = nil
      frameWaiterOwner = nil
      readerError = nil
      if let error {
        waiter.resume(throwing: error)
      } else {
        waiter.resume(returning: nil)
      }
    }
  }

  /// TCP-interleaved reader loop. Owns the single TCP connection: it
  /// demultiplexes interleaved RTP/RTCP and routes RTSP responses (keepalive,
  /// PLAY/PAUSE, TEARDOWN) back to their waiters. Runs until the socket closes
  /// — by stop() (clean) or by the peer (propagates the error).
  private func readInterleaved(conn: RTSPTransportConnection) async throws {
    while true {
      await waitForConsumer()
      let msg: RTSPMessage
      do {
        msg = try await conn.receiveMessage()
      } catch {
        // After stop() set isPlaying = false, the socket close is expected —
        // end cleanly. Otherwise the peer dropped us; propagate the error.
        if !isPlaying { break }
        throw error
      }

      // Route control responses to their awaiting sender.
      if case .response(let resp) = msg {
        if let cseq = resp.cseq { resumePending(cseq, .success(resp)) }
        continue
      }

      // After stop(), media read on the way to TEARDOWN's response is
      // discarded: the consumer gets only the items already waiting.
      guard case .data(let interleaved) = msg, isPlaying else { continue }
      guard let mapping = channelMappings.lookup(interleaved.channelId) else {
        // The camera sent interleaved data on a channel we never negotiated.
        // Drop it (can't route it) but surface it once per channel.
        warnStreamOnce(
          "channel.\(interleaved.channelId)", .warning,
          "Interleaved data on unassigned channel \(interleaved.channelId); dropped.")
        continue
      }

      if mapping.channelType == .rtp {
        try receiveRTP(streamIndex: mapping.streamIndex, data: interleaved.data)
      } else if mapping.channelType == .rtcp {
        try routeRTCP(streamIndex: mapping.streamIndex, data: interleaved.data)
      }
    }
  }

  /// UDP/multicast reader loop. RTP and RTCP arrive on per-stream sockets while
  /// RTSP control stays on the TCP connection, so the sources are multiplexed
  /// through one ordered event stream and fed to the same routing pipeline as
  /// TCP. Runs until the TCP control connection closes — by stop() (clean) or
  /// by the peer (propagates the error).
  private func readDatagrams(conn: RTSPTransportConnection) async throws {
    udpControlError = nil
    let queue = DatagramQueue(
      maxCount: Self.udpEventBufferCount, maxBytes: Self.udpEventBufferBytes)

    // Per-stream receivers feed RTP/RTCP datagrams into the event stream. Each
    // socket's callbacks are serial, so per-stream packet order holds.
    let diag = onDiagnostic
    var sources: [(Int, any RTPDatagramSource)] = udpPairs.map { ($0.key, $0.value) }
    sources += multicastPairs.map { ($0.key, $0.value) }
    processedDatagrams = 0
    deferredSeekResponses = []
    for (idx, source) in sources {
      source.startReceiving(
        onRTP: { data in queue.enqueue { .rtp(streamIndex: idx, data: data, arrival: $0) } },
        onRTCP: { data in queue.enqueue { .rtcp(streamIndex: idx, data: data, arrival: $0) } },
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
    // data). The control reader handles them directly (off the lossy data
    // buffer, and regardless of consumer backpressure) and, on close, records
    // why and ends the event stream so the consumer unblocks even if no more
    // datagrams arrive.
    let controlReader = Task { [weak self] in
      while true {
        let msg: RTSPMessage
        do {
          msg = try await conn.receiveMessage()
        } catch {
          let rtspError = (error as? RTSPError) ?? .connectionFailed("\(error)")
          await self?.recordUDPControlClose(rtspError)
          queue.finish()
          return
        }
        if case .response(let resp) = msg, let cseq = resp.cseq {
          let queuedBefore = queue.queued
          await self?.receiveDatagramSessionResponse(cseq, resp, queuedBefore: queuedBefore)
        }
        // Interleaved data isn't expected on a UDP session; ignore it.
      }
    }

    // The reader owns teardown: stop the control reader and release the
    // sockets (stop() also closes them — close() is idempotent). The control
    // reader may linger blocked on receiveMessage until stop() closes the TCP
    // connection; that is the documented contract for releasing the session.
    defer {
      controlReader.cancel()
      queue.finish()
      for (_, source) in sources { source.close() }
    }

    while let event = await queue.next() {
      // After stop(), datagrams still in the buffer are discarded, as a TCP
      // session discards the media it reads on the way to TEARDOWN's
      // response. The loop itself runs on until the control connection
      // closes: stop() sends TEARDOWN through it first.
      guard isPlaying else { continue }
      // A response deferred until this datagram's predecessors were taken
      // (some may have been dropped from the full buffer) goes first.
      resumeDeferredSeekResponses(through: event.arrival - 1)
      switch event {
      case .rtp(let idx, let data, _):
        guard let packet = unprotectSRTP(data, streamIndex: idx, isRTCP: false) else { break }
        try receiveRTP(streamIndex: idx, data: packet)
      case .rtcp(let idx, let data, _):
        guard let packet = unprotectSRTP(data, streamIndex: idx, isRTCP: true) else { break }
        try routeRTCP(streamIndex: idx, data: packet)
      }
      processedDatagrams = event.arrival
      resumeDeferredSeekResponses(through: event.arrival)
      await waitForConsumer()
    }
    resumeDeferredSeekResponses(through: .max)

    // The stream finished, which only happens when the control connection
    // closed. A clean stop() (isPlaying == false) ends here; a peer drop while
    // still playing propagates the recorded transport error.
    if isPlaying, let error = udpControlError {
      throw error
    }
  }

  /// Decrypt and authenticate an SRTP/SRTCP packet for a stream with SRTP
  /// keys; plain packets pass through. A packet that fails is dropped.
  private func unprotectSRTP(_ data: Data, streamIndex: Int, isRTCP: Bool) -> Data? {
    guard var context = srtpInbound[streamIndex] else { return data }
    defer { srtpInbound[streamIndex] = context }
    do {
      return isRTCP ? try context.unprotectRTCP(data) : try context.unprotectRTP(data)
    } catch let error as SRTPError where error.kind == .replayed {
      // A duplicate or very late datagram: normal on UDP, dropped quietly.
      return nil
    } catch {
      let kind = isRTCP ? "SRTCP" : "SRTP"
      warnStreamOnce(
        "srtp.\(kind).\(streamIndex)", .warning,
        "\(kind) packet on stream \(streamIndex) failed authentication or decryption "
          + "(\(error)); dropped. Further failures on this stream are dropped silently.")
      return nil
    }
  }

  /// Datagrams of this UDP session the reader has taken (`arrival` of the
  /// last one).
  private var processedDatagrams: UInt64 = 0

  /// Seek PLAY responses waiting for the datagrams queued before them.
  private var deferredSeekResponses:
    [(queuedBefore: UInt64, cseq: UInt32, response: RTSPResponse)] =
      []

  /// A response on a UDP session's control connection. A seek PLAY's response
  /// is applied only after the datagrams queued before it have been taken, as
  /// on TCP, where they arrive ahead of it on the one connection: a consumer
  /// that fell behind leaves up to `udpEventBufferCount` datagrams (or
  /// `udpEventBufferBytes`) of the
  /// playback before the seek in the queue, which must be held or dropped as
  /// that playback's, not taken for the new one's. The reader doesn't wait for
  /// the consumer while the PLAY is outstanding, so the wait is short.
  private func receiveDatagramSessionResponse(
    _ cseq: UInt32, _ response: RTSPResponse, queuedBefore: UInt64
  ) {
    if queuedBefore > processedDatagrams,
      seekPlayCSeqs.contains(cseq) || supersededSeekCSeqs.contains(cseq)
    {
      deferredSeekResponses.append((queuedBefore, cseq, response))
    } else {
      resumePending(cseq, .success(response))
    }
  }

  /// Apply the deferred seek responses that came after datagram `arrival` at
  /// the latest.
  private func resumeDeferredSeekResponses(through arrival: UInt64) {
    while let first = deferredSeekResponses.first, first.queuedBefore <= arrival {
      deferredSeekResponses.removeFirst()
      resumePending(first.cseq, .success(first.response))
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

  /// Take one RTP packet from the network. Packets of a playback a seek
  /// replaced are dropped, and while a seek PLAY is outstanding they, and
  /// the packets of streams without replay tags, are held for its response
  /// (see `SeekRollback`).
  private func receiveRTP(streamIndex: Int, data: Data) throws {
    guard inorderParsers[streamIndex] != nil else { return }
    let ext = ONVIFReplayExtension(rtpPacket: data)
    let timestamp =
      data.count >= 8
      ? data.dropFirst(4).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } : nil
    if isStaleReplayPacket(ext, streamIndex: streamIndex, timestamp: timestamp) {
      if !seekResponseReceived {
        _ = seekRollback?.hold(data, streamIndex: streamIndex, stale: true)
      }
      return
    }
    if ext == nil, !replayTaggedStreams.contains(streamIndex), !seekResponseReceived,
      seekRollback?.holdsUntagged == true
    {
      if seekRollback?.hold(data, streamIndex: streamIndex, stale: false) == true { return }
      // Too much to hold: the new pipelines take these streams' packets from
      // here on, and a rejected seek can't restore them.
      seekRollback?.holdsUntagged = false
      routeHeldPackets(seekRollback?.takeUntagged() ?? [], firstSequences: [:])
    }
    try routeRTP(streamIndex: streamIndex, data: data)
  }

  /// Run packets held during a seek through the current pipelines. A stream
  /// in `firstSequences` (the seek response's RTP-Info) skips the packets
  /// before its new playback's first one: they belong to the playback the
  /// seek replaced.
  private func routeHeldPackets(
    _ held: [SeekRollback.HeldPacket], firstSequences: [Int: UInt16]
  ) {
    // After stop(), as with the media the readers discard, held packets give
    // no more frames: the consumer gets only the items already waiting.
    guard isPlaying else { return }
    var waiting = firstSequences
    for packet in held {
      if let first = waiting[packet.streamIndex] {
        let data = packet.data
        guard data.count >= 4 else { continue }
        let seq = UInt16(data[data.startIndex + 2]) << 8 | UInt16(data[data.startIndex + 3])
        // The first packet, or a later one when it was lost.
        guard seq &- first < Self.seekStartWindow else { continue }
        waiting[packet.streamIndex] = nil
      }
      do {
        try routeRTP(streamIndex: packet.streamIndex, data: packet.data)
      } catch {
        warnStreamOnce(
          "seek.held", .warning, "A packet held during a seek failed: \(error)")
      }
    }
  }

  /// How far after the RTP-Info `seq` a held packet may be to count as the
  /// new playback's first one received.
  private static let seekStartWindow: UInt16 = 100

  /// Run one RTP packet through its stream's in-order parser, and remember
  /// its replay header extension for annotating the frame it completes.
  private func receivePacket(
    _ parser: inout InorderParser, streamIndex: Int, data: Data
  ) throws -> ReceivedRTPPacket? {
    let ext = ONVIFReplayExtension(rtpPacket: data)
    guard
      let pkt = try parser.rtp(
        data: data, ctx: .dummy, streamId: streamIndex, streamCtx: .dummy)
    else { return nil }
    if seekRollback != nil { seekRollback?.touched.insert(streamIndex) }
    if let ext {
      replayTrackers[streamIndex, default: ReplayTracker()].record(
        timestamp: pkt.timestamp.timestamp, ext: ext)
    }
    let clockRate = Double(pkt.timestamp.clockRate)
    let (seconds, attoseconds) = (ContinuousClock.now - clockOrigin).components
    let arrivalTicks = Int64((Double(seconds) + Double(attoseconds) * 1e-18) * clockRate)
    receptionStats[streamIndex, default: ReceptionStats()].recordPacket(
      ssrc: pkt.ssrc, sequence: pkt.sequenceNumber, rtpTimestamp: pkt.raw.rtpTimestamp,
      arrivalTicks: arrivalTicks, timingRestarted: pkt.timelineRebased)
    return pkt
  }

  /// `ReplayInfo` for a frame of `streamIndex` at `timestamp`, or nil for a
  /// live stream.
  private func replayInfo(streamIndex: Int, timestamp: Timestamp) -> ReplayInfo? {
    replayTrackers[streamIndex]?.info(
      forFrameAt: timestamp.timestamp, clockRate: timestamp.clockRate)
  }

  /// Route one RTP packet to its stream's depacketizer, delivering any
  /// completed frames. Shared by the TCP and UDP reader loops; a missing parser
  /// or depacketizer (a disabled stream, or the backchannel) drops the packet.
  /// A malformed wire packet or a per-frame depacketization failure drops that
  /// packet/frame and emits a rate-limited diagnostic rather than tearing down
  /// the whole stream — only the opt-in `.abortSession` SSRC policy still
  /// propagates fatally.
  private func routeRTP(streamIndex: Int, data: Data) throws {
    guard var parser = inorderParsers[streamIndex] else { return }
    defer { inorderParsers[streamIndex] = parser }

    if let videoIdx = videoStreamIndex, streamIndex == videoIdx {
      // Taken out while it works, so the stored copy doesn't share its buffers
      // (a shared copy would copy the frame in progress on every packet).
      guard var depkt = depacketizer else { return }
      depacketizer = nil
      defer { depacketizer = depkt }
      guard let pkt = try receivePacket(&parser, streamIndex: streamIndex, data: data)
      else { return }
      if pkt.payload.isEmpty {
        warnStreamOnce(
          "video.empty", .warning, "Empty video RTP payload from camera; packets skipped.")
      }
      // A push that fails can still have completed the previous frame (the
      // packet's new timestamp ends it), so drain the output either way.
      do {
        try depkt.push(pkt)
      } catch {
        warnStreamOnce(
          "video.push", .error, "Video depacketizer push failed; packet dropped: \(error)")
      }
      surfaceVideoAnomalies(depkt)
      while let result = depkt.pull() {
        switch result {
        case .success(.videoFrame(let frame)):
          deliver(
            .video(
              convertFrame(
                frame,
                replay: replayInfo(streamIndex: streamIndex, timestamp: frame.timestamp))))
        case .failure(let err):
          warnStreamOnce(
            "video.pull", .error, "Video depacketization failed; frame dropped: \(err)")
        default:
          break
        }
      }
    } else if let audioIdx = audioStreamIndex, streamIndex == audioIdx {
      guard var depkt = audioDepacketizer else { return }
      audioDepacketizer = nil
      defer { audioDepacketizer = depkt }
      guard let pkt = try receivePacket(&parser, streamIndex: streamIndex, data: data)
      else { return }
      do {
        try depkt.push(pkt)
      } catch {
        warnStreamOnce(
          "audio.push", .error, "Audio depacketizer push failed; packet dropped: \(error)")
      }
      while let result = depkt.pull() {
        switch result {
        case .success(.audioFrame(let frame)):
          // A new source, clock restart or seek continues after this frame's
          // end, not just after its packet's timestamp.
          parser.timeline.noteFrameEnd(
            frame.timestamp.timestamp &+ Int64(depkt.ticks(of: frame, channels: audioChannels)))
          deliver(
            .audio(
              PublicAudioFrame(
                data: frame.data,
                timestamp: frame.timestamp.elapsedSeconds,
                codec: publicAudioCodec(from: audioEncodingName ?? ""),
                sampleRate: Self.audioSampleRate(
                  encoding: audioEncodingName ?? "", clockRate: audioClockRate ?? 0),
                channels: audioChannels,
                loss: frame.loss,
                replay: replayInfo(streamIndex: streamIndex, timestamp: frame.timestamp))))
        case .failure(let err):
          warnStreamOnce(
            "audio.pull", .error, "Audio depacketization failed; frame dropped: \(err)")
        default:
          break
        }
      }
    } else if let applicationIdx = applicationStreamIndex, streamIndex == applicationIdx {
      guard var depkt = applicationDepacketizer else { return }
      applicationDepacketizer = nil
      defer { applicationDepacketizer = depkt }
      guard let pkt = try receivePacket(&parser, streamIndex: streamIndex, data: data)
      else { return }
      do {
        try depkt.push(pkt)
      } catch {
        warnStreamOnce(
          "metadata.push", .error, "Metadata depacketizer push failed; packet dropped: \(error)")
      }
      while let result = depkt.pull() {
        switch result {
        case .success(.metadataFrame(let frame)):
          let encoding = applicationEncodingName ?? ""
          deliver(
            .metadata(
              PublicMetadataFrame(
                data: frame.data,
                timestamp: frame.timestamp.elapsedSeconds,
                encodingName: encoding,
                loss: frame.loss,
                xml: metadataXML(frame.data, encoding: encoding),
                replay: replayInfo(streamIndex: streamIndex, timestamp: frame.timestamp))))
        case .failure(let err):
          warnStreamOnce(
            "metadata.pull", .error, "Metadata depacketization failed; frame dropped: \(err)")
        default:
          break
        }
      }
    }
  }

  /// The XML document of a metadata frame: the payload itself, or the
  /// decompressed payload for the gzip encoding. nil for EXI (not decoded).
  /// Decompressed documents are capped at the size limit for uncompressed
  /// metadata (1 MiB), so a small gzip payload can't inflate to many MiB per
  /// frame on the session actor.
  private func metadataXML(_ data: Data, encoding: String) -> Data? {
    switch encoding {
    case "vnd.onvif.metadata":
      return data
    case "vnd.onvif.metadata.gzip":
      do {
        return try Gzip.decompress(data, maxOutputBytes: ApplicationDepacketizer.maxFragmentBytes)
      } catch {
        warnStreamOnce(
          "metadata.gzip", .warning,
          "Could not decompress gzip metadata (\(error)); xml is nil for such frames.")
        return nil
      }
    default:
      return nil
    }
  }

  /// Route one RTCP packet to its stream's parser, delivering a public RTCP
  /// item when a sender report is parsed. Shared by both reader loops.
  private func routeRTCP(streamIndex: Int, data: Data) throws {
    guard var parser = inorderParsers[streamIndex] else { return }
    defer { inorderParsers[streamIndex] = parser }
    if let rtcpPkt = try parser.rtcp(ctx: .dummy, streamId: streamIndex, data: data) {
      if let first = try? ReceivedCompoundPacket.validate(data),
        let report = try? first.asSenderReport()
      {
        receptionStats[streamIndex, default: ReceptionStats()].recordSenderReport(
          ssrc: report.ssrc, ntpTimestamp: report.ntpTimestamp.rawValue,
          arrival: ContinuousClock.now)
      }
      deliver(
        .rtcp(
          PublicRTCPPacket(
            timestamp: rtcpPkt.rtpTimestamp?.elapsedSeconds, data: rtcpPkt.raw)))
    }
  }

  func stop() async {
    switch phase {
    case .idle:
      phase = .stopped
      return
    case .starting:
      // start() owns the connection and is suspended in it. Closing it ends
      // that wait at once; start() then sees the flag, releases what it
      // opened and throws.
      stopRequested = true
      phase = .stopped
      isPlaying = false
      await connection?.close()
      return
    case .running, .stopped:
      break
    }
    // A stop() already tearing down: wait for it rather than sending a
    // second TEARDOWN.
    if stopInProgress {
      await withCheckedContinuation { stopWaiters.append($0) }
      return
    }
    stopInProgress = true
    defer {
      stopInProgress = false
      let waiters = stopWaiters
      stopWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
    phase = .stopped
    let readerRunning = readerTask != nil && !readerFinished
    isPlaying = false
    wakeReader()
    keepaliveTask?.cancel()
    keepaliveTask = nil
    receiverReportTask?.cancel()
    receiverReportTask = nil

    if readerRunning, connection != nil, sessionId != nil {
      // TEARDOWN (best-effort), through the reader, which owns the socket.
      _ = try? await controlRequest(method: .teardown, timeoutSeconds: 5)
    }

    // Closing the socket unblocks the reader's pending receive (it ends cleanly
    // because isPlaying is now false) and lets us fail any outstanding waiter.
    await connection?.close()
    failAllPending(RTSPError.unexpectedDisconnection)
    connection = nil

    // Release any UDP/multicast sockets (no-op for TCP). close() is
    // idempotent, so the reader loop's defer closing them too is harmless.
    for pair in udpPairs.values {
      pair.close()
    }
    udpPairs.removeAll()
    for pair in multicastPairs.values {
      pair.close()
    }
    multicastPairs.removeAll()
    backchannelPacketizer = nil
  }

  // MARK: - Control channel (requests while the reader owns the connection)

  /// Send a control request on the streaming connection and await its response,
  /// which the reader loop routes back by CSeq. Used while the reader owns the
  /// connection: we must not issue a competing read here. Bounded by
  /// `timeoutSeconds`. A seek PLAY's response is applied by the reader as it
  /// arrives, before the packets that follow it are routed.
  private func sendControlRequest(
    method: RTSPMethod,
    extraHeaders: [(String, String)] = [],
    timeoutSeconds: Double = 10,
    isSeekPlay: Bool = false,
    cseq preallocated: UInt32? = nil
  ) async throws -> RTSPResponse {
    guard let conn = connection, let url = aggregateURL ?? self.url else {
      throw RTSPError.connectionFailed("Not connected")
    }
    // Nothing would answer once the reader has ended (a 401 retry after the
    // server closed the connection, for one).
    guard readerTask != nil, !readerFinished else { throw RTSPError.unexpectedDisconnection }
    let cseq = preallocated ?? nextCSeq(for: method)
    var request = RTSPRequest(method: method, url: url)
    request.setHeader("CSeq", value: "\(cseq)")
    if let userAgent = userAgent, !userAgent.isEmpty {
      request.setHeader("User-Agent", value: userAgent)
    }
    if let sid = sessionId {
      request.setHeader("Session", value: sid)
    }
    if authenticator?.hasChallenge == true,
      let authHeader = authenticator!.authorizationHeader(method: method.rawValue, uri: url)
    {
      request.setHeader("Authorization", value: authHeader)
    }
    for (name, value) in requireHeaders(for: method) + extraHeaders {
      request.setHeader(name, value: value)
    }
    if method == .play { didSendPlay(cseq: cseq, isSeek: isSeekPlay) }
    if isSeekPlay { seekPlayCSeqs.insert(cseq) }
    let data = RTSPSerializer().serialize(request)

    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<RTSPResponse, any Error>) in
      // Register the waiter BEFORE the bytes go out so the reader can never see
      // the response before we are ready to receive it, and wake the reader
      // if it's waiting for the consumer: the response has to be read.
      pendingResponses[cseq] = continuation
      wakeReader()
      let previousSend = lastControlSend
      lastControlSend = Task {
        await previousSend?.value
        do {
          try await conn.send(data)
        } catch {
          self.resumePending(
            cseq,
            .failure(
              .connectionFailed(
                "control send failed: \(error)",
                underlying: (error as? RTSPError)?.underlyingNetworkError)))
        }
      }
      pendingTimeouts[cseq] = Task {
        try? await Task.sleep(for: .seconds(timeoutSeconds))
        self.resumePending(cseq, .failure(.timeout))
      }
    }
  }

  /// RTP clock ticks a talkspurt skips: the time since the anchor in ticks at
  /// `clockRate`, less the `sentTicks` of audio sent since, or 0 when the
  /// audio sent reaches that far. Counted in 64 bits, so any silence
  /// longer than 2^31 ticks (12 hours at 48 kHz) still skips, by its length
  /// modulo 2^32 as RTP timestamps wrap.
  static func talkspurtSkip(elapsed: Duration, clockRate: UInt32, sentTicks: UInt64) -> UInt32 {
    let (seconds, attoseconds) = elapsed.components
    guard seconds >= 0, attoseconds >= 0 else { return 0 }
    let rate = UInt64(clockRate)
    let (whole, overflow) = UInt64(seconds).multipliedReportingOverflow(by: rate)
    guard !overflow else { return 0 }
    let ticks = whole &+ UInt64(Double(attoseconds) * 1e-18 * Double(rate))
    return ticks > sentTicks ? UInt32(truncatingIfNeeded: ticks - sentTicks) : 0
  }

  /// Whether an RTP-Info entry is the `seq=0;rtptime=0` placeholder some
  /// cameras send instead of a real seed (their RTP timestamps start
  /// elsewhere): neither value is used, at the first PLAY or after a seek.
  private static func isPlaceholderRTPInfo(_ info: StreamStateInit) -> Bool {
    info.initialSeq == 0 && (info.initialRtptime ?? 0) == 0
  }

  /// Write an interleaved frame (a receiver report or backchannel packet)
  /// after every request and frame sent before it. Its caller checked
  /// `isPlaying`/`isPaused` in the same actor turn, so the frame reaches the
  /// server before a PAUSE or TEARDOWN sent after that check, whatever the
  /// priorities of the tasks involved; a direct `conn.send` could follow it.
  private func sendInOrder(_ frame: Data, on conn: RTSPTransportConnection) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      let previousSend = lastControlSend
      lastControlSend = Task {
        await previousSend?.value
        do {
          try await conn.send(frame)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// `sendControlRequest`, answering a 401: a camera that expires its Digest
  /// nonce during a long session challenges a keepalive or PLAY again, and
  /// the retry carries credentials for the new challenge (once more when the
  /// retry is refused with `stale=true` and a new nonce). Returns the final response,
  /// whatever its status.
  private func controlRequest(
    method: RTSPMethod,
    extraHeaders: [(String, String)] = [],
    timeoutSeconds: Double = 10,
    isSeekPlay: Bool = false,
    cseq: UInt32? = nil
  ) async throws -> RTSPResponse {
    // What sendControlRequest is about to send (it adds no Authorization
    // without a challenge).
    var sent = authenticator?.sending ?? .none
    var resp = try await sendControlRequest(
      method: method, extraHeaders: extraHeaders, timeoutSeconds: timeoutSeconds,
      isSeekPlay: isSeekPlay, cseq: cseq)
    var retries = 0
    while resp.statusCode == 401, !resp.headers(named: "WWW-Authenticate").isEmpty,
      var auth = authenticator
    {
      // Taken in even when not retried, so the next request answers the
      // latest challenge.
      auth.handleChallenges(resp.headerValues(named: "WWW-Authenticate"))
      authenticator = auth
      guard auth.retries(afterRejecting: sent),
        retries == 0 || (retries == 1 && auth.digestIsStale && auth.sending != sent)
      else { return resp }
      // A seek a later seek replaced isn't retried: the retry would go out
      // after the later seek and move the server back to the replaced position.
      if isSeekPlay, let cseq, latestSeekCSeq != cseq { return resp }
      // After stop() the session is being torn down: a retry would follow the
      // TEARDOWN with the dead session's id. TEARDOWN's own 401 is answered.
      guard method == .teardown || phase != .stopped else { return resp }
      // A PLAY or PAUSE whose caller was cancelled sends nothing more; the
      // 401 stands as the server's answer.
      guard method == .teardown || !Task.isCancelled else { return resp }
      retries += 1
      sent = auth.sending
      resp = try await sendControlRequest(
        method: method, extraHeaders: extraHeaders, timeoutSeconds: timeoutSeconds,
        isSeekPlay: isSeekPlay)
    }
    return resp
  }

  /// Resume (exactly once) the waiter for `cseq`, if still pending. The
  /// remove-then-resume is actor-isolated, so the reader, a send failure, and
  /// the timeout can race safely — the first to run wins, the rest no-op.
  private func resumePending(_ cseq: UInt32, _ result: Result<RTSPResponse, RTSPError>) {
    // Cancel the (now-moot) timeout task; its only action after the sleep is a
    // no-op resumePending, so cancelling is always safe.
    pendingTimeouts.removeValue(forKey: cseq)?.cancel()
    if seekPlayCSeqs.remove(cseq) != nil, case .success(let response) = result,
      response.statusCode >= 200 && response.statusCode < 300
    {
      applySeekResponse(response)
    } else if supersededSeekCSeqs.remove(cseq) != nil, case .success(let response) = result,
      response.statusCode >= 200 && response.statusCode < 300, seekRollback != nil,
      cseq > acceptedSupersededSeek?.cseq ?? 0
    {
      acceptedSupersededSeek = (cseq, response)
    }
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
    seekPlayCSeqs.removeAll()
    supersededSeekCSeqs.removeAll()
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

  /// Send RTCP receiver reports for the receive streams while the reader runs:
  /// over the interleaved RTCP channel (TCP) or the RTCP socket (UDP, as
  /// SRTCP for RTSPS). Multicast sessions stay receive-only.
  private func startReceiverReports() {
    receiverReportTask?.cancel()
    guard transport != .multicast else { return }
    let fixed = receiverReportIntervalOverride
    receiverReportTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: fixed ?? .seconds(5) * Double.random(in: 0.5...1.5))
        guard !Task.isCancelled, let self else { return }
        await self.sendReceiverReports()
      }
    }
  }

  private func sendReceiverReports() async {
    guard isPlaying, let conn = connection else { return }
    let now = ContinuousClock.now
    for index in receptionStats.keys.sorted() {
      // Checked per stream: pause() or stop() may run while an earlier report
      // is sent, and nothing may follow TEARDOWN. UDP reports continue while
      // paused and keep NAT bindings open.
      guard isPlaying, !(isPaused && transport == .tcp) else { return }
      guard var stats = receptionStats[index], let block = stats.reportBlock(now: now) else {
        continue
      }
      receptionStats[index] = stats
      var packet = RTCPReport.receiverReport(
        reporterSSRC: reporterSSRC, blocks: [block], cname: rtcpCNAME)
      do {
        switch transport {
        case .tcp:
          guard let channel = interleavedChannels[index] else { continue }
          var frame = Data([
            0x24, channel &+ 1, UInt8(packet.count >> 8), UInt8(packet.count & 0xFF),
          ])
          frame.append(packet)
          try await sendInOrder(frame, on: conn)
        case .udp:
          guard let pair = udpPairs[index] else { continue }
          if var context = srtpOutbound[index] {
            packet = try context.protectRTCP(packet)
            srtpOutbound[index] = context
          }
          try await pair.sendRTCP(packet)
        case .multicast:
          return
        }
      } catch {
        warnStreamOnce(
          "rtcp.rr.\(index)", .warning,
          "Sending an RTCP receiver report on stream \(index) failed: \(error)")
      }
    }
  }

  /// Send one keepalive request, surfacing the outcome as a diagnostic. Failures
  /// are non-fatal — the stream keeps running and the next tick retries.
  private func sendKeepalive(method: RTSPMethod) async {
    guard isPlaying else { return }
    do {
      let resp = try await controlRequest(method: method, timeoutSeconds: 10)
      guard resp.statusCode >= 200 && resp.statusCode < 300 else {
        onDiagnostic?(
          RTSPDiagnostic(
            severity: .warning,
            message: "RTSP keepalive (\(method.rawValue)) failed: \(resp.statusCode) "
              + cutForMessage(resp.reasonPhrase)))
        return
      }
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

  /// The ONVIF `Require` header for requests that negotiate the requested
  /// features.
  private func requireHeaders(for method: RTSPMethod) -> [(String, String)] {
    guard let value = onvif.requireHeaderValue else { return [] }
    switch method {
    case .describe, .setup, .play, .pause:
      return [("Require", value)]
    default:
      return []
    }
  }

  private func sendRequest(
    method: RTSPMethod,
    url: String,
    extraHeaders: [(String, String)] = []
  ) async throws -> RTSPResponse {
    guard let conn = connection else {
      throw RTSPError.connectionFailed("Not connected")
    }
    let extraHeaders = requireHeaders(for: method) + extraHeaders

    var request = RTSPRequest(method: method, url: url)
    let requestCSeq = nextCSeq(for: method)
    request.setHeader("CSeq", value: "\(requestCSeq)")
    if method == .play { didSendPlay(cseq: requestCSeq) }

    if let userAgent = userAgent, !userAgent.isEmpty {
      request.setHeader("User-Agent", value: userAgent)
    }

    if let sid = sessionId {
      request.setHeader("Session", value: sid)
    }

    var sent = RTSPAuthenticator.Sent.none
    if authenticator?.hasChallenge == true {
      let sending = authenticator!.sending
      if let authHeader = authenticator!.authorizationHeader(method: method.rawValue, uri: url) {
        request.setHeader("Authorization", value: authHeader)
        sent = sending
      }
    }

    for (name, value) in extraHeaders {
      request.setHeader(name, value: value)
    }

    var resp = try await exchange(request, on: conn)

    // A 401 is answered with its challenge, and once more when that answer is
    // refused with `stale=true` and a new nonce (the nonce, not the password,
    // was refused). A Digest refused otherwise isn't sent again; a server that also offers
    // Basic, on any of the 401s, gets Basic once unless Basic was already
    // refused for this request.
    var retries = 0
    var basicRefused = false
    var basicOffered = false
    while resp.statusCode == 401 {
      guard var auth = authenticator else { throw RTSPError.authenticationFailed }
      if sent == .basic { basicRefused = true }
      // Every challenge of the response at once (a server may offer Basic
      // and Digest on separate WWW-Authenticate lines), so Digest wins
      // regardless of ordering.
      auth.handleChallenges(resp.headerValues(named: "WWW-Authenticate"))
      authenticator = auth
      basicOffered = basicOffered || auth.latestChallengesOfferBasic
      if auth.retries(afterRejecting: sent),
        retries == 0 || (retries == 1 && auth.digestIsStale && auth.sending != sent)
      {
        retries += 1
        // Rebuild the retry the same way the first attempt did: a 401 on
        // SETUP/PLAY requires the Session (and User-Agent) headers preserved,
        // or the retry is rejected. Authorization is set last so a freshly
        // computed digest isn't clobbered by a caller-supplied extra header.
        var retryRequest = RTSPRequest(method: method, url: url)
        let retryCSeq = nextCSeq(for: method)
        retryRequest.setHeader("CSeq", value: "\(retryCSeq)")
        if method == .play { didSendPlay(cseq: retryCSeq) }
        if let userAgent = userAgent, !userAgent.isEmpty {
          retryRequest.setHeader("User-Agent", value: userAgent)
        }
        if let sid = sessionId {
          retryRequest.setHeader("Session", value: sid)
        }
        for (name, value) in extraHeaders {
          retryRequest.setHeader(name, value: value)
        }
        sent = .none
        let sending = auth.sending
        if let authHeader = auth.authorizationHeader(method: method.rawValue, uri: url) {
          retryRequest.setHeader("Authorization", value: authHeader)
          sent = sending
        }
        // Persist after authorize so the advanced nonce-count survives.
        authenticator = auth
        resp = try await exchange(retryRequest, on: conn)
        continue
      }
      if case .digest = sent, basicOffered, auth.usesDigest, !basicRefused,
        let basicResp = try await retryWithBasicFallback(
          auth: &auth, method: method, url: url, extraHeaders: extraHeaders)
      {
        authenticator = auth
        return basicResp
      }
      throw RTSPError.authenticationFailed
    }

    guard resp.statusCode >= 200 && resp.statusCode < 300 else {
      throw RTSPError.sessionSetupFailed(
        statusCode: Int(resp.statusCode),
        reason: cutForMessage(resp.reasonPhrase)
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
    let requestCSeq = nextCSeq(for: method)
    request.setHeader("CSeq", value: "\(requestCSeq)")
    if method == .play { didSendPlay(cseq: requestCSeq) }
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

    let resp = try await exchange(request, on: conn)
    if resp.statusCode == 401 {
      return nil
    }
    // Basic was accepted: keep it even when the request fails for another
    // reason (a 551 for a feature tag, say), so the next request doesn't send
    // the refused Digest again.
    authenticator = auth
    guard resp.statusCode >= 200 && resp.statusCode < 300 else {
      throw RTSPError.sessionSetupFailed(
        statusCode: Int(resp.statusCode), reason: cutForMessage(resp.reasonPhrase))
    }
    return resp
  }

  /// The next CSeq. A PLAY's skips values whose low byte one of the latest
  /// PLAYs used, once packets have carried the ONVIF replay extension: it
  /// tags packets with that byte alone, and packets of the playback still in
  /// flight must not pass for the new one's. RFC 2326 asks only that CSeqs
  /// increase.
  private func nextCSeq(for method: RTSPMethod? = nil) -> UInt32 {
    cseq += 1
    guard method == .play else { return cseq }
    if !replayTaggedStreams.isEmpty {
      while recentPlayCSeqLowBytes.contains(UInt8(truncatingIfNeeded: cseq)) { cseq += 1 }
    }
    recentPlayCSeqLowBytes.append(UInt8(truncatingIfNeeded: cseq))
    if recentPlayCSeqLowBytes.count > 4 { recentPlayCSeqLowBytes.removeFirst() }
    return cseq
  }

  /// How long a request sent before the reader runs (during `start()`) waits
  /// for its response.
  private var setupResponseTimeout: Duration = .seconds(15)
  /// Set when `exchange`'s deadline closed the connection.
  private var setupResponseTimedOut = false

  /// Send `request` and read its response directly from the connection (no
  /// reader yet). A server that accepts the connection but never answers
  /// would otherwise leave `start()` waiting forever: after
  /// `setupResponseTimeout` (15 s) the connection is closed and this throws
  /// `RTSPError.timeout`.
  private func exchange(
    _ request: RTSPRequest, on conn: RTSPTransportConnection
  ) async throws -> RTSPResponse {
    setupResponseTimedOut = false
    let timeout = setupResponseTimeout
    let deadline = Task {
      try await Task.sleep(for: timeout)
      // The response may have arrived while this task waited to run.
      guard !Task.isCancelled else { return }
      self.setupResponseTimedOut = true
      await conn.close()
    }
    defer { deadline.cancel() }
    do {
      let response = try await conn.sendRequest(request)
      // The deadline ran as the response arrived and is closing the
      // connection: the next request would fail with "Not connected".
      if setupResponseTimedOut { throw RTSPError.timeout }
      return response
    } catch {
      if setupResponseTimedOut { throw RTSPError.timeout }
      throw error
    }
  }

  /// SETUP one stream using the selected transport. Returns the parsed SETUP
  /// response; every path rolls the session id forward and, as a side effect,
  /// records where the stream's data will arrive (a TCP interleaved channel, a
  /// bound UDP socket pair in `udpPairs`, or a joined group in
  /// `multicastPairs`). `outboundSSRC` is the SSRC the client sends with (the
  /// backchannel), carried in the MIKEY offer for SRTP.
  private func setupStream(
    controlURL: String, streamIndex: Int, outboundSSRC: UInt32? = nil
  ) async throws -> SetupResponse {
    switch transport {
    case .tcp:
      return try await setupStreamTCP(controlURL: controlURL, streamIndex: streamIndex)
    case .udp:
      return try await setupStreamUDP(
        controlURL: controlURL, streamIndex: streamIndex, outboundSSRC: outboundSSRC)
    case .multicast:
      return try await setupStreamMulticast(controlURL: controlURL, streamIndex: streamIndex)
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
            + "(\(cutForMessage(prev)) -> \(cutForMessage(setup.session.id))); rolling forward."))
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
    interleavedChannels[streamIndex] = channel
    return setup
  }

  /// SETUP one stream over a UDP socket pair. Binds a local even/odd RTP/RTCP
  /// pair, advertises it via `client_port`, then connects the sockets to the
  /// server's `server_port` (RTCP = RTP + 1, enforced by `parseSetup`). The
  /// connected pair is recorded in `udpPairs`; on any failure its sockets are
  /// released before rethrowing. For RTSPS the profile is `RTP/SAVP` with a
  /// MIKEY key exchange (`KeyMgmt`).
  ///
  /// The local socket family (IPv4 / IPv6) is taken from the resolved control
  /// connection so it matches the server, and the RTP/RTCP peer is chosen from a
  /// candidate of the same family — IPv4 and IPv6 peers (including `[::1]`) both
  /// work.
  private func setupStreamUDP(
    controlURL: String, streamIndex: Int, outboundSSRC: UInt32?
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
      let profile = usesSRTP ? "RTP/SAVP" : "RTP/AVP"
      var headers = [
        ("Transport", "\(profile);unicast;client_port=\(pair.rtpPort)-\(pair.rtcpPort)")
      ]
      var offer: SRTPOffer?
      if usesSRTP {
        let made = try makeSRTPOffer(controlURL: controlURL, ssrc: outboundSSRC ?? reporterSSRC)
        headers.append(("KeyMgmt", made.keyMgmt))
        offer = made
      }
      let resp = try await sendRequest(
        method: .setup, url: controlURL, extraHeaders: headers)
      let setup = try parseSetup(response: resp)
      adoptSession(setup)

      guard let serverRTPPort = setup.serverPort else {
        throw RTSPError.sessionSetupFailed(
          statusCode: Int(resp.statusCode),
          reason: "UDP SETUP response omitted server_port")
      }
      guard serverRTPPort > 0 else {
        throw RTSPError.sessionSetupFailed(
          statusCode: Int(resp.statusCode), reason: "Invalid server_port 0")
      }
      if let offer {
        srtpInbound[streamIndex] = try serverSRTPContext(response: resp, streamIndex: streamIndex)
        srtpOutbound[streamIndex] = offer.outbound
      }
      // Choose the RTP/RTCP peer. Prefer the server-advertised `source`, then
      // the resolved control-connection peer, then the URL host — but only a
      // numeric literal matching the bound socket family, since this path does
      // not resolve hostnames. The control connection's resolved peer is always
      // a numeric literal of the right family, so it backstops a hostname URL
      // (or a `source` given as a name / wrong family).
      let matchesFamily = peerIsIPv6 ? UDPPair.isNumericIPv6 : UDPPair.isNumericIPv4
      let peerHost = linkLocalWithZone(
        [setup.source, resolved?.host, host]
          .compactMap { $0 }
          .first(where: matchesFamily) ?? resolved?.host ?? family.loopback,
        zoneFrom: [resolved?.host, host])
      try await pair.connect(peerHost: peerHost, peerRTPPort: serverRTPPort)
      try checkNotStopped()

      udpPairs[streamIndex] = pair
      return setup
    } catch {
      pair.close()
      throw error
    }
  }

  /// SETUP one stream as multicast (`RTP/AVP;multicast`, or `RTP/SAVP` for
  /// RTSPS) and join the group and port pair the server answers with
  /// (`destination`, `port`).
  private func setupStreamMulticast(
    controlURL: String, streamIndex: Int
  ) async throws -> SetupResponse {
    var headers = [("Transport", usesSRTP ? "RTP/SAVP;multicast" : "RTP/AVP;multicast")]
    var offer: SRTPOffer?
    if usesSRTP {
      let made = try makeSRTPOffer(controlURL: controlURL, ssrc: reporterSSRC)
      headers.append(("KeyMgmt", made.keyMgmt))
      offer = made
    }
    let resp = try await sendRequest(method: .setup, url: controlURL, extraHeaders: headers)
    let setup = try parseSetup(response: resp)
    adoptSession(setup)

    guard let group = setup.destination, let rtpPort = setup.multicastPort ?? setup.serverPort
    else {
      throw RTSPError.sessionSetupFailed(
        statusCode: Int(resp.statusCode),
        reason: "Multicast SETUP response omitted destination or port "
          + "(Transport: \(cutForMessage(resp.header("Transport") ?? "")))")
    }
    guard rtpPort > 0, rtpPort < UInt16.max else {
      throw RTSPError.sessionSetupFailed(
        statusCode: Int(resp.statusCode), reason: "Invalid multicast port \(rtpPort)")
    }
    if let offer {
      srtpInbound[streamIndex] = try serverSRTPContext(response: resp, streamIndex: streamIndex)
      srtpOutbound[streamIndex] = offer.outbound
    }
    // Join on the interface the control connection uses, the one facing the
    // server. Without it the kernel picks its multicast route's interface,
    // which may not be where the server's packets arrive.
    let local = await connection?.resolvedLocal()
    let pair = try await MulticastPair.join(
      group: group, rtpPort: rtpPort, rtcpPort: rtpPort + 1, source: setup.source,
      interface: local?.host)
    if stopRequested {
      pair.close()
      try checkNotStopped()
    }
    multicastPairs[streamIndex] = pair
    return setup
  }

  /// The client's half of an SRTP key exchange: a `KeyMgmt` header value
  /// carrying a MIKEY message with fresh keys, and the context those keys
  /// protect outgoing packets with.
  private struct SRTPOffer {
    let keyMgmt: String
    let outbound: SRTPContext
  }

  private func makeSRTPOffer(controlURL: String, ssrc: UInt32) throws -> SRTPOffer {
    let keys = SRTPKeyMaterial.random()
    let mikey = MIKEY.makeInitiatorMessage(
      cryptoSessions: [MIKEY.CryptoSession(policyNumber: 0, ssrc: ssrc, roc: 0)], keys: keys)
    return SRTPOffer(
      keyMgmt: KeyMgmtHeader.format(uri: controlURL, mikey: mikey),
      outbound: try SRTPContext(keys: keys, policy: .aesCM128HMACSHA1_80))
  }

  /// The SRTP context for the server's packets, keyed by its MIKEY message:
  /// the SETUP response's `KeyMgmt` header, else the SDP `a=key-mgmt`.
  private func serverSRTPContext(
    response: RTSPResponse, streamIndex: Int
  ) throws -> SRTPContext {
    let status = Int(response.statusCode)
    let mikey: Data
    if let header = response.header("KeyMgmt"), let parsed = KeyMgmtHeader.parse(header) {
      mikey = parsed.mikey
    } else if let attribute = presentation?.streams[streamIndex].keyMgmt,
      let data = KeyMgmtHeader.parseSDPAttribute(attribute)
    {
      mikey = data
    } else {
      throw RTSPError.sessionSetupFailed(
        statusCode: status,
        reason: "Server sent no SRTP keys (no KeyMgmt header or SDP a=key-mgmt)")
    }
    let context: SRTPContext
    do {
      context = try MIKEY.parse(mikey).makeContext()
    } catch {
      throw RTSPError.sessionSetupFailed(
        statusCode: status, reason: "Unusable SRTP key message from server: \(error)")
    }
    guard Self.isAcceptableServerSRTPPolicy(context.policy) else {
      throw RTSPError.sessionSetupFailed(
        statusCode: status,
        reason: "Server's SRTP policy is not AES-CM-128 with HMAC-SHA1 authentication")
    }
    // A reply profile other than RTP/SAVP is tolerated: packets that are not
    // valid SRTP fail authentication and are dropped. Say why up front.
    if let transport = response.header("Transport"), !Self.repliesWithSAVP(transport) {
      warnStreamOnce(
        "setup.profile.\(streamIndex)", .warning,
        "Server answered SETUP for stream \(streamIndex) with \(quotedForMessage(transport)) instead of "
          + "RTP/SAVP; packets that fail SRTP authentication will be dropped")
    }
    return context
  }

  /// Whether a SETUP reply's `Transport` header names the `RTP/SAVP` profile
  /// (with or without the `/UDP` lower transport).
  static func repliesWithSAVP(_ transport: String) -> Bool {
    let spec = transport.split(separator: ",", maxSplits: 1).first ?? ""
    let profile = spec.split(separator: ";", maxSplits: 1).first ?? ""
    let upper = profile.trimmingCharacters(in: .whitespaces).uppercased()
    return upper == "RTP/SAVP" || upper == "RTP/SAVP/UDP"
  }

  /// MIKEY lets the server choose NULL encryption, no authentication or a
  /// short authentication key; each would accept forged or readable media on
  /// a session that asked for TLS. Accepted: AES-CM-128 encryption with
  /// HMAC-SHA1 authentication of every packet under a 160-bit key (RFC 3711
  /// section 8.2), with an 80-bit or 32-bit tag.
  static func isAcceptableServerSRTPPolicy(_ policy: SRTPPolicy) -> Bool {
    policy.cipher == .aesCM128 && policy.auth == .hmacSHA1 && policy.authKeyLength == 20
      && policy.rtpEncryption && policy.rtpAuthentication
      && (policy.authTagLength == 10 || policy.authTagLength == 4)
  }

  /// The public frame, with `sps`/`pps`/`vps` set to the parameter sets the
  /// frame was depacketized with. `handOff` clears them unless they differ
  /// from the ones the consumer was last given.
  private func convertFrame(_ frame: VideoFrame, replay: ReplayInfo?) -> PublicVideoFrame {
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

    return PublicVideoFrame(
      nalus: nalus,
      timestamp: frame.timestamp.elapsedSeconds,
      isKeyframe: frame.isRandomAccessPoint,
      loss: frame.loss,
      sps: frame.parameterSets?.sps,
      pps: frame.parameterSets?.pps,
      vps: frame.parameterSets?.vps,
      replay: replay
    )
  }

  /// Prepare an item for the consumer. A video frame keeps `sps`/`pps`/`vps`
  /// only when they differ from the last parameter sets the consumer was
  /// given (initially the description's). Comparing here, rather than in the
  /// depacketizer, keeps the notice when the frame that carried a change was
  /// dropped from the queue, and after a seek reset the depacketizer to the
  /// SDP's parameter sets.
  private func handOff(_ item: PublicCodecItem) -> PublicCodecItem {
    switch item {
    case .video(let frame):
      var keepParameterSets = true
      if let sps = frame.sps, let pps = frame.pps {
        let sets = VideoParameterSetNALs(sps: sps, pps: pps, vps: frame.vps)
        keepParameterSets = sets != reportedVideoParameters
        reportedVideoParameters = sets
      }
      let extra = droppedVideoFrames
      droppedVideoFrames = 0
      guard extra > 0 || !keepParameterSets else { return item }
      return .video(
        PublicVideoFrame(
          nalus: frame.nalus, timestamp: frame.timestamp, isKeyframe: frame.isKeyframe,
          loss: Self.addingLoss(frame.loss, extra),
          sps: keepParameterSets ? frame.sps : nil, pps: keepParameterSets ? frame.pps : nil,
          vps: keepParameterSets ? frame.vps : nil, replay: frame.replay))
    case .audio(let frame):
      let extra = droppedAudioFrames
      droppedAudioFrames = 0
      guard extra > 0 else { return item }
      return .audio(
        PublicAudioFrame(
          data: frame.data, timestamp: frame.timestamp, codec: frame.codec,
          sampleRate: frame.sampleRate, channels: frame.channels,
          loss: Self.addingLoss(frame.loss, extra), replay: frame.replay))
    case .metadata(let frame):
      let extra = droppedMetadataFrames
      droppedMetadataFrames = 0
      guard extra > 0 else { return item }
      return .metadata(
        PublicMetadataFrame(
          data: frame.data, timestamp: frame.timestamp, encodingName: frame.encodingName,
          loss: Self.addingLoss(frame.loss, extra), xml: frame.xml, replay: frame.replay))
    case .rtcp:
      return item
    }
  }

  /// Count a frame that won't reach the consumer.
  private func noteDropped(_ item: PublicCodecItem) {
    switch item {
    case .video: droppedVideoFrames += 1
    case .audio: droppedAudioFrames += 1
    case .metadata: droppedMetadataFrames += 1
    case .rtcp: break
    }
  }

  private static func addingLoss(_ loss: UInt16, _ extra: Int) -> UInt16 {
    UInt16(clamping: Int(loss) + extra)
  }

  /// Whether an H.264/H.265 fmtp carries parameter sets (`sprop-parameter-sets`,
  /// `sprop-vps`, `sprop-sps`, `sprop-pps`), as opposed to other `sprop-`
  /// parameters such as `sprop-max-don-diff`.
  static func advertisesParameterSets(_ fmtp: String) -> Bool {
    fmtp.lazySplit(separator: ";").contains { parameter in
      let key = parameter.split(separator: "=", maxSplits: 1).first?
        .trimmingCharacters(in: .whitespaces).lowercased()
      return ["sprop-parameter-sets", "sprop-vps", "sprop-sps", "sprop-pps"].contains(key ?? "")
    }
  }

  /// The sample rate reported for an audio stream: its RTP clock rate, except
  /// G.722, whose RTP clock rate is 8000 although it samples at 16 kHz
  /// (RFC 3551 section 4.5.2).
  static func audioSampleRate(encoding: String, clockRate: UInt32) -> UInt32 {
    encoding.lowercased() == "g722" ? 16000 : clockRate
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

// MARK: - Waiting that the caller can cancel

/// `task`'s value, or `CancellationError` as soon as the calling task is
/// cancelled, whichever comes first. A cancelled caller cancels `task` too
/// but doesn't wait for it to end.
func valueUnlessCancelled<T: Sendable>(of task: Task<T, any Error>) async throws -> T {
  let waiter = FirstResultWaiter<T>()
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      waiter.install(continuation)
      Task { waiter.resume(with: await task.result) }
    }
  } onCancel: {
    task.cancel()
    waiter.resume(with: .failure(CancellationError()))
  }
}

/// Resumes one continuation, once, with the first result offered, which is
/// kept when it comes before the continuation is installed. State is guarded
/// by `lock`, hence `@unchecked Sendable`.
private final class FirstResultWaiter<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, any Error>?
  private var result: Result<T, any Error>?

  func install(_ continuation: CheckedContinuation<T, any Error>) {
    lock.lock()
    guard let result else {
      self.continuation = continuation
      lock.unlock()
      return
    }
    lock.unlock()
    continuation.resume(with: result)
  }

  func resume(with offered: Result<T, any Error>) {
    lock.lock()
    guard result == nil else {
      lock.unlock()
      return
    }
    result = offered
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: offered)
  }
}

// MARK: - URL helpers (free functions, testable)

/// Where to open the RTSP control connection for a stream URL.
struct RTSPEndpoint: Equatable {
  /// Host for `NWEndpoint.Host`: an ASCII hostname (IDNA A-labels) or an
  /// unbracketed IP literal; see `asciiHost(of:)`.
  let host: String
  let port: UInt16
  /// True for `rtsps://`: the connection, and media interleaved on it, use TLS.
  let usesTLS: Bool
}

/// Parse the control-connection endpoint from an `rtsp://` or `rtsps://` URL.
/// The scheme is case-insensitive. Without an explicit port, `rtsp` uses 554
/// and `rtsps` uses 322, the ports IANA registers for each scheme (RFC 7826).
///
/// The URL goes into every request line, so spaces and control characters
/// (which would split the line or start a new header) are rejected.
///
/// Errors show `shownURL` (default `url`), redacted: `start()` passes the URL
/// as the caller wrote it, since cutting the fragment or percent-encoding a
/// `＠` can remove what `redactedURL` finds the end of a password by.
func rtspEndpoint(for url: String, shownAs shownURL: String? = nil) throws -> RTSPEndpoint {
  let shown = redactedURL(shownURL ?? url)
  guard !url.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F }) else {
    throw RTSPError.invalidURL(
      "Invalid URL (contains a space or control character): \(shown)")
  }
  guard let components = URLComponents(string: percentEncodingForParsing(url)) else {
    throw RTSPError.invalidURL("Invalid URL: \(shown)")
  }
  let scheme = components.scheme?.lowercased()
  guard scheme == "rtsp" || scheme == "rtsps" else {
    throw RTSPError.invalidURL("Invalid URL (expected rtsp:// or rtsps://): \(shown)")
  }
  let usesTLS = scheme == "rtsps"
  guard let host = asciiHost(of: components) else {
    throw RTSPError.invalidURL("Invalid URL (no host): \(shown)")
  }
  // A port too large for `Int` reads as no port, which would mean the
  // default one; an empty port (`host:`, `[::1]:`) does mean it.
  guard components.port != nil || components.rangeOfPort?.isEmpty != false else {
    throw RTSPError.invalidURL("Invalid port in URL: \(shown)")
  }
  let rawPort = components.port ?? (usesTLS ? 322 : 554)
  guard let port = UInt16(exactly: rawPort), port != 0 else {
    throw RTSPError.invalidURL("Invalid port \(rawPort) in URL: \(shown)")
  }
  return RTSPEndpoint(host: host, port: port, usesTLS: usesTLS)
}

/// Reject a URL containing a space or a control character: it would end the
/// RTSP request line early or let the rest be read as headers.
func checkURLCharacters(_ url: String) throws {
  guard !url.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F }) else {
    throw RTSPError.invalidURL(
      "Invalid URL (contains a space or control character): \(redactedURL(url))")
  }
}

/// Reject a URL whose user name or password `URLComponents` can't read
/// right because it has a raw `/`, `?`, `#` or `@`: the host then ends early or
/// at the wrong `@`, and the URL names another host
/// (`rtsp://admin:12345/abc@cam/` reads as host `admin`, port 12345;
/// `rtsp://admin:p@ss/1@cam/` as host `ss`; `rtsp://corp/alice:pw@cam/` as
/// host `corp`), which would get the password on the request line. Such a URL
/// has an `@` after its host, and is rejected when it also has userinfo, a
/// port on a host name (how a user name and a password's start read), or any
/// `:` between the host and the last `@` (a user name's rest and its password,
/// whatever raw characters they hold). An IPv4 address with a port, like a
/// bracketed IPv6 one, isn't taken for a user name: ONVIF cameras report
/// stream URIs such as `rtsp://192.0.2.5:554/live?password=Adm1n@2024`. In a
/// rejected URL a path or query `@` has to be written `%40`; a user name with
/// a raw `/`, `?` or `#` and no password can't be told from a path and isn't
/// caught.
func checkAmbiguousUserInfo(_ url: String) throws {
  // Unicode scalars, not Characters: URLComponents splits at an `@`, `/`, `?`,
  // `#` or `:` that a combining mark follows, which makes the pair one
  // Character.
  guard let schemeEnd = url.utf8.firstRange(of: "://".utf8) else { return }
  let rest = url.unicodeScalars[schemeEnd.upperBound...]
  guard let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }),
    let at = rest[authorityEnd...].lastIndex(of: "@")
  else { return }
  let authority = rest[..<authorityEnd]
  guard
    authority.contains("@")
      || (authority.first != "[" && authority.contains(":")
        && !isIPv4AddressWithPort(authority))
      || rest[authorityEnd..<at].contains(":")
  else { return }
  throw RTSPError.invalidURL(
    "Invalid URL (an @ after the host that may end a user name or password; write /, ?, # and "
      + "@ in a user name or password as %2F, %3F, %23 and %40, and an @ in the path as %40): "
      + "\(redactedURL(url))")
}

/// Whether `authority` is an IPv4 address in dotted-decimal form (four
/// numbers up to 255), a `:` and a port of one to five digits.
private func isIPv4AddressWithPort(_ authority: Substring.UnicodeScalarView) -> Bool {
  func isDigits(_ part: Substring.UnicodeScalarView, count: ClosedRange<Int>) -> Bool {
    count.contains(part.count) && part.allSatisfy { ("0"..."9").contains($0) }
  }
  let hostAndPort = authority.split(separator: ":", omittingEmptySubsequences: false)
  guard hostAndPort.count == 2, isDigits(hostAndPort[1], count: 1...5) else { return false }
  let octets = hostAndPort[0].split(separator: ".", omittingEmptySubsequences: false)
  return octets.count == 4
    && octets.allSatisfy { octet in
      isDigits(octet, count: 1...3) && octet.reduce(0) { $0 * 10 + Int($1.value - 48) } <= 255
    }
}

/// Where `URLComponents` finds the parts of a URL string, as offsets into its
/// Unicode scalars. After the scheme and `//`, the authority runs to the
/// first `/`, `?` or `#`; its user name and password run to its last `@`,
/// and the user name to their first `:`. The path runs to the first `?` or
/// `#`, the query to the first `#` after it, and the fragment to the end.
/// Scalars, not Characters, as `URLComponents` reads the URL: a delimiter
/// that a combining mark follows still delimits.
struct URLLayout {
  let scalars: [Unicode.Scalar]
  /// The scheme and its `:`; empty when the URL doesn't start with one.
  let scheme: Range<Int>
  /// The authority, after its `//`; nil without `//`.
  let authority: Range<Int>?
  /// The user name and password, without the `@` after them; nil without an
  /// `@` in the authority.
  let userInfo: Range<Int>?
  /// The `:` between the user name and the password.
  let passwordColon: Int?
  /// The host, without the port; nil without an authority.
  let host: Range<Int>?
  /// The fragment, after its `#`; nil without a `#`.
  let fragment: Range<Int>?

  init(_ url: String) {
    let scalars = Array(url.unicodeScalars)
    self.scalars = scalars
    func isLetter(_ c: Unicode.Scalar) -> Bool {
      ("a"..."z").contains(c) || ("A"..."Z").contains(c)
    }
    // A scheme is a letter, then letters, digits, `+`, `-` or `.` (RFC 3986).
    var index = 0
    if let colon = scalars.firstIndex(of: ":"), colon > 0, isLetter(scalars[0]),
      scalars[..<colon].allSatisfy({
        isLetter($0) || ("0"..."9").contains($0) || "+-.".unicodeScalars.contains($0)
      })
    {
      index = colon + 1
    }
    scheme = 0..<index
    if scalars[index...].starts(with: "//".unicodeScalars) {
      let start = index + 2
      let end =
        scalars[start...].firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
        ?? scalars.count
      authority = start..<end
      var hostStart = start
      if let at = scalars[start..<end].lastIndex(of: "@") {
        userInfo = start..<at
        passwordColon = scalars[start..<at].firstIndex(of: ":")
        hostStart = at + 1
      } else {
        userInfo = nil
        passwordColon = nil
      }
      var hostEnd = end
      if hostStart < end, scalars[hostStart] == "[" {
        if let close = scalars[hostStart..<end].firstIndex(of: "]") { hostEnd = close + 1 }
      } else if let colon = scalars[hostStart..<end].firstIndex(of: ":") {
        hostEnd = colon
      }
      host = hostStart..<hostEnd
      index = end
    } else {
      authority = nil
      userInfo = nil
      passwordColon = nil
      host = nil
    }
    fragment = scalars[index...].firstIndex(of: "#").map { ($0 + 1)..<scalars.count }
  }

  /// The URL with `range` replaced by `replacement`.
  func replacing(_ range: Range<Int>, with replacement: String) -> String {
    var result = scalars
    result.replaceSubrange(range, with: replacement.unicodeScalars)
    return String(String.UnicodeScalarView(result))
  }
}

/// `url` with every character percent-encoded that `URLComponents(string:)`
/// would encode itself, so that it parses the result without changing it.
/// When `URLComponents` has to encode a character in a component, it encodes
/// the `%` of every escape already in that component too, and the escapes
/// then decode to themselves (`£ecret|1` read as `%C2%A3ecret|1`). These are
/// encoded: non-ASCII characters (as their UTF-8 bytes), spaces and control
/// characters, `"` `<` `>` `[` `\` `]` `^` `` ` `` `{` `|` `}`, a `%` that
/// two hex digits don't follow, in the user name and password every `@` but
/// the one ending them and every `:` but the one between them, and in the
/// fragment every `#`. The scheme, host and port stay as written, apart from
/// non-ASCII characters, so a zone id (`[fe80::1%en0]`) keeps working.
func percentEncodingForParsing(_ url: String) -> String {
  let layout = URLLayout(url)
  let scalars = layout.scalars
  let hostAndPort = layout.host.flatMap { host in
    layout.authority.map { host.lowerBound..<$0.upperBound }
  }
  func isHexDigit(_ offset: Int) -> Bool {
    offset < scalars.count && scalars[offset].properties.isASCIIHexDigit
  }
  func mustEncode(_ offset: Int) -> Bool {
    let scalar = scalars[offset]
    if !scalar.isASCII || scalar.value <= 0x20 || scalar.value == 0x7F { return true }
    if layout.scheme.contains(offset) || hostAndPort?.contains(offset) == true { return false }
    if "\"<>[\\]^`{|}".unicodeScalars.contains(scalar) { return true }
    if scalar == "%" { return !(isHexDigit(offset + 1) && isHexDigit(offset + 2)) }
    if layout.userInfo?.contains(offset) == true {
      return scalar == "@" || (scalar == ":" && offset != layout.passwordColon)
    }
    return scalar == "#" && layout.fragment?.contains(offset) == true
  }
  guard scalars.indices.contains(where: mustEncode) else { return url }
  var encoded = String.UnicodeScalarView()
  for offset in scalars.indices {
    guard mustEncode(offset) else {
      encoded.append(scalars[offset])
      continue
    }
    for byte in String(scalars[offset]).utf8 {
      encoded.append(contentsOf: String(format: "%%%02X", byte).unicodeScalars)
    }
  }
  return String(encoded)
}

/// `url` without its `user:password@`, everything else as written. The
/// userinfo is what `URLComponents` takes for it: up to the authority's last
/// `@`.
func removingUserInfo(_ url: String) -> String {
  let layout = URLLayout(url)
  guard let userInfo = layout.userInfo else { return url }
  // The `@` after the userinfo goes too.
  return layout.replacing(userInfo.lowerBound..<(userInfo.upperBound + 1), with: "")
}

/// The percent-decoded credentials in `url`'s `user:password@` (an absent
/// password is empty); nil when the URL has no userinfo or `URLComponents`
/// can't parse it. Throws when the user name or password doesn't decode to
/// UTF-8 (`%FF`), rather than authenticating with an empty one.
func credentialsInUserInfo(_ url: String) throws -> Credentials? {
  guard URLLayout(url).userInfo != nil,
    let components = URLComponents(string: percentEncodingForParsing(url)),
    components.percentEncodedUser != nil || components.percentEncodedPassword != nil
  else { return nil }
  // Decoded here rather than read from `user` and `password`, which drop a
  // leading U+FEFF.
  func decoded(_ part: String?) throws -> String {
    guard let part else { return "" }
    guard let text = part.removingPercentEncoding else {
      throw RTSPError.invalidURL(
        "Invalid URL (the user name or password isn't percent-encoded UTF-8): \(redactedURL(url))")
    }
    return text
  }
  return Credentials(
    username: try decoded(components.percentEncodedUser),
    password: try decoded(components.percentEncodedPassword))
}

/// Split `user:password@` out of a URL: `removingUserInfo(url)` and
/// `credentialsInUserInfo(url)`.
func splitUserInfo(_ url: String) throws -> (url: String, credentials: Credentials?) {
  (removingUserInfo(url), try credentialsInUserInfo(url))
}

/// `url` as an ASCII URI, for the request line: a Unicode or
/// percent-encoded host name in IDNA (`xn--`) form, and non-ASCII characters
/// elsewhere percent-encoded. Everything else is kept as written, escapes and
/// characters a URI can't hold raw (`{`, `|`) included, so the URL names the
/// same resource whatever its host.
func asciiURL(_ url: String) -> String {
  let encoded = percentEncodingNonASCII(url)
  let layout = URLLayout(url)
  guard let hostRange = layout.host,
    let components = URLComponents(string: percentEncodingForParsing(url))
  else { return encoded }
  // A host written percent-encoded (`caf%C3%A9.example`), or in Unicode,
  // goes as the name connected to (`xn--caf-dma.example`).
  let encodedHost = components.encodedHost ?? ""
  guard !encodedHost.hasPrefix("["), encodedHost.contains("%"),
    let host = asciiHost(of: components)
  else { return encoded }
  return percentEncodingNonASCII(layout.replacing(hostRange, with: host))
}

/// `url` with every non-ASCII scalar written as the percent-encoded bytes of
/// its UTF-8, and nothing else changed.
func percentEncodingNonASCII(_ url: String) -> String {
  guard !url.unicodeScalars.allSatisfy(\.isASCII) else { return url }
  var encoded = ""
  for scalar in url.unicodeScalars {
    if scalar.isASCII {
      encoded.unicodeScalars.append(scalar)
    } else {
      for byte in String(scalar).utf8 { encoded += String(format: "%%%02X", byte) }
    }
  }
  return encoded
}

/// `url` without its `#fragment`, which isn't part of a request URI
/// (RFC 3986 section 3.5). Called once the userinfo is gone, so the first `#`
/// starts the fragment.
func withoutFragment(_ url: String) -> String {
  // A `#` that a combining mark follows still starts the fragment.
  guard let hash = url.unicodeScalars.firstIndex(of: "#") else { return url }
  return String(url.unicodeScalars[..<hash])
}

/// `url` with its userinfo replaced by `***`, for error messages: everything
/// between the scheme's `:` (and the `//` right after it, if any) and the last
/// `@`. A password may contain a raw `/`, `?`, `#`, `@` or `://`, so the
/// userinfo can't be found by cutting at any of them; when the URL is
/// ambiguous (an `@` in the path or query), more is redacted rather than less.
/// A fullwidth `＠` or small `﹫` (typed through an input method) counts as
/// `@`, so the password before it isn't shown either. The URL is read as
/// Unicode scalars: an `@` that a combining mark follows still counts.
/// Credential-like parameters are hidden too (`redactingCredentialParameters`).
func redactedURL(_ url: String) -> String {
  redactingCredentialParameters(redactingUserInfo(url))
}

/// `url` with its userinfo replaced by `***` (see `redactedURL`).
private func redactingUserInfo(_ url: String) -> String {
  let scalars = url.unicodeScalars
  var afterScheme = scalars.startIndex
  // A scheme is a letter, then letters, digits, `+`, `-` or `.` (RFC 3986).
  func isLetter(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("A"..."Z").contains(c) }
  if let colon = scalars.firstIndex(of: ":"), let first = scalars.first, isLetter(first),
    scalars[..<colon].allSatisfy({
      isLetter($0) || ("0"..."9").contains($0) || "+-.".unicodeScalars.contains($0)
    })
  {
    afterScheme = scalars.index(after: colon)
    if scalars[afterScheme...].starts(with: "//".unicodeScalars) {
      afterScheme = scalars.index(afterScheme, offsetBy: 2)
    }
  }
  guard
    let at = scalars[afterScheme...].lastIndex(where: {
      $0 == "@" || $0 == "\u{FF20}" || $0 == "\u{FE6B}"
    })
  else { return url }
  return String(scalars[..<afterScheme]) + "***" + String(scalars[at...])
}

/// Whether URL parameter name `raw` looks like it holds a credential: after
/// percent-decoding and in any case, it contains user, pass, pwd, auth, token
/// or secret, or is one of the CGI names usr, pw, psw, loginuse and loginpas.
func isCredentialParameterName(_ raw: some StringProtocol) -> Bool {
  let name = (raw.removingPercentEncoding ?? String(raw)).lowercased()
  return ["user", "pass", "pwd", "auth", "token", "secret"].contains { name.contains($0) }
    || ["usr", "pw", "psw", "loginuse", "loginpas"].contains(name)
}

/// `url` with the values of credential-like parameters
/// (`isCredentialParameterName`) replaced by `***`: some cameras take the
/// user name and password in the query (`?user=admin&password=…`), or in a
/// path segment (Xiongmai's `/user=admin_password=…_channel=1…`). A
/// parameter after `?`, `&` or `;` is hidden after its `=` up to the next
/// `&` or `#` (a `;` may be part of a password); one that starts a path
/// segment, up to the next `/`, `?` or `#`. The URL is taken as a whole, so
/// a name or value may hold a space. Read as Unicode scalars, so a separator
/// that a combining mark follows still separates.
func redactingCredentialParameters(_ url: String) -> String {
  let scalars = Array(url.unicodeScalars)
  // An array, appended to in place: appending slices to a
  // `String.UnicodeScalarView` isn't amortized, which made many hidden
  // parameters take quadratic time.
  var result: [Unicode.Scalar] = []
  result.reserveCapacity(scalars.count)
  var index = 0
  while index < scalars.count {
    let separator = scalars[index]
    result.append(separator)
    index += 1
    let inQuery = separator == "?" || separator == "&" || separator == ";"
    guard inQuery || separator == "/" else { continue }
    // The name runs to `=`; another separator first means none (that
    // separator starts its own name), so each scalar is scanned once.
    let nameStops: Set<Unicode.Scalar> = ["=", "?", "&", ";", "#", "/"]
    var equals = index
    while equals < scalars.count, !nameStops.contains(scalars[equals]) { equals += 1 }
    guard equals < scalars.count, scalars[equals] == "=",
      isCredentialParameterName(String(String.UnicodeScalarView(scalars[index..<equals])))
    else { continue }
    result.append(contentsOf: scalars[index...equals])
    result.append(contentsOf: "***".unicodeScalars)
    let valueStops: Set<Unicode.Scalar> = inQuery ? ["&", "#"] : ["/", "?", "#"]
    index = equals + 1
    while index < scalars.count, !valueStops.contains(scalars[index]) { index += 1 }
  }
  return String(String.UnicodeScalarView(result))
}

/// `peer` with a zone id added when it is a link-local IPv6 address
/// (`fe80::/10`) without one, taken from the first of `candidates` that has a
/// zone. A camera's SETUP `source` can't name the client's interface, and a
/// link-local address without a zone can't be reached.
func linkLocalWithZone(_ peer: String, zoneFrom candidates: [String?]) -> String {
  guard !peer.contains("%"), let address = IPv6Address(peer), address.isLinkLocal else {
    return peer
  }
  for case let candidate? in candidates {
    guard let percent = candidate.firstIndex(of: "%"), IPv6Address(candidate) != nil else {
      continue
    }
    return peer + candidate[percent...]
  }
  return peer
}

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
/// advertising this SDP `a=rtpmap` encoding name: ONVIF metadata as plain XML,
/// gzip-compressed XML, or EXI (delivered undecoded).
func isApplicationEncodingSupported(_ name: String) -> Bool {
  switch name {
  case "vnd.onvif.metadata", "vnd.onvif.metadata.gzip", "vnd.onvif.metadata.exi.onvif",
    "vnd.onvif.metadata.exi.ext":
    return true
  default:
    return false
  }
}
