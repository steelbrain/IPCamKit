// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Unit tests for URL host normalization (IPv6 bracket stripping, IDNA).

import Foundation
import Network
import Testing

@testable import IPCamKit

@Suite("URL host parsing")
struct URLHostTests {

  @Test("Strips brackets from an IPv6 literal host")
  func stripsIPv6Brackets() {
    #expect(unbracketedHost("[::1]") == "::1")
    #expect(unbracketedHost("[2001:db8::1]") == "2001:db8::1")
  }

  @Test("Preserves the zone id inside a link-local IPv6 host")
  func preservesZoneId() {
    #expect(unbracketedHost("[fe80::1%en0]") == "fe80::1%en0")
  }

  @Test("Leaves IPv4 and hostname hosts unchanged")
  func leavesNonBracketedUnchanged() {
    #expect(unbracketedHost("127.0.0.1") == "127.0.0.1")
    #expect(unbracketedHost("camera.local") == "camera.local")
    // A bare IPv6 literal (no brackets) is already in NWEndpoint.Host form.
    #expect(unbracketedHost("::1") == "::1")
  }

  @Test("Does not mangle a host with only one bracket")
  func toleratesUnbalancedBrackets() {
    #expect(unbracketedHost("[::1") == "[::1")
    #expect(unbracketedHost("::1]") == "::1]")
  }

  @Test(
    "RTSP and tunnel URLs connect to IDNA A-labels or a bare IP literal",
    .timeLimit(.minutes(1)),
    arguments: [
      // URLComponents.host decodes the first three to "café.example".
      ("xn--caf-dma.example", "xn--caf-dma.example"),
      ("café.example", "xn--caf-dma.example"),
      ("caf%C3%A9.example", "xn--caf-dma.example"),
      ("ex%61mple.com", "example.com"),
      ("Camera.Local", "Camera.Local"),
      ("192.168.1.10:8554", "192.168.1.10"),
      ("[::1]", "::1"),
      ("[2001:db8::1]:8554", "2001:db8::1"),
      ("user:p%40ss@[fe80::1%25en0]:554", "fe80::1%en0"),
    ])
  func endpointHosts(_ authority: String, _ expected: String) throws {
    let rtsp = try rtspEndpoint(for: "rtsp://\(authority)/live")
    #expect(rtsp.host == expected)
    let http = try HTTPEndpoint(
      url: try #require(URL(string: "http://\(authority)/live")),
      plainScheme: "http", tlsScheme: "https")
    #expect(http.host == expected)
    // What the connection hands Network framework: an ASCII name or an address.
    switch NWEndpoint.Host(rtsp.host) {
    case .name(let name, _):
      #expect(name.unicodeScalars.allSatisfy { $0.isASCII }, "\(name)")
      #expect(!expected.contains(":"))
    case .ipv4, .ipv6:
      #expect(expected.contains(".") || expected.contains(":"))
    @unknown default:
      Issue.record("unexpected NWEndpoint.Host for \(rtsp.host)")
    }
  }

  @Test("A link-local zone id reaches NWEndpoint.Host as the interface", .timeLimit(.minutes(1)))
  func zoneReachesEndpoint() throws {
    let endpoint = try rtspEndpoint(for: "rtsp://[fe80::1%25lo0]:554/x")
    guard case .ipv6(let address) = NWEndpoint.Host(endpoint.host) else {
      Issue.record("not an IPv6 address: \(endpoint.host)")
      return
    }
    #expect(address.interface?.name == "lo0")
  }

  @Test(
    "A name with no IDNA form, or broken percent-encoding, is rejected", .timeLimit(.minutes(1)))
  func hostWithoutASCIIForm() {
    // A 70-character label is 140 octets of UTF-8 and longer than DNS allows.
    let longLabel = String(repeating: "%C3%A9", count: 70)
    for url in ["rtsp://\(longLabel).example/x", "rtsp://caf%C3.example/x", "rtsp:///x"] {
      #expect(throws: RTSPError.self, "\(url)") { _ = try rtspEndpoint(for: url) }
    }
  }

  @Test(
    "The request line is ASCII: a Unicode host as its xn-- form, a Unicode path percent-encoded",
    arguments: [
      ("rtsp://café.example:554/live", "rtsp://xn--caf-dma.example:554/live"),
      ("rtsp://Büro-Kamera.local/stream", "rtsp://xn--bro-kamera-9db.local/stream"),
      ("rtsp://CAFÉ.example:8554/stream", "rtsp://xn--caf-dma.example:8554/stream"),
      ("rtsp://ＣＡＭ.example/a", "rtsp://cam.example/a"),
      ("rtsp://caf%C3%A9.example/live", "rtsp://xn--caf-dma.example/live"),
      ("rtsp://１２７.０.０.１:554/a", "rtsp://127.0.0.1:554/a"),
      ("rtsp://192.168.1.10/caméra", "rtsp://192.168.1.10/cam%C3%A9ra"),
      ("rtsp://xn--caf-dma.example/live?x=[1]", "rtsp://xn--caf-dma.example/live?x=[1]"),
      ("rtsp://[fe80::1%25lo0]/live", "rtsp://[fe80::1%25lo0]/live"),
    ])
  func requestLineHost(_ input: String, _ expected: String) {
    #expect(asciiURL(input) == expected)
  }

