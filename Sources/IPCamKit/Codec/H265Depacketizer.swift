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

    if let fmtp = formatSpecificParams {
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
        inFU: false, loss: pkt.loss + additionalLoss,
        sameTsAsPrev: sameTsAsPrev)
    }
  }

  // MARK: - Public Interface

  mutating func push(_ pkt: ReceivedRTPPacket) throws {
    let result = pushInner(pkt)
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

  private func sameTimestamp(_ a: Timestamp, _ b: Timestamp) -> Bool {
    a.timestamp == b.timestamp
  }

  // MARK: - Core Logic

  private mutating func pushInner(
    _ pkt: ReceivedRTPPacket
  ) -> Result<Void, DepacketizeError> {
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
        accessUnit = AccessUnit.start(pkt, additionalLoss: 0, sameTsAsPrev: false)
      } else if !sameTimestamp(pkt.timestamp, au.timestamp) {
        if au.inFU {
          let desc =
            "timestamp changed from \(au.timestamp) to \(pkt.timestamp) in the middle of a fragmented NAL"
          pending.append(.failure(DepacketizeError(desc)))
          nals.removeAll(keepingCapacity: true)
          pieces.removeAll(keepingCapacity: true)
          accessUnit = AccessUnit.start(pkt, additionalLoss: 0, sameTsAsPrev: false)
        } else if nals.isEmpty {
          return .failure(DepacketizeError("nals should not be empty"))
        } else if canEndAU(nals.last!.hdr.unitType) {
          let frame = finalizeAccessUnit(&au)
          pending.append(frame)
          nals.removeAll(keepingCapacity: true)
          pieces.removeAll(keepingCapacity: true)
          accessUnit = AccessUnit.start(pkt, additionalLoss: 0, sameTsAsPrev: false)
        } else {
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
        lossPkts += pkt.loss
        inputState = .loss(timestamp: lossTs, pkts: lossPkts)
        return .success(())
      }
      accessUnit = AccessUnit.start(pkt, additionalLoss: lossPkts, sameTsAsPrev: false)
    }

    // Parse 2-byte NAL header from payload
    let payload = pkt.payload
    guard payload.count >= 2 else {
      return .failure(DepacketizeError("Short NAL"))
    }
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
      if !body.isEmpty {
        pieces.append(body)
      }
      nals.append(NALEntry(hdr: hdr, nextPieceIdx: pieces.count, len: len))

    case 48:
      // Aggregation Packet (RFC 7798 section 4.4.2)
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
        if !innerBody.isEmpty {
          pieces.append(innerBody)
        }
        nals.append(
          NALEntry(
            hdr: innerHdr, nextPieceIdx: pieces.count,
            len: nalLen))

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

      if isStart && isEnd {
        return .failure(
          DepacketizeError(
            "Invalid FU header \(String(format: "%02x", fuHeader))"))
      }
      if !isEnd && pkt.mark {
        return .failure(DepacketizeError("FU pkt with MARK && !END"))
      }

      let fuPayload = Data(payload[(payload.startIndex + 3)...])

      switch (isStart, accessUnit.inFU) {
      case (true, true):
        return .failure(
          DepacketizeError("FU with start bit while frag in progress"))
      case (true, false):
        pieces.append(fuPayload)
        nals.append(
          NALEntry(
            hdr: reconstructedHdr,
            nextPieceIdx: Int.max,  // overwritten on end
            len: 2 + fuPayload.count))
        accessUnit.inFU = true
      case (false, true):
        pieces.append(fuPayload)
        guard var nal = nals.last else {
          return .failure(DepacketizeError("nals non-empty while in fu"))
        }
        if reconstructedHdr != nal.hdr && !seenInconsistentFuNalHdr {
          seenInconsistentFuNalHdr = true
        }
        nal.len += fuPayload.count
        if isEnd {
          nal.nextPieceIdx = pieces.count
          accessUnit.inFU = false
        }
        nals[nals.count - 1] = nal
      case (false, false):
        if pkt.loss > 0 {
          nals.removeAll(keepingCapacity: true)
          pieces.removeAll(keepingCapacity: true)
          inputState = .loss(timestamp: accessUnit.timestamp, pkts: pkt.loss)
          return .success(())
        }
        return .failure(
          DepacketizeError("FU has start bit unset while no frag in progress"))
      }

    default:
      return .failure(DepacketizeError("unexpected/bad nal header type \(nalTypeRaw)"))
    }

    // Post-processing: handle mark bit
    if pkt.mark {
      guard !nals.isEmpty else {
        return .failure(DepacketizeError("nals should not be empty after mark"))
      }
      if canEndAU(nals.last!.hdr.unitType) {
        accessUnit.endCtx = pkt.ctx
        let frame = finalizeAccessUnit(&accessUnit)
        pending.append(frame)
        inputState = .postMark(timestamp: pkt.timestamp, loss: 0)
      } else {
        accessUnit.timestamp = pkt.timestamp
        inputState = .preMark(accessUnit)
      }
    } else {
      inputState = .preMark(accessUnit)
    }

    return .success(())
  }

  // MARK: - Access Unit Finalization

  /// Returns true if we allow the given NAL unit type to end an access unit.
  private func canEndAU(_ unitType: H265UnitType) -> Bool {
    switch unitType {
    case .vpsNut, .spsNut, .ppsNut,
      .rsvNvcl41, .rsvNvcl42, .rsvNvcl43, .rsvNvcl44,
      .unspec48, .unspec49, .unspec50, .unspec51,
      .unspec52, .unspec53, .unspec54, .unspec55:
      return false
    default:
      return true
    }
  }

  private mutating func finalizeAccessUnit(
    _ au: inout AccessUnit
  ) -> Result<VideoFrame, DepacketizeError> {
    var pieceIdx = 0
    var totalLen = 0
    var isRandomAccessPoint = false
    let isDisposable = false
    var newVPS: Data?
    var newSPS: Data?
    var newPPS: Data?

    // First pass: check parameters, RAP status, calculate total length
    for nal in nals {
      let nextPieceIdx = nal.nextPieceIdx
      let nalPieces = Array(pieces[pieceIdx..<nextPieceIdx])

      switch nal.hdr.unitType {
      case .vpsNut:
        let assembled = reassembleNAL(nal, pieces: nalPieces)
        if parameters == nil || assembled != parameters!.vpsNAL {
          newVPS = assembled
        }
      case .spsNut:
        let assembled = reassembleNAL(nal, pieces: nalPieces)
        if parameters == nil || assembled != parameters!.spsNAL {
          newSPS = assembled
        }
      case .ppsNut:
        let assembled = reassembleNAL(nal, pieces: nalPieces)
        if parameters == nil || assembled != parameters!.ppsNAL {
          newPPS = assembled
        }
      default:
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

    nals.removeAll(keepingCapacity: true)
    pieces.removeAll(keepingCapacity: true)

    // Update parameters if changed
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
        data: data))
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
