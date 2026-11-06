// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// UDP transport for RTP/RTCP on BSD sockets.

import Darwin
import Foundation
import Network

/// Address family for a UDP RTP/RTCP socket pair, chosen to match the resolved
/// RTSP control-connection peer so the local bind family matches the server.
enum UDPAddressFamily: Sendable {
  case ipv4
  case ipv6

  /// Loopback literal for this family, used as a last-resort peer fallback.
  var loopback: String {
    switch self {
    case .ipv4: return "127.0.0.1"
    case .ipv6: return "::1"
    }
  }
}

/// A pair of connected UDP sockets for one RTP stream: RTP on an even local
/// port and RTCP on the consecutive odd port (`rtpPort + 1`), as required by
/// RFC 3550 and the `client_port=X-Y` SETUP transport parameter.
///
/// ## Why BSD sockets, not Network framework
///
/// Network framework's `NWConnection` cuts every received UDP datagram to 9216
/// bytes and drops the rest without an error, with `receiveMessage` and with
/// `receive(minimumIncompleteLength:maximumLength:)`. A server that relies on
/// IP fragmentation sends RTP packets larger than that, so this type uses two
/// BSD UDP sockets, read by `DispatchSource` read sources on a private serial
/// queue into a 64 KiB buffer, which holds any UDP datagram whole. Every socket
/// is non-blocking, so no call here waits on the network.
///
/// ## Lifecycle
///
/// `bind()` opens both sockets on the wildcard address and keeps them from
/// SETUP (which advertises the ports) to `close()`. `connect()` connects each
/// socket to the server's port once SETUP's reply names it. A connected UDP
/// socket gets only datagrams from that address and port, and the receive path
/// also drops any datagram from another sender that was queued before
/// `connect()`. The IPv6 sockets are dual-stack, so their ports are held for
/// IPv4 too and an IPv4-mapped peer (`::ffff:a.b.c.d`) works.
///
/// `@unchecked Sendable`: `rtpPort`, `rtcpPort`, `family`, `queue`, and
/// `buffer` are immutable after `bind()`. All other mutable state (`rtpFD`,
/// `rtcpFD`, the peer addresses, the read sources, `stoppedSources`, `connected`,
/// `receiving`, `closed`) is guarded by `lock`. Read-source handlers run on the
/// serial `queue`, the only user of `buffer`.
final class UDPPair: @unchecked Sendable {
  /// The bound local RTP port (even).
  let rtpPort: UInt16
  /// The bound local RTCP port (`rtpPort + 1`, odd).
  let rtcpPort: UInt16

  private let family: UDPAddressFamily
  /// Private serial queue for both read sources and every callback. It is never
  /// a Swift Concurrency cooperative thread.
  private let queue: DispatchQueue
  /// Receive buffer shared by both read sources (they run serially on `queue`).
  private let buffer: UnsafeMutableRawBufferPointer

  private let lock = NSLock()
  /// The sockets, open from `bind()` until `close()`; `-1` after that. Sends use
  /// them under `lock`. Once `startReceiving` has made the read sources, each
  /// source's cancel handler closes its socket; before that, `close()` does.
  private var rtpFD: Int32
  private var rtcpFD: Int32
  /// The server's RTP and RTCP endpoints, set by `connect()`.
  private var rtpPeer: Endpoint?
  private var rtcpPeer: Endpoint?
  private var rtpSource: DispatchSourceRead?
  private var rtcpSource: DispatchSourceRead?
  /// Read sources suspended after a receive error stopped their port. A stopped
  /// source is suspended, not cancelled, because its cancel handler closes the
  /// socket and sends still use it. `close()` resumes them so they can finish.
  private var stoppedSources: [DispatchSourceRead] = []
  private var connected = false
  private var receiving = false
  private var closed = false

  /// Max attempts to land an even RTP port with a free consecutive odd RTCP
  /// port before giving up. Ephemeral ports are ~50/50 even/odd, so a handful
  /// of tries is overwhelmingly sufficient.
  private static let maxBindTries = 20
  /// Large enough for any UDP datagram.
  private static let maxDatagramBytes = 65_536
  /// Datagrams read per read-source wakeup before yielding the queue, so a busy
  /// RTP socket cannot starve the RTCP socket. Any remainder fires the source again.
  private static let maxDatagramsPerWakeup = 64
  /// Requested kernel receive buffer per socket, room for a burst of large
  /// datagrams (a keyframe) while the queue is busy. Best effort.
  private static let receiveBufferBytes: Int32 = 2 << 20

