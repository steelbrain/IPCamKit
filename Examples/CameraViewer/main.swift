// CameraViewer — example app for the IPCamKit RTSP client library.
// Displays a live RTSP camera feed using VideoToolbox decoding.
// Supports ONVIF discovery: pass an http:// device service URL to
// auto-discover RTSP stream URLs.
//
// Usage:
//   swift run -c release CameraViewer <url> [username] [password] [options]
//   (run without arguments for the list of options)
//
// Examples:
//   swift run -c release CameraViewer rtsp://192.168.1.158:554/stream1 admin pass
//   swift run -c release CameraViewer http://192.168.1.158:2020/onvif/device_service admin pass
//   swift run -c release CameraViewer rtsps://192.168.1.1:7441/abcdef --tls-sha256 <fingerprint>
//   swift run -c release CameraViewer rtsp://192.168.1.158/stream1 admin pass --transport udp
//   swift run -c release CameraViewer rtsp://192.168.1.158/stream1 admin pass --talk

@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import CryptoKit
import IPCamKit

// MARK: - Sendable wrapper for AVSampleBufferDisplayLayer

final class DisplayLayerRef: @unchecked Sendable {
  let layer: AVSampleBufferDisplayLayer
  init(_ layer: AVSampleBufferDisplayLayer) { self.layer = layer }

  /// Enqueue `sample` for display. The layer's rendering API (`status`,
  /// `flush()`, `enqueue(_:)`) is main-actor isolated in the macOS 27 SDK, and
  /// the streaming loop runs off the main actor, so this hops there. Awaiting
  /// each hop keeps frames in decode order.
  func enqueue(_ sample: CMSampleBuffer) async {
    // CMSampleBuffer is non-Sendable (CM_SWIFT_NONSENDABLE). The caller hands
    // the buffer over and never touches it again, so boxing it is safe.
    let handoff = SampleBufferRef(sample)
    await MainActor.run {
      if layer.status == .failed { layer.flush() }
      layer.enqueue(handoff.sample)
    }
  }
}

/// Carries a sample buffer to the main actor; see `DisplayLayerRef.enqueue`.
final class SampleBufferRef: @unchecked Sendable {
  let sample: CMSampleBuffer
  init(_ sample: CMSampleBuffer) { self.sample = sample }
}

// MARK: - Audio Playback

final class AudioPlayer: @unchecked Sendable {
  /// At most this much audio is scheduled ahead of what is playing. Audio
  /// that arrives faster than it plays (in a burst after a stall, or in a
  /// replay faster than 1×) is dropped while this much is queued, so it adds
  /// no lasting latency and holds no memory.
  static let maxQueuedSeconds = 0.5

  /// Guards the properties below: the stream task enqueues, the player node
  /// reports consumed buffers on its own thread, and the main thread may stop
  /// the player at quit. Never held while calling the engine or the node: a
  /// node that stops runs the completion handlers, which take it.
  private let lock = NSLock()
  private var engine: AVAudioEngine?
  private var playerNode: AVAudioPlayerNode?
  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?
  /// Output frames scheduled on `playerNode` and not yet consumed.
  private var queuedFrames: AVAudioFrameCount = 0
  /// Changes whenever `queuedFrames` restarts from zero (the node was
  /// flushed), so buffers scheduled before then aren't counted off it.
  private var generation = 0
  private var loggedDropping = false
  /// Starts, stops and restarts the engine one at a time, without `lock`.
  private let engineQueue = DispatchQueue(label: "CameraViewer.AudioPlayer")
  /// Used on `engineQueue` only.
  private var configurationObserver: (any NSObjectProtocol)?

  func start(codec: PublicAudioCodec, sampleRate: Double, channels: UInt32) {
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = sampleRate
    asbd.mChannelsPerFrame = channels
    asbd.mFramesPerPacket = 1

    switch codec {
    case .pcma:
      asbd.mFormatID = kAudioFormatALaw
      asbd.mBitsPerChannel = 8
      asbd.mBytesPerFrame = channels
      asbd.mBytesPerPacket = channels
    case .pcmu:
      asbd.mFormatID = kAudioFormatULaw
      asbd.mBitsPerChannel = 8
      asbd.mBytesPerFrame = channels
      asbd.mBytesPerPacket = channels
    case .l16:
      asbd.mFormatID = kAudioFormatLinearPCM
      asbd.mFormatFlags =
        kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian
        | kAudioFormatFlagIsPacked
      asbd.mBitsPerChannel = 16
      asbd.mBytesPerFrame = channels * 2
      asbd.mBytesPerPacket = channels * 2
    default:
      log("AudioPlayer: unsupported codec \(codec)")
      return
    }

    guard let inFmt = AVAudioFormat(streamDescription: &asbd) else {
      log("AudioPlayer: failed to create input format")
      return
    }
    guard
      let outFmt = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: channels, interleaved: false)
    else {
      log("AudioPlayer: failed to create output format")
      return
    }
    guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
      log("AudioPlayer: failed to create converter")
      return
    }

    let eng = AVAudioEngine()
    let node = AVAudioPlayerNode()
    eng.attach(node)
    eng.connect(node, to: eng.mainMixerNode, format: outFmt)

    let started = engineQueue.sync {
      do {
        try eng.start()
      } catch {
        log("AudioPlayer: engine start failed: \(error)")
        return false
      }
      node.play()

      lock.withLock {
        self.engine = eng
        self.playerNode = node
        self.converter = conv
        self.inputFormat = inFmt
        queuedFrames = 0
        generation += 1
        loggedDropping = false
      }
      // Another output device, or a new sample rate, stops the engine. The
      // notification comes on an engine queue, which must not tear the
      // engine down, so the restart runs on ours.
      let id = ObjectIdentifier(eng)
      configurationObserver = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: eng, queue: nil
      ) { [weak self] _ in
        guard let self else { return }
        engineQueue.async { self.restart(id) }
      }
      return true
    }
    if started {
      log("AudioPlayer: started (\(codec), \(Int(sampleRate)) Hz, \(channels) ch)")
    }
  }

  /// Restart playback on the engine `id` names, if it is still the current
  /// one, after a configuration change stopped it. The output node converts
  /// the sample rate, so the connections stay. What was queued is dropped.
  /// Runs on `engineQueue`.
  private func restart(_ id: ObjectIdentifier) {
    let (engine, node) = lock.withLock { () -> (AVAudioEngine?, AVAudioPlayerNode?) in
      guard let engine = self.engine, ObjectIdentifier(engine) == id else { return (nil, nil) }
      queuedFrames = 0
      generation += 1
      return (engine, self.playerNode)
    }
    guard let engine, let node else { return }
    node.stop()
    do {
      try engine.start()
    } catch {
      log("AudioPlayer: restart after an audio configuration change failed: \(error)")
      stopEngine()
      return
    }
    node.play()
    log("AudioPlayer: the audio configuration changed; playback restarted")
  }

  func enqueue(_ frame: PublicAudioFrame) {
    let (converter, inputFormat, playerNode) = lock.withLock {
      (self.converter, self.inputFormat, self.playerNode)
    }
    guard let converter, let inputFormat, let playerNode else { return }
    let data = frame.data
    let frameCount = UInt32(data.count) / inputFormat.streamDescription.pointee.mBytesPerFrame
    guard frameCount > 0 else { return }

    guard let inBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
      return
    }
    inBuf.frameLength = frameCount
    // Copy whole frames only: a payload whose length isn't a multiple of the
    // frame size (e.g. 6 bytes of 2-channel L16) would overrun the buffer.
    let byteCount = Int(frameCount) * Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
    _ = data.withUnsafeBytes { raw in
      memcpy(inBuf.audioBufferList.pointee.mBuffers.mData, raw.baseAddress, byteCount)
    }

    guard
      let outBuf = AVAudioPCMBuffer(
        pcmFormat: converter.outputFormat, frameCapacity: frameCount)
    else { return }

    var error: NSError?
    nonisolated(unsafe) var consumed = false
    converter.convert(to: outBuf, error: &error) { _, status in
      if consumed {
        status.pointee = .noDataNow
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return inBuf
    }
    if let error {
      log("AudioPlayer: convert error: \(error)")
      return
    }
    let frames = outBuf.frameLength
    guard frames > 0 else { return }
    let limit = AVAudioFrameCount(Self.maxQueuedSeconds * converter.outputFormat.sampleRate)
    let (generation, logDrop) = lock.withLock { () -> (Int?, Bool) in
      // Stopped meanwhile.
      guard self.playerNode === playerNode else { return (nil, false) }
      guard queuedFrames < limit else {
        defer { loggedDropping = true }
        return (nil, !loggedDropping)
      }
      queuedFrames += frames
      return (self.generation, false)
    }
    if logDrop {
      log(
        "AudioPlayer: audio is arriving faster than it plays; dropping it while "
          + "\(Self.maxQueuedSeconds) s is queued (logged once)")
    }
    guard let generation else { return }
    playerNode.scheduleBuffer(outBuf, completionCallbackType: .dataConsumed) { [self] _ in
      lock.withLock {
        if self.generation == generation { queuedFrames -= min(queuedFrames, frames) }
      }
    }
  }

  func stop() {
    engineQueue.sync { stopEngine() }
  }

  /// Runs on `engineQueue`.
  private func stopEngine() {
    let (playerNode, engine) = lock.withLock {
      defer {
        self.playerNode = nil
        self.engine = nil
        self.converter = nil
        self.inputFormat = nil
        queuedFrames = 0
        generation += 1
      }
      return (self.playerNode, self.engine)
    }
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
      self.configurationObserver = nil
    }
    playerNode?.stop()
    engine?.stop()
  }
}

// MARK: - Options

/// Command-line options that shape the RTSP session.
struct ViewerOptions: Sendable {
  var url = ""
  var username: String?
  var password: String?
  var tls = TLSOptions.default
  var transport = Transport.tcp
  var tunnel: RTSPTunnel?
  /// Start of an ONVIF replay (`Range: clock=`), or nil for live video.
  var replayFrom: Date?
  var scale: Double?
  /// Set up the ONVIF backchannel and send the microphone while Space is held.
  var talk = false

  var onvif: ONVIFFeatures {
    var features: ONVIFFeatures = []
    if replayFrom != nil { features.insert(.replay) }
    if talk { features.insert(.backchannel) }
    return features
  }

  var play: PlayOptions {
    PlayOptions(range: replayFrom.map { .clock(start: $0) }, scale: scale)
  }
}

// MARK: - Two-way audio

