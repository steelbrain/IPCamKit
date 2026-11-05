// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Unit tests for RTSPS (RTSP over TLS): URL endpoint parsing, certificate
// fingerprints and pinning, the rtsps + UDP rejection, a server that
// rejects the client after the TLS 1.3 handshake, and the certificate check
// for a link-local IPv6 host with a zone (in-process listeners whose identity
// `/usr/bin/openssl` makes). A full RTSPS session is exercised against a real
// server in LiveIntegrationTests.

import Foundation
import Network
import Security
import Testing

@testable import IPCamKit

/// A self-signed EC P-256 certificate (CN=ipcamkit-test, SAN DNS:camera.test),
/// DER, base64. Only the public certificate; the key was discarded.
private let testCertificateBase64 = """
  MIIBQjCB6aADAgECAgkAvLdLwSZM+gEwCgYIKoZIzj0EAwIwGDEWMBQGA1UEAwwNaXBjYW1raXQt\
  dGVzdDAgFw0yNjExMDQwNjE1MjZaGA8yMTI2MTAxMTA2MTUyNlowGDEWMBQGA1UEAwwNaXBjYW1r\
  aXQtdGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABJqBim3VcwxpoKA6feMuNYnZBgxmkeK2\
  mt1rM9YNU/FWQ5fZ2c5yevC8ZrKiWCfF8MQ3ckJxY5wRXNtoIfC7OTijGjAYMBYGA1UdEQQPMA2C\
  C2NhbWVyYS50ZXN0MAoGCCqGSM49BAMCA0gAMEUCIQCvbHUNde5iSxTTnhWTBiwJYmFomPaus2pg\
  KbjnXkoWqQIgIHSPziHkuTAnV0ayg5SJzSYdfefZcBcEGuD4EVm20VQ=
  """

/// `openssl x509 -noout -fingerprint -sha256` output for the certificate above.
private let testCertificateOpenSSLFingerprint =
  "52:22:79:35:EE:3E:F5:C5:F1:A1:A1:FF:FD:22:F6:BA:99:77:36:C9:CD:B0:2F:E4:44:41:FF:4A:8B:CC:84:6A"

private func testCertificate() throws -> SecCertificate {
  let der = try #require(Data(base64Encoded: testCertificateBase64))
  return try #require(SecCertificateCreateWithData(nil, der as CFData))
}

/// A trust object holding just `certificate`, as the TLS stack would hand to a
/// verify block for a server presenting it.
private func trust(for certificate: SecCertificate) throws -> SecTrust {
  var trust: SecTrust?
  let status = SecTrustCreateWithCertificates(
    certificate, SecPolicyCreateSSL(true, "camera.test" as CFString), &trust)
  #expect(status == errSecSuccess)
  return try #require(trust)
}

@Suite("RTSP endpoint parsing")
struct RTSPEndpointTests {

  @Test("rtsp:// defaults to port 554 without TLS")
  func rtspDefaults() throws {
    let endpoint = try rtspEndpoint(for: "rtsp://camera.local/stream1")
    #expect(endpoint == RTSPEndpoint(host: "camera.local", port: 554, usesTLS: false))
  }

  @Test("rtsps:// defaults to port 322 with TLS")
  func rtspsDefaults() throws {
    let endpoint = try rtspEndpoint(for: "rtsps://camera.local/stream1")
    #expect(endpoint == RTSPEndpoint(host: "camera.local", port: 322, usesTLS: true))
  }

  @Test("An explicit port wins, and the scheme is case-insensitive")
  func explicitPortAndUppercaseScheme() throws {
    let endpoint = try rtspEndpoint(for: "RTSPS://192.168.1.1:7441/abcdef?enableSrtp")
    #expect(endpoint == RTSPEndpoint(host: "192.168.1.1", port: 7441, usesTLS: true))
    let plain = try rtspEndpoint(for: "RTSP://192.168.1.1:8554/x")
    #expect(plain == RTSPEndpoint(host: "192.168.1.1", port: 8554, usesTLS: false))
  }

