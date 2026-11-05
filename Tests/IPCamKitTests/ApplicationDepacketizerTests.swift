// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Tests for ApplicationDepacketizer (ONVIF metadata RTP payload).

import Foundation
import Testing

@testable import IPCamKit

/// Packets a new `ApplicationDepacketizer` receives first, for one encoding.
struct MetadataFirstPacketCase: Sendable, CustomStringConvertible {
  var name: String
  /// SDP encoding name; nil when not given.
  var encodingName: String?
  /// The marked last packet of a document whose earlier packets were not received.
  var tail: [UInt8]
  /// The packets of one whole document, the last one marked.
  var document: [[UInt8]]
  var description: String { name }
}

private let metadataXMLDocument = Array(
  ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    + "<tt:MetadataStream xmlns:tt=\"http://www.onvif.org/ver10/schema\">"
    + "<tt:VideoAnalytics/></tt:MetadataStream>").utf8)
private let metadataXMLTail = Array("</tt:VideoAnalytics></tt:MetadataStream>".utf8)
/// Gzip member header (deflate, no flags, unknown OS) followed by deflate data.
private let metadataGzipHeader: [UInt8] = [0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF]
/// Deflate data from the middle of a gzip member.
private let metadataGzipTail: [UInt8] = [0x5D, 0x8E, 0xCB, 0x0A, 0xC2, 0x30, 0x10, 0x45]
/// EXI body bytes; 0x3C does not begin with the distinguishing bits `10`.
private let metadataEXITail: [UInt8] = [0x3C, 0x12, 0x9A, 0x07]

