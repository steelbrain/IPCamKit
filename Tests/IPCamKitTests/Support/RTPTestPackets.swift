// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// RTP/RTCP packet, H.264 NAL, and SDP builders for tests against FakeRTSPServer

import Foundation

// MARK: - RTP

/// Build an RTP packet (RFC 3550): version 2, no padding, no CSRCs.
///
/// When `extensionProfile` or `extensionData` is given, the X bit is set and a
/// header extension follows the fixed header: the 16-bit profile, the 16-bit
/// length in 32-bit words, then `extensionData` zero-padded to a multiple of 4
/// bytes. A missing profile defaults to 0 and missing data to an empty
/// extension (length 0).
func makeRTP(
  sequence: UInt16,
  timestamp: UInt32,
  ssrc: UInt32,
  payloadType: UInt8,
  marker: Bool,
  payload: Data,
  extensionProfile: UInt16? = nil,
  extensionData: Data? = nil
) -> Data {
  let hasExtension = extensionProfile != nil || extensionData != nil
  var packet = Data(capacity: 12 + payload.count + (extensionData?.count ?? 0) + 8)
  packet.append(0x80 | (hasExtension ? 0x10 : 0))
  packet.append((marker ? 0x80 : 0) | (payloadType & 0x7F))
  appendBigEndian(sequence, to: &packet)
  appendBigEndian(timestamp, to: &packet)
  appendBigEndian(ssrc, to: &packet)
  if hasExtension {
    var body = extensionData ?? Data()
    let padding = (4 - body.count % 4) % 4
    body.append(contentsOf: [UInt8](repeating: 0, count: padding))
    let words = body.count / 4
    precondition(words <= Int(UInt16.max), "RTP header extension too long: \(words) words")
    appendBigEndian(extensionProfile ?? 0, to: &packet)
    appendBigEndian(UInt16(words), to: &packet)
    packet.append(body)
  }
  packet.append(payload)
  return packet
}

/// Build the ONVIF replay RTP header extension (ONVIF Streaming Specification,
/// "RTP header extension"): profile `0xABAC`, 3 words of data laid out as the
/// 64-bit NTP timestamp, one flags byte (C `0x80`, E `0x40`, D `0x20`,
/// T `0x10`, low 4 bits zero), the CSeq byte, then 2 zero padding bytes.
///
/// Pass the result to `makeRTP(extensionProfile:extensionData:)`.
func onvifReplayExtension(
  ntp: UInt64,
  cleanPoint: Bool,
  endOfSection: Bool,
  discontinuity: Bool,
  terminal: Bool,
  cseq: UInt8
) -> (profile: UInt16, data: Data) {
  var data = Data(capacity: 12)
  appendBigEndian(ntp, to: &data)
  var flags: UInt8 = 0
  if cleanPoint { flags |= 0x80 }
  if endOfSection { flags |= 0x40 }
  if discontinuity { flags |= 0x20 }
  if terminal { flags |= 0x10 }
  data.append(flags)
  data.append(cseq)
  data.append(contentsOf: [0, 0])
  return (0xABAC, data)
}

/// Seconds between the NTP epoch (1900-01-01) and the Unix epoch (1970-01-01).
let ntpUnixEpochOffsetSeconds: Int64 = 2_208_988_800

/// 64-bit NTP timestamp for `date`: seconds since 1900-01-01 UTC in the high 32
/// bits (NTP era 0, so the value wraps after 2036-02-07) and the binary
/// fraction of a second in the low 32 bits.
func ntpTimestamp(for date: Date) -> UInt64 {
  let unixSeconds = date.timeIntervalSince1970
  let whole = unixSeconds.rounded(.down)
  let fraction = unixSeconds - whole
  let seconds = UInt32(truncatingIfNeeded: Int64(whole) + ntpUnixEpochOffsetSeconds)
  let fractionBits = UInt32(min(fraction * 4_294_967_296.0, 4_294_967_295.0))
  return UInt64(seconds) << 32 | UInt64(fractionBits)
}

/// Build a minimal RTCP Sender Report (RFC 3550 section 6.4.1) with no report
/// blocks: 28 bytes, `PT=200`, `length=6`.
func makeRTCPSenderReport(
  ssrc: UInt32,
  ntp: UInt64,
  rtpTimestamp: UInt32,
  packetCount: UInt32 = 0,
  octetCount: UInt32 = 0
) -> Data {
  var packet = Data(capacity: 28)
  packet.append(0x80)
  packet.append(200)
  appendBigEndian(UInt16(6), to: &packet)
  appendBigEndian(ssrc, to: &packet)
  appendBigEndian(ntp, to: &packet)
  appendBigEndian(rtpTimestamp, to: &packet)
  appendBigEndian(packetCount, to: &packet)
  appendBigEndian(octetCount, to: &packet)
  return packet
}

