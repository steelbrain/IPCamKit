// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Unit tests for MulticastPair, using datagrams this process sends over lo0.
//
// The delivery tests send to random groups in 239.255.0.0/16 (administratively
// scoped) and ff12::/16 (transient link-local) out of the loopback interface
// only, so nothing leaves the host and concurrent runs don't share a group. A raw-socket probe
// that does not use MulticastPair runs first and skips these tests, with a
// message, on a host where loopback multicast does not work.

import Darwin
import Foundation
import Testing

@testable import IPCamKit

// MARK: - Shared helpers (also used by LiveMulticastTests)

/// Thread-safe log of the datagrams a `MulticastPair` delivered.
final class DatagramLog: @unchecked Sendable {
  private let lock = NSLock()
  private var rtpDatagrams: [Data] = []
  private var rtcpDatagrams: [Data] = []
  private var errorMessages: [String] = []

  var rtp: [Data] { locked { rtpDatagrams } }
  var rtcp: [Data] { locked { rtcpDatagrams } }
  var errors: [String] { locked { errorMessages } }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  /// Start `pair` delivering into this log.
  func attach(to pair: MulticastPair) {
    pair.startReceiving(
      onRTP: { data in self.locked { self.rtpDatagrams.append(data) } },
      onRTCP: { data in self.locked { self.rtcpDatagrams.append(data) } },
      onError: { error in self.locked { self.errorMessages.append("\(error)") } })
  }

  /// Poll (never block) until `condition` holds or `timeout` elapses. Returns
  /// whether it held.
  @discardableResult
  func wait(
    timeout: Duration, until condition: (DatagramLog) -> Bool
  ) async -> Bool {
    let end = ContinuousClock.now + timeout
    while ContinuousClock.now < end {
      if condition(self) { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition(self)
  }
}

/// A random group, so concurrent runs don't share one: IPv4 in 239.255.0.0/16
/// (administratively scoped), IPv6 in ff12::/16 (transient link-local, without
/// a zone). IPv6 tests use link-local groups on lo0 because a host without
/// global IPv6 has no route for wider scopes (sending to ff15:: fails with
/// EHOSTUNREACH).
func randomMulticastGroup(ipv6: Bool) -> String {
  if ipv6 {
    return "ff12::\(String(UInt16.random(in: 1...0xFFFE), radix: 16)):"
      + String(UInt16.random(in: 1...0xFFFE), radix: 16)
  }
  return "239.255.\(Int.random(in: 1...254)).\(Int.random(in: 1...254))"
}

/// A random even port with its odd successor. Receivers share ports
/// (`SO_REUSEPORT`) and bind the group address, so a random group makes a
/// collision with another test harmless.
func randomPortPair() -> (rtp: UInt16, rtcp: UInt16) {
  let rtp = UInt16.random(in: 20_000...30_000) * 2
  return (rtp, rtp + 1)
}

/// Sends multicast datagrams out of lo0 with plain BSD sockets, independent of
/// the code under test.
final class LoopbackMulticastSender {
  private let fd: Int32
  private let ipv6: Bool

  init?(ipv6: Bool) {
    // Stored properties are assigned last, so a failure here never runs deinit
    // (which would close the descriptor a second time).
    let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return nil }
    let configured: Bool
    if ipv6 {
      var index = if_nametoindex("lo0")
      var loop: UInt32 = 1
      configured =
        setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, &index, socklen_t(4)) == 0
        && setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_LOOP, &loop, socklen_t(4)) == 0
    } else {
      var interface = in_addr(s_addr: inet_addr("127.0.0.1"))
      var loop: UInt8 = 1
      configured =
        setsockopt(
          fd, IPPROTO_IP, IP_MULTICAST_IF, &interface, socklen_t(MemoryLayout<in_addr>.size))
        == 0 && setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(1)) == 0
    }
    // macOS caps a UDP datagram at the send buffer size, 9216 bytes by
    // default (net.inet.udp.maxdgram); 1 MiB lets a test send any size.
    var sendBuffer: Int32 = 1 << 20
    guard configured,
      setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size)) == 0
    else {
      close(fd)
      return nil
    }
    self.fd = fd
    self.ipv6 = ipv6
  }

  deinit { close(fd) }

  /// Send `data` to `group` (a literal; an IPv6 group may end in `%lo0`) on
  /// `port`. Returns whether the whole datagram was sent.
  @discardableResult
  func send(_ data: Data, to group: String, port: UInt16) -> Bool {
    var storage = sockaddr_storage()
    let parts = group.split(separator: "%", maxSplits: 1).map(String.init)
    let ok = withUnsafeMutableBytes(of: &storage) { raw -> Bool in
      if ipv6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_scope_id = parts.count == 2 ? if_nametoindex(parts[1]) : 0
        guard inet_pton(AF_INET6, parts[0], &address.sin6_addr) == 1 else { return false }
        withUnsafeBytes(of: address) { raw.copyMemory(from: $0) }
      } else {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, parts[0], &address.sin_addr) == 1 else { return false }
        withUnsafeBytes(of: address) { raw.copyMemory(from: $0) }
      }
      return true
    }
    guard ok else { return false }
    let sent = data.withUnsafeBytes { bytes in
      withUnsafePointer(to: &storage) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t($0.pointee.sa_len))
        }
      }
    }
    return sent == data.count
  }
}

