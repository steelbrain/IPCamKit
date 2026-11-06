// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// RTSP over HTTP tunneling (QuickTime style) and the HTTP helpers it shares
// with the WebSocket transport.

import Foundation
import Network

// MARK: - HTTP endpoint

/// The host of a URL as `NWEndpoint.Host` takes it and a `Host` header names
/// it, for `HTTPEndpoint` and `rtspEndpoint(for:)`: an IP literal without its
/// brackets (a zone id percent-decoded: `fe80::1%en0`), and a registered name
/// in ASCII, with internationalized labels as IDNA A-labels
/// (`xn--caf-dma.example`). `URLComponents.host` decodes A-labels to Unicode
/// (`café.example`), which is not the name DNS or a certificate has.
/// Percent-encoded UTF-8 in a name is decoded and IDNA-encoded too
/// (RFC 3986 section 3.2.2). Nil when the URL has no host, a name with no
/// IDNA form, or a host with any other character than letters, digits, `-`,
/// `.` and `_` (an IPv6 address and its zone id aside): a decoded `%00` would
/// cut the name short where Network reads it, which would connect to, and
/// check the certificate against, a different host.
func asciiHost(of components: URLComponents) -> String? {
  // The host as the URL spells it, except that Foundation has already
  // IDNA-encoded a Unicode host.
  guard let encoded = components.encodedHost, !encoded.isEmpty else { return nil }
  if encoded.hasPrefix("[") {
    guard let literal = unbracketedHost(encoded).removingPercentEncoding else { return nil }
    let parts = literal.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
    guard IPv6Address(String(parts[0])) != nil,
      parts.count == 1
        || (!parts[1].isEmpty && parts[1].unicodeScalars.allSatisfy(isHostNameScalar))
    else { return nil }
    return literal
  }
  guard let decoded = encoded.removingPercentEncoding else { return nil }
  var name = decoded
  if !decoded.unicodeScalars.allSatisfy(\.isASCII) {
    var idna = URLComponents()
    idna.host = decoded
    // A name IDNA rejects comes back percent-encoded, which the check below
    // refuses.
    guard let ascii = idna.encodedHost else { return nil }
    name = ascii
  }
  guard name.unicodeScalars.allSatisfy(isHostNameScalar) else { return nil }
  return name
}

/// A letter, digit, `-`, `.` or `_`: what a host name (or a zone id) is made of.
private func isHostNameScalar(_ scalar: Unicode.Scalar) -> Bool {
  switch scalar {
  case "a"..."z", "A"..."Z", "0"..."9", "-", ".", "_": true
  default: false
  }
}

/// Where an `http(s)://` or `ws(s)://` URL points: what to connect to and what
/// to put in the request line and `Host` header.
struct HTTPEndpoint: Sendable, Equatable {
  /// Host for `NWEndpoint.Host`: an ASCII name (IDNA A-labels) or a bare
  /// (unbracketed) IP literal; see `asciiHost(of:)`.
  let host: String
  let port: UInt16
  let usesTLS: Bool
  /// Origin-form request target: the URL's path (or `/`) plus `?query`.
  let target: String
  /// `target` for error messages, with credential-like parameter values
  /// hidden (`redactingCredentialParameters`).
  var shownTarget: String { redactingCredentialParameters(target) }
  /// `Host` header value: the host (IPv6 bracketed) plus `:port` when the URL
  /// names one.
  let hostHeader: String

