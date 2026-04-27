# Changelog

## 0.2.0

### Breaking changes

- Remove `SessionIdPolicy` enum and the `sessionIdPolicy:` parameter from `RTSPClientSession.init`. Audio SETUP responses that return a different session ID are now always accepted (latest wins) instead of being a configurable choice.

### Improvements

- Add iOS 16, tvOS 16, and macCatalyst 16 to supported platforms (Thanks @brientim)
- Lower macOS minimum from 14 to 13

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
