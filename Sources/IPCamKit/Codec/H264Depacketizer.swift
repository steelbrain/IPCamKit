// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/codec/h264.rs - H.264 RTP depacketizer (RFC 6184)

import Foundation

/// H.264 RTP depacketizer.
///
/// Finds access unit boundaries and produces unfragmented NAL units in AVCC format
/// (4-byte big-endian length prefix). Supports Single NAL, STAP-A (type 24),
/// and FU-A (type 28) per RFC 6184.
///
/// Handles Annex B byte streams from broken cameras, tolerates FU-A header
/// inconsistencies, and correctly handles Reolink-style timestamp quirks
/// at GOP boundaries.
struct H264Depacketizer: Sendable {
  private var inputState: InputState
  private var pending: [Result<VideoFrame, DepacketizeError>]
  var parameters: H264Parameters?
  private var pieces: [Data]
  private var nals: [NALEntry]
  var seenInconsistentFuANalHdr: Bool
  /// True once a FU-A with both the START and END bits set has been seen (a
  /// single-fragment FU-A, forbidden by RFC 6184 section 5.8 but emitted by
  /// some cameras). Tracked so callers can surface it as a diagnostic.
  var seenSingleFragmentFuA: Bool
  /// Running total of output bytes for the in-progress access unit: each
  /// buffered NAL's 4-byte length prefix and header byte plus all body bytes.
  /// Used to bound memory against a hostile camera (see `maxAccessUnitBytes`).
  private var pendingBytes: Int = 0
  /// Index in `nals` of the last VCL NAL unit (a coded slice) of the access
  /// unit in progress, or nil when it has none yet.
  private var lastVCLIndex: Int?

  /// Cap on the output size of a single accumulated access unit. A hostile
  /// camera could otherwise stream FU-A continuations (or same-timestamp NALs)
  /// forever and grow memory without bound. 16 MiB sits well above any real
  /// 4K/8K keyframe.
  private static let maxAccessUnitBytes = 16 << 20

  /// Cap on the NAL units plus body pieces buffered for a single access unit.
  /// Each costs bookkeeping memory beyond its output bytes, so a flood of tiny
  /// NALs or fragments would otherwise use several times `maxAccessUnitBytes`.
  /// A 16 MiB access unit sent in 1,400-byte packets is about 12,000 pieces.
  static let maxAccessUnitEntries = 1 << 16

  init(clockRate: UInt32, formatSpecificParams: String?) throws {
    guard clockRate == 90_000 else {
      throw RTSPError.depacketizationError(
        "invalid H.264 clock rate \(clockRate); must always be 90000")
    }
    self.inputState = .new
    self.pending = []
    self.pieces = []
    self.nals = []
    self.seenInconsistentFuANalHdr = false
    self.seenSingleFragmentFuA = false

    if let fmtp = formatSpecificParams {
      // Interleaved mode can't be depacketized: fail loud. Bad
      // sprop-parameter-sets only fall back to in-band parameters.
      try H264Parameters.validatePacketizationMode(fmtp)
      self.parameters = try? H264Parameters.parseFormatSpecificParams(fmtp)
    } else {
      self.parameters = nil
    }
  }

  // MARK: - Internal Types

  private enum InputState: Sendable {
    case new
    case loss(timestamp: Timestamp, pkts: UInt16)
    case preMark(AccessUnit)
    case postMark(timestamp: Timestamp, loss: UInt16)
  }

  struct NALEntry: Sendable {
    var hdr: NALHeader
    var nextPieceIdx: Int
    var len: Int  // total NAL length including header byte
  }

  struct AccessUnit: Sendable {
    var startCtx: PacketContext
    var endCtx: PacketContext
    var timestamp: Timestamp
    var streamId: Int
    var fuA: FuAState?
    var loss: UInt16
    var sameTsAsPrev: Bool

    static func start(
      _ pkt: ReceivedRTPPacket, additionalLoss: UInt16, sameTsAsPrev: Bool
    )
      -> AccessUnit
    {
      AccessUnit(
        startCtx: pkt.ctx, endCtx: pkt.ctx,
        timestamp: pkt.timestamp, streamId: pkt.streamId,
        fuA: nil, loss: UInt16(clamping: UInt32(pkt.loss) + UInt32(additionalLoss)),
        sameTsAsPrev: sameTsAsPrev)
    }
  }

