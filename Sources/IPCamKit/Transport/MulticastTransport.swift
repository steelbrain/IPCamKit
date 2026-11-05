// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Multicast RTP/RTCP receiver for RTSP-initiated multicast (`RTP/AVP;multicast`).

import Darwin
import Foundation

/// Receives one RTP stream's RTP and RTCP datagrams from an IP multicast group,
/// as negotiated by a SETUP with `Transport: RTP/AVP;multicast` (the server's
/// reply names the group and ports: `destination=G;port=P-Q`). The receiving
/// counterpart of `UDPPair` for multicast: the same `startReceiving` / `close`
/// shape, callbacks on a private serial queue, and lock discipline.
///
/// ## Why BSD sockets, not Network framework
///
/// The TCP and TLS connections use Network framework, but `NWConnectionGroup` (with
/// `NWMulticastGroup`) cannot share its port. With `allowLocalEndpointReuse`
/// set, it still fails with `EADDRINUSE` when any other socket holds the port,
/// and that includes a second `NWConnectionGroup` for the same group and port.
/// That rules out two receivers of one camera on one machine (two sessions, or
/// two apps) and a camera server on the same host (it holds the port to send).
/// So this type uses two BSD UDP sockets with `SO_REUSEADDR` + `SO_REUSEPORT`,
/// joined with the RFC 3678 socket options, read by `DispatchSource` read
/// sources on a private serial queue. Every syscall here is non-blocking.
///
/// Each socket is bound to the group address itself (not the wildcard), so it
/// receives only datagrams sent to this group. Unicast traffic to the same port
/// and other groups that share the port go to other sockets.
///
/// ## Interface selection
///
/// A host receives a multicast datagram only on the interfaces where a socket
/// joined the group. `nil` lets the kernel pick the interface of its route for
/// the group (normally the primary interface). That interface can be wrong for
/// a multi-homed host, a VPN that claims `224.0.0.0/4`, or a server on the same
/// host. The reliable choice is the local address of the RTSP control connection,
/// which is on the interface that reaches the camera. For example, mediamtx sends
/// each datagram once per multicast-capable interface. With the server on the
/// same Mac, a join on `127.0.0.1` (lo0) receives the copy sent from `127.0.0.1`,
/// and a `nil` join receives the copy the kernel loops back from the primary
/// interface (en0).
///
/// ## Platform requirements
///
/// On iOS, tvOS, and visionOS, an app must have the
/// `com.apple.developer.networking.multicast` entitlement to receive multicast,
/// whether through BSD sockets or Network framework. Local Network privacy also
/// applies (iOS 14+, macOS 15+): the app needs `NSLocalNetworkUsageDescription`
/// in its Info.plist, and the user must allow access.
///
/// `@unchecked Sendable`: `group`, `rtpPort`, `rtcpPort`, `isSourceSpecific`,
/// `sourceFilter`, `queue`, and `buffer` are immutable after `join()`. All other
/// mutable state (`rtpFD`, `rtcpFD`, `rtpSource`, `rtcpSource`, `receiving`,
/// `closed`) is guarded by `lock`. Read-source handlers run on the serial
/// `queue`, the only user of `buffer`.
final class MulticastPair: @unchecked Sendable {
  /// The joined group, normalized (brackets and surrounding whitespace removed).
  let group: String
  /// The port receiving RTP datagrams.
  let rtpPort: UInt16
  /// The port receiving RTCP datagrams.
  let rtcpPort: UInt16
  /// Whether the kernel joined the source-specific group (IGMPv3/MLDv2). `false`
  /// for any-source joins. That includes a `source` the platform could not join
  /// source-specifically, in which case datagrams from other senders are dropped
  /// here instead.
  let isSourceSpecific: Bool

  /// Datagrams from any other sender are dropped. `nil` accepts every sender.
  private let sourceFilter: IPLiteral?
  /// Private serial queue for both read sources and every callback. It is never
  /// a Swift Concurrency cooperative thread.
  private let queue: DispatchQueue
  /// Receive buffer shared by both read sources (they run serially on `queue`).
  private let buffer: UnsafeMutableRawBufferPointer

  private let lock = NSLock()
  /// The sockets. Owned here until `startReceiving` hands each one to its read
  /// source (whose cancel handler closes it); `-1` after that or after `close()`.
  private var rtpFD: Int32
  private var rtcpFD: Int32
  private var rtpSource: DispatchSourceRead?
  private var rtcpSource: DispatchSourceRead?
  private var receiving = false
  private var closed = false