private let metadataFirstPacketCases: [MetadataFirstPacketCase] = [
  MetadataFirstPacketCase(
    name: "xml", encodingName: "vnd.onvif.metadata", tail: metadataXMLTail,
    document: [metadataXMLDocument]),
  MetadataFirstPacketCase(
    name: "xml, no declaration, BOM and whitespace, two packets",
    encodingName: "vnd.onvif.metadata", tail: metadataXMLTail,
    document: [
      [0xEF, 0xBB, 0xBF] + Array("\r\n<tt:MetadataStream xmlns:tt=\"urn:x\">".utf8),
      Array("<tt:VideoAnalytics/></tt:MetadataStream>".utf8),
    ]),
  MetadataFirstPacketCase(
    name: "gzip", encodingName: "vnd.onvif.metadata.gzip", tail: metadataGzipTail,
    document: [metadataGzipHeader + [0x4B, 0x4C, 0x4A, 0x06, 0x00], [0xC2, 0x41, 0x24, 0x35]]),
  MetadataFirstPacketCase(
    name: "exi cookie", encodingName: "vnd.onvif.metadata.exi.onvif", tail: metadataEXITail,
    document: [Array("$EXI".utf8) + [0x80, 0x40, 0x1C, 0x22]]),
  MetadataFirstPacketCase(
    name: "exi distinguishing bits", encodingName: "vnd.onvif.metadata.exi.ext",
    tail: metadataEXITail, document: [[0x80, 0x40, 0x1C, 0x22]]),
  MetadataFirstPacketCase(
    name: "no encoding name", encodingName: nil, tail: metadataXMLTail,
    document: [metadataXMLDocument]),
]

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

  /// A metadata document split as a camera might split it: the XML declaration
  /// and root start tag, the content, and the root end tag.
  private static let head = Data(
    ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
      + "<tt:MetadataStream xmlns:tt=\"http://www.onvif.org/ver10/schema\">").utf8)
  private static let body = Data(
    ("<tt:VideoAnalytics><tt:Frame UtcTime=\"2026-01-01T00:00:00Z\"/>"
      + "</tt:VideoAnalytics>").utf8)
  private static let tail = Data("</tt:MetadataStream>".utf8)

  /// A complete single-packet metadata document; `n` makes each one distinct.
  private func document(_ n: Int) -> Data {
    let frame = Data(
      ("<tt:VideoAnalytics><tt:Frame UtcTime=\"2026-01-01T00:00:0\(n)Z\"/>"
        + "</tt:VideoAnalytics>").utf8)
    return Self.head + frame + Self.tail
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
    try d.push(makeMetadataPacket(seq: 0, timestamp: 1000, mark: false, payload: Self.head))
    #expect(d.pull() == nil)
    try d.push(makeMetadataPacket(seq: 1, timestamp: 1000, mark: false, payload: Self.body))
    #expect(d.pull() == nil)
    try d.push(makeMetadataPacket(seq: 2, timestamp: 1000, mark: true, payload: Self.tail))
    let frame = pullFrame(&d)
    #expect(frame?.data == Self.head + Self.body + Self.tail)
    #expect(frame?.loss == 0)
    // Timestamp reflects the last packet (marker packet).
    #expect(frame?.timestamp == ts(1000))
    #expect(d.pull() == nil)
  }

  @Test("Two consecutive documents emit independently")
  func twoConsecutiveDocuments() throws {
    var d = ApplicationDepacketizer()
    try d.push(makeMetadataPacket(seq: 0, timestamp: 1000, mark: true, payload: document(1)))
    let f1 = pullFrame(&d)
    #expect(f1?.data == document(1))
    #expect(f1?.loss == 0)
    try d.push(makeMetadataPacket(seq: 1, timestamp: 91_000, mark: true, payload: document(2)))
    let f2 = pullFrame(&d)
    #expect(f2?.data == document(2))
    #expect(f2?.loss == 0)
  }

  // MARK: - Loss

  @Test("Initial loss surfaces on the first emitted frame")
  func initialLossOnFirstFrame() throws {
    var d = ApplicationDepacketizer()
    // After loss a packet is kept only if it starts a document.
    let doc = Data("<tt:MetadataStream/>".utf8)
    try d.push(makeMetadataPacket(seq: 3, timestamp: 1000, mark: true, loss: 3, payload: doc))
    let frame = pullFrame(&d)
    #expect(frame?.loss == 3)
    #expect(frame?.data == doc)
  }

  @Test("Loss between two complete documents is reported on the second")
  func lossBetweenDocuments() throws {
    var d = ApplicationDepacketizer()
    try d.push(makeMetadataPacket(seq: 0, timestamp: 1000, mark: true, payload: document(1)))
    #expect(pullFrame(&d)?.loss == 0)
    let doc = Data("<?xml version=\"1.0\"?><tt:MetadataStream/>".utf8)
    try d.push(makeMetadataPacket(seq: 5, timestamp: 2000, mark: true, loss: 4, payload: doc))
    let frame = pullFrame(&d)
    #expect(frame?.loss == 4)
    #expect(frame?.data == doc)
  }

  @Test("Loss on the marker packet with a non-empty prefix drops the doc")
  func lossOnMarkerWithPrefix() throws {
    var d = ApplicationDepacketizer()
    try d.push(makeMetadataPacket(seq: 0, timestamp: 1000, mark: false, payload: Self.head))
    // Marker packet itself carries loss > 0 — the prefix is unusable and
    // we can't trust the marker packet's payload either.
    try d.push(
      makeMetadataPacket(seq: 2, timestamp: 1000, mark: true, loss: 2, payload: Self.tail))
    #expect(d.pull() == nil)
    // Loss is carried to the next clean document.
    try d.push(makeMetadataPacket(seq: 3, timestamp: 2000, mark: true, payload: document(2)))
    let frame = pullFrame(&d)
    #expect(frame?.loss == 2)
    #expect(frame?.data == document(2))
  }

  @Test("Mid-document loss discards prefix and carries loss to next clean frame")
  func midDocumentLossDiscards() throws {
    var d = ApplicationDepacketizer()
    try d.push(makeMetadataPacket(seq: 0, timestamp: 1000, mark: false, payload: Self.head))
    // Loss in the middle of the document — the buffered head is unusable.
    try d.push(
      makeMetadataPacket(seq: 2, timestamp: 1000, mark: false, loss: 1, payload: Self.body))
    // Marker closes the unusable document — no frame emitted.
    try d.push(makeMetadataPacket(seq: 3, timestamp: 1000, mark: true, payload: Self.tail))
    #expect(d.pull() == nil)
    // Next clean document carries the loss=1.
    try d.push(makeMetadataPacket(seq: 4, timestamp: 2000, mark: true, payload: document(2)))
    let frame = pullFrame(&d)
    #expect(frame?.loss == 1)
    #expect(frame?.data == document(2))
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
    // the 1 MiB depacketizer cap. The first one starts the document.
    let start = Self.head + Data(repeating: 0x42, count: 60_000 - Self.head.count)
    let chunk = Data(repeating: 0x42, count: 60_000)
    for seq in 0..<20 {
      try d.push(
        makeMetadataPacket(
          seq: UInt16(seq), timestamp: 1000, mark: false, payload: seq == 0 ? start : chunk))
    }
    #expect(d.pull() == nil)
    #expect(box.diagnostics.count == 1)
    #expect(box.diagnostics.first?.severity == .warning)

    // Marker on the abandoned document — no emit, depacketizer resets.
    try d.push(makeMetadataPacket(seq: 100, timestamp: 1000, mark: true, payload: Self.tail))
    #expect(d.pull() == nil)

    // Next clean document emits normally.
    try d.push(makeMetadataPacket(seq: 101, timestamp: 2000, mark: true, payload: document(2)))
    let frame = pullFrame(&d)
    #expect(frame?.data == document(2))
  }

  @Test("Repeated overflow within one in-flight document emits only one warning")
  func overflowWarningIsRateLimited() throws {
    final class Box: @unchecked Sendable {
      var diagnostics: [RTSPDiagnostic] = []
    }
    let box = Box()
    var d = ApplicationDepacketizer { box.diagnostics.append($0) }

    let start = Self.head + Data(repeating: 0x00, count: 60_000 - Self.head.count)
    let chunk = Data(repeating: 0x00, count: 60_000)
    // First overflow cycle: accumulate past 1 MiB, see one warning.
    for seq in 0..<20 {
      try d.push(
        makeMetadataPacket(
          seq: UInt16(seq), timestamp: 1000, mark: false, payload: seq == 0 ? start : chunk))
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
    try d.push(makeMetadataPacket(seq: 100, timestamp: 1000, mark: true, payload: Self.tail))
    for seq in 101..<121 {
      try d.push(
        makeMetadataPacket(
          seq: UInt16(seq), timestamp: 2000, mark: false, payload: seq == 101 ? start : chunk))
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
    try d.push(makeMetadataPacket(seq: 0, timestamp: 1000, mark: false, payload: document(1)))
    try d.push(makeMetadataPacket(seq: 1, timestamp: 1000, mark: true, payload: Data()))
    let frame = pullFrame(&d)
    #expect(frame?.data == document(1))
  }

  // MARK: - First packet

  @Test(
    "A new depacketizer drops the rest of a document whose start it never got",
    arguments: metadataFirstPacketCases)
  func newDepacketizerDropsDocumentTail(_ c: MetadataFirstPacketCase) throws {
    var d = ApplicationDepacketizer(encodingName: c.encodingName)
    // No loss is reported: after a seek this is the end of a document from the
    // previous position; over UDP the packets before it were lost unseen.
    try d.push(makeMetadataPacket(seq: 7, timestamp: 1000, mark: true, payload: Data(c.tail)))
    #expect(d.pull() == nil, "tail delivered as a document")
    for (i, packet) in c.document.enumerated() {
      try d.push(
        makeMetadataPacket(
          seq: UInt16(8 + i), timestamp: 2000, mark: i == c.document.count - 1,
          payload: Data(packet)))
    }
    let frame = pullFrame(&d)
    #expect(frame?.data == Data(c.document.joined()))
    // The dropped packets are not loss: the sequence numbers have no gap.
    #expect(frame?.loss == 0)
    #expect(frame?.timestamp == ts(2000))
  }

  @Test("A new depacketizer drops every packet of that document up to the marker")
  func newDepacketizerDropsUntilMarker() throws {
    var d = ApplicationDepacketizer(encodingName: "vnd.onvif.metadata")
    try d.push(makeMetadataPacket(seq: 0, timestamp: 1000, mark: false, payload: Self.body))
    // Looks like a start, but it is still the dropped document: only a marker ends it.
    try d.push(makeMetadataPacket(seq: 1, timestamp: 1000, mark: false, payload: Self.head))
    try d.push(makeMetadataPacket(seq: 2, timestamp: 1000, mark: true, payload: Self.tail))
    #expect(d.pull() == nil)
    try d.push(makeMetadataPacket(seq: 3, timestamp: 2000, mark: false, payload: Self.head))
    try d.push(makeMetadataPacket(seq: 4, timestamp: 2000, mark: false, payload: Self.body))
    try d.push(makeMetadataPacket(seq: 5, timestamp: 2000, mark: true, payload: Self.tail))
    let frame = pullFrame(&d)
    #expect(frame?.data == Self.head + Self.body + Self.tail)
    #expect(frame?.loss == 0)
  }

  @Test(
    "A new depacketizer delivers a first document that starts in its first packet",
    arguments: metadataFirstPacketCases)
  func newDepacketizerDeliversDocumentStart(_ c: MetadataFirstPacketCase) throws {
    var d = ApplicationDepacketizer(encodingName: c.encodingName)
    for (i, packet) in c.document.enumerated() {
      try d.push(
        makeMetadataPacket(
          seq: UInt16(i), timestamp: 1000, mark: i == c.document.count - 1,
          payload: Data(packet)))
    }
    let frame = pullFrame(&d)
    #expect(frame?.data == Data(c.document.joined()))
    #expect(frame?.loss == 0)
  }

  @Test("Only the first packet must start a document; later ones follow the markers")
  func laterDocumentsAreNotChecked() throws {
    var d = ApplicationDepacketizer(encodingName: "vnd.onvif.metadata")
    try d.push(makeMetadataPacket(seq: 0, timestamp: 1000, mark: true, payload: document(1)))
    #expect(pullFrame(&d)?.data == document(1))
    // After a marker with no loss, the next packet starts a document even if
    // its first bytes aren't recognized as a start.
    let commented = Data("<!-- camera 1 -->".utf8) + document(2)
    try d.push(makeMetadataPacket(seq: 1, timestamp: 2000, mark: true, payload: commented))
    let frame = pullFrame(&d)
    #expect(frame?.data == commented)
    #expect(frame?.loss == 0)
  }
}