/// Part of a microphone buffer to send, from `TalkWindows.slices`.
struct TalkSlice: Equatable {
  /// The buffer's frames captured while Space was held; may be empty.
  var frames: Range<Int>
  /// These are the first frames of a press, so they start a talkspurt.
  var startsTalkspurt: Bool
  /// The press ended in this buffer or before it: nothing after `frames`
  /// belongs to it, and the converter is flushed.
  var endsTalkspurt: Bool
}

/// The Space presses, as host-clock times in seconds, and which frames of each
/// microphone buffer were captured during one.
///
/// The microphone tap delivers buffers of about 100 ms, each some time after
/// its frames were captured, so a press or release usually falls inside a
/// buffer, and the buffers holding a press's last frames arrive after the
/// release. A press is therefore kept until a buffer that ends at or after
/// its release has been processed.
struct TalkWindows {
  private struct Press {
    var start: Double
    /// Nil while Space is held.
    var end: Double?
    var started = false
  }
  private var presses: [Press] = []

  var isPressed: Bool { presses.last.map { $0.end == nil } ?? false }

  mutating func press(at time: Double) {
    if !isPressed { presses.append(Press(start: time)) }
  }

  mutating func release(at time: Double) {
    if isPressed { presses[presses.count - 1].end = time }
  }

  /// The parts of a buffer of `frameCount` frames at `sampleRate` whose first
  /// frame was captured at `bufferStart`: one slice for each press that
  /// overlaps the buffer or ended before the buffer's end, in order. The frame
  /// captured at time `t` has index `(t - bufferStart) * sampleRate`, rounded;
  /// a press covers the frames from its start up to, not including, its end.
  /// Presses that ended are forgotten.
  mutating func slices(bufferStart: Double, frameCount: Int, sampleRate: Double) -> [TalkSlice] {
    let bufferEnd = bufferStart + Double(frameCount) / sampleRate
    func index(_ time: Double) -> Int {
      let offset = ((time - bufferStart) * sampleRate).rounded()
      return Int(min(max(offset, 0), Double(frameCount)))
    }
    var slices: [TalkSlice] = []
    var ended = 0
    for i in presses.indices {
      let press = presses[i]
      // This press, and every one after it, starts after the buffer.
      guard press.start < bufferEnd else { break }
      let lower = index(press.start)
      let frames = lower..<max(lower, press.end.map(index) ?? frameCount)
      let ends = press.end.map { $0 <= bufferEnd } ?? false
      let starts = !press.started && !frames.isEmpty
      if starts { presses[i].started = true }
      if !frames.isEmpty || ends {
        slices.append(TalkSlice(frames: frames, startsTalkspurt: starts, endsTalkspurt: ends))
      }
      // Held past this buffer, so the next press starts after it too.
      guard ends else { break }
      ended += 1
    }
    presses.removeFirst(ended)
    return slices
  }
}

/// Converts the microphone frames that `TalkWindows` picks to the
/// backchannel's format: mono 16-bit at its clock rate. Each press goes
/// through the converter as a stream of its own. A sample-rate converter holds
/// back the last few frames it was given until it sees the ones after them,
/// so when a press ends the converter is flushed (those frames come out) and
/// reset, and the next press doesn't start with the end of the last one.
final class TalkConverter {
  let converter: AVAudioConverter
  let outputFormat: AVAudioFormat
  /// A press started, and none of its audio has come out yet.
  private var talkspurtPending = false

  init?(from inputFormat: AVAudioFormat, sampleRate: Double) {
    guard inputFormat.channelCount > 0,
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
      let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else { return nil }
    self.converter = converter
    self.outputFormat = outputFormat
  }

  /// The samples to send for `slices` of `buffer`, each chunk with whether it
  /// starts a talkspurt.
  func convert(
    _ buffer: AVAudioPCMBuffer, slices: [TalkSlice]
  ) -> [(samples: [Int16], startsTalkspurt: Bool)] {
    var chunks: [(samples: [Int16], startsTalkspurt: Bool)] = []
    for slice in slices {
      if slice.startsTalkspurt { talkspurtPending = true }
      let input = slice.frames.isEmpty ? nil : Self.frames(slice.frames, of: buffer)
      let samples = convert(input, flush: slice.endsTalkspurt)
      if slice.endsTalkspurt { converter.reset() }
      guard !samples.isEmpty else { continue }
      chunks.append((samples, talkspurtPending))
      talkspurtPending = false
    }
    return chunks
  }

  /// Run `input` (nil for none) through the converter and return what comes
  /// out. With `flush`, the frames the converter holds back come out too, and
  /// it needs `reset()` before more input.
  private func convert(_ input: AVAudioPCMBuffer?, flush: Bool) -> [Int16] {
    let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
    let capacity = AVAudioFrameCount((Double(input?.frameLength ?? 0) * ratio).rounded(.up)) + 256
    var samples: [Int16] = []
    nonisolated(unsafe) var pending = input
    while let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) {
      var error: NSError?
      let status = converter.convert(to: output, error: &error) { _, inputStatus in
        if let next = pending {
          pending = nil
          inputStatus.pointee = .haveData
          return next
        }
        inputStatus.pointee = flush ? .endOfStream : .noDataNow
        return nil
      }
      guard error == nil, let channel = output.int16ChannelData else { break }
      samples += UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength))
      // `.haveData` means the output buffer filled up, so more may be waiting.
      guard status == .haveData, output.frameLength == capacity else { break }
    }
    return samples
  }

  /// Frames `range` of `buffer`, copied into a buffer of their own unless
  /// they are all of it.
  private static func frames(
    _ range: Range<Int>, of buffer: AVAudioPCMBuffer
  ) -> AVAudioPCMBuffer? {
    if range == 0..<Int(buffer.frameLength) { return buffer }
    guard
      let part = AVAudioPCMBuffer(
        pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(range.count))
    else { return nil }
    part.frameLength = AVAudioFrameCount(range.count)
    // Each AudioBuffer holds one channel (non-interleaved) or all of them.
    let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
    let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let destination = UnsafeMutableAudioBufferListPointer(part.mutableAudioBufferList)
    for (from, to) in zip(source, destination) {
      guard let from = from.mData, let to = to.mData else { return nil }
      memcpy(to, from + range.lowerBound * bytesPerFrame, range.count * bytesPerFrame)
    }
    return part
  }
}

/// Captures the default microphone and sends it to the camera's backchannel
/// while Space is held. Each press starts a new talkspurt, so the first packet
/// carries the RTP marker bit and the RTP timestamp skips the silent time.
/// Only G.711 backchannels are handled here; `G711` encodes the samples.
///
/// The microphone stays open for the whole session, so the audio from the
/// moment Space goes down is already being captured. `setPressed` notes the
/// host time of each press and release, and the tap keeps only the frames
/// captured between them, going by each buffer's capture time
/// (`AVAudioTime.hostTime`, the same clock): see `TalkWindows`.
///
/// When the microphone's format changes (a headset plugged in), capture
/// restarts with a converter for the new format.
final class Talker: @unchecked Sendable {
  private let lock = NSLock()
  /// Guarded by `lock`. Presses are ignored unless capturing: before capture
  /// starts and after it stops.
  private var windows = TalkWindows()
  private var capturing = false
  private var engine: AVAudioEngine?
  /// Why talking ended before the session did, once it has.
  private var endReason: String?
  // Set before the first tap is installed, then read on the tap's thread.
  private var codec: PublicAudioCodec = .pcmu
  private var clockRate = 8000.0
  private var chunks: AsyncStream<(Data, Bool)>.Continuation?
  /// Starts, restarts and stops capture one at a time. Never waited for on
  /// the tap's thread, and `lock` isn't held while calling the engine.
  private let engineQueue = DispatchQueue(label: "CameraViewer.Talker")
  /// Used on `engineQueue` only.
  private var configurationObserver: (any NSObjectProtocol)?

  /// Called on the main actor from the Space key handler and when the window
  /// stops seeing keys. The press or release happens now, by the host clock.
  func setPressed(_ down: Bool) {
    let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
    lock.withLock {
      guard capturing else { return }
      if down { windows.press(at: now) } else { windows.release(at: now) }
    }
  }

  /// Start capturing and return the task that sends audio until the session
  /// ends, or nil when the backchannel or microphone can't be used. When
  /// talking ends before the session (sending failed, or the microphone went
  /// away), capture stops and the task calls `onEnd` with a short reason.
  func start(
    session: RTSPClientSession, backchannel: BackchannelStream,
    onEnd: @escaping @Sendable (String) async -> Void
  ) async -> Task<Void, Never>? {
    guard backchannel.codec == .pcmu || backchannel.codec == .pcma else {
      log("Talk: the camera's backchannel codec \(backchannel.codec) isn't handled by this example")
      return nil
    }
    guard await AVCaptureDevice.requestAccess(for: .audio) else {
      log("Talk: microphone access was denied")
      return nil
    }
    let engine = AVAudioEngine()
    let (stream, continuation) = AsyncStream<(Data, Bool)>.makeStream(
      bufferingPolicy: .bufferingNewest(50))
    lock.withLock {
      self.codec = backchannel.codec
      self.clockRate = Double(backchannel.clockRate)
      self.chunks = continuation
    }
    let started = engineQueue.sync {
      guard startCapture(on: engine) else { return false }
      lock.withLock {
        self.engine = engine
        capturing = true
      }
      // The notification comes on an engine queue, which must not tear the
      // engine down, so the restart runs on ours.
      let id = ObjectIdentifier(engine)
      configurationObserver = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
      ) { [weak self] _ in
        guard let self else { return }
        engineQueue.async { self.restart(id) }
      }
      return true
    }
    guard started else {
      continuation.finish()
      return nil
    }
    log("Talk: hold Space to talk (\(backchannel.codec), \(backchannel.clockRate) Hz)")
    return Task {
      for await (payload, startsTalkspurt) in stream {
        do {
          try await session.sendBackchannelAudio(payload, startsTalkspurt: startsTalkspurt)
        } catch {
          log("Talk: send failed: \(redactingUserInfo(in: "\(error)")); talking stopped")
          lock.withLock { endReason = endReason ?? "send failed" }
          stop()
          break
        }
      }
      if let reason = lock.withLock({ endReason }) { await onEnd(reason) }
    }
  }

  /// Install the microphone tap, with a converter for the input's current
  /// format, and start `engine`. Runs on `engineQueue`.
  private func startCapture(on engine: AVAudioEngine) -> Bool {
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard let converter = TalkConverter(from: inputFormat, sampleRate: clockRate) else {
      log("Talk: no usable microphone input")
      return false
    }
    // Each tap has a converter of its own: the tap a restart replaces may
    // still be converting a buffer.
    nonisolated(unsafe) let tapConverter = converter
    input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [self] buffer, time in
      capture(buffer, at: time, converter: tapConverter)
    }
    do {
      try engine.start()
    } catch {
      log("Talk: audio engine failed to start: \(error)")
      input.removeTap(onBus: 0)
      return false
    }
    return true
  }

  /// Restart capture on the engine `id` names, if it is still capturing,
  /// after a configuration change stopped it: the input's format may have
  /// changed, and the tap must follow it. Runs on `engineQueue`.
  private func restart(_ id: ObjectIdentifier) {
    let engine = lock.withLock { capturing ? self.engine : nil }
    guard let engine, ObjectIdentifier(engine) == id else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    guard startCapture(on: engine) else {
      log("Talk: the audio input changed and the microphone couldn't restart; talking stopped")
      lock.withLock { endReason = endReason ?? "no microphone" }
      stopCapture()
      return
    }
    let format = engine.inputNode.outputFormat(forBus: 0)
    log(
      "Talk: the audio input changed; the microphone restarted "
        + "(\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)")
  }

  /// Runs on the audio engine's tap thread, for every buffer the microphone
  /// delivers. `time.hostTime` is when the buffer's first frame was captured.
  private func capture(
    _ buffer: AVAudioPCMBuffer, at time: AVAudioTime, converter: TalkConverter
  ) {
    guard let chunks else { return }
    let frameCount = Int(buffer.frameLength)
    let sampleRate = buffer.format.sampleRate
    let start: Double
    if time.isHostTimeValid {
      start = AVAudioTime.seconds(forHostTime: time.hostTime)
    } else {
      // No capture time: take the buffer's last frame as captured just now.
      let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
      start = now - Double(frameCount) / sampleRate
    }
    let slices = lock.withLock {
      windows.slices(bufferStart: start, frameCount: frameCount, sampleRate: sampleRate)
    }
    guard !slices.isEmpty else { return }
    for (samples, startsTalkspurt) in converter.convert(buffer, slices: slices) {
      let payload = codec == .pcma ? G711.encodeALaw(samples) : G711.encodeMuLaw(samples)
      chunks.yield((payload, startsTalkspurt))
    }
  }

  /// Stop capturing: Space presses are ignored from now on, and the sending
  /// task ends once it has sent what was captured.
  func stop() {
    engineQueue.sync { stopCapture() }
  }

  /// Runs on `engineQueue`.
  private func stopCapture() {
    let (engine, chunks) = lock.withLock {
      defer {
        capturing = false
        windows = TalkWindows()
        self.engine = nil
      }
      return (self.engine, self.chunks)
    }
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
      self.configurationObserver = nil
    }
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    chunks?.finish()
  }
}