  @Test("A bracketed IPv6 host is unbracketed for rtsps://")
  func rtspsIPv6() throws {
    let endpoint = try rtspEndpoint(for: "rtsps://[2001:db8::1]:8322/x")
    #expect(endpoint == RTSPEndpoint(host: "2001:db8::1", port: 8322, usesTLS: true))
  }

  @Test("An out-of-range port is rejected")
  func invalidPort() {
    #expect(throws: RTSPError.self) {
      _ = try rtspEndpoint(for: "rtsps://camera.local:70000/x")
    }
  }
}

@Suite("Certificate fingerprints and pinning")
struct CertificateFingerprintTests {

  @Test("Fingerprint of a certificate matches openssl's SHA-256 fingerprint")
  func fingerprintMatchesOpenSSL() throws {
    let fromCert = CertificateFingerprint(certificate: try testCertificate())
    let fromHex = try #require(CertificateFingerprint(hex: testCertificateOpenSSLFingerprint))
    #expect(fromCert == fromHex)
    #expect(fromCert.description == testCertificateOpenSSLFingerprint)
    #expect(fromCert.sha256.count == 32)
  }

  @Test("Hex parsing ignores case, colons, and whitespace")
  func hexFormats() throws {
    let expected = try #require(CertificateFingerprint(hex: testCertificateOpenSSLFingerprint))
    let compact = testCertificateOpenSSLFingerprint.replacingOccurrences(of: ":", with: "")
    #expect(CertificateFingerprint(hex: compact.lowercased()) == expected)
    let spaced = testCertificateOpenSSLFingerprint.replacingOccurrences(of: ":", with: " ")
    #expect(CertificateFingerprint(hex: "  \(spaced)\n") == expected)
  }

  @Test("Malformed hex is rejected")
  func malformedHex() {
    let valid = testCertificateOpenSSLFingerprint
    #expect(CertificateFingerprint(hex: "") == nil)
    #expect(CertificateFingerprint(hex: String(valid.dropLast(3))) == nil, "31 bytes")
    #expect(CertificateFingerprint(hex: valid + ":00") == nil, "33 bytes")
    #expect(CertificateFingerprint(hex: String(valid.dropLast())) == nil, "odd digit count")
    #expect(CertificateFingerprint(hex: "G" + valid.dropFirst()) == nil, "non-hex digit")
    #expect(CertificateFingerprint(hex: "SHA256 Fingerprint=" + valid) == nil, "label prefix")
  }

  @Test("Raw digest bytes must be exactly 32 bytes")
  func rawDigestLength() {
    #expect(CertificateFingerprint(sha256: Data(repeating: 0xAB, count: 32)) != nil)
    #expect(CertificateFingerprint(sha256: Data(repeating: 0xAB, count: 31)) == nil)
    #expect(CertificateFingerprint(sha256: Data(repeating: 0xAB, count: 33)) == nil)
  }

  @Test("Pinning accepts only the leaf certificate's fingerprint")
  func pinMatching() throws {
    let certificate = try testCertificate()
    let trust = try trust(for: certificate)
    let pin = CertificateFingerprint(certificate: certificate)
    let other = try #require(CertificateFingerprint(sha256: Data(repeating: 0, count: 32)))

    #expect(leafCertificateMatches(trust, pins: [pin]))
    #expect(leafCertificateMatches(trust, pins: [other, pin]))
    #expect(!leafCertificateMatches(trust, pins: [other]))
    #expect(!leafCertificateMatches(trust, pins: []))
  }
}

@Suite("RTSPS session configuration")
struct RTSPSSessionTests {