  struct FuAState: Sendable {
    var initialNalHeader: NALHeader
    var curNal: CurFuANal?
  }

  struct CurFuANal: Sendable {
    var hdr: NALHeader
    var trailingZeros: Int
    var piecesBytes: Int
  }

  /// NAL units taken off the end of one access unit to start the next, with
  /// their body pieces (`nextPieceIdx` relative to `pieces`) and the bytes
  /// they were charged against the access-unit cap.
  private struct MovedNALs {
    var nals: [NALEntry]
    var pieces: [Data]
    var bytes: Int
  }

  // MARK: - Public Interface

  /// Take over `other`'s current parameters (the stored SPS and PPS and what
  /// was parsed from them), so the next access unit's parameter sets are
  /// compared against them. Nothing else is copied. A session uses this to
  /// keep the stream's parameters when it replaces the depacketizer with a
  /// fresh one built from the SDP, as after a seek.
  mutating func adoptParameters(from other: Self) {
    parameters = other.parameters
  }

  /// Add one packet. A thrown error drops this packet and the rest of its
  /// access unit (see `discardAccessUnit`); the depacketizer stays usable.
  mutating func push(_ pkt: ReceivedRTPPacket) throws {
    let result = pushInner(pkt)
    if case .failure(let err) = result {
      // pushInner has already moved to a state that drops the rest of this
      // access unit; clear the partially mutated buffers it leaves behind.
      resetAccumulation()
      throw err
    }
    // Success: keep the in-progress NAL buffers only while mid-AU (.preMark).
    if case .preMark = inputState {
    } else {
      resetAccumulation()
    }
  }

  /// Clear the in-progress access-unit buffers and the byte accumulator together,
  /// so the running total can never drift from the actual buffered bytes.
  private mutating func resetAccumulation() {
    nals.removeAll(keepingCapacity: true)
    pieces.removeAll(keepingCapacity: true)
    pendingBytes = 0
    lastVCLIndex = nil
  }

  /// Charge `bytes` of output and one buffered entry against the per-access-unit
  /// caps. Throws when either cap would be exceeded, so a never-terminating
  /// FU-A or a flood of NALs at one timestamp can't exhaust memory.
  private mutating func reserve(_ bytes: Int) throws {
    guard pendingBytes + bytes <= Self.maxAccessUnitBytes else {
      throw DepacketizeError(
        "H.264 access unit exceeded \(Self.maxAccessUnitBytes) bytes")
    }
    guard nals.count + pieces.count < Self.maxAccessUnitEntries else {
      throw DepacketizeError(
        "H.264 access unit exceeded \(Self.maxAccessUnitEntries) NAL units and fragments")
    }
    pendingBytes += bytes
  }

  /// Append a NAL-body piece, charging it against the access-unit caps.
  private mutating func appendPiece(_ piece: Data) throws {
    try reserve(piece.count)
    pieces.append(piece)
  }

  /// Finish a NAL whose body pieces are already appended, charging its 4-byte
  /// length prefix and header byte against the access-unit caps.
  private mutating func appendNAL(_ hdr: NALHeader, len: Int) throws {
    try reserve(4 + 1)
    nals.append(NALEntry(hdr: hdr, nextPieceIdx: pieces.count, len: len))
    if Self.isVCL(hdr) {
      lastVCLIndex = nals.count - 1
    }
  }

  /// Remove the NAL units after `lastVCL` that belong to the next access unit
  /// (from the first one that `startsAccessUnit` on) from the access unit in
  /// progress, with their pieces and their share of `pendingBytes`.
  private mutating func takeNextAccessUnitNALs(after lastVCL: Int) -> MovedNALs {
    let tail = nals[(lastVCL + 1)...]
    guard let first = tail.firstIndex(where: { Self.startsAccessUnit($0.hdr) }) else {
      return MovedNALs(nals: [], pieces: [], bytes: 0)
    }
    // `first` > `lastVCL` >= 0, so a NAL precedes it.
    let pieceStart = nals[first - 1].nextPieceIdx
    var moved = MovedNALs(nals: [], pieces: Array(pieces[pieceStart...]), bytes: 0)
    for nal in nals[first...] {
      moved.nals.append(
        NALEntry(hdr: nal.hdr, nextPieceIdx: nal.nextPieceIdx - pieceStart, len: nal.len))
      // Each NAL was charged its 4-byte length prefix plus `len` (header
      // byte and body).
      moved.bytes += 4 + nal.len
    }
    nals.removeSubrange(first...)
    pieces.removeSubrange(pieceStart...)
    pendingBytes -= moved.bytes
    return moved
  }

