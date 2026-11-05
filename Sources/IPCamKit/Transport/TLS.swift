// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// TLS (RTSPS) settings and server-certificate verification for the RTSP
// control connection.

import CryptoKit
import Foundation
import Network
import Security

/// TLS settings for `rtsps://` URLs and for `https://` and `wss://` tunnels.
///
/// An `rtsps://` URL runs the RTSP control connection over TLS. With
/// `Transport.tcp` RTP/RTCP is interleaved on that connection, so the media is
/// encrypted too; with `.udp` or `.multicast` the media is SRTP, keyed through
/// the TLS connection. An `https://` or `wss://` tunnel is verified with these
/// options whatever the RTSP URL's scheme. They are unused for a plain
/// `rtsp://` URL without such a tunnel.
public struct TLSOptions: Sendable {
  /// How the server's certificate is verified during the TLS handshake.
  public enum ServerTrust: Sendable {
    /// The platform's default evaluation: the certificate chain must lead to a
    /// root the system trusts, every certificate must be within its validity
    /// period, and the leaf must name the URL host (DNS name or IP address;
    /// without the zone id of a link-local IPv6 address such as `fe80::1%en0`).
    /// A camera's self-signed certificate fails this check unless it has been
    /// added to the system's trusted certificates.
    case system

    /// Accept the server only if its leaf certificate's SHA-256 fingerprint
    /// equals one of these. The chain, validity dates, and host name are not
    /// checked; the fingerprint alone identifies the server. Use this for
    /// cameras with self-signed certificates.
    case pinned([CertificateFingerprint])

    /// Decide in your own code. The closure receives the server's `SecTrust`
    /// (the presented certificates, with an SSL policy for the URL host,
    /// without the zone id of a link-local IPv6 address) and returns whether
    /// to continue the handshake. It runs synchronously on a private serial
    /// queue (not the main thread), so it may call `SecTrustEvaluateWithError`.
    /// The 15-second connect timeout keeps running while it executes.
    case custom(@Sendable (SecTrust) -> Bool)
  }

  /// How the server's certificate is verified. Defaults to `.system`.
  public var serverTrust: ServerTrust

  public init(serverTrust: ServerTrust = .system) {
    self.serverTrust = serverTrust
  }

  /// System trust evaluation (`ServerTrust.system`).
  public static let `default` = TLSOptions()
}

/// The SHA-256 digest of a DER-encoded X.509 certificate: the value
/// `openssl x509 -noout -fingerprint -sha256` prints.
public struct CertificateFingerprint: Sendable, Hashable, CustomStringConvertible {
  /// The 32 digest bytes.
  public let sha256: Data

  /// Wrap raw digest bytes. Returns `nil` unless `sha256` is exactly 32 bytes.
  public init?(sha256: Data) {
    guard sha256.count == SHA256.byteCount else { return nil }
    self.sha256 = Data(sha256)
  }

  /// Parse a hex digest such as `"09:1B:14:…"` (openssl's format) or
  /// `"091b14…"`. Case-insensitive; colons and whitespace between digits are
  /// ignored. Returns `nil` unless the rest is exactly 64 hex digits.
  public init?(hex: String) {
    var bytes = Data()
    bytes.reserveCapacity(SHA256.byteCount)
    var high: UInt8?
    for ch in hex.unicodeScalars {
      if ch == ":" || CharacterSet.whitespacesAndNewlines.contains(ch) { continue }
      guard let nibble = hexNibble(ch) else { return nil }
      if let h = high {
        bytes.append(h << 4 | nibble)
        high = nil
      } else {
        high = nibble
      }
    }
    guard high == nil else { return nil }
    self.init(sha256: bytes)
  }

  /// The fingerprint of `certificate` (SHA-256 over its DER encoding).
  public init(certificate: SecCertificate) {
    let der = SecCertificateCopyData(certificate) as Data
    self.sha256 = Data(SHA256.hash(data: der))
  }

  /// Colon-separated uppercase hex, the format openssl prints.
  public var description: String {
    sha256.map { String(format: "%02X", $0) }.joined(separator: ":")
  }
}

/// The value of one hex digit, or `nil` if `ch` is not `[0-9A-Fa-f]`.
private func hexNibble(_ ch: Unicode.Scalar) -> UInt8? {
  switch ch.value {
  case 0x30...0x39: return UInt8(ch.value - 0x30)  // 0-9
  case 0x41...0x46: return UInt8(ch.value - 0x41 + 10)  // A-F
  case 0x61...0x66: return UInt8(ch.value - 0x61 + 10)  // a-f
  default: return nil
  }
}

extension TLSOptions {
  /// Network framework TLS options that apply `serverTrust` to a connection
  /// to `host` (the host as `NWEndpoint.Host` takes it).
  ///
  /// `.system` leaves Network's default evaluation in place, except for a host
  /// with a zone id (below). `.pinned` and `.custom` install a verify block,
  /// which replaces that evaluation; it runs on `verifyQueue`, kept separate
  /// from the connection's queue so a slow custom evaluator cannot delay the
  /// connect timeout scheduled there.
  ///
  /// For an IPv6 host with a zone id (`fe80::1%en0`), Network's SSL policy
  /// names the host zone included, which no certificate matches. A zone has
  /// meaning only on this host (RFC 6874), so the verify block replaces the
  /// policy with one for the address alone, and `.system` gets a verify block
  /// too, which evaluates the trust with that policy.
  func makeProtocolOptions(host: String, verifyQueue: DispatchQueue) -> NWProtocolTLS.Options {
    let options = NWProtocolTLS.Options()
    let unzonedHost = hostWithoutZone(host)
    let evaluate: (@Sendable (SecTrust) -> Bool)?
    switch serverTrust {
    case .system:
      if unzonedHost == nil {
        evaluate = nil
      } else {
        evaluate = { SecTrustEvaluateWithError($0, nil) }
      }
    case .pinned(let pins):
      evaluate = { leafCertificateMatches($0, pins: pins) }
    case .custom(let custom):
      evaluate = custom
    }
    if let evaluate {
      sec_protocol_options_set_verify_block(
        options.securityProtocolOptions,
        { _, trust, complete in
          let trust = sec_trust_copy_ref(trust).takeRetainedValue()
          if let unzonedHost {
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, unzonedHost as CFString))
          }
          complete(evaluate(trust))
        },
        verifyQueue)
    }
    return options
  }
}

/// `host` without its zone id when it is an IPv6 literal with one
/// (`fe80::1%en0` gives `fe80::1`); nil for any other host.
func hostWithoutZone(_ host: String) -> String? {
  guard host.contains(":"), let percent = host.firstIndex(of: "%") else { return nil }
  return String(host[..<percent])
}

/// Whether the leaf (server) certificate in `trust` has one of the `pins`
/// fingerprints. The leaf is always the first certificate of the chain.
func leafCertificateMatches(_ trust: SecTrust, pins: [CertificateFingerprint]) -> Bool {
  guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
    let leaf = chain.first
  else { return false }
  return pins.contains(CertificateFingerprint(certificate: leaf))
}
