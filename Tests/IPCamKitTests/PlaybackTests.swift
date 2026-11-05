// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// PLAY options, ONVIF replay extension parsing, and the SDP/SETUP fields the
// ONVIF features and multicast/SRTP transports read.

import Foundation
import Testing

@testable import IPCamKit

/// An RTP packet (V=2) with an optional header extension.
private func rtpPacket(
  seq: UInt16, timestamp: UInt32, ssrc: UInt32 = 0x1234_5678,
  extensionProfile: UInt16? = nil, extensionData: Data = Data(), payload: Data = Data([0x01])
) -> Data {
  var data = Data()
  data.append(extensionProfile == nil ? 0x80 : 0x90)
  data.append(96)
  data.append(contentsOf: [UInt8(seq >> 8), UInt8(seq & 0xFF)])
  data.append(contentsOf: withUnsafeBytes(of: timestamp.bigEndian, Array.init))
  data.append(contentsOf: withUnsafeBytes(of: ssrc.bigEndian, Array.init))
  if let extensionProfile {
    let words = UInt16(extensionData.count / 4)
    data.append(contentsOf: [UInt8(extensionProfile >> 8), UInt8(extensionProfile & 0xFF)])
    data.append(contentsOf: [UInt8(words >> 8), UInt8(words & 0xFF)])
    data.append(extensionData)
  }
  data.append(payload)
  return data
}

/// The 12-byte ONVIF replay extension body.
private func replayExtensionBody(ntp: UInt64, flags: UInt8, cseq: UInt8) -> Data {
  var data = Data(withUnsafeBytes(of: ntp.bigEndian, Array.init))
  data.append(contentsOf: [flags, cseq, 0, 0])
  return data
}

/// NTP time for a Unix time in seconds.
private func ntp(unixSeconds: Double) -> UInt64 {
  let seconds = UInt64(unixSeconds.rounded(.down)) + 2_208_988_800
  let fraction = UInt64((unixSeconds - unixSeconds.rounded(.down)) * 4_294_967_296)
  return seconds << 32 | fraction
}

@Suite("PlayOptions headers")
struct PlayOptionsTests {
  private func headerMap(_ headers: [(String, String)]) -> [String: String] {
    Dictionary(headers, uniquingKeysWith: { first, _ in first })
  }

  @Test("The first PLAY defaults to npt=0.000-; later ones send no Range")
  func defaultRange() throws {
    #expect(headerMap(try PlayOptions().headers(isInitial: true)) == ["Range": "npt=0.000-"])
    #expect(try PlayOptions().headers(isInitial: false).isEmpty)
  }