  /// Large enough for any UDP datagram.
  private static let maxDatagramBytes = 65_536
  /// Datagrams read per read-source wakeup before yielding the queue, so a busy
  /// RTP socket cannot starve the RTCP socket. Any remainder fires the source again.
  private static let maxDatagramsPerWakeup = 64

  private init(
    group: String, rtpPort: UInt16, rtcpPort: UInt16, rtpFD: Int32, rtcpFD: Int32,
    isSourceSpecific: Bool, sourceFilter: IPLiteral?
  ) {
    self.group = group
    self.rtpPort = rtpPort
    self.rtcpPort = rtcpPort
    self.rtpFD = rtpFD
    self.rtcpFD = rtcpFD
    self.isSourceSpecific = isSourceSpecific
    self.sourceFilter = sourceFilter
    self.queue = DispatchQueue(label: "ipcamkit.multicast.\(group).\(rtpPort)")
    self.buffer = UnsafeMutableRawBufferPointer.allocate(
      byteCount: Self.maxDatagramBytes, alignment: 16)
  }

  deinit {
    close()
    buffer.deallocate()
  }

  // MARK: - Joining

  /// Join `group` on `rtpPort` (RTP) and `rtcpPort` (RTCP, usually `rtpPort + 1`).
  /// Delivery begins with `startReceiving`. Any number of receivers, in this
  /// process or others, can join the same group and ports at once.
  ///
  /// - Parameters:
  ///   - group: An IPv4 (`224.0.0.0/4`) or IPv6 (`ff00::/8`) multicast literal,
  ///     optionally bracketed. An IPv6 zone (`ff02::1%en0`) selects the interface
  ///     when `interface` is `nil`.
  ///   - source: The sender's address literal, in the group's family, or `nil`
  ///     for any sender. The kernel then joins the source-specific group when the
  ///     platform allows it. Otherwise this joins any-source and drops datagrams
  ///     from other senders (see `isSourceSpecific`).
  ///   - interface: An interface name (`en0`) or one of this host's addresses (the
  ///     RTSP control connection's local address is the reliable choice), or
  ///     `nil` for the interface of the kernel's route to the group.
  /// - Throws: `RTSPError.connectionFailed` naming the bad argument or failed call
  ///   (invalid group, port, source, or interface; socket, bind, or join failure).
  static func join(
    group: String, rtpPort: UInt16, rtcpPort: UInt16, source: String?,
    interface: String? = nil
  ) async throws -> MulticastPair {
    let groupText = IPLiteral.normalize(group)
    guard let groupAddress = IPLiteral(groupText), groupAddress.isMulticast else {
      throw RTSPError.connectionFailed(
        "Invalid multicast group address '\(cutForMessage(group))': expected an IPv4 (224.0.0.0/4) or "
          + "IPv6 (ff00::/8) multicast literal")
    }
    guard rtpPort != 0, rtcpPort != 0, rtpPort != rtcpPort else {
      throw RTSPError.connectionFailed(
        "Invalid multicast ports \(rtpPort)-\(rtcpPort): need two distinct nonzero ports")
    }
    var sourceAddress: IPLiteral?
    if let source {
      guard let parsed = IPLiteral(IPLiteral.normalize(source)),
        parsed.isIPv6 == groupAddress.isIPv6, !parsed.isMulticast
      else {
        throw RTSPError.connectionFailed(
          "Invalid multicast source address '\(cutForMessage(source))': expected a unicast "
            + "\(groupAddress.isIPv6 ? "IPv6" : "IPv4") literal, like the group '\(cutForMessage(group))'"
        )
      }
      sourceAddress = parsed
    }
    let interfaceIndex = try interface.map(resolveInterface) ?? groupAddress.zone

    let rtp = try openSocket(
      group: groupAddress, port: rtpPort, source: sourceAddress, interfaceIndex: interfaceIndex)
    let rtcp: (fd: Int32, isSourceSpecific: Bool)
    do {
      rtcp = try openSocket(
        group: groupAddress, port: rtcpPort, source: sourceAddress,
        interfaceIndex: interfaceIndex)
    } catch {
      Darwin.close(rtp.fd)
      throw error
    }
    return MulticastPair(
      group: groupText, rtpPort: rtpPort, rtcpPort: rtcpPort, rtpFD: rtp.fd, rtcpFD: rtcp.fd,
      isSourceSpecific: rtp.isSourceSpecific && rtcp.isSourceSpecific,
      sourceFilter: sourceAddress)
  }