/// Whether this host delivers multicast sent out of lo0 back to a socket that
/// joined the group on lo0. Probed once per family with plain BSD sockets, so a
/// broken `MulticastPair` fails its tests instead of skipping them.
enum LoopbackMulticast {
  static let ipv4 = Task<Bool, Never> { await probe(ipv6: false) }
  static let ipv6 = Task<Bool, Never> { await probe(ipv6: true) }

  /// Whether the kernel has a route to pick an interface for an IPv4 group (an
  /// `INADDR_ANY` join succeeds), i.e. whether `interface: nil` can work at all.
  static func hasIPv4MulticastRoute() -> Bool {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var request = ip_mreq()
    request.imr_multiaddr = in_addr(s_addr: inet_addr(randomMulticastGroup(ipv6: false)))
    request.imr_interface = in_addr(s_addr: INADDR_ANY)
    return setsockopt(
      fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request, socklen_t(MemoryLayout<ip_mreq>.size)) == 0
  }

  /// Runs the blocking probe on its own queue, off the cooperative pool.
  private static func probe(ipv6: Bool) async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue(label: "ipcamkit.test.multicast-probe").async {
        continuation.resume(returning: probeSync(ipv6: ipv6))
      }
    }
  }

  private static func probeSync(ipv6: Bool) -> Bool {
    let group = randomMulticastGroup(ipv6: ipv6)
    let port = randomPortPair().rtp
    let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(4))
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(4))

    var storage = sockaddr_storage()
    let joined = withUnsafeMutableBytes(of: &storage) { raw -> Bool in
      if ipv6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_scope_id = if_nametoindex("lo0")
        var request = ipv6_mreq()
        guard inet_pton(AF_INET6, group, &address.sin6_addr) == 1,
          inet_pton(AF_INET6, group, &request.ipv6mr_multiaddr) == 1
        else { return false }
        request.ipv6mr_interface = if_nametoindex("lo0")
        withUnsafeBytes(of: address) { raw.copyMemory(from: $0) }
        return setsockopt(
          fd, IPPROTO_IPV6, IPV6_JOIN_GROUP, &request, socklen_t(MemoryLayout<ipv6_mreq>.size))
          == 0
      }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      address.sin_addr = in_addr(s_addr: inet_addr(group))
      var request = ip_mreq()
      request.imr_multiaddr = address.sin_addr
      request.imr_interface = in_addr(s_addr: inet_addr("127.0.0.1"))
      withUnsafeBytes(of: address) { raw.copyMemory(from: $0) }
      return setsockopt(
        fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request, socklen_t(MemoryLayout<ip_mreq>.size)) == 0
    }
    let bound = withUnsafePointer(to: &storage) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t($0.pointee.sa_len)) == 0
      }
    }
    guard joined, bound, let sender = LoopbackMulticastSender(ipv6: ipv6) else { return false }
    // UDP may drop a datagram, so retry a few times before declaring the host
    // unable to deliver loopback multicast.
    for _ in 0..<5 {
      sender.send(Data("probe".utf8), to: ipv6 ? "\(group)%lo0" : group, port: port)
      var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      if poll(&pollFD, 1, 400) == 1 { return true }
    }
    return false
  }
}

