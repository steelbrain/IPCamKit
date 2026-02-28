// CameraViewer — example app for the IPCamKit RTSP client library.
// Displays a live RTSP camera feed using VideoToolbox decoding.
// Supports ONVIF discovery: pass an http:// device service URL to
// auto-discover RTSP stream URLs.
//
// Usage:
//   swift run -c release CameraViewer [url] [username] [password]
//
// Examples:
//   swift run -c release CameraViewer rtsp://192.168.1.158:554/stream1 admin pass
//   swift run -c release CameraViewer http://192.168.1.158:2020/onvif/device_service admin pass

@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import CryptoKit
import IPCamKit

// MARK: - Sendable wrapper for AVSampleBufferDisplayLayer

final class DisplayLayerRef: @unchecked Sendable {
  let layer: AVSampleBufferDisplayLayer
  init(_ layer: AVSampleBufferDisplayLayer) { self.layer = layer }
}

// MARK: - Audio Playback

final class AudioPlayer: @unchecked Sendable {
  private var engine: AVAudioEngine?
  private var playerNode: AVAudioPlayerNode?
  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?

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

    do {
      try eng.start()
    } catch {
      log("AudioPlayer: engine start failed: \(error)")
      return
    }
    node.play()

    self.engine = eng
    self.playerNode = node
    self.converter = conv
    self.inputFormat = inFmt
    log("AudioPlayer: started (\(codec), \(Int(sampleRate)) Hz, \(channels) ch)")
  }

  func enqueue(_ frame: PublicAudioFrame) {
    guard let converter, let inputFormat, let playerNode else { return }
    let data = frame.data
    let frameCount = UInt32(data.count) / inputFormat.streamDescription.pointee.mBytesPerFrame
    guard frameCount > 0 else { return }

    guard let inBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
      return
    }
    inBuf.frameLength = frameCount
    _ = data.withUnsafeBytes { raw in
      memcpy(inBuf.audioBufferList.pointee.mBuffers.mData, raw.baseAddress, data.count)
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
    if outBuf.frameLength > 0 {
      playerNode.scheduleBuffer(outBuf)
    }
  }

  func stop() {
    playerNode?.stop()
    engine?.stop()
    playerNode = nil
    engine = nil
    converter = nil
    inputFormat = nil
  }
}

// MARK: - App Delegate

@MainActor
final class CameraViewerDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  var displayLayer: AVSampleBufferDisplayLayer!
  var streamTask: Task<Void, Never>?
  let audioPlayer = AudioPlayer()

  let inputURL: String
  let username: String?
  let password: String?

  init(url: String, username: String?, password: String?) {
    self.inputURL = url
    self.username = username
    self.password = password
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

    let layerRef = DisplayLayerRef(displayLayer)
    let url = inputURL
    let user = username
    let pass = password
    let win = window!
    let audio = audioPlayer

    streamTask = Task.detached {
      await Self.run(
        layerRef: layerRef, window: win, audioPlayer: audio,
        url: url, username: user, password: pass
      )
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool { true }

  func applicationWillTerminate(_ notification: Notification) {
    streamTask?.cancel()
    audioPlayer.stop()
  }

  // MARK: - Main entry (runs off main actor)

  nonisolated static func run(
    layerRef: DisplayLayerRef,
    window: NSWindow,
    audioPlayer: AudioPlayer,
    url: String,
    username: String?,
    password: String?
  ) async {
    var rtspURL = url

    // ONVIF discovery if the URL is HTTP
    if url.lowercased().hasPrefix("http") {
      do {
        let urls = try await discoverStreamURLs(
          deviceService: url, username: username, password: password
        )
        if urls.isEmpty {
          log("ONVIF: no RTSP stream URLs discovered")
          return
        }
        for (i, u) in urls.enumerated() {
          log("ONVIF stream \(i): \(u)")
        }
        rtspURL = urls[0]
        log("Playing first stream: \(rtspURL)")
      } catch {
        log("ONVIF discovery failed: \(error)")
        return
      }
    }

    await stream(
      layerRef: layerRef, window: window, audioPlayer: audioPlayer,
      rtspURL: rtspURL, username: username, password: password
    )
  }

  // MARK: - RTSP Streaming

  nonisolated static func stream(
    layerRef: DisplayLayerRef,
    window: NSWindow,
    audioPlayer: AudioPlayer,
    rtspURL: String,
    username: String?,
    password: String?
  ) async {
    let creds = username.flatMap { u in
      password.map { Credentials(username: u, password: $0) }
    }
    let session = RTSPClientSession(url: rtspURL, credentials: creds)

    do {
      let desc = try await session.start()
      let res = desc.resolution.map { "\($0.width)×\($0.height)" } ?? "?"
      log("Connected: \(desc.videoCodec) \(res)")

      await MainActor.run {
        window.title = "IPCamKit — \(desc.videoCodec) \(res)"
      }

      if let audioCodec = desc.audioCodec, let audioRate = desc.audioSampleRate {
        audioPlayer.start(
          codec: audioCodec, sampleRate: Double(audioRate),
          channels: UInt32(desc.audioChannels ?? 1))
      }

      var fmtDesc = try makeFormatDescription(
        codec: desc.videoCodec,
        sps: desc.sps, pps: desc.pps, vps: desc.vps
      )

      let layer = layerRef.layer
      var receivedKeyframe = false

      for try await item in session.frames() {
        if Task.isCancelled { break }

        switch item {
        case .audio(let audioFrame):
          audioPlayer.enqueue(audioFrame)

        case .video(let frame):
          if let newSPS = frame.sps, let newPPS = frame.pps {
            fmtDesc = try makeFormatDescription(
              codec: desc.videoCodec,
              sps: newSPS, pps: newPPS, vps: frame.vps
            )
          }

          if !receivedKeyframe {
            guard frame.isKeyframe else { continue }
            receivedKeyframe = true
          }

          if let sample = buildSampleBuffer(
            frame, codec: desc.videoCodec, formatDescription: fmtDesc
          ) {
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sample)
          }

        case .rtcp:
          break
        }
      }
    } catch {
      log("Error: \(error)")
    }

    await session.stop()
  }
}

