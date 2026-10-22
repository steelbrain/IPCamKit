# IPCamKit

A pure-Swift RTSP client library for streaming live video and audio from IP cameras.

- **H.264 and H.265/HEVC video** — depacketized into individual NAL units for VideoToolbox
- **Audio** — AAC, PCMU, PCMA, G.722, G.726, L16, G.723.1
- **ONVIF analytics metadata** — raw XML documents from the camera's `application` RTSP stream
- **Optional streams** — any combination of video / audio / metadata is supported; audio-only or metadata-only sessions (e.g. Axis `video=0`) work end-to-end
- **TCP & UDP transport** — RTP/RTCP over RTSP-interleaved TCP or a dedicated UDP socket pair, over IPv4 or IPv6
- **Zero dependencies** — built only on Apple system frameworks (Foundation, Network, CryptoKit)
- **Swift 6** — strict concurrency with async/await and AsyncThrowingStream

## Requirements

- macOS 13.0+, iOS 16.0+, tvOS 16.0+, Mac Catalyst 16.0+, visionOS 1.0+
- Swift 6.0+

## Installation

Add IPCamKit as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/steelbrain/IPCamKit.git", from: "0.3.1"),
]
```

Then add it to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: ["IPCamKit"]
),
```

## Usage

```swift
import IPCamKit

let session = RTSPClientSession(
    url: "rtsp://192.168.1.100:554/stream",
    credentials: Credentials(username: "admin", password: "password"),
    transport: .tcp
)

// Connect and get stream metadata
let desc = try await session.start()
// desc.video, desc.audio, desc.metadataEncoding — at least one is non-nil
//   desc.video?.codec / .clockRate / .sps / .pps / .vps / .resolution
//   desc.audio?.codec / .sampleRate / .channels / .extraData

if let video = desc.video {
    // configure a video decoder (VideoToolbox, etc.)
}

// Consume depacketized frames
for try await item in session.frames() {
    switch item {
    case .video(let frame):
        // frame.nalus — raw NAL units; prefix each with its 4-byte
        //   big-endian length to build a VideoToolbox sample
        // frame.isKeyframe, frame.timestamp, frame.loss
        // frame.sps, frame.pps, frame.vps — non-nil when parameters change
        break
    case .audio(let frame):
        // frame.data — raw audio bytes (codec-specific)
        // frame.codec, frame.sampleRate, frame.channels, frame.timestamp
        break
    case .metadata(let frame):
        // frame.data — raw payload (typically ONVIF XML, possibly GZIP-compressed)
        // frame.encodingName, frame.timestamp, frame.loss
        break
    case .rtcp:
        break
    }
}

// Disconnect
await session.stop()
```

See [API.md](API.md) for the full API reference.

## Features

### Video
- H.264 depacketization (RFC 6184): Single NAL, FU-A, STAP-A
- H.265/HEVC depacketization (RFC 7798): Single NAL, AP, FU (SRST mode)
- Output as raw NAL units, one per array element (no length prefixes or start codes)

### Audio
- AAC (RFC 3640) with aggregation and fragmentation
- PCMU (G.711 u-law), PCMA (G.711 A-law), L16, G.722, G.726, DVI4, G.723.1

### Metadata
- ONVIF analytics metadata (`vnd.onvif.metadata`) per the ONVIF Streaming Specification
- Concatenates RTP payload fragments and emits a frame on the marker bit (end-of-document)
- Best-effort: malformed metadata SDP degrades to a diagnostic without aborting video/audio

### Protocol
- RTSP session management (DESCRIBE, SETUP, PLAY, TEARDOWN)
- RTSP message parsing and serialization
- SDP parsing with codec parameter extraction
- RTP packet parsing (RFC 3550) with sequence tracking and loss detection
- RTSP authentication (Basic and Digest with MD5)
- Automatic session keepalive while streaming (GET_PARAMETER when the server
  advertises it, else OPTIONS) so long sessions aren't dropped at the timeout
- Transport: TCP interleaved and UDP, over IPv4 or IPv6

### Compatibility
- Tested with Reolink, Dahua, Hikvision, Longse, GW Security, VStarcam, Tenda, Foscam, and others
- Handles real-world camera quirks (non-standard SDP, inline parameter sets, unusual framing)

## Example App

The included `CameraViewer` example displays a live camera feed with audio playback:

```bash
swift run -c release CameraViewer rtsp://192.168.1.100:554/stream1 admin password
```

The example app also supports ONVIF discovery — pass an HTTP device service URL to auto-discover RTSP streams:

```bash
swift run -c release CameraViewer http://192.168.1.100:2020/onvif/device_service admin password
```

## Architecture

```
Sources/IPCamKit/
├── RTSP/           RTSP message model, parser, serializer
├── SDP/            SDP session description parser (RFC 8866)
├── RTP/            RTP/RTCP packets, Timeline, ChannelMapping, InorderParser
├── Codec/          H.264/H.265 depacketizers, NAL/SPS/PPS parsing, audio + metadata depacketizers
├── Auth/           Basic and Digest authentication
├── Transport/      Network-framework RTSP/TCP control + UDP RTP/RTCP socket pair (IPv4/IPv6)
└── Client/         RTSP session, DESCRIBE/SETUP/PLAY parsers, Presentation
```

## Testing

165+ tests across 18 suites covering RTSP parsing, SDP, RTP, H.264/H.265 depacketization, AAC, simple audio, ONVIF metadata depacketization, authentication, and the full pipeline:

```bash
swift test
```

The **live integration suite** drives the real `RTSPClientSession` end to end: `ffmpeg`
publishes a synthetic H.264/H.265/AAC stream to a [mediamtx](https://github.com/bluenviron/mediamtx)
RTSP server, and the client pulls it back over both RTSP-interleaved TCP and UDP. Both tools
must be on `PATH`:

```bash
brew install ffmpeg mediamtx
```

## License

MIT — see [LICENSE](LICENSE) for details.

## Acknowledgements

See [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).