extension Trait where Self == ConditionTrait {
  /// Skip unless lo0 delivers IPv4 multicast on this host.
  static var loopbackIPv4Multicast: Self {
    .enabled("this host does not deliver IPv4 multicast over lo0 (raw-socket probe failed)") {
      await LoopbackMulticast.ipv4.value
    }
  }

  /// Skip unless lo0 delivers IPv6 multicast on this host.
  static var loopbackIPv6Multicast: Self {
    .enabled("this host does not deliver IPv6 multicast over lo0 (raw-socket probe failed)") {
      await LoopbackMulticast.ipv6.value
    }
  }
}

// MARK: - Local helpers

/// A minimal RTP datagram (version 2, PT 96) carrying `sequence`.
private func rtpDatagram(sequence: UInt16) -> Data {
  Data([0x80, 96, UInt8(sequence >> 8), UInt8(sequence & 0xFF)])
    + Data([0, 0, 0, 1, 0xAB, 0xCD, 0xEF, 0x01, 0x42])
}

/// A minimal RTCP datagram (version 2, PT 200) tagged with `tag`.
private func rtcpDatagram(tag: UInt8) -> Data {
  Data([0x80, 200, 0, 6]) + Data(repeating: tag, count: 24)
}

/// Expect `join` to throw `RTSPError.connectionFailed` whose message contains
/// `fragment`.
private func expectJoinFailure(
  _ fragment: String, sourceLocation: SourceLocation = #_sourceLocation,
  _ join: () async throws -> MulticastPair
) async {
  do {
    let pair = try await join()
    pair.close()
    Issue.record("join should have thrown", sourceLocation: sourceLocation)
  } catch RTSPError.connectionFailed(let message, _) {
    #expect(message.contains(fragment), "got: \(message)", sourceLocation: sourceLocation)
  } catch {
    Issue.record("expected connectionFailed, got \(error)", sourceLocation: sourceLocation)
  }
}

// MARK: - Tests

@Suite("Multicast Transport")
struct MulticastTests {

  // MARK: Argument validation (no network needed)

  @Test(
    "Invalid group strings throw",
    arguments: [
      "", "  ", "not-an-ip", "example.com", "192.168.1.10", "127.0.0.1", "239.1.1",
      "239.1.1.1.1", "300.1.1.1", "::1", "fe80::1", "ff02::1%nosuchif0", "[239.1.1.1",
    ])
  func invalidGroupThrows(group: String) async {
    await expectJoinFailure("Invalid multicast group address") {
      try await MulticastPair.join(group: group, rtpPort: 40_000, rtcpPort: 40_001, source: nil)
    }
  }

  @Test("Invalid ports, sources and interfaces throw")
  func invalidArgumentsThrow() async {
    await expectJoinFailure("Invalid multicast ports") {
      try await MulticastPair.join(group: "239.255.1.1", rtpPort: 0, rtcpPort: 1, source: nil)
    }
    await expectJoinFailure("Invalid multicast ports") {
      try await MulticastPair.join(
        group: "239.255.1.1", rtpPort: 40_000, rtcpPort: 40_000, source: nil)
    }
    for source in ["::1", "239.255.0.9", "camera.local", ""] {
      await expectJoinFailure("Invalid multicast source address") {
        try await MulticastPair.join(
          group: "239.255.1.1", rtpPort: 40_000, rtcpPort: 40_001, source: source)
      }
    }
    await expectJoinFailure("Invalid multicast source address") {
      try await MulticastPair.join(
        group: "ff15::1", rtpPort: 40_000, rtcpPort: 40_001, source: "127.0.0.1")
    }
    for interface in ["nosuchif0", "203.0.113.77", "2001:db8::77"] {
      await expectJoinFailure("Unknown multicast interface") {
        try await MulticastPair.join(
          group: "239.255.1.1", rtpPort: 40_000, rtcpPort: 40_001, source: nil,
          interface: interface)
      }
    }
  }