  /// Start the (empty) access unit in progress with `moved`. None of them is a
  /// VCL NAL unit.
  private mutating func restore(_ moved: MovedNALs) {
    nals.append(contentsOf: moved.nals)
    pieces.append(contentsOf: moved.pieces)
    pendingBytes += moved.bytes
  }

  /// The loss to report on the next frame after dropping `au`: its own loss
  /// plus one for the dropped data.
  private static func lossAfterDropping(_ au: AccessUnit) -> UInt16 {
    UInt16(clamping: UInt32(au.loss) + 1)
  }

  /// After a failed push, drop the rest of the access unit `pkt` belongs to:
  /// later packets with its timestamp are ignored (or, if `pkt` had the MARK
  /// bit, the next packet starts a new access unit), and the next frame's
  /// `loss` reports the drop. Without this, the remaining packets would start
  /// a fresh access unit and deliver a partial picture with `loss` 0.
  private mutating func discardAccessUnit(after pkt: ReceivedRTPPacket, _ au: AccessUnit) {
    resetAccumulation()
    let loss = Self.lossAfterDropping(au)
    if pkt.mark {
      inputState = .postMark(timestamp: pkt.timestamp, loss: loss)
    } else {
      inputState = .loss(timestamp: pkt.timestamp, pkts: loss)
    }
  }

  /// Finalize `au` into `pending`. Returns the loss to carry into the next
  /// access unit: 0, or if finalization failed (the frame is dropped) the
  /// dropped unit's loss plus one.
  private mutating func emitAccessUnit(_ au: inout AccessUnit) -> UInt16 {
    let frame = finalizeAccessUnit(&au)
    pending.append(frame)
    if case .failure = frame {
      return Self.lossAfterDropping(au)
    }
    return 0
  }

  /// Returns the next completed item, or nil when none are buffered.
  ///
  /// Contract: callers MUST drain `pull()` to nil after each `push()` (as
  /// RTSPSession does). The internal `pending` buffer is unbounded; not draining
  /// lets it grow without limit. This type is module-internal with a single
  /// driver that upholds the invariant.
  mutating func pull() -> Result<CodecItem, DepacketizeError>? {
    guard !pending.isEmpty else { return nil }
    let item = pending.removeFirst()
    switch item {
    case .success(let frame):
      return .success(.videoFrame(frame))
    case .failure(let err):
      return .failure(err)
    }
  }

  /// Compare timestamps by their raw i64 value only (matching upstream which compares
  /// `access_unit.timestamp.timestamp == pkt.timestamp().timestamp`).
  private func sameTimestamp(_ a: Timestamp, _ b: Timestamp) -> Bool {
    a.timestamp == b.timestamp
  }

  // MARK: - Core Logic