/// Tells from polls of the Space key's state, while a press lasts, whether
/// Space was released without its key-up event reaching the viewer (Mission
/// Control, a menu-bar extra's menu or the screen lock can take it). The state
/// counts only once it has shown Space down during the press: were it always
/// reported up, talking would still end at the key-up rather than at the
/// first poll.
struct SpaceKeyPoll {
  private var sawDown: Bool

  /// `downAtPress`: the state, read as the press was handled, shows Space down.
  init(downAtPress: Bool) { sawDown = downAtPress }

  /// Whether the press is over, now that a poll found Space down or not.
  mutating func isReleased(spaceDown: Bool) -> Bool {
    if spaceDown { sawDown = true }
    return !spaceDown && sawDown
  }
}

/// Space as push-to-talk for a `Talker`. A press starts talking only while
/// the viewer window is key; talking stops at the key-up, when the window or
/// app stops seeing keys, when the screen locks or sleeps, and when polls of
/// the key state (every 100 ms while talking) find Space up. The Space events
/// are swallowed, which keeps AppKit from beeping, until `stop()`.
@MainActor
final class PushToTalk {
  /// The Space bar's virtual key code (`kVK_Space`).
  nonisolated static let spaceKeyCode: CGKeyCode = 49

  private let talker: Talker
  private let window: NSWindow
  private var keyMonitor: Any?
  private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
  private var pollTimer: Timer?
  private var poll = SpaceKeyPoll(downAtPress: false)

  init(talker: Talker, window: NSWindow) {
    self.talker = talker
    self.window = window
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
      [weak self] event in
      guard event.charactersIgnoringModifiers == " " else { return event }
      let isPress = event.type == .keyDown
      if !event.isARepeat { MainActor.assumeIsolated { self?.space(isPress: isPress) } }
      return nil
    }
    // A Space released while the window isn't key (another app or window
    // activated), while a menu is open, during a live resize, or while the
    // screen is locked or the session switched away never reaches the
    // monitor, so stop talking when any of them starts.
    let app = NotificationCenter.default
    let workspace = NSWorkspace.shared.notificationCenter
    let stopNotifications: [(NotificationCenter, Notification.Name, NSWindow?)] = [
      (app, NSWindow.didResignKeyNotification, window),
      (app, NSApplication.didResignActiveNotification, nil),
      (app, NSMenu.didBeginTrackingNotification, nil),
      (app, NSWindow.willStartLiveResizeNotification, window),
      // Dragging the window by its title bar runs its own event loop.
      (app, NSWindow.willMoveNotification, window),
      // Fast user switching, or the login window.
      (workspace, NSWorkspace.sessionDidResignActiveNotification, nil),
      (workspace, NSWorkspace.screensDidSleepNotification, nil),
      (workspace, NSWorkspace.willSleepNotification, nil),
      (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), nil),
    ]
    observers = stopNotifications.map { center, name, object in
      let token = center.addObserver(forName: name, object: object, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.setTalking(false) }
      }
      return (center, token)
    }
  }

  /// Whether the Space key is down now, by the login session's key state.
  nonisolated static func spaceIsDown() -> Bool {
    CGEventSource.keyState(.combinedSessionState, key: spaceKeyCode)
  }

  /// A Space key-down or key-up that isn't a repeat.
  private func space(isPress: Bool) {
    // Only a press while the viewer window is key starts talking: with the
    // window minimized the app can still get key events, and the stop
    // notifications would never see it lose focus.
    if isPress, NSApp.keyWindow !== window { return }
    setTalking(isPress)
  }

  private func setTalking(_ talking: Bool) {
    talker.setPressed(talking)
    pollTimer?.invalidate()
    pollTimer = nil
    guard talking, keyMonitor != nil else { return }
    poll = SpaceKeyPoll(downAtPress: Self.spaceIsDown())
    // In the common modes, so it also fires while a menu or a resize tracks
    // events.
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pollSpace() }
    }
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer
  }

  private func pollSpace() {
    if poll.isReleased(spaceDown: Self.spaceIsDown()) { setTalking(false) }
  }

  /// Stop talking and stop handling Space: when the session ends, or when
  /// talking ended before it.
  func stop() {
    setTalking(false)
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    for (center, token) in observers { center.removeObserver(token) }
    observers = []
  }
}

/// The window title during a session: what it plays, the push-to-talk state
/// and, during replay, the recording time of the frame shown (or played, in a
/// session without video). Once the session has ended or failed, that title
/// stays.
@MainActor
final class SessionTitle {
  private let window: NSWindow
  private var stream = ""
  private var talk: String?
  private var talkStopped = false
  private var recordingTime: String?
  private var isFinal = false

  init(window: NSWindow) { self.window = window }

  func connected(stream: String) {
    self.stream = stream
    update()
  }

  /// Push-to-talk is ready, unless talking already stopped.
  func talkReady() {
    guard !talkStopped else { return }
    talk = "hold Space to talk"
    update()
  }

  /// Talking ended for the session, because of `reason`.
  func talkEnded(_ reason: String) {
    talkStopped = true
    talk = "talk stopped (\(reason))"
    update()
  }

  func showRecordingTime(_ time: String) {
    recordingTime = time
    update()
  }

  /// Show `title` from now on.
  func finish(_ title: String) {
    guard !isFinal else { return }
    isFinal = true
    window.title = title
  }

  private func update() {
    guard !isFinal else { return }
    window.title = (["IPCamKit — \(stream)"] + [talk, recordingTime].compactMap { $0 })
      .joined(separator: " — ")
  }
}

// MARK: - App Delegate