  /// Parse `url`, whose scheme must be `plainScheme` (default port 80) or
  /// `tlsScheme` (default port 443, TLS). Case-insensitive.
  init(url: URL, plainScheme: String, tlsScheme: String) throws {
    try checkAmbiguousUserInfo(url.absoluteString)
    // A URL relative to a base is read whole, as the checks above it read it.
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
      let host = asciiHost(of: components)
    else {
      throw RTSPError.invalidURL("Invalid URL: \(redactedURL(url.absoluteString))")
    }
    switch components.scheme?.lowercased() {
    case plainScheme: usesTLS = false
    case tlsScheme: usesTLS = true
    default:
      throw RTSPError.invalidURL(
        "Unsupported URL scheme in \(redactedURL(url.absoluteString)) (expected \(plainScheme):// or "
          + "\(tlsScheme)://)")
    }
    // A raw `@` after the host may end a password: `URL` re-encodes some
    // strings (`http://admin:/pw@[::1]/` becomes host `admin`, path
    // `/pw@%5B::1%5D/`), and the string as written can't be recovered to
    // check it. A tunnel URL's credentials aren't used, so `@` must be `%40`.
    let afterHost =
      components.percentEncodedPath + (components.percentEncodedQuery ?? "")
      + (components.percentEncodedFragment ?? "")
    guard !afterHost.contains("@") else {
      throw RTSPError.invalidURL(
        "Invalid URL (write @ after the host as %40): \(redactedURL(url.absoluteString))")
    }
    // A port too large for `Int` reads as no port, which would mean the
    // default one; an empty port (`host:`, `[::1]:`) does mean it.
    guard components.port != nil || components.rangeOfPort?.isEmpty != false else {
      throw RTSPError.invalidURL(
        "Invalid port in URL: \(redactedURL(url.absoluteString))")
    }
    let rawPort = components.port ?? (usesTLS ? 443 : 80)
    guard let port = UInt16(exactly: rawPort), port != 0 else {
      throw RTSPError.invalidURL(
        "Invalid port \(rawPort) in URL: \(redactedURL(url.absoluteString))")
    }
    self.port = port
    self.host = host

    let path = components.percentEncodedPath
    var target = path.isEmpty ? "/" : path
    if let query = components.percentEncodedQuery {
      target += "?\(query)"
    }
    // URLComponents never yields whitespace or control bytes in these parts,
    // but the target goes verbatim into a request line, so make sure.
    guard !target.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F })
    else {
      throw RTSPError.invalidURL(
        "Invalid request path in URL: \(redactedURL(url.absoluteString))")
    }
    self.target = target

    // A zone id has meaning only on this host and is not sent (RFC 6874
    // section 4); `host` keeps it for the connection's interface.
    let headerHost = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
    let bracketed = headerHost.contains(":") ? "[\(headerHost)]" : headerHost
    hostHeader = components.port == nil ? bracketed : "\(bracketed):\(port)"
  }
}

// MARK: - HTTP messages

/// The status line and headers of an HTTP response; the body is not read.
struct HTTPResponseHead: Sendable {
  let version: String
  let statusCode: Int
  let reasonPhrase: String
  let headers: [(String, String)]
  /// Indices into `headers` of values that weren't valid UTF-8 and were
  /// decoded as ISO Latin-1 instead (see `RTSPHeaderValue`).
  var latin1HeaderIndices: Set<Int> = []

  /// Largest header block accepted before the blank line that ends it.
  static let maxBytes = 64 * 1024
  /// Most header lines accepted (not counting the status line). Like the
  /// byte limit, it bounds the rescan of a head that arrives in small pieces.
  static let maxLines = 256

  /// Case-insensitive lookup of the first value of header `name`.
  func header(_ name: String) -> String? {
    let lowered = name.lowercased()
    return headers.first { $0.0.lowercased() == lowered }?.1
  }

  /// Case-insensitive lookup of every value of header `name`.
  func headers(named name: String) -> [String] {
    let lowered = name.lowercased()
    return headers.filter { $0.0.lowercased() == lowered }.map(\.1)
  }

  /// Every value of header `name`, marked when it was decoded as ISO Latin-1,
  /// for `RTSPAuthenticator.handleChallenges(_:)`.
  func headerValues(named name: String) -> [RTSPHeaderValue] {
    let lowered = name.lowercased()
    return headers.indices.compactMap { index in
      guard headers[index].0.lowercased() == lowered else { return nil }
      return RTSPHeaderValue(headers[index].1, isLatin1: latin1HeaderIndices.contains(index))
    }
  }