  @Test("TLS connect failures are labelled as TLS errors")
  func tlsErrorDescription() {
    // Network's code for a failed trust decision gets a pointer to the setting
    // that made it, not the system's "bad certificate format" string.
    let rejected = RTSPTransportConnection.describe(.tls(errSSLBadCert))
    #expect(
      rejected
        == "TLS handshake failed: server certificate rejected by TLSOptions.serverTrust "
        + "(OSStatus \(errSSLBadCert))")

    let protocolError = RTSPTransportConnection.describe(.tls(errSSLProtocol))
    #expect(protocolError.hasPrefix("TLS handshake failed: "))
    #expect(protocolError.hasSuffix("(OSStatus \(errSSLProtocol))"))

    let posix = RTSPTransportConnection.describe(.posix(.ECONNREFUSED))
    #expect(!posix.contains("TLS"))
  }

  @Test(
    "A TLS failure after the connection is ready is a failed handshake until data arrives",
    .timeLimit(.minutes(1)))
  func tlsFailureAfterReadyDescription() {
    let status = errSSLPeerCertUnknown
    let early = RTSPTransportConnection.describeAfterReady(.tls(status), dataReceived: false)
    #expect(early.hasPrefix("TLS handshake failed: "), "got: \(early)")
    #expect(early.hasSuffix("(OSStatus \(status))"), "got: \(early)")
    let late = RTSPTransportConnection.describeAfterReady(.tls(status), dataReceived: true)
    #expect(late.hasPrefix("TLS connection failed: "), "got: \(late)")
    #expect(late.hasSuffix("(OSStatus \(status))"), "got: \(late)")
    let reset = RTSPTransportConnection.describeAfterReady(
      .posix(.ECONNRESET), dataReceived: true)
    #expect(!reset.contains("TLS"), "got: \(reset)")
  }

  @Test(
    "A failure reported after cancel() is not recorded; one before it is", .timeLimit(.minutes(1)))
  func failureAfterCancelIgnored() {
    let alert = NWError.tls(errSSLPeerCertUnknown)
    let failed = WatchedConnection(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
    failed.handle(.failed(alert))
    guard case .connectionFailed(let message)? = failed.failure else {
      Issue.record("expected a recorded failure, got \(String(describing: failed.failure))")
      return
    }
    #expect(message.hasPrefix("TLS handshake failed: "), "got: \(message)")

    let closed = WatchedConnection(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
    closed.cancel()
    closed.handle(.failed(alert))
    #expect(closed.failure(after: alert) == nil)
    #expect(closed.failure == nil, "a clean close must not report a failure")
  }
}

@Suite("RTSP endpoint checks")
struct RTSPEndpointCheckTests {
  @Test("Only rtsp:// and rtsps:// URLs with a non-zero port are accepted")
  func schemeAndPort() throws {
    #expect(throws: RTSPError.self) { try rtspEndpoint(for: "http://camera.local/stream") }
    #expect(throws: RTSPError.self) { try rtspEndpoint(for: "rtsp://camera.local:0/stream") }
    let endpoint = try rtspEndpoint(for: "rtsp://camera.local:8554/stream")
    #expect(endpoint.port == 8554)
    // A port too large for `Int` isn't taken as no port (the default).
    for url in [
      "rtsp://127.0.0.1:18446744073709551615/s", "rtsps://[::1]:9223372036854775808/s",
      "rtsp://camera.local:99999999999999999999/s",
    ] {
      #expect(throws: RTSPError.self, "\(url)") { try rtspEndpoint(for: url) }
    }
    // An empty port is the default one (RFC 3986).
    #expect(try rtspEndpoint(for: "rtsp://camera.local:/s").port == 554)
    #expect(try rtspEndpoint(for: "rtsp://127.0.0.1:/s").port == 554)
    #expect(try rtspEndpoint(for: "rtsp://[::1]:/s").port == 554)
    #expect(try rtspEndpoint(for: "rtsps://[fe80::1%25en0]:/s").port == 322)
    for (url, port) in [("http://[::1]:/t", 80), ("https://cam.example:/t", 443)] {
      let endpoint = try HTTPEndpoint(
        url: try #require(URL(string: url)), plainScheme: "http", tlsScheme: "https")
      #expect(endpoint.port == port)
    }
  }

  @Test("A link-local UDP peer without a zone takes the zone of the control connection")
  func linkLocalZone() {
    let zoned = linkLocalWithZone("fe80::1", zoneFrom: [nil, "fe80::1%en0"])
    #expect(zoned == "fe80::1%en0")
    #expect(linkLocalWithZone("fe80::1%lo0", zoneFrom: ["fe80::1%en0"]) == "fe80::1%lo0")
    #expect(linkLocalWithZone("2001:db8::1", zoneFrom: ["fe80::1%en0"]) == "2001:db8::1")
    #expect(linkLocalWithZone("192.168.1.10", zoneFrom: ["fe80::1%en0"]) == "192.168.1.10")
    #expect(linkLocalWithZone("fe80::1", zoneFrom: ["camera.local"]) == "fe80::1")
  }

  @Test("Only the parameter-set sprop keys count as advertised parameter sets")
  func spropKeys() {
    #expect(SessionState.advertisesParameterSets("packetization-mode=1;sprop-parameter-sets=Z0,aO"))
    #expect(SessionState.advertisesParameterSets("profile-id=1; sprop-vps=QAE;sprop-sps=QgE"))
    #expect(!SessionState.advertisesParameterSets("profile-id=1;sprop-max-don-diff=0"))
    #expect(!SessionState.advertisesParameterSets("sprop-depack-buf-nalus=2"))
  }
}

// MARK: - Failure after the handshake

private struct TLSServerError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// A flag only touched on one serial queue, hence `@unchecked Sendable`.
private final class SettledFlag: @unchecked Sendable {
  var value = false
}

/// Whether PKCS #12 import can keep the test identity in memory
/// (`kSecImportToMemoryOnly`), out of the keychain.
private let canImportIdentityInMemory: Bool = {
  if #available(macOS 15.0, iOS 18.0, *) { return true }
  return false
}()

/// Run `/usr/bin/openssl` with `arguments`, waiting for it to exit without
/// blocking a thread.
private func runOpenSSL(_ arguments: [String]) async throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
  process.arguments = arguments
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  let status: Int32 = try await withCheckedThrowingContinuation { continuation in
    process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
    do {
      try process.run()
    } catch {
      process.terminationHandler = nil
      continuation.resume(throwing: error)
    }
  }
  guard status == 0 else {
    throw TLSServerError("openssl \(arguments.first ?? "") exited \(status)")
  }
}

/// A fresh self-signed identity for the subject alternative names
/// `subjectAltName` (openssl's syntax), made with `/usr/bin/openssl` in a
/// temporary directory (removed afterwards) and imported into memory only.
@available(macOS 15.0, iOS 18.0, *)
private func makeServerIdentity(subjectAltName: String) async throws -> SecIdentity {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("ipcamkit-tls-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let key = directory.appendingPathComponent("key.pem").path
  let certificate = directory.appendingPathComponent("cert.pem").path
  let bundle = directory.appendingPathComponent("identity.p12").path
  try await runOpenSSL([
    "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", certificate,
    "-days", "2", "-subj", "/CN=localhost",
    "-addext", "subjectAltName=\(subjectAltName)",
    "-addext", "extendedKeyUsage=serverAuth",
    "-addext", "basicConstraints=critical,CA:FALSE",
  ])
  try await runOpenSSL([
    "pkcs12", "-export", "-inkey", key, "-in", certificate, "-out", bundle,
    "-passout", "pass:ipcamkit",
  ])
  let data = try Data(contentsOf: URL(fileURLWithPath: bundle))
  let options: [String: Any] = [
    kSecImportExportPassphrase as String: "ipcamkit",
    kSecImportToMemoryOnly as String: true,
  ]
  var items: CFArray?
  let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
  guard status == errSecSuccess,
    let item = (items as? [[String: Any]])?.first?[kSecImportItemIdentity as String]
  else {
    throw TLSServerError("PKCS #12 import failed (OSStatus \(status))")
  }
  return item as! SecIdentity
}

/// A local TLS 1.3 listener with a fresh self-signed certificate. One that
/// requires a client certificate aborts each handshake with a
/// certificate_required alert, since the client has none, after the client has
/// already finished its part of the handshake. Otherwise the handshake
/// completes and the connection stays open.
@available(macOS 15.0, iOS 18.0, *)
private final class TLSTestServer: @unchecked Sendable {
  let port: UInt16
  /// The listener's certificate.
  let certificate: SecCertificate
  /// The fingerprint of the listener's certificate, to pin.
  var fingerprint: CertificateFingerprint { CertificateFingerprint(certificate: certificate) }
  private let listener: NWListener
  private let lock = NSLock()
  private var connections: [NWConnection] = []

  private init(listener: NWListener, port: UInt16, certificate: SecCertificate) {
    self.listener = listener
    self.port = port
    self.certificate = certificate
  }

  /// Start listening on an ephemeral port of `host`, with a certificate for
  /// `subjectAltName` (openssl's syntax).
  static func start(
    host: String = "127.0.0.1", subjectAltName: String = "DNS:localhost,IP:127.0.0.1",
    requireClientCertificate: Bool
  ) async throws -> TLSTestServer {
    let identity = try await makeServerIdentity(subjectAltName: subjectAltName)
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
      let certificate, let secIdentity = sec_identity_create(identity)
    else {
      throw TLSServerError("unusable identity")
    }
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
    sec_protocol_options_set_peer_authentication_required(
      tls.securityProtocolOptions, requireClientCertificate)
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
    let listener = try NWListener(using: parameters)
    let queue = DispatchQueue(label: "ipcamkit.tests.tls-server")
    let port = try await startListening(listener, queue: queue)
    let server = TLSTestServer(listener: listener, port: port, certificate: certificate)
    listener.newConnectionHandler = { [server] connection in
      server.lock.withLock { server.connections.append(connection) }
      connection.start(queue: queue)
    }
    return server
  }

  func stop() {
    listener.cancel()
    let toCancel = lock.withLock {
      defer { connections.removeAll() }
      return connections
    }
    for connection in toCancel { connection.cancel() }
  }
}

/// A loopback TCP relay to a local port that delays the client's second
/// flight: it forwards the client's first chunk (the ClientHello) at once and
/// the next one (the client's Certificate and Finished) after `hold`, then
/// reads nothing more from the client. Server-to-client bytes pass at once.
/// So the client, ready as soon as it sent its Finished, can start a send
/// that is still pending when the server's alert reaches it.
private final class HoldingRelay: @unchecked Sendable {
  let port: UInt16
  private let listener: NWListener
  private let lock = NSLock()
  private var connections: [NWConnection] = []
  private var tasks: [Task<Void, Never>] = []

  private init(listener: NWListener, port: UInt16) {
    self.listener = listener
    self.port = port
  }

  static func start(to targetPort: UInt16, hold: Duration) async throws -> HoldingRelay {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    let queue = DispatchQueue(label: "ipcamkit.tests.tls-relay")
    let port = try await startListening(listener, queue: queue)
    let relay = HoldingRelay(listener: listener, port: port)
    let target = try #require(NWEndpoint.Port(rawValue: targetPort))
    listener.newConnectionHandler = { [relay] client in
      let server = NWConnection(host: "127.0.0.1", port: target, using: .tcp)
      client.start(queue: queue)
      server.start(queue: queue)
      let toClient = Task {
        while let chunk = try? await receiveChunk(from: server) {
          guard (try? await sendData(chunk, on: client)) != nil else { return }
        }
      }
      let toServer = Task {
        guard let hello = try? await receiveChunk(from: client),
          (try? await sendData(hello, on: server)) != nil,
          let flight = try? await receiveChunk(from: client)
        else { return }
        try? await Task.sleep(for: hold)
        _ = try? await sendData(flight, on: server)
      }
      relay.lock.withLock {
        relay.connections += [client, server]
        relay.tasks += [toClient, toServer]
      }
    }
    return relay
  }

  func stop() {
    listener.cancel()
    let (toCancel, toStop) = lock.withLock {
      defer {
        connections.removeAll()
        tasks.removeAll()
      }
      return (connections, tasks)
    }
    for task in toStop { task.cancel() }
    for connection in toCancel { connection.cancel() }
  }
}

/// Start `listener` on `queue` and return its port once it is ready.
private func startListening(_ listener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
  try await withCheckedThrowingContinuation { continuation in
    // The handler runs on the serial `queue`, so the flag needs no lock.
    let settled = SettledFlag()
    @Sendable func settle(_ result: Result<UInt16, Error>) {
      guard !settled.value else { return }
      settled.value = true
      continuation.resume(with: result)
    }
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        if let port = listener.port?.rawValue {
          settle(.success(port))
        } else {
          settle(.failure(TLSServerError("listener has no port")))
        }
      case .failed(let error):
        settle(.failure(error))
      case .cancelled:
        settle(.failure(TLSServerError("cancelled")))
      default:
        break
      }
    }
    // A listener needs a handler to start; callers set theirs once the port
    // is known.
    listener.newConnectionHandler = { $0.cancel() }
    listener.start(queue: queue)
  }
}

