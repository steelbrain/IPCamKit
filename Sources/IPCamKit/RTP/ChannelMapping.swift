// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/client/channel_mapping.rs - TCP interleaved channel management

import Foundation

/// Type of data on an interleaved channel.
enum ChannelType: Sendable, Equatable {
  case rtp
  case rtcp
}

/// Mapping from a channel ID to a stream and channel type.
struct ChannelMapping: Sendable, Equatable {
  var streamIndex: Int
  var channelType: ChannelType
}

/// Manages TCP interleaved channel assignments.
///
/// Channels are assigned in even/odd pairs: even = RTP, odd = RTCP.
/// Supports up to 128 stream pairs (256 channels, 0-255).
struct ChannelMappings: Sendable {
  /// Each element at index i maps to channel pair (i*2, i*2+1).
  /// nil means unassigned.
  private var slots: [Int?]

  init() {
    self.slots = []
  }

  /// Returns the next unassigned even channel ID, or nil if all 128 slots are used.
  func nextUnassigned() -> UInt8? {
    for i in 0..<128 {
      if i >= slots.count || slots[i] == nil {
        return UInt8(i * 2)
      }
    }
    return nil
  }

  /// Assign a channel pair to a stream.
  ///
  /// - Parameters:
  ///   - channelId: Must be even (the RTP channel)
  ///   - streamIndex: The stream index
  mutating func assign(channelId: UInt8, streamIndex: Int) throws {
    guard channelId % 2 == 0 else {
      throw RTSPError.depacketizationError(
        "Channel ID \(channelId) must be even")
    }
    guard streamIndex < 255 else {
      throw RTSPError.depacketizationError(
        "Stream index \(streamIndex) too large")
    }

    let slotIndex = Int(channelId / 2)

    // Extend slots array if needed
    while slots.count <= slotIndex {
      slots.append(nil)
    }

    guard slots[slotIndex] == nil else {
      throw RTSPError.depacketizationError(
        "Channel \(channelId) already assigned")
    }

    slots[slotIndex] = streamIndex
  }

  /// Look up a channel ID to find the stream and whether it's RTP or RTCP.
  func lookup(_ channelId: UInt8) -> ChannelMapping? {
    let slotIndex = Int(channelId / 2)
    guard slotIndex < slots.count, let streamIndex = slots[slotIndex] else {
      return nil
    }
    let channelType: ChannelType = (channelId % 2 == 0) ? .rtp : .rtcp
    return ChannelMapping(streamIndex: streamIndex, channelType: channelType)
  }
}
