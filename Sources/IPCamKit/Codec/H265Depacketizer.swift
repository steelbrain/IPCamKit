// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/codec/h265.rs - H.265 RTP depacketizer (RFC 7798)

import Foundation

/// H.265 RTP depacketizer.
///
/// Finds access unit boundaries and produces unfragmented NAL units in AVCC format
/// (4-byte big-endian length prefix). Supports Single NAL (0-47), AP (type 48),
/// and FU (type 49) per RFC 7798. SRST mode only (no DONL).
struct H265Depacketizer: Sendable {
  private var inputState: InputState
  private var pending: [Result<VideoFrame, DepacketizeError>]
  var parameters: H265Parameters?
  private var pieces: [Data]
  private var nals: [NALEntry]
  var seenInconsistentFuNalHdr: Bool
  /// True once a FU with both the START and END bits set has been seen (a
  /// single-fragment FU, forbidden by RFC 7798 section 4.4.3 but emitted by
  /// some cameras). Tracked so callers can surface it as a diagnostic.
  var seenSingleFragmentFu: Bool
  /// Running total of output bytes for the in-progress access unit: each
  /// buffered NAL's 4-byte length prefix and 2-byte header plus all body bytes.
  /// Used to bound memory against a hostile camera (see `maxAccessUnitBytes`).
  private var pendingBytes: Int = 0
  /// Index in `nals` of the last VCL NAL unit (a coded slice segment) of the
  /// access unit in progress, or nil when it has none yet.
  private var lastVCLIndex: Int?

