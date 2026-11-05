// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// ONVIF replay RTP header extension (ONVIF Streaming Specification, replay).

import Foundation

/// The RTP header extension an ONVIF replay server attaches to its packets
/// (every packet, or at least the first packet of each access unit):
///
/// ```
///  0                   1                   2                   3
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |            0xABAC             |          length = 3           |
/// |                     NTP timestamp (64 bits)                   |
/// |                                                               |
/// |C|E|D|T|  mbz  |     CSeq      |            padding            |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
///
/// The NTP timestamp is the recording time of the packet's frame; C marks a
/// clean point (start of a key frame), E the end of a contiguous recorded
/// section, D a discontinuity (data missing before this packet), T the last
/// packet of the playback; CSeq is the low byte of the PLAY request's CSeq
/// that the packet belongs to. Longer extensions (other ONVIF elements after
/// the first three words) are accepted; only the first 12 bytes are read.
struct ONVIFReplayExtension: Sendable, Equatable {
  static let profile: UInt16 = 0xABAC

  let ntpTimestamp: UInt64
  let cleanPoint: Bool
  let endOfSection: Bool
  let discontinuity: Bool
  let terminal: Bool
  let cseq: UInt8

  init(
    ntpTimestamp: UInt64, cleanPoint: Bool, endOfSection: Bool, discontinuity: Bool,
    terminal: Bool, cseq: UInt8
  ) {
    self.ntpTimestamp = ntpTimestamp
    self.cleanPoint = cleanPoint
    self.endOfSection = endOfSection
    self.discontinuity = discontinuity
    self.terminal = terminal
    self.cseq = cseq
  }

  /// Parse an RTP header extension; nil unless it is the ONVIF replay profile
  /// with at least 12 bytes of data.
  init?(profile: UInt16, data: Data) {
    guard profile == Self.profile, data.count >= 12 else { return nil }
    let base = data.startIndex
    var ntp: UInt64 = 0
    for offset in 0..<8 {
      ntp = ntp << 8 | UInt64(data[base + offset])
    }
    let flags = data[base + 8]
    self.ntpTimestamp = ntp
    self.cleanPoint = flags & 0x80 != 0
    self.endOfSection = flags & 0x40 != 0
    self.discontinuity = flags & 0x20 != 0
    self.terminal = flags & 0x10 != 0
    self.cseq = data[base + 9]
  }

  /// The replay extension of an RTP packet (unparsed wire bytes), or nil when
  /// the packet has no header extension or another kind of one. Bounds are
  /// checked here, since this runs before the packet is validated.
  init?(rtpPacket: Data) {
    guard let ext = rtpHeaderExtension(rtpPacket) else { return nil }
    self.init(profile: ext.profile, data: ext.data)
  }

  /// The recording time as a `Date`.
  var date: Date { NtpTimestamp(rawValue: ntpTimestamp).date }
}

/// The RFC 3550 header extension of an RTP packet: its 16-bit profile and its
/// data without the 4-byte extension header. nil if the packet is not RTP
/// version 2, the X bit is clear, or the extension doesn't fit.
func rtpHeaderExtension(_ packet: Data) -> (profile: UInt16, data: Data)? {
  let base = packet.startIndex
  guard packet.count >= 12, packet[base] >> 6 == 2, packet[base] & 0b0001_0000 != 0 else {
    return nil
  }
  let csrcEnd = 12 + 4 * Int(packet[base] & 0b0000_1111)
  guard packet.count >= csrcEnd + 4 else { return nil }
  let profile = UInt16(packet[base + csrcEnd]) << 8 | UInt16(packet[base + csrcEnd + 1])
  let words = Int(UInt16(packet[base + csrcEnd + 2]) << 8 | UInt16(packet[base + csrcEnd + 3]))
  let start = base + csrcEnd + 4
  let end = start + words * 4
  guard end <= packet.endIndex else { return nil }
  return (profile, packet[start..<end])
}

extension RawRTPPacket {
  /// The RFC 3550 header extension (16-bit profile, data without the 4-byte
  /// extension header), or nil if the X bit is clear.
  var headerExtension: (profile: UInt16, data: Data)? {
    rtpHeaderExtension(data)
  }
}

/// Remembers the replay extensions of a stream's recent packets so a frame
/// assembled from them can be annotated with `ReplayInfo`.
///
/// Packets of one frame share an RTP timestamp, so entries are keyed by the
/// extended RTP timestamp and the flags of all packets with that timestamp are
/// combined. A frame whose timestamp has no entry of its own (e.g. the second
/// AAC access unit of an aggregated packet) gets the time of the closest
/// earlier entry advanced by the timestamp difference, with no flags.
struct ReplayTracker: Sendable {
  private struct Entry: Sendable {
    var timestamp: Int64
    var ext: ONVIFReplayExtension
  }

  /// Bound on remembered timestamps; frames are pulled within a few packets of
  /// their last packet, so this only needs to cover the depacketizer's lag.
  private static let capacity = 128

  private var entries: [Entry] = []

  /// Record a packet's extension at its extended RTP timestamp.
  mutating func record(timestamp: Int64, ext: ONVIFReplayExtension) {
    if let last = entries.indices.last, entries[last].timestamp == timestamp {
      let merged = entries[last].ext
      entries[last].ext = ONVIFReplayExtension(
        ntpTimestamp: merged.ntpTimestamp,
        cleanPoint: merged.cleanPoint || ext.cleanPoint,
        endOfSection: merged.endOfSection || ext.endOfSection,
        discontinuity: merged.discontinuity || ext.discontinuity,
        terminal: merged.terminal || ext.terminal,
        cseq: ext.cseq)
      return
    }
    entries.append(Entry(timestamp: timestamp, ext: ext))
    if entries.count > Self.capacity {
      entries.removeFirst(entries.count - Self.capacity)
    }
  }

  /// `ReplayInfo` for a frame at extended RTP timestamp `timestamp`.
  func info(forFrameAt timestamp: Int64, clockRate: UInt32) -> ReplayInfo? {
    if let exact = entries.last(where: { $0.timestamp == timestamp }) {
      return ReplayInfo(
        time: exact.ext.date, isCleanPoint: exact.ext.cleanPoint,
        isEndOfSection: exact.ext.endOfSection, isDiscontinuity: exact.ext.discontinuity,
        isTerminal: exact.ext.terminal)
    }
    guard clockRate > 0,
      let earlier = entries.last(where: {
        $0.timestamp < timestamp && timestamp - $0.timestamp <= Int64(clockRate) * 10
      })
    else { return nil }
    let offset = Double(timestamp - earlier.timestamp) / Double(clockRate)
    return ReplayInfo(
      time: earlier.ext.date.addingTimeInterval(offset), isCleanPoint: false,
      isEndOfSection: false, isDiscontinuity: false, isTerminal: false)
  }

  /// Forget everything (after a seek).
  mutating func removeAll() {
    entries.removeAll()
  }
}