@Suite(
  "TLS failure after the client's handshake", .timeLimit(.minutes(1)),
  .enabled(if: canImportIdentityInMemory))
struct TLSFailureAfterHandshakeTests {

  @Test(
    "A server that rejects the client after a TLS 1.3 handshake fails start() at once",
    arguments: ["rtsps", "https", "wss"])
  func clientCertificateRequired(route: String) async throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let server = try await TLSTestServer.start(requireClientCertificate: true)
    defer { server.stop() }
    let base = "127.0.0.1:\(server.port)/stream"
    let tunnel: RTSPTunnel?
    switch route {
    case "https": tunnel = .http(try #require(URL(string: "https://\(base)")))
    case "wss": tunnel = .webSocket(try #require(URL(string: "wss://\(base)")))
    default: tunnel = nil
    }
    let session = RTSPClientSession(
      url: "rtsps://\(base)", credentials: nil, transport: .tcp,
      tls: TLSOptions(serverTrust: .pinned([server.fingerprint])), tunnel: tunnel,
      userAgent: "IPCamKit", onDiagnostic: nil, keepaliveInterval: nil,
      setupResponseTimeout: .seconds(4))

    // Before the fix, a send after the server's alert never completed:
    // start() threw RTSPError.timeout after setupResponseTimeout (rtsps) or
    // the 15-second connect timeout (tunnels).
    let started = ContinuousClock.now
    let result = await outcome { try await session.start() }
    let elapsed = ContinuousClock.now - started
    #expect(elapsed < .seconds(2), "start() took \(elapsed)")
    guard case .failure(RTSPError.connectionFailed(let message)) = result else {
      Issue.record("expected connectionFailed, got \(result)")
      return
    }
    #expect(message.hasPrefix("TLS handshake failed: "), "got: \(message)")
    #expect(message.contains("OSStatus"), "got: \(message)")
  }
  @Test(
    "A send pending when the server aborts the TLS 1.3 handshake ends with the TLS error",
    .timeLimit(.minutes(1)))
  func pendingSendEnds() async throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let server = try await TLSTestServer.start(requireClientCertificate: true)
    defer { server.stop() }
    let relay = try await HoldingRelay.start(to: server.port, hold: .milliseconds(300))
    defer { relay.stop() }
    let client = RTSPTransportConnection()
    try await client.connect(
      host: "127.0.0.1", port: relay.port,
      tls: TLSOptions(serverTrust: .pinned([server.fingerprint])))

    // More than the socket buffers hold while the relay reads nothing, so
    // the send is still pending when the alert arrives. Before the fix it
    // never completed; `closer` stands in for the deadline that ended it.
    let started = ContinuousClock.now
    let sender = Task { await outcome { try await client.send(Data(count: 64 << 20)) } }
    let closer = Task {
      try await Task.sleep(for: .seconds(5))
      await client.close()
    }
    let result = await sender.value
    closer.cancel()
    let elapsed = ContinuousClock.now - started
    #expect(elapsed < .seconds(2), "the send ended after \(elapsed)")
    guard case .failure(RTSPError.connectionFailed(let message)) = result else {
      Issue.record("expected connectionFailed, got \(result)")
      return
    }
    #expect(message.hasPrefix("TLS handshake failed: "), "got: \(message)")
    await expectTLSFailure(message) {
      try await client.send(Data("OPTIONS * RTSP/1.0\r\nCSeq: 2\r\n\r\n".utf8))
    }
    await client.close()
  }
}

