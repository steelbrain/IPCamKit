# IPCamKit API Reference

## Quick Start

```swift
import IPCamKit

let session = RTSPClientSession(
  url: "rtsp://192.168.1.100:554/stream1",
  credentials: Credentials(username: "admin", password: "pass"))

let desc = try await session.start()
// desc.video?.codec / .resolution / .sps / .pps / .vps / .clockRate
// desc.audio?.codec / .sampleRate / .channels / .extraData
// desc.metadataEncoding (e.g. "vnd.onvif.metadata")

for try await item in session.frames() {
  switch item {
  case .video(let frame):
    // frame.nalus — raw NAL units (no length prefix)
    _ = frame
  case .audio(let frame):
    // frame.data — raw audio (PCMA/PCMU/AAC/etc.)
    _ = frame
  case .metadata(let frame):
    // frame.data — raw payload; frame.xml — the XML document (gunzipped if needed)
    _ = frame
  case .rtcp:
    break
  }
}

await session.stop()
```

## Core Types

### RTSPClientSession

The main entry point. Manages the full RTSP lifecycle (DESCRIBE, SETUP, PLAY, TEARDOWN).
From a successful `start()` until `stop()` it sends periodic keepalives
(GET_PARAMETER when the server advertises support, otherwise OPTIONS) at
roughly half the negotiated session timeout, so long-running sessions aren't
dropped by the camera, whether or not `frames()` is being iterated and while
paused. A successful keepalive is reported via `onDiagnostic` at `.info`
severity; a failed one (no response, or a non-2xx status) at `.warning`. The
stream keeps running and the next tick retries. A 401 on a keepalive, `play`
or `pause` (a camera that expired its Digest nonce) is answered with the new
challenge, and once more when that retry is refused with `stale=true` and a
new nonce. It isn't answered for a seek that a later seek has already
replaced (that seek's `play()` throws `RTSPError.authenticationFailed`
instead),
after `stop()` sent TEARDOWN, or when the retry would only repeat the
credentials just refused: Basic again, or Digest with the same nonce when
the challenge doesn't say `stale=true`. The next request answers the latest
usable challenge. Requests during `start()` are retried the same way, and a
server offering both Digest and Basic (on any of a request's 401s) that
rejects Digest gets one more try with Basic, unless Basic was already
refused for that request; from then on the session sends Basic. Credentials
refused on the OPTIONS request `start()` sends first end `start()` with
`RTSPError.authenticationFailed`.

PLAY, PAUSE, TEARDOWN and keepalives go to the aggregate control URL: the
SDP's session-level `a=control` resolved against `Content-Base` (RFC 2326
appendix C.1.1), which is the `Content-Base` itself for `a=control:*`.
At most 64 media sections of the SDP are read; the rest are dropped with one
`onDiagnostic` warning. Media sections whose `m=` line is malformed are
skipped and counted apart: each of the first 64 gets a warning, and one more
warning counts the rest. Only the first
1024 attributes of each section (session level included) are read, with one
warning for the rest. `RTP-Info`
entries past twice the stream count (at least 128) are ignored. A `Content-Base`, `Content-Location` or
session `a=control` longer than 8192 bytes is ignored with a warning, and a
media section whose `a=control` is that long is dropped.

`start()` runs once per session; call it again and it throws
`RTSPError.invalidState` (create a new session to reconnect). If it fails, it
closes what it opened, sending TEARDOWN first if the server had already
created a session and the connection is still open (not after
`RTSPError.timeout`, which closes it, or a dropped connection). `stop()`
during `start()` closes the connection at once, without TEARDOWN, and makes
`start()` throw `RTSPError.invalidState`. Cancelling the task awaiting
`start()` also closes the connection at once, without TEARDOWN, and
`start()` throws `CancellationError` rather than waiting out the connect and
request deadlines (15 seconds each); in a task that is already cancelled,
`start()` throws `CancellationError` without connecting. Either way the
session is stopped. Cancelling the task after `start()` has returned doesn't
affect the session. A session released without `stop()`, once no `frames()`
sequence of it remains, stops itself.