  @Test("Replay headers are formatted as ONVIF specifies")
  func replayHeaders() throws {
    let start = Date(timeIntervalSince1970: 1_750_000_000.25)
    let options = PlayOptions(
      range: .clock(start: start), scale: -2, rateControl: false, frames: .intra,
      immediate: true)
    #expect(
      headerMap(try options.headers(isInitial: false)) == [
        "Range": "clock=20250615T150640.250Z-",
        "Scale": "-2.0",
        "Rate-Control": "no",
        "Frames": "intra",
        "Immediate": "yes",
      ])
  }

  @Test("Scale keeps fractional digits")
  func fractionalScale() throws {
    let headers = headerMap(try PlayOptions(scale: 0.25).headers(isInitial: false))
    #expect(headers["Scale"] == "0.25")
  }

  @Test(
    "Scale is [-]digits.digits with up to six decimals, never 0 or hundreds of digits",
    .timeLimit(.minutes(1)),
    arguments: [
      (2, "2.0"), (-1, "-1.0"), (0.5, "0.5"), (1.0 / 3, "0.333333"), (-2.0 / 3, "-0.666667"),
      (0.000_001, "0.000001"), (-0.000_001, "-0.000001"), (0.000_001_4, "0.000001"),
      (1000, "1000.0"), (-1000, "-1000.0"), (999.999_999_6, "1000.0"), (16.25, "16.25"),
    ] as [(Double, String)])
  func scaleSyntax(_ scale: Double, _ expected: String) throws {
    let value = try #require(
      headerMap(try PlayOptions(scale: scale).headers(isInitial: false))["Scale"])
    #expect(value == expected)
    // RFC 7826's scale-value, which also fits RFC 2326's.
    #expect(value.wholeMatch(of: /-?[0-9]+\.[0-9]+/) != nil, "\(value)")
  }

  @Test(
    "A zero, non-finite, vanishing or huge scale is rejected with invalidState",
    .timeLimit(.minutes(1)),
    arguments: [
      0, -0.0, .nan, .infinity, -.infinity, 1e-7, -4e-7, 0.000_000_9, 1000.001, -1001, 1e300,
      -1e300, .leastNonzeroMagnitude, .greatestFiniteMagnitude,
    ] as [Double])
  func invalidScale(_ scale: Double) {
    let options = PlayOptions(scale: scale)
    for result in [
      Result { try options.validate() }, Result { _ = try options.headers(isInitial: true) },
    ] {
      if case .failure(let error) = result, case .invalidState = error as? RTSPError { continue }
      Issue.record("scale \(scale): expected RTSPError.invalidState, got \(result)")
    }
  }

  @Test("start() and play() reject a bad scale without sending a request", .timeLimit(.minutes(1)))
  func sessionRejectsInvalidScale() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    try await server.start()
    defer { server.stop() }

    let unstarted = RTSPClientSession(url: server.url)
    let startResult = await outcome { try await unstarted.start(PlayOptions(scale: 1e-7)) }
    guard case .failure(let startError) = startResult,
      case .invalidState = startError as? RTSPError
    else {
      Issue.record("expected RTSPError.invalidState from start(), got \(startResult)")
      await unstarted.stop()
      return
    }
    #expect(server.requests.isEmpty)

    let session = RTSPClientSession(url: server.url)
    _ = try await session.start(PlayOptions(scale: 2))
    let playResult = await outcome { try await session.play(PlayOptions(scale: 1e300)) }
    guard case .failure(let playError) = playResult, case .invalidState = playError as? RTSPError
    else {
      Issue.record("expected RTSPError.invalidState from play(), got \(playResult)")
      await session.stop()
      return
    }
    // The session still plays: the next PLAY goes out, and the rejected one
    // didn't even take a CSeq.
    try await session.play(PlayOptions(scale: 0.000_001))
    #expect(server.requests(method: "PLAY").map(\.scale) == ["2.0", "0.000001"])
    let cseqs = server.requests.compactMap(\.cseq)
    #expect(zip(cseqs, cseqs.dropFirst()).allSatisfy { $1 == $0 + 1 }, "\(cseqs)")
    await session.stop()
  }

  @Test("Frame filters map to Frames header values")
  func frameFilters() {
    #expect(FrameFilter.all.headerValue == nil)
    #expect(FrameFilter.intra.headerValue == "intra")
    #expect(FrameFilter.intraEvery(.milliseconds(1500)).headerValue == "intra/1500")
    // The largest whole-millisecond count plus a fraction used to overflow.
    let longest = Duration.seconds(Int64.max / 1000) + .milliseconds(999)
    #expect(FrameFilter.intraEvery(longest).headerValue == "intra/\(Int64.max)")
    #expect(FrameFilter.intraAndPredicted.headerValue == "predicted")
  }

  @Test("npt ranges format with three decimals")
  func nptFormatting() {
    #expect(PlaybackRange.npt(start: 12.5).headerValue == "npt=12.500-")
    #expect(PlaybackRange.npt(start: 0, end: 30).headerValue == "npt=0.000-30.000")
    // -0.0 (from rounding a small negative value, say) is written as 0.
    #expect(PlaybackRange.npt(start: -0.0).headerValue == "npt=0.000-")
    #expect(PlaybackRange.npt(start: 0, end: -0.0).headerValue == "npt=0.000-0.000")
  }
}

