// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Depacketizer for RTSP `application` streams carrying ONVIF analytics metadata.

import Foundation

/// Depacketizer for the ONVIF metadata RTP payload format (`vnd.onvif.metadata`).
///
/// Per the ONVIF Streaming Specification, payloads concatenate across packets
/// until the RTP marker bit, which signals end-of-document. The loss count is
/// forwarded to the next completed frame so consumers can detect dropped events.
///
/// Recovery semantics:
/// - The first packet a new depacketizer receives is treated like a packet
///   after loss at a document boundary (below): kept only if it starts a
///   document, otherwise dropped with the rest of its document until the next
///   marker. A new depacketizer can't know where the documents before that
///   packet ended: after a seek the packet may be the rest of a document from
///   the previous position, and over UDP the packets before it may have been
///   lost with no known sequence number to report the gap. Like the packets
///   dropped after loss, the dropped packets are not counted in `loss`, which
///   counts RTP sequence gaps.
/// - After packet loss, the packet reporting the loss is kept only if it
///   starts a document. Otherwise it and the rest of its document are
///   dropped until the next marker, so a document missing its beginning is
///   not emitted (for EXI, see below). Loss mid-document (part of a document
///   buffered) also discards the buffered prefix. The loss surfaces on the
///   next emitted frame either way.
/// - A packet starts a document when it begins with `<?xml` or a
///   `MetadataStream` root element (any case, any namespace prefix, after an
///   optional UTF-8 BOM and whitespace) for XML; the gzip header `1F 8B 08`
///   for gzip; the `$EXI` cookie or the EXI distinguishing bits `10` for EXI.
///   With an unknown encoding, any of these except the distinguishing bits
///   counts.
/// - About one byte in four begins with the distinguishing bits. They count
///   in the first packet and after loss at a document boundary (nothing
///   buffered, or already dropping until a marker), so there the rest of an
///   EXI document can be emitted if its first byte begins with them. After
///   loss mid-document the packet is often the rest of the abandoned
///   document, so there only the `$EXI` cookie counts, and an EXI document
///   without the cookie that follows such a loss is dropped.
/// - Buffer overflow (oversized document) discards the prefix, fires a
///   `warning` diagnostic, and drops the rest of that document until the
///   next marker — same as the loss case. The next document emits normally.
struct ApplicationDepacketizer: Sendable {
  /// Hard cap on a single accumulated document. ONVIF places no limit on
  /// document size, but real metadata documents are on the order of a few KB
  /// per second; anything above this points at a malformed stream.
  static let maxFragmentBytes = 1 << 20  // 1 MiB

