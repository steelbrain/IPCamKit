// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// UDPPair delivers whole datagrams larger than 9216 bytes, from the connected
// peer only, until close(), and keeps receiving after an ICMP port-unreachable.

import Darwin
import Foundation
import Testing

@testable import IPCamKit

/// What a `UDPPair` delivered, in arrival order.
private final class Received: @unchecked Sendable {
  private let lock = NSLock()
  private var rtpData: [Data] = []
  private var rtcpData: [Data] = []
  private var errorText: [String] = []

  var rtp: [Data] { lock.withLock { rtpData } }
  var rtcp: [Data] { lock.withLock { rtcpData } }
  var errors: [String] { lock.withLock { errorText } }

  func start(_ pair: UDPPair) {
    pair.startReceiving(
      onRTP: { data in self.lock.withLock { self.rtpData.append(data) } },
      onRTCP: { data in self.lock.withLock { self.rtcpData.append(data) } },
      onError: { error in self.lock.withLock { self.errorText.append("\(error)") } })
  }
}

/// Lock-protected value shared with server hooks and consumer tasks.
private final class Shared<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
  func update(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

/// Poll `condition` every 10 ms until it holds or `timeout` passes.
private func waitUntil(
  _ timeout: Duration = .seconds(5), _ condition: () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

/// `count` bytes of a pattern that differs by `count`, so datagrams of
/// different sizes can't be mistaken for one another.
private func pattern(_ count: Int) -> Data {
  Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ count) })
}

/// Which address of this host a test socket uses.
private enum TestHost: Sendable {
  /// `127.0.0.1` or `::1`.
  case loopback
  /// `0.0.0.0` or `::`.
  case wildcard
  /// `fe80::1%lo0`, the loopback interface's link-local address (IPv6 only).
  case linkLocal
}

/// A socket address for `family`, `host`, and `port`.
private func withAddress<T>(
  family: UDPAddressFamily, host: TestHost = .loopback, port: UInt16,
  _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
) -> T {
  switch family {
  case .ipv4:
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(
      s_addr: host == .wildcard ? INADDR_ANY : UInt32(0x7F00_0001).bigEndian)
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
  case .ipv6:
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_port = port.bigEndian
    switch host {
    case .loopback:
      address.sin6_addr.__u6_addr.__u6_addr8.15 = 1
    case .wildcard:
      break
    case .linkLocal:
      address.sin6_addr.__u6_addr.__u6_addr8.0 = 0xFE
      address.sin6_addr.__u6_addr.__u6_addr8.1 = 0x80
      address.sin6_addr.__u6_addr.__u6_addr8.15 = 1
      address.sin6_scope_id = if_nametoindex("lo0")
    }
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        body($0, socklen_t(MemoryLayout<sockaddr_in6>.size))
      }
    }
  }
}

/// Whether a UDP socket can bind `family`'s wildcard address on `port` now.
private func canBindWildcard(family: UDPAddressFamily, port: UInt16) -> Bool {
  let fd = socket(family == .ipv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
  guard fd >= 0 else { return false }
  defer { Darwin.close(fd) }
  return withAddress(family: family, host: .wildcard, port: port) { Darwin.bind(fd, $0, $1) == 0 }
}

/// A non-blocking UDP socket bound on loopback, standing in for a camera or a
/// stranger; it sends to the same address it is bound to. Its send buffer is
/// raised so it can send datagrams up to 64 KiB (macOS caps a datagram at the
/// send buffer, 9216 bytes by default).
private final class LoopbackUDPSocket: @unchecked Sendable {
  let family: UDPAddressFamily
  let host: TestHost
  let port: UInt16
  private let fd: Int32

  /// Bind `host` (loopback or link-local) on `port` (0 = ephemeral), or return
  /// `nil`.
  init?(family: UDPAddressFamily, host: TestHost = .loopback, port: UInt16 = 0) {
    let fd = socket(family == .ipv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return nil }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var sendBuffer: Int32 = 1 << 20
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
    var local = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let bound = withAddress(family: family, host: host, port: port) {
      Darwin.bind(fd, $0, $1) == 0
    }
    let named =
      bound
      && withUnsafeMutablePointer(to: &local) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) == 0 }
      }
    guard named else {
      Darwin.close(fd)
      return nil
    }
    self.fd = fd
    self.family = family
    self.host = host
    self.port = withUnsafeBytes(of: local) { raw in
      family == .ipv6
        ? UInt16(bigEndian: raw.load(as: sockaddr_in6.self).sin6_port)
        : UInt16(bigEndian: raw.load(as: sockaddr_in.self).sin_port)
    }
  }

  deinit { Darwin.close(fd) }

  /// Two sockets on consecutive loopback ports, like a camera's RTP/RTCP pair.
  static func consecutivePair(
    family: UDPAddressFamily, host: TestHost = .loopback
  ) -> (rtp: LoopbackUDPSocket, rtcp: LoopbackUDPSocket)? {
    for _ in 0..<64 {
      guard let rtp = LoopbackUDPSocket(family: family, host: host) else { return nil }
      if rtp.port < UInt16.max,
        let rtcp = LoopbackUDPSocket(family: family, host: host, port: rtp.port + 1)
      {
        return (rtp, rtcp)
      }
    }
    return nil
  }

  /// Send `data` as one datagram to `port` at this socket's own address.
  @discardableResult
  func send(_ data: Data, toPort port: UInt16) -> Bool {
    withAddress(family: family, host: host, port: port) { address, length in
      data.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, address, length) == $0.count }
    }
  }

  /// The next waiting datagram, or `nil` if none is waiting.
  func receive() -> Data? {
    var buffer = [UInt8](repeating: 0, count: 65_536)
    let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
    return count < 0 ? nil : Data(buffer[0..<count])
  }
}