@Suite("PlaybackRange parsing")
struct PlaybackRangeParseTests {
  @Test("npt forms, including hh:mm:ss and a ;time= suffix")
  func npt() {
    #expect(PlaybackRange.parse("npt=0-") == .npt(start: 0))
    #expect(PlaybackRange.parse("npt=10.5-20") == .npt(start: 10.5, end: 20))
    #expect(PlaybackRange.parse("npt=00:01:30.5-") == .npt(start: 90.5))
    #expect(PlaybackRange.parse("npt=5-;time=19970123T143720Z") == .npt(start: 5))
  }

  @Test(
    "npt values are digits only, with minutes and seconds of one or two digits below 60",
    arguments: [
      ("npt=1e3-", nil), ("npt=0x10-", nil), ("npt=+5-", nil), ("npt=5-+6", nil),
      ("npt=.5-", nil), ("npt=5.-", PlaybackRange.npt(start: 5)), ("npt=nan-", nil),
      ("npt=0:0:1e1-", nil), ("npt=+1:00:00-", nil), ("npt=1:-1:00-", nil),
      ("npt=00:60:00-", nil), ("npt=00:00:60-", nil), ("npt=00:001:00-", nil),
      ("npt=00:00:001-", nil), ("npt=00:00:5.-", .npt(start: 5)), ("npt=00:00:.5-", nil),
      ("npt=1:2:3-", .npt(start: 3723)), ("npt=100:00:00.25-", .npt(start: 360_000.25)),
      ("npt=00:59:59.999-", .npt(start: 3599.999)),
    ] as [(String, PlaybackRange?)])
  func nptDigitsOnly(value: String, expected: PlaybackRange?) {
    #expect(PlaybackRange.parse(value) == expected)
  }

  @Test(
    "clock times map to the proleptic Gregorian calendar in years 0001-9999",
    arguments: [
      ("00010101T000000Z", -62_135_596_800.0), ("15821004T120000Z", -12_220_200_000),
      ("16000229T000000Z", -11_670_998_400), ("18991231T235959Z", -2_208_988_801),
      ("19000101T000000Z", -2_208_988_800), ("99991231T235959Z", 253_402_300_799),
      // A leap second is read as the next midnight.
      ("20161231T235960Z", 1_483_228_800),
    ])
  func clockCalendar(time: String, interval: Double) {
    #expect(
      PlaybackRange.parse("clock=\(time)-") == .clock(start: Date(timeIntervalSince1970: interval)))
  }

  @Test(
    "Spaces may surround the value and the =, not a time",
    arguments: [
      ("npt = 5-", PlaybackRange.npt(start: 5)), (" npt=5- ", .npt(start: 5)),
      ("npt=5- ;time=19970123T143720Z", .npt(start: 5)), ("npt= 5 - 6", nil), ("npt=5 -", nil),
      ("npt=5-6 7", nil), (";npt=5-", nil), ("clock= 20250101T120000Z -", nil),
      ("clock=20250101T120000Z -", nil), ("npt=00:00:59.999999999999999-", .npt(start: 60)),
      ("clock=20250101T120060Z-", nil),
      ("clock=20250101T235960Z-", .clock(start: Date(timeIntervalSince1970: 1_735_776_000))),
    ] as [(String, PlaybackRange?)])
  func rangeSpacing(value: String, expected: PlaybackRange?) {
    #expect(PlaybackRange.parse(value) == expected)
  }

  @Test("clock ranges as an ONVIF recording advertises them")
  func clock() {
    let start = Date(timeIntervalSince1970: 1_735_732_800)  // 2025-01-01T12:00:00Z
    #expect(
      PlaybackRange.parse("clock=20250101T120000Z-20250101T130000.5Z")
        == .clock(start: start, end: start.addingTimeInterval(3600.5)))
    #expect(PlaybackRange.parse("clock=20250101T120000.000Z-") == .clock(start: start))
  }

  @Test("Unsupported and malformed values are nil")
  func rejects() {
    #expect(PlaybackRange.parse("npt=now-") == nil)
    #expect(PlaybackRange.parse("smpte=0:10:20-") == nil)
    #expect(PlaybackRange.parse("clock=20251301T000000Z-") == nil)
    #expect(PlaybackRange.parse("clock=20250101T120000-") == nil)
    #expect(PlaybackRange.parse("npt=5-x") == nil)
    // Infinite, and dates that don't exist.
    #expect(PlaybackRange.parse("npt=0:0:1e400-") == nil)
    #expect(PlaybackRange.parse("npt=inf:00:00-") == nil)
    #expect(PlaybackRange.parse("clock=20250230T000000Z-") == nil)
    #expect(PlaybackRange.parse("clock=20230229T000000Z-") == nil)
    #expect(PlaybackRange.parse("clock=21000229T000000Z-") == nil)
    #expect(PlaybackRange.parse("clock=20250431T000000Z-") == nil)
    #expect(PlaybackRange.parse("clock=20240229T000000Z-") != nil)
    #expect(PlaybackRange.parse("clock=20000229T000000Z-") != nil)
    #expect(PlaybackRange.parse("clock=20251231T235960Z-") != nil)
    // The calendar has no year 0.
    #expect(PlaybackRange.parse("clock=00000101T000000Z-") == nil)
    #expect(PlaybackRange.parse("clock=00010101T000000Z-") != nil)
    // Case doesn't matter in the `T` and `Z` separators.
    #expect(PlaybackRange.parse("clock=20250101t000000z-") != nil)
  }

  @Test("clock formatting round-trips through parsing")
  func roundTrip() {
    let date = Date(timeIntervalSince1970: 1_700_000_123.456)
    let parsed = PlaybackRange.parse(PlaybackRange.clock(start: date).headerValue)
    guard case .clock(let start, nil) = parsed else {
      Issue.record("expected a clock range, got \(String(describing: parsed))")
      return
    }
    #expect(abs(start.timeIntervalSince(date)) < 0.0005)
  }
}