  // MARK: Delivery over lo0

  @Test(
    "IPv4 RTP and RTCP datagrams reach their callbacks", .loopbackIPv4Multicast,
    arguments: ["lo0", "127.0.0.1", " [127.0.0.1] "])
  func ipv4Delivery(interface: String) async throws {
    let group = randomMulticastGroup(ipv6: false)
    let ports = randomPortPair()
    let pair = try await MulticastPair.join(
      group: " [\(group)] ", rtpPort: ports.rtp, rtcpPort: ports.rtcp, source: nil,
      interface: interface)
    defer { pair.close() }
    #expect(pair.group == group)
    #expect(pair.rtpPort == ports.rtp && pair.rtcpPort == ports.rtcp)
    #expect(!pair.isSourceSpecific)
    let log = DatagramLog()
    log.attach(to: pair)

    let sender = try #require(LoopbackMulticastSender(ipv6: false))
    // An empty datagram first: it must be dropped, not delivered.
    #expect(sender.send(Data(), to: group, port: ports.rtp))
    for sequence in UInt16(1)...5 {
      #expect(sender.send(rtpDatagram(sequence: sequence), to: group, port: ports.rtp))
    }
    for tag in UInt8(1)...3 {
      #expect(sender.send(rtcpDatagram(tag: tag), to: group, port: ports.rtcp))
    }

    await log.wait(timeout: .seconds(3)) { $0.rtp.count >= 5 && $0.rtcp.count >= 3 }
    #expect(log.rtp == (UInt16(1)...5).map(rtpDatagram(sequence:)))
    #expect(log.rtcp == (UInt8(1)...3).map(rtcpDatagram(tag:)))
    #expect(log.errors.isEmpty)
  }

  @Test(
    "Multicast datagrams larger than 9216 bytes arrive whole", .loopbackIPv4Multicast,
    .timeLimit(.minutes(1)))
  func largeDatagrams() async throws {
    let group = randomMulticastGroup(ipv6: false)
    let ports = randomPortPair()
    let pair = try await MulticastPair.join(
      group: group, rtpPort: ports.rtp, rtcpPort: ports.rtcp, source: nil, interface: "lo0")
    defer { pair.close() }
    let log = DatagramLog()
    log.attach(to: pair)
    let sender = try #require(LoopbackMulticastSender(ipv6: false))
    let sizes = [9300, 20_000, 60_000]
    let datagrams = sizes.enumerated().map { index, size in
      rtpDatagram(sequence: UInt16(index + 1)) + Data((0..<size - 13).map { UInt8($0 & 0xFF) })
    }
    // UDP may drop a datagram: resend until each has arrived.
    for _ in 0..<5 {
      for datagram in datagrams where !log.rtp.contains(datagram) {
        #expect(sender.send(datagram, to: group, port: ports.rtp))
      }
      await log.wait(timeout: .seconds(1)) { log in datagrams.allSatisfy(log.rtp.contains) }
      if datagrams.allSatisfy(log.rtp.contains) { break }
    }
    #expect(Set(log.rtp.map(\.count)) == Set(sizes))
    #expect(datagrams.allSatisfy(log.rtp.contains), "every byte arrives")
    #expect(log.errors.isEmpty)
  }