  private var buffer = Data()
  /// Packet context + timestamp of the last packet appended into `buffer`.
  private var lastCtx: PacketContext = .dummy
  private var lastStreamId: Int = 0
  private var lastTimestamp: Timestamp?
  /// Loss accumulated across packets contributing to the in-progress document.
  /// Cleared once a frame is emitted; carried across drops so the consumer
  /// always sees a non-zero loss on the next good frame.
  private var pendingLoss: UInt32 = 0
  /// True after a mid-document loss; the document under construction is
  /// abandoned and we wait for the next marker before resuming.
  private var dropUntilMark: Bool = false
  /// True until the first packet is pushed. That packet may be the rest of a
  /// document whose beginning this depacketizer never saw.
  private var awaitingFirstPacket: Bool = true
  /// True after an overflow diagnostic has fired since the last marker; used
  /// to avoid spamming diagnostics if every packet in the same in-flight
  /// document keeps overshooting the cap.
  private var warnedSinceMark: Bool = false
  private var ready: MetadataFrame?
  private let encoding: Encoding
  private let onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)?

  /// The payload encoding, which decides what a document's first bytes look
  /// like.
  enum Encoding: Sendable, Equatable {
    /// `vnd.onvif.metadata`: UTF-8 XML.
    case xml
    /// `vnd.onvif.metadata.gzip`: gzip-compressed XML.
    case gzip
    /// `vnd.onvif.metadata.exi.onvif` / `vnd.onvif.metadata.exi.ext`.
    case exi
    /// Any other or unknown encoding name.
    case unknown

    init(encodingName: String?) {
      switch encodingName?.lowercased() {
      case "vnd.onvif.metadata": self = .xml
      case "vnd.onvif.metadata.gzip": self = .gzip
      case "vnd.onvif.metadata.exi.onvif", "vnd.onvif.metadata.exi.ext": self = .exi
      default: self = .unknown
      }
    }
  }

  /// - Parameter encodingName: the SDP encoding name of the stream (e.g.
  ///   `vnd.onvif.metadata`), used to recognize a document start in the
  ///   first packet and after loss.
  ///   nil accepts the start of any known encoding.
  init(
    encodingName: String? = nil,
    onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)? = nil
  ) {
    self.encoding = Encoding(encodingName: encodingName)
    self.onDiagnostic = onDiagnostic
  }

  /// Whether `payload` begins a metadata document in `encoding`, judged from
  /// its first bytes. See "Recovery semantics" above.
  static func startsDocument(_ payload: Data, encoding: Encoding) -> Bool {
    switch encoding {
    case .xml: return startsXMLDocument(payload)
    case .gzip: return startsGzip(payload)
    case .exi: return hasEXICookie(payload) || hasEXIDistinguishingBits(payload)
    case .unknown:
      return startsXMLDocument(payload) || startsGzip(payload) || hasEXICookie(payload)
    }
  }

  private static func startsGzip(_ payload: Data) -> Bool {
    payload.starts(with: [0x1F, 0x8B, 0x08])
  }

  private static func hasEXICookie(_ payload: Data) -> Bool {
    payload.starts(with: Array("$EXI".utf8))
  }

  private static func hasEXIDistinguishingBits(_ payload: Data) -> Bool {
    guard let first = payload.first else { return false }
    return first & 0b1100_0000 == 0b1000_0000
  }

  /// `<?xml`, or a start tag whose local name is `MetadataStream` (any case),
  /// after an optional UTF-8 BOM and ASCII whitespace.
  private static func startsXMLDocument(_ payload: Data) -> Bool {
    var bytes = payload.prefix(256)[...]
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
    bytes = bytes.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D || $0 == 0x0A }
    guard bytes.first == UInt8(ascii: "<") else { return false }
    bytes = bytes.dropFirst()
    if bytes.starts(with: Array("?xml".utf8)) { return true }
    let name = bytes.prefix { byte in
      byte != 0x20 && byte != 0x09 && byte != 0x0D && byte != 0x0A
        && byte != UInt8(ascii: ">") && byte != UInt8(ascii: "/")
    }
    // The name must end within the inspected bytes.
    guard name.count < bytes.count else { return false }
    let localName =
      name.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false)
      .last ?? name
    return String(decoding: localName, as: UTF8.self).lowercased() == "metadatastream"
  }

  mutating func push(_ pkt: ReceivedRTPPacket) throws {
    precondition(ready == nil, "push() called before pull() drained the previous frame")
    pendingLoss = UInt32(clamping: UInt64(pendingLoss) + UInt64(pkt.loss))

    var skipAppend = false

    if pkt.loss > 0 {
      if !buffer.isEmpty {
        // Lost a packet mid-document: the buffered prefix is unusable. This
        // packet is either more of that document or the start of a later one,
        // so keep it only if it starts one. For EXI only the `$EXI` cookie
        // counts here: about one byte in four begins with the distinguishing
        // bits, so the rest of the abandoned document would often pass as a
        // new one.
        buffer.removeAll(keepingCapacity: true)
        lastTimestamp = nil
        let isStart =
          encoding == .exi
          ? Self.hasEXICookie(pkt.payload)
          : Self.startsDocument(pkt.payload, encoding: encoding)
        dropUntilMark = !isStart
      } else {
        // Lost at a document boundary: the lost packet may have started this
        // packet's document, so keep this packet only if it starts one.
        dropUntilMark = !Self.startsDocument(pkt.payload, encoding: encoding)
      }
    } else if awaitingFirstPacket {
      // Nothing is buffered, but the packets before this one may have started
      // its document: handle it like a packet after loss at a boundary.
      dropUntilMark = !Self.startsDocument(pkt.payload, encoding: encoding)
    }
    awaitingFirstPacket = false

    if buffer.count + pkt.payload.count > Self.maxFragmentBytes {
      if !warnedSinceMark {
        onDiagnostic?(
          RTSPDiagnostic(
            severity: .warning,
            message:
              "Metadata document exceeded \(Self.maxFragmentBytes) bytes; "
              + "dropping until next marker."))
        warnedSinceMark = true
      }
      buffer.removeAll(keepingCapacity: true)
      lastTimestamp = nil
      dropUntilMark = true
      skipAppend = true
    }

    if !dropUntilMark && !skipAppend {
      buffer.append(pkt.payload)
      lastCtx = pkt.ctx
      lastStreamId = pkt.streamId
      lastTimestamp = pkt.timestamp
    }

    guard pkt.mark else { return }

    // Mark observed. Empty buffer means there's nothing to emit (drop, or
    // marker on an empty payload). Carry `pendingLoss` forward.
    if dropUntilMark || buffer.isEmpty {
      buffer.removeAll(keepingCapacity: true)
      lastTimestamp = nil
      dropUntilMark = false
      warnedSinceMark = false
      return
    }

    // `lastTimestamp` is set on every append, and we only reach here when
    // `buffer` is non-empty — so the guard is unreachable in practice.
    guard let ts = lastTimestamp else {
      buffer.removeAll(keepingCapacity: true)
      dropUntilMark = false
      warnedSinceMark = false
      return
    }

    let loss = UInt16(clamping: pendingLoss)
    pendingLoss = 0
    warnedSinceMark = false
    ready = MetadataFrame(
      ctx: lastCtx,
      streamId: lastStreamId,
      timestamp: ts,
      loss: loss,
      data: buffer
    )
    buffer.removeAll(keepingCapacity: true)
  }

  mutating func pull() -> Result<CodecItem, DepacketizeError>? {
    guard let frame = ready else { return nil }
    ready = nil
    return .success(.metadataFrame(frame))
  }
}