@Suite("ONVIF replay RTP header extension")
struct ONVIFReplayExtensionTests {
  @Test("Reads time, flags and CSeq from a packet")
  func parse() throws {
    let body = replayExtensionBody(
      ntp: ntp(unixSeconds: 1_700_000_000.5), flags: 0x80 | 0x20, cseq: 7)
    let packet = rtpPacket(
      seq: 1, timestamp: 9000, extensionProfile: 0xABAC, extensionData: body)
    let ext = try #require(ONVIFReplayExtension(rtpPacket: packet))
    #expect(ext.cleanPoint)
    #expect(!ext.endOfSection)
    #expect(ext.discontinuity)
    #expect(!ext.terminal)
    #expect(ext.cseq == 7)
    #expect(abs(ext.date.timeIntervalSince1970 - 1_700_000_000.5) < 0.001)

    // The validated-packet accessor sees the same extension.
    guard case .success(let raw) = RawRTPPacket.parse(packet) else {
      Issue.record("packet should parse")
      return
    }
    #expect(raw.headerExtension?.profile == 0xABAC)
  }

  @Test("Longer extensions are accepted; other profiles and short ones are not")
  func otherShapes() {
    var long = replayExtensionBody(ntp: 1 << 32, flags: 0x10, cseq: 1)
    long.append(Data(repeating: 0xEE, count: 8))
    #expect(
      ONVIFReplayExtension(
        rtpPacket: rtpPacket(seq: 1, timestamp: 0, extensionProfile: 0xABAC, extensionData: long)
      )?.terminal == true)
    #expect(
      ONVIFReplayExtension(
        rtpPacket: rtpPacket(
          seq: 1, timestamp: 0, extensionProfile: 0xBEDE, extensionData: Data(count: 12))) == nil
    )
    #expect(
      ONVIFReplayExtension(
        rtpPacket: rtpPacket(
          seq: 1, timestamp: 0, extensionProfile: 0xABAC, extensionData: Data(count: 8))) == nil)
    #expect(ONVIFReplayExtension(rtpPacket: rtpPacket(seq: 1, timestamp: 0)) == nil)
  }

  @Test("Truncated packets don't read out of bounds")
  func truncated() {
    let body = replayExtensionBody(ntp: 1, flags: 0, cseq: 0)
    let packet = rtpPacket(seq: 1, timestamp: 0, extensionProfile: 0xABAC, extensionData: body)
    for length in 0..<(12 + 4 + 12) {
      #expect(ONVIFReplayExtension(rtpPacket: packet.prefix(length)) == nil)
    }
    // A slice not starting at index 0 still parses.
    var padded = Data([0xFF, 0xFF])
    padded.append(packet)
    #expect(ONVIFReplayExtension(rtpPacket: padded.dropFirst(2)) != nil)
  }
}