/// Append `value` to `data` in network byte order.
private func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
  withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
}

// MARK: - H.264

/// Valid H.264 SPS (High profile, level 5.1, 640x360) as a raw NAL unit, the
/// same bytes `IntegrationTests` decodes.
let h264TestSPS = Data([
  0x67, 0x64, 0x00, 0x33, 0xAC, 0x15, 0x14, 0xA0, 0xA0, 0x2F, 0xF9, 0x50,
])

/// PPS matching `h264TestSPS`, as a raw NAL unit.
let h264TestPPS = Data([0x68, 0xEE, 0x3C, 0xB0])

/// An IDR slice (NAL type 5) as a raw NAL unit. Not decodable video; enough for
/// the depacketizer to mark the access unit as a keyframe.
let h264TestIDRSlice = Data([0x65, 0x88, 0x84, 0x00, 0x4E, 0xFF, 0xFE, 0xF8])

/// A non-IDR slice (NAL type 1, `nal_ref_idc` 2) as a raw NAL unit.
let h264TestNonIDRSlice = Data([0x41, 0x9A, 0x02, 0x03, 0x04])

/// The NAL units of one H.264 access unit, each usable as a single-NAL-unit RTP
/// payload: SPS, PPS, and IDR for a keyframe; one non-IDR slice otherwise.
func h264AccessUnit(keyframe: Bool) -> [Data] {
  keyframe ? [h264TestSPS, h264TestPPS, h264TestIDRSlice] : [h264TestNonIDRSlice]
}

/// Packetize one access unit in single-NAL-unit mode: one RTP packet per NAL,
/// consecutive sequence numbers from `firstSequence`, a shared `timestamp`, and
/// the marker bit on the last packet only.
func h264RTPPackets(
  nalus: [Data],
  firstSequence: UInt16,
  timestamp: UInt32,
  ssrc: UInt32,
  payloadType: UInt8 = 96
) -> [Data] {
  nalus.enumerated().map { offset, nal in
    makeRTP(
      sequence: firstSequence &+ UInt16(truncatingIfNeeded: offset),
      timestamp: timestamp,
      ssrc: ssrc,
      payloadType: payloadType,
      marker: offset == nalus.count - 1,
      payload: nal)
  }
}

/// Hands out RTP packets for one stream with consecutive sequence numbers and a
/// timestamp that advances once per access unit. Seed it from the stream's
/// `FakeRTPStreamParameters` so the packets match the SETUP `ssrc` and PLAY
/// `RTP-Info` the fake server advertised.
struct RTPTestSequencer: Sendable {
  /// Sequence number of the next packet.
  var sequence: UInt16
  /// RTP timestamp of the next access unit.
  var timestamp: UInt32
  let ssrc: UInt32
  let payloadType: UInt8

  init(sequence: UInt16, timestamp: UInt32, ssrc: UInt32, payloadType: UInt8 = 96) {
    self.sequence = sequence
    self.timestamp = timestamp
    self.ssrc = ssrc
    self.payloadType = payloadType
  }

  init(parameters: FakeRTPStreamParameters, payloadType: UInt8 = 96) {
    self.init(
      sequence: parameters.initialSequence, timestamp: parameters.initialRTPTime,
      ssrc: parameters.ssrc, payloadType: payloadType)
  }

  /// Packetize one access unit (one packet per payload, marker on the last),
  /// then advance `sequence` past it and `timestamp` by `timestampIncrement`.
  /// `rtpExtension` (e.g. from `onvifReplayExtension`) goes on the first packet
  /// only, or on every packet with `extensionOnAllPackets`.
  mutating func accessUnit(
    _ payloads: [Data],
    timestampIncrement: UInt32,
    rtpExtension: (profile: UInt16, data: Data)? = nil,
    extensionOnAllPackets: Bool = false
  ) -> [Data] {
    var packets: [Data] = []
    for (offset, payload) in payloads.enumerated() {
      let ext = offset == 0 || extensionOnAllPackets ? rtpExtension : nil
      packets.append(
        makeRTP(
          sequence: sequence, timestamp: timestamp, ssrc: ssrc, payloadType: payloadType,
          marker: offset == payloads.count - 1, payload: payload,
          extensionProfile: ext?.profile, extensionData: ext?.data))
      sequence &+= 1
    }
    timestamp &+= timestampIncrement
    return packets
  }
}

// MARK: - SDP

