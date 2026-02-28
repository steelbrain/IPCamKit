// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Ports upstream src/client/parse.rs DESCRIBE/SETUP/PLAY tests.
// 22 tests covering camera SDPs from Dahua, Hikvision, Reolink, Foscam,
// GW Security, VStarcam, Anpviz, Ubiquiti, TP-LINK, Macrovideo, IPCAM, etc.

import Foundation
import Testing

@testable import IPCamKit

// MARK: - Test Helpers

/// Load and parse an RTSP response from a test data file.
func loadResponse(_ filename: String) throws -> RTSPResponse {
  let url = Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "TestData")
  guard let url else {
    throw RTSPError.depacketizationError("Test data file not found: \(filename)")
  }
  var data = try Data(contentsOf: url)
  let parser = RTSPParser()
  guard let (msg, _) = try parser.parse(&data) else {
    throw RTSPError.depacketizationError("Failed to parse response from \(filename)")
  }
  guard case .response(let resp) = msg else {
    throw RTSPError.depacketizationError("Expected response in \(filename)")
  }
  return resp
}

/// Parse a DESCRIBE response from a test data file.
/// Handles both full RTSP responses and raw SDP bodies.
func loadDescribe(url: String, filename: String) throws -> Presentation {
  let fileURL = Bundle.module.url(
    forResource: filename, withExtension: nil, subdirectory: "TestData")
  guard let fileURL else {
    throw RTSPError.depacketizationError("Test data file not found: \(filename)")
  }
  let data = try Data(contentsOf: fileURL)
  let text = String(data: data, encoding: .utf8) ?? ""

  // Check if it starts with "RTSP/" (full response) or not (raw SDP)
  if text.hasPrefix("RTSP/") {
    let response = try loadResponse(filename)
    return try parseDescribe(requestURL: url, response: response)
  } else {
    // Raw SDP — wrap in a synthetic response
    let response = RTSPResponse(
      statusCode: 200,
      reasonPhrase: "OK",
      headers: [("Content-Type", "application/sdp")],
      body: data
    )
    return try parseDescribe(requestURL: url, response: response)
  }
}

/// Set all streams to setup state for PLAY testing (matches upstream dummy_stream_state_init).
func initStreamsForPlay(_ presentation: inout Presentation) {
  for i in 0..<presentation.streams.count {
    presentation.streams[i].state = .setup(
      StreamStateInit(ssrc: nil, initialSeq: nil, initialRtptime: nil, ctx: .dummy))
  }
}

// MARK: - DESCRIBE Tests

@Suite("SDP and Response Parsing Tests")
struct DescribeParserTests {

  // Test 1: longse_cseq is in RTSPParserTests already

  // Test 2: anpviz_sdp
  @Test("Anpviz camera SDP parses without error")
  func anpvizSDP() throws {
    let p = try loadDescribe(url: "rtsp://127.0.0.1/", filename: "anpviz_sdp.txt")
    #expect(!p.streams.isEmpty)
  }

  // Test 3: geovision_sdp
  @Test("Geovision camera SDP parses without error")
  func geovisionSDP() throws {
    let p = try loadDescribe(url: "rtsp://127.0.0.1/", filename: "geovision_sdp.txt")
    #expect(!p.streams.isEmpty)
  }

  // Test 4: ubiquiti_sdp
  @Test("Ubiquiti camera SDP has 3 streams")
  func ubiquitiSDP() throws {
    let p = try loadDescribe(url: "rtsp://127.0.0.1/", filename: "ubiquiti_sdp.txt")
    #expect(p.streams.count == 3)
  }

  // Test 5: tplink_sdp
  @Test("TP-LINK camera SDP has 2 streams")
  func tplinkSDP() throws {
    let p = try loadDescribe(url: "rtsp://127.0.0.1/", filename: "tplink_sdp.txt")
    #expect(p.streams.count == 2)
  }