  @Test(
    "A user:password@ with a raw / ? # or @ is rejected; other @ placements are not",
    arguments: [
      ("rtsp://admin:12345/abc@192.168.1.10/stream", true),
      ("rtsp://admin:pa/ss:x@192.168.1.10/stream", true),
      // A `:` anywhere between the host and an `@` may be a password's.
      ("rtsp://nvr/replay?start=10:00:00&user=bob@site", true),
      ("rtsp://cam/live/a:b@c", true),
      ("rtsp://nvr/replay?start=10:00:00&user=bob%40site", false),
      ("rtsp://nvr/replay?start=10:00:00", false),
      ("rtsp://ops/cam:a/b@192.0.2.10/stream", true),
      ("rtsp://ops?x:a/b@192.0.2.10/stream", true),
      ("rtsp://ops/cam:a?b@192.0.2.10/stream", true),
      ("rtsp://a/b/c:pw@192.0.2.10/stream", true),
      ("rtsp://[::1]:8554/u:s3/cret@cam.invalid/stream", true),
      // A raw @ before the raw /: Foundation finds a short user:password@.
      ("rtsp://admin:p@ss/1@cam.example/stream", true),
      ("rtsp://me@mail.example:1234/x@cam.example/stream", true),
      ("rtsp://admin:p@ss?1@cam.example/stream", true),
      ("rtsp://u:p@cam.example/live@main", true),
      ("rtsp://u:p@cam.example/live%40main", false),
      // A user name with a raw / ? or #, then its password.
      ("rtsp://corp/alice:s3cret@cam.example/stream", true),
      ("rtsp://127.0.0.1?ops:s3cret@cam.invalid/stream", true),
      ("rtsp://127.0.0.1#ops:s3cret@cam.invalid/stream", true),
      // ... with a raw @ in the user name as well: the last @ counts.
      ("rtsp://svc/cam@REALM:pw123@10.0.0.5/live", true),
      ("rtsp://dom?alice@x:pw123@cam/", true),
      // An @ that a combining mark follows is still an @ to URLComponents.
      ("rtsp://corp/alice:s3cret@\u{301}cam.example/stream", true),
      ("rtsp://cam.example:554/live@\u{301}main", true),
      // An IPv6 literal with a port can't be read as a password's start.
      ("rtsp://[::1]:8554/a@b", false),
      ("rtsp://admin:12?3@192.168.1.10/stream", true),
      ("rtsp://admin:12#3@192.168.1.10/stream", true),
      ("rtsp://admin:12%2F3@192.168.1.10/stream", false),
      ("rtsp://cam.example/live@main", false),
      ("rtsp://[fe80::1%25lo0]:554/live@main", false),
      ("rtsp://cam.example:554/stream", false),
    ])
  func unparsedUserInfo(_ url: String, _ rejected: Bool) {
    let threw = (try? checkAmbiguousUserInfo(url)) == nil
    #expect(threw == rejected)
    // Tunnel URLs are checked the same way (when `URL` takes them at all).
    let http = url.replacingOccurrences(of: "rtsp://", with: "http://")
    guard rejected, let tunnelURL = URL(string: http) else { return }
    #expect(throws: RTSPError.self, "\(http)") {
      _ = try HTTPEndpoint(url: tunnelURL, plainScheme: "http", tlsScheme: "https")
    }
  }

  @Test("A tunnel URL relative to a base URL is read whole")
  func relativeTunnelURL() throws {
    let url = try #require(
      URL(string: "/tunnel", relativeTo: URL(string: "http://127.0.0.1:8080/")))
    let endpoint = try HTTPEndpoint(url: url, plainScheme: "http", tlsScheme: "https")
    #expect(endpoint.host == "127.0.0.1")
    #expect(endpoint.port == 8080)
    #expect(endpoint.target == "/tunnel")
  }

  /// `URL` re-encodes some strings so their user name becomes the host
  /// (`http://admin:/S3cret@[::1]/` is host `admin`, path `/S3cret@%5B…`); a
  /// raw `@` after a tunnel URL's host is rejected so none of them pass.
  @Test(
    "A tunnel URL with a raw @ after its host is rejected",
    arguments: [
      ("http://admin:/S3cret@[fe80::1%25en0]/stream", true),
      ("https://admin:/S3cret@[2001:db8::7]:8443/rtsp", true),
      ("ws://admin:?S3cret@[::1]/x", true),
      ("http://127.0.0.1:/S3cret@[::1]/stream", true),
      ("http://127.0.0.1/live@main", true),
      ("http://127.0.0.1/x#a@b", true),
      ("http://127.0.0.1/live%40main", false),
      ("http://user:pw@127.0.0.1/live", false),
    ])
  func tunnelRawAt(_ text: String, _ rejected: Bool) throws {
    let url = try #require(URL(string: text))
    let isWebSocket = text.hasPrefix("ws")
    do {
      _ = try HTTPEndpoint(
        url: url, plainScheme: isWebSocket ? "ws" : "http", tlsScheme: isWebSocket ? "wss" : "https"
      )
      #expect(!rejected, "\(url.absoluteString)")
    } catch {
      #expect(rejected, "\(error)")
      #expect(!"\(error)".contains("S3cret"), "\(error)")
    }
  }

  /// The endpoint error named the URL after its fragment was cut or its `＠`
  /// percent-encoded, so `redactedURL` found no `@` and showed the password.
  @Test(
    "start() errors for a URL without // don't show the password",
    .timeLimit(.minutes(1)),
    arguments: [
      "rtsp:admin:pa#ss@192.0.2.10/stream", "rtsp:admin:Secret\u{FF20}192.0.2.10/stream",
      "rtsp:admin:Secret\u{FE6B}192.0.2.10/stream",
    ])
  func noSlashURLErrorRedacted(_ url: String) async {
    do {
      _ = try await RTSPClientSession(url: url).start()
      Issue.record("start() should fail")
    } catch {
      let text = "\(error)"
      #expect(!text.contains("admin"), "\(text)")
      #expect(!text.contains("Secret") && !text.contains("pa#") && !text.contains(":pa"), "\(text)")
    }
  }

  /// A `%00` cut the host short where Network reads it: the session connected
  /// to `127.0.0.1` for `127.0.0.1%00.invalid`.
  @Test(
    "A host with a percent-encoded control character or other punctuation is rejected",
    arguments: [
      "rtsp://127.0.0.1%00.invalid/stream", "rtsps://localhost%00.cams.example/stream",
      "rtsp://cam%20era.example/stream", "rtsp://[fe80::1%25lo%000]/stream",
      "rtsp://[fe80::1%25]/stream", "rtsp://cam%2Fx.example/stream",
    ])
  func hostControlCharacters(_ url: String) {
    #expect(throws: RTSPError.self, "\(url)") { _ = try rtspEndpoint(for: url) }
    let http = url.replacingOccurrences(of: "rtsps://", with: "https://")
      .replacingOccurrences(of: "rtsp://", with: "http://")
    if let tunnelURL = URL(string: http) {
      #expect(throws: RTSPError.self, "\(http)") {
        _ = try HTTPEndpoint(url: tunnelURL, plainScheme: "http", tlsScheme: "https")
      }
    }
  }

  @Test("A URL's #fragment isn't sent", .timeLimit(.minutes(1)))
  func fragmentNotSent() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: server.url + "#frag")
    _ = try await session.start()
    let urls = server.requests.map(\.url)
    #expect(!urls.isEmpty && urls.allSatisfy { !$0.contains("#") }, "\(urls)")
    await session.stop()
  }

  @Test("A URL without // still has its password redacted from errors", .timeLimit(.minutes(1)))
  func passwordRedactedWithoutSlashes() async {
    #expect(redactedURL("rtsp:admin:s3cret@cam/x") == "rtsp:***@cam/x")
    #expect(redactedURL("rtsp:/admin:s3cret@cam/x") == "rtsp:***@cam/x")
    // A `://` inside the password isn't the scheme's.
    #expect(redactedURL("rtsp:admin:se://cret@cam/x") == "rtsp:***@cam/x")
    #expect(redactedURL("rtsp:/admin:se://cret@cam/x") == "rtsp:***@cam/x")
    #expect(redactedURL("rtsp://admin:se://cret@cam/x") == "rtsp://***@cam/x")
    #expect(redactedURL("rtsp:admin:s3cret@cam/x?next=http://a") == "rtsp:***@cam/x?next=http://a")
    for url in ["rtsp:admin:s3cret@cam.invalid/stream", "rtsp:/admin:s3cret@cam.invalid/stream"] {
      let session = RTSPClientSession(url: url)
      let result = await outcome { try await session.start() }
      guard case .failure(let error) = result else {
        Issue.record("\(url) was accepted")
        continue
      }
      #expect(!"\(error)".contains("s3cret"), "\(error)")
    }
  }

  @Test("A %00 host isn't connected to", .timeLimit(.minutes(1)))
  func nulHostNotConnected() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: "rtsp://127.0.0.1%00.invalid:\(server.port)/stream")
    _ = await outcome { try await session.start() }
    #expect(server.requests.isEmpty)
    await session.stop()
  }

  /// `user` 127.0.0.1, password `<port>/abc`: Foundation reads the URL as
  /// host 127.0.0.1 and that port, which is the fake server's.
  @Test("A password with a raw / isn't sent to the host named by the user name")
  func rawSlashPasswordNotSent() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    try await server.start()
    defer { server.stop() }
    let session = RTSPClientSession(url: "rtsp://127.0.0.1:\(server.port)/abc@cam.invalid/stream")
    do {
      _ = try await session.start()
      Issue.record("start() succeeded")
    } catch RTSPError.connectionFailed(let message) {
      #expect(message.contains("%2F"), "\(message)")
      #expect(!message.contains("abc"), "\(message)")
    }
    #expect(server.requests(method: "OPTIONS").isEmpty)
    await session.stop()
  }
}
