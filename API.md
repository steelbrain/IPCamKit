# IPCamKit API Reference

## Quick Start

```swift
import IPCamKit

let session = RTSPClientSession(
  url: "rtsp://192.168.1.100:554/stream1",
  credentials: Credentials(username: "admin", password: "pass"))

let desc = try await session.start()
// desc.videoCodec, desc.resolution, desc.audioCodec, etc.

for try await item in session.frames() {
  switch item {
  case .video(let frame):
    // frame.nalus — AVCC NAL units for VideoToolbox
  case .audio(let frame):
    // frame.data — raw audio (PCMA/PCMU/AAC/etc.)
  case .rtcp:
    break
  }
}

await session.stop()
```

## Core Types

### RTSPClientSession

The main entry point. Manages the full RTSP lifecycle (DESCRIBE, SETUP, PLAY, TEARDOWN).

```swift
final class RTSPClientSession: Sendable

init(
  url: String,
  credentials: Credentials? = nil,
  transport: Transport = .tcp,
  sessionIdPolicy: SessionIdPolicy = .defaultPolicy,
  userAgent: String = "IPCamKit")

func start() async throws -> SessionDescription
func frames() -> AsyncThrowingStream<PublicCodecItem, Error>
func stop() async
```

### Credentials

```swift
struct Credentials: Sendable
init(username: String, password: String)
```

### Transport

```swift
enum Transport: Sendable {
  case tcp   // RTP interleaved over RTSP TCP connection
  case udp   // RTP/RTCP on separate UDP ports
}
```

### SessionIdPolicy

```swift
enum SessionIdPolicy: Sendable {
  case defaultPolicy   // Currently requireMatch
  case requireMatch    // Same session ID for all SETUP requests
  case useFirst        // Use first SETUP session ID, ignore changes
}
```

## Session Description

Returned by `start()` with stream metadata parsed from SDP.

```swift
struct SessionDescription: Sendable {
  let videoCodec: VideoCodec
  let sps: Data
  let pps: Data
  let vps: Data?                               // H.265 only
  let resolution: (width: Int, height: Int)?
  let clockRate: UInt32

  let audioCodec: PublicAudioCodec?
  let audioSampleRate: UInt32?
  let audioChannels: UInt16?
  let audioExtraData: Data?                    // e.g. AudioSpecificConfig for AAC
}
```

### VideoCodec

```swift
enum VideoCodec: Sendable {
  case h264
  case h265
}
```

### PublicAudioCodec

```swift
enum PublicAudioCodec: Sendable {
  case aac
  case pcmu
  case pcma
  case g722
  case g723
  case l16
  case other(String)
}
```

## Frames

### PublicCodecItem

```swift
enum PublicCodecItem: Sendable {
  case video(PublicVideoFrame)
  case audio(PublicAudioFrame)
  case rtcp(PublicRTCPPacket)
}
```

### PublicVideoFrame

NAL units in AVCC format (4-byte big-endian length prefix), ready for VideoToolbox.

```swift
struct PublicVideoFrame: Sendable {
  let nalus: [Data]         // NAL units (AVCC format)
  let timestamp: Double     // Presentation timestamp in seconds
  let isKeyframe: Bool      // IDR frame
  let loss: UInt16          // RTP packets lost before this frame
  let sps: Data?            // Non-nil when parameters change
  let pps: Data?
  let vps: Data?            // H.265 only
}
```

### PublicAudioFrame

Raw codec-specific audio data (e.g. G.711 A-law samples, AAC AU).

```swift
struct PublicAudioFrame: Sendable {
  let data: Data            // Raw audio bytes
  let timestamp: Double     // Presentation timestamp in seconds
  let codec: PublicAudioCodec
  let sampleRate: UInt32    // Hz
  let channels: UInt16?
  let loss: UInt16          // RTP packets lost before this frame
}
```

### PublicRTCPPacket

```swift
struct PublicRTCPPacket: Sendable {
  let timestamp: Double?
  let data: Data
}
```

## Errors

```swift
enum RTSPError: Error, Sendable {
  case connectionFailed(String)
  case authenticationFailed
  case sessionSetupFailed(statusCode: Int, reason: String)
  case transportNegotiationFailed
  case unexpectedDisconnection
  case timeout
  case invalidSDP(String)
  case depacketizationError(String)
}
```

## Advanced Types

These are exposed for advanced use cases (custom RTSP flows, SDP inspection, etc.)
but are not needed for typical streaming.

### RTSP Messages

