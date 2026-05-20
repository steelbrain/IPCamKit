// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Frame type for RTSP `application` media streams (ONVIF analytics metadata).

import Foundation

/// A depacketized metadata frame from an RTSP `application` stream.
///
/// Per the ONVIF Streaming Specification, the payload is an XML document with
/// root node `tt:MetaDataStream`, optionally GZIP-compressed; the RTP marker
/// bit signals end-of-document.
struct MetadataFrame: Sendable, Equatable {
  /// Context of the last packet in this frame.
  var ctx: PacketContext

  /// Stream index.
  var streamId: Int

  /// RTP timestamp of this frame.
  var timestamp: Timestamp

  /// Number of RTP packets lost before or during this frame.
  var loss: UInt16

  /// Raw payload bytes — typically UTF-8 XML, may be GZIP-compressed.
  var data: Data
}