  @Test(
    "Two pairs share one group and port; close() stops only its own delivery",
    .loopbackIPv4Multicast)
  func twoPairsShareGroupAndClose() async throws {
    let group = randomMulticastGroup(ipv6: false)
    let ports = randomPortPair()
    let first = try await MulticastPair.join(
      group: group, rtpPort: ports.rtp, rtcpPort: ports.rtcp, source: nil, interface: "lo0")
    let second = try await MulticastPair.join(
      group: group, rtpPort: ports.rtp, rtcpPort: ports.rtcp, source: nil, interface: "lo0")
    defer {
      first.close()
      second.close()
    }
    let firstLog = DatagramLog()
    let secondLog = DatagramLog()
    firstLog.attach(to: first)
    secondLog.attach(to: second)
    // A second startReceiving is a no-op: the first callbacks stay attached.
    let ignored = DatagramLog()
    ignored.attach(to: first)

    let sender = try #require(LoopbackMulticastSender(ipv6: false))
    for sequence in UInt16(1)...4 {
      sender.send(rtpDatagram(sequence: sequence), to: group, port: ports.rtp)
    }
    sender.send(rtcpDatagram(tag: 9), to: group, port: ports.rtcp)
    for log in [firstLog, secondLog] {
      await log.wait(timeout: .seconds(3)) { $0.rtp.count >= 4 && $0.rtcp.count >= 1 }
      #expect(log.rtp.count == 4)
      #expect(log.rtcp == [rtcpDatagram(tag: 9)])
    }
    #expect(ignored.rtp.isEmpty)

    first.close()
    first.close()  // idempotent
    first.startReceiving(onRTP: { _ in }, onRTCP: { _ in })  // no-op after close
    for sequence in UInt16(5)...8 {
      sender.send(rtpDatagram(sequence: sequence), to: group, port: ports.rtp)
    }
    await secondLog.wait(timeout: .seconds(3)) { $0.rtp.count >= 8 }
    #expect(secondLog.rtp.count == 8)
    try await Task.sleep(for: .milliseconds(200))
    #expect(firstLog.rtp.count == 4, "a closed pair must not deliver")
  }

  @Test("A pair only receives its own group on a shared port", .loopbackIPv4Multicast)
  func groupIsolation() async throws {
    let groupA = randomMulticastGroup(ipv6: false)
    var groupB = randomMulticastGroup(ipv6: false)
    while groupB == groupA { groupB = randomMulticastGroup(ipv6: false) }
    let ports = randomPortPair()
    let pairA = try await MulticastPair.join(
      group: groupA, rtpPort: ports.rtp, rtcpPort: ports.rtcp, source: nil, interface: "lo0")
    let pairB = try await MulticastPair.join(
      group: groupB, rtpPort: ports.rtp, rtcpPort: ports.rtcp, source: nil, interface: "lo0")
    defer {
      pairA.close()
      pairB.close()
    }
    let logA = DatagramLog()
    let logB = DatagramLog()
    logA.attach(to: pairA)
    logB.attach(to: pairB)

    let sender = try #require(LoopbackMulticastSender(ipv6: false))
    sender.send(rtpDatagram(sequence: 1), to: groupB, port: ports.rtp)
    sender.send(rtpDatagram(sequence: 2), to: groupA, port: ports.rtp)
    await logA.wait(timeout: .seconds(3)) { !$0.rtp.isEmpty }
    await logB.wait(timeout: .seconds(3)) { !$0.rtp.isEmpty }
    try await Task.sleep(for: .milliseconds(100))
    #expect(logA.rtp == [rtpDatagram(sequence: 2)])
    #expect(logB.rtp == [rtpDatagram(sequence: 1)])
  }

  @Test(
    "A source-specific pair receives its source and drops other senders",
    .loopbackIPv4Multicast)
  func ipv4SourceSpecific() async throws {
    let group = randomMulticastGroup(ipv6: false)
    let ports = randomPortPair()
    // The sender's datagrams come from 127.0.0.1; 192.0.2.1 (TEST-NET-1) never sends.
    let matching = try await MulticastPair.join(
      group: group, rtpPort: ports.rtp, rtcpPort: ports.rtcp, source: "127.0.0.1",
      interface: "lo0")
    let other = try await MulticastPair.join(
      group: group, rtpPort: ports.rtp, rtcpPort: ports.rtcp, source: "192.0.2.1",
      interface: "lo0")
    defer {
      matching.close()
      other.close()
    }
    #expect(matching.isSourceSpecific, "macOS supports IPv4 source-specific joins")
    let matchingLog = DatagramLog()
    let otherLog = DatagramLog()
    matchingLog.attach(to: matching)
    otherLog.attach(to: other)

    let sender = try #require(LoopbackMulticastSender(ipv6: false))
    for sequence in UInt16(1)...3 {
      sender.send(rtpDatagram(sequence: sequence), to: group, port: ports.rtp)
    }
    await matchingLog.wait(timeout: .seconds(3)) { $0.rtp.count >= 3 }
    #expect(matchingLog.rtp.count == 3)
    try await Task.sleep(for: .milliseconds(200))
    #expect(otherLog.rtp.isEmpty, "datagrams from a different source must be dropped")
  }