  /// `"HTTP 404 Not Found"`, for error messages.
  var statusDescription: String {
    reasonPhrase.isEmpty
      ? "HTTP \(statusCode)" : "HTTP \(statusCode) \(cutForMessage(reasonPhrase))"
  }

  /// Parse the response head at the front of `buffer` (which may be a slice).
  /// Returns `nil` until the blank line ending the head has arrived; otherwise
  /// the head and the number of bytes it occupied (including the blank line).
  /// Throws `RTSPError.connectionFailed` if the status line isn't HTTP.
  static func parse(_ buffer: Data) throws -> (head: HTTPResponseHead, length: Int)? {
    let end: Range<Int>
    switch RTSPParser().scanForBlankLine(
      in: buffer, limit: maxBytes, maxLineFeeds: maxLines + 1)
    {
    case .found(let range): end = range
    case .notFound: return nil
    case .tooManyLines:
      throw RTSPError.connectionFailed("HTTP response has more than \(maxLines) header lines")
    }
    // Split on LF, dropping the CRs before it (the blank line may follow
    // CR CR LF line endings). Each line is decoded as UTF-8, or as ISO
    // Latin-1 when it isn't valid UTF-8 (a GBK Digest realm), so a
    // challenge's bytes can be echoed exactly; the status line is decoded
    // leniently.
    var lineBytes = buffer[buffer.startIndex..<end.lowerBound]
      .split(separator: 0x0A, omittingEmptySubsequences: false)
      .map { line in
        var line = line
        while line.last == 0x0D { line = line.dropLast() }
        return line
      }
    guard !lineBytes.isEmpty else {
      throw RTSPError.connectionFailed("Empty HTTP response")
    }
    guard lineBytes.count <= maxLines + 1 else {
      throw RTSPError.connectionFailed("HTTP response has more than \(maxLines) header lines")
    }
    let statusLine = String(decoding: lineBytes.removeFirst(), as: UTF8.self)
    let lines = lineBytes.map { bytes -> (text: String, isLatin1: Bool) in
      if let text = String(bytes: bytes, encoding: .utf8) { return (text, false) }
      return (RTSPHeaderValue.latin1Text(bytes), true)
    }
    let parts = statusLine.split(
      maxSplits: 2, omittingEmptySubsequences: true,
      whereSeparator: { $0 == " " || $0 == "\t" })
    guard parts.count >= 2, parts[0].hasPrefix("HTTP/"),
      parts[1].count == 3, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
      let code = Int(parts[1])
    else {
      throw RTSPError.connectionFailed(
        "Server did not answer with HTTP: \(quotedForMessage(statusLine))")
    }
    var headers: [(String, String)] = []
    var latin1: Set<Int> = []
    // A line starting with SP or HT continues the previous header's value
    // (obsolete line folding), joined on after one space as the RTSP parser
    // does. One that follows the status line or a line without a colon is
    // dropped, like that line. Only spaces and tabs are trimmed, so a Latin-1
    // 0xA0 (a GBK lead byte) isn't taken for a no-break space.
    let blanks = CharacterSet(charactersIn: " \t")
    var lastLineIsHeader = false
    for (line, isLatin1) in lines {
      if let first = line.unicodeScalars.first, first == " " || first == "\t" {
        let continuation = line.trimmingCharacters(in: blanks)
        if lastLineIsHeader, !continuation.isEmpty {
          let last = headers.count - 1
          if isLatin1 && !latin1.contains(last) {
            // Mixed encodings: Latin-1 for the whole value, so no byte is lost.
            headers[last].1 = RTSPHeaderValue.latin1Text(Data(headers[last].1.utf8))
            latin1.insert(last)
          }
          let piece =
            latin1.contains(last) && !isLatin1
            ? RTSPHeaderValue.latin1Text(Data(continuation.utf8)) : continuation
          headers[last].1 = headers[last].1.isEmpty ? piece : headers[last].1 + " " + piece
        }
        continue
      }
      lastLineIsHeader = false
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[line.startIndex..<colon].trimmingCharacters(in: blanks)
      let value = line[line.index(after: colon)...].trimmingCharacters(in: blanks)
      if isLatin1 { latin1.insert(headers.count) }
      headers.append((name, value))
      lastLineIsHeader = true
    }
    var head = HTTPResponseHead(
      version: String(parts[0]), statusCode: code,
      reasonPhrase: parts.count >= 3 ? String(parts[2]) : "", headers: headers)
    head.latin1HeaderIndices = latin1
    return (head, end.upperBound - buffer.startIndex)
  }
}