  /// Open a non-blocking UDP socket bound to `group`:`port` with port reuse, and
  /// join it to the group. Closes the socket and throws on any failure.
  private static func openSocket(
    group: IPLiteral, port: UInt16, source: IPLiteral?, interfaceIndex: UInt32
  ) throws -> (fd: Int32, isSourceSpecific: Bool) {
    let context = "Multicast join of \(cutForMessage(group.text)) port \(port)"
    let fd = socket(group.isIPv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else {
      throw RTSPError.connectionFailed("\(context) failed: socket: \(describeErrno(errno))")
    }
    do {
      func check(_ result: Int32, _ call: String) throws {
        guard result == 0 else {
          throw RTSPError.connectionFailed("\(context) failed: \(call): \(describeErrno(result))")
        }
      }
      try check(setOption(fd, SOL_SOCKET, SO_REUSEADDR, Int32(1)), "SO_REUSEADDR")
      try check(setOption(fd, SOL_SOCKET, SO_REUSEPORT, Int32(1)), "SO_REUSEPORT")
      if group.isIPv6 {
        try check(setOption(fd, IPPROTO_IPV6, IPV6_V6ONLY, Int32(1)), "IPV6_V6ONLY")
      }
      let flags = fcntl(fd, F_GETFL)
      try check(flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 ? 0 : errno, "O_NONBLOCK")
      try check(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 ? 0 : errno, "FD_CLOEXEC")

      // A link- or interface-local group is bound with its zone.
      var bindAddress = group.socketAddress(port: port, interfaceIndex: interfaceIndex)
      let bound = withUnsafePointer(to: &bindAddress) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(fd, $0, socklen_t($0.pointee.sa_len))
        }
      }
      try check(bound == 0 ? 0 : errno, "bind")

      if let source {
        // Source-specific when the platform supports it; otherwise fall through
        // to an any-source join (the receive path drops other senders).
        if joinSourceSpecific(fd, group: group, source: source, interfaceIndex: interfaceIndex)
          == 0
        {
          return (fd, true)
        }
      }
      try check(joinAnySource(fd, group: group, interfaceIndex: interfaceIndex), "join")
      return (fd, false)
    } catch {
      Darwin.close(fd)
      throw error
    }
  }

  /// Join any-source. Returns 0 or an errno. IPv4 without an interface uses
  /// `IP_ADD_MEMBERSHIP` with `INADDR_ANY` (the kernel routes the group): the
  /// protocol-independent `MCAST_JOIN_GROUP` requires an interface index for IPv4.
  private static func joinAnySource(
    _ fd: Int32, group: IPLiteral, interfaceIndex: UInt32
  ) -> Int32 {
    if group.isIPv6 {
      var request = ipv6_mreq()
      request.ipv6mr_multiaddr = group.in6Address
      request.ipv6mr_interface = interfaceIndex
      return setOption(fd, IPPROTO_IPV6, IPV6_JOIN_GROUP, request)
    }
    if interfaceIndex == 0 {
      var request = ip_mreq()
      request.imr_multiaddr = group.inAddress
      request.imr_interface = in_addr(s_addr: INADDR_ANY)
      return setOption(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, request)
    }
    var request = group_req()
    request.gr_interface = interfaceIndex
    request.gr_group = group.socketAddress(port: 0, interfaceIndex: interfaceIndex)
    return setOption(fd, IPPROTO_IP, MCAST_JOIN_GROUP, request)
  }

  /// Join the source-specific group (S,G). Returns 0 or an errno. IPv4 without an
  /// interface uses `IP_ADD_SOURCE_MEMBERSHIP` (the kernel routes the group).
  /// IPv6 has no route-selected form, so without an interface this fails and the
  /// caller falls back to any-source.
  private static func joinSourceSpecific(
    _ fd: Int32, group: IPLiteral, source: IPLiteral, interfaceIndex: UInt32
  ) -> Int32 {
    if !group.isIPv6 && interfaceIndex == 0 {
      var request = ip_mreq_source()
      request.imr_multiaddr = group.inAddress
      request.imr_sourceaddr = source.inAddress
      request.imr_interface = in_addr(s_addr: INADDR_ANY)
      return setOption(fd, IPPROTO_IP, IP_ADD_SOURCE_MEMBERSHIP, request)
    }
    var request = group_source_req()
    request.gsr_interface = interfaceIndex
    request.gsr_group = group.socketAddress(port: 0, interfaceIndex: interfaceIndex)
    request.gsr_source = source.socketAddress(port: 0, interfaceIndex: interfaceIndex)
    return setOption(
      fd, group.isIPv6 ? IPPROTO_IPV6 : IPPROTO_IP, MCAST_JOIN_SOURCE_GROUP, request)
  }

  /// Resolve an interface name (`en0`) or a local address to an interface index.
  private static func resolveInterface(_ spec: String) throws -> UInt32 {
    let text = IPLiteral.normalize(spec)
    let byName = if_nametoindex(text)
    if byName != 0 { return byName }
    if let address = IPLiteral(text) {
      if address.zone != 0 { return address.zone }
      var list: UnsafeMutablePointer<ifaddrs>?
      if getifaddrs(&list) == 0, let first = list {
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
          guard let addr = entry.pointee.ifa_addr, address.matches(addr) else { continue }
          let index = if_nametoindex(entry.pointee.ifa_name)
          if index != 0 { return index }
        }
      }
    }
    throw RTSPError.connectionFailed(
      "Unknown multicast interface '\(spec)': not an interface name or an address of this host")
  }

  // MARK: - Receiving

  /// Begin delivering datagrams: `onRTP`/`onRTCP` are invoked (on the private
  /// serial queue) once per datagram received on the RTP/RTCP port. Empty
  /// datagrams, and datagrams from a sender other than `source`, are dropped.
  /// No-op if already closed or if receiving already started. `onError` reports
  /// a failed receive, after which that port stops delivering.
  func startReceiving(
    onRTP: @escaping @Sendable (Data) -> Void,
    onRTCP: @escaping @Sendable (Data) -> Void,
    onError: (@Sendable (Error) -> Void)? = nil
  ) {
    lock.lock()
    guard !closed, !receiving, rtpFD >= 0, rtcpFD >= 0 else {
      lock.unlock()
      return
    }
    receiving = true
    let rtp = makeReadSource(fd: rtpFD, port: rtpPort, handler: onRTP, onError: onError)
    let rtcp = makeReadSource(fd: rtcpFD, port: rtcpPort, handler: onRTCP, onError: onError)
    // The read sources own the sockets from here; their cancel handlers close them.
    rtpSource = rtp
    rtcpSource = rtcp
    rtpFD = -1
    rtcpFD = -1
    lock.unlock()
    // A close() racing in between cancels a source before activation; activating
    // it then just runs the cancel handler, which closes the socket.
    rtp.activate()
    rtcp.activate()
  }

  private func makeReadSource(
    fd: Int32, port: UInt16, handler: @escaping @Sendable (Data) -> Void,
    onError: (@Sendable (Error) -> Void)?
  ) -> DispatchSourceRead {
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self, weak source] in
      guard let self, let source else { return }
      self.drain(fd: fd, port: port, source: source, handler: handler, onError: onError)
    }
    source.setCancelHandler { Darwin.close(fd) }
    return source
  }

  /// Read the datagrams waiting on `fd` (up to `maxDatagramsPerWakeup`) and
  /// deliver them. Runs on `queue`. A receive error other than "no more data"
  /// is reported and stops this port (re-firing on a persistent error would
  /// busy-loop).
  private func drain(
    fd: Int32, port: UInt16, source: DispatchSourceRead,
    handler: @Sendable (Data) -> Void, onError: (@Sendable (Error) -> Void)?
  ) {
    for _ in 0..<Self.maxDatagramsPerWakeup {
      var sender = sockaddr_storage()
      var senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let count = withUnsafeMutablePointer(to: &sender) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          recvfrom(fd, buffer.baseAddress, buffer.count, 0, $0, &senderLength)
        }
      }
      let code = count < 0 ? errno : 0
      if code == EINTR { continue }
      if code == EAGAIN || code == EWOULDBLOCK { return }
      // Checked per datagram so nothing is delivered once close() has run.
      lock.lock()
      let stillOpen = !closed
      lock.unlock()
      guard stillOpen else { return }
      guard code == 0 else {
        source.cancel()
        onError?(
          RTSPError.connectionFailed(
            "Multicast receive on \(cutForMessage(group)) port \(port) failed: \(Self.describeErrno(code))"
          ))
        return
      }
      guard count > 0, sourceFilter?.matches(sender) ?? true else { continue }
      handler(Data(bytes: buffer.baseAddress!, count: count))
    }
  }

  // MARK: - Teardown

  /// Stop delivery and leave the group (closing a socket drops its membership).
  /// Idempotent. `closed` is set first, so a datagram being read concurrently
  /// is not delivered; at most a callback already in progress completes.
  func close() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    let sources = [rtpSource, rtcpSource].compactMap { $0 }
    let fds = [rtpFD, rtcpFD].filter { $0 >= 0 }
    rtpSource = nil
    rtcpSource = nil
    rtpFD = -1
    rtcpFD = -1
    lock.unlock()
    for source in sources {
      source.cancel()
    }
    for fd in fds {
      Darwin.close(fd)
    }
  }

  // MARK: - Helpers

  /// `setsockopt` with a plain C value (`Int32` or an imported option struct).
  /// Returns 0 or the errno.
  private static func setOption<T>(
    _ fd: Int32, _ level: Int32, _ name: Int32, _ value: T
  ) -> Int32 {
    let result = withUnsafeBytes(of: value) {
      setsockopt(fd, level, name, $0.baseAddress, socklen_t($0.count))
    }
    return result == 0 ? 0 : errno
  }

  private static func describeErrno(_ code: Int32) -> String {
    "\(String(cString: strerror(code))) (errno \(code))"
  }
}