@Suite("ReplayTracker")
struct ReplayTrackerTests {
  private func ext(_ seconds: Double, flags: UInt8 = 0) -> ONVIFReplayExtension {
    ONVIFReplayExtension(
      ntpTimestamp: ntp(unixSeconds: seconds), cleanPoint: flags & 0x80 != 0,
      endOfSection: flags & 0x40 != 0, discontinuity: flags & 0x20 != 0,
      terminal: flags & 0x10 != 0, cseq: 3)
  }

  @Test("Packets of one frame merge their flags")
  func mergesFlags() throws {
    var tracker = ReplayTracker()
    tracker.record(timestamp: 1000, ext: ext(100, flags: 0x80))
    tracker.record(timestamp: 1000, ext: ext(100, flags: 0x40))
    let info = try #require(tracker.info(forFrameAt: 1000, clockRate: 90000))
    #expect(info.isCleanPoint)
    #expect(info.isEndOfSection)
    #expect(!info.isDiscontinuity)
    #expect(info.time == Date(timeIntervalSince1970: 100))
  }

  @Test("A frame without its own entry extrapolates from the previous one")
  func extrapolates() throws {
    var tracker = ReplayTracker()
    tracker.record(timestamp: 8000, ext: ext(200, flags: 0x80))
    let info = try #require(tracker.info(forFrameAt: 8000 + 4000, clockRate: 8000))
    #expect(abs(info.time.timeIntervalSince1970 - 200.5) < 0.0001)
    #expect(!info.isCleanPoint)
    // Beyond 10 s, or before the first entry, there's nothing to go on.
    #expect(tracker.info(forFrameAt: 8000 + 8000 * 11, clockRate: 8000) == nil)
    #expect(tracker.info(forFrameAt: 100, clockRate: 8000) == nil)
    tracker.removeAll()
    #expect(tracker.info(forFrameAt: 8000, clockRate: 8000) == nil)
  }
}

@Suite("InorderParser reseed")
struct InorderParserReseedTests {
  @Test("Reseeding after a seek accepts the new sequence range without loss")
  func reseed() throws {
    var parser = InorderParser(
      ssrc: 0x1234_5678, nextSeq: nil, isTcp: true,
      timeline: try Timeline(start: nil, clockRate: 90000))
    _ = try parser.rtp(
      data: rtpPacket(seq: 5000, timestamp: 0), ctx: .dummy, streamId: 0, streamCtx: .dummy)
    // Without reseeding, a restart at seq 100 is a sequence jump: TCP can't
    // reorder, so it resyncs at once and reports the discontinuity as loss.
    var stale = parser
    let resynced = try #require(
      try stale.rtp(
        data: rtpPacket(seq: 100, timestamp: 3000), ctx: .dummy, streamId: 0, streamCtx: .dummy))
    #expect(resynced.loss >= 1)

    parser.reseed(nextSeq: 100, ssrc: 0x0BAD_CAFE)
    let pkt = try #require(
      try parser.rtp(
        data: rtpPacket(seq: 100, timestamp: 3000, ssrc: 0x0BAD_CAFE), ctx: .dummy,
        streamId: 0, streamCtx: .dummy))
    #expect(pkt.loss == 0)
  }
}