@MainActor
final class CameraViewerDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  var displayLayer: AVSampleBufferDisplayLayer!
  var streamTask: Task<Void, Never>?
  var pushToTalk: PushToTalk?
  let audioPlayer = AudioPlayer()
  let talker = Talker()

  let options: ViewerOptions

  init(options: ViewerOptions) {
    self.options = options
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered, defer: false
    )
    window.title = "IPCamKit Viewer — connecting…"
    window.center()
    window.minSize = NSSize(width: 320, height: 240)

    displayLayer = AVSampleBufferDisplayLayer()
    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = CGColor.black

    let contentView = NSView(frame: window.contentView!.bounds)
    contentView.layer = displayLayer
    contentView.wantsLayer = true
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)

    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(
      NSMenuItem(
        title: "Quit CameraViewer", action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"))
    appMenu.addItem(
      NSMenuItem(
        title: "Close Window", action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "w"))
    appMenuItem.submenu = appMenu
    NSApplication.shared.mainMenu = mainMenu

    if options.talk {
      pushToTalk = PushToTalk(talker: talker, window: window)
    }

    let layerRef = DisplayLayerRef(displayLayer)
    let options = options
    let win = window!
    let audio = audioPlayer
    let talker = talker
    let pushToTalk = pushToTalk

    streamTask = Task.detached {
      await Self.run(
        layerRef: layerRef, window: win, audioPlayer: audio, talker: talker,
        pushToTalk: pushToTalk, options: options)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool { true }

  func applicationWillTerminate(_ notification: Notification) {
    streamTask?.cancel()
    audioPlayer.stop()
    talker.stop()
  }

  // MARK: - Main entry (runs off main actor)

  nonisolated static func run(
    layerRef: DisplayLayerRef,
    window: NSWindow,
    audioPlayer: AudioPlayer,
    talker: Talker,
    pushToTalk: PushToTalk?,
    options: ViewerOptions
  ) async {
    var options = options

    // ONVIF discovery if the URL is HTTP
    if isDeviceServiceURL(options.url) {
      do {
        let urls = try await discoverStreamURLs(
          deviceService: options.url, username: options.username, password: options.password,
          multicast: options.transport == .multicast
        )
        if urls.isEmpty {
          log("ONVIF: no RTSP stream URLs discovered")
          await pushToTalk?.stop()
          await showFailure("no RTSP stream URLs discovered", in: window)
          return
        }
        for (i, u) in urls.enumerated() {
          log("ONVIF stream \(i): \(redactedURL(u))")
        }
        options.url = urls[0]
        log("Playing first stream: \(redactedURL(options.url))")
      } catch {
        log("ONVIF discovery failed: \(redactingUserInfo(in: "\(error)"))")
        await pushToTalk?.stop()
        await showFailure(error.localizedDescription, in: window)
        return
      }
    }

    await stream(
      layerRef: layerRef, window: window, audioPlayer: audioPlayer, talker: talker,
      pushToTalk: pushToTalk, options: options)
  }

  // MARK: - RTSP Streaming

  nonisolated static func stream(
    layerRef: DisplayLayerRef,
    window: NSWindow,
    audioPlayer: AudioPlayer,
    talker: Talker,
    pushToTalk: PushToTalk?,
    options: ViewerOptions
  ) async {
    // The library rejects a URL with a space or C0 control character, naming
    // it with only its userinfo hidden; this names it with every
    // credential-like value hidden, a raw space in one included. C1 controls
    // (U+0080–U+009F), which the library lets through, are rejected too.
    if options.url.unicodeScalars.contains(where: {
      $0.value <= 0x20 || (0x7F...0x9F).contains($0.value)
    }) {
      let reason =
        "Invalid URL (contains a space or control character): \(redactedURL(options.url))"
      log(reason)
      await pushToTalk?.stop()
      await showFailure(reason, in: window)
      return
    }
    // A username without a password is sent with an empty one.
    let creds = options.username.map { u in
      Credentials(username: u, password: options.password ?? "")
    }
    let session = RTSPClientSession(
      url: options.url, credentials: creds, transport: options.transport, tls: options.tls,
      tunnel: options.tunnel, onvif: options.onvif,
      onDiagnostic: { diagnostic in
        if diagnostic.severity != .info {
          log("\(diagnostic.severity): \(redactingUserInfo(in: diagnostic.message))")
        }
      })
    var talkTask: Task<Void, Never>?
    let title = await SessionTitle(window: window)

    do {
      let desc = try await session.start(options.play)
      let streamLabel = Self.streamLabel(desc)
      log("Connected: \(streamLabel)")
      await title.connected(stream: streamLabel)

      if options.talk {
        if let backchannel = desc.backchannel {
          talkTask = await talker.start(session: session, backchannel: backchannel) { reason in
            await MainActor.run {
              pushToTalk?.stop()
              title.talkEnded(reason)
            }
          }
        } else {
          log("Talk: the camera set up no backchannel")
        }
        if talkTask != nil {
          await title.talkReady()
        } else {
          await pushToTalk?.stop()
        }
      }
      // During replay, show the recording time of the frame on screen: of
      // each video frame, or of each audio frame when there is no video.
      var shownReplaySecond: Int?
      func showRecordingTime(_ recorded: Date) async {
        let second = Int(recorded.timeIntervalSince1970)
        guard second != shownReplaySecond else { return }
        shownReplaySecond = second
        await title.showRecordingTime(recorded.formatted(.iso8601))
      }

      if let audio = desc.audio {
        audioPlayer.start(
          codec: audio.codec, sampleRate: Double(audio.sampleRate),
          channels: UInt32(audio.channels ?? 1))
      }

      // Parameter sets VideoToolbox rejects are skipped (the previous ones,
      // or the next in-band ones, are used) rather than ending the session.
      var fmtDesc: CMVideoFormatDescription?
      var rejectedParameterSets = false
      if let video = desc.video, let sps = video.sps, let pps = video.pps {
        do {
          fmtDesc = try makeFormatDescription(
            codec: video.codec, sps: sps, pps: pps, vps: video.vps)
        } catch {
          log("Video: the SDP's parameter sets were rejected (\(error)); waiting for in-band ones")
        }
      }

      var receivedKeyframe = false

      for try await item in session.frames() {
        if Task.isCancelled { break }

        switch item {
        case .audio(let audioFrame):
          audioPlayer.enqueue(audioFrame)
          // Without video, the recording time comes from the audio.
          if desc.video == nil, let recorded = audioFrame.replay?.time {
            await showRecordingTime(recorded)
          }

        case .video(let frame):
          guard let video = desc.video else { continue }
          if let newSPS = frame.sps, let newPPS = frame.pps {
            do {
              fmtDesc = try makeFormatDescription(
                codec: video.codec,
                sps: newSPS, pps: newPPS, vps: frame.vps
              )
            } catch {
              if !rejectedParameterSets {
                rejectedParameterSets = true
                log(
                  "Video: in-band parameter sets were rejected (\(error)); keeping the previous ones"
                )
              }
            }
          }

          if !receivedKeyframe {
            guard frame.isKeyframe else { continue }
            receivedKeyframe = true
          }

          if let fmt = fmtDesc,
            let sample = buildSampleBuffer(
              frame, codec: video.codec, formatDescription: fmt
            )
          {
            await layerRef.enqueue(sample)
          }

          if let recorded = frame.replay?.time { await showRecordingTime(recorded) }

        case .metadata, .rtcp:
          break
        }
      }
      log("Session ended")
      await title.finish("IPCamKit Viewer — ended")
    } catch {
      log("Error: \(redactingUserInfo(in: "\(error)"))")
      await title.finish(failureTitle(error.localizedDescription))
    }

    // Space presses are neither handled nor recorded after the session.
    await pushToTalk?.stop()
    talker.stop()
    // The audio output would otherwise keep running (and keep the Mac from
    // idle sleep) while the window shows the session ended.
    audioPlayer.stop()
    await talkTask?.value
    await session.stop()
  }

  /// What the session plays, for the log and the window title: the video
  /// codec and resolution, or for a session without video, its audio.
  nonisolated static func streamLabel(_ desc: SessionDescription) -> String {
    if let video = desc.video {
      let res = video.resolution.map { "\($0.width)×\($0.height)" } ?? "?"
      return "\(video.codec) \(res)"
    }
    guard let audio = desc.audio else { return "no video or audio" }
    let codec: String
    switch audio.codec {
    // The SDP's encoding name, from the device.
    case .other(let name): codec = escapingLineBreaks(escapingControls(name))
    default: codec = "\(audio.codec)"
    }
    return "audio only (\(codec), \(audio.sampleRate) Hz)"
  }

  /// Show in the window title that the session failed: see `failureTitle(_:)`.
  nonisolated static func showFailure(_ reason: String, in window: NSWindow) async {
    let title = failureTitle(reason)
    await MainActor.run {
      window.title = title
    }
  }

  /// The window title for a session that failed: `reason`'s first line,
  /// without credentials or control characters, cut to 100 Unicode scalars.
  nonisolated static func failureTitle(_ reason: String) -> String {
    var short = escapingControls(redactingUserInfo(in: String(reason.prefix { !$0.isNewline })))
    if short.unicodeScalars.count > 100 {
      short = String(String.UnicodeScalarView(short.unicodeScalars.prefix(99))) + "…"
    }
    return "IPCamKit Viewer — failed: \(short)"
  }
}

// MARK: - ONVIF Discovery

/// The RTSP stream URI of each of the device's media profiles. With
/// `multicast`, each is asked for its multicast stream first, and for its
/// unicast one when the device answers that with an error or without a
/// usable URI. A profile whose unicast answer has no usable URI is skipped.
func discoverStreamURLs(
  deviceService: String,
  username: String?,
  password: String?,
  multicast: Bool = false
) async throws -> [String] {
  // The credentials go in WS-Security and in answers to HTTP authentication.
  let session = URLSession(
    configuration: .ephemeral,
    delegate: ONVIFAuthentication(username: username, password: password), delegateQueue: nil)
  defer { session.finishTasksAndInvalidate() }

  // Step 1: GetCapabilities → find the media service URL
  log("ONVIF: GetCapabilities…")
  let capsXML = try await onvifRequest(
    session: session, url: deviceService, username: username, password: password,
    body: """
      <GetCapabilities xmlns="http://www.onvif.org/ver10/device/wsdl">
        <Category>Media</Category>
      </GetCapabilities>
      """
  )

  // A device may answer with every category; the Media element's XAddr is
  // the one wanted, not the first (Analytics comes before Media).
  guard let media = extractElementContent(capsXML, localName: "Media"),
    let mediaXAddr = extractTagContent(media, localName: "XAddr")
  else {
    throw OnvifError("GetCapabilities: no Media XAddr found")
  }
  // The credentials come from the options; a user:password@ the device puts
  // in the address isn't used, or logged. The address is used on the
  // device service URL's scheme, host and port: the credentials go only to
  // the device named, and a device behind NAT reports its own address.
  guard let device = URLComponents(string: deviceService),
    let mediaServiceURL = onDeviceOrigin(mediaXAddr, device: device)
  else {
    throw OnvifError("GetCapabilities: invalid Media XAddr \(redactedURL(mediaXAddr))")
  }
  if mediaServiceURL != removingUserInfo(mediaXAddr) {
    log("ONVIF: Media service address \(redactedURL(mediaXAddr)) is used on the device's address")
  }
  log("ONVIF: Media service at \(redactedURL(mediaServiceURL))")

  // Step 2: GetProfiles → get profile tokens
  log("ONVIF: GetProfiles…")
  let profilesXML = try await onvifRequest(
    session: session, url: mediaServiceURL, username: username, password: password,
    body: """
      <GetProfiles xmlns="http://www.onvif.org/ver10/media/wsdl"/>
      """
  )

  let tokens = extractProfileTokens(profilesXML)
  if tokens.isEmpty {
    throw OnvifError("GetProfiles: no profiles found")
  }
  log("ONVIF: Found \(tokens.count) profile(s): \(tokens.joined(separator: ", "))")

  // Step 3: GetStreamUri for each profile
  var urls: [String] = []
  // A profile without a stream (metadata only, for example) answers with a
  // SOAP fault; skip it and keep the others.
  var lastError: Error?
  for token in tokens {
    func getStreamUri(multicast: Bool) async throws -> String {
      try await onvifRequest(
        session: session, url: mediaServiceURL, username: username, password: password,
        body: getStreamUriBody(token: token, multicast: multicast))
    }
    let answer: StreamURIAnswer
    do {
      var multicastAnswer: StreamURIAnswer?
      if multicast {
        // A device without multicast set up for the profile answers with a
        // SOAP fault (an HTTP error status), or without a usable URI. A
        // failure to reach it at all isn't retried.
        do {
          let found = StreamURIAnswer(xml: try await getStreamUri(multicast: true), device: device)
          switch found {
          case .usable:
            multicastAnswer = found
          case .missing:
            log("ONVIF: profile \(token) gave no multicast stream URI; asking for its unicast one")
          case .unusable(let uri):
            log(
              "ONVIF: profile \(token) gave an unusable multicast stream URI \(redactedURL(uri)); "
                + "asking for its unicast one")
          }
        } catch let error as OnvifError where error.httpStatus != nil {
          log(
            "ONVIF: GetStreamUri for a multicast stream of profile \(token) failed: "
              + "\(redactingUserInfo(in: "\(error)")); asking for its unicast one")
        }
      }
      if let multicastAnswer {
        answer = multicastAnswer
      } else {
        answer = StreamURIAnswer(xml: try await getStreamUri(multicast: false), device: device)
      }
    } catch {
      log("ONVIF: GetStreamUri for profile \(token) failed: \(redactingUserInfo(in: "\(error)"))")
      lastError = error
      continue
    }
    switch answer {
    case .usable(let uri, let onDevice):
      if URLComponents(string: onDevice)?.encodedHost != URLComponents(string: uri)?.encodedHost {
        log("ONVIF: stream URI \(redactedURL(uri)) is used on the device's host")
      }
      urls.append(onDevice)
    case .missing:
      log("ONVIF: profile \(token) gave no stream URI; skipping it")
    case .unusable(let uri):
      log("ONVIF: profile \(token) has an unusable stream URI \(redactedURL(uri)); skipping it")
    }
  }
  if urls.isEmpty, let lastError { throw lastError }

  return urls
}

/// The body of a GetStreamUri request (ONVIF Media service) for the profile
/// `token`. Unicast asks for RTP over RTSP. Multicast asks for Stream
/// `RTP-Multicast` with Transport Protocol `UDP`: the protocol says how RTP
/// travels (`UDP` on its own, `RTSP` interleaved in the RTSP connection over
/// TCP, `HTTP` with RTSP tunnelled in HTTP), and multicast RTP can only be UDP.
/// The URI is still an `rtsp://` one, whose SETUP asks for the multicast
/// transport; ONVIF Media2 calls this pairing `RtspMulticast`.
func getStreamUriBody(token: String, multicast: Bool) -> String {
  let (stream, transport) = multicast ? ("RTP-Multicast", "UDP") : ("RTP-Unicast", "RTSP")
  return """
    <GetStreamUri xmlns="http://www.onvif.org/ver10/media/wsdl">
      <StreamSetup>
        <Stream xmlns="http://www.onvif.org/ver10/schema">\(stream)</Stream>
        <Transport xmlns="http://www.onvif.org/ver10/schema">
          <Protocol>\(transport)</Protocol>
        </Transport>
      </StreamSetup>
      <ProfileToken>\(escapeXML(token))</ProfileToken>
    </GetStreamUri>
    """
}

/// The stream URI a GetStreamUri response gives.
enum StreamURIAnswer {
  /// `uri` as the device gave it, and `onDevice`, the same on the device's
  /// host without a user:password@ the device put in it (`onDeviceHost`):
  /// RTSP gets the credentials given.
  case usable(uri: String, onDevice: String)
  /// No `Uri`, or one that is empty or only whitespace.
  case missing
  /// A `Uri` that `onDeviceHost` rejects.
  case unusable(String)

  init(xml: String, device: URLComponents) {
    guard let uri = extractTagContent(xml, localName: "Uri"), !uri.isEmpty else {
      self = .missing
      return
    }
    guard let onDevice = onDeviceHost(uri, device: device) else {
      self = .unusable(uri)
      return
    }
    self = .usable(uri: uri, onDevice: onDevice)
  }
}

/// `url` without its `user:password@`, or nil unless it is an
/// `http://host…` or `https://host…` URL that `URLComponents` parses
/// (`http:/user:pw@host/` has no host for `URLComponents`, but URLSession
/// would rewrite it and send the userinfo). A URL without userinfo is
/// returned as it is.
func removingUserInfo(_ url: String) -> String? {
  guard isDeviceServiceURL(url), let colon = url.firstIndex(of: ":"),
    url[url.index(after: colon)...].hasPrefix("//"),
    var components = URLComponents(string: url), components.host?.isEmpty == false
  else { return nil }
  guard components.percentEncodedUser != nil || components.percentEncodedPassword != nil else {
    return url
  }
  components.percentEncodedUser = nil
  components.percentEncodedPassword = nil
  return components.string
}

/// `address` (the media service address a device reports) on the device
/// service URL's scheme, host and port, without its userinfo; nil unless it
/// is an `http(s)://host…` URL.
func onDeviceOrigin(_ address: String, device: URLComponents) -> String? {
  guard let stripped = removingUserInfo(address), var components = URLComponents(string: stripped)
  else { return nil }
  components.scheme = device.scheme
  components.encodedHost = device.encodedHost
  components.port = device.port
  return components.string
}

/// `uri` (a stream URI a device reports) on the device service URL's host,
/// keeping its scheme, port, path and query, without its userinfo; nil when
/// `URLComponents` finds no host in it.
func onDeviceHost(_ uri: String, device: URLComponents) -> String? {
  guard var components = URLComponents(string: uri), components.host?.isEmpty == false,
    let colon = uri.firstIndex(of: ":"), uri[uri.index(after: colon)...].hasPrefix("//")
  else { return nil }
  components.percentEncodedUser = nil
  components.percentEncodedPassword = nil
  components.encodedHost = device.encodedHost
  return components.string
}

// MARK: - ONVIF SOAP Transport

/// Answers a device's HTTP Digest or Basic challenge with the credentials
/// from the options (a username without a password gets an empty one). ONVIF
/// requires devices to support HTTP Digest, and some ask for it besides
/// WS-Security. Credentials the device rejected aren't sent again, and other
/// challenges (server trust) get URLSession's default handling.
final class ONVIFAuthentication: NSObject, URLSessionTaskDelegate, Sendable {
  let credential: URLCredential?

  init(username: String?, password: String?) {
    credential = username.map {
      URLCredential(user: $0, password: password ?? "", persistence: .forSession)
    }
  }

  typealias ChallengeHandler =
    @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping ChallengeHandler
  ) {
    let method = challenge.protectionSpace.authenticationMethod
    let http = [NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodHTTPBasic]
    guard http.contains(method) else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    guard let credential, challenge.previousFailureCount == 0 else {
      // No credentials, or the device rejected them: give up, and the
      // request ends with the device's 401 response.
      completionHandler(.rejectProtectionSpace, nil)
      return
    }
    completionHandler(.useCredential, credential)
  }

  /// Follow a redirect only within the same scheme, host and port: the
  /// credentials are for the device the user named, and a redirect to
  /// another host would get them in its HTTP authentication challenge. A
  /// refused redirect ends the request with the 3xx response. A
  /// `user:password@` in the new URL is dropped, as URLSession would answer
  /// the device's challenge with it instead of asking for the user's.
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    func origin(_ url: URL?) -> String? {
      guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased()
      else { return nil }
      let port = url.port ?? (scheme == "https" ? 443 : 80)
      return "\(scheme)://\(host):\(port)"
    }
    let from = origin(task.originalRequest?.url)
    guard from != nil, origin(request.url) == from, let url = request.url,
      var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
    else {
      completionHandler(nil)
      return
    }
    components.percentEncodedUser = nil
    components.percentEncodedPassword = nil
    guard let stripped = components.url else {
      completionHandler(nil)
      return
    }
    var redirected = request
    redirected.url = stripped
    completionHandler(redirected)
  }
}

