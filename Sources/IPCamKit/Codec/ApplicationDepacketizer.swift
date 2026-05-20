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
/// - Loss mid-document discards the buffered prefix and drops the rest of
///   that document (until the next marker). The loss surfaces on the next
///   clean frame.
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
  /// True after an overflow diagnostic has fired since the last marker; used
  /// to avoid spamming diagnostics if every packet in the same in-flight
  /// document keeps overshooting the cap.
  private var warnedSinceMark: Bool = false
  private var ready: MetadataFrame?
  private let onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)?

  init(onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)? = nil) {
    self.onDiagnostic = onDiagnostic
  }

  mutating func push(_ pkt: ReceivedRTPPacket) throws {
    precondition(ready == nil, "push() called before pull() drained the previous frame")
    pendingLoss = pendingLoss + UInt32(pkt.loss)

    var skipAppend = false

    if pkt.loss > 0 && !buffer.isEmpty {
      // Lost a packet mid-document — the buffered prefix is unusable.
      buffer.removeAll(keepingCapacity: true)
      lastTimestamp = nil
      dropUntilMark = true
    }

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