  private init(family: UDPAddressFamily, rtpFD: Int32, rtcpFD: Int32, rtpPort: UInt16) {
    self.family = family
    self.rtpFD = rtpFD
    self.rtcpFD = rtcpFD
    self.rtpPort = rtpPort
    self.rtcpPort = rtpPort + 1
    self.queue = DispatchQueue(label: "ipcamkit.udp.\(family)")
    self.buffer = UnsafeMutableRawBufferPointer.allocate(
      byteCount: Self.maxDatagramBytes, alignment: 16)
  }

  /// Release the ports when the pair is dropped without `close()`.
  deinit {
    close()
    buffer.deallocate()
  }

  // MARK: - Binding

  /// Bind a local even-RTP / odd-RTCP UDP socket pair in `family`.
  ///
  /// Both sockets are bound to the wildcard address and stay open until
  /// `close()`. Retries until an even RTP port with a free consecutive odd RTCP
  /// port lands or `maxBindTries` is exhausted, then throws
  /// `transportNegotiationFailed`.
  static func bind(family: UDPAddressFamily) async throws -> UDPPair {
    for _ in 0..<maxBindTries {
      guard let rtp = openSocket(family: family, port: 0) else { continue }
      // Need an even RTP port with a free consecutive odd RTCP port. (An even
      // port is at most 65534, so `port + 1` never overflows `UInt16`.)
      guard rtp.port % 2 == 0 else {
        Darwin.close(rtp.fd)
        continue
      }
      if let rtcp = openSocket(family: family, port: rtp.port + 1) {
        if rtcp.port == rtp.port + 1 {
          return UDPPair(family: family, rtpFD: rtp.fd, rtcpFD: rtcp.fd, rtpPort: rtp.port)
        }
        // Bound a different port than requested (shouldn't happen): release it.
        Darwin.close(rtcp.fd)
      }
      Darwin.close(rtp.fd)
    }
    throw RTSPError.transportNegotiationFailed
  }

