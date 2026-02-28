// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// NWConnection-based TCP transport for RTSP

import Foundation
import Network

/// A TCP connection for RTSP communication using Apple's Network framework.
///
/// Handles:
/// - TCP connection lifecycle (connect, send, receive)
/// - RTSP message framing (responses and interleaved data)
/// - Buffered reading for partial message assembly
/// - Private dispatch queue for NWConnection callbacks
actor RTSPTransportConnection {
  private var connection: NWConnection?
  private let queue = DispatchQueue(label: "ipcamkit.rtsp.connection")
  private let parser = RTSPParser()
  private var readBuffer = Data()
  private var connectionContext: ConnectionContext?
  private var readPos: UInt64 = 0

  /// Connect to an RTSP server.
  func connect(host: String, port: UInt16) async throws {
    let nwHost = NWEndpoint.Host(host)
    let nwPort = NWEndpoint.Port(rawValue: port)!
    let conn = NWConnection(host: nwHost, port: nwPort, using: .tcp)

    self.connection = conn

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
          continuation.resume()
        case .failed(let error):
          continuation.resume(throwing: RTSPError.connectionFailed(error.localizedDescription))
        case .cancelled:
          continuation.resume(throwing: RTSPError.unexpectedDisconnection)
        default:
          break
        }
      }
      conn.start(queue: queue)
    }

    // Clear the state handler after connection
    conn.stateUpdateHandler = nil

    if let localEndpoint = conn.currentPath?.localEndpoint,
      let remoteEndpoint = conn.currentPath?.remoteEndpoint
    {
      connectionContext = ConnectionContext(
        localAddr: "\(localEndpoint)",
        peerAddr: "\(remoteEndpoint)",
        establishedWall: .now()
      )
    } else {
      connectionContext = .dummy()
    }
  }

  /// Send raw data over the connection.
  func send(_ data: Data) async throws {
    guard let conn = connection else {
      throw RTSPError.connectionFailed("Not connected")
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      conn.send(
        content: data,
        completion: .contentProcessed({ error in
          if let error = error {
            continuation.resume(
              throwing: RTSPError.connectionFailed("Send failed: \(error.localizedDescription)"))
          } else {
            continuation.resume()
          }
        }))
    }
  }

  /// Send an RTSP request and wait for the response.
  func sendRequest(_ request: RTSPRequest) async throws -> RTSPResponse {
    let serializer = RTSPSerializer()
    let data = serializer.serialize(request)
    try await send(data)
    return try await receiveResponse()
  }

  /// Receive the next RTSP message (response or interleaved data).
  func receiveMessage() async throws -> RTSPMessage {
    while true {
      // Try to parse from existing buffer
      var bufferCopy = readBuffer
      if let (msg, consumed) = try parser.parse(&bufferCopy) {
        readBuffer = bufferCopy
        readPos += UInt64(consumed)
        return msg
      }

      // Need more data
      let newData = try await readData()
      readBuffer.append(newData)
    }
  }

  /// Receive the next RTSP response, skipping interleaved data.
  func receiveResponse() async throws -> RTSPResponse {
    while true {
      let msg = try await receiveMessage()
      if case .response(let resp) = msg {
        return resp
      }
      // Skip interleaved data while waiting for response
    }
  }

  /// Read raw data from the connection.
  private func readData() async throws -> Data {
    guard let conn = connection else {
      throw RTSPError.unexpectedDisconnection
    }

    return try await withCheckedThrowingContinuation { continuation in
      conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
        content, _, isComplete, error in
        if let error = error {
          continuation.resume(
            throwing: RTSPError.connectionFailed("Read error: \(error.localizedDescription)"))
        } else if let data = content, !data.isEmpty {
          continuation.resume(returning: data)
        } else if isComplete {
          continuation.resume(throwing: RTSPError.unexpectedDisconnection)
        } else {
          continuation.resume(throwing: RTSPError.unexpectedDisconnection)
        }
      }
    }
  }

  /// Close the connection.
  func close() {
    connection?.cancel()
    connection = nil
  }

  /// The connection context for error reporting.
  var ctx: ConnectionContext {
    connectionContext ?? .dummy()
  }
}