@Suite(
  "TLS certificate check for a link-local IPv6 host", .timeLimit(.minutes(1)),
  .enabled(if: canImportIdentityInMemory))
struct TLSLinkLocalHostTests {

  @Test(
    "A link-local host's zone is left out of the SSL policy the certificate is checked against",
    arguments: [("IP:fe80::1", true), ("IP:fe80::2", false)])
  func zoneLeftOutOfPolicy(subjectAltName: String, accepted: Bool) async throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    // macOS gives lo0 the address fe80::1.
    let host = "fe80::1%lo0"
    let server = try await TLSTestServer.start(
      host: host, subjectAltName: subjectAltName, requireClientCertificate: false)
    defer { server.stop() }
    let anchor = server.certificate
    let tls = TLSOptions(
      serverTrust: .custom { trust in
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil)
      })
    let client = RTSPTransportConnection()
    // Before the fix the policy named `fe80::1%lo0`, which no certificate
    // matches, so the handshake failed for `IP:fe80::1` too.
    let result = await outcome { try await client.connect(host: host, port: server.port, tls: tls) }
    await client.close()
    if accepted {
      #expect(throws: Never.self) { try result.get() }
    } else {
      guard case .failure(RTSPError.connectionFailed(let message)) = result else {
        Issue.record("expected connectionFailed, got \(result)")
        return
      }
      #expect(message.hasPrefix("TLS handshake failed: "), "got: \(message)")
    }
  }

  @Test("With .system, a link-local host's certificate must still lead to a trusted root")
  func systemTrustStillEvaluated() async throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let host = "fe80::1%lo0"
    let server = try await TLSTestServer.start(
      host: host, subjectAltName: "IP:fe80::1", requireClientCertificate: false)
    defer { server.stop() }
    let client = RTSPTransportConnection()
    let result = await outcome {
      try await client.connect(host: host, port: server.port, tls: TLSOptions(serverTrust: .system))
    }
    await client.close()
    guard case .failure(RTSPError.connectionFailed(let message)) = result else {
      Issue.record("expected connectionFailed, got \(result)")
      return
    }
    #expect(message.hasPrefix("TLS handshake failed: "), "got: \(message)")
  }
}

/// Expect `body` to throw `connectionFailed(message)`: the failure a
/// connection recorded is reported by every later send.
private func expectTLSFailure(
  _ message: String, sourceLocation: SourceLocation = #_sourceLocation,
  _ body: () async throws -> Void
) async {
  do {
    try await body()
    Issue.record("expected the recorded failure", sourceLocation: sourceLocation)
  } catch RTSPError.connectionFailed(let later) {
    #expect(later == message, sourceLocation: sourceLocation)
  } catch {
    Issue.record("expected connectionFailed, got \(error)", sourceLocation: sourceLocation)
  }
}