func onvifRequest(
  session: URLSession,
  url: String,
  username: String?,
  password: String?,
  body: String
) async throws -> String {
  guard let requestURL = URL(string: url) else {
    throw OnvifError("Invalid URL: \(redactedURL(url))")
  }

  let securityHeader: String
  if let u = username {
    securityHeader = wsSecurityHeader(username: u, password: password ?? "")
  } else {
    securityHeader = ""
  }

  let envelope = """
    <?xml version="1.0" encoding="UTF-8"?>
    <s:Envelope
      xmlns:s="http://www.w3.org/2003/05/soap-envelope"
      xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
      xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
      <s:Header>\(securityHeader)</s:Header>
      <s:Body>\(body)</s:Body>
    </s:Envelope>
    """

  var request = URLRequest(url: requestURL)
  request.httpMethod = "POST"
  request.httpBody = envelope.data(using: .utf8)
  request.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")

  // At most 1 MiB of the response is read. No device's answer comes near
  // that, and a larger one would only take memory, and time to parse.
  let limit = 1 << 20
  let (bytes, response) = try await session.bytes(for: request)
  var data = Data()
  var tooLarge = false
  for try await byte in bytes {
    guard data.count < limit else {
      tooLarge = true
      bytes.task.cancel()
      break
    }
    data.append(byte)
  }

  if let http = response as? HTTPURLResponse, http.statusCode != 200 {
    let body = String(data: data, encoding: .utf8) ?? ""
    throw OnvifError("HTTP \(http.statusCode): \(body.prefix(200))", httpStatus: http.statusCode)
  }

  guard !tooLarge else { throw OnvifError("Response larger than 1 MiB") }
  guard let xml = String(data: data, encoding: .utf8) else {
    throw OnvifError("Invalid UTF-8 in response")
  }
  return xml
}

// MARK: - WS-Security UsernameToken (PasswordDigest)

func wsSecurityHeader(username: String, password: String) -> String {
  var nonceBytes = [UInt8](repeating: 0, count: 16)
  _ = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
  let nonceB64 = Data(nonceBytes).base64EncodedString()

  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  let created = formatter.string(from: Date())

  // Digest = Base64(SHA1(nonce + created + password))
  var digestInput = Data(nonceBytes)
  digestInput.append(Data(created.utf8))
  digestInput.append(Data(password.utf8))
  let digest = Data(Insecure.SHA1.hash(data: digestInput))
  let digestB64 = digest.base64EncodedString()

  return """
    <wsse:Security>
      <wsse:UsernameToken>
        <wsse:Username>\(escapeXML(username))</wsse:Username>
        <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digestB64)</wsse:Password>
        <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonceB64)</wsse:Nonce>
        <wsu:Created>\(created)</wsu:Created>
      </wsse:UsernameToken>
    </wsse:Security>
    """
}

// MARK: - Simple XML Helpers

/// Escape text for an XML element's content.
func escapeXML(_ text: String) -> String {
  text.replacingOccurrences(of: "&", with: "&amp;")
    .replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;")
    .replacingOccurrences(of: "\"", with: "&quot;")
    .replacingOccurrences(of: "'", with: "&apos;")
}

/// Decode the five predefined XML entities and numeric character references,
/// e.g. the `&amp;` that separates query parameters in a stream URI. The `;`
/// is looked for only as far as a reference can reach, so a long run of `&`
/// without one takes linear time.
func decodeXMLEntities(_ text: String) -> String {
  var result = ""
  var rest = Substring(text)
  while let amp = rest.firstIndex(of: "&") {
    result += rest[..<amp]
    guard let semi = rest[amp...].prefix(11).firstIndex(of: ";") else {
      result += "&"
      rest = rest[rest.index(after: amp)...]
      continue
    }
    let name = rest[rest.index(after: amp)..<semi]
    var decoded: String?
    switch name {
    case "amp": decoded = "&"
    case "lt": decoded = "<"
    case "gt": decoded = ">"
    case "quot": decoded = "\""
    case "apos": decoded = "'"
    default:
      if name.hasPrefix("#x") || name.hasPrefix("#X") {
        decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(String.init)
      } else if name.hasPrefix("#") {
        decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map(String.init)
      }
    }
    if let decoded {
      result += decoded
      rest = rest[rest.index(after: semi)...]
    } else {
      result += "&"
      rest = rest[rest.index(after: amp)...]
    }
  }
  return result + rest
}