`user:password@` in the URL is used as the credentials when `credentials` is
nil, and is removed from every request; when `credentials` is passed, the
URL's user name and password are removed without being read. The user name
runs to the first `:` and the password to the last `@` before the host. Each
is percent-decoded once, whatever else it holds (`admin:P|ss%40word@` and
`admin:£ecret|1@` give the passwords `P|ss@word` and `£ecret|1`), and one
that doesn't decode to UTF-8 (`%FF`) makes `start()` throw
`RTSPError.invalidURL`. Percent-encode `/`, `?`, `#` and `@`
in a user name or password (`%2F`, `%3F`, `%23`, `%40`): a raw `/`, `?` or
`#` ends the host early, and a raw `@` followed by another `@` after the host
ends it at the wrong one, so the URL would name another host. `start()`
rejects a URL with an `@` after its host when the URL also has
`user:password@`, a port on a host name, or any `:` between the host and the
last `@`; in such a URL an `@` in the path or query must be written `%40`
too. An IPv4 address (four decimal numbers) or a bracketed IPv6 address with
a port isn't taken for a user name and password, so stream URIs such as
`rtsp://192.0.2.5:554/live?password=Adm1n@2024`, which ONVIF cameras report,
are accepted. A user name with a raw
`/`, `?` or `#` and no password can't be told from a path, and the URL is read
as host and path. The same check applies to a tunnel URL, which must also write any `@` after
its host as `%40`. These checks read the URL as Unicode scalars, as
`URLComponents` does, so an `@`, `/`, `?`, `#` or `:` followed by a
combining mark still counts. A URL containing a
space or an ASCII control character is rejected, and so is a host name with
any character other than letters, digits, `-`, `.` and `_` (a percent-encoded
one included; IPv6 literals aside). The URL goes into the request line as
ASCII: a Unicode or percent-encoded host name goes as its `xn--` form, and
non-ASCII characters in the path and query are percent-encoded. The rest of
the path and query is sent as written, escapes and characters such as `{` and
`|` included (`/live/a{%20b` is sent as `/live/a{%20b`), whether or not the
URL has a user name or a Unicode host. Control URLs the server gives
(`Content-Base`, SDP `a=control`) are sent as the server wrote them. A
`#fragment` isn't sent. Errors that show the URL or a tunnel URL put `***`
in place of everything from the scheme to the last `@` (or fullwidth `＠`
or small `﹫`), which may be more than the userinfo when the path or query
holds an `@`, and in place of the values of parameters whose names,
percent-decoded and in any case, contain user, pass, pwd, auth, token or
secret, or are usr, pw, psw, loginuse or loginpas (query values up to the
next `&` or `#`; a path segment `/user=…` up to the next `/`, `?` or `#`).

```swift
final class RTSPClientSession: Sendable

init(
  url: String,                         // rtsp:// or rtsps:// (TLS)
  credentials: Credentials? = nil,
  transport: Transport = .tcp,
  tls: TLSOptions = .default,          // rtsps:// URLs and https/wss tunnels
  tunnel: RTSPTunnel? = nil,           // RTSP over HTTP or WebSocket
  onvif: ONVIFFeatures = [],           // .replay, .backchannel
  userAgent: String = "IPCamKit",
  onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)? = nil)

func start(_ play: PlayOptions = PlayOptions()) async throws -> SessionDescription
func frames() -> AsyncThrowingStream<PublicCodecItem, Error>
func play(_ options: PlayOptions) async throws   // seek, speed, resume
func pause() async throws
func sendBackchannelAudio(
  _ payload: Data, samples: UInt32? = nil, startsTalkspurt: Bool = false) async throws
func stop() async
```

One `frames()` sequence can be iterated at a time: a second concurrent one
throws `RTSPError.invalidState`, and so does a second task asking the same
sequence for a frame while another task waits on it. When the consumer's task
is cancelled, or the consumer breaks out of its loop and the sequence is
released (a variable still holding it keeps it), the next `frames()` call
continues the stream; items still waiting when the sequence was released, and
frames that arrive before the next `frames()` call, are dropped, and the next
frame of each kind counts them in its `loss`. Frames that arrive between `start()` and the first
`frames()` call are kept for it: the newest 256 items, up to 32 MiB. The
session keeps reading until then, so a session whose `frames()` is never
iterated (two-way audio only) doesn't stall the camera. Delivery is bounded:
once 256 items or 32 MiB are waiting, the session stops reading the TCP
connection until the consumer catches up (with UDP or multicast, datagrams
wait instead, at most 4096 of them and 8 MiB, past which the oldest are
dropped). Responses to `play`, `pause`, keepalives and
`stop` are still read while the consumer lags; while one is awaited, items
beyond 4096 or 64 MiB are dropped, oldest first, with a warning. A `frames()`
sequence iterated before `start()` has returned ends at once without an
error; call `frames()` after `start()`. After `stop()`, `frames()` delivers the
items already waiting and then ends.

The `url` host may be a hostname, an IPv4 literal, or a bracketed IPv6 literal
(`rtsp://[2001:db8::1]:554/stream`) — including link-local addresses with a zone
id. Both IPv4 and IPv6 cameras work over either transport.