  private mutating func pushInner(_ pkt: ReceivedRTPPacket) -> Result<Void, DepacketizeError> {
    // An empty payload has no NAL. Without loss it changes nothing, so return
    // before the state machine below can finalize or clear the access unit in
    // progress. With loss, run the state machine so the loss is recorded.
    let payload = pkt.payload
    if payload.isEmpty && pkt.loss == 0 {
      return .success(())
    }

    // Resolve access unit from state machine
    var accessUnit: AccessUnit

    switch inputState {
    case .new:
      accessUnit = AccessUnit.start(pkt, additionalLoss: 0, sameTsAsPrev: false)

    case .preMark(var au):
      au.endCtx = pkt.ctx
      let loss = pkt.loss
      if loss > 0 {
        resetAccumulation()
        // The discarded unit's own loss (carried from before it) still has
        // to reach the next frame.
        let carried = UInt16(clamping: UInt32(au.loss) + UInt32(loss))
        if sameTimestamp(pkt.timestamp, au.timestamp) {
          if pkt.mark {
            inputState = .postMark(timestamp: au.timestamp, loss: carried)
          } else {
            inputState = .loss(timestamp: au.timestamp, pkts: carried)
          }
          return .success(())
        }
        // Different timestamp: discard old AU, start fresh
        accessUnit = AccessUnit.start(pkt, additionalLoss: au.loss, sameTsAsPrev: false)
      } else if !sameTimestamp(pkt.timestamp, au.timestamp) {
        // Timestamp changed
        if au.fuA != nil {
          // Mid-fragment timestamp change
          let desc =
            "timestamp changed from \(au.timestamp) to \(pkt.timestamp) in the middle of a fragmented NAL"
          pending.append(.failure(DepacketizeError(desc)))
          resetAccumulation()
          accessUnit = AccessUnit.start(
            pkt, additionalLoss: Self.lossAfterDropping(au), sameTsAsPrev: false)
        } else if let lastVCL = lastVCLIndex {
          // AU boundary. After the last VCL NAL, an AUD, SEI, SPS or PPS
          // starts the next access unit (H.264 section 7.4.1.2.3): move the
          // NALs from the first of those on to the new one, so their
          // parameter sets apply there.
          let moved = takeNextAccessUnitNALs(after: lastVCL)
          let carriedLoss = emitAccessUnit(&au)
          resetAccumulation()
          accessUnit = AccessUnit.start(pkt, additionalLoss: carriedLoss, sameTsAsPrev: false)
          restore(moved)
        } else {
          // No VCL NAL yet, so no picture to end: only non-VCL NALs (Reolink
          // sends SPS/PPS with the previous picture's timestamp) or none.
          // They precede the new picture; absorb the new timestamp.
          au.timestamp = pkt.timestamp
          accessUnit = au
        }
      } else {
        accessUnit = au
      }

    case .postMark(let prevTs, let prevLoss):
      let sameTsAsPrev = sameTimestamp(pkt.timestamp, prevTs)
      accessUnit = AccessUnit.start(pkt, additionalLoss: prevLoss, sameTsAsPrev: sameTsAsPrev)

    case .loss(let lossTs, var lossPkts):
      if sameTimestamp(pkt.timestamp, lossTs) {
        // Stay in Loss regardless of mark bit — once loss is detected for a
        // timestamp, ALL remaining packets for that timestamp are ignored.
        // This matches upstream behavior (h264.rs lines 349-361).
        lossPkts = UInt16(clamping: UInt32(lossPkts) + UInt32(pkt.loss))
        inputState = .loss(timestamp: lossTs, pkts: lossPkts)
        return .success(())
      }
      accessUnit = AccessUnit.start(pkt, additionalLoss: lossPkts, sameTsAsPrev: false)
    }

    // An empty payload with loss: the state machine has recorded the loss; the
    // packet adds no NAL.
    if payload.isEmpty {
      inputState = .preMark(accessUnit)
      return .success(())
    }

    switch addPayload(pkt, to: &accessUnit) {
    case .failure(let err):
      discardAccessUnit(after: pkt, accessUnit)
      return .failure(err)
    case .success(false):
      // FU-A continuation whose start was lost: drop the rest of the AU.
      resetAccumulation()
      // `accessUnit.loss` already includes this packet's gap.
      inputState = .loss(timestamp: accessUnit.timestamp, pkts: accessUnit.loss)
      return .success(())
    case .success(true):
      break
    }

    // Post-processing: handle mark bit
    if pkt.mark {
      if lastVCLIndex != nil {
        // The access unit has a picture: MARK ends it, with any non-VCL NALs
        // the camera sent after the picture with this MARK.
        accessUnit.endCtx = pkt.ctx
        let carriedLoss = emitAccessUnit(&accessUnit)
        inputState = .postMark(timestamp: pkt.timestamp, loss: carriedLoss)
      } else if !nals.isEmpty {
        // MARK on non-VCL NALs before any picture (SPS/PPS/SEI from Reolink
        // or "H264DVR 1.0" firmware): not an access unit yet. Update the AU
        // timestamp (matches upstream h264.rs line 517:
        // access_unit.timestamp.timestamp = timestamp.timestamp)
        accessUnit.timestamp = pkt.timestamp
        inputState = .preMark(accessUnit)
      } else {
        inputState = .preMark(accessUnit)
      }
    } else {
      inputState = .preMark(accessUnit)
    }

    return .success(())
  }