/// A numeric IPv4 or IPv6 address literal, parsed with `inet_pton`. An IPv6
/// literal may carry a `%zone` (interface name or index).
private struct IPLiteral: Sendable {
  /// The literal as given (normalized), for messages.
  let text: String
  /// Address bytes in network order: 4 for IPv4, 16 for IPv6.
  let bytes: [UInt8]
  /// Interface index from an IPv6 `%zone` suffix; 0 if none.
  let zone: UInt32

  var isIPv6: Bool { bytes.count == 16 }
  var isMulticast: Bool { isIPv6 ? bytes[0] == 0xFF : bytes[0] & 0xF0 == 0xE0 }
  /// An IPv6 address that is only meaningful with a zone: an interface-local
  /// (`ffx1::`) or link-local (`ffx2::`) multicast group, or a link-local unicast
  /// address (`fe80::/10`).
  var isScoped: Bool {
    guard isIPv6 else { return false }
    if isMulticast { return [1, 2].contains(bytes[1] & 0x0F) }
    return bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
  }

  /// Trim whitespace and one pair of enclosing brackets (`[ff02::1]`).
  static func normalize(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 else {
      return trimmed
    }
    return String(trimmed.dropFirst().dropLast())
  }

  init?(_ text: String) {
    var v4 = in_addr()
    if inet_pton(AF_INET, text, &v4) == 1 {
      self.text = text
      self.bytes = withUnsafeBytes(of: v4) { Array($0) }
      self.zone = 0
      return
    }
    let parts = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
    var v6 = in6_addr()
    guard let host = parts.first, inet_pton(AF_INET6, String(host), &v6) == 1 else {
      return nil
    }
    var zone: UInt32 = 0
    if parts.count == 2 {
      let name = String(parts[1])
      zone = UInt32(name) ?? if_nametoindex(name)
      guard zone != 0 else { return nil }
    }
    self.text = text
    self.bytes = withUnsafeBytes(of: v6) { Array($0) }
    self.zone = zone
  }

