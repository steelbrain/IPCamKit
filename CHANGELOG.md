# Changelog

## 0.3.2

### Fixes

- Only include `algorithm=` in the RTSP Digest `Authorization` header when the
  camera's challenge specified one. Since 0.3.0 it was always sent (defaulting
  to `MD5`), which Reolink cameras (e.g. TrackMix PoE) reject with 401.
- Correct the `PublicVideoFrame.nalus` documentation (#9). Each element is one
  raw NAL unit with no AVCC length prefix, which is what the API has always
  returned; it was documented as length-prefixed. To build a VideoToolbox
  sample, write each NAL's 4-byte big-endian length before it. Runtime
  behavior is unchanged.

## 0.3.1

### Fixes

- Fall back to RTSP Basic authentication when a camera advertises both Digest
  and Basic but rejects Digest. Fixes TP-Link RTSP servers that offer Digest
  in `WWW-Authenticate` but only accept Basic for authenticated requests.

## 0.3.0

### Breaking changes

- `SessionDescription` now groups video and audio fields into `VideoStream?` and `AudioStream?` substructs. Replaces the flat `videoCodec` / `sps` / `pps` / `clockRate` / `audioCodec` / `audioSampleRate` / `audioChannels` / `audioExtraData` fields. A session is valid as long as any one of video, audio, or analytics metadata is set up — audio-only and metadata-only RTSP configurations (e.g. Axis cameras with `video=0`) now work end-to-end. Consumers branch on `desc.video != nil` (or `desc.audio != nil`) before configuring their decoders.

### New

- ONVIF analytics metadata stream support (`vnd.onvif.metadata` per the ONVIF Streaming Specification). Surfaced as `PublicCodecItem.metadata(PublicMetadataFrame)` in the `session.frames()` stream, with discoverability via `SessionDescription.metadataEncoding`. Best-effort: malformed metadata SDP or a failed application SETUP degrades to a diagnostic without aborting video/audio.
- Real UDP transport for RTP/RTCP. Selecting `Transport.udp` now streams end-to-end over an Apple Network-framework socket pair (an even RTP port and the consecutive odd RTCP port, negotiated via `client_port`), replacing the earlier non-functional scaffolding. A best-effort NAT hole-punch is sent toward the peer after `PLAY`.
- IPv6 support on both transports. The RTSP control connection and the UDP RTP/RTCP pair work over IPv6 peers, and a bracketed IPv6 literal in the URL host (e.g. `rtsp://[2001:db8::1]:554/stream`) is parsed correctly.
- Automatic RTSP session keepalive while streaming: sends `GET_PARAMETER` when the server advertises support, otherwise `OPTIONS`, at roughly half the negotiated session timeout, so long-running sessions aren't dropped by the camera. Each round-trip is reported via `onDiagnostic` at `.info` severity.

### Improvements

- Add visionOS 1.0 to supported platforms
- Make the `ntpUnixEpoch` constant private. It was accidentally exposed as a public top-level symbol but is only used internally; consumers should not have relied on it.
- Add a connect timeout to the RTSP TCP transport so an unreachable or refused camera fails fast instead of hanging. `NWConnection` parks refused/unreachable peers in `.waiting`, which previously burned the full timeout; these now surface the real cause after a short grace window.
- Surface transport-level failures that previously stalled or died silently: a terminal UDP receive error (e.g. an ICMP port-unreachable from a NAT'd camera) is now reported via `onDiagnostic` instead of letting the receive loop die quietly.
- Broaden `onDiagnostic` coverage of the drop/recover paths — interleaved data on an unnegotiated channel, FU-reassembly anomalies, audio/metadata SETUP or init failures, sprop parameter-set parse fallback, interleaved media a camera streams before its `PLAY` response completes, and SDP streams that fail to parse while others succeed. Each condition is rate-limited to fire once so a misbehaving camera can't flood the consumer.
- Live integration test suite: drives `RTSPClientSession` end-to-end against an `ffmpeg`-published stream relayed by `mediamtx`, exercising H.264/H.265/AAC over both RTSP-interleaved TCP and UDP, including IPv6. CI installs `ffmpeg` and `mediamtx`.

### Fixes

- Audio depacketizer init failures now null out the audio stream state (index, encoding name, clock rate, channels), mirroring the metadata-init failure path. Previously the indices stayed set while the depacketizer was nil; packets on that channel were silently dropped by the dispatch loop but `SessionDescription` could still claim the stream existed. Required to keep the "at least one usable stream" guard honest in audio-only sessions.
- Stop the codec, SDP, and RTSP parsers from trapping (crashing the process) on malformed or hostile input — out-of-range reads, bad lengths, and truncated buffers now error or are tolerated instead of aborting.
- Don't tear down the stream on a single bad packet; the packet is dropped and streaming continues.
- Bound depacketizer memory and reset depacketizer state on failure, so a malformed stream can't grow memory without limit.
- Validate the RTCP sender-report SSRC before anchoring the RTP/NTP timeline, so a stray report can't corrupt timestamps.
- Tolerate sloppy SDP and lenient H.265 `fmtp` from real cameras (Postel's law) instead of rejecting the session, and make AAC depacketization tolerant of real-camera deviations.
- Harden the session lifecycle and SETUP tolerance.
- Strengthen RTSP Digest authentication: escape quoted-string parameters correctly and fix the 401 retry path.
- Harden the H.265 depacketizer and parameter-set parsing against malformed input.
- Fix and harden H.264 SPS parsing.
- Harden RTP packet and context handling, and saturate loss counters to avoid overflow traps.
- Harden the RTSP parsers against malformed server input, and harden the session start path.
- Fix the static L16 payload clock rate to 44100 Hz.
- Ignore the RTP MARK bit on H.264 SEI packets (some cameras set it on a trailing SEI, splitting the access unit early).
- Tolerate a complete (un-fragmented) NAL that arrives inside an FU wrapper instead of erroring.
- Accept a scheme-less `Content-Base` header by resolving it against the request URL.
- Normalize audio frame data to a standalone `Data`.

## 0.2.0

### Breaking changes

- Remove `SessionIdPolicy` enum and the `sessionIdPolicy:` parameter from `RTSPClientSession.init`. Audio SETUP responses that return a different session ID are now always accepted (latest wins) instead of being a configurable choice.

### New

- `onDiagnostic` callback on `RTSPClientSession.init` for observing non-fatal anomalies (e.g. cameras deviating from spec). Emits `RTSPDiagnostic` values with `info` / `warning` / `error` severity. Initial events:
  - `warning` when a camera issues a different Session ID at audio SETUP than at video SETUP.
  - `warning` when an empty video RTP payload is received and skipped.
  - `warning` when an out-of-order RTP packet is received on TCP-interleaved transport (and dropped).

### Improvements

- Add iOS 16, tvOS 16, and macCatalyst 16 to supported platforms (Thanks @brientim)
- Lower macOS minimum from 14 to 13

### Fixes

- Stop tearing down the video stream when a camera emits an empty (or, for H.265, sub-2-byte) RTP payload. Such packets are now skipped — matches GStreamer / Live555 behavior.
- Stop tearing down the session when an out-of-order RTP packet arrives on TCP-interleaved transport. Packet is now dropped to match UDP behavior, matching FFmpeg / GStreamer / Live555 / ExoPlayer (none of which abort on this case). TCP byte-stream ordering does not imply RTP-sequence ordering — buggy camera packetizers can write packets out-of-order before muxing.

## 0.1.1

### Improvements

- Use `memchr` for zero-byte scanning in H.264 depacketizer for better performance

## 0.1.0

Initial release.

### Features

- **RTSP session management** — full DESCRIBE, SETUP, PLAY, TEARDOWN lifecycle via `RTSPClientSession`
- **RTSP message parsing and serialization** — request/response framing, interleaved data, header handling
- **SDP parsing** — media descriptions, codec parameter extraction, control URL resolution
- **RTP/RTCP** — packet parsing (RFC 3550), 32-bit timestamp wraparound, sequence tracking, loss detection, TCP interleaved channel mapping
- **H.264 depacketization** (RFC 6184) — Single NAL, FU-A, STAP-A, Annex B processing
- **H.265/HEVC depacketization** (RFC 7798) — Single NAL, AP, FU (SRST mode), full SPS/PPS/VPS parsing, HEVCDecoderConfigurationRecord
- **AAC depacketization** (RFC 3640) — AAC-hbr mode, aggregation, fragmentation, AudioSpecificConfig parsing
- **Simple audio** — PCMU, PCMA, L16, G.722, G.726, DVI4 pass-through
- **G.723.1 depacketization** — frame size validation (24/20/4 bytes)
- **Authentication** — Basic and Digest (MD5) via CryptoKit
- **Transport** — TCP interleaved and UDP via NWConnection
- **Output format** — AVCC (4-byte length-prefixed NAL units) ready for VideoToolbox
- **Camera quirk handling** — Reolink, Dahua, Hikvision, Longse, GW Security, VStarcam, Tenda, Foscam, and others
- **CameraViewer example app** — live video display with audio playback, ONVIF stream discovery
- **90 tests** across 15 suites ported from the upstream Rust test suite
