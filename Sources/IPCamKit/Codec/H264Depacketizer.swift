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

    if let fmtp = formatSpecificParams {
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
        fuA: nil, loss: pkt.loss + additionalLoss,
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

  // MARK: - Public Interface

  mutating func push(_ pkt: ReceivedRTPPacket) throws {
    let result = pushInner(pkt)
    // Clear nals and pieces if not in preMark state
    if case .preMark = inputState {
    } else {
      nals.removeAll(keepingCapacity: true)
      pieces.removeAll(keepingCapacity: true)
    }
    if case .failure(let err) = result {
      throw err
    }
  }

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
    // Resolve access unit from state machine
    var accessUnit: AccessUnit

    switch inputState {
    case .new:
      accessUnit = AccessUnit.start(pkt, additionalLoss: 0, sameTsAsPrev: false)

    case .preMark(var au):
      au.endCtx = pkt.ctx
      let loss = pkt.loss
      if loss > 0 {
        nals.removeAll(keepingCapacity: true)
        pieces.removeAll(keepingCapacity: true)
        if sameTimestamp(pkt.timestamp, au.timestamp) {
          if pkt.mark {
            inputState = .postMark(timestamp: au.timestamp, loss: loss)
          } else {
            inputState = .loss(timestamp: au.timestamp, pkts: loss)
          }
          return .success(())
        }
        // Different timestamp: discard old AU, start fresh
        accessUnit = AccessUnit.start(pkt, additionalLoss: 0, sameTsAsPrev: false)
      } else if !sameTimestamp(pkt.timestamp, au.timestamp) {
        // Timestamp changed
        if au.fuA != nil {
          // Mid-fragment timestamp change
          let desc =
            "timestamp changed from \(au.timestamp) to \(pkt.timestamp) in the middle of a fragmented NAL"
          pending.append(.failure(DepacketizeError(desc)))
          nals.removeAll(keepingCapacity: true)
          pieces.removeAll(keepingCapacity: true)
          accessUnit = AccessUnit.start(pkt, additionalLoss: 0, sameTsAsPrev: false)
        } else if !nals.isEmpty && canEndAU(nals.last!) {
          // Normal AU boundary
          let frame = finalizeAccessUnit(&au)
          pending.append(frame)
          nals.removeAll(keepingCapacity: true)
          pieces.removeAll(keepingCapacity: true)
          accessUnit = AccessUnit.start(pkt, additionalLoss: 0, sameTsAsPrev: false)
        } else if nals.isEmpty {
          au.timestamp = pkt.timestamp
          accessUnit = au
        } else {
          // SPS/PPS can't end AU — Reolink quirk, absorb new timestamp
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
        lossPkts += pkt.loss
        inputState = .loss(timestamp: lossTs, pkts: lossPkts)
        return .success(())
      }
      accessUnit = AccessUnit.start(pkt, additionalLoss: lossPkts, sameTsAsPrev: false)
    }

    // Parse NAL header from payload
    let payload = pkt.payload
    guard !payload.isEmpty else {
      return .success(())
    }

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

      if isStart && isEnd {
        return .failure(DepacketizeError("Invalid FU-A: both START and END set"))
      }
      if !isEnd && pkt.mark {
        return .failure(DepacketizeError("FU-A with MARK but no END bit"))
      }

      let fuPayload = Data(payload[(payload.startIndex + 2)...])

      if isStart {
        if accessUnit.fuA != nil {
          return .failure(DepacketizeError("FU-A START while fragment already in progress"))
        }
        var fuState = FuAState(
          initialNalHeader: reconstructedHeader,
          curNal: CurFuANal(hdr: reconstructedHeader, trailingZeros: 0, piecesBytes: 0))
        do {
          try addFuA(curNal: &fuState.curNal, data: fuPayload)
        } catch {
          return .failure(DepacketizeError("\(error)"))
        }
        accessUnit.fuA = fuState
      } else if var fuState = accessUnit.fuA {
        // Continuation or end
        if reconstructedHeader != fuState.initialNalHeader && !seenInconsistentFuANalHdr {
          seenInconsistentFuANalHdr = true
        }
        do {
          try addFuA(curNal: &fuState.curNal, data: fuPayload)
        } catch {
          return .failure(DepacketizeError("\(error)"))
        }
        if isEnd {
          // Finalize the FU-A NAL
          if let c = fuState.curNal {
            let totalLen = 1 + c.piecesBytes  // header + body
            nals.append(
              NALEntry(
                hdr: c.hdr,
                nextPieceIdx: pieces.count,
                len: totalLen))
          }
          fuState.curNal = nil
          accessUnit.fuA = nil
        } else {
          accessUnit.fuA = fuState
        }
      } else {
        if pkt.loss > 0 {
          inputState = .loss(timestamp: accessUnit.timestamp, pkts: pkt.loss)
          nals.removeAll(keepingCapacity: true)
          pieces.removeAll(keepingCapacity: true)
          return .success(())
        }
        return .failure(DepacketizeError("FU-A continuation without START"))
      }

    case 0, 30, 31:
      return .failure(DepacketizeError("Bad NAL header type \(nalType)"))

    default:
      return .failure(DepacketizeError("Unknown NAL type \(nalType)"))
    }

    // Post-processing: handle mark bit
    if pkt.mark {
      if !nals.isEmpty && canEndAU(nals.last!) {
        accessUnit.endCtx = pkt.ctx
        let frame = finalizeAccessUnit(&accessUnit)
        pending.append(frame)
        inputState = .postMark(timestamp: pkt.timestamp, loss: 0)
      } else if !nals.isEmpty {
        // Mark set but last NAL is SPS/PPS — update AU timestamp
        // (matches upstream h264.rs line 517: access_unit.timestamp.timestamp = timestamp.timestamp)
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

  // MARK: - NAL Processing

  private mutating func addSingleNal(_ data: Data) -> Result<Void, DepacketizeError> {
    guard !data.isEmpty else { return .success(()) }
    let len = data.count
    let hdr = NALHeader(data[data.startIndex])
    if hdr.forbiddenZeroBit {
      return .failure(DepacketizeError("Forbidden zero bit in NAL header within Annex B or STAP-A"))
    }
    let body = data.count > 1 ? Data(data[(data.startIndex + 1)...]) : Data()
    if !body.isEmpty {
      pieces.append(body)
    }
    nals.append(
      NALEntry(
        hdr: hdr,
        nextPieceIdx: pieces.count,
        len: len))
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
            c.piecesBytes += piece.count
            pieces.append(piece)
          }
          // Finalize current NAL
          nals.append(
            NALEntry(
              hdr: c.hdr,
              nextPieceIdx: pieces.count,
              len: c.piecesBytes + 1))
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
            c.piecesBytes += prevChunkZeros
            pieces.append(Data(repeating: 0, count: prevChunkZeros))
          }
          c.trailingZeros = 0
          curPos += 1
        }
      }

      // Push non-trailing-zero portion of remaining data
      let nonTrailingEnd = bytes.count - c.trailingZeros
      if nonTrailingEnd > dataOffset {
        let piece = Data(bytes[dataOffset..<nonTrailingEnd])
        c.piecesBytes += piece.count
        pieces.append(piece)
      }
      curNal = c
      return
    }
  }

  // MARK: - Diagnostics

  /// Validate NAL ordering per H.264 section 7.4.1.2.3 (diagnostic only).
  /// Ports upstream `validate_order` from h264.rs lines 816-854.
  private func validateOrder(_ nals: [NALEntry]) -> String {
    var errs = ""
    var seenVCL = false
    for (i, nal) in nals.enumerated() {
      switch nal.hdr.nalUnitTypeId {
      case 1, 2, 3, 4, 5:
        seenVCL = true
      case 6:  // SEI
        if seenVCL { errs += "\n* SEI after VCL" }
      case 9:  // Access Unit Delimiter
        if i != 0 { errs += "\n* access unit delimiter must be first in AU" }
      case 10:  // End of Sequence
        if !seenVCL { errs += "\n* end of sequence without VCL" }
      case 11:  // End of Stream
        if i != nals.count - 1 { errs += "\n* end of stream NAL isn't last" }
      default:
        break
      }
    }
    if !seenVCL { errs += "\n* missing VCL" }
    return errs
  }

  // MARK: - Access Unit Finalization

  private func canEndAU(_ nal: NALEntry) -> Bool {
    let nalType = nal.hdr.nalUnitTypeId
    // SPS and PPS cannot end an access unit (handles Reolink quirk)
    return nalType != 7 && nalType != 8
  }

  private mutating func finalizeAccessUnit(
    _ au: inout AccessUnit
  ) -> Result<VideoFrame, DepacketizeError> {
    var isRandomAccessPoint = false
    var isDisposable = true
    var totalLen = 0
    var newSPS: Data?
    var newPPS: Data?

    // First pass: check parameters, RAP status, calculate total length
    var pieceIdx = 0
    for nal in nals {
      let nalType = nal.hdr.nalUnitTypeId
      switch nalType {
      case 7:
        // SPS
        let spsData = reassembleNal(nal, startPieceIdx: pieceIdx)
        if parameters == nil || spsData != parameters!.spsNAL {
          newSPS = spsData
        }
      case 8:
        // PPS
        let ppsData = reassembleNal(nal, startPieceIdx: pieceIdx)
        if parameters == nil || ppsData != parameters!.ppsNAL {
          newPPS = ppsData
        }
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
        data: data
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