  // Test 6: dahua_h264_aac_onvif
  @Test("Dahua H.264 + AAC + ONVIF (3 streams)")
  func dahuaH264AacOnvif() throws {
    let url =
      "rtsp://192.168.5.111:554/cam/realmonitor?channel=1&subtype=1&unicast=true&proto=Onvif"

    // DESCRIBE
    let p = try loadDescribe(url: url, filename: "dahua_describe_h264_aac_onvif.txt")
    #expect(
      p.control
        == "rtsp://192.168.5.111:554/cam/realmonitor?channel=1&subtype=1&unicast=true&proto=Onvif/"
    )
    #expect(p.streams.count == 3)

    // Stream 0: H.264 video
    let s0 = p.streams[0]
    #expect(s0.control == url + "/trackID=0")
    #expect(s0.media == "video")
    #expect(s0.encodingName == "h264")
    #expect(s0.rtpPayloadType == 96)
    #expect(s0.clockRateHz == 90000)
    let v0 = s0.videoParameters
    #expect(v0 != nil)
    #expect(v0!.rfc6381Codec == "avc1.64001E")
    #expect(v0!.pixelDimensions?.width == 704)
    #expect(v0!.pixelDimensions?.height == 480)
    #expect(v0!.pixelAspectRatio == nil)
    #expect(v0!.frameRate?.num == 2)
    #expect(v0!.frameRate?.den == 30)

    // Stream 1: AAC audio
    let s1 = p.streams[1]
    #expect(s1.control == url + "/trackID=1")
    #expect(s1.media == "audio")
    #expect(s1.encodingName == "mpeg4-generic")
    #expect(s1.rtpPayloadType == 97)
    #expect(s1.clockRateHz == 48000)

    // Stream 2: ONVIF metadata
    let s2 = p.streams[2]
    #expect(s2.control == url + "/trackID=4")
    #expect(s2.media == "application")
    #expect(s2.encodingName == "vnd.onvif.metadata")
    #expect(s2.rtpPayloadType == 107)
    #expect(s2.clockRateHz == 90000)

    // SETUP
    let setupResp = try loadResponse("dahua_setup.txt")
    let setup = try parseSetup(response: setupResp)
    #expect(setup.session.id == "634214675641")
    #expect(setup.session.timeoutSec == 60)
    #expect(setup.channelId == 0)
    #expect(setup.ssrc == 0x30A9_8EE7)

    // PLAY — set streams to setup state first (upstream uses dummy_stream_state_init)
    var pMut = p
    initStreamsForPlay(&pMut)
    let playResp = try loadResponse("dahua_play.txt")
    try parsePlay(response: playResp, presentation: &pMut)
    if case .setup(let init0) = pMut.streams[0].state {
      #expect(init0.initialSeq == 47121)
      #expect(init0.initialRtptime == 3_475_222_385)
    } else {
      Issue.record("Stream 0 should be in setup state")
    }