/// Serialize an HTTP request head: request line, `headers` in order, blank
/// line.
func httpRequestHead(
  method: String, target: String, version: String, headers: [(String, String)],
  authorization: RTSPHeaderValue? = nil
) -> Data {
  // Control characters can't end a line early and add a header.
  func clean(_ text: String) -> String {
    String(
      String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
  }
  var text = "\(clean(method)) \(clean(target)) \(clean(version))\r\n"
  for (name, value) in headers {
    text += "\(clean(name)): \(clean(value))\r\n"
  }
  var head = Data(text.utf8)
  if let authorization {
    // In the bytes the challenge used (Latin-1 or UTF-8), without control
    // characters.
    head.append(Data("Authorization: ".utf8))
    head.append(authorization.bytes.filter { $0 >= 0x20 && $0 != 0x7F })
    head.append(Data("\r\n".utf8))
  }
  head.append(Data("\r\n".utf8))
  return head
}

/// `value` with every control character removed, so a caller-supplied string
/// (e.g. a User-Agent) can't inject header lines.
func sanitizedHeaderValue(_ value: String) -> String {
  String(
    String.UnicodeScalarView(value.unicodeScalars.filter { $0.value >= 0x20 && $0 != "\u{7F}" }))
}

/// A random token of `length` ASCII letters and digits from the system CSPRNG.
func randomAlphanumericToken(length: Int) -> String {
  let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
  var generator = SystemRandomNumberGenerator()
  let bytes = (0..<length).map { _ in
    alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]
  }
  return String(decoding: bytes, as: UTF8.self)
}

/// Read an HTTP response head from `connection`. Returns the head and the
/// bytes that followed it. `what` names the request in error messages.
func readHTTPResponseHead(
  from connection: WatchedConnection, what: String
) async throws -> (head: HTTPResponseHead, rest: Data) {
  var buffer = Data()
  while true {
    if let (head, length) = try HTTPResponseHead.parse(buffer) {
      return (head, Data(buffer[(buffer.startIndex + length)...]))
    }
    guard buffer.count <= HTTPResponseHead.maxBytes else {
      throw RTSPError.connectionFailed(
        "\(what): HTTP response header exceeded \(HTTPResponseHead.maxBytes) bytes")
    }
    guard let chunk = try await connection.receive() else {
      throw RTSPError.connectionFailed(
        "\(what): server closed the connection before sending an HTTP response")
    }
    buffer.append(chunk)
  }
}