  /// Add the NAL units in a non-empty payload to the access unit in progress.
  ///
  /// Returns `false` when `pkt` is a FU-A continuation whose start was lost
  /// (`pkt.loss > 0`); the caller then drops the rest of the access unit.
  private mutating func addPayload(
    _ pkt: ReceivedRTPPacket, to accessUnit: inout AccessUnit
  ) -> Result<Bool, DepacketizeError> {
    let payload = pkt.payload
    let nalHeaderByte = payload[payload.startIndex]
    let nalHeader = NALHeader(nalHeaderByte)
    guard !nalHeader.forbiddenZeroBit else {
      return .failure(DepacketizeError("Forbidden zero bit set in NAL header"))
    }

    let nalType = nalHeader.nalUnitTypeId

    // Route by NAL type
    switch nalType {
    case 1...23:
      // Single NAL unit
      if accessUnit.fuA != nil {
        return .failure(DepacketizeError("Non-fragmented NAL while FU-A fragment in progress"))
      }
      if case .failure(let err) = processAnnexB(payload, handler: { nal in self.addSingleNal(nal) })
      {
        return .failure(err)
      }

    case 24:
      // STAP-A
      if accessUnit.fuA != nil {
        return .failure(DepacketizeError("STAP-A while FU-A fragment in progress"))
      }
      var offset = payload.startIndex + 1  // skip aggregation header
      while offset < payload.endIndex {
        guard payload.endIndex - offset >= 3 else {
          return .failure(DepacketizeError("STAP-A too short"))
        }
        let nalLen = Int(UInt16(payload[offset]) << 8 | UInt16(payload[offset + 1]))
        offset += 2
        guard nalLen > 0 else {
          return .failure(DepacketizeError("zero length in STAP-A"))
        }
        guard offset + nalLen <= payload.endIndex else {
          return .failure(DepacketizeError("STAP-A NAL extends past packet"))
        }
        let nalData = payload[offset..<(offset + nalLen)]
        if case .failure(let err) = processAnnexB(
          Data(nalData),
          handler: { nal in
            self.addSingleNal(nal)
          })
        {
          return .failure(err)
        }
        offset += nalLen
      }

    case 25...27, 29:
      return .failure(DepacketizeError("Unimplemented interleaved mode NAL type \(nalType)"))

    case 28:
      // FU-A
      guard payload.count >= 2 else {
        return .failure(DepacketizeError("FU-A too short"))
      }
      let fuHeader = payload[payload.startIndex + 1]
      let isStart = (fuHeader & 0b1000_0000) != 0
      let isEnd = (fuHeader & 0b0100_0000) != 0
      // reserved bit is ignored (Longse camera sets it)
      let reconstructedByte = (nalHeaderByte & 0b1110_0000) | (fuHeader & 0b0001_1111)
      let reconstructedHeader = NALHeader(reconstructedByte)

      // A FU-A with both START and END set is a single-fragment FU-A:
      // forbidden by RFC 6184 section 5.8, but some cameras wrap small NALs
      // this way. Tolerate it (treat as a complete NAL) instead of erroring.
      // Port of retina 8ff7a0f / e1c0bbf.
      if !isEnd && pkt.mark {
        return .failure(DepacketizeError("FU-A with MARK but no END bit"))
      }

      let fuPayload = Data(payload[(payload.startIndex + 2)...])

      var fuState: FuAState
      if isStart {
        if accessUnit.fuA != nil {
          return .failure(DepacketizeError("FU-A START while fragment already in progress"))
        }
        if isEnd && !seenSingleFragmentFuA {
          seenSingleFragmentFuA = true
        }
        fuState = FuAState(
          initialNalHeader: reconstructedHeader,
          curNal: CurFuANal(hdr: reconstructedHeader, trailingZeros: 0, piecesBytes: 0))
        do {
          try addFuA(curNal: &fuState.curNal, data: fuPayload)
        } catch {
          return .failure(DepacketizeError("\(error)"))
        }
      } else if let inProgress = accessUnit.fuA {
        // Continuation or end
        fuState = inProgress
        if reconstructedHeader != fuState.initialNalHeader && !seenInconsistentFuANalHdr {
          seenInconsistentFuANalHdr = true
        }
        do {
          try addFuA(curNal: &fuState.curNal, data: fuPayload)
        } catch {
          return .failure(DepacketizeError("\(error)"))
        }
      } else {
        if pkt.loss > 0 {
          return .success(false)
        }
        return .failure(DepacketizeError("FU-A continuation without START"))
      }

      if isEnd {
        // Finalize the FU-A NAL. With a single-fragment FU-A this happens on
        // the START fragment itself.
        if let c = fuState.curNal {
          do {
            try appendNAL(c.hdr, len: 1 + c.piecesBytes)  // header + body
          } catch {
            return .failure(DepacketizeError("\(error)"))
          }
        }
        accessUnit.fuA = nil
      } else {
        accessUnit.fuA = fuState
      }

    case 0, 30, 31:
      return .failure(DepacketizeError("Bad NAL header type \(nalType)"))

    default:
      return .failure(DepacketizeError("Unknown NAL type \(nalType)"))
    }

    return .success(true)
  }