    // OPTIONS
    let optionsResp = try loadResponse("dahua_options.txt")
    let options = parseOptions(response: optionsResp)
    #expect(options.setParameterSupported == true)
  }

  // Test 7: dahua_h265_pcma
  @Test("Dahua H.265 + PCMA (2 streams)")
  func dahuaH265Pcma() throws {
    let url = "rtsp://192.168.5.111:554/cam/realmonitor?channel=1&subtype=2"
    let p = try loadDescribe(url: url, filename: "dahua_describe_h265_pcma.txt")
    #expect(p.streams.count == 2)

    #expect(p.streams[0].media == "video")
    #expect(p.streams[0].encodingName == "h265")
    #expect(p.streams[0].rtpPayloadType == 98)

    #expect(p.streams[1].media == "audio")
    #expect(p.streams[1].encodingName == "pcma")
    #expect(p.streams[1].rtpPayloadType == 8)
  }

  // Test 8: hikvision
  @Test("Hikvision (video + metadata)")
  func hikvision() throws {
    let url =
      "rtsp://192.168.5.106:554/Streaming/Channels/101?transportmode=unicast&Profile=Profile_1"

    let prefix = "rtsp://192.168.5.106:554/Streaming/Channels/101"
    let p = try loadDescribe(url: url, filename: "hikvision_describe.txt")
    // Upstream checks base_url
    #expect(p.baseURL == prefix + "/")
    #expect(p.streams.count == 2)

    // Stream 0: H.264 video
    let s0 = p.streams[0]
    // Upstream checks control URL with query params
    #expect(
      s0.control == prefix + "/trackID=1?transportmode=unicast&profile=Profile_1")
    #expect(s0.media == "video")
    #expect(s0.encodingName == "h264")
    #expect(s0.rtpPayloadType == 96)
    #expect(s0.clockRateHz == 90000)
    let v0 = s0.videoParameters
    #expect(v0 != nil)
    #expect(v0!.rfc6381Codec == "avc1.4D0029")
    #expect(v0!.pixelDimensions?.width == 1920)
    #expect(v0!.pixelDimensions?.height == 1080)
    #expect(v0!.pixelAspectRatio == nil)
    #expect(v0!.frameRate?.num == 2000)
    #expect(v0!.frameRate?.den == 60000)

    // Stream 1: ONVIF metadata
    let s1 = p.streams[1]
    // Upstream checks control URL
    #expect(
      s1.control == prefix + "/trackID=3?transportmode=unicast&profile=Profile_1")
    #expect(s1.media == "application")
    #expect(s1.encodingName == "vnd.onvif.metadata")
    #expect(s1.rtpPayloadType == 107)
    #expect(s1.clockRateHz == 90000)

    // SETUP
    let setupResp = try loadResponse("hikvision_setup.txt")
    let setup = try parseSetup(response: setupResp)
    #expect(setup.session.id == "708345999")
    #expect(setup.session.timeoutSec == 60)
    #expect(setup.channelId == 0)
    #expect(setup.ssrc == 0x4CAC_C3D1)

    // PLAY
    var pMut = p
    initStreamsForPlay(&pMut)
    let playResp = try loadResponse("hikvision_play.txt")
    try parsePlay(response: playResp, presentation: &pMut)
    if case .setup(let init0) = pMut.streams[0].state {
      #expect(init0.initialSeq == 24104)
      #expect(init0.initialRtptime == 1_270_711_678)
    } else {
      Issue.record("Stream 0 should be in setup state")
    }
  }

  // Test 9: reolink
  @Test("Reolink (LIVE555 server, video + audio)")
  func reolink() throws {
    let url = "rtsp://192.168.5.206:554/h264Preview_01_main"

    let p = try loadDescribe(url: url, filename: "reolink_describe.txt")
    #expect(p.tool == "LIVE555 Streaming Media v2013.04.08")
    #expect(p.streams.count == 2)

    let base = "rtsp://192.168.5.206/h264Preview_01_main/"
    // Upstream checks presentation control URL
    #expect(p.control == base)

    let s0 = p.streams[0]
    // Upstream checks control URL
    #expect(s0.control == base + "trackID=1")
    #expect(s0.media == "video")
    #expect(s0.encodingName == "h264")
    #expect(s0.rtpPayloadType == 96)
    #expect(s0.clockRateHz == 90000)
    let rv0 = s0.videoParameters
    #expect(rv0 != nil)
    #expect(rv0!.rfc6381Codec == "avc1.640033")
    #expect(rv0!.pixelDimensions?.width == 2560)
    #expect(rv0!.pixelDimensions?.height == 1440)
    #expect(rv0!.pixelAspectRatio == nil)
    #expect(rv0!.frameRate == nil)

    let s1 = p.streams[1]
    // Upstream checks control URL
    #expect(s1.control == base + "trackID=2")
    #expect(s1.media == "audio")
    #expect(s1.encodingName == "mpeg4-generic")
    #expect(s1.rtpPayloadType == 97)
    #expect(s1.clockRateHz == 16000)

    // Also test with control-first variant and verify equality
    let p2 = try loadDescribe(url: url, filename: "reolink_describe_control_first.txt")
    #expect(p2.streams.count == 2)
    #expect(p.control == p2.control)
    #expect(p.tool == p2.tool)

    // SETUP
    let setupResp = try loadResponse("reolink_setup.txt")
    let setup = try parseSetup(response: setupResp)
    #expect(setup.session.id == "F8F8E425")
    #expect(setup.session.timeoutSec == 60)
    #expect(setup.channelId == 0)
    #expect(setup.ssrc == nil)

    // PLAY
    var pMut = p
    initStreamsForPlay(&pMut)
    let playResp = try loadResponse("reolink_play.txt")
    try parsePlay(response: playResp, presentation: &pMut)
    if case .setup(let init0) = pMut.streams[0].state {
      #expect(init0.initialSeq == 16852)
      #expect(init0.initialRtptime == 1_070_938_629)
    } else {
      Issue.record("Stream 0 should be in setup state")
    }
    // Stream 1 assertions (upstream parse.rs lines 1131-1137)
    if case .setup(let init1) = pMut.streams[1].state {
      #expect(init1.initialRtptime == 3_075_976_528)
      #expect(init1.ssrc == 0x9FC9_FFF8)
    } else {
      Issue.record("Stream 1 should be in setup state")
    }
  }

  // Test 10: bunny (Wowza test server)
  @Test("Bunny (Wowza, audio first then video)")
  func bunny() throws {
    let url = "rtsp://wowzaec2demo.streamlock.net/vod/mp4:BigBuckBunny_115k.mov"

    let prefix = url + "/"
    let p = try loadDescribe(url: url, filename: "bunny_describe.txt")
    // Upstream checks control URL
    #expect(p.control == prefix)
    #expect(p.streams.count == 2)

    // Stream 0: AAC audio (first!)
    let s0 = p.streams[0]
    // Upstream checks control URL
    #expect(s0.control == prefix + "trackID=1")
    #expect(s0.media == "audio")
    #expect(s0.encodingName == "mpeg4-generic")
    #expect(s0.rtpPayloadType == 96)
    #expect(s0.clockRateHz == 12000)
    #expect(s0.channels == 2)

    // Stream 1: H.264 video
    let bv1 = p.streams[1]
    // Upstream checks control URL
    #expect(bv1.control == prefix + "trackID=2")
    #expect(bv1.media == "video")
    #expect(bv1.encodingName == "h264")
    #expect(bv1.rtpPayloadType == 97)
    #expect(bv1.clockRateHz == 90000)
    let bvp = bv1.videoParameters
    #expect(bvp != nil)
    #expect(bvp!.rfc6381Codec == "avc1.42C01E")
    #expect(bvp!.pixelDimensions?.width == 240)
    #expect(bvp!.pixelDimensions?.height == 160)
    #expect(bvp!.pixelAspectRatio == nil)
    #expect(bvp!.frameRate?.num == 2)
    #expect(bvp!.frameRate?.den == 48)

    // SETUP
    let setupResp = try loadResponse("bunny_setup.txt")
    let setup = try parseSetup(response: setupResp)
    #expect(setup.session.id == "1642021126")
    #expect(setup.session.timeoutSec == 60)
    #expect(setup.channelId == 0)
    #expect(setup.ssrc == nil)

    // PLAY
    var pMut = p
    initStreamsForPlay(&pMut)
    let playResp = try loadResponse("bunny_play.txt")
    try parsePlay(response: playResp, presentation: &pMut)
    if case .setup(let init1) = pMut.streams[1].state {
      #expect(init1.initialRtptime == 0)
      #expect(init1.initialSeq == 1)
      #expect(init1.ssrc == nil)  // upstream also checks this
    } else {
      Issue.record("Stream 1 should be in setup state")
    }
  }

  // Test 11: missing_contenttype_describe
  @Test("DESCRIBE without Content-Type header still parses")
  func missingContentType() throws {
    let p = try loadDescribe(
      url: "rtsp://192.168.1.101/live/test", filename: "missing_content_type_describe.txt")
    #expect(!p.streams.isEmpty)
  }

  // Test 12: bad_rtptime
  @Test("Negative rtptime is treated as missing")
  func badRtptime() throws {
    let p = try loadDescribe(
      url: "rtsp://wowzaec2demo.streamlock.net/vod/mp4:BigBuckBunny_115k.mov",
      filename: "bunny_describe.txt"
    )
    var pMut = p
    // Set stream 0 to setup state (upstream sets to Init before parse_play)
    initStreamsForPlay(&pMut)
    let playResp = try loadResponse("bad_rtptime.txt")
    try parsePlay(response: playResp, presentation: &pMut)

    // Check stream 0 state (upstream uses stream index 0)
    if case .setup(let init0) = pMut.streams[0].state {
      #expect(init0.initialRtptime == nil)
      #expect(init0.initialSeq == 1)
      #expect(init0.ssrc == nil)  // upstream also checks this
    } else {
      Issue.record("Stream 0 should be in setup state")
    }
  }

  // Test 13: foscam
  @Test("Foscam (H.264 + PCMU static payload type)")
  func foscam() throws {
    let url = "rtsp://192.168.5.107:65534/videoMain"

    let prefix = url + "/"
    let p = try loadDescribe(url: url, filename: "foscam_describe.txt")
    #expect(p.control == prefix)
    #expect(p.tool == "LIVE555 Streaming Media v2014.02.10")
    #expect(p.streams.count == 2)

    let s0 = p.streams[0]
    #expect(s0.control == prefix + "track1")
    #expect(s0.media == "video")
    #expect(s0.encodingName == "h264")
    #expect(s0.rtpPayloadType == 96)
    #expect(s0.clockRateHz == 90000)
    let fv0 = s0.videoParameters
    #expect(fv0 != nil)
    #expect(fv0!.rfc6381Codec == "avc1.4D001F")
    #expect(fv0!.pixelDimensions?.width == 1280)
    #expect(fv0!.pixelDimensions?.height == 720)
    #expect(fv0!.pixelAspectRatio == nil)
    #expect(fv0!.frameRate == nil)

    // PCMU audio uses static payload type 0 with no rtpmap
    let s1 = p.streams[1]
    #expect(s1.control == prefix + "track2")
    #expect(s1.media == "audio")
    #expect(s1.encodingName == "pcmu")
    #expect(s1.rtpPayloadType == 0)
    #expect(s1.clockRateHz == 8000)
    #expect(s1.channels == 1)
  }

  // Test 14: vstarcam
  @Test("VStarcam (H.264 + PCMA static type 8)")
  func vstarcam() throws {
    let url = "rtsp://192.168.1.198:10554/tcp/av0_0"

    let p = try loadDescribe(url: url, filename: "vstarcam_describe.txt")
    // Upstream checks control (no trailing slash for vstarcam)
    #expect(p.control == url)
    #expect(p.streams.count == 2)

    let s0 = p.streams[0]
    // Upstream checks control URL
    #expect(s0.control == url + "/track0")
    #expect(s0.media == "video")
    #expect(s0.encodingName == "h264")
    #expect(s0.rtpPayloadType == 96)
    #expect(s0.clockRateHz == 90000)
    let vsv0 = s0.videoParameters
    #expect(vsv0 != nil)
    #expect(vsv0!.rfc6381Codec == "avc1.4D002A")
    #expect(vsv0!.pixelDimensions?.width == 1920)
    #expect(vsv0!.pixelDimensions?.height == 1080)
    #expect(vsv0!.pixelAspectRatio == nil)
    #expect(vsv0!.frameRate?.num == 2)
    #expect(vsv0!.frameRate?.den == 15)

    let s1 = p.streams[1]
    #expect(s1.control == url + "/track1")
    #expect(s1.media == "audio")
    #expect(s1.encodingName == "pcma")
    #expect(s1.rtpPayloadType == 8)
    #expect(s1.clockRateHz == 8000)
    #expect(s1.channels == 1)
  }

  // Test 15: gw_main
  @Test("GW Security main stream (rtpmap overrides static type)")
  func gwMain() throws {
    let url =
      "rtsp://192.168.1.110:5050/H264?channel=1&subtype=0&unicast=true&proto=Onvif"

    let p = try loadDescribe(url: url, filename: "gw_main_describe.txt")
    #expect(p.control == url)
    #expect(p.streams.count == 2)

    let s0 = p.streams[0]
    #expect(s0.control == url + "/video")
    #expect(s0.media == "video")
    #expect(s0.encodingName == "h264")
    #expect(s0.rtpPayloadType == 96)
    #expect(s0.clockRateHz == 90000)
    #expect(s0.videoParameters?.rfc6381Codec == "avc1.4D002A")

    // Audio: rtpmap "pcmu/8000/1" overrides static type 8 (pcma)
    let s1 = p.streams[1]
    #expect(s1.control == url + "/audio")
    #expect(s1.media == "audio")
    #expect(s1.encodingName == "pcmu")
    #expect(s1.rtpPayloadType == 8)
    #expect(s1.clockRateHz == 8000)
    #expect(s1.channels == 1)

    // SETUP video
    let videoSetup = try parseSetup(response: try loadResponse("gw_main_setup_video.txt"))
    #expect(videoSetup.session.id == "9a90de54")
    #expect(videoSetup.session.timeoutSec == 60)
    #expect(videoSetup.channelId == 0)
    #expect(videoSetup.ssrc == nil)

    // SETUP audio
    let audioSetup = try parseSetup(response: try loadResponse("gw_main_setup_audio.txt"))
    #expect(audioSetup.session.id == "9a90de54")
    #expect(audioSetup.session.timeoutSec == 60)
    #expect(audioSetup.channelId == 2)
    #expect(audioSetup.ssrc == nil)

    // PLAY
    var pMut = p
    initStreamsForPlay(&pMut)
    let playResp = try loadResponse("gw_main_play.txt")
    try parsePlay(response: playResp, presentation: &pMut)
    // Upstream: RTP-Info url= isn't in expected format, so contents are skipped
    if case .setup(let init0) = pMut.streams[0].state {
      #expect(init0.initialSeq == nil)
      #expect(init0.initialRtptime == nil)
    } else {
      Issue.record("Stream 0 should be in setup state")
    }
    if case .setup(let init1) = pMut.streams[1].state {
      #expect(init1.initialSeq == nil)
      #expect(init1.initialRtptime == nil)
    } else {
      Issue.record("Stream 1 should be in setup state")
    }
  }

  // Test 16: gw_sub
  @Test("GW Security sub stream (single video stream)")
  func gwSub() throws {
    let url =
      "rtsp://192.168.1.110:5049/H264?channel=1&subtype=1&unicast=true&proto=Onvif"

    let p = try loadDescribe(url: url, filename: "gw_sub_describe.txt")
    #expect(p.control == url)
    #expect(p.streams.count == 1)

    let s0 = p.streams[0]
    #expect(s0.control == url + "/video")
    #expect(s0.media == "video")
    #expect(s0.encodingName == "h264")
    #expect(s0.rtpPayloadType == 96)
    #expect(s0.clockRateHz == 90000)
    #expect(s0.videoParameters?.rfc6381Codec == "avc1.4D001E")

    // SETUP
    let setup = try parseSetup(response: try loadResponse("gw_sub_setup.txt"))
    #expect(setup.session.id == "9b0d0e54")
    #expect(setup.session.timeoutSec == 60)
    #expect(setup.channelId == 0)
    #expect(setup.ssrc == nil)

    // PLAY
    var pMut = p
    initStreamsForPlay(&pMut)
    let playResp = try loadResponse("gw_sub_play.txt")
    try parsePlay(response: playResp, presentation: &pMut)
    if case .setup(let init0) = pMut.streams[0].state {
      #expect(init0.initialSeq == 273)
      #expect(init0.initialRtptime == 1_621_810_809)
    } else {
      Issue.record("Stream 0 should be in setup state")
    }
  }

  // Test: h264dvr (DESCRIBE + SETUP parsing, session ID change detection)
  @Test("H264DVR (dual framerate attrs, PCMA static type, session ID change)")
  func h264dvr() throws {
    let url = "rtsp://127.0.0.1:554/camera"

    let p = try loadDescribe(url: url, filename: "h264dvr_describe.txt")
    #expect(p.streams.count == 2)

    // Stream 0: H.264 video with dual framerate attrs (0S ignored, 25 used)
    let s0 = p.streams[0]
    #expect(s0.media == "video")
    #expect(s0.encodingName == "h264")
    #expect(s0.rtpPayloadType == 96)
    #expect(s0.clockRateHz == 90000)
    #expect(s0.framerate == 25.0)

    // Stream 1: PCMA audio (static payload type 8)
    let s1 = p.streams[1]
    #expect(s1.media == "audio")
    #expect(s1.encodingName == "pcma")
    #expect(s1.rtpPayloadType == 8)
    #expect(s1.clockRateHz == 8000)

    // SETUP video
    let videoSetup = try parseSetup(response: try loadResponse("h264dvr_setup_video.txt"))
    #expect(videoSetup.session.id == "231970")
    #expect(videoSetup.session.timeoutSec == 60)
    #expect(videoSetup.ssrc == 0)
    #expect(videoSetup.serverPort == 40004)

    // SETUP audio — different session ID (231980 vs 231970)
    let audioSetup = try parseSetup(response: try loadResponse("h264dvr_setup_audio.txt"))
    #expect(audioSetup.session.id == "231980")
    #expect(audioSetup.session.id != videoSetup.session.id)
    #expect(audioSetup.ssrc == 0)
    #expect(audioSetup.serverPort == 40006)
  }

  // Test 17: macrovideo
  @Test("Macrovideo (missing origin line)")
  func macrovideo() throws {
    let p = try loadDescribe(url: "rtsp://127.0.0.1/", filename: "macrovideo_describe.txt")
    #expect(p.streams.count == 1)
  }

  // Test 18: ipcam
  @Test("IPCAM (trailing space in rtpmap)")
  func ipcam() throws {
    let p = try loadDescribe(url: "rtsp://127.0.0.1/", filename: "ipcam_describe.txt")
    #expect(p.streams.count == 1)
  }

  // Test 19: rtp_info_trailing_semicolon
  // Uses gw_sub (single stream) to match upstream test
  @Test("RTP-Info trailing semicolon handled correctly")
  func rtpInfoTrailingSemicolon() throws {
    let url =
      "rtsp://192.168.1.110:5049/H264?channel=1&subtype=1&unicast=true&proto=Onvif"
    var p = try loadDescribe(url: url, filename: "gw_sub_describe.txt")
    // Set stream to setup state (as upstream does with dummy_stream_state_init)
    p.streams[0].state = .setup(
      StreamStateInit(ssrc: nil, initialSeq: nil, initialRtptime: nil, ctx: .dummy))
    let playResp = try loadResponse("laureii_play.txt")
    try parsePlay(response: playResp, presentation: &p)
    if case .setup(let init0) = p.streams[0].state {
      #expect(init0.initialSeq == 0)
      #expect(init0.initialRtptime == 0)
    } else {
      Issue.record("Stream 0 should be in setup state")
    }
  }

  // Test 20: hikvision_ssrc_with_leading_space
  // Upstream asserts all fields of SetupResponse
  @Test("Hikvision SSRC with leading space in Transport header")
  func hikvisionSSRCWithLeadingSpace() throws {
    let setupResp = try loadResponse("hikvision_setup_ssrc_space.txt")
    let setup = try parseSetup(response: setupResp)
    #expect(setup.session.id == "708886412")
    #expect(setup.session.timeoutSec == 60)
    #expect(setup.channelId == 0)
    #expect(setup.ssrc == 0x0D6D_6627)
    #expect(setup.source == nil)
    #expect(setup.serverPort == nil)
  }

  // Test 21: luckfox_setup_tcp
  @Test("Luckfox TCP SETUP response")
  func luckfoxSetupTCP() throws {
    let setup = try parseSetup(response: try loadResponse("luckfox_rkipc_setup_tcp.txt"))
    #expect(setup.session.id == "12345678")
    #expect(setup.session.timeoutSec == 60)
    #expect(setup.channelId == 0)
    #expect(setup.ssrc == 0x2234_5684)
    #expect(setup.source == nil)
    #expect(setup.serverPort == nil)
  }

  // Test 22: luckfox_setup_udp
  @Test("Luckfox UDP SETUP response")
  func luckfoxSetupUDP() throws {
    let setup = try parseSetup(response: try loadResponse("luckfox_rkipc_setup_udp.txt"))
    #expect(setup.session.id == "12345678")
    #expect(setup.session.timeoutSec == 60)
    #expect(setup.channelId == nil)
    #expect(setup.ssrc == 0x2234_5685)
    #expect(setup.source == nil)
    #expect(setup.serverPort == 49152)
  }
}
