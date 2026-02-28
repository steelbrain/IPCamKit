# IPCamKit

A pure-Swift RTSP client library for streaming live video and audio from IP cameras.

- **H.264 and H.265/HEVC video** — depacketized to AVCC format, ready for VideoToolbox
- **Audio** — AAC, PCMU, PCMA, G.722, G.726, L16, G.723.1
- **Zero dependencies** — only Foundation, Network, and CryptoKit
- **Swift 6** — strict concurrency with async/await and AsyncThrowingStream

## Requirements

- macOS 14.0+
- Swift 6.0+

## Installation

Add IPCamKit as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/steelbrain/IPCamKit.git", from: "0.1.0"),
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
// desc.videoCodec, desc.resolution, desc.sps, desc.pps, desc.vps
// desc.audioCodec, desc.audioSampleRate, desc.audioChannels

// Consume depacketized frames
for try await item in session.frames() {
    switch item {
    case .video(let frame):
        // frame.nalus — AVCC-format NAL units (ready for VideoToolbox)
        // frame.isKeyframe, frame.timestamp, frame.loss
        // frame.sps, frame.pps, frame.vps — non-nil when parameters change
        break
    case .audio(let frame):
        // frame.data — raw audio bytes (codec-specific)
        // frame.codec, frame.sampleRate, frame.channels, frame.timestamp
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
- Output in AVCC format (4-byte length-prefixed NAL units) ready for VideoToolbox

### Audio
- AAC (RFC 3640) with aggregation and fragmentation
- PCMU (G.711 u-law), PCMA (G.711 A-law), L16, G.722, G.726, DVI4, G.723.1

### Protocol
- RTSP session management (DESCRIBE, SETUP, PLAY, TEARDOWN)
- RTSP message parsing and serialization
- SDP parsing with codec parameter extraction
- RTP packet parsing (RFC 3550) with sequence tracking and loss detection
- RTSP authentication (Basic and Digest with MD5)
- Transport: TCP interleaved and UDP

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
├── Codec/          H.264/H.265 depacketizers, NAL/SPS/PPS parsing, audio depacketizers
├── Auth/           Basic and Digest authentication
├── Transport/      NWConnection TCP/UDP transport
└── Client/         RTSP session, DESCRIBE/SETUP/PLAY parsers, Presentation
```

## Testing

90 tests across 15 suites covering RTSP parsing, SDP, RTP, H.264/H.265 depacketization, AAC, simple audio, authentication, and integration:

```bash
swift test
```

## License

MIT — see [LICENSE](LICENSE) for details.

## Acknowledgements

See [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).