  @Test(
    "IPv6 delivery by interface name, by group zone, and source-specific",
    .loopbackIPv6Multicast)
  func ipv6Delivery() async throws {
    let group = randomMulticastGroup(ipv6: true)
    let zoned = "\(group)%lo0"
    let ports = randomPortPair()
    let byName = try await MulticastPair.join(
      group: group, rtpPort: ports.rtp, rtcpPort: ports.rtcp, source: nil, interface: "lo0")
    // The zone selects lo0; no `interface` argument.
    let byZone = try await MulticastPair.join(
      group: "[\(zoned)]", rtpPort: ports.rtp, rtcpPort: ports.rtcp, source: nil)
    // Datagrams sent out of lo0 to a link-local group come from fe80::1%lo0.
    let sourced = try await MulticastPair.join(
      group: group, rtpPort: ports.rtp, rtcpPort: ports.rtcp, source: "fe80::1%lo0",
      interface: "::1")
    let otherSource = try await MulticastPair.join(
      group: group, rtpPort: ports.rtp, rtcpPort: ports.rtcp, source: "fe80::99%lo0",
      interface: "lo0")
    let pairs = [byName, byZone, sourced, otherSource]
    defer {
      for pair in pairs { pair.close() }
    }
    #expect(byZone.group == zoned)
    #expect(sourced.isSourceSpecific, "macOS supports IPv6 source-specific joins")
    let logs = pairs.map { _ in DatagramLog() }
    for (pair, log) in zip(pairs, logs) { log.attach(to: pair) }

    let sender = try #require(LoopbackMulticastSender(ipv6: true))
    // Sent again until the three pairs have both: a machine busy with other
    // tests can drop a loopback multicast datagram.
    for _ in 0..<6 {
      sender.send(rtpDatagram(sequence: 1), to: zoned, port: ports.rtp)
      sender.send(rtcpDatagram(tag: 1), to: zoned, port: ports.rtcp)
      var received = true
      for log in logs.prefix(3) {
        await log.wait(timeout: .milliseconds(500)) { !$0.rtp.isEmpty && !$0.rtcp.isEmpty }
        received = received && !log.rtp.isEmpty && !log.rtcp.isEmpty
      }
      if received { break }
    }
    for log in logs.prefix(3) {
      #expect(!log.rtp.isEmpty && log.rtp.allSatisfy { $0 == rtpDatagram(sequence: 1) })
      #expect(!log.rtcp.isEmpty && log.rtcp.allSatisfy { $0 == rtcpDatagram(tag: 1) })
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(logs[3].rtp.isEmpty && logs[3].rtcp.isEmpty, "other senders must be dropped")
  }

  @Test("close() before startReceiving releases the sockets", .loopbackIPv4Multicast)
  func closeBeforeReceiving() async throws {
    let group = randomMulticastGroup(ipv6: false)
    let ports = randomPortPair()
    let pair = try await MulticastPair.join(
      group: group, rtpPort: ports.rtp, rtcpPort: ports.rtcp, source: nil, interface: "lo0")
    pair.close()
    pair.close()
    let log = DatagramLog()
    log.attach(to: pair)  // no-op after close
    let sender = try #require(LoopbackMulticastSender(ipv6: false))
    sender.send(rtpDatagram(sequence: 1), to: group, port: ports.rtp)
    try await Task.sleep(for: .milliseconds(200))
    #expect(log.rtp.isEmpty)
  }
}
