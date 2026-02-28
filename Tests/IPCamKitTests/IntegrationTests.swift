// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Integration test exercising the full RTP -> VideoFrame pipeline

import Foundation
import Testing

@testable import IPCamKit

@Suite("Integration Tests")
struct IntegrationTests {

  /// Test the full pipeline: RTP packets -> InorderParser -> H264Depacketizer -> VideoFrame.
  @Test("Full RTP to VideoFrame pipeline")
  func fullPipeline() throws {
    let clockRate: UInt32 = 90000
    let fmtp =
      "packetization-mode=1;profile-level-id=640033;sprop-parameter-sets=Z2QAM6wVFKCgL/lQ,aO48sA=="

    // Create depacketizer with initial params from SDP
    var depacketizer = try H264Depacketizer(
      clockRate: clockRate, formatSpecificParams: fmtp)
    #expect(depacketizer.parameters != nil)
    #expect(depacketizer.parameters!.genericParameters.pixelDimensions?.width == 640)
    #expect(depacketizer.parameters!.genericParameters.pixelDimensions?.height == 360)

    // Create timeline and inorder parser
    var timeline = try Timeline(start: nil, clockRate: clockRate, enforceMaxJumpSecs: 10)
    var parser = InorderParser(
      ssrc: nil, nextSeq: nil, isTcp: true, timeline: timeline)

    // Build RTP packets for a complete IDR frame:
    // 1. SPS (same as sprop, should NOT trigger parameter change)
    // 2. PPS (same as sprop)
    // 3. IDR slice

    let spsPayload = Data([
      0x67, 0x64, 0x00, 0x33, 0xAC, 0x15, 0x14, 0xA0,
      0xA0, 0x2F, 0xF9, 0x50,
    ])
    let ppsPayload = Data([0x68, 0xEE, 0x3C, 0xB0])
    let idrPayload = Data([0x65, 0x88, 0x84, 0x00, 0x4E, 0xFF, 0xFE, 0xF8])

    // Construct RTP packets via builder
    let rtpTimestamp: UInt32 = 1000
    let ssrc: UInt32 = 0x1234_5678

    let spsRTP = RTPPacketBuilder(
      sequenceNumber: 1, timestamp: rtpTimestamp, payloadType: 96,
      ssrc: ssrc, mark: false
    )
    let ppsRTP = RTPPacketBuilder(
      sequenceNumber: 2, timestamp: rtpTimestamp, payloadType: 96,
      ssrc: ssrc, mark: false
    )
    let idrRTP = RTPPacketBuilder(
      sequenceNumber: 3, timestamp: rtpTimestamp, payloadType: 96,
      ssrc: ssrc, mark: true
    )

    let spsData = try spsRTP.build(payload: spsPayload).get().data
    let ppsData = try ppsRTP.build(payload: ppsPayload).get().data
    let idrData = try idrRTP.build(payload: idrPayload).get().data

    // Feed through InorderParser
    let pkt1 = try parser.rtp(data: spsData, ctx: .dummy, streamId: 0, streamCtx: .dummy)
    #expect(pkt1 != nil)
    try depacketizer.push(pkt1!)
    #expect(depacketizer.pull() == nil)

    let pkt2 = try parser.rtp(data: ppsData, ctx: .dummy, streamId: 0, streamCtx: .dummy)
    #expect(pkt2 != nil)
    try depacketizer.push(pkt2!)
    #expect(depacketizer.pull() == nil)

    let pkt3 = try parser.rtp(data: idrData, ctx: .dummy, streamId: 0, streamCtx: .dummy)
    #expect(pkt3 != nil)
    try depacketizer.push(pkt3!)

    // Should produce a video frame
    guard case .success(.videoFrame(let frame)) = depacketizer.pull() else {
      Issue.record("Expected video frame from pipeline")
      return
    }

    // Verify frame properties
    #expect(frame.isRandomAccessPoint == true)
    #expect(frame.loss == 0)

    // Verify AVCC data structure (3 NALs with 4-byte length prefixes)
    var offset = frame.data.startIndex
    var nalCount = 0
    while offset + 4 <= frame.data.endIndex {
      let len =
        Int(frame.data[offset]) << 24
        | Int(frame.data[offset + 1]) << 16
        | Int(frame.data[offset + 2]) << 8
        | Int(frame.data[offset + 3])
      offset += 4 + len
      nalCount += 1
    }
    #expect(nalCount == 3)  // SPS + PPS + IDR

    // No more frames
    #expect(depacketizer.pull() == nil)
  }

  /// Test a second GOP with non-IDR slices.
  @Test("Second GOP with non-IDR slices")
  func secondGOP() throws {
    let clockRate: UInt32 = 90000
    var depacketizer = try H264Depacketizer(clockRate: clockRate, formatSpecificParams: nil)
    var timeline = try Timeline(start: nil, clockRate: clockRate)
    var parser = InorderParser(
      ssrc: nil, nextSeq: nil, isTcp: true, timeline: timeline)

    let ssrc: UInt32 = 0xABCD

    // Frame 1: SPS + PPS + IDR (timestamp 0)
    let sps = Data([0x67, 0x64, 0x00, 0x33, 0xAC, 0x15, 0x14, 0xA0, 0xA0, 0x2F, 0xF9, 0x50])
    let pps = Data([0x68, 0xEE, 0x3C, 0xB0])
    let idr = Data([0x65, 0x88, 0x84])

    for (seq, (payload, mark)) in [(sps, false), (pps, false), (idr, true)].enumerated() {
      let rtp = try RTPPacketBuilder(
        sequenceNumber: UInt16(seq), timestamp: 0, payloadType: 96,
        ssrc: ssrc, mark: mark
      ).build(payload: payload).get().data
      if let pkt = try parser.rtp(data: rtp, ctx: .dummy, streamId: 0, streamCtx: .dummy) {
        try depacketizer.push(pkt)
      }
    }

    guard case .success(.videoFrame(let frame1)) = depacketizer.pull() else {
      Issue.record("Expected first frame")
      return
    }
    #expect(frame1.isRandomAccessPoint == true)
    #expect(frame1.hasNewParameters == true)

    // Frame 2: Non-IDR slice (timestamp 3000)
    let nonIDR = Data([0x01, 0x9E, 0x01])
    let rtp2 = try RTPPacketBuilder(
      sequenceNumber: 3, timestamp: 3000, payloadType: 96,
      ssrc: ssrc, mark: true
    ).build(payload: nonIDR).get().data
    if let pkt = try parser.rtp(data: rtp2, ctx: .dummy, streamId: 0, streamCtx: .dummy) {
      try depacketizer.push(pkt)
    }

    guard case .success(.videoFrame(let frame2)) = depacketizer.pull() else {
      Issue.record("Expected second frame")
      return
    }
    #expect(frame2.isRandomAccessPoint == false)
    #expect(frame2.hasNewParameters == false)
  }
}