/// The XML inside the first `<prefix:localName>` element (any prefix), or
/// nil if there is none.
///
/// The opening tag is found first, then the first closing tag after it: one
/// pattern with `(.*?)` between them tries every opening tag against the
/// rest of the document, which takes quadratic time when they aren't closed.
/// An opening tag holds no `<` (XML allows none in an attribute value), so
/// each tried ends by the next `<`.
func extractElementContent(_ xml: String, localName: String) -> String? {
  let prefix = "(?:[a-zA-Z0-9_-]+:)?"
  guard
    let opening = try? NSRegularExpression(pattern: "<\(prefix)\(localName)(?:\\s[^<>]*)?>"),
    let closing = try? NSRegularExpression(pattern: "</\(prefix)\(localName)>"),
    let open = opening.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
    let contentStart = Range(open.range, in: xml)?.upperBound,
    let close = closing.firstMatch(in: xml, range: NSRange(contentStart..., in: xml)),
    let contentEnd = Range(close.range, in: xml)?.lowerBound
  else { return nil }
  return String(xml[contentStart..<contentEnd])
}

/// Extract the text content of the first element with the given local name,
/// ignoring namespace prefixes. e.g. `<tt:XAddr>http://…</tt:XAddr>` → `http://…`
/// Entities are decoded (`&amp;` → `&`). An opening tag holds no `<`, as in
/// `extractElementContent`, so the search takes linear time.
func extractTagContent(_ xml: String, localName: String) -> String? {
  // Match <prefix:localName> or <localName>, capture content up to closing tag
  let pattern =
    "<(?:[a-zA-Z0-9_-]+:)?\(localName)(?:\\s[^<>]*)?>([^<]+)</(?:[a-zA-Z0-9_-]+:)?\(localName)>"
  guard let regex = try? NSRegularExpression(pattern: pattern),
    let match = regex.firstMatch(
      in: xml, range: NSRange(xml.startIndex..., in: xml))
  else { return nil }
  guard let range = Range(match.range(at: 1), in: xml) else { return nil }
  return decodeXMLEntities(String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Extract all `token` attribute values from `<…:Profiles token="…">`
/// elements. XML allows single or double quotes and spaces around `=`. An
/// opening tag holds no `<`, as in `extractElementContent`, so the search
/// takes linear time.
func extractProfileTokens(_ xml: String) -> [String] {
  let pattern =
    #"<(?:[a-zA-Z0-9_-]+:)?Profiles(?:\s[^<>]*?)?\stoken\s*=\s*(?:"([^"]+)"|'([^']+)')"#
  guard let regex = try? NSRegularExpression(pattern: pattern) else {
    return []
  }
  let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
  return matches.compactMap { match in
    // Group 1 holds a double-quoted value, group 2 a single-quoted one.
    let quoted = match.range(at: 1).location != NSNotFound ? 1 : 2
    guard let range = Range(match.range(at: quoted), in: xml) else { return nil }
    return decodeXMLEntities(String(xml[range]))
  }
}

struct OnvifError: Error, CustomStringConvertible, LocalizedError {
  let description: String
  /// The device's HTTP status, when it answered with an error (a SOAP fault
  /// comes with 400 or 500).
  let httpStatus: Int?
  init(_ description: String, httpStatus: Int? = nil) {
    self.description = description
    self.httpStatus = httpStatus
  }
  var errorDescription: String? { description }
}

// MARK: - VideoToolbox Helpers

func makeFormatDescription(
  codec: VideoCodec, sps: Data, pps: Data, vps: Data?
) throws -> CMVideoFormatDescription {
  var formatDesc: CMVideoFormatDescription?
  let status: OSStatus

  switch codec {
  case .h264:
    let spsArr = Array(sps)
    let ppsArr = Array(pps)
    status = spsArr.withUnsafeBufferPointer { spsPtr in
      ppsArr.withUnsafeBufferPointer { ppsPtr in
        var ptrs = [spsPtr.baseAddress!, ppsPtr.baseAddress!]
        var sizes = [spsArr.count, ppsArr.count]
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: nil, parameterSetCount: 2,
          parameterSetPointers: &ptrs, parameterSetSizes: &sizes,
          nalUnitHeaderLength: 4, formatDescriptionOut: &formatDesc
        )
      }
    }

  case .h265:
    let vpsArr = vps.map { Array($0) } ?? []
    let spsArr = Array(sps)
    let ppsArr = Array(pps)
    status = vpsArr.withUnsafeBufferPointer { vpsPtr in
      spsArr.withUnsafeBufferPointer { spsPtr in
        ppsArr.withUnsafeBufferPointer { ppsPtr in
          var ptrs: [UnsafePointer<UInt8>] = []
          var sizes: [Int] = []
          if let vp = vpsPtr.baseAddress, !vpsArr.isEmpty {
            ptrs.append(vp)
            sizes.append(vpsArr.count)
          }
          ptrs.append(spsPtr.baseAddress!)
          sizes.append(spsArr.count)
          ptrs.append(ppsPtr.baseAddress!)
          sizes.append(ppsArr.count)
          return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: nil, parameterSetCount: ptrs.count,
            parameterSetPointers: &ptrs, parameterSetSizes: &sizes,
            nalUnitHeaderLength: 4, extensions: nil,
            formatDescriptionOut: &formatDesc
          )
        }
      }
    }
  }

  guard status == noErr, let desc = formatDesc else {
    throw NSError(
      domain: "CameraViewer", code: Int(status),
      userInfo: [
        NSLocalizedDescriptionKey:
          "CMVideoFormatDescription creation failed: \(status)"
      ]
    )
  }
  return desc
}

func buildSampleBuffer(
  _ frame: PublicVideoFrame,
  codec: VideoCodec,
  formatDescription: CMVideoFormatDescription
) -> CMSampleBuffer? {
  // Reconstruct AVCC: [4-byte length][NAL]...
  // Skip non-VCL NALs: parameter sets are in the format description,
  // and SEI/AUD corrupt VideoToolbox's decoder state.
  var avccData = Data()
  for nal in frame.nalus {
    guard !nal.isEmpty else { continue }
    let firstByte = nal[nal.startIndex]
    let nalType: UInt8 =
      codec == .h264 ? (firstByte & 0x1F) : ((firstByte >> 1) & 0x3F)
    if codec == .h264 && nalType >= 6 && nalType <= 9 { continue }
    if codec == .h265 && nalType >= 32 && nalType <= 40 { continue }
    var length = UInt32(nal.count).bigEndian
    withUnsafeBytes(of: &length) { avccData.append(contentsOf: $0) }
    avccData.append(nal)
  }
  guard !avccData.isEmpty else { return nil }

  var blockBuffer: CMBlockBuffer?
  guard
    CMBlockBufferCreateWithMemoryBlock(
      allocator: nil, memoryBlock: nil,
      blockLength: avccData.count, blockAllocator: nil,
      customBlockSource: nil, offsetToData: 0,
      dataLength: avccData.count, flags: 0,
      blockBufferOut: &blockBuffer
    ) == noErr, let block = blockBuffer
  else { return nil }
  CMBlockBufferAssureBlockMemory(block)
  _ = avccData.withUnsafeBytes { ptr in
    CMBlockBufferReplaceDataBytes(
      with: ptr.baseAddress!, blockBuffer: block,
      offsetIntoDestination: 0, dataLength: avccData.count
    )
  }

  var sampleBuffer: CMSampleBuffer?
  var sampleSize = avccData.count
  var timingInfo = CMSampleTimingInfo(
    duration: .invalid,
    presentationTimeStamp: .zero,
    decodeTimeStamp: .invalid
  )
  guard
    CMSampleBufferCreateReady(
      allocator: nil, dataBuffer: block,
      formatDescription: formatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 1, sampleTimingArray: &timingInfo,
      sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer
    ) == noErr, let sample = sampleBuffer
  else { return nil }

  let attachments =
    CMSampleBufferGetSampleAttachmentsArray(
      sample, createIfNecessary: true
    )! as NSArray
  let dict = attachments[0] as! NSMutableDictionary
  dict[kCMSampleAttachmentKey_DisplayImmediately] = true
  if !frame.isKeyframe {
    dict[kCMSampleAttachmentKey_NotSync] = true
  }

  return sample
}

// MARK: - Logging (unbuffered stderr)

/// `url` with its `user:password@` replaced by `***`, for the log: everything
/// between `://` (or the scheme's `:` when there's no `//`) and the last `@`
/// (a password may contain a raw `/` or `@`).
func redactedURL(_ url: String) -> String {
  // Unicode scalars, not Characters: an `@` that a combining mark follows
  // still ends the userinfo.
  let scalars = url.unicodeScalars
  var afterScheme = scalars.startIndex
  // A scheme is a letter, then letters, digits, `+`, `-` or `.` (RFC 3986);
  // a `://` later on may be part of the password.
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
  // A fullwidth `＠` or small `﹫` typed through an input method counts too.
  guard
    let at = scalars[afterScheme...].lastIndex(where: {
      $0 == "@" || $0 == "\u{FF20}" || $0 == "\u{FE6B}"
    })
  else { return redactingQueryCredentials(in: url, wholeURL: true) }
  return redactingQueryCredentials(
    in: String(scalars[..<afterScheme]) + "***" + String(scalars[at...]), wholeURL: true)
}

/// `text` with the values of query parameters that look like credentials
/// (`isCredentialName(_:)`) replaced by `***`: some cameras put them in the
/// stream URI's query. A name runs from a `?`, `&` or `;` up to the `=`
/// (without `&`, `;` or `#` in it). A path segment that starts with such a
/// `name=` is hidden after the `=` up to the next `/`, `?` or `#`, as in
/// Xiongmai's `/user=admin_password=…_channel=1…`. A query value ends only at
/// `&` or `#` (a `;` may be part of a password). In free text a name or value
/// also ends at an ASCII space, tab or line break, which separate a URL from
/// the words around it (other whitespace, such as U+00A0, doesn't: the
/// library accepts URLs holding it and quotes them in its errors); with
/// `wholeURL` (the text is one URL) it doesn't, so a name with a raw space
/// in it is still recognised, and a raw space in a password doesn't show
/// what follows it.
func redactingQueryCredentials(in text: String, wholeURL: Bool = false) -> String {
  let wordBreaks = wholeURL ? [] : urlWordBreaks
  let queryHidden = hidingCredentialValues(
    in: text, after: ["?", "&", ";"], nameEnds: wordBreaks.union(["=", "&", ";", "#"]),
    valueEnds: wordBreaks.union(["&", "#"]))
  return hidingCredentialValues(
    in: queryHidden, after: ["/"], nameEnds: wordBreaks.union(["=", "/", "?", "#", ";"]),
    valueEnds: wordBreaks.union(["/", "?", "#"]))
}