@Suite("SDP and SETUP fields for ONVIF and multicast")
struct ONVIFSDPTests {
  private func describe(_ sdp: String) throws -> Presentation {
    let body = Data(sdp.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    return try parseDescribe(
      requestURL: "rtsp://192.0.2.1/onvif",
      response: RTSPResponse(
        statusCode: 200, reasonPhrase: "OK", headers: [("Content-Type", "application/sdp")],
        body: body))
  }

  @Test("Backchannel SDP: per-media direction, session range, key-mgmt")
  func backchannelSDP() throws {
    let p = try describe(
      """
      v=0
      o=- 0 0 IN IP4 192.0.2.1
      s=ONVIF
      t=0 0
      a=range:clock=20250101T120000Z-20250101T130000Z
      a=key-mgmt:mikey AQAFAA==
      m=video 0 RTP/AVP 96
      a=rtpmap:96 H264/90000
      a=control:video
      a=recvonly
      m=audio 0 RTP/AVP 0
      a=rtpmap:0 PCMU/8000
      a=control:audio
      a=recvonly
      m=audio 0 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      a=control:audioback
      a=sendonly
      a=key-mgmt:mikey AgAFAA==

      """)
    #expect(p.streams.map(\.direction) == [.receiveOnly, .receiveOnly, .sendOnly])
    #expect(p.range == "clock=20250101T120000Z-20250101T130000Z")
    #expect(p.streams[0].keyMgmt == "mikey AQAFAA==")
    #expect(p.streams[2].keyMgmt == "mikey AgAFAA==")
    #expect(p.streams[2].encodingName == "pcma")
  }

  @Test("Session-level direction is inherited; media range is the fallback")
  func inheritance() throws {
    let p = try describe(
      """
      v=0
      o=- 0 0 IN IP4 192.0.2.1
      s=Live
      t=0 0
      a=sendonly
      m=video 0 RTP/AVP 96
      a=rtpmap:96 H264/90000
      a=range:npt=0-
      a=control:video

      """)
    #expect(p.streams[0].direction == .sendOnly)
    #expect(p.range == "npt=0-")
    #expect(p.streams[0].keyMgmt == nil)
  }

  private func setupResponse(transport: String) -> RTSPResponse {
    RTSPResponse(
      statusCode: 200, reasonPhrase: "OK",
      headers: [("Session", "abc;timeout=60"), ("Transport", transport)], body: Data())
  }

  @Test("Multicast SETUP response: group, port pair and TTL")
  func multicastSetup() throws {
    let setup = try parseSetup(
      response: setupResponse(
        transport: "RTP/AVP;multicast;destination=224.1.0.1;port=8000-8001;ttl=127"))
    #expect(setup.destination == "224.1.0.1")
    #expect(setup.multicastPort == 8000)
    #expect(setup.ttl == 127)

    let single = try parseSetup(
      response: setupResponse(transport: "RTP/AVP;multicast;destination=239.0.0.5;port=5004"))
    #expect(single.multicastPort == 5004)

    #expect(throws: RTSPError.self) {
      try parseSetup(
        response: setupResponse(transport: "RTP/AVP;multicast;destination=224.1.0.1;port=8000-8005")
      )
    }
    #expect(throws: RTSPError.self) {
      try parseSetup(response: setupResponse(transport: "RTP/AVP;multicast;port=65535"))
    }
  }

  @Test("Compressed ONVIF metadata encodings are accepted")
  func metadataEncodings() {
    #expect(isApplicationEncodingSupported("vnd.onvif.metadata.gzip"))
    #expect(isApplicationEncodingSupported("vnd.onvif.metadata.exi.onvif"))
    #expect(isApplicationEncodingSupported("vnd.onvif.metadata.exi.ext"))
  }

  @Test("Require carries each requested ONVIF feature tag")
  func requireValue() {
    #expect(ONVIFFeatures().requireHeaderValue == nil)
    #expect(ONVIFFeatures.replay.requireHeaderValue == "onvif-replay")
    #expect(
      ONVIFFeatures([.replay, .backchannel]).requireHeaderValue
        == "onvif-replay, www.onvif.org/ver20/backchannel")
  }
}