  /// Open a non-blocking UDP socket bound to `family`'s wildcard address on
  /// `port` (0 = ephemeral) and read back its port. Returns `nil` on any failure
  /// (e.g. the port is taken); the socket is closed on failure.
  private static func openSocket(
    family: UDPAddressFamily, port: UInt16
  ) -> (fd: Int32, port: UInt16)? {
    let fd = socket(family == .ipv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return nil }
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
      fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
    else {
      Darwin.close(fd)
      return nil
    }
    // Best effort: the default buffer still works, with less room for bursts.
    _ = setOption(fd, SOL_SOCKET, SO_RCVBUF, receiveBufferBytes)
    if family == .ipv6 {
      _ = setOption(fd, IPPROTO_IPV6, IPV6_V6ONLY, Int32(0))
    }

    var address = sockaddr_storage()
    withUnsafeMutableBytes(of: &address) { raw in
      if family == .ipv6 {
        var wildcard = sockaddr_in6()
        wildcard.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        wildcard.sin6_family = sa_family_t(AF_INET6)
        wildcard.sin6_port = port.bigEndian
        withUnsafeBytes(of: wildcard) { raw.copyMemory(from: $0) }
      } else {
        var wildcard = sockaddr_in()
        wildcard.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        wildcard.sin_family = sa_family_t(AF_INET)
        wildcard.sin_port = port.bigEndian
        wildcard.sin_addr = in_addr(s_addr: INADDR_ANY)
        withUnsafeBytes(of: wildcard) { raw.copyMemory(from: $0) }
      }
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t($0.pointee.sa_len))
      }
    }
    var local = sockaddr_storage()
    var localLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let named =
      bound == 0
      && withUnsafeMutablePointer(to: &local) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          getsockname(fd, $0, &localLength) == 0
        }
      }
    guard named else {
      Darwin.close(fd)
      return nil
    }
    return (fd, portNumber(of: local))
  }

  // MARK: - Connecting

  /// Connect the sockets to the server's RTP (`peerRTPPort`) and RTCP
  /// (`peerRTPPort + 1`) ports. A connected socket receives only datagrams from
  /// that address and port (the kernel drops datagrams from anywhere else), and
  /// `holePunch()`/sends need no address. `peerHost` must be a numeric literal
  /// of this pair's address family: IPv4, or IPv6 including a link-local
  /// address with a zone id (`fe80::1%en0`, whose interface becomes the scope
  /// id). An IPv4-mapped IPv6 literal works on an IPv6 pair. Names are not
  /// resolved. Completes at once: connecting a UDP socket sends nothing.
  func connect(peerHost: String, peerRTPPort: UInt16) async throws {
    guard peerRTPPort < UInt16.max else {
      throw RTSPError.transportNegotiationFailed
    }
    guard let rtpAddress = Self.peerAddress(host: peerHost, port: peerRTPPort, family: family),
      let rtcpAddress = Self.peerAddress(host: peerHost, port: peerRTPPort + 1, family: family),
      let rtpEndpoint = Endpoint(rtpAddress), let rtcpEndpoint = Endpoint(rtcpAddress)
    else {
      throw RTSPError.connectionFailed(
        "UDP peer '\(cutForMessage(peerHost))' is not a numeric "
          + "\(family == .ipv6 ? "IPv6" : "IPv4") address")
    }
    try lock.withLock {
      guard !closed, !connected else {
        throw RTSPError.connectionFailed("UDP connect on a closed or unbound pair")
      }
      for (fd, address) in [(rtpFD, rtpAddress), (rtcpFD, rtcpAddress)] {
        var address = address
        let result = withUnsafePointer(to: &address) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t($0.pointee.sa_len))
          }
        }
        guard result == 0 else {
          let code = errno
          throw RTSPError.connectionFailed(
            "UDP connect failed: \(Self.describeErrno(code))", underlying: NWError(errno: code))
        }
      }
      rtpPeer = rtpEndpoint
      rtcpPeer = rtcpEndpoint
      connected = true
    }
  }

  /// Best-effort NAT/firewall hole-punch: send one datagram from each local
  /// port to its connected peer so the server learns our mapping and its
  /// RTP/RTCP can return. The RTP port sends an empty datagram; the RTCP port
  /// sends `rtcpPacket`, a valid RTCP packet (an empty datagram there is a
  /// decode error for servers that parse all RTCP from clients). Harmless on
  /// loopback/LAN; errors are ignored.
  func holePunch(rtcpPacket: Data) {
    try? send(Data(), rtcp: false)
    try? send(rtcpPacket, rtcp: true)
  }

  /// Send one RTP datagram from the RTP socket to the connected peer (the
  /// ONVIF backchannel). Throws once the pair is closed or the send fails.
  func sendRTP(_ datagram: Data) async throws {
    try send(datagram, rtcp: false)
  }

  /// Send one RTCP datagram (a receiver report) from the RTCP socket to the
  /// connected peer's RTCP port.
  func sendRTCP(_ datagram: Data) async throws {
    try send(datagram, rtcp: true)
  }

  /// Send `datagram` on a non-blocking socket, so the caller never waits.
  ///
  /// Runs under `lock`, which keeps `close()` from closing the socket during the
  /// call. `EAGAIN` and `ENOBUFS` (no room in the socket or interface queue)
  /// drop the datagram without an error: UDP gives no delivery guarantee, the
  /// network can drop it the same way, and RTP and RTCP tolerate loss.
  /// An ICMP error for an earlier datagram (`isICMPError`: a camera not
  /// listening on that port yet, say) is returned instead of sending this
  /// one, so the send is tried once more; a lasting condition, such as no
  /// route to the host, fails that try too and throws.
  private func send(_ datagram: Data, rtcp: Bool) throws {
    try lock.withLock {
      guard !closed, connected else {
        throw RTSPError.connectionFailed("UDP \(rtcp ? "RTCP" : "RTP") socket is not connected")
      }
      let fd = rtcp ? rtcpFD : rtpFD
      var retriedICMP = false
      while true {
        let sent = datagram.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        if sent >= 0 { return }
        let code = errno
        switch code {
        case EINTR:
          continue
        case _ where Self.isICMPError(code) && !retriedICMP:
          retriedICMP = true
          continue
        case EAGAIN, EWOULDBLOCK, ENOBUFS:
          return
        default:
          throw RTSPError.connectionFailed(
            "UDP send failed: \(Self.describeErrno(code))", underlying: NWError(errno: code))
        }
      }
    }
  }

  // MARK: - Receiving

  /// Begin delivering datagrams: `onRTP`/`onRTCP` are invoked (on the private
  /// serial queue) once per datagram received on the RTP/RTCP socket, in
  /// arrival order. Empty datagrams, and datagrams from anyone but the connected
  /// peer, are dropped. No-op if already closed or not yet connected, or if
  /// receiving already started. `onError` reports a failed receive, after which
  /// that port stops delivering; an ICMP error an earlier send drew
  /// (`isICMPError`) is not a failure.
  func startReceiving(
    onRTP: @escaping @Sendable (Data) -> Void,
    onRTCP: @escaping @Sendable (Data) -> Void,
    onError: (@Sendable (Error) -> Void)? = nil
  ) {
    lock.lock()
    guard !closed, !receiving, let rtpPeer, let rtcpPeer else {
      lock.unlock()
      return
    }
    receiving = true
    let rtp = makeReadSource(
      fd: rtpFD, name: "RTP", port: rtpPort, peer: rtpPeer, handler: onRTP, onError: onError)
    let rtcp = makeReadSource(
      fd: rtcpFD, name: "RTCP", port: rtcpPort, peer: rtcpPeer, handler: onRTCP,
      onError: onError)
    // The read sources close the sockets from here (in their cancel handlers).
    rtpSource = rtp
    rtcpSource = rtcp
    lock.unlock()
    // A close() racing in between cancels a source before activation; activating
    // it then just runs the cancel handler, which closes the socket.
    rtp.activate()
    rtcp.activate()
  }

  private func makeReadSource(
    fd: Int32, name: String, port: UInt16, peer: Endpoint,
    handler: @escaping @Sendable (Data) -> Void, onError: (@Sendable (Error) -> Void)?
  ) -> DispatchSourceRead {
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self, weak source] in
      guard let self, let source else { return }
      self.drain(
        fd: fd, name: name, port: port, peer: peer, source: source, handler: handler,
        onError: onError)
    }
    source.setCancelHandler { Darwin.close(fd) }
    return source
  }

  /// Read the datagrams waiting on `fd` (up to `maxDatagramsPerWakeup`) and
  /// deliver those from `peer`. Runs on `queue`. A receive error other than "no
  /// more data", an interrupt, or an ICMP error (`isICMPError`) is reported
  /// once and stops this port (re-firing on a persistent error would
  /// busy-loop).
  private func drain(
    fd: Int32, name: String, port: UInt16, peer: Endpoint, source: DispatchSourceRead,
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
      // An earlier send drew an ICMP error (e.g. a camera not yet listening
      // on its RTCP port). The kernel clears the error once it is reported,
      // and the socket keeps receiving.
      if Self.isICMPError(code) { continue }
      // Checked per datagram so nothing is delivered once close() has run.
      lock.lock()
      let stillOpen = !closed
      if stillOpen && code != 0 {
        source.suspend()
        stoppedSources.append(source)
      }
      lock.unlock()
      guard stillOpen else { return }
      guard code == 0 else {
        onError?(
          RTSPError.connectionFailed(
            "UDP \(name) receive on local port \(port) failed: \(Self.describeErrno(code))",
            underlying: NWError(errno: code)))
        return
      }
      guard count > 0, Endpoint(sender) == peer else { continue }
      handler(Data(bytes: buffer.baseAddress!, count: count))
    }
  }

  // MARK: - Teardown

  /// Close both sockets, stopping delivery. Idempotent. `closed` is set first,
  /// so a datagram read after that is not delivered; a callback for one that
  /// passed the check just before may still run, even after `close()`
  /// returns (callers that must not see it discard it themselves, as
  /// RTSPSession's datagram queue does once finished). Once receiving has started, the sockets
  /// close on the private queue right after any read in progress.
  func close() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    let sources = [rtpSource, rtcpSource].compactMap { $0 }
    let stopped = stoppedSources
    // Without read sources nothing else owns the sockets.
    let fds = sources.isEmpty ? [rtpFD, rtcpFD].filter { $0 >= 0 } : []
    rtpSource = nil
    rtcpSource = nil
    stoppedSources = []
    rtpFD = -1
    rtcpFD = -1
    lock.unlock()
    for source in sources {
      source.cancel()
    }
    // A suspended source runs its cancel handler (closing its socket) only once
    // resumed; being cancelled already, it delivers nothing more.
    for source in stopped {
      source.resume()
    }
    for fd in fds {
      Darwin.close(fd)
    }
  }

  // MARK: - Host classification

  /// Whether `host` is a numeric IPv4 literal (no DNS/zone handling needed).
  static func isNumericIPv4(_ host: String) -> Bool {
    IPv4Address(host) != nil
  }

  /// Whether `host` is a numeric IPv6 literal, including link-local with a zone
  /// id (e.g. `fe80::1%en0`).
  static func isNumericIPv6(_ host: String) -> Bool {
    IPv6Address(host) != nil
  }

  // MARK: - Helpers

  /// The socket address of numeric `host` (parsed like `isNumericIPv4` /
  /// `isNumericIPv6`) and `port` in `family`, or `nil` if `host` is not a
  /// literal of that family. An IPv6 zone becomes the scope id.
  private static func peerAddress(
    host: String, port: UInt16, family: UDPAddressFamily
  ) -> sockaddr_storage? {
    var storage = sockaddr_storage()
    switch family {
    case .ipv4:
      guard let parsed = IPv4Address(host) else { return nil }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyBytes(from: parsed.rawValue) }
      withUnsafeMutableBytes(of: &storage) { raw in
        withUnsafeBytes(of: address) { raw.copyMemory(from: $0) }
      }
    case .ipv6:
      guard let parsed = IPv6Address(host) else { return nil }
      var address = sockaddr_in6()
      address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      address.sin6_family = sa_family_t(AF_INET6)
      address.sin6_port = port.bigEndian
      address.sin6_scope_id = UInt32(parsed.interface?.index ?? 0)
      withUnsafeMutableBytes(of: &address.sin6_addr) { $0.copyBytes(from: parsed.rawValue) }
      withUnsafeMutableBytes(of: &storage) { raw in
        withUnsafeBytes(of: address) { raw.copyMemory(from: $0) }
      }
    }
    return storage
  }

  /// The port of a `sockaddr_in`/`sockaddr_in6` held in `storage`.
  private static func portNumber(of storage: sockaddr_storage) -> UInt16 {
    withUnsafeBytes(of: storage) { raw in
      if Int32(storage.ss_family) == AF_INET6 {
        return UInt16(bigEndian: raw.load(as: sockaddr_in6.self).sin6_port)
      }
      return UInt16(bigEndian: raw.load(as: sockaddr_in.self).sin_port)
    }
  }

  /// A UDP sender or peer, compared by address and port, with an IPv4 address
  /// in its IPv4-mapped IPv6 form: a socket connected to an IPv4-mapped peer
  /// reports that peer's datagrams with an IPv4 sender, but a datagram queued
  /// before `connect()` with the mapped one. The IPv6 scope id is left out; the
  /// connected socket already matched it.
  private struct Endpoint: Equatable {
    let port: UInt16
    let addressHigh: UInt64
    let addressLow: UInt64

    /// The endpoint of a `sockaddr_in`/`sockaddr_in6` held in `storage`.
    init?(_ storage: sockaddr_storage) {
      var address = in6_addr()
      switch Int32(storage.ss_family) {
      case AF_INET:
        let v4 = withUnsafeBytes(of: storage) { $0.load(as: sockaddr_in.self) }
        port = UInt16(bigEndian: v4.sin_port)
        withUnsafeMutableBytes(of: &address) { bytes in
          bytes[10] = 0xFF
          bytes[11] = 0xFF
          withUnsafeBytes(of: v4.sin_addr) {
            UnsafeMutableRawBufferPointer(rebasing: bytes[12...]).copyMemory(from: $0)
          }
        }
      case AF_INET6:
        let v6 = withUnsafeBytes(of: storage) { $0.load(as: sockaddr_in6.self) }
        port = UInt16(bigEndian: v6.sin6_port)
        address = v6.sin6_addr
      default:
        return nil
      }
      (addressHigh, addressLow) = withUnsafeBytes(of: address) {
        ($0.loadUnaligned(as: UInt64.self), $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
      }
    }
  }

  /// `setsockopt` with an `Int32` value. Returns 0 or the errno.
  private static func setOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) -> Int32
  {
    let result = withUnsafeBytes(of: value) {
      setsockopt(fd, level, name, $0.baseAddress, socklen_t($0.count))
    }
    return result == 0 ? 0 : errno
  }

  /// Whether `code` is how a connected UDP socket reports, once, an ICMP
  /// message an earlier datagram drew: port unreachable (`ECONNREFUSED`),
  /// host or network unreachable, host down, fragmentation needed or packet
  /// too big (`EMSGSIZE`), or a parameter problem (`ENOPROTOOPT`). It says
  /// nothing lasting about the socket, which keeps working. (A send of a
  /// datagram too large to go out at all fails `EMSGSIZE` again on its retry
  /// and throws.)
  private static func isICMPError(_ code: Int32) -> Bool {
    [ECONNREFUSED, EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, EMSGSIZE, ENOPROTOOPT].contains(code)
  }

  private static func describeErrno(_ code: Int32) -> String {
    "\(String(cString: strerror(code))) (errno \(code))"
  }
}