  // MARK: - NAL Processing

  private mutating func addSingleNal(_ data: Data) -> Result<Void, DepacketizeError> {
    guard !data.isEmpty else { return .success(()) }
    let len = data.count
    let hdr = NALHeader(data[data.startIndex])
    if hdr.forbiddenZeroBit {
      return .failure(DepacketizeError("Forbidden zero bit in NAL header within Annex B or STAP-A"))
    }
    let body = data.count > 1 ? Data(data[(data.startIndex + 1)...]) : Data()
    do {
      if !body.isEmpty {
        try appendPiece(body)
      }
      try appendNAL(hdr, len: len)
    } catch {
      return .failure(DepacketizeError("\(error)"))
    }
    return .success(())
  }

  /// Add FU-A fragment data, handling Annex B separators across fragment boundaries.
  ///
  /// Faithful port of upstream `add_fu_a` (h264.rs lines 559-635).
  /// Tracks trailing zeros across fragments to detect `00 00 01` separators
  /// split between packets. When a separator is found, finalizes the current
  /// NAL, sets curNal to nil, and continues in an outer loop to process
  /// remaining data as a new NAL.
  private mutating func addFuA(
    curNal: inout CurFuANal?, data: Data
  ) throws {
    let bytes = [UInt8](data)
    var dataOffset = 0

    outerLoop: while true {
      guard var c = curNal else {
        // No current NAL — read header byte from remaining data to start a new one
        guard dataOffset < bytes.count else { return }
        let hdrByte = bytes[dataOffset]
        dataOffset += 1
        let hdr = NALHeader(hdrByte)
        guard !hdr.forbiddenZeroBit else {
          throw DepacketizeError("bad NAL header \(String(format: "%02x", hdrByte))")
        }
        curNal = CurFuANal(hdr: hdr, trailingZeros: 0, piecesBytes: 0)
        continue outerLoop
      }

      var curPos = dataOffset
      while curPos < bytes.count {
        if c.trailingZeros == 0 {
          // Fast path: scan for zero byte
          if let zeroIdx = findZero(bytes, from: curPos) {
            curPos = zeroIdx + 1
            c.trailingZeros = 1
          } else {
            c.trailingZeros = 0
            break
          }
        } else if c.trailingZeros >= 2 && bytes[curPos] == 2 {
          throw DepacketizeError("forbidden sequence 00 00 02 in NAL")
        } else if c.trailingZeros >= 2 && bytes[curPos] == 1 {
          // Found Annex B separator
          // Push data before the separator (excluding trailing zeros and the 01)
          let dataEnd = curPos + 1  // includes the 01 byte
          let pieceEnd = dataEnd - c.trailingZeros - 1
          if pieceEnd > dataOffset {
            let piece = Data(bytes[dataOffset..<pieceEnd])
            try appendPiece(piece)
            c.piecesBytes += piece.count
          }
          // Finalize current NAL
          try appendNAL(c.hdr, len: c.piecesBytes + 1)
          curNal = nil
          dataOffset = curPos + 1
          continue outerLoop
        } else if bytes[curPos] == 0 {
          c.trailingZeros += 1
          curPos += 1
        } else if c.trailingZeros > 2 {
          throw DepacketizeError("forbidden sequence 00 00 00 in NAL")
        } else {
          // The trailing zeros were NAL content, not a start code prefix
          if curPos - dataOffset < c.trailingZeros {
            // Some zeros came from previous fragment — insert synthetic zeros
            let prevChunkZeros = c.trailingZeros - (curPos - dataOffset)
            try appendPiece(Data(repeating: 0, count: prevChunkZeros))
            c.piecesBytes += prevChunkZeros
          }
          c.trailingZeros = 0
          curPos += 1
        }
      }

      // Push non-trailing-zero portion of remaining data
      let nonTrailingEnd = bytes.count - c.trailingZeros
      if nonTrailingEnd > dataOffset {
        let piece = Data(bytes[dataOffset..<nonTrailingEnd])
        try appendPiece(piece)
        c.piecesBytes += piece.count
      }
      curNal = c
      return
    }
  }

