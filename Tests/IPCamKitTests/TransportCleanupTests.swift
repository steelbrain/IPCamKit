// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Transports dropped without close() release their sockets.

import Darwin
import Foundation
import Testing

@testable import IPCamKit

/// Whether a UDP socket can bind `0.0.0.0:port` right now.
private func canBindUDP(_ port: UInt16) -> Bool {
  let fd = socket(AF_INET, SOCK_DGRAM, 0)
  guard fd >= 0 else { return false }
  defer { Darwin.close(fd) }
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = port.bigEndian
  address.sin_addr = in_addr(s_addr: INADDR_ANY)
  return withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
    }
  }
}

private func eventually(_ condition: () async -> Bool) async -> Bool {
  for _ in 0..<150 {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return false
}

@Suite("Transport cleanup")
struct TransportCleanupTests {
  @Test("A UDP pair dropped without close() frees its ports")
  func droppedUDPPair() async throws {
    var port: UInt16 = 0
    do {
      let pair = try await UDPPair.bind(family: .ipv4)
      port = pair.rtpPort
      #expect(!canBindUDP(port), "the bound pair holds its RTP port")
    }
    let rtpPort = port
    #expect(await eventually { canBindUDP(rtpPort) })
  }

  @Test("A connection dropped without close() closes its socket")
  func droppedConnection() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    try await server.start()
    defer { server.stop() }
    let port = try #require(URLComponents(string: server.url)?.port)
    do {
      let connection = RTSPTransportConnection()
      try await connection.connect(host: "127.0.0.1", port: UInt16(port))
      #expect(await eventually { server.sessionHandles.count == 1 })
    }
    #expect(await eventually { server.sessionHandles.allSatisfy(\.isClosed) })
  }
}

extension TransportCleanupTests {
  @Test("The RTSP read buffer doesn't keep the bytes of messages it has parsed")
  func readBufferReleasesParsedBytes() throws {
    let parser = RTSPParser()
    var frame = Data([0x24, 0, 0x05, 0x78])
    frame.append(Data(repeating: 0x80, count: 1400))
    // Each read ends the previous read's last frame, carries nine whole
    // frames, and ends with the first half of another.
    var read = Data(frame.suffix(704))
    for _ in 0..<9 { read.append(frame) }
    read.append(frame.prefix(700))

    var buffer = Data(frame.prefix(700))
    var parsed = 0
    for _ in 0..<1000 {
      RTSPTransportConnection.appendCompacting(read, to: &buffer)
      while case .message = try parser.parseNext(&buffer) { parsed += 1 }
    }
    #expect(parsed == 10_000)
    // Before, the storage held every byte read (start index about 14 MB).
    RTSPTransportConnection.appendCompacting(Data(), to: &buffer)
    #expect(buffer.startIndex == 0)
    #expect(buffer.count == 700)
  }
}