An `rtsps://` URL connects over TLS, on port 322 unless the URL names one, and
`tls` selects how the server certificate is verified. With `Transport.tcp`,
RTP/RTCP is interleaved inside the TLS connection. With `.udp` or `.multicast`
the media is SRTP (`RTP/SAVP`): SETUP carries a MIKEY key message in a
`KeyMgmt` header (RFC 4567, pre-shared key mode), and packets are decrypted
and authenticated with AES-CM-128 and HMAC-SHA1 (RFC 3711; an 80-bit tag, or
the 32-bit tag a server's key message may choose) using the keys
from the server's `KeyMgmt` response or SDP `a=key-mgmt`. Packets that fail
authentication are dropped; the first such SRTP packet and the first such
SRTCP packet of each stream are reported via `onDiagnostic`. A replayed
packet (a duplicate or one too late for the replay window) is dropped
without a report. A failed TLS
handshake makes `start()` throw `RTSPError.connectionFailed`, whose `underlying`
is Network's `.tls` error, with a message that
begins `TLS handshake failed:`. When the certificate was rejected (Network
reports OSStatus -9808, `errSSLBadCert`), it reads `TLS handshake failed: server
certificate rejected by TLSOptions.serverTrust (OSStatus -9808)`. A server that
aborts the handshake after the client has finished its part, as a TLS 1.3
server that requires a client certificate does (IPCamKit sends none), fails
`start()` the same way as soon as its alert arrives. A TLS error after the
server has sent data is reported as `RTSPError.connectionFailed` with a message
that begins `TLS connection failed:`.

### TLSOptions

Server-certificate verification for `rtsps://` URLs and `https://`/`wss://`
tunnels.

```swift
struct TLSOptions: Sendable {
  enum ServerTrust: Sendable {
    case system                                  // default
    case pinned([CertificateFingerprint])
    case custom(@Sendable (SecTrust) -> Bool)
  }
  var serverTrust: ServerTrust
  init(serverTrust: ServerTrust = .system)
  static let `default`: TLSOptions             // .system
}
```

- `.system`: the platform's default evaluation. The chain must lead to a root
  the system trusts, the certificates must be within their validity dates, and
  the leaf must name the URL host (DNS name or IP address, without the zone id
  of a link-local IPv6 address). Self-signed camera certificates fail it unless
  installed as trusted on the device.
- `.pinned`: accept the server only if its leaf certificate's SHA-256
  fingerprint is in the list. Chain, validity dates and host name are not
  checked. Use this for self-signed certificates.
- `.custom`: your closure gets the server's `SecTrust`, which holds the
  presented certificates and an SSL policy for the URL host (without an IPv6
  zone id), and returns whether to continue. It runs synchronously on a private
  serial queue during the handshake, and the 15-second connect timeout keeps
  running meanwhile.

Trusting a private CA with `.custom`:

```swift
let tls = TLSOptions(serverTrust: .custom { trust in
  SecTrustSetAnchorCertificates(trust, [myCA] as CFArray)
  SecTrustSetAnchorCertificatesOnly(trust, true)
  return SecTrustEvaluateWithError(trust, nil)
})
```

### CertificateFingerprint

The SHA-256 digest of a DER-encoded certificate, the value
`openssl x509 -noout -fingerprint -sha256` prints after `SHA256 Fingerprint=`
(the label is `sha256 Fingerprint=` in some builds; pass only the part after `=` to `init?(hex:)`).

```swift
struct CertificateFingerprint: Sendable, Hashable, CustomStringConvertible {
  let sha256: Data                    // 32 bytes
  init?(sha256: Data)                 // nil unless 32 bytes
  init?(hex: String)                  // "09:1B:14:…" or "091b14…"; colons/whitespace ignored
  init(certificate: SecCertificate)
  var description: String { get }     // "09:1B:14:…", openssl's format
}
```

To get a camera's fingerprint:

```sh
openssl s_client -connect 192.168.1.100:322 </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256
```

### RTSPDiagnostic

Non-fatal anomalies observed during a session (e.g. cameras deviating from spec). The
stream stays alive; the callback is purely observational. `severity == .error` here
means real damage (e.g. dropped data) but the stream continues — distinct from a
thrown `RTSPError`, which means the stream is dead.

```swift
struct RTSPDiagnostic: Sendable {
  enum Severity: Sendable { case info, warning, error }
  let severity: Severity
  let message: String
  init(severity: Severity, message: String)
}
```

### Credentials

```swift
struct Credentials: Sendable
let username: String
let password: String
init(username: String, password: String)
```

### Transport

```swift
enum Transport: Sendable {
  case tcp        // RTP interleaved over the RTSP connection (inside TLS for rtsps://)
  case udp        // RTP/RTCP on an even/odd UDP port pair (SRTP for rtsps://)
  case multicast  // RTP/RTCP from the group and ports the server assigns at SETUP
}
```

TCP and UDP work over IPv4 and IPv6 peers. With `.udp` and `.multicast`,
datagrams up to the UDP maximum (65,507 bytes over IPv4) are received
whole, so a server that sends RTP packets larger than the path MTU (relying
on IP fragmentation) works too. An ICMP error an earlier datagram drew (port or
host unreachable, as from a camera not yet listening on its RTCP port, or
fragmentation needed) doesn't stop a UDP port. With `.multicast`, SETUP sends
`Transport: RTP/AVP;multicast` (`RTP/SAVP;multicast` for `rtsps://`) and the
session joins the `destination` group
on the `port` pair from the response. Receiving multicast on iOS, tvOS and
visionOS requires the `com.apple.developer.networking.multicast` entitlement.
Two-way audio isn't set up with `.multicast`.

### RTSPTunnel

```swift
enum RTSPTunnel: Sendable {
  case http(URL)       // http:// or https://
  case webSocket(URL)  // ws:// or wss://
}
```

Carries the RTSP connection, and the RTP interleaved on it, through HTTP or a
WebSocket. Requires `Transport.tcp`; `start()` throws
`RTSPError.invalidState` otherwise. The session's `url` is still the RTSP URL
used inside the tunnel. HTTPS and WSS verify the server with the session's
`tls` options. The tunnel URL alone decides whether the connection is
encrypted, so an `rtsps://` URL requires an `https://` or `wss://` tunnel;
with `http://` or `ws://`, `start()` throws `RTSPError.invalidState`. A 401
on the GET (or the WebSocket upgrade) is answered with the session's
credentials by the same rules as a request during `start()`, each attempt on
a new connection, and the POST carries the same credentials.

- `.http`: QuickTime-style RTSP over HTTP. A GET connection carries server
  data and a POST connection carries base64-encoded client requests, paired by
  an `x-sessioncookie` header.
- `.webSocket`: RTSP over WebSocket as in the ONVIF Streaming Specification,
  subprotocol `rtsp.onvif.org`. ONVIF devices report the URL in the Media2
  service capabilities (`RTSPWebSocketUri`).

## ONVIF Extensions

### ONVIFFeatures

```swift
struct ONVIFFeatures: OptionSet, Sendable, Hashable {
  let rawValue: Int
  init(rawValue: Int)
  static let replay       // Require: onvif-replay
  static let backchannel  // Require: www.onvif.org/ver20/backchannel
}
```

Requested features are sent as a `Require` header on DESCRIBE, SETUP, PLAY
and PAUSE. A server that answers DESCRIBE with `551 Option not supported`
fails `start()` with `RTSPError.sessionSetupFailed(statusCode: 551, ...)`,
except for `.backchannel`: the session then repeats DESCRIBE without it and,
when that succeeds, reports a warning via `onDiagnostic` and continues
without two-way audio. A 551 to the repeat (for `.replay`) fails `start()`.

### Replay

Use the replay URI from the ONVIF Replay service (`GetReplayUri`) with
`onvif: .replay`:

```swift
let session = RTSPClientSession(url: replayURI, credentials: creds, onvif: .replay)
let desc = try await session.start(PlayOptions(range: .clock(start: recordingStart)))
// desc.range — the recording's span from the SDP, e.g. .clock(start:end:)

for try await item in session.frames() {
  if case .video(let frame) = item, let replay = frame.replay {
    // replay.time — when the frame was recorded
    // replay.isCleanPoint, .isEndOfSection, .isDiscontinuity, .isTerminal
  }
}

// From another task while frames() is running:
try await session.play(PlayOptions(range: .clock(start: later), immediate: true))  // seek
try await session.play(PlayOptions(scale: -1, immediate: true))                    // reverse
try await session.pause()
try await session.play(PlayOptions())                                              // resume
```

`scale` must be from 0.000001 to 1000 in magnitude, and is sent with up to
six decimal places. For zero, NaN, an infinity or a value outside that range,
`start(_:)` and `play(_:)` throw `RTSPError.invalidState` before sending
anything.

```swift
struct PlayOptions: Sendable {
  var range: PlaybackRange?    // nil: first PLAY sends npt=0.000-, later ones no Range
  var scale: Double?           // Scale: 2.0 = double speed, -1.0 = reverse; |scale| 0.000001...1000
  var rateControl: Bool        // false sends Rate-Control: no (as fast as possible)
  var frames: FrameFilter      // Frames header
  var immediate: Bool          // true sends Immediate: yes
  init(range:scale:rateControl:frames:immediate:)   // defaults: nil, nil, true, .all, false
}

enum PlaybackRange: Sendable, Equatable {
  case npt(start: Double, end: Double? = nil)   // npt=10.000-
  case clock(start: Date, end: Date? = nil)     // clock=20250101T120000.000Z-
}

enum FrameFilter: Sendable, Equatable {
  case all                      // no Frames header
  case intra                    // Frames: intra
  case intraEvery(Duration)     // Frames: intra/<milliseconds>
  case intraAndPredicted        // Frames: predicted
}

struct ReplayInfo: Sendable, Equatable {
  let time: Date                // recording time (NTP timestamp in the RTP header extension)
  let isCleanPoint: Bool        // C: the frame starts at a key frame
  let isEndOfSection: Bool      // E: last frame of a contiguous recorded section
  let isDiscontinuity: Bool     // D: data missing before this frame
  let isTerminal: Bool          // T: last frame of the playback
  init(time: Date, isCleanPoint: Bool, isEndOfSection: Bool, isDiscontinuity: Bool,
       isTerminal: Bool)
}
```

`SessionDescription.range` reads the SDP `a=range` in the `npt=` and
`clock=` forms RFC 2326 and RFC 7826 define, and is nil for anything else
(`npt=now-`, an end-only range, `smpte=`, or a malformed value). An npt time
is digits only: seconds (`12.5`) or `h:mm:ss[.frac]` with one or two digits
of minutes and seconds, each below 60; a sign, exponent or hex digits make
it malformed. A clock time is `YYYYMMDDThhmmss[.frac]Z` with a date that
exists, in years 0001 to 9999 (proleptic Gregorian), seconds below 60
except 23:59:60 (a leap second, read as the next midnight), and at most 9
fraction digits, as RFC 7826 allows. Spaces may surround the value and the
`=`, but not a time or the `-`.

`replay` is read from the ONVIF replay RTP header extension (profile
`0xABAC`). A frame whose packets carried no extension of their own, such as
the second AAC frame of an aggregated packet, gets the time of the previous
extension advanced by the RTP timestamp difference, with all flags false.

A PLAY with a `range` or `immediate: true` is a seek: reassembly restarts.
ONVIF replay servers tag packets with the low byte of the PLAY request's
CSeq (every packet, or the first packet of each frame), so until a packet of
the new PLAY arrives, packets with any other CSeq, and the untagged packets
that follow them, are discarded. Once packets with the extension have
arrived, a PLAY's CSeq skips values whose low byte one of the latest PLAYs
used. Packets without the extension are held until
the PLAY response (over UDP and multicast, the response takes effect after the
datagrams that arrived before it, as on TCP); then those before their stream's
first new sequence
number (the response's RTP-Info `seq`) are discarded, and without RTP-Info
they can't be told apart and are delivered. If more than 1000 such packets
arrive after a seek's PLAY response, the session stops filtering until the
next seek and reports a warning; untagged packets with the RTP timestamp of
their stream's last packet carrying an older CSeq (the rest of its frame)
aren't counted. Frames already waiting for `frames()` when `play()`
is called are still delivered first. `timestamp` values continue across
seeks, with every stream's new playback starting at the same time; use
`replay.time` for the recording position. If the server rejects a seek, the
packets of the playback in flight are kept while the PLAY is outstanding and
queued for `frames()` when `play()` throws (up to 4096 packets or 8 MiB;
beyond that, packets with the replay extension count as `loss` and the
others go to the new playback). With
`rateControl: false`, use `Transport.tcp` so that a slow consumer slows the
server instead of losing datagrams.

`play()` and `pause()` also work without `onvif`, against any server that
supports PAUSE and `Range`. While a PAUSE awaits its response, and from its
success until a later `play()` succeeds, a TCP session (plain, TLS or
tunneled) sends no RTCP receiver reports, because some servers close a
paused connection that carries interleaved data, and `sendBackchannelAudio`
throws `RTSPError.invalidState` on any transport. A `pause()` that throws an
`RTSPError` (rejected, or no response) leaves the session as it was.

When the task awaiting `play()` or `pause()` is cancelled, the call throws
`CancellationError` at once instead of waiting for the response (up to 10
seconds). A request not yet sent isn't sent. One already sent can't be taken
back, so the session follows the server's answer as if the caller had
waited: an accepted PAUSE pauses it, an accepted seek moves the playback, and
a rejected seek is rolled back when the rejection arrives. A 401 to it isn't
answered.

### Two-way audio

```swift
let session = RTSPClientSession(url: url, credentials: creds, onvif: .backchannel)
let desc = try await session.start()
if let back = desc.backchannel, back.codec == .pcmu {
  // 20 ms of 8 kHz mono PCM per packet
  try await session.sendBackchannelAudio(G711.encodeMuLaw(pcmSamples))
}
```

```swift
struct BackchannelStream: Sendable {
  let codec: PublicAudioCodec      // what the camera accepts
  let clockRate: UInt32
  let channels: UInt16?
  let payloadType: UInt8
  let formatSpecificParams: String?
}
```

The session sets up the first audio stream the camera's SDP marks
`a=sendonly` (ONVIF marks streams from the client's side: `recvonly` for
streams the client receives, `sendonly` for the one it sends) whose format it
can packetize (G.711, G.722, G.726, L16 or AAC, with format parameters it
accepts). If every stream is marked
`sendonly`, none is treated as a backchannel. Setup is
best-effort: when the camera offers no backchannel, its codec isn't
supported, or its SETUP is rejected, `desc.backchannel` is nil and
`onDiagnostic` says why. A SETUP that gets no answer within the setup timeout
(15 seconds) makes `start()` throw `RTSPError.timeout`, as for audio and
metadata.

`sendBackchannelAudio(_:samples:startsTalkspurt:)` takes audio already encoded in the
backchannel's codec, packetizes it into RTP and sends it on the session's
transport (interleaved TCP, UDP, or SRTP for `rtsps://` over UDP). The RTP
timestamp advances by `samples`, or by the duration the codec implies.
Call it from one task, in order, at the rate the audio plays. Pass
`startsTalkspurt: true` for the first chunk after a pause (push-to-talk
pressed again): the RTP timestamp moves forward by the time that passed
beyond the audio already sent, and the chunk's first packet carries the RTP
marker bit, as does the session's first chunk. For AAC the marker keeps its
RFC 3640 meaning (the last packet of each access unit) and only the
timestamp moves. The skip has no upper limit: a silence longer than 2^31
ticks (12 hours at 48 kHz) moves the timestamp by its length modulo 2^32.
When the calling task is cancelled, the call throws `CancellationError` and
sends no more of its chunk.

### G711

```swift
enum G711 {
  static func encodeMuLaw(_ samples: [Int16]) -> Data
  static func encodeALaw(_ samples: [Int16]) -> Data
  static func decodeMuLaw(_ data: Data) -> [Int16]
  static func decodeALaw(_ data: Data) -> [Int16]
}
```

## Session Description

Returned by `start()` with stream metadata parsed from SDP.

At least one of `video`, `audio`, `metadataEncoding` or `backchannel` is non-`nil`; a session with zero usable streams is rejected at `start()`. A session whose only usable stream is the ONVIF backchannel has all of `video`, `audio` and `metadataEncoding` nil.

```swift
struct SessionDescription: Sendable {
  let video: VideoStream?
  let audio: AudioStream?
  let metadataEncoding: String?                // e.g. "vnd.onvif.metadata"
  let backchannel: BackchannelStream?          // with onvif: .backchannel
  let range: PlaybackRange?                    // SDP a=range, npt or clock
}

struct VideoStream: Sendable {
  let codec: VideoCodec
  let clockRate: UInt32
  let sps: Data?                               // from SDP sprop-*; nil without
  let pps: Data?
  let vps: Data?                               // H.265 only
  let resolution: (width: Int, height: Int)?
}

struct AudioStream: Sendable {
  let codec: PublicAudioCodec
  let sampleRate: UInt32                       // RTP clock rate; 16000 for G.722
  let channels: UInt16?
  let extraData: Data?                         // AudioSpecificConfig for AAC; else nil
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
enum PublicAudioCodec: Sendable, Hashable {
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
  case metadata(PublicMetadataFrame)
  case rtcp(PublicRTCPPacket)
}
```

### PublicVideoFrame

One raw NAL unit per `nalus` element, starting with the NAL header: no AVCC
length prefix and no Annex B start code. To build a VideoToolbox sample, write
each NAL's length as a 4-byte big-endian integer before it, as
`Examples/CameraViewer` does. Parameter sets sent in-band appear in `nalus` too.

```swift
struct PublicVideoFrame: Sendable {
  let nalus: [Data]         // Raw NAL units, no length prefix
  let timestamp: Double     // Presentation timestamp in seconds
  let isKeyframe: Bool      // H.264 IDR, or H.265 IDR/CRA/BLA (IRAP)
  let loss: UInt16          // RTP packets lost (and frames dropped) before this one
  let sps: Data?            // Non-nil when they differ from the last delivered,
                            // and on the first frame of each later frames() sequence
  let pps: Data?
  let vps: Data?            // H.265 only
  let replay: ReplayInfo?   // ONVIF replay only
}
```

### PublicAudioFrame

Raw codec-specific audio data (e.g. G.711 A-law samples, AAC AU).

```swift
struct PublicAudioFrame: Sendable {
  let data: Data            // Raw audio bytes
  let timestamp: Double     // Presentation timestamp in seconds
  let codec: PublicAudioCodec
  let sampleRate: UInt32    // as AudioStream.sampleRate
  let channels: UInt16?
  let loss: UInt16          // RTP packets lost (and packets/AUs/frames dropped) before this one
  let replay: ReplayInfo?   // ONVIF replay only
}
```

### PublicMetadataFrame

One document from an ONVIF analytics-metadata RTP stream. The session sets up
streams with encoding `vnd.onvif.metadata` (XML), `vnd.onvif.metadata.gzip`
(gzip-compressed XML), `vnd.onvif.metadata.exi.onvif` or
`vnd.onvif.metadata.exi.ext` (EXI).

```swift
struct PublicMetadataFrame: Sendable {
  let data: Data            // Raw payload (depacketized across RTP fragments)
  let timestamp: Double     // Presentation timestamp in seconds
  let encodingName: String  // e.g. "vnd.onvif.metadata"
  let loss: UInt16          // RTP packets lost (and frames dropped) before this frame
  let xml: Data?            // The XML document; nil for EXI or a failed gunzip
  let replay: ReplayInfo?   // ONVIF replay only
}
```

`xml` is `data` for plain metadata and the decompressed `data` for gzip. EXI
is not decoded: `xml` is nil and `data` holds the EXI stream. A gzip payload
that fails to decompress also leaves `xml` nil and is reported once via
`onDiagnostic`.

### PublicRTCPPacket

```swift
struct PublicRTCPPacket: Sendable {
  let timestamp: Double?
  let data: Data
}
```

## Errors

```swift
enum RTSPError: Error, Sendable, CustomStringConvertible, LocalizedError {
  // localizedDescription == description
  case invalidURL(String)            // the URL or tunnel URL can't be used
  case connectionFailed(String, underlying: NWError? = nil)
  case authenticationFailed
  case sessionSetupFailed(statusCode: Int, reason: String)
  case transportNegotiationFailed
  case unexpectedDisconnection
  case timeout
  case invalidSDP(String)
  case depacketizationError(String)
  case invalidState(String)          // API misuse, e.g. a tunnel with .udp
}
```

`invalidURL` means `start()` can't use the stream URL or the tunnel URL, and
nothing was sent: a scheme other than `rtsp`/`rtsps` (`http`/`https` or
`ws`/`wss` for a tunnel), no host or a host that isn't a valid name, a bad
port, a space or control character, an `@` after the host that may end a
password, or a user name or password that isn't percent-encoded UTF-8. The
message names the problem; the URL in it has its credentials hidden.

`connectionFailed` means the connection couldn't be opened, or failed after
it was. `underlying` is the Network framework error behind it, when there is
one: `.dns` for a name that didn't resolve (`cam.invalid` gives
`.dns(-65554)`, NoSuchRecord), `.posix` for a refused or unreachable host or
another socket error (`.posix(.ECONNREFUSED)`, `.posix(.EHOSTUNREACH)`,
`.posix(.ECONNRESET)`; UDP and multicast socket errors too), and `.tls` for a
failed TLS handshake or connection. It is nil for failures that don't come
from the network, such as an HTTP tunnel or WebSocket upgrade the server
refused, or an RTSP message that never ends.

## Advanced Types

These are exposed for advanced use cases (custom RTSP flows, SDP inspection, etc.)
but are not needed for typical streaming.

### RTSP Messages

```swift
enum RTSPMethod: String, Sendable {
  case options = "OPTIONS", describe = "DESCRIBE", announce = "ANNOUNCE",
       setup = "SETUP", play = "PLAY", pause = "PAUSE", record = "RECORD",
       teardown = "TEARDOWN", getParameter = "GET_PARAMETER",
       setParameter = "SET_PARAMETER"
}

struct RTSPRequest: Sendable {
  var method: RTSPMethod
  var url: String
  var version: String               // default "RTSP/1.0"
  var headers: [(String, String)]
  var body: Data
  init(method: RTSPMethod, url: String, version: String = "RTSP/1.0",
       headers: [(String, String)] = [], body: Data = Data())
  func header(_ name: String) -> String?
  mutating func setHeader(_ name: String, value: String)
}

struct RTSPResponse: Sendable {
  var statusCode: UInt16
  var reasonPhrase: String
  var version: String
  var headers: [(String, String)]
  var body: Data
  var cseq: UInt32? { get }         // from the headers
  var contentLength: Int? { get }
  var contentType: String? { get }
  init(statusCode: UInt16, reasonPhrase: String, version: String = "RTSP/1.0",
       headers: [(String, String)] = [], body: Data = Data())
  func header(_ name: String) -> String?
  func headers(named name: String) -> [String]
}

struct RTSPInterleavedData: Sendable {
  var channelId: UInt8
  var data: Data
  init(channelId: UInt8, data: Data)
}

enum RTSPMessage: Sendable {
  case response(RTSPResponse)
  case data(RTSPInterleavedData)
}
```

### RTSP Parser / Serializer

```swift
struct RTSPParser: Sendable {
  init()
  // Requests the server sends are consumed and skipped.
  func parse(_ buffer: inout Data) throws -> (RTSPMessage, Int)?
}

struct RTSPSerializer: Sendable {
  init()
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
  var bandwidth: String?
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
  init(name: String, value: String? = nil)
}

struct SDPParser: Sendable {
  init()
  func parse(_ data: Data) throws -> SDPSession
  func parse(_ text: String) throws -> SDPSession
}
```

### Presentation

Parsed SDP media streams and control URLs, used internally by `RTSPClientSession`.
Foundation also declares a `Stream` class, so in a file that imports
Foundation write `IPCamKit.Stream`.

```swift
struct Presentation: Sendable {
  var streams: [Stream]
  let baseURL: String
  var control: String
  var tool: String?
  var range: String?             // SDP a=range: session level, else the first parsed stream's that has one
  init(streams: [Stream], baseURL: String, control: String, tool: String? = nil,
       range: String? = nil)
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
  var direction: MediaDirection? // a=sendonly/recvonly/sendrecv/inactive
  var videoParameters: VideoParameters? { get }  // parsed from the fmtp
  init(media: String, encodingName: String, rtpPayloadType: UInt8, clockRateHz: UInt32,
       channels: UInt16? = nil, framerate: Float? = nil, control: String? = nil,
       formatSpecificParams: String? = nil, direction: MediaDirection? = nil)
}

enum MediaDirection: String, Sendable {
  case sendOnly = "sendonly"     // in an ONVIF backchannel SDP: the stream the client sends
  case receiveOnly = "recvonly"
  case sendReceive = "sendrecv"
  case inactive
}
```

### Video Parameters

```swift
struct VideoParameters: Sendable, Equatable {
  let rfc6381Codec: String       // e.g. "avc1.640033"
  let pixelDimensions: (width: UInt16, height: UInt16)?
  let pixelAspectRatio: (h: UInt32, v: UInt32)?
  let frameRate: (num: UInt32, den: UInt32)?  // seconds per frame: num/den (fps = den/num)
  let codecParams: VideoParametersCodec
  let extraData: Data            // AVC (H.264) or HEVC (H.265) decoder configuration record
}

enum VideoParametersCodec: Sendable, Equatable {
  case h264(sps: Data, pps: Data)
  case h265(vps: Data, sps: Data, pps: Data)
  case jpeg
}
```

### Timestamps

```swift
struct Timestamp: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  let timestamp: Int64
  let clockRate: UInt32
  let start: UInt32
  var elapsed: Int64 { get }
  var elapsedSeconds: Double { get }
  init?(timestamp: Int64, clockRate: UInt32, start: UInt32)
  func adding(_ delta: UInt32) -> Timestamp?
}

struct NtpTimestamp: Sendable, Equatable, Comparable, CustomStringConvertible,
  CustomDebugStringConvertible {
  let rawValue: UInt64
  init(rawValue: UInt64)
  var date: Date { get }
}

struct WallTime: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  let date: Date
  init()
  init(date: Date)
  static func now() -> WallTime
}
```

### Context Types

```swift
struct ConnectionContext: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  let localAddr: String
  let peerAddr: String
  let establishedWall: WallTime
  init(localAddr: String, peerAddr: String, establishedWall: WallTime)
  static func dummy() -> ConnectionContext
}

struct RtspMessageContext: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible {
  let pos: UInt64
  let receivedWall: WallTime
  let received: ContinuousClock.Instant
  init(pos: UInt64, receivedWall: WallTime, received: ContinuousClock.Instant)
  static func dummy() -> RtspMessageContext
}

enum StreamContext: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  case tcp(TcpStreamContext)
  case udp(UdpStreamContext)
  case dummy
}

struct TcpStreamContext: Sendable {
  let rtpChannelId: UInt8          // RTCP channel id is one higher
  init(rtpChannelId: UInt8)
}

struct UdpStreamContext: Sendable, CustomStringConvertible {
  let localIP: String
  let peerIP: String
  let localRtpPort: UInt16         // RTCP port is one higher
  let peerRtpPort: UInt16
  init(localIP: String, peerIP: String, localRtpPort: UInt16, peerRtpPort: UInt16)
}

enum PacketContext: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  case tcp(RtspMessageContext)
  case udp(receivedWall: WallTime)
  case dummy
}
```

### Setup / Options

The session parses SETUP and OPTIONS responses into these types internally;
no public API creates or returns them.

```swift
struct SetupResponse: Sendable {
  var session: SessionHeader
  var ssrc: UInt32?
  var channelId: UInt8?
  var source: String?
  var serverPort: UInt16?
  var destination: String?       // multicast group
  var multicastPort: UInt16?     // multicast RTP port; RTCP is one higher
  var ttl: UInt8?
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