/// Send the request `makeRequest` builds on a new connection to `endpoint` and
/// read the response head. On a `401` with `credentials`, retry on another new
/// connection with the `Authorization` the challenge calls for (method
/// `method`, URI `endpoint.target`), and once more when that retry is refused
/// with `stale=true` and a new nonce. If a Digest answer is rejected otherwise
/// and the server offered Basic on any of the 401s, retry once more with
/// Basic, which the returned authenticator then keeps using (some cameras
/// advertise Digest but only accept Basic, as the RTSP request path also
/// handles). Credentials are never sent again in a form already refused.
///
/// Returns the connection, the final response head (any status but 401), the
/// bytes received after it, and the authenticator primed with the challenge
/// (nil if the server never asked for credentials). Throws
/// `RTSPError.authenticationFailed` on a 401 without credentials or a usable
/// challenge, or when the retries are rejected too.
func exchangeHTTPWithAuthRetry(
  endpoint: HTTPEndpoint, tls: TLSOptions, opener: ConnectionOpener,
  credentials: Credentials?, method: String, what: String,
  makeRequest: (_ authorization: RTSPHeaderValue?) -> Data
) async throws -> (
  connection: WatchedConnection, head: HTTPResponseHead, rest: Data,
  authenticator: RTSPAuthenticator?
) {
  var authenticator: RTSPAuthenticator?
  var authorization: RTSPHeaderValue?
  // What the last request carried, how many challenge answers were sent, and
  // whether Basic was refused (then it isn't the fallback).
  var sent = RTSPAuthenticator.Sent.none
  var retries = 0
  var basicRefused = false
  while true {
    let connection = try await opener.open(
      host: endpoint.host, port: endpoint.port, tls: endpoint.usesTLS ? tls : nil)
    let response: (head: HTTPResponseHead, rest: Data)
    do {
      try await connection.send(makeRequest(authorization))
      response = try await readHTTPResponseHead(from: connection, what: what)
    } catch {
      connection.cancel()
      opener.attempt.untrack(connection.nwConnection)
      throw error
    }
    guard response.head.statusCode == 401 else {
      return (connection, response.head, response.rest, authenticator)
    }
    connection.cancel()
    opener.attempt.untrack(connection.nwConnection)
    guard let credentials else { throw RTSPError.authenticationFailed }
    var auth = authenticator ?? RTSPAuthenticator(credentials: credentials)
    if sent == .basic { basicRefused = true }
    // Every challenge of the response at once (Basic and Digest may come on
    // separate lines), so Digest wins regardless of order.
    auth.handleChallenges(response.head.headerValues(named: "WWW-Authenticate"))
    if auth.retries(afterRejecting: sent),
      retries == 0 || (retries == 1 && auth.digestIsStale && auth.sending != sent)
    {
      let sending = auth.sending
      guard let header = auth.authorizationHeader(method: method, uri: endpoint.target) else {
        throw RTSPError.authenticationFailed
      }
      retries += 1
      sent = sending
      authenticator = auth
      authorization = header
      continue
    }
    // A refused Digest falls back to Basic once, when Basic was offered and
    // not refused already.
    guard case .digest = sent, !basicRefused, auth.usesDigest,
      let header = auth.authorizeBasicFallback()
    else {
      throw RTSPError.authenticationFailed
    }
    sent = .basic
    authenticator = auth
    authorization = RTSPHeaderValue(header)
  }
}

// MARK: - HTTP tunnel

/// RTSP over HTTP tunneling, as in Apple's "Tunnelling RTSP and RTP through
/// HTTP" (QuickTime Streaming Server).
///
/// Two HTTP/1.0 connections share a random `x-sessioncookie`:
/// 1. `GET`: the server answers `200 OK` (`application/x-rtsp-tunnelled`) and
///    then streams raw RTSP responses and `$` interleaved frames as the
///    response body. Bytes after the header block belong to that stream.
/// 2. `POST`: its body carries every client-to-server message base64-encoded,
///    each `send` encoded on its own. The POST is sent only after the GET has
///    been accepted, because servers pair the POST with an existing GET by
///    cookie. Anything the server sends back on it (nothing, an HTTP 200
///    header block, or a close) is read and discarded, except an error status
///    or a failure of the connection, which ends the tunnel.
enum HTTPTunnel {
  /// Media type of the tunnel's GET response and POST request bodies.
  static let contentType = "application/x-rtsp-tunnelled"
  /// The POST's nominal `Content-Length`. QuickTime clients announce this value
  /// and keep sending past it; mediamtx accepts that (see LiveTunnelTests).
  static let postContentLength = 32767
  /// Length of the random `x-sessioncookie`.
  static let cookieLength = 32