  /// Cap on the output size of a single accumulated access unit. A hostile
  /// camera could otherwise stream FU continuations (or same-timestamp NALs)
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
        "invalid H.265 clock rate \(clockRate); must always be 90000")
    }
    self.inputState = .new
    self.pending = []
    self.pieces = []
    self.nals = []
    self.seenInconsistentFuNalHdr = false
    self.seenSingleFragmentFu = false

    if let fmtp = formatSpecificParams {
      // A transmission mode with DONL fields can't be depacketized: fail loud.
      // Bad sprop-* parameter sets only fall back to in-band parameters.
      try H265Parameters.validateTransmissionMode(fmtp)
      self.parameters = try? H265Parameters.parseFormatSpecificParams(fmtp)
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
    var hdr: H265NALHeader
    /// The length of `Depacketizer.pieces` as this NAL finishes.
    var nextPieceIdx: Int
    /// The total length of this NAL, including the 2 header bytes.
    var len: Int
  }

  struct AccessUnit: Sendable {
    var startCtx: PacketContext
    var endCtx: PacketContext
    var timestamp: Timestamp
    var streamId: Int
    /// True iff currently processing a FU.
    var inFU: Bool
    var loss: UInt16
    var sameTsAsPrev: Bool

    static func start(
      _ pkt: ReceivedRTPPacket, additionalLoss: UInt16, sameTsAsPrev: Bool
    ) -> AccessUnit {
      AccessUnit(
        startCtx: pkt.ctx, endCtx: pkt.ctx,
        timestamp: pkt.timestamp, streamId: pkt.streamId,
        inFU: false, loss: UInt16(clamping: UInt32(pkt.loss) + UInt32(additionalLoss)),
        sameTsAsPrev: sameTsAsPrev)
    }
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

  /// Take over `other`'s current parameters (the stored VPS, SPS and PPS and
  /// what was parsed from them), so the next access unit's parameter sets are
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
  /// caps, failing when either would be exceeded, so a never-terminating FU or
  /// a flood of NALs at one timestamp can't exhaust memory.
  private mutating func reserve(_ bytes: Int) -> Result<Void, DepacketizeError> {
    guard pendingBytes + bytes <= Self.maxAccessUnitBytes else {
      return .failure(
        DepacketizeError("H.265 access unit exceeded \(Self.maxAccessUnitBytes) bytes"))
    }
    guard nals.count + pieces.count < Self.maxAccessUnitEntries else {
      return .failure(
        DepacketizeError(
          "H.265 access unit exceeded \(Self.maxAccessUnitEntries) NAL units and fragments"))
    }
    pendingBytes += bytes
    return .success(())
  }

  /// Append a NAL-body piece, charging it against the access-unit caps. An
  /// empty piece is skipped: it adds no output but would still use memory.
  private mutating func appendPiece(_ piece: Data) -> Result<Void, DepacketizeError> {
    guard !piece.isEmpty else { return .success(()) }
    if case .failure(let e) = reserve(piece.count) { return .failure(e) }
    pieces.append(piece)
    return .success(())
  }

  /// Append a NAL entry, charging its 4-byte length prefix and 2-byte header
  /// against the access-unit caps (its body is charged as pieces).
  private mutating func appendNAL(_ nal: NALEntry) -> Result<Void, DepacketizeError> {
    if case .failure(let e) = reserve(4 + 2) { return .failure(e) }
    nals.append(nal)
    if case .vcl = nal.hdr.unitType.unitTypeClass {
      lastVCLIndex = nals.count - 1
    }
    return .success(())
  }

  /// Remove the NAL units after `lastVCL` that belong to the next access unit
  /// (from the first one that `startsAccessUnit` on) from the access unit in
  /// progress, with their pieces and their share of `pendingBytes`. Only
  /// called with no FU in progress, so every NAL's `nextPieceIdx` is final.
  private mutating func takeNextAccessUnitNALs(after lastVCL: Int) -> MovedNALs {
    let tail = nals[(lastVCL + 1)...]
    guard let first = tail.firstIndex(where: { Self.startsAccessUnit($0.hdr.unitType) }) else {
      return MovedNALs(nals: [], pieces: [], bytes: 0)
    }
    // `first` > `lastVCL` >= 0, so a NAL precedes it.
    let pieceStart = nals[first - 1].nextPieceIdx
    var moved = MovedNALs(nals: [], pieces: Array(pieces[pieceStart...]), bytes: 0)
    for nal in nals[first...] {
      moved.nals.append(
        NALEntry(hdr: nal.hdr, nextPieceIdx: nal.nextPieceIdx - pieceStart, len: nal.len))
      // Each NAL was charged its 4-byte length prefix plus `len` (2-byte
      // header and body).
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

  private func sameTimestamp(_ a: Timestamp, _ b: Timestamp) -> Bool {
    a.timestamp == b.timestamp
  }

  // MARK: - Core Logic

  private mutating func pushInner(
    _ pkt: ReceivedRTPPacket
  ) -> Result<Void, DepacketizeError> {
    // A payload shorter than the 2-byte NAL header has no NAL. Without loss it
    // changes nothing, so return before the state machine below can finalize
    // or clear the access unit in progress. With loss, run the state machine
    // so the loss is recorded.
    let payload = pkt.payload
    let isShort = payload.count < 2
    if isShort && pkt.loss == 0 {
      return .success(())
    }

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
        accessUnit = AccessUnit.start(pkt, additionalLoss: au.loss, sameTsAsPrev: false)
      } else if !sameTimestamp(pkt.timestamp, au.timestamp) {
        if au.inFU {
          let desc =
            "timestamp changed from \(au.timestamp) to \(pkt.timestamp) in the middle of a fragmented NAL"
          pending.append(.failure(DepacketizeError(desc)))
          resetAccumulation()
          accessUnit = AccessUnit.start(
            pkt, additionalLoss: Self.lossAfterDropping(au), sameTsAsPrev: false)
        } else if let lastVCL = lastVCLIndex {
          // AU boundary. After the last VCL NAL, an AUD, VPS, SPS, PPS or
          // prefix SEI starts the next access unit (H.265 section 7.4.2.4.4):
          // move the NALs from the first of those on to the new one, so
          // their parameter sets apply there.
          let moved = takeNextAccessUnitNALs(after: lastVCL)
          let carriedLoss = emitAccessUnit(&au)
          resetAccumulation()
          accessUnit = AccessUnit.start(pkt, additionalLoss: carriedLoss, sameTsAsPrev: false)
          restore(moved)
        } else {
          // No VCL NAL yet, so no picture to end: only non-VCL NALs (sent with
          // the previous picture's timestamp) or none (a short packet with
          // loss started this access unit). Adopt the new timestamp.
          au.timestamp = pkt.timestamp
          accessUnit = au
        }
      } else {
        accessUnit = au
      }

    case .postMark(let prevTs, let prevLoss):
      let sameTsAsPrev = sameTimestamp(pkt.timestamp, prevTs)
      accessUnit = AccessUnit.start(
        pkt, additionalLoss: prevLoss, sameTsAsPrev: sameTsAsPrev)

    case .loss(let lossTs, var lossPkts):
      if sameTimestamp(pkt.timestamp, lossTs) {
        lossPkts = UInt16(clamping: UInt32(lossPkts) + UInt32(pkt.loss))
        inputState = .loss(timestamp: lossTs, pkts: lossPkts)
        return .success(())
      }
      accessUnit = AccessUnit.start(pkt, additionalLoss: lossPkts, sameTsAsPrev: false)
    }

    // A short payload with loss: the state machine has recorded the loss; the
    // packet adds no NAL.
    if isShort {
      inputState = .preMark(accessUnit)
      return .success(())
    }

    switch addPayload(pkt, to: &accessUnit) {
    case .failure(let err):
      discardAccessUnit(after: pkt, accessUnit)
      return .failure(err)
    case .success(false):
      // FU continuation whose start was lost: drop the rest of the AU.
      resetAccumulation()
      // `accessUnit.loss` already includes this packet's gap.
      inputState = .loss(timestamp: accessUnit.timestamp, pkts: accessUnit.loss)
      return .success(())
    case .success(true):
      break
    }

    // Post-processing: handle mark bit
    if pkt.mark {
      guard !nals.isEmpty else {
        discardAccessUnit(after: pkt, accessUnit)
        return .failure(DepacketizeError("nals should not be empty after mark"))
      }
      if lastVCLIndex != nil {
        // The access unit has a picture: MARK ends it, with any non-VCL NALs
        // the camera sent after the picture with this MARK.
        accessUnit.endCtx = pkt.ctx
        let carriedLoss = emitAccessUnit(&accessUnit)
        inputState = .postMark(timestamp: pkt.timestamp, loss: carriedLoss)
      } else {
        // MARK on non-VCL NALs before any picture: not an access unit yet.
        accessUnit.timestamp = pkt.timestamp
        inputState = .preMark(accessUnit)
      }
    } else {
      inputState = .preMark(accessUnit)
    }

    return .success(())
  }

  /// Add the NAL units in a payload of at least 2 bytes to the access unit in
  /// progress.
  ///
  /// Returns `false` when `pkt` is a FU continuation whose start was lost
  /// (`pkt.loss > 0`); the caller then drops the rest of the access unit.
  private mutating func addPayload(
    _ pkt: ReceivedRTPPacket, to accessUnit: inout AccessUnit
  ) -> Result<Bool, DepacketizeError> {
    // Parse 2-byte NAL header from payload
    let payload = pkt.payload
    let hdr: H265NALHeader
    do {
      hdr = try H265NALHeader(
        byte0: payload[payload.startIndex],
        byte1: payload[payload.startIndex + 1])
    } catch {
      return .failure(DepacketizeError("\(error)"))
    }

    let nalTypeRaw = hdr.unitType.rawValue

    switch nalTypeRaw {
    case 0...47:
      // Single NAL Unit (RFC 7798 section 4.4.1)
      if accessUnit.inFU {
        return .failure(
          DepacketizeError("Non-fragmented NAL while fragment in progress"))
      }
      let body = Data(payload[(payload.startIndex + 2)...])
      let len = body.count + 2  // includes 2-byte header
      if case .failure(let e) = appendPiece(body) { return .failure(e) }
      let nal = NALEntry(hdr: hdr, nextPieceIdx: pieces.count, len: len)
      if case .failure(let e) = appendNAL(nal) { return .failure(e) }

    case 48:
      // Aggregation Packet (RFC 7798 section 4.4.2)
      if accessUnit.inFU {
        // An AP arriving mid-fragment would leave the in-progress FU NALEntry
        // with its Int.max sentinel nextPieceIdx, which finalizeAccessUnit
        // would then slice on and trap. Reject like the single-NAL branch.
        return .failure(DepacketizeError("AP while fragment in progress"))
      }
      var offset = payload.startIndex + 2  // skip outer NAL header
      guard offset < payload.endIndex else {
        return .failure(
          DepacketizeError("AP has 0 remaining bytes; expecting 2-byte length"))
      }
      while offset < payload.endIndex {
        guard payload.endIndex - offset >= 2 else {
          return .failure(
            DepacketizeError(
              "AP has \(payload.endIndex - offset) remaining bytes; expecting 2-byte length"))
        }
        let nalLen = Int(payload[offset]) << 8 | Int(payload[offset + 1])
        offset += 2
        guard offset + nalLen <= payload.endIndex else {
          return .failure(
            DepacketizeError(
              "AP too short: \(payload.endIndex - offset) bytes remaining, expecting \(nalLen)-byte NAL"
            ))
        }
        let nalData = payload[offset..<(offset + nalLen)]

        guard nalData.count >= 2 else {
          return .failure(DepacketizeError("Short NAL in AP"))
        }
        let innerHdr: H265NALHeader
        do {
          innerHdr = try H265NALHeader(
            byte0: nalData[nalData.startIndex],
            byte1: nalData[nalData.startIndex + 1])
        } catch {
          return .failure(DepacketizeError("\(error)"))
        }
        let innerBody =
          nalData.count > 2
          ? Data(nalData[(nalData.startIndex + 2)...])
          : Data()
        if case .failure(let e) = appendPiece(innerBody) { return .failure(e) }
        let nal = NALEntry(hdr: innerHdr, nextPieceIdx: pieces.count, len: nalLen)
        if case .failure(let e) = appendNAL(nal) { return .failure(e) }

        offset += nalLen
      }

    case 49:
      // Fragmentation Unit (RFC 7798 section 4.4.3)
      guard payload.count >= 3 else {
        return .failure(DepacketizeError("FU len \(payload.count) too short"))
      }
      let fuHeader = payload[payload.startIndex + 2]
      let isStart = (fuHeader & 0b1000_0000) != 0
      let isEnd = (fuHeader & 0b0100_0000) != 0
      let fuTypeRaw = fuHeader & 0b0011_1111
      guard let fuType = H265UnitType(rawValue: fuTypeRaw) else {
        return .failure(DepacketizeError("Invalid FU type \(fuTypeRaw)"))
      }
      let reconstructedHdr = hdr.withUnitType(fuType)

      // A FU with both START and END set is a single-fragment FU: forbidden by
      // RFC 7798 section 4.4.3, but some cameras wrap small NALs this way.
      // Tolerate it (treat as a complete NAL) instead of erroring. Port of
      // retina 8ff7a0f / e1c0bbf.
      if !isEnd && pkt.mark {
        return .failure(DepacketizeError("FU pkt with MARK && !END"))
      }

      let fuPayload = Data(payload[(payload.startIndex + 3)...])

      // `pieces` count once this fragment's payload has been appended; used to
      // close out the NAL's piece range on the END fragment (possibly now).
      let piecesLen: Int
      switch (isStart, accessUnit.inFU) {
      case (true, true):
        return .failure(
          DepacketizeError("FU with start bit while frag in progress"))
      case (true, false):
        if isEnd && !seenSingleFragmentFu {
          seenSingleFragmentFu = true
        }
        if case .failure(let e) = appendPiece(fuPayload) { return .failure(e) }
        let nal = NALEntry(
          hdr: reconstructedHdr,
          nextPieceIdx: Int.max,  // overwritten on end (which may be now)
          len: 2 + fuPayload.count)
        if case .failure(let e) = appendNAL(nal) { return .failure(e) }
        piecesLen = pieces.count
      case (false, true):
        if case .failure(let e) = appendPiece(fuPayload) { return .failure(e) }
        piecesLen = pieces.count
        guard var nal = nals.last else {
          return .failure(DepacketizeError("nals non-empty while in fu"))
        }
        if reconstructedHdr != nal.hdr && !seenInconsistentFuNalHdr {
          seenInconsistentFuNalHdr = true
        }
        nal.len += fuPayload.count
        nals[nals.count - 1] = nal
      case (false, false):
        if pkt.loss > 0 {
          return .success(false)
        }
        return .failure(
          DepacketizeError("FU has start bit unset while no frag in progress"))
      }

      if isEnd {
        guard !nals.isEmpty else {
          return .failure(DepacketizeError("FU end with no NAL in progress"))
        }
        nals[nals.count - 1].nextPieceIdx = piecesLen
      }
      accessUnit.inFU = !isEnd

    default:
      return .failure(DepacketizeError("unexpected/bad nal header type \(nalTypeRaw)"))
    }

    return .success(true)
  }

  // MARK: - Access Unit Finalization

  /// Whether a NAL unit of this type after the last VCL NAL unit of an access
  /// unit starts the next access unit (H.265 section 7.4.2.4.4): access unit
  /// delimiter, VPS, SPS, PPS, prefix SEI, and types 41–44 and 48–55. Others,
  /// such as a suffix SEI or end of sequence, belong to the access unit they
  /// follow.
  ///
  /// An access unit ends (on MARK or a timestamp change) only once it has a
  /// VCL NAL unit (types 0–31); one of only non-VCL NAL units is not a picture.
  private static func startsAccessUnit(_ unitType: H265UnitType) -> Bool {
    switch unitType {
    case .vpsNut, .spsNut, .ppsNut, .audNut, .prefixSeiNut,
      .rsvNvcl41, .rsvNvcl42, .rsvNvcl43, .rsvNvcl44,
      .unspec48, .unspec49, .unspec50, .unspec51,
      .unspec52, .unspec53, .unspec54, .unspec55:
      return true
    default:
      return false
    }
  }

  private mutating func finalizeAccessUnit(
    _ au: inout AccessUnit
  ) -> Result<VideoFrame, DepacketizeError> {
    var pieceIdx = 0
    var totalLen = 0
    var isRandomAccessPoint = false
    let isDisposable = false
    var vpsCandidates = ParameterSetCandidates(stored: parameters?.vpsNAL)
    var spsCandidates = ParameterSetCandidates(stored: parameters?.spsNAL)
    var ppsCandidates = ParameterSetCandidates(stored: parameters?.ppsNAL)

    // First pass: check parameters, RAP status, calculate total length
    for nal in nals {
      let nextPieceIdx = nal.nextPieceIdx
      let nalPieces = Array(pieces[pieceIdx..<nextPieceIdx])

      switch nal.hdr.unitType {
      case .vpsNut:
        vpsCandidates.add(reassembleNAL(nal, pieces: nalPieces))
      case .spsNut:
        spsCandidates.add(reassembleNAL(nal, pieces: nalPieces))
      case .ppsNut:
        ppsCandidates.add(reassembleNAL(nal, pieces: nalPieces))
      default:
        // IRAP pictures (BLA, IDR, CRA, reserved IRAP: types 16...23).
        if case .vcl(intraCoded: true) = nal.hdr.unitType.unitTypeClass {
          isRandomAccessPoint = true
        }
      }

      totalLen += 4 + nal.len
      pieceIdx = nextPieceIdx
    }

    // Second pass: build AVCC output
    var data = Data(capacity: totalLen)
    pieceIdx = 0
    for nal in nals {
      let nextPieceIdx = nal.nextPieceIdx
      // 4-byte big-endian length
      let len = UInt32(nal.len)
      data.append(UInt8(len >> 24))
      data.append(UInt8((len >> 16) & 0xFF))
      data.append(UInt8((len >> 8) & 0xFF))
      data.append(UInt8(len & 0xFF))
      // 2-byte NAL header
      data.append(contentsOf: nal.hdr.rawBytes)
      // NAL body pieces
      for i in pieceIdx..<nextPieceIdx {
        data.append(pieces[i])
      }
      pieceIdx = nextPieceIdx
    }

    resetAccumulation()

    // Update parameters if changed
    let newVPS = vpsCandidates.replacement
    let newSPS = spsCandidates.replacement
    let newPPS = ppsCandidates.replacement
    let allNew = newVPS != nil && newSPS != nil && newPPS != nil
    let someNew = newVPS != nil || newSPS != nil || newPPS != nil
    let hasNewParameters: Bool
    if allNew || (someNew && parameters != nil) {
      let vps = newVPS ?? parameters!.vpsNAL
      let sps = newSPS ?? parameters!.spsNAL
      let pps = newPPS ?? parameters!.ppsNAL
      do {
        let newParams = try H265Parameters.parseVPSSPSPPS(
          vps: vps, sps: sps, pps: pps)
        parameters = newParams
        hasNewParameters = true
      } catch {
        return .failure(DepacketizeError("Failed to parse updated parameters: \(error)"))
      }
    } else {
      hasNewParameters = false
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
        parameterSets: parameters.map {
          VideoParameterSetNALs(sps: $0.spsNAL, pps: $0.ppsNAL, vps: $0.vpsNAL)
        }))
  }

  /// Reassemble a NAL from its 2-byte header and pieces.
  private func reassembleNAL(_ nal: NALEntry, pieces: [Data]) -> Data {
    var result = Data(capacity: nal.len)
    result.append(contentsOf: nal.hdr.rawBytes)
    for piece in pieces {
      result.append(piece)
    }
    return result
  }
}
