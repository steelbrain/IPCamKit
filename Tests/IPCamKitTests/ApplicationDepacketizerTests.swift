// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Tests for ApplicationDepacketizer (ONVIF metadata RTP payload).

import Foundation
import Testing

@testable import IPCamKit

@Suite("Application Depacketizer Tests")
struct ApplicationDepacketizerTests {

  // MARK: - Helpers

  private func ts(_ value: UInt32) -> Timestamp {
    Timestamp(timestamp: Int64(value), clockRate: 90_000, start: 0)!
  }

  private func makeMetadataPacket(
    seq: UInt16, timestamp: UInt32, mark: Bool, loss: UInt16 = 0,
    payload: Data
  ) -> ReceivedRTPPacket {
    let builder = ReceivedPacketBuilder(
      ctx: .dummy, streamId: 0, sequenceNumber: seq,
      timestamp: ts(timestamp), payloadType: 107, ssrc: 0x12_34_56_78,
      mark: mark, loss: loss)
    return try! builder.build(payload: payload).get()
  }

  private func pullFrame(
    _ d: inout ApplicationDepacketizer, _ comment: Comment? = nil
  ) -> MetadataFrame? {
    guard let result = d.pull() else { return nil }
    switch result {
    case .success(.metadataFrame(let frame)):
      return frame
    default:
      Issue.record(comment ?? "Expected metadataFrame, got \(result)")
      return nil
    }
  }

  // MARK: - Happy path

  @Test("Single-packet document emits one frame with marker bit")
  func singlePacketDocument() throws {
    var d = ApplicationDepacketizer()
    let xml = Data("<tt:MetaDataStream/>".utf8)
    try d.push(makeMetadataPacket(seq: 0, timestamp: 1000, mark: true, payload: xml))
    let frame = pullFrame(&d)
    #expect(frame?.data == xml)
    #expect(frame?.loss == 0)
    #expect(frame?.timestamp == ts(1000))
    #expect(d.pull() == nil)
  }

  @Test("Multi-packet document concatenates payload and emits on marker")
  func multiPacketDocument() throws {
    var d = ApplicationDepacketizer()
    try d.push(makeMetadataPacket(seq: 0, timestamp: 1000, mark: false, payload: Data("<root>".utf8)))
    #expect(d.pull() == nil)
    try d.push(makeMetadataPacket(seq: 1, timestamp: 1000, mark: false, payload: Data("body".utf8)))
    #expect(d.pull() == nil)
    try d.push(makeMetadataPacket(seq: 2, timestamp: 1000, mark: true, payload: Data("</root>".utf8)))
    let frame = pullFrame(&d)
    #expect(frame?.data == Data("<root>body</root>".utf8))
    #expect(frame?.loss == 0)
    // Timestamp reflects the last packet (marker packet).
    #expect(frame?.timestamp == ts(1000))
    #expect(d.pull() == nil)
  }

  @Test("Two consecutive documents emit independently")
  func twoConsecutiveDocuments() throws {
    var d = ApplicationDepacketizer()
    try d.push(makeMetadataPacket(seq: 0, timestamp: 1000, mark: true, payload: Data("doc1".utf8)))
    let f1 = pullFrame(&d)
    #expect(f1?.data == Data("doc1".utf8))
    #expect(f1?.loss == 0)
    try d.push(makeMetadataPacket(seq: 1, timestamp: 91_000, mark: true, payload: Data("doc2".utf8)))
    let f2 = pullFrame(&d)
    #expect(f2?.data == Data("doc2".utf8))
    #expect(f2?.loss == 0)
  }

  // MARK: - Loss

  @Test("Initial loss surfaces on the first emitted frame")
  func initialLossOnFirstFrame() throws {
    var d = ApplicationDepacketizer()
    try d.push(
      makeMetadataPacket(seq: 3, timestamp: 1000, mark: true, loss: 3, payload: Data("ok".utf8)))
    let frame = pullFrame(&d)
    #expect(frame?.loss == 3)
    #expect(frame?.data == Data("ok".utf8))
  }

  @Test("Loss between two complete documents is reported on the second")
  func lossBetweenDocuments() throws {
    var d = ApplicationDepacketizer()
    try d.push(makeMetadataPacket(seq: 0, timestamp: 1000, mark: true, payload: Data("a".utf8)))
    #expect(pullFrame(&d)?.loss == 0)
    try d.push(
      makeMetadataPacket(seq: 5, timestamp: 2000, mark: true, loss: 4, payload: Data("b".utf8)))
    let frame = pullFrame(&d)
    #expect(frame?.loss == 4)
    #expect(frame?.data == Data("b".utf8))
  }

  @Test("Loss on the marker packet with a non-empty prefix drops the doc")
  func lossOnMarkerWithPrefix() throws {
    var d = ApplicationDepacketizer()
    try d.push(makeMetadataPacket(seq: 0, timestamp: 1000, mark: false, payload: Data("aaa".utf8)))
    // Marker packet itself carries loss > 0 — the prefix is unusable and
    // we can't trust the marker packet's payload either.
    try d.push(
      makeMetadataPacket(seq: 2, timestamp: 1000, mark: true, loss: 2, payload: Data("bbb".utf8)))
    #expect(d.pull() == nil)
    // Loss is carried to the next clean document.
    try d.push(makeMetadataPacket(seq: 3, timestamp: 2000, mark: true, payload: Data("ok".utf8)))
    let frame = pullFrame(&d)
    #expect(frame?.loss == 2)
    #expect(frame?.data == Data("ok".utf8))
  }