@Suite("UDP datagrams")
struct UDPDatagramTests {
  static let families: [UDPAddressFamily] = [.ipv4, .ipv6]

  /// Network framework cut every datagram to 9216 bytes; the BSD sockets
  /// receive the largest UDP datagrams whole, in order on each socket.
  @Test(
    "Datagrams of 9300, 20000 and 60000 bytes arrive whole on both ports",
    .timeLimit(.minutes(1)), arguments: families)
  func largeDatagramsArriveWhole(family: UDPAddressFamily) async throws {
    let camera = try #require(LoopbackUDPSocket.consecutivePair(family: family))
    let pair = try await UDPPair.bind(family: family)
    defer { pair.close() }
    #expect(pair.rtpPort % 2 == 0)
    #expect(pair.rtcpPort == pair.rtpPort + 1)
    try await pair.connect(peerHost: family.loopback, peerRTPPort: camera.rtp.port)
    let received = Received()
    received.start(pair)

    let datagrams = [9300, 20_000, 60_000].map(pattern)
    for datagram in datagrams {
      #expect(camera.rtp.send(datagram, toPort: pair.rtpPort))
      #expect(camera.rtcp.send(datagram, toPort: pair.rtcpPort))
    }
    #expect(await waitUntil { received.rtp.count == 3 && received.rtcp.count == 3 })
    #expect(received.rtp.map(\.count) == [9300, 20_000, 60_000])
    #expect(received.rtp == datagrams)
    #expect(received.rtcp == datagrams)
    #expect(received.errors.isEmpty)
  }

  /// The sockets are connected to the camera's ports: a datagram from another
  /// port of the same host is dropped, whether it came before `connect()`
  /// (queued while the socket took any sender) or after.
  @Test(
    "A datagram from another port of the peer's host is not delivered",
    .timeLimit(.minutes(1)), arguments: families)
  func otherSourcePortIsDropped(family: UDPAddressFamily) async throws {
    let camera = try #require(LoopbackUDPSocket.consecutivePair(family: family))
    let stranger = try #require(LoopbackUDPSocket(family: family))
    let pair = try await UDPPair.bind(family: family)
    defer { pair.close() }

    #expect(stranger.send(Data("early rtp".utf8), toPort: pair.rtpPort))
    #expect(stranger.send(Data("early rtcp".utf8), toPort: pair.rtcpPort))
    // Let the early datagrams land in the socket buffers before connect().
    try await Task.sleep(for: .milliseconds(50))
    try await pair.connect(peerHost: family.loopback, peerRTPPort: camera.rtp.port)
    stranger.send(Data("late rtp".utf8), toPort: pair.rtpPort)
    stranger.send(Data("late rtcp".utf8), toPort: pair.rtcpPort)
    let received = Received()
    received.start(pair)

    #expect(camera.rtp.send(Data("rtp".utf8), toPort: pair.rtpPort))
    #expect(camera.rtcp.send(Data("rtcp".utf8), toPort: pair.rtcpPort))
    #expect(await waitUntil { !received.rtp.isEmpty && !received.rtcp.isEmpty })
    // Room for a stray datagram to show up.
    try await Task.sleep(for: .milliseconds(100))
    #expect(received.rtp == [Data("rtp".utf8)])
    #expect(received.rtcp == [Data("rtcp".utf8)])
    #expect(received.errors.isEmpty)
  }