  /// The tunnel GET request head.
  static func getRequest(
    endpoint: HTTPEndpoint, cookie: String, userAgent: String?, authorization: RTSPHeaderValue?
  ) -> Data {
    var headers: [(String, String)] = [("Host", endpoint.hostHeader)]
    if let userAgent { headers.append(("User-Agent", userAgent)) }
    headers += [
      ("x-sessioncookie", cookie),
      ("Accept", contentType),
      ("Pragma", "no-cache"),
      ("Cache-Control", "no-cache"),
    ]
    return httpRequestHead(
      method: "GET", target: endpoint.target, version: "HTTP/1.0", headers: headers,
      authorization: authorization)
  }

  /// The tunnel POST request head.
  static func postRequest(
    endpoint: HTTPEndpoint, cookie: String, userAgent: String?, authorization: RTSPHeaderValue?
  ) -> Data {
    var headers: [(String, String)] = [("Host", endpoint.hostHeader)]
    if let userAgent { headers.append(("User-Agent", userAgent)) }
    headers += [
      ("x-sessioncookie", cookie),
      ("Content-Type", contentType),
      ("Pragma", "no-cache"),
      ("Cache-Control", "no-cache"),
      ("Content-Length", "\(postContentLength)"),
      ("Expires", "Sun, 9 Jan 1972 00:00:00 GMT"),
    ]
    return httpRequestHead(
      method: "POST", target: endpoint.target, version: "HTTP/1.0", headers: headers,
      authorization: authorization)
  }

  /// Open the GET and POST connections for `url` (`http://` or `https://`).
  static func connect(
    url: URL, tls: TLSOptions, credentials: Credentials?, userAgent: String?,
    opener: ConnectionOpener
  ) async throws -> EstablishedStream {
    let endpoint = try HTTPEndpoint(url: url, plainScheme: "http", tlsScheme: "https")
    let cookie = randomAlphanumericToken(length: cookieLength)
    let agent = userAgent.map(sanitizedHeaderValue).flatMap { $0.isEmpty ? nil : $0 }

    let get = try await exchangeHTTPWithAuthRetry(
      endpoint: endpoint, tls: tls, opener: opener, credentials: credentials, method: "GET",
      what: "HTTP tunnel GET \(endpoint.shownTarget)"
    ) { authorization in
      getRequest(endpoint: endpoint, cookie: cookie, userAgent: agent, authorization: authorization)
    }
    guard get.head.statusCode == 200 else {
      get.connection.cancel()
      throw RTSPError.connectionFailed(
        "HTTP tunnel GET \(endpoint.shownTarget) failed: \(get.head.statusDescription)")
    }

    var authenticator = get.authenticator
    let postAuthorization = authenticator?.authorizationHeader(
      method: "POST", uri: endpoint.target)
    let post: WatchedConnection
    do {
      post = try await opener.open(
        host: endpoint.host, port: endpoint.port, tls: endpoint.usesTLS ? tls : nil)
    } catch {
      get.connection.cancel()
      throw error
    }
    let stream = HTTPTunnelByteStream(getConnection: get.connection, postConnection: post)
    do {
      try await post.send(
        postRequest(
          endpoint: endpoint, cookie: cookie, userAgent: agent, authorization: postAuthorization))
    } catch {
      stream.cancel()
      throw error
    }
    stream.startDrainingPost()
    return EstablishedStream(
      stream: stream, initialBytes: get.rest, primary: get.connection.nwConnection)
  }
}

/// The byte stream of an open HTTP tunnel: reads the GET response body, sends
/// base64 on the POST body.
final class HTTPTunnelByteStream: RTSPByteStream {
  let getConnection: WatchedConnection
  let postConnection: WatchedConnection
  private let postMonitor: TunnelPostMonitor

  init(getConnection: WatchedConnection, postConnection: WatchedConnection) {
    self.getConnection = getConnection
    self.postConnection = postConnection
    // Once the POST has failed, nothing more can reach the server: end a
    // pending GET read too, so the reader fails at once with the cause.
    postMonitor = TunnelPostMonitor { getConnection.cancel() }
  }

  /// Read and discard whatever the server sends on the POST connection,
  /// watching it for an error status or a hard failure.
  func startDrainingPost() {
    postMonitor.drain(postConnection)
  }