// MARK: - ONVIF Discovery

func discoverStreamURLs(
  deviceService: String,
  username: String?,
  password: String?
) async throws -> [String] {
  // Step 1: GetCapabilities → find the media service URL
  log("ONVIF: GetCapabilities…")
  let capsXML = try await onvifRequest(
    url: deviceService, username: username, password: password,
    body: """
      <GetCapabilities xmlns="http://www.onvif.org/ver10/device/wsdl">
        <Category>Media</Category>
      </GetCapabilities>
      """
  )

  guard let mediaServiceURL = extractTagContent(capsXML, localName: "XAddr")
  else {
    throw OnvifError("GetCapabilities: no Media XAddr found")
  }
  log("ONVIF: Media service at \(mediaServiceURL)")

  // Step 2: GetProfiles → get profile tokens
  log("ONVIF: GetProfiles…")
  let profilesXML = try await onvifRequest(
    url: mediaServiceURL, username: username, password: password,
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
  for token in tokens {
    let uriXML = try await onvifRequest(
      url: mediaServiceURL, username: username, password: password,
      body: """
        <GetStreamUri xmlns="http://www.onvif.org/ver10/media/wsdl">
          <StreamSetup>
            <Stream xmlns="http://www.onvif.org/ver10/schema">RTP-Unicast</Stream>
            <Transport xmlns="http://www.onvif.org/ver10/schema">
              <Protocol>RTSP</Protocol>
            </Transport>
          </StreamSetup>
          <ProfileToken>\(token)</ProfileToken>
        </GetStreamUri>
        """
    )
    if let uri = extractTagContent(uriXML, localName: "Uri") {
      urls.append(uri)
    }
  }

  return urls
}

// MARK: - ONVIF SOAP Transport

func onvifRequest(
  url: String,
  username: String?,
  password: String?,
  body: String
) async throws -> String {
  guard let requestURL = URL(string: url) else {
    throw OnvifError("Invalid URL: \(url)")
  }

  let securityHeader: String
  if let u = username, let p = password {
    securityHeader = wsSecurityHeader(username: u, password: p)
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

  let (data, response) = try await URLSession.shared.data(for: request)

  if let http = response as? HTTPURLResponse, http.statusCode != 200 {
    let body = String(data: data, encoding: .utf8) ?? ""
    throw OnvifError("HTTP \(http.statusCode): \(body.prefix(200))")
  }

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
        <wsse:Username>\(username)</wsse:Username>
        <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digestB64)</wsse:Password>
        <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonceB64)</wsse:Nonce>
        <wsu:Created>\(created)</wsu:Created>
      </wsse:UsernameToken>
    </wsse:Security>
    """
}

// MARK: - Simple XML Helpers

/// Extract the text content of the first element with the given local name,
/// ignoring namespace prefixes. e.g. `<tt:XAddr>http://…</tt:XAddr>` → `http://…`
func extractTagContent(_ xml: String, localName: String) -> String? {
  // Match <prefix:localName> or <localName>, capture content up to closing tag
  let pattern =
    "<(?:[a-zA-Z0-9_-]+:)?\(localName)(?:\\s[^>]*)?>([^<]+)</(?:[a-zA-Z0-9_-]+:)?\(localName)>"
  guard let regex = try? NSRegularExpression(pattern: pattern),
    let match = regex.firstMatch(
      in: xml, range: NSRange(xml.startIndex..., in: xml))
  else { return nil }
  guard let range = Range(match.range(at: 1), in: xml) else { return nil }
  return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Extract all `token="…"` attribute values from `<…:Profiles token="…">` elements.
func extractProfileTokens(_ xml: String) -> [String] {
  let pattern = "<(?:[a-zA-Z0-9_-]+:)?Profiles[^>]+token=\"([^\"]+)\""
  guard let regex = try? NSRegularExpression(pattern: pattern) else {
    return []
  }
  let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
  return matches.compactMap { match in
    guard let range = Range(match.range(at: 1), in: xml) else { return nil }
    return String(xml[range])
  }
}

struct OnvifError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
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

func log(_ msg: String) {
  var m = msg + "\n"
  m.withUTF8 { _ = fwrite($0.baseAddress, 1, $0.count, stderr) }
}

// MARK: - Entry Point

let args = CommandLine.arguments

guard args.count >= 2 else {
  log(
    """
    Usage: CameraViewer <url> [username] [password]

    Examples:
      CameraViewer rtsp://192.168.1.100:554/stream1 admin password
      CameraViewer http://192.168.1.100:2020/onvif/device_service admin password

    An http/https URL triggers ONVIF discovery to find RTSP stream URLs.
    Username and password are optional (used for both RTSP and ONVIF auth).
    """)
  exit(1)
}

let url = args[1]
let user: String? = args.count > 2 ? args[2] : nil
let pass: String? = args.count > 3 ? args[3] : nil

log("Connecting to \(url)…")

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = CameraViewerDelegate(
  url: url, username: user, password: pass
)
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