  // MARK: - Access Unit Finalization

  /// Whether `hdr` is a VCL NAL unit: a coded slice (types 1–5).
  ///
  /// An access unit ends (on MARK or a timestamp change) only once it has
  /// one. Some cameras set MARK and/or change the timestamp after non-VCL NAL
  /// units that precede the picture (Reolink after SPS/PPS, "H264DVR 1.0"
  /// firmware after an SEI); an access unit of only those is not a picture.
  /// Port of retina ff771fe, deciding by the picture instead of the last NAL.
  private static func isVCL(_ hdr: NALHeader) -> Bool {
    (1...5).contains(hdr.nalUnitTypeId)
  }

  /// Whether a NAL unit of this type after the last VCL NAL unit of an access
  /// unit starts the next access unit (H.264 section 7.4.1.2.3): SEI (6),
  /// SPS (7), PPS (8), access unit delimiter (9), and types 14–18. Others,
  /// such as end of sequence (10) or filler data (12), belong to the access
  /// unit they follow.
  private static func startsAccessUnit(_ hdr: NALHeader) -> Bool {
    let nalType = hdr.nalUnitTypeId
    return (6...9).contains(nalType) || (14...18).contains(nalType)
  }

  private mutating func finalizeAccessUnit(
    _ au: inout AccessUnit
  ) -> Result<VideoFrame, DepacketizeError> {
    var isRandomAccessPoint = false
    var isDisposable = true
    var totalLen = 0
    var spsCandidates = ParameterSetCandidates(stored: parameters?.spsNAL)
    var ppsCandidates = ParameterSetCandidates(stored: parameters?.ppsNAL)

    // First pass: check parameters, RAP status, calculate total length
    var pieceIdx = 0
    for nal in nals {
      let nalType = nal.hdr.nalUnitTypeId
      switch nalType {
      case 7:
        // SPS
        spsCandidates.add(reassembleNal(nal, startPieceIdx: pieceIdx))
      case 8:
        // PPS
        ppsCandidates.add(reassembleNal(nal, startPieceIdx: pieceIdx))
      case 5:
        // IDR slice — this is a random access point
        isRandomAccessPoint = true
      default:
        break
      }
      if nal.hdr.nalRefIdc != 0 {
        isDisposable = false
      }
      totalLen += 4 + nal.len  // 4-byte length prefix + NAL
      pieceIdx = nal.nextPieceIdx
    }

    // Second pass: build output data
    var data = Data(capacity: totalLen)
    pieceIdx = 0
    for nal in nals {
      // 4-byte big-endian length
      let len = UInt32(nal.len)
      data.append(UInt8(len >> 24))
      data.append(UInt8((len >> 16) & 0xFF))
      data.append(UInt8((len >> 8) & 0xFF))
      data.append(UInt8(len & 0xFF))
      // NAL header byte
      data.append(nal.hdr.rawByte)
      // NAL body pieces
      let prevIdx = pieceIdx
      pieceIdx = nal.nextPieceIdx
      for i in prevIdx..<pieceIdx {
        data.append(pieces[i])
      }
    }

    // Update parameters if changed
    var hasNewParameters = false
    let newSPS = spsCandidates.replacement
    let newPPS = ppsCandidates.replacement
    let effectiveSPS = newSPS ?? parameters?.spsNAL
    let effectivePPS = newPPS ?? parameters?.ppsNAL
    if newSPS != nil || newPPS != nil, let sps = effectiveSPS, let pps = effectivePPS {
      do {
        parameters = try H264Parameters.parseSPSAndPPS(sps: sps, pps: pps)
        hasNewParameters = true
      } catch {
        return .failure(DepacketizeError("\(error)"))
      }
    }

    return .success(
      VideoFrame(
        hasNewParameters: hasNewParameters,
        loss: au.loss,
        startCtx: au.startCtx,
        endCtx: au.endCtx,
        timestamp: au.timestamp,
        streamId: au.streamId,
        isRandomAccessPoint: isRandomAccessPoint,
        isDisposable: isDisposable,
        data: data,
        parameterSets: parameters.map { VideoParameterSetNALs(sps: $0.spsNAL, pps: $0.ppsNAL) }
      ))
  }