  func send(_ data: Data) async throws {
    if let failure = postMonitor.failure {
      throw failure
    }
    do {
      try await postConnection.send(data.base64EncodedData())
    } catch {
      // Prefer the root cause (e.g. the POST was rejected) when there is one.
      throw postMonitor.failure ?? error
    }
  }

  func receive() async throws -> Data {
    // A failed POST ends the GET read (see init); report why.
    let data: Data?
    do {
      data = try await getConnection.receive()
    } catch {
      throw postMonitor.failure ?? error
    }
    guard let data else {
      throw postMonitor.failure ?? RTSPError.unexpectedDisconnection
    }
    return data
  }

  func cancel() {
    postMonitor.markCancelled()
    getConnection.cancel()
    postConnection.cancel()
  }
}

/// Reads the tunnel POST connection, which carries nothing the client needs.
/// A server may answer the POST with an HTTP header block, say nothing, or
/// close it. A non-2xx status or a read error, though, means sends can no
/// longer reach the server, so it is recorded: it fails later sends, and
/// `onFailure` runs once so the stream can end its reads too.
///
/// State is guarded by `lock`, hence `@unchecked Sendable`.
final class TunnelPostMonitor: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedFailure: RTSPError?
  private var cancelled = false
  /// The response's first bytes, kept until its status is known.
  private var head = Data()
  private var headChecked = false
  /// Runs once, outside the lock, when the first failure is recorded (never
  /// after `markCancelled()`).
  private let onFailure: @Sendable () -> Void

  init(onFailure: @escaping @Sendable () -> Void = {}) {
    self.onFailure = onFailure
  }

  /// Why sends must fail, if the POST connection broke.
  var failure: RTSPError? {
    lock.lock()
    defer { lock.unlock() }
    return recordedFailure
  }

  /// The stream is being torn down: errors from here on are expected.
  func markCancelled() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  /// Keep reading `connection` until it closes or fails.
  func drain(_ connection: WatchedConnection) {
    connection.nwConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [self] content, _, isComplete, error in
      if let error {
        // A failure of the connection itself (e.g. TLS) names the cause better.
        record(
          connection.failure(after: error)
            ?? .connectionFailed(
              "HTTP tunnel POST connection failed: \(error.localizedDescription)",
              underlying: error))
        return
      }
      if let content, !content.isEmpty {
        connection.noteDataReceived()
        inspect(content)
      }
      // A server closing its side of the POST is harmless; a send on a fully
      // closed connection fails on its own.
      if !isComplete {
        drain(connection)
      }
    }
  }

  private func record(_ error: RTSPError) {
    lock.lock()
    let isFirst = !cancelled && recordedFailure == nil
    if isFirst {
      recordedFailure = error
    }
    lock.unlock()
    if isFirst { onFailure() }
  }

  /// Check the start of the POST response for an HTTP error status. Anything
  /// that isn't an HTTP response head is ignored.
  private func inspect(_ content: Data) {
    lock.lock()
    guard !headChecked else {
      lock.unlock()
      return
    }
    // Only the first 64 KiB can hold the head; a body after it may be larger.
    head.append(content.prefix(max(0, HTTPResponseHead.maxBytes - head.count)))
    let prefix = Data("HTTP/".utf8)
    let parsed: (head: HTTPResponseHead, length: Int)?
    if !head.starts(with: prefix.prefix(head.count)) {
      parsed = nil
      headChecked = true
    } else {
      do {
        parsed = try HTTPResponseHead.parse(head)
        // Without a complete head in 64 KiB there is none to find.
        if parsed != nil || head.count >= HTTPResponseHead.maxBytes { headChecked = true }
      } catch {
        parsed = nil
        headChecked = true
      }
    }
    if headChecked { head = Data() }
    lock.unlock()

    guard let response = parsed?.head, !(200..<300).contains(response.statusCode) else { return }
    record(
      response.statusCode == 401
        ? .authenticationFailed
        : .connectionFailed("HTTP tunnel POST rejected: \(response.statusDescription)"))
  }
}