/// `text` with the value of every credential-like `name=value` that starts
/// right after one of `starts` replaced by `***`. The name runs up to the
/// first of `nameEnds`, which must be `=`; the value up to the first of
/// `valueEnds`. After a hidden value the scan goes on at its end, else at the
/// end of the name. Unicode scalars, not Characters: a `=` or `&` that a
/// combining mark follows still separates.
///
/// A start character that isn't one of `nameEnds` (`?` in a query) can come
/// inside a name, where it begins a name of its own: a suffix of the one
/// around it. Scanning each such suffix again took quadratic time on a long
/// run of `?`, so they are checked with the name around them instead. A
/// suffix contains a credential word only if the whole name does (`?` is
/// neither a hex digit nor part of a percent escape), and only the last one,
/// without a `?` in it, can be one of the CGI names, so checking the whole
/// name and that last suffix hides the same values in linear time.
func hidingCredentialValues(
  in text: String, after starts: Set<Unicode.Scalar>, nameEnds: Set<Unicode.Scalar>,
  valueEnds: Set<Unicode.Scalar>
) -> String {
  let scalars = Array(text.unicodeScalars)
  // An array, not a `String.UnicodeScalarView`: appending slices to that
  // isn't amortized, so it takes quadratic time.
  var result: [Unicode.Scalar] = []
  result.reserveCapacity(scalars.count)
  var i = 0
  while i < scalars.count {
    let scalar = scalars[i]
    result.append(scalar)
    i += 1
    guard starts.contains(scalar) else { continue }
    let nameStart = i
    var nameEnd = nameStart
    var lastInnerStart: Int?
    while nameEnd < scalars.count, !nameEnds.contains(scalars[nameEnd]) {
      if starts.contains(scalars[nameEnd]) { lastInnerStart = nameEnd }
      nameEnd += 1
    }
    // Without `=`, no start character before `nameEnd` begins a parameter
    // either; with it, the names that begin inside this one are checked here.
    // The scan goes on at `nameEnd` unless a value is hidden.
    result.append(contentsOf: scalars[nameStart..<nameEnd])
    i = nameEnd
    guard nameEnd < scalars.count, scalars[nameEnd] == "=" else { continue }
    func isCredential(from start: Int) -> Bool {
      isCredentialName(String(String.UnicodeScalarView(scalars[start..<nameEnd])))
    }
    let isHidden =
      isCredential(from: nameStart) || lastInnerStart.map { isCredential(from: $0 + 1) } == true
    guard isHidden else { continue }
    var valueEnd = nameEnd + 1
    while valueEnd < scalars.count, !valueEnds.contains(scalars[valueEnd]) { valueEnd += 1 }
    result.append(scalars[nameEnd])
    result.append(contentsOf: "***".unicodeScalars)
    i = valueEnd
  }
  return String(String.UnicodeScalarView(result))
}

/// Whether a query parameter or path segment name looks like a credential:
/// percent-decoded (`%70wd` is `pwd`), it contains user, pass, pwd, auth,
/// token or secret, or is one of the CGI names usr, pw, psw, loginuse and
/// loginpas, in any case.
func isCredentialName(_ name: String) -> Bool {
  let decoded = percentDecoded(name)
  return decoded.contains(/(?i)user|pass|pwd|auth|token|secret/.matchingSemantics(.unicodeScalar))
    || decoded.wholeMatch(of: /(?i)usr|pw|psw|loginuse|loginpas/.matchingSemantics(.unicodeScalar))
      != nil
}

/// `text` with each `%` and two hex digits replaced by the byte they stand
/// for, read as UTF-8 (bytes that aren't UTF-8 read as U+FFFD). A `%`
/// without two hex digits after it stays.
func percentDecoded(_ text: String) -> String {
  guard text.contains("%") else { return text }
  func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
    default: nil
    }
  }
  let utf8 = Array(text.utf8)
  var bytes: [UInt8] = []
  var i = 0
  while i < utf8.count {
    if utf8[i] == UInt8(ascii: "%"), i + 2 < utf8.count, let high = hexValue(utf8[i + 1]),
      let low = hexValue(utf8[i + 2])
    {
      bytes.append(high << 4 | low)
      i += 3
    } else {
      bytes.append(utf8[i])
      i += 1
    }
  }
  return String(decoding: bytes, as: UTF8.self)
}

/// Whether `url` is an ONVIF device service URL: its scheme is `http` or
/// `https`, in any case.
func isDeviceServiceURL(_ url: String) -> Bool {
  guard let colon = url.firstIndex(of: ":") else { return false }
  let scheme = url[..<colon].lowercased()
  return scheme == "http" || scheme == "https"
}

/// Whether `url` may hold a user name or password `URLComponents` reads
/// wrong (the library's rule for its own URLs): an `@` after the host, plus
/// userinfo, a port on a host name or IPv4 address, or any `:` between the
/// host and the last `@`. `http://admin:12345/abc@cam/` reads as host `admin`,
/// port 12345, which would then get the WS-Security digest of the password.
func hasAmbiguousUserInfo(_ url: String) -> Bool {
  // Unicode scalars, not Characters: URLComponents splits at an `@`, `/`, `?`,
  // `#` or `:` that a combining mark follows.
  guard let schemeEnd = url.utf8.firstRange(of: "://".utf8) else { return false }
  let rest = url.unicodeScalars[schemeEnd.upperBound...]
  guard let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }),
    let at = rest[authorityEnd...].lastIndex(of: "@")
  else { return false }
  let authority = rest[..<authorityEnd]
  return authority.contains("@") || (authority.first != "[" && authority.contains(":"))
    || rest[authorityEnd..<at].contains(":")
}