```swift
enum RTSPMethod: String, Sendable {
  case options, describe, announce, setup, play,
       pause, record, teardown, getParameter, setParameter
}

struct RTSPRequest: Sendable {
  var method: RTSPMethod
  var url: String
  var version: String               // default "RTSP/1.0"
  var headers: [(String, String)]
  var body: Data
  func header(_ name: String) -> String?
  mutating func setHeader(_ name: String, value: String)
}

struct RTSPResponse: Sendable {
  var statusCode: UInt16
  var reasonPhrase: String
  var version: String
  var headers: [(String, String)]
  var body: Data
  var cseq: UInt32?
  var contentLength: Int?
  var contentType: String?
  func header(_ name: String) -> String?
  func headers(named name: String) -> [String]
}

struct RTSPInterleavedData: Sendable {
  var channelId: UInt8
  var data: Data
}

enum RTSPMessage: Sendable {
  case response(RTSPResponse)
  case data(RTSPInterleavedData)
}
```

### RTSP Parser / Serializer

```swift
struct RTSPParser: Sendable {
  func parse(_ buffer: inout Data) throws -> (RTSPMessage, Int)?
}

struct RTSPSerializer: Sendable {
  func serialize(_ request: RTSPRequest) -> Data
  func serializeInterleaved(_ data: RTSPInterleavedData) -> Data
}
```

### SDP

```swift
struct SDPSession: Sendable {
  var version: Int
  var origin: String?
  var sessionName: String?
  var connectionInfo: String?
  var timing: String?
  var attributes: [SDPAttribute]
  var mediaDescriptions: [SDPMediaDescription]
  func attribute(_ name: String) -> SDPAttribute?
  func attributes(named name: String) -> [SDPAttribute]
}

struct SDPMediaDescription: Sendable {
  var media: String              // "video", "audio", etc.
  var port: UInt16
  var proto: String              // "RTP/AVP", etc.
  var fmt: String                // Payload type numbers
  var connectionInfo: String?
  var bandwidth: String?
  var attributes: [SDPAttribute]
  func attribute(_ name: String) -> SDPAttribute?
  func attributes(named name: String) -> [SDPAttribute]
}

struct SDPAttribute: Sendable, Equatable {
  var name: String
  var value: String?
}

struct SDPParser: Sendable {
  func parse(_ data: Data) throws -> SDPSession
  func parse(_ text: String) throws -> SDPSession
}
```

### Presentation

Parsed SDP media streams and control URLs, used internally by `RTSPClientSession`.

```swift
struct Presentation: Sendable {
  var streams: [Stream]
  let baseURL: String
  var control: String
  var tool: String?
}

struct Stream: Sendable {
  let media: String
  let encodingName: String       // lowercase: "h264", "pcmu", etc.
  let rtpPayloadType: UInt8
  let clockRateHz: UInt32
  let channels: UInt16?
  let framerate: Float?
  let control: String?
  let formatSpecificParams: String?
  var videoParameters: VideoParameters?
}
```

### Video Parameters

```swift
struct VideoParameters: Sendable, Equatable {
  let rfc6381Codec: String       // e.g. "avc1.640033"
  let pixelDimensions: (width: UInt16, height: UInt16)?
  let pixelAspectRatio: (h: UInt32, v: UInt32)?
  let frameRate: (num: UInt32, den: UInt32)?
  let codecParams: VideoParametersCodec
  let extraData: Data            // AVCDecoderConfiguration record
}

enum VideoParametersCodec: Sendable, Equatable {
  case h264(sps: Data, pps: Data)
  case h265(vps: Data, sps: Data, pps: Data)
  case jpeg
}
```

### Timestamps

```swift
struct Timestamp: Sendable, Equatable {
  let timestamp: Int64
  let clockRate: UInt32
  let start: UInt32
  var elapsed: Int64
  var elapsedSeconds: Double
  init?(timestamp: Int64, clockRate: UInt32, start: UInt32)
  func adding(_ delta: UInt32) -> Timestamp?
}

struct NtpTimestamp: Sendable, Equatable, Comparable {
  let rawValue: UInt64
  var date: Date
}

struct WallTime: Sendable, Equatable {
  let date: Date
  init()
  init(date: Date)
  static func now() -> WallTime
}
```

### Context Types

```swift
struct ConnectionContext: Sendable {
  let localAddr: String
  let peerAddr: String
  let establishedWall: WallTime
}

struct RtspMessageContext: Sendable, Equatable {
  let pos: UInt64
  let receivedWall: WallTime
  let received: ContinuousClock.Instant
}

enum StreamContext: Sendable {
  case tcp(TcpStreamContext)
  case udp(UdpStreamContext)
  case dummy
}

enum PacketContext: Sendable {
  case tcp(RtspMessageContext)
  case udp(receivedWall: WallTime)
  case dummy
}
```

### Setup / Options

```swift
struct SetupResponse: Sendable {
  var session: SessionHeader
  var ssrc: UInt32?
  var channelId: UInt8?
  var source: String?
  var serverPort: UInt16?
}

struct SessionHeader: Sendable {
  var id: String
  var timeoutSec: UInt32
}

struct OptionsResponse: Sendable {
  var setParameterSupported: Bool
  var getParameterSupported: Bool
}
```