  @Test(
    "close() stops delivery, can be called again, and frees both ports",
    .timeLimit(.minutes(1)), arguments: families)
  func closeStopsDelivery(family: UDPAddressFamily) async throws {
    let camera = try #require(LoopbackUDPSocket.consecutivePair(family: family))
    let pair = try await UDPPair.bind(family: family)
    try await pair.connect(peerHost: family.loopback, peerRTPPort: camera.rtp.port)
    let received = Received()
    received.start(pair)
    #expect(camera.rtp.send(Data("before".utf8), toPort: pair.rtpPort))
    #expect(await waitUntil { received.rtp.count == 1 })

    pair.close()
    pair.close()
    for _ in 0..<10 {
      camera.rtp.send(Data("after".utf8), toPort: pair.rtpPort)
      camera.rtcp.send(Data("after".utf8), toPort: pair.rtcpPort)
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(received.rtp == [Data("before".utf8)])
    #expect(received.rtcp.isEmpty)
    #expect(received.errors.isEmpty)
    await #expect(throws: RTSPError.self) { try await pair.sendRTP(Data([0x80])) }
    await #expect(throws: RTSPError.self) { try await pair.sendRTCP(Data([0x80])) }
    let (rtpPort, rtcpPort) = (pair.rtpPort, pair.rtcpPort)
    #expect(
      await waitUntil {
        canBindWildcard(family: family, port: rtpPort)
          && canBindWildcard(family: family, port: rtcpPort)
      })
  }