/// A complete SDP document: the session-level lines (`v=`, `o=`, `s=`, `c=`,
/// `t=`, `a=control:*`, then `sessionAttributes` as `a=` lines) followed by the
/// given media sections. Lines end with CRLF.
func makeTestSDP(
  media: [String],
  sessionName: String = "IPCamKit Fake Camera",
  sessionAttributes: [String] = []
) -> String {
  var lines = [
    "v=0",
    "o=- 1 1 IN IP4 127.0.0.1",
    "s=\(sessionName)",
    "c=IN IP4 0.0.0.0",
    "t=0 0",
    "a=control:*",
  ]
  lines += sessionAttributes.map { "a=\($0)" }
  return lines.map { $0 + "\r\n" }.joined() + media.joined()
}

/// SDP media section for an H.264 stream whose `sprop-parameter-sets` carry
/// `h264TestSPS`/`h264TestPPS` (`m=video 0 RTP/AVP <pt>`, `H264/90000`,
/// `packetization-mode=1`). `control` is relative to the server's
/// `Content-Base`. CRLF-terminated.
func h264VideoMediaSDP(
  control: String = "video", payloadType: UInt8 = 96, recvonly: Bool = false
) -> String {
  let sprop = "\(h264TestSPS.base64EncodedString()),\(h264TestPPS.base64EncodedString())"
  var lines = [
    "m=video 0 RTP/AVP \(payloadType)",
    "a=rtpmap:\(payloadType) H264/90000",
    "a=fmtp:\(payloadType) packetization-mode=1;profile-level-id=640033;"
      + "sprop-parameter-sets=\(sprop)",
    "a=control:\(control)",
  ]
  if recvonly { lines.append("a=recvonly") }
  return lines.map { $0 + "\r\n" }.joined()
}

/// SDP media section for a G.711 mu-law audio stream (`m=audio 0 RTP/AVP 0`,
/// `PCMU/8000`). `direction` is emitted as its own attribute (`recvonly` for
/// camera-to-client audio, `sendonly` for an ONVIF backchannel), or omitted
/// when `nil`. CRLF-terminated.
func pcmuAudioMediaSDP(control: String = "audio", direction: String? = "recvonly") -> String {
  var lines = [
    "m=audio 0 RTP/AVP 0",
    "a=rtpmap:0 PCMU/8000",
    "a=control:\(control)",
  ]
  if let direction { lines.append("a=\(direction)") }
  return lines.map { $0 + "\r\n" }.joined()
}

/// SDP media section for an ONVIF analytics metadata stream
/// (`m=application 0 RTP/AVP <pt>`, `vnd.onvif.metadata/90000`). CRLF-terminated.
func onvifMetadataMediaSDP(
  control: String = "metadata", payloadType: UInt8 = 107, recvonly: Bool = true
) -> String {
  var lines = [
    "m=application 0 RTP/AVP \(payloadType)",
    "a=rtpmap:\(payloadType) vnd.onvif.metadata/90000",
    "a=control:\(control)",
  ]
  if recvonly { lines.append("a=recvonly") }
  return lines.map { $0 + "\r\n" }.joined()
}

/// A video-only H.264 presentation (one media section, control `video`).
func h264VideoOnlySDP(control: String = "video") -> String {
  makeTestSDP(media: [h264VideoMediaSDP(control: control)])
}

/// An ONVIF backchannel presentation, in the order cameras typically list it:
/// H.264 video (`recvonly`), optional PCMU audio (`recvonly`), optional ONVIF
/// metadata, then the PCMU audio backchannel (`sendonly`, client to camera).
/// SDP media indices follow that order, so with every stream present: video 0,
/// audio 1, metadata 2, backchannel 3. `includeBackchannel: false` gives the
/// same layout without the backchannel, for
/// `FakeRTSPServer.Configuration.sdpWithoutBackchannel`.
func onvifBackchannelSDP(
  videoControl: String = "video",
  audioControl: String? = "audio",
  metadataControl: String? = "metadata",
  backchannelControl: String = "audioback",
  includeBackchannel: Bool = true
) -> String {
  var media = [h264VideoMediaSDP(control: videoControl, recvonly: true)]
  if let audioControl {
    media.append(pcmuAudioMediaSDP(control: audioControl, direction: "recvonly"))
  }
  if let metadataControl {
    media.append(onvifMetadataMediaSDP(control: metadataControl))
  }
  if includeBackchannel {
    media.append(pcmuAudioMediaSDP(control: backchannelControl, direction: "sendonly"))
  }
  return makeTestSDP(media: media)
}

/// The outcome of `body` as a `Result` (the standard library's async
/// `Result(catching:)` isn't available on every supported toolchain).
func outcome<T>(_ body: () async throws -> T) async -> Result<T, any Error> {
  do {
    return .success(try await body())
  } catch {
    return .failure(error)
  }
}
