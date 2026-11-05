// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/client/rtp.rs - RTP/RTCP sequence tracking and SSRC validation

import Foundation

/// Policy for handling RTCP packets with unknown/mismatched SSRC.
/// Matches upstream UnknownRtcpSsrcPolicy.
enum UnknownRtcpSsrcPolicy: Sendable {
  /// Default behavior: drop packets with a mismatched SSRC. For RTP, two
  /// consecutive packets (consecutive sequence numbers) from one new SSRC
  /// switch the stream to that source.
  case dropPackets
  /// Error out on mismatched SSRC.
  case abortSession
  /// Accept packets regardless of SSRC.
  case processPackets
}

/// Tracks RTP packet ordering, SSRC consistency, and loss detection.
///
/// Handles:
/// - SSRC validation (drop mismatched SSRCs; follow a new SSRC once two
///   consecutive packets confirm it)
/// - Sequence number tracking and loss detection
/// - Out-of-order packet detection (drop, emit diagnostic on TCP)
/// - Sequence jumps (resync per RFC 3550 appendix A.1)
/// - Geovision PT=50 quirk (silently drop)
/// - RTCP compound packet validation and SR timestamp placement
struct InorderParser: Sendable {
  /// RFC 3550 appendix A.1 `MAX_MISORDER`: a packet at most this many sequence
  /// numbers behind the expected one is late or a duplicate and is dropped.
  /// Anything further back, or 0x8000 or more ahead, is a sequence jump.
  private static let maxMisorder: UInt16 = 100

  /// An RTP timestamp further behind the timeline than this means the
  /// sender's RTP clock restarted, even with the same SSRC.
  private static let maxBackwardJumpSeconds: UInt32 = 5

