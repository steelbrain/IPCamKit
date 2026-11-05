# IPCamKit

A pure-Swift RTSP client library for streaming live video and audio from IP cameras.

- **H.264 and H.265/HEVC video**, depacketized into raw NAL units for VideoToolbox
- **Audio**: AAC (including HE-AAC), PCMU, PCMA, G.722, G.726, L16, U8, DVI4, G.723.1
- **ONVIF analytics metadata**: XML documents from the camera's `application` stream, gunzipped when compressed
- **ONVIF replay**: play recordings from an absolute time, seek, pause, change speed or play backwards, with the recording time on every frame
- **Two-way audio** over the ONVIF backchannel (G.711, G.722, G.726, L16, AAC)
- **Any combination of streams**: audio-only and metadata-only sessions work too
- **Transports**: RTP/RTCP over RTSP-interleaved TCP, UDP or multicast, over IPv4 or IPv6; RTSP tunneled over HTTP or WebSocket
- **RTSP over TLS** (`rtsps://`), with SRTP for UDP and multicast; the certificate is checked by the system trust store, a pinned SHA-256 fingerprint, or your own `SecTrust` evaluation
- **Authentication**: Basic, and Digest with MD5, SHA-256 and their `-sess` variants
- **Long sessions**: keepalives while streaming, and RTCP receiver reports over TCP and UDP
- **No dependencies** beyond Apple system frameworks; Swift 6 strict concurrency with async/await

Tested with Reolink, Dahua, Hikvision, Longse, GW Security, VStarcam, Tenda, Foscam and others.

## Requirements

- macOS 13.0+, iOS 16.0+, tvOS 16.0+, Mac Catalyst 16.0+, visionOS 1.0+
- Swift 6.0+

## Installation

Add IPCamKit as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/steelbrain/IPCamKit.git", from: "0.3.2"),
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
// desc.video, desc.audio, desc.metadataEncoding, desc.backchannel — at least one is non-nil
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
        // frame.sps, frame.pps, frame.vps — non-nil when they differ from
        //   the last ones delivered (at first, desc.video's), and on the
        //   first frame of each later frames() sequence
        break
    case .audio(let frame):
        // frame.data — raw audio bytes (codec-specific)
        // frame.codec, frame.sampleRate, frame.channels, frame.timestamp
        break
    case .metadata(let frame):
        // frame.xml — the ONVIF XML document (decompressed for gzip encodings)
        // frame.data — raw payload; frame.encodingName, frame.timestamp, frame.loss
        break
    case .rtcp:
        break
    }
}

// Disconnect
await session.stop()
```

### RTSP over TLS

An `rtsps://` URL connects over TLS (port 322 unless the URL names one). With
`transport: .tcp` (the default) RTP is interleaved inside the encrypted
connection; with `.udp` or `.multicast` it is SRTP, keyed through the TLS
connection. By default the certificate must be trusted by the system, which
a camera's self-signed certificate is not unless you installed it as trusted.
Pin that certificate's SHA-256 fingerprint instead:

```swift
// openssl s_client -connect 192.168.1.100:322 </dev/null 2>/dev/null \
//   | openssl x509 -noout -fingerprint -sha256
// prints "SHA256 Fingerprint=09:1B:14:…" (the label is lowercase in some builds);
// pass the part after "=".
let pin = CertificateFingerprint(hex: "09:1B:14:16:2B:2F:C7:B0:50:30:B7:9A:EB:AF:60:A2:16:07:6E:3C:AE:1C:39:3B:C9:EE:73:BD:90:B7:DF:C0")!

let session = RTSPClientSession(
    url: "rtsps://192.168.1.100:322/stream",
    credentials: Credentials(username: "admin", password: "password"),
    tls: TLSOptions(serverTrust: .pinned([pin]))
)
```

`TLSOptions.ServerTrust.custom` hands you the server's `SecTrust` to decide
yourself, for example to trust a private CA. See [API.md](API.md#tlsoptions).

### ONVIF replay

Pass the replay URI from the camera's or recorder's ONVIF Replay service
(`GetReplayUri`) and ask for the `onvif-replay` extension:

```swift
let session = RTSPClientSession(url: replayURI, credentials: creds, onvif: .replay)
_ = try await session.start(PlayOptions(range: .clock(start: recordingStart)))

let reader = Task {
    for try await item in session.frames() {
        if case .video(let frame) = item {
            // frame.replay?.time — when this frame was recorded
        }
    }
}

try await session.play(PlayOptions(range: .clock(start: later), immediate: true))  // seek
try await session.play(PlayOptions(scale: 4, frames: .intra, immediate: true))     // fast forward
try await session.pause()
```

### Two-way audio

```swift
let session = RTSPClientSession(url: url, credentials: creds, onvif: .backchannel)
let desc = try await session.start()
if desc.backchannel?.codec == .pcmu {
    try await session.sendBackchannelAudio(G711.encodeMuLaw(samples))  // [Int16], 8 kHz mono
}
```

### Tunnels

When only HTTP(S) reaches the camera, tunnel RTSP through it:

```swift
let session = RTSPClientSession(
    url: "rtsp://192.168.1.100/stream",
    tunnel: .http(URL(string: "http://192.168.1.100:80/stream")!))
// or .webSocket(URL(string: "wss://192.168.1.100/rtsp-over-websocket")!)
```

See [API.md](API.md) for the full API reference.

## Example App

`CameraViewer` (macOS) shows a live H.264 or H.265 feed and plays G.711 and
L16 audio. Pass an RTSP URL, or an ONVIF device service URL to discover the
camera's streams:

```bash
swift run -c release CameraViewer rtsp://192.168.1.100:554/stream1 admin password
swift run -c release CameraViewer http://192.168.1.100:2020/onvif/device_service admin password
```

Options include `--transport`, `--tunnel`, `--tls-sha256`, `--replay`/`--scale`
and `--talk` (hold Space to talk); run it without arguments for the full list.

## Testing

```bash
swift test
```

The live integration suites stream from a real [mediamtx](https://github.com/bluenviron/mediamtx)
server fed by `ffmpeg`, over every transport, TLS and tunnel. They need both on `PATH`:

```bash
brew install ffmpeg mediamtx
```

## License

MIT — see [LICENSE](LICENSE) for details.

## Acknowledgements

See [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).