  /// Reassemble a NAL from its header byte and pieces.
  private func reassembleNal(_ nal: NALEntry, startPieceIdx: Int) -> Data {
    var result = Data(capacity: nal.len)
    result.append(nal.hdr.rawByte)
    for i in startPieceIdx..<nal.nextPieceIdx {
      result.append(pieces[i])
    }
    return result
  }
}

// MARK: - Fast Zero-Byte Scan

/// Find the index of the first zero byte in `bytes` starting from `from`,
/// using `memchr` for O(1)-overhead scanning instead of Swift Collection protocol dispatch.
private func findZero(_ bytes: [UInt8], from start: Int) -> Int? {
  guard start < bytes.count else { return nil }
  let len = bytes.count - start
  return bytes.withContiguousStorageIfAvailable { buf -> Int? in
    guard let base = buf.baseAddress else { return nil }
    guard let found = memchr(base + start, 0, len) else { return nil }
    return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
  } ?? nil
}

// MARK: - Annex B Processing

/// Process data that may contain Annex B byte stream separators.
///
/// Ports upstream `process_annex_b` (h264.rs lines 155-202).
/// Uses a trailing-zero state machine to detect `00 00 01` separators.
/// Errors on forbidden sequences (`00 00 02`, `00 00 00` not followed by `01`).
/// Strips trailing zero bytes per H.264 section 7.4.1.
/// Process data that may contain Annex B byte stream separators.
///
/// Handler returns Result to allow error propagation (matches upstream
/// `process_annex_b<F: FnMut(Bytes) -> Result<(), String>>` signature).
@discardableResult
func processAnnexB(
  _ data: Data, handler: (Data) -> Result<Void, DepacketizeError>
) -> Result<Void, DepacketizeError> {
  guard !data.isEmpty else { return .success(()) }

  let bytes = [UInt8](data)
  var i = 0
  var trailingZeros = 0
  var nalStart = 0

  while i < bytes.count {
    if trailingZeros == 0 {
      // Fast path: scan for zero byte
      if let zeroIdx = findZero(bytes, from: i) {
        i = zeroIdx + 1
        trailingZeros = 1
      } else {
        trailingZeros = 0
        break
      }
    } else if trailingZeros >= 2 && bytes[i] == 2 {
      return .failure(DepacketizeError("forbidden sequence 00 00 02 in NAL"))
    } else if trailingZeros >= 2 && bytes[i] == 1 {
      // Found Annex B separator: emit NAL before the trailing zeros
      let nalEnd = i - trailingZeros
      if nalEnd > nalStart {
        if case .failure(let err) = handler(Data(bytes[nalStart..<nalEnd])) {
          return .failure(err)
        }
      }
      i += 1
      nalStart = i
      trailingZeros = 0
    } else if bytes[i] == 0 {
      trailingZeros += 1
      i += 1
    } else if trailingZeros >= 3 {
      return .failure(DepacketizeError("forbidden sequence 00 00 00 in NAL"))
    } else {
      // Non-zero, non-separator byte: trailing zeros were part of NAL content
      trailingZeros = 0
      i += 1
    }
  }

  // Emit last NAL, stripping trailing zeros
  let nalEnd = bytes.count - trailingZeros
  if nalEnd > nalStart {
    if case .failure(let err) = handler(Data(bytes[nalStart..<nalEnd])) {
      return .failure(err)
    }
  }
  return .success(())
}