  private var ssrc: UInt32?
  private var nextSeq: UInt16?
  /// UDP only: after a sequence jump, the sequence number that confirms it
  /// (the jumping packet's successor), as RFC 3550 appendix A.1 `bad_seq`.
  private var badSeq: UInt16?
  /// The SSRC of the previous packet when it differed from `ssrc`, with the
  /// sequence number its next packet would carry. A matching packet right
  /// after it switches the stream to that source.
  private var ssrcCandidate: SSRCCandidate?
  /// The next accepted packet starts a new source (SSRC change or
  /// `restartSequenceTracking`), so its timestamp rebases the timeline.
  private var rebasePending = false
  /// Set by `restartSequenceTracking`; the sequence number of the first
  /// packet accepted after it, which tells a seek response's RTP-Info whether
  /// the new playback has already started.
  private var restarted = false
  private var firstSequenceSinceRestart: UInt16?
  /// Seconds after the timeline's start where the first packet after
  /// `restartSequenceTracking` goes (the seek's common start), if any.
  private var restartTarget: Double?
  private var isTcp: Bool
  var timeline: Timeline
  private var unknownRtcpSsrcPolicy: UnknownRtcpSsrcPolicy
  private let onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)?

  /// Kinds of recurring per-packet anomaly we warn about at most once per stream,
  /// so a hostile/sloppy camera can't flood the diagnostic sink with one
  /// diagnostic per packet.
  private enum DiagKind: Sendable {
    case malformedRtp, ssrcMismatch, ssrcChange, rtpTimeline, outOfOrderTcp, sequenceJump
    case rtpClockRestart
    case unknownRtcpSsrc, malformedRtcp, rtcpTimeline
  }

  private struct SSRCCandidate: Sendable {
    var ssrc: UInt32
    var nextSeq: UInt16
  }
  private var warned: Set<DiagKind> = []

  /// Number of RTP packets seen.
  private(set) var seenRtpPackets: UInt64 = 0

  /// Number of RTCP packets seen.
  private(set) var seenRtcpPackets: UInt64 = 0

  init(
    ssrc: UInt32?, nextSeq: UInt16?, isTcp: Bool, timeline: Timeline,
    unknownRtcpSsrcPolicy: UnknownRtcpSsrcPolicy = .dropPackets,
    onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)? = nil
  ) {
    self.ssrc = ssrc
    self.nextSeq = nextSeq
    self.isTcp = isTcp
    self.timeline = timeline
    self.unknownRtcpSsrcPolicy = unknownRtcpSsrcPolicy
    self.onDiagnostic = onDiagnostic
  }

  /// Emit `message` via `onDiagnostic` only the first time `kind` occurs on this
  /// stream; later occurrences are silent (rate-limited per the diagnostic
  /// contract).
  private mutating func warnOnce(
    _ kind: DiagKind, _ severity: RTSPDiagnostic.Severity,
    _ message: @autoclosure () -> String
  ) {
    guard warned.insert(kind).inserted else { return }
    onDiagnostic?(RTSPDiagnostic(severity: severity, message: message()))
  }

  /// Restart sequence tracking after a seek: `nextSeq` (from the PLAY
  /// response's RTP-Info) or, when nil, whatever the next packet carries.
  /// `ssrc` replaces the expected SSRC when given. The timeline continues.
  mutating func reseed(nextSeq: UInt16?, ssrc: UInt32?) {
    self.nextSeq = nextSeq
    badSeq = nil
    ssrcCandidate = nil
    if let ssrc {
      self.ssrc = ssrc
    }
  }

  /// Whether packets of the playback a seek PLAY's RTP-Info describes were
  /// already processed since `restartSequenceTracking`: the latest accepted
  /// packet came from the same source and is at or after `seq` (without
  /// `seq`, any packet since the restart counts). Packets of the previous
  /// playback still in flight come before `seq`.
  func seekPlaybackStarted(seq: UInt16?, ssrc: UInt32?) -> Bool {
    guard restarted, firstSequenceSinceRestart != nil, ssrc == nil || ssrc == self.ssrc else {
      return false
    }
    guard let seq, let nextSeq else { return true }
    return (nextSeq &- 1) &- seq < 0x8000
  }

  /// Apply a seek PLAY response's RTP-Info: the expected sequence number
  /// becomes `seq`, and `rtptime` maps to `elapsedSeconds` on the timeline
  /// (so all streams' new playback starts at the same time). Skipped, and
  /// false returned, when packets of the new playback were already processed
  /// (`seekPlaybackStarted`): moving tracking back then would count those
  /// packets again as loss.
  @discardableResult
  mutating func applySeekRTPInfo(
    seq: UInt16?, rtptime: UInt32?, ssrc: UInt32?, elapsedSeconds: Double?
  ) -> Bool {
    guard !seekPlaybackStarted(seq: seq, ssrc: ssrc) else { return false }
    reseed(nextSeq: seq, ssrc: ssrc)
    if let rtptime, let elapsedSeconds,
      timeline.rebase(mapping: rtptime, toElapsedSeconds: elapsedSeconds)
    {
      rebasePending = false
      restartTarget = nil
    }
    return true
  }

  /// Seconds into the stream where its next frame would have been (see
  /// `Timeline.nextElapsedSeconds`).
  var nextElapsedSeconds: Double? { timeline.nextElapsedSeconds }

  /// Forget the expected source, for a seek whose playback may come from a
  /// new SSRC: clears the expected SSRC, the expected sequence number and any
  /// pending sequence-jump or SSRC-change confirmation. The next packet's SSRC
  /// is accepted as the source without confirmation. The timeline is kept:
  /// that packet's timestamp goes to `target` seconds after the timeline's
  /// start (the seek's common start for all streams, at or after every
  /// stream's latest timestamp), or, without one, one tick after the last
  /// accepted timestamp or at the end of the last delivered frame, whichever
  /// is later (`Timeline.rebase(continuingWith:)`), so timestamps stay
  /// comparable and monotonic across the seek. A later
  /// `applySeekRTPInfo` (the seek PLAY response's RTP-Info) applies as usual.
  mutating func restartSequenceTracking(continuingAt target: Double? = nil) {
    ssrc = nil
    nextSeq = nil
    badSeq = nil
    ssrcCandidate = nil
    rebasePending = timeline.hasAdvanced || target != nil
    restartTarget = target
    restarted = true
    firstSequenceSinceRestart = nil
  }

  /// Process an incoming RTP packet.
  ///
  /// Returns a ReceivedRTPPacket if the packet should be processed,
  /// or nil if it should be skipped (e.g., PT=50, out-of-order on UDP).
  mutating func rtp(
    data: Data,
    ctx: PacketContext,
    streamId: Int,
    streamCtx: StreamContext
  ) throws -> ReceivedRTPPacket? {
    let raw: RawRTPPacket
    switch RawRTPPacket.parse(data) {
    case .success(let pkt):
      raw = pkt
    case .failure(let reason):
      // A malformed datagram (truncated, wrong version, bad padding/extension)
      // is dropped, never fatal: one bad packet must not tear down the stream.
      warnOnce(
        .malformedRtp, .warning,
        "Invalid RTP packet from camera; dropping: \(reason). "
          + "Further malformed RTP on this stream is dropped silently.")
      return nil
    }

    // Geovision quirk: skip PT=50 packets
    if raw.payloadType == 50 {
      return nil
    }

    // SSRC validation. A packet from another SSRC (a camera that rotated its
    // SSRC after an internal restart, or a stray/spoofed datagram) is dropped
    // by default, but two consecutive packets from one new SSRC with
    // consecutive sequence numbers switch the stream to it, on TCP and UDP
    // alike: a single stray packet can't take the stream over, and a real
    // source change costs one packet instead of silencing the stream.
    // `.abortSession` is the opt-in fatal policy.
    var newSource = false
    if let expectedSSRC = ssrc, raw.ssrc != expectedSSRC {
      switch unknownRtcpSsrcPolicy {
      case .abortSession:
        throw RTSPError.depacketizationError(
          "SSRC mismatch: expected \(String(format: "%08x", expectedSSRC)), "
            + "got \(String(format: "%08x", raw.ssrc))")
      case .dropPackets:
        guard let candidate = ssrcCandidate, candidate.ssrc == raw.ssrc,
          candidate.nextSeq == raw.sequenceNumber
        else {
          ssrcCandidate = SSRCCandidate(ssrc: raw.ssrc, nextSeq: raw.sequenceNumber &+ 1)
          warnOnce(
            .ssrcMismatch, .warning,
            "RTP SSRC mismatch (expected \(String(format: "%08x", expectedSSRC)), "
              + "got \(String(format: "%08x", raw.ssrc))); dropping. Two consecutive "
              + "packets from a new SSRC switch the stream to it. Further "
              + "SSRC-mismatched RTP on this stream is handled silently.")
          return nil
        }
        warnOnce(
          .ssrcChange, .warning,
          "RTP SSRC changed from \(String(format: "%08x", expectedSSRC)) to "
            + "\(String(format: "%08x", raw.ssrc)); following the new source. "
            + "Further SSRC changes on this stream are handled silently.")
        ssrc = raw.ssrc
        ssrcCandidate = nil
        nextSeq = nil
        badSeq = nil
        rebasePending = timeline.hasAdvanced
        newSource = true
      case .processPackets:
        break
      }
    } else {
      if ssrc == nil {
        ssrc = raw.ssrc
      }
      ssrcCandidate = nil
    }

    // Sequence number tracking and loss detection, after RFC 3550 appendix A.1.
    var loss: UInt16 = 0
    if let expected = nextSeq {
      let delta = raw.sequenceNumber &- expected
      if delta < 0x8000 {
        loss = delta
      } else if delta > UInt16.max - Self.maxMisorder {
        // Slightly behind: late or a duplicate. UDP reordering is normal and
        // stays silent; TCP-interleaved reordering means the camera's
        // packetizer wrote sequence-numbers out of order before muxing, which
        // is camera misbehavior worth surfacing (once).
        if isTcp {
          warnOnce(
            .outOfOrderTcp, .warning,
            "Out-of-order RTP packet on TCP-interleaved transport: "
              + "seq=\(raw.sequenceNumber), expected=\(expected); packet dropped. "
              + "Further out-of-order RTP on this stream is dropped silently.")
        }
        return nil
      } else {
        // A jump: far behind, or 0x8000 or more ahead (e.g. the sender
        // restarted its sequence). TCP can't reorder or carry strays, so
        // resync at once. On UDP the jumping packet may be a stray: drop it
        // and resync only if its successor follows (appendix A.1 bad_seq).
        if !isTcp && badSeq != raw.sequenceNumber {
          badSeq = raw.sequenceNumber &+ 1
          return nil
        }
        warnOnce(
          .sequenceJump, .warning,
          "RTP sequence number jumped (expected \(expected), got \(raw.sequenceNumber)); "
            + "resynchronized to the new sequence. Further jumps on this stream are "
            + "handled silently.")
        badSeq = nil
        // The discontinuity is reported as loss so depacketizers discard any
        // partial frame.
        loss = 1
      }
    }
    if newSource {
      loss = max(loss, 1)
    }
    // A sender whose RTP clock went back by more than a few seconds restarted
    // (its SSRC and sequence numbers may have carried on). Continue the
    // timeline from the previous timestamp: otherwise the timestamps would
    // fall before the start of the stream and every later packet would be
    // dropped as a timeline error.
    if !rebasePending,
      timeline.isBehind(raw.rtpTimestamp, bySeconds: Self.maxBackwardJumpSeconds)
    {
      warnOnce(
        .rtpClockRestart, .warning,
        "RTP timestamp went back more than \(Self.maxBackwardJumpSeconds) s (sender restart?); "
          + "timestamps continue from the previous packet. Further restarts on this stream "
          + "are handled silently.")
      rebasePending = true
      loss = max(loss, 1)
    }
    nextSeq = raw.sequenceNumber &+ 1
    seenRtpPackets += 1
    if restarted && firstSequenceSinceRestart == nil {
      firstSequenceSinceRestart = raw.sequenceNumber
    }

    let rebased = rebasePending
    if rebasePending {
      let mapped =
        restartTarget.map {
          timeline.rebase(
            mapping: raw.rtpTimestamp,
            toElapsedSeconds: max($0, timeline.nextElapsedSeconds ?? 0))
        } ?? false
      if !mapped { timeline.rebase(continuingWith: raw.rtpTimestamp) }
      rebasePending = false
      restartTarget = nil
    }

    // Advance timeline. A rejected/overflowing timestamp drops this packet
    // rather than aborting the session.
    let timestamp: Timestamp
    do {
      timestamp = try timeline.advanceTo(raw.rtpTimestamp)
    } catch {
      warnOnce(
        .rtpTimeline, .warning,
        "RTP timestamp rejected (\(error)); dropping. "
          + "Further timeline errors on this stream are dropped silently.")
      return nil
    }

    return ReceivedRTPPacket(
      ctx: ctx,
      streamId: streamId,
      timestamp: timestamp,
      raw: raw,
      loss: loss,
      timelineRebased: rebased
    )
  }

  /// Process an incoming RTCP compound packet.
  ///
  /// Validates the compound packet per RFC 3550 Appendix A.2, extracts
  /// the Sender Report's RTP timestamp if present, and validates SSRC.
  /// Matches upstream rtcp() method (client/rtp.rs lines 243-311).
  mutating func rtcp(
    ctx: PacketContext,
    streamId: Int,
    data: Data
  ) throws -> ReceivedCompoundPacket? {
    // A malformed RTCP compound packet is dropped, not fatal.
    let firstPkt: RTCPPacketRef
    let sr: SenderReportRef?
    do {
      firstPkt = try ReceivedCompoundPacket.validate(data)
      sr = try firstPkt.asSenderReport()
    } catch {
      warnOnce(
        .malformedRtcp, .warning,
        "Invalid RTCP packet from camera; dropping: \(error). "
          + "Further malformed RTCP on this stream is dropped silently.")
      return nil
    }

    var rtpTimestamp: Timestamp?

    if let sr = sr {
      let srSSRC = sr.ssrc
      if let knownSSRC = ssrc, knownSSRC != srSSRC {
        switch unknownRtcpSsrcPolicy {
        case .abortSession:
          throw RTSPError.depacketizationError(
            "Expected ssrc=\(String(format: "%08x", knownSSRC)), "
              + "got RTCP SR ssrc=\(String(format: "%08x", srSSRC))")
        case .dropPackets:
          // Drop BEFORE touching the timeline: place() permanently anchors the
          // timeline `start` on the first SR, so a foreign/early SR must not be
          // allowed to corrupt the origin used by every subsequent RTP packet's
          // NPT. Warn once per stream; further unknown-SSRC SRs drop silently.
          warnOnce(
            .unknownRtcpSsrc, .warning,
            "RTCP Sender Report with unexpected ssrc="
              + "\(String(format: "%08x", srSSRC)) (expected "
              + "\(String(format: "%08x", knownSSRC))); dropping. Further "
              + "unknown-SSRC RTCP on this stream is dropped silently.")
          return nil
        case .processPackets:
          break
        }
      }
      // An SR never sets the RTP source: before the first RTP packet its SSRC
      // is unchecked, and the RTP stream decides which SSRC is followed.
      //
      // Only anchor/advance the timeline for an SR we are actually keeping. A
      // rejected/overflowing SR timestamp drops the packet rather than aborting.
      // While a rebase is pending (after `restartSequenceTracking`), the new
      // source's timestamps aren't mapped yet, so the SR is kept unplaced.
      if !rebasePending {
        do {
          rtpTimestamp = try timeline.place(sr.rtpTimestamp)
        } catch {
          warnOnce(
            .rtcpTimeline, .warning,
            "RTCP SR timestamp rejected (\(error)); dropping. "
              + "Further RTCP timeline errors on this stream are dropped silently.")
          return nil
        }
      }
    }

    seenRtcpPackets += 1
    return ReceivedCompoundPacket(
      ctx: ctx,
      streamId: streamId,
      rtpTimestamp: rtpTimestamp,
      raw: data
    )
  }
}