  /// A camera not listening on its RTCP port answers each receiver report
  /// with an ICMP port-unreachable, which the connected socket reports as
  /// `ECONNREFUSED` on its next send or receive. Neither fails: the next send
  /// goes out and the socket keeps receiving once the camera listens.
  @Test(
    "Sending and receiving continue after an ECONNREFUSED", .timeLimit(.minutes(1)),
    arguments: families)
  func connectionRefusedIsNotFatal(family: UDPAddressFamily) async throws {
    var camera = try #require(LoopbackUDPSocket.consecutivePair(family: family))
    let cameraRTCPPort = camera.rtcp.port
    // Free the camera's RTCP port: nothing listens there for now.
    camera.rtcp = try #require(LoopbackUDPSocket(family: family))
    let pair = try await UDPPair.bind(family: family)
    defer { pair.close() }
    try await pair.connect(peerHost: family.loopback, peerRTPPort: camera.rtp.port)

    let report = Data([0x80, 201, 0x00, 0x01, 0x12, 0x34, 0x56, 0x78])
    try await pair.sendRTCP(report)
    // macOS sends at most about one port-unreachable per 100 ms for a flow, so
    // the reports go 200 ms apart for each to draw one.
    try await Task.sleep(for: .milliseconds(200))
    // The pending error from the first report doesn't fail this one; this one
    // draws another, pending when receiving starts.
    try await pair.sendRTCP(report)
    try await Task.sleep(for: .milliseconds(200))
    let received = Received()
    received.start(pair)
    try await Task.sleep(for: .milliseconds(50))

    let lateRTCP = try #require(LoopbackUDPSocket(family: family, port: cameraRTCPPort))
    #expect(lateRTCP.send(Data("rtcp".utf8), toPort: pair.rtcpPort))
    #expect(camera.rtp.send(Data("rtp".utf8), toPort: pair.rtpPort))
    #expect(await waitUntil { !received.rtcp.isEmpty && !received.rtp.isEmpty })
    #expect(received.rtcp == [Data("rtcp".utf8)])
    #expect(received.rtp == [Data("rtp".utf8)])
    #expect(received.errors.isEmpty)

    try await pair.sendRTCP(report)
    var delivered: Data?
    #expect(
      await waitUntil {
        delivered = delivered ?? lateRTCP.receive()
        return delivered != nil
      })
    #expect(delivered == report)
  }

  /// The peer literals a session passes besides plain loopback: a link-local
  /// IPv6 address with a zone id (the interface becomes the scope id), and an
  /// IPv4-mapped address on the dual-stack IPv6 sockets.
  @Test(
    "A link-local peer with a zone id and an IPv4-mapped peer work both ways",
    .timeLimit(.minutes(1)), arguments: ["fe80::1%lo0", "::ffff:127.0.0.1"])
  func scopedAndMappedPeers(peerHost: String) async throws {
    let linkLocal = peerHost.hasPrefix("fe80")
    let camera = try #require(
      LoopbackUDPSocket.consecutivePair(
        family: linkLocal ? .ipv6 : .ipv4, host: linkLocal ? .linkLocal : .loopback))
    let pair = try await UDPPair.bind(family: .ipv6)
    defer { pair.close() }
    try await pair.connect(peerHost: peerHost, peerRTPPort: camera.rtp.port)
    let received = Received()
    received.start(pair)

    let datagram = pattern(20_000)
    #expect(camera.rtp.send(datagram, toPort: pair.rtpPort))
    #expect(camera.rtcp.send(datagram, toPort: pair.rtcpPort))
    #expect(await waitUntil { !received.rtp.isEmpty && !received.rtcp.isEmpty })
    #expect(received.rtp == [datagram])
    #expect(received.rtcp == [datagram])
    #expect(received.errors.isEmpty)

    try await pair.sendRTP(Data("rtp".utf8))
    try await pair.sendRTCP(Data("rtcp".utf8))
    var (rtp, rtcp): (Data?, Data?) = (nil, nil)
    #expect(
      await waitUntil {
        rtp = rtp ?? camera.rtp.receive()
        rtcp = rtcp ?? camera.rtcp.receive()
        return rtp != nil && rtcp != nil
      })
    #expect(rtp == Data("rtp".utf8))
    #expect(rtcp == Data("rtcp".utf8))
  }

  /// A whole UDP session: RTP packets of 9300 to 60000 bytes (single NAL unit
  /// packets) come through the session's sockets and depacketizer whole.
  @Test(
    "A UDP session decodes frames whose RTP packets exceed 9216 bytes",
    .timeLimit(.minutes(1)), arguments: [FakeRTSPServer.AddressFamily.ipv4, .ipv6])
  func sessionDeliversLargePackets(family: FakeRTSPServer.AddressFamily) async throws {
    func slice(_ start: Data, size: Int) -> Data {
      start + Data((start.count..<size).map { UInt8(truncatingIfNeeded: $0 % 251 + 1) })
    }
    let slices = [
      slice(h264TestIDRSlice, size: 20_000),
      slice(h264TestNonIDRSlice, size: 9300),
      slice(h264TestNonIDRSlice, size: 60_000),
    ]
    var configuration = FakeRTSPServer.Configuration(sdp: h264VideoOnlySDP())
    configuration.family = family
    let server = FakeRTSPServer(configuration: configuration)
    server.onPlay = { _, handle in
      guard let video = handle.setup(forStream: 0) else { return }
      var sequencer = RTPTestSequencer(parameters: video.parameters)
      for (index, slice) in slices.enumerated() {
        let nalus = index == 0 ? [h264TestSPS, h264TestPPS, slice] : [slice]
        for packet in sequencer.accessUnit(nalus, timestampIncrement: 3000) {
          handle.sendRTP(packet, stream: 0)
        }
      }
    }
    try await server.start()
    defer { server.stop() }

    let session = RTSPClientSession(url: server.url, transport: .udp)
    _ = try await session.start()
    let frames = Shared<[PublicVideoFrame]>([])
    let consumer = Task {
      for try await item in session.frames() {
        guard case .video(let frame) = item else { continue }
        frames.update { $0.append(frame) }
        if frames.value.count == slices.count { break }
      }
    }
    defer { consumer.cancel() }
    let complete = await waitUntil(.seconds(10)) { frames.value.count == slices.count }
    await session.stop()
    #expect(complete, "\(frames.value.count) of \(slices.count) frames arrived")
    let delivered = frames.value
    #expect(delivered.map { $0.nalus.last?.count } == slices.map(\.count))
    #expect(delivered.map { $0.nalus.last } == slices)
    #expect(delivered.first?.isKeyframe == true)
    #expect(delivered.allSatisfy { $0.loss == 0 })
  }
}