/// The ASCII space, tab and line breaks, which separate a URL in free text
/// from the words around it. Other whitespace, such as U+00A0, doesn't: the
/// library accepts URLs holding it and quotes them in its errors.
nonisolated var urlWordBreaks: Set<Unicode.Scalar> { [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}"] }

/// `text` (an error's description, say) with the `user:password@` of every
/// URL in it replaced by `***@`, and its credential-like query values hidden
/// (`redactingQueryCredentials(in:)`). A URL starts at the first scheme in a
/// word (a letter, then letters, digits, `+`, `-` or `.`, then `:`) and ends
/// at the next `urlWordBreaks` scalar. As in `redactedURL(_:)`, its userinfo
/// is everything from the scheme's `:`, or the `//` after it, to the URL's
/// last `@`, as a password may contain a raw `@` or `/`. A word without a
/// scheme and an `@` after it stays as it is; a URL with an `@` in its path
/// loses a little more than its userinfo.
func redactingUserInfo(in text: String) -> String {
  func isLetter(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("A"..."Z").contains(c) }
  let scalars = Array(text.unicodeScalars)
  var result: [Unicode.Scalar] = []
  result.reserveCapacity(scalars.count)
  var wordStart = 0
  while wordStart < scalars.count {
    var wordEnd = wordStart
    while wordEnd < scalars.count, !urlWordBreaks.contains(scalars[wordEnd]) { wordEnd += 1 }
    // The userinfo starts after the first `:` that a run of scheme
    // characters with a letter in it comes right before.
    var userInfoStart: Int?
    var schemeHasLetter = false
    for j in wordStart..<wordEnd {
      let c = scalars[j]
      if c == ":", schemeHasLetter {
        userInfoStart = j + 1
        break
      }
      if isLetter(c) {
        schemeHasLetter = true
      } else if !(("0"..."9").contains(c) || "+-.".unicodeScalars.contains(c)) {
        schemeHasLetter = false
      }
    }
    if var start = userInfoStart {
      if scalars[start..<wordEnd].starts(with: "//".unicodeScalars) { start += 2 }
      // A fullwidth `＠` or small `﹫` typed through an input method counts too.
      if let at = scalars[start..<wordEnd].lastIndex(where: {
        $0 == "@" || $0 == "\u{FF20}" || $0 == "\u{FE6B}"
      }) {
        result.append(contentsOf: scalars[wordStart..<start])
        result.append(contentsOf: "***".unicodeScalars)
        wordStart = at
      }
    }
    result.append(contentsOf: scalars[wordStart..<min(wordEnd + 1, scalars.count)])
    wordStart = wordEnd + 1
  }
  return redactingQueryCredentials(in: String(String.UnicodeScalarView(result)))
}

/// `text` with control characters other than newline and tab, the Unicode
/// bidirectional formatting characters, and the line and paragraph
/// separators U+2028 and U+2029 written as `\u{1B}`, `\u{202E}` and the like.
/// Log lines and the window title can carry text from the device (a profile
/// token, an HTTP error body), which could otherwise drive the terminal with
/// escape sequences or reorder what is shown.
func escapingControls(_ text: String) -> String {
  var escaped = ""
  for scalar in text.unicodeScalars {
    let value = scalar.value
    let isControl =
      (value < 0x20 && scalar != "\n" && scalar != "\t") || (0x7F...0x9F).contains(value)
    let isBidi =
      value == 0x061C || value == 0x200E || value == 0x200F || (0x202A...0x202E).contains(value)
      || (0x2066...0x2069).contains(value)
    let isSeparator = value == 0x2028 || value == 0x2029
    if isControl || isBidi || isSeparator {
      escaped += "\\u{\(String(value, radix: 16, uppercase: true))}"
    } else {
      escaped.unicodeScalars.append(scalar)
    }
  }
  return escaped
}

/// `text` with its line breaks (line feed, carriage return, NEL, U+2028 and
/// U+2029) written as `\u{A}` and the like, as `escapingControls(_:)` writes
/// the others.
func escapingLineBreaks(_ text: String) -> String {
  var escaped = ""
  for scalar in text.unicodeScalars {
    switch scalar.value {
    case 0x0A, 0x0D, 0x85, 0x2028, 0x2029:
      escaped += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
    default:
      escaped.unicodeScalars.append(scalar)
    }
  }
  return escaped
}

/// Write `msg` and a newline to stderr, through `escapingControls(_:)` and
/// `escapingLineBreaks(_:)`: messages quote the device and the library (an
/// error, an HTTP error body, a profile token, a URI), whose line breaks
/// could otherwise make what looks like log lines of their own. Text of
/// several lines goes in one `log` call per line.
func log(_ msg: String) {
  var m = escapingLineBreaks(escapingControls(msg)) + "\n"
  m.withUTF8 { _ = fwrite($0.baseAddress, 1, $0.count, stderr) }
}

// MARK: - Entry Point

let usage = """
  Usage: CameraViewer <url> [username] [password] [options]

  Examples:
    CameraViewer rtsp://192.168.1.100:554/stream1 admin password
    CameraViewer rtsps://192.168.1.100:322/stream1 admin password
    CameraViewer http://192.168.1.100:2020/onvif/device_service admin password

  An http/https URL triggers ONVIF discovery to find RTSP stream URLs.
  Username and password are optional (used for both RTSP and ONVIF auth);
  they can also be given in the URL as user:password@.

  Options:
    --transport tcp|udp|multicast
        How RTP arrives: interleaved on the RTSP connection (default), a UDP
        port pair, or the multicast group the camera assigns.
    --tunnel <url>
        Carry RTSP through an http://, https://, ws:// or wss:// tunnel.
        Needs --transport tcp. <url> stays the rtsp:// URL used inside it.
    --tls-sha256 <fingerprint>
        Accept only the server certificate with this SHA-256 fingerprint
        (rtsps:// URLs and https/wss tunnels). A self-signed camera certificate
        needs it; this prints the fingerprint:
          openssl s_client -connect HOST:PORT </dev/null 2>/dev/null \\
            | openssl x509 -noout -fingerprint -sha256
    --replay <time>
        ONVIF replay from a recording, starting at an ISO 8601 time such as
        2026-11-01T08:00:00Z. <url> is the camera's replay URL. The window
        title shows each frame's recording time.
    --scale <speed>
        Playback speed: 2 is twice as fast, -1 plays backwards. Mostly for
        --replay; live cameras usually ignore it.
    --talk
        Two-way audio over the ONVIF backchannel: hold Space to send the
        microphone to the camera. G.711 backchannels only. The microphone
        stays open while connected (macOS shows its indicator); audio is sent
        only while Space is held in the viewer window.
    --
        Ends the options: the arguments after it are the URL, username and
        password even when they start with --, e.g.
          CameraViewer rtsp://192.168.1.100/stream1 admin --talk -- --secret
  """

func fail(_ message: String) -> Never {
  log(message)
  exit(1)
}

/// Log `message`, when there is one, and a blank line, then the usage text,
/// and exit with status 1.
func failShowingUsage(_ message: String? = nil) -> Never {
  if let message {
    log(message)
    log("")
  }
  for line in usage.split(separator: "\n", omittingEmptySubsequences: false) {
    log(String(line))
  }
  exit(1)
}

/// A command-line argument, and where it is: 0 is the program, 1 the first
/// argument after it.
typealias Argument = (position: Int, text: String)

/// Remove `--name <value>` from `args` and return the value, or nil when absent.
func takeValue(_ name: String, from args: inout [Argument]) -> String? {
  guard let flag = args.firstIndex(where: { $0.text == name }) else { return nil }
  guard flag + 1 < args.count else { fail("\(name) needs a value") }
  let value = args[flag + 1].text
  // `--transport --transport tcp` gives the option twice rather than a value.
  if value == name { fail("\(name) given more than once") }
  args.removeSubrange(flag...(flag + 1))
  if args.contains(where: { $0.text == name }) { fail("\(name) given more than once") }
  return value
}

/// Remove `--name` from `args` and return whether it was there.
func takeFlag(_ name: String, from args: inout [Argument]) -> Bool {
  guard let flag = args.firstIndex(where: { $0.text == name }) else { return false }
  args.remove(at: flag)
  if args.contains(where: { $0.text == name }) { fail("\(name) given more than once") }
  return true
}

/// Parse a `--replay` time: ISO 8601 with a time zone, such as
/// `2026-11-01T08:00:00Z` or `2026-11-01T08:00:00.5+01:00`. A field out of
/// range is rejected; `Date.ISO8601FormatStyle` would roll `2026-02-30` over
/// into March and `08:60` into the next hour.
func parseReplayTime(_ text: String) -> Date? {
  let format =
    /(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|[+-](\d{2})(?::?(\d{2}))?)/
  guard let match = text.wholeMatch(of: format.asciiOnlyDigits()) else { return nil }
  let (_, year, month, day, hour, minute, second, zoneHours, zoneMinutes) = match.output
  let number = { (digits: Substring?) in digits.flatMap { Int($0) } ?? 0 }
  let isLeapYear = number(year) % 4 == 0 && (number(year) % 100 != 0 || number(year) % 400 == 0)
  let monthLengths = [31, isLeapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  guard (1...12).contains(number(month)),
    (1...monthLengths[number(month) - 1]).contains(number(day)),
    number(hour) < 24, number(minute) < 60, number(second) < 60, number(zoneHours) < 24,
    number(zoneMinutes) < 60
  else { return nil }
  // With fractional seconds first: the plain strategy drops them. Foundation
  // reads at most 9 digits (nanoseconds); the rest are dropped.
  let text = text.replacing(/(\.\d{9})\d+/) { $0.1 }
  let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  return (try? withFraction.parse(text)) ?? (try? Date(text, strategy: .iso8601))
}

var args: [Argument] = CommandLine.arguments.enumerated().map { ($0.offset, $0.element) }
var options = ViewerOptions()
// Arguments after `--` are never options.
var afterOptions: [String] = []
if let end = args.firstIndex(where: { $0.text == "--" }) {
  afterOptions = args[(end + 1)...].map(\.text)
  args.removeSubrange(end...)
}

if let hex = takeValue("--tls-sha256", from: &args) {
  guard let pin = CertificateFingerprint(hex: hex) else {
    fail("--tls-sha256 needs a SHA-256 fingerprint: 64 hex digits, colons optional")
  }
  options.tls = TLSOptions(serverTrust: .pinned([pin]))
}
if let name = takeValue("--transport", from: &args) {
  switch name.lowercased() {
  case "tcp": options.transport = .tcp
  case "udp": options.transport = .udp
  case "multicast": options.transport = .multicast
  default: fail("--transport needs tcp, udp or multicast")
  }
}
if let value = takeValue("--tunnel", from: &args) {
  guard let tunnelURL = URL(string: value), let scheme = tunnelURL.scheme?.lowercased() else {
    fail("--tunnel needs an http, https, ws or wss URL")
  }
  switch scheme {
  case "http", "https": options.tunnel = .http(tunnelURL)
  case "ws", "wss": options.tunnel = .webSocket(tunnelURL)
  default: fail("--tunnel needs an http, https, ws or wss URL")
  }
  guard options.transport == .tcp else { fail("--tunnel needs --transport tcp") }
}
if let value = takeValue("--replay", from: &args) {
  guard let start = parseReplayTime(value) else {
    fail("--replay needs a valid ISO 8601 time with a time zone, e.g. 2026-11-01T08:00:00Z")
  }
  options.replayFrom = start
}
if let value = takeValue("--scale", from: &args) {
  guard let speed = Double(value), speed.isFinite, speed != 0 else {
    fail("--scale needs a non-zero number, e.g. 2 or -1")
  }
  options.scale = speed
}
options.talk = takeFlag("--talk", from: &args)

if let unknown = args.dropFirst().first(where: { $0.text.hasPrefix("--") }) {
  failShowingUsage(
    "Unknown option in argument \(unknown.position) (not shown, as it may be a password); "
      + "a username or password that starts with -- goes after --")
}
let arguments = args.map(\.text) + afterOptions
guard (2...4).contains(arguments.count) else { failShowingUsage() }

options.url = arguments[1]
options.username = arguments.count > 2 ? arguments[2] : nil
options.password = arguments.count > 3 ? arguments[3] : nil
// An ONVIF device service URL's user:password@ is used for WS-Security, HTTP
// authentication and RTSP when no username argument is given; RTSP URLs keep
// theirs, which the library reads.
if isDeviceServiceURL(options.url) {
  // `http:/user:pw@host/` and `http:host/` have no `//`, so URLComponents
  // finds no host or userinfo in them, but URLSession rewrites them to
  // `http://` and sends the userinfo; accept only `scheme://host…`.
  let formError =
    "Invalid URL \(redactedURL(options.url)): an ONVIF device service URL needs the form "
    + "http://host/… or https://host/…"
  let afterScheme = options.url[options.url.firstIndex(of: ":")!...].dropFirst()
  guard afterScheme.hasPrefix("//") else { fail(formError) }
  if hasAmbiguousUserInfo(options.url) {
    fail(
      "Invalid URL \(redactedURL(options.url)): write /, ?, # and @ in a user name or password "
        + "as %2F, %3F, %23 and %40, and an @ in the path as %40")
  }
  guard var components = URLComponents(string: options.url) else {
    // A character URLs can't hold, say, or a raw `/`, `?` or `#` in a
    // password that no `@` after the host gives away. Nothing after the
    // scheme is shown: the userinfo can't be told apart (a fullwidth `＠`
    // isn't `@`).
    let scheme = options.url[..<options.url.firstIndex(of: ":")!]
    fail(
      "Invalid URL \(scheme)://…: it can't be parsed. Write /, ?, # and @ in a user name or "
        + "password as %2F, %3F, %23 and %40")
  }
  guard components.host?.isEmpty == false else { fail(formError) }
  // URLSession would take a port above 65535 modulo 65536 and connect there.
  // A port too large for `Int` reads as nil (URLSession then uses 65535); an
  // empty one (`host:`, `[::1]:`) is the default.
  if components.port.map({ !(1...65535).contains($0) })
    ?? (components.rangeOfPort?.isEmpty == false)
  {
    fail("Invalid URL \(redactedURL(options.url)): the port must be from 1 to 65535")
  }
  if components.percentEncodedUser != nil || components.percentEncodedPassword != nil {
    // A part that isn't percent-encoded UTF-8 decodes to nil; sending an
    // empty user name or password instead would fail without saying why.
    guard (components.percentEncodedUser == nil) == (components.user == nil),
      (components.percentEncodedPassword == nil) == (components.password == nil)
    else {
      fail(
        "Invalid URL \(redactedURL(options.url)): its user name or password isn't "
          + "percent-encoded UTF-8")
    }
    if options.username == nil {
      options.username = components.user ?? ""
      options.password = components.password
    }
    components.percentEncodedUser = nil
    components.percentEncodedPassword = nil
    if let stripped = components.string { options.url = stripped }
  }
}

log("Connecting to \(redactedURL(options.url))…")

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = CameraViewerDelegate(options: options)
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