  @Test("Mid-document loss discards prefix and carries loss to next clean frame")
  func midDocumentLossDiscards() throws {
    var d = ApplicationDepacketizer()
    try d.push(makeMetadataPacket(seq: 0, timestamp: 1000, mark: false, payload: Data("aaa".utf8)))
    // Loss in the middle of the document — the buffered "aaa" is unusable.
    try d.push(
      makeMetadataPacket(seq: 2, timestamp: 1000, mark: false, loss: 1, payload: Data("bbb".utf8)))
    // Marker closes the unusable document — no frame emitted.
    try d.push(makeMetadataPacket(seq: 3, timestamp: 1000, mark: true, payload: Data("ccc".utf8)))
    #expect(d.pull() == nil)
    // Next clean document carries the loss=1.
    try d.push(makeMetadataPacket(seq: 4, timestamp: 2000, mark: true, payload: Data("ok".utf8)))
    let frame = pullFrame(&d)
    #expect(frame?.loss == 1)
    #expect(frame?.data == Data("ok".utf8))
  }

  // MARK: - Cap and recovery

  @Test("Document over cap fires diagnostic, drops, and recovers on next marker")
  func overflowDiagnosticAndRecovery() throws {
    final class Box: @unchecked Sendable {
      var diagnostics: [RTSPDiagnostic] = []
    }
    let box = Box()
    var d = ApplicationDepacketizer { box.diagnostics.append($0) }

    // RTP packets are capped at 64 KiB by the transport, so simulate
    // overflow with many 60 KiB unmarked packets that together exceed
    // the 1 MiB depacketizer cap.
    let chunk = Data(repeating: 0x42, count: 60_000)
    for seq in 0..<20 {
      try d.push(
        makeMetadataPacket(seq: UInt16(seq), timestamp: 1000, mark: false, payload: chunk))
    }
    #expect(d.pull() == nil)
    #expect(box.diagnostics.count == 1)
    #expect(box.diagnostics.first?.severity == .warning)

    // Marker on the abandoned document — no emit, depacketizer resets.
    try d.push(
      makeMetadataPacket(seq: 100, timestamp: 1000, mark: true, payload: Data("end".utf8)))
    #expect(d.pull() == nil)

    // Next clean document emits normally.
    try d.push(
      makeMetadataPacket(seq: 101, timestamp: 2000, mark: true, payload: Data("clean".utf8)))
    let frame = pullFrame(&d)
    #expect(frame?.data == Data("clean".utf8))
  }

  @Test("Repeated overflow within one in-flight document emits only one warning")
  func overflowWarningIsRateLimited() throws {
    final class Box: @unchecked Sendable {
      var diagnostics: [RTSPDiagnostic] = []
    }
    let box = Box()
    var d = ApplicationDepacketizer { box.diagnostics.append($0) }

    let chunk = Data(repeating: 0x00, count: 60_000)
    // First overflow cycle: accumulate past 1 MiB, see one warning.
    for seq in 0..<20 {
      try d.push(
        makeMetadataPacket(seq: UInt16(seq), timestamp: 1000, mark: false, payload: chunk))
    }
    #expect(box.diagnostics.count == 1)

    // Continue piling on more packets in the same in-flight document —
    // each one is dropped while waiting for the marker, no new warnings.
    for seq in 20..<40 {
      try d.push(
        makeMetadataPacket(seq: UInt16(seq), timestamp: 1000, mark: false, payload: chunk))
    }
    #expect(box.diagnostics.count == 1)

    // Marker resets the depacketizer. A fresh overflow then fires a new warning.
    try d.push(
      makeMetadataPacket(seq: 100, timestamp: 1000, mark: true, payload: Data("end".utf8)))
    for seq in 101..<121 {
      try d.push(
        makeMetadataPacket(seq: UInt16(seq), timestamp: 2000, mark: false, payload: chunk))
    }
    #expect(box.diagnostics.count == 2)
  }

  // MARK: - Edge cases

  @Test("Marker on empty payload at idle emits nothing")
  func emptyPayloadWithMarkerAtIdle() throws {
    var d = ApplicationDepacketizer()
    try d.push(makeMetadataPacket(seq: 0, timestamp: 1000, mark: true, payload: Data()))
    #expect(d.pull() == nil)
  }

  @Test("Marker on empty payload mid-document still emits buffered bytes")
  func emptyPayloadMarkerEmitsBufferedBytes() throws {
    var d = ApplicationDepacketizer()
    try d.push(makeMetadataPacket(seq: 0, timestamp: 1000, mark: false, payload: Data("xyz".utf8)))
    try d.push(makeMetadataPacket(seq: 1, timestamp: 1000, mark: true, payload: Data()))
    let frame = pullFrame(&d)
    #expect(frame?.data == Data("xyz".utf8))
  }
}