  var inAddress: in_addr {
    var address = in_addr()
    withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes.prefix(4)) }
    return address
  }

  var in6Address: in6_addr {
    var address = in6_addr()
    withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes.prefix(16)) }
    return address
  }

  /// A `sockaddr_in`/`sockaddr_in6` (by family) inside a `sockaddr_storage`. A
  /// scoped IPv6 address gets its own zone, else `interfaceIndex`, as scope id.
  func socketAddress(port: UInt16, interfaceIndex: UInt32) -> sockaddr_storage {
    let scopeID = isScoped ? (zone != 0 ? zone : interfaceIndex) : 0
    var storage = sockaddr_storage()
    withUnsafeMutableBytes(of: &storage) { raw in
      if isIPv6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6Address
        address.sin6_scope_id = scopeID
        withUnsafeBytes(of: address) { raw.copyMemory(from: $0) }
      } else {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = inAddress
        withUnsafeBytes(of: address) { raw.copyMemory(from: $0) }
      }
    }
    return storage
  }

  /// Whether `address` (a `sockaddr_in`/`sockaddr_in6`) holds this address. The
  /// IPv6 zone is ignored.
  func matches(_ address: UnsafePointer<sockaddr>) -> Bool {
    switch Int32(address.pointee.sa_family) {
    case AF_INET where !isIPv6:
      return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        withUnsafeBytes(of: $0.pointee.sin_addr) { $0.elementsEqual(bytes) }
      }
    case AF_INET6 where isIPv6:
      return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
        withUnsafeBytes(of: $0.pointee.sin6_addr) { $0.elementsEqual(bytes) }
      }
    default:
      return false
    }
  }

  func matches(_ storage: sockaddr_storage) -> Bool {
    var storage = storage
    return withUnsafePointer(to: &storage) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { matches($0) }
    }
  }
}
