// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Self-tests for FakeRTSPServer, RawRTSPTestClient, and the RTP/SDP test builders

import Foundation
import Network
import Testing

@testable import IPCamKit

// MARK: - Helpers

private actor ItemCollector {
  private(set) var items: [PublicCodecItem] = []
  private(set) var finished = false
  func add(_ item: PublicCodecItem) { items.append(item) }
  func finish() { finished = true }
}

/// Consume `session.frames()` until `until` holds, the stream ends, or
/// `deadline` passes. The consumer task is cancelled on return; the session's
/// reader keeps running so a later `stop()` can still route its TEARDOWN.
private func collectItems(
  from session: RTSPClientSession,
  deadline: Duration,
  until: @escaping @Sendable ([PublicCodecItem]) -> Bool
) async -> [PublicCodecItem] {
  let collector = ItemCollector()
  let consumer = Task {
    do {
      for try await item in session.frames() {
        await collector.add(item)
        if until(await collector.items) { break }
      }
    } catch {}
    await collector.finish()
  }
  let endBy = ContinuousClock.now + deadline
  while ContinuousClock.now < endBy {
    let finished = await collector.finished
    let items = await collector.items
    if finished || until(items) { break }
    try? await Task.sleep(for: .milliseconds(25))
  }
  consumer.cancel()
  return await collector.items
}

private func videoFrames(_ items: [PublicCodecItem]) -> [PublicVideoFrame] {
  items.compactMap {
    if case .video(let frame) = $0 { return frame }
    return nil
  }
}

private func containsRTCP(_ items: [PublicCodecItem]) -> Bool {
  items.contains {
    if case .rtcp = $0 { return true }
    return false
  }
}

/// Stop `server` after `cap` unless cancelled. Dropping its connections fails
/// any client read that has no timeout of its own, so a regression cannot hang
/// the test.
private func watchdog(_ server: FakeRTSPServer, after cap: Duration) -> Task<Void, Never> {
  Task.detached {
    try? await Task.sleep(for: cap)
    guard !Task.isCancelled else { return }
    server.stop()
  }
}

/// Stream `frameCount` H.264 access units on `stream`, 6000 RTP ticks apart
/// (15 fps at 90 kHz), a keyframe every `keyframeInterval`, with an RTCP sender
/// report after the first. Seeded from the stream's advertised SSRC and
/// RTP-Info; stops once the stream is torn down or the connection closes.
private func streamH264(
  on handle: FakeRTSPSessionHandle, stream: Int, frameCount: Int, keyframeInterval: Int,
  interval: Duration
) async {
  guard let setup = handle.setup(forStream: stream) else { return }
  var sequencer = RTPTestSequencer(parameters: setup.parameters)
  for index in 0..<frameCount {
    let rtpTime = sequencer.timestamp
    let nalus = h264AccessUnit(keyframe: index % keyframeInterval == 0)
    for packet in sequencer.accessUnit(nalus, timestampIncrement: 6000) {
      guard handle.sendRTP(packet, stream: stream) else { return }
    }
    if index == 0 {
      let report = makeRTCPSenderReport(
        ssrc: setup.parameters.ssrc, ntp: ntpTimestamp(for: Date()), rtpTimestamp: rtpTime)
      handle.sendRTCP(report, stream: stream)
    }
    guard !Task.isCancelled else { return }
    try? await Task.sleep(for: interval)
  }
}

/// One `$`-interleaved frame.
private func interleavedFrame(channel: UInt8, _ payload: Data) -> Data {
  RTSPSerializer().serializeInterleaved(RTSPInterleavedData(channelId: channel, data: payload))
}

/// Send one UDP datagram from an ephemeral port to loopback `port`.
private func sendUDPDatagram(_ data: Data, toPort port: UInt16) async throws {
  let queue = DispatchQueue(label: "ipcamkit.tests.fake-rtsp.udp-sender")
  let connection = NWConnection(
    host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
  defer { connection.cancel() }
  try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
    let lock = NSLock()
    nonisolated(unsafe) var settled = false
    @Sendable func settle(_ result: Result<Void, Error>) {
      lock.lock()
      let first = !settled
      settled = true
      lock.unlock()
      if first { continuation.resume(with: result) }
    }
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready:
        connection.send(
          content: data,
          completion: .contentProcessed { error in
            settle(error.map { .failure($0) } ?? .success(()))
          })
      case .failed(let error), .waiting(let error):
        settle(.failure(error))
      default:
        break
      }
    }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 5) {
      settle(.failure(RawRTSPTestClient.ClientError.timedOut))
    }
  }
}

// MARK: - Tests

@Suite("Fake RTSP Server")
struct FakeRTSPServerTests {

  // MARK: Real client

  @Test(
    "RTSPClientSession streams H.264 from the fake server",
    arguments: zip(
      [IPCamKit.Transport.tcp, .udp, .tcp, .udp],
      [FakeRTSPServer.AddressFamily.ipv4, .ipv4, .ipv6, .ipv6]))
  func realClientStreamsH264(
    transport: IPCamKit.Transport, family: FakeRTSPServer.AddressFamily
  ) async throws {
    let server = FakeRTSPServer(configuration: .init(sdp: h264VideoOnlySDP(), family: family))
    server.onPlay = { _, handle in
      Task {
        await streamH264(
          on: handle, stream: 0, frameCount: 150, keyframeInterval: 10,
          interval: .milliseconds(20))
      }
    }
    try await server.start()
    defer { server.stop() }
    let guardTask = watchdog(server, after: .seconds(30))
    defer { guardTask.cancel() }
    #expect(server.url == "rtsp://\(family.urlHost):\(server.port)/stream")

    let session = RTSPClientSession(url: server.url, transport: transport)
    let description = try await session.start()
    #expect(description.video?.codec == .h264)
    #expect(description.video?.sps == h264TestSPS)
    #expect(description.video?.pps == h264TestPPS)

    let items = await collectItems(from: session, deadline: .seconds(10)) { items in
      let frames = videoFrames(items)
      return frames.count >= 4 && frames.contains(where: \.isKeyframe) && containsRTCP(items)
    }
    let frames = videoFrames(items)
    #expect(frames.count >= 4)
    #expect(containsRTCP(items), "the RTCP sender report should arrive")
    let keyframe = frames.first(where: \.isKeyframe)
    #expect(keyframe?.nalus == h264AccessUnit(keyframe: true))
    #expect(frames.filter { !$0.isKeyframe }.allSatisfy { $0.nalus == [h264TestNonIDRSlice] })

    // Consecutive frames are 6000 ticks (1/15 s) apart. UDP may in principle
    // drop a datagram, so there only whole multiples of the step are required.
    let step = 6000.0 / 90_000.0
    for (previous, next) in zip(frames, frames.dropFirst()) {
      let steps = (next.timestamp - previous.timestamp) / step
      if transport == .tcp {
        #expect(abs(steps - 1) < 1e-9)
      } else {
        #expect(steps > 0.5 && abs(steps - steps.rounded()) < 1e-9)
      }
    }

    await session.stop()
    // PLAY and TEARDOWN go to the aggregate control URL: the SDP's
    // `a=control:*` resolves to the Content-Base (RFC 2326 C.1.1).
    let teardown = await server.waitForRequest(method: "TEARDOWN")
    #expect(teardown?.url == server.contentBase)
    #expect(teardown?.sessionID != nil)
    #expect(server.requests(method: "PLAY").first?.url == server.contentBase)

    #expect(server.requests.prefix(4).map(\.method) == ["OPTIONS", "DESCRIBE", "SETUP", "PLAY"])
    let setup = try #require(server.requests(method: "SETUP").first)
    #expect(setup.url == server.controlURL("video"))
    switch transport {
    case .tcp:
      #expect(setup.transport == "RTP/AVP/TCP;unicast;interleaved=0-1")
    case .udp:
      #expect(setup.transport?.hasPrefix("RTP/AVP;unicast;client_port=") == true)
    case .multicast:
      Issue.record("not parameterized over multicast")
    }
    let play = try #require(server.exchanges.first { $0.request.method == "PLAY" })
    #expect(
      play.response.header("RTP-Info")
        == "url=\(server.controlURL("video"));seq=1000;rtptime=90000")
    #expect(play.response.header("Range") == "npt=0.000-")
    #expect(play.response.header("Session")?.hasSuffix(";timeout=60") == true)
  }

  @Test("onRequest replaces responses; transformResponse edits default ones")
  func overrideHooks() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    server.onRequest = { request in
      guard request.method == "DESCRIBE", request.header("Authorization") == nil else {
        return nil
      }
      return FakeRTSPResponse(
        statusCode: 401, headers: [("WWW-Authenticate", "Basic realm=\"fake\"")])
    }
    server.transformResponse = { request, response in
      var response = response
      if request.method == "OPTIONS" { response.setHeader("Server", "FakeCam/1.0") }
      return response
    }
    server.onPlay = { _, handle in
      Task {
        await streamH264(
          on: handle, stream: 0, frameCount: 150, keyframeInterval: 10,
          interval: .milliseconds(20))
      }
    }
    try await server.start()
    defer { server.stop() }
    let guardTask = watchdog(server, after: .seconds(30))
    defer { guardTask.cancel() }

    // Wire level: the hook's 401 goes out verbatim plus the echoed CSeq.
    let client = RawRTSPTestClient(server: server)
    try await client.connect()
    let options = try await client.request(method: "OPTIONS", url: server.url)
    #expect(options.header("Server") == "FakeCam/1.0")
    #expect(options.header("Public")?.contains("GET_PARAMETER") == true)
    let challenged = try await client.request(method: "DESCRIBE", url: server.url)
    #expect(challenged.statusCode == 401)
    #expect(challenged.reasonPhrase == "Unauthorized")
    #expect(challenged.cseq == 2)
    #expect(challenged.header("WWW-Authenticate") == "Basic realm=\"fake\"")
    client.close()

    // Real client: retries DESCRIBE with Basic credentials and then streams.
    let session = RTSPClientSession(
      url: server.url, credentials: Credentials(username: "user", password: "pass"),
      transport: .tcp)
    _ = try await session.start()
    let items = await collectItems(from: session, deadline: .seconds(10)) {
      !videoFrames($0).isEmpty
    }
    #expect(!videoFrames(items).isEmpty)
    await session.stop()

    let describes = server.requests(method: "DESCRIBE").filter { $0.connectionID != 1 }
    #expect(describes.count == 2)
    let expectedAuth = "Basic " + Data("user:pass".utf8).base64EncodedString()
    #expect(describes.last?.header("Authorization") == expectedAuth)
    #expect(server.exchanges.filter(\.overridden).map(\.response.statusCode) == [401, 401])

    // A replaced PLAY response fails the client's start().
    server.onRequest = { $0.method == "PLAY" ? FakeRTSPResponse(statusCode: 454) : nil }
    let rejected = RTSPClientSession(url: server.url, transport: .tcp)
    do {
      _ = try await rejected.start()
      Issue.record("start() should fail when PLAY is answered with 454")
    } catch RTSPError.sessionSetupFailed(let statusCode, _) {
      #expect(statusCode == 454)
    } catch {
      Issue.record("expected sessionSetupFailed(454), got \(error)")
    }
    await rejected.stop()
  }

  // MARK: Wire level

  @Test("Unknown Require tags get 551 with Unsupported on any method")
  func requireTags() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    try await server.start()
    defer { server.stop() }
    let client = RawRTSPTestClient(server: server)
    try await client.connect()
    defer { client.close() }

    let rejected = try await client.request(
      method: "OPTIONS", url: server.url,
      headers: [("Require", "com.example.bogus, onvif-replay"), ("Require", "x-other")])
    #expect(rejected.statusCode == 551)
    #expect(rejected.reasonPhrase == "Option not supported")
    #expect(rejected.header("Unsupported") == "com.example.bogus, x-other")
    #expect(rejected.cseq == 1)

    let described = try await client.request(
      method: "DESCRIBE", url: server.url,
      headers: [("Require", "onvif-replay, www.onvif.org/ver20/backchannel")])
    #expect(described.statusCode == 200)
    #expect(described.cseq == 2)
    #expect(described.contentType == "application/sdp")
    #expect(described.header("Content-Base") == server.url + "/")
    #expect(String(decoding: described.body, as: UTF8.self) == h264VideoOnlySDP())

    // SETUP is checked too, and a rejected SETUP creates no session.
    let setup = try await client.request(
      method: "SETUP", url: server.controlURL("video"),
      headers: [
        ("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1"), ("Require", "ONVIF-REPLAY, nope"),
      ])
    #expect(setup.statusCode == 551)
    #expect(setup.header("Unsupported") == "nope")
    #expect(server.sessionHandles.first?.sessionID == nil)

    // The tag list is configurable.
    server.configuration.supportedFeatureTags = []
    let narrowed = try await client.request(
      method: "OPTIONS", url: server.url, headers: [("Require", "onvif-replay")])
    #expect(narrowed.statusCode == 551)
    #expect(narrowed.header("Unsupported") == "onvif-replay")
  }

  @Test("DESCRIBE lists the backchannel only when required; SETUP follows the served SDP")
  func backchannelDescribe() async throws {
    let full = onvifBackchannelSDP()
    let plain = onvifBackchannelSDP(audioControl: nil, includeBackchannel: false)
    let server = FakeRTSPServer(configuration: .init(sdp: full, sdpWithoutBackchannel: plain))
    try await server.start()
    defer { server.stop() }
    let transport = ("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1")

    // Without Require: video 0, metadata 1.
    let viewer = RawRTSPTestClient(server: server)
    try await viewer.connect()
    defer { viewer.close() }
    let plainDescribe = try await viewer.request(method: "DESCRIBE", url: server.url)
    #expect(String(decoding: plainDescribe.body, as: UTF8.self) == plain)
    let metadata = try await viewer.request(
      method: "SETUP", url: server.controlURL("metadata"), headers: [transport])
    #expect(metadata.statusCode == 200)
    let viewerHandle = try #require(server.sessionHandle(connectionID: 1))
    #expect(viewerHandle.setups.map(\.stream) == [1])
    #expect(viewerHandle.setup(forStream: 1)?.control == "metadata")

    // With Require: video 0, audio 1, metadata 2, backchannel 3.
    let talker = RawRTSPTestClient(server: server)
    try await talker.connect()
    defer { talker.close() }
    let fullDescribe = try await talker.request(
      method: "DESCRIBE", url: server.url,
      headers: [("Require", "www.onvif.org/ver20/backchannel")])
    #expect(String(decoding: fullDescribe.body, as: UTF8.self) == full)
    let back = try await talker.request(
      method: "SETUP", url: server.controlURL("audioback"), headers: [transport])
    #expect(back.statusCode == 200)
    let talkerHandle = try #require(server.sessionHandle(connectionID: 2))
    #expect(talkerHandle.setups.map(\.stream) == [3])
    #expect(talkerHandle.setup(forStream: 3)?.parameters == .defaults(forStream: 3))
  }

  @Test("Raw SETUP/PLAY: session rules, PLAY echoes, media both ways in order")
  func rawInterleavedSession() async throws {
    let server = FakeRTSPServer(sdp: onvifBackchannelSDP())
    let videoPacket = makeRTP(
      sequence: 1000, timestamp: 90_000, ssrc: 0x5EED_0000, payloadType: 96, marker: true,
      payload: h264TestIDRSlice)
    server.onPlay = { _, handle in
      handle.sendRTP(videoPacket, stream: 0)
    }
    try await server.start()
    defer { server.stop() }
    let client = RawRTSPTestClient(server: server)
    try await client.connect()
    defer { client.close() }

    let early = try await client.request(method: "PLAY", url: server.url)
    #expect(early.statusCode == 455)

    let video = try await client.request(
      method: "SETUP", url: server.controlURL("video"),
      headers: [("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1")])
    #expect(video.statusCode == 200)
    #expect(video.header("Transport") == "RTP/AVP/TCP;unicast;interleaved=0-1")
    let sessionHeader = try #require(video.header("Session"))
    #expect(sessionHeader.hasSuffix(";timeout=60"))
    let sessionID = String(sessionHeader.split(separator: ";")[0])

    let back = try await client.request(
      method: "SETUP", url: server.controlURL("audioback"),
      headers: [
        ("Transport", "RTP/AVP/TCP;unicast;interleaved=6-7"), ("Session", sessionID),
        ("Require", "www.onvif.org/ver20/backchannel"),
      ])
    #expect(back.statusCode == 200)
    #expect(back.header("Session") == sessionHeader)

    let wrongSession = try await client.request(
      method: "PLAY", url: server.url, headers: [("Session", "not-\(sessionID)")])
    #expect(wrongSession.statusCode == 454)

    // The PLAY response precedes the media its onPlay hook sends.
    let play = client.makeRequest(
      method: "PLAY", url: server.url,
      headers: [
        ("Session", sessionID), ("Range", "clock=20260101T000000Z-"), ("Scale", "2.0"),
        ("Rate-Control", "no"), ("Frames", "intra"), ("Immediate", "yes"),
        ("Require", "onvif-replay"),
      ])
    try await client.send(play.bytes)
    guard case .response(let playResponse) = try await client.receiveMessage() else {
      Issue.record("expected the PLAY response before any media")
      return
    }
    #expect(playResponse.statusCode == 200)
    #expect(playResponse.cseq == UInt32(play.cseq))
    #expect(playResponse.header("Range") == "clock=20260101T000000Z-")
    #expect(playResponse.header("Scale") == "2.0")
    #expect(
      playResponse.header("RTP-Info")
        == "url=\(server.controlURL("video"));seq=1000;rtptime=90000,"
        + "url=\(server.controlURL("audioback"));seq=4000;rtptime=360000")
    guard case .data(let media) = try await client.receiveMessage() else {
      Issue.record("expected interleaved media after the PLAY response")
      return
    }
    #expect(media.channelId == 0)
    #expect(media.data == videoPacket)

    let recordedPlay = try #require(
      await server.waitForRequests(where: { $0.cseq == play.cseq }).first)
    #expect(recordedPlay.range == "clock=20260101T000000Z-")
    #expect(recordedPlay.scale == "2.0")
    #expect(recordedPlay.rateControl == "no")
    #expect(recordedPlay.frames == "intra")
    #expect(recordedPlay.immediate == "yes")
    #expect(recordedPlay.requireTags == ["onvif-replay"])

    // Backchannel RTP/RTCP, a keepalive, more RTP, and a frame on an unset
    // channel, all in one write.
    let audio1 = makeRTP(
      sequence: 1, timestamp: 0, ssrc: 0xBAC0, payloadType: 0, marker: false,
      payload: Data(repeating: 0xFF, count: 160))
    let report = makeRTCPSenderReport(ssrc: 0xBAC0, ntp: 0, rtpTimestamp: 0)
    let audio2 = makeRTP(
      sequence: 2, timestamp: 160, ssrc: 0xBAC0, payloadType: 0, marker: false,
      payload: Data(repeating: 0x7F, count: 160))
    let keepalive = client.makeRequest(
      method: "GET_PARAMETER", url: server.url, headers: [("Session", sessionID)])
    var burst = interleavedFrame(channel: 6, audio1)
    burst.append(interleavedFrame(channel: 7, report))
    burst.append(keepalive.bytes)
    burst.append(interleavedFrame(channel: 6, audio2))
    burst.append(interleavedFrame(channel: 9, Data([1, 2, 3])))
    try await client.send(burst)

    let keepaliveResponse = try await client.receiveResponse()
    #expect(keepaliveResponse.statusCode == 200)
    #expect(keepaliveResponse.cseq == UInt32(keepalive.cseq))
    #expect(keepaliveResponse.header("Session") == sessionHeader)

    let received = await server.waitForReceivedMedia(count: 4)
    #expect(received.map(\.channel) == [6, 7, 6, 9])
    #expect(received.map(\.stream) == [3, 3, 3, nil])
    #expect(received.map(\.isRTCP) == [false, true, false, false])
    #expect(received.map(\.data) == [audio1, report, audio2, Data([1, 2, 3])])
    #expect(received.allSatisfy { $0.connectionID == 1 })

    let handle = try #require(server.sessionHandle(connectionID: 1))
    #expect(handle.setups.map(\.stream) == [0, 3])
    #expect(handle.setup(forStream: 3)?.transport == .interleaved(rtpChannel: 6, rtcpChannel: 7))

    let pause = try await client.request(
      method: "PAUSE", url: server.url, headers: [("Session", sessionID)])
    #expect(pause.statusCode == 200)
    let teardown = try await client.request(
      method: "TEARDOWN", url: server.url, headers: [("Session", sessionID)])
    #expect(teardown.statusCode == 200)
    #expect(handle.sessionID == nil)
    #expect(handle.setups.isEmpty)
  }

  @Test("Requests and interleaved frames split into 1-byte TCP writes still parse")
  func bytewiseWrites() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    try await server.start()
    defer { server.stop() }
    let client = RawRTSPTestClient(server: server)
    try await client.connect()
    defer { client.close() }

    let options = client.makeRequest(method: "OPTIONS", url: server.url)
    let parameters = Data("tick: 1\r\n".utf8)
    let setParameter = client.makeRequest(
      method: "SET_PARAMETER", url: server.url,
      headers: [("Content-Type", "text/parameters")], body: parameters)
    let payload = Data((1...20).map { UInt8($0) })
    var bytes = Data("\r\n".utf8)
    bytes.append(options.bytes)
    bytes.append(interleavedFrame(channel: 2, payload))
    bytes.append(setParameter.bytes)
    try await client.sendBytewise(bytes)

    let requests = await server.waitForRequests(count: 2)
    #expect(requests.map(\.method) == ["OPTIONS", "SET_PARAMETER"])
    #expect(requests.map(\.cseq) == [options.cseq, setParameter.cseq])
    #expect(requests.last?.body == parameters)
    #expect(requests.last?.header("content-type") == "text/parameters")
    let media = await server.waitForReceivedMedia(count: 1)
    #expect(media.map(\.channel) == [2])
    #expect(media.first?.stream == nil)
    #expect(media.first?.data == payload)

    let first = try await client.receiveResponse()
    let second = try await client.receiveResponse()
    #expect([first.cseq, second.cseq] == [UInt32(options.cseq), UInt32(setParameter.cseq)])
    #expect([first.statusCode, second.statusCode] == [200, 200])
  }

  @Test("UDP SETUP binds an even/odd server port pair and records client datagrams")
  func udpDatagramsRecorded() async throws {
    let server = FakeRTSPServer(sdp: onvifBackchannelSDP())
    try await server.start()
    defer { server.stop() }
    let client = RawRTSPTestClient(server: server)
    try await client.connect()
    defer { client.close() }

    let response = try await client.request(
      method: "SETUP", url: server.controlURL("audioback"),
      headers: [("Transport", "RTP/AVP;unicast;client_port=40000-40001")])
    #expect(response.statusCode == 200)
    let handle = try #require(server.sessionHandle(connectionID: 1))
    let setup = try #require(handle.setup(forStream: 3))
    guard case .udp(40000, 40001, let rtpPort, let rtcpPort) = setup.transport else {
      Issue.record("expected a UDP setup, got \(setup.transport)")
      return
    }
    #expect(rtpPort % 2 == 0)
    #expect(rtcpPort == rtpPort + 1)
    #expect(
      response.header("Transport")
        == "RTP/AVP;unicast;client_port=40000-40001;server_port=\(rtpPort)-\(rtcpPort);"
        + "ssrc=5EED0003")

    let rtp = makeRTP(
      sequence: 7, timestamp: 0, ssrc: 0xBAC0, payloadType: 0, marker: false,
      payload: Data(repeating: 0xFF, count: 160))
    let rtcp = makeRTCPSenderReport(ssrc: 0xBAC0, ntp: 0, rtpTimestamp: 0)
    try await sendUDPDatagram(Data(), toPort: rtpPort)
    try await sendUDPDatagram(rtp, toPort: rtpPort)
    try await sendUDPDatagram(rtcp, toPort: rtcpPort)

    let media = await server.waitForReceivedMedia(count: 2)
    #expect(media.count == 2)
    let byPort = Dictionary(uniqueKeysWithValues: media.map { ($0.path, $0) })
    #expect(byPort[.udp(serverPort: rtpPort)]?.data == rtp)
    #expect(byPort[.udp(serverPort: rtpPort)]?.isRTCP == false)
    #expect(byPort[.udp(serverPort: rtcpPort)]?.data == rtcp)
    #expect(byPort[.udp(serverPort: rtcpPort)]?.isRTCP == true)
    #expect(media.allSatisfy { $0.stream == 3 && $0.channel == nil })
  }

  @Test("Concurrent connections get separate sessions; close() and stop() end them")
  func connectionsAndShutdown() async throws {
    let server = FakeRTSPServer(sdp: h264VideoOnlySDP())
    try await server.start()
    defer { server.stop() }
    let port = server.port
    let first = RawRTSPTestClient(server: server)
    let second = RawRTSPTestClient(server: server)
    try await first.connect()
    try await second.connect()
    defer {
      first.close()
      second.close()
    }

    let setupURL = server.controlURL("video")
    let transport = [("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1")]
    async let firstSetup = first.request(method: "SETUP", url: setupURL, headers: transport)
    async let secondSetup = second.request(method: "SETUP", url: setupURL, headers: transport)
    let (firstResponse, secondResponse) = try await (firstSetup, secondSetup)
    #expect(firstResponse.statusCode == 200)
    #expect(secondResponse.statusCode == 200)
    let firstSession = try #require(firstResponse.header("Session"))
    #expect(firstSession != secondResponse.header("Session"))
    #expect(server.sessionHandles.count == 2)

    // Abrupt close of one connection.
    let firstID = String(firstSession.split(separator: ";")[0])
    let handle = try #require(server.sessionHandles.first { $0.sessionID == firstID })
    handle.close()
    #expect(handle.isClosed)
    #expect(!handle.sendRTP(Data([0x80]), stream: 0))
    #expect(server.sessionHandles.count == 1)
    await #expect(throws: RawRTSPTestClient.ClientError.self) {
      _ = try await first.receiveMessage(timeout: .seconds(5))
    }

    // stop() releases an outstanding waiter, drops connections, frees the port.
    let started = ContinuousClock.now
    async let pending = server.waitForRequests(
      where: { $0.method == "ANNOUNCE" }, count: 1, timeout: .seconds(30))
    try await Task.sleep(for: .milliseconds(100))
    server.stop()
    #expect(await pending.isEmpty)
    #expect(ContinuousClock.now - started < .seconds(10))
    await #expect(throws: RawRTSPTestClient.ClientError.self) {
      _ = try await second.receiveMessage(timeout: .seconds(5))
    }
    let late = RawRTSPTestClient(host: "127.0.0.1", port: port)
    await #expect(throws: RawRTSPTestClient.ClientError.self) {
      try await late.connect(timeout: .seconds(3))
    }
    late.close()
  }

  // MARK: Builders

  @Test("onvifReplayExtension matches the ONVIF replay extension layout")
  func onvifReplayExtensionLayout() {
    let ext = onvifReplayExtension(
      ntp: 0x0102_0304_0506_0708, cleanPoint: true, endOfSection: false, discontinuity: true,
      terminal: false, cseq: 0x2A)
    #expect(ext.profile == 0xABAC)
    #expect(ext.data == Data([1, 2, 3, 4, 5, 6, 7, 8, 0xA0, 0x2A, 0, 0]))

    func flags(_ c: Bool, _ e: Bool, _ d: Bool, _ t: Bool) -> UInt8 {
      onvifReplayExtension(
        ntp: 0, cleanPoint: c, endOfSection: e, discontinuity: d, terminal: t, cseq: 0
      ).data[8]
    }
    #expect(flags(true, false, false, false) == 0x80)
    #expect(flags(false, true, false, false) == 0x40)
    #expect(flags(false, false, true, false) == 0x20)
    #expect(flags(false, false, false, true) == 0x10)
    #expect(flags(true, true, true, true) == 0xF0)
    #expect(flags(false, false, false, false) == 0x00)

    let packet = makeRTP(
      sequence: 0x1234, timestamp: 0xDEAD_BEEF, ssrc: 0x0A0B_0C0D, payloadType: 96,
      marker: true, payload: Data([0x65, 0x88]), extensionProfile: ext.profile,
      extensionData: ext.data)
    #expect(
      packet
        == Data([
          0x90, 0xE0, 0x12, 0x34, 0xDE, 0xAD, 0xBE, 0xEF, 0x0A, 0x0B, 0x0C, 0x0D,
          0xAB, 0xAC, 0x00, 0x03, 1, 2, 3, 4, 5, 6, 7, 8, 0xA0, 0x2A, 0, 0,
          0x65, 0x88,
        ]))
  }

  @Test("makeRTP output parses with RawRTPPacket.parse")
  func makeRTPParses() throws {
    let payload = Data([0x41, 0x9A, 0x02])
    let plain = try RawRTPPacket.parse(
      makeRTP(
        sequence: 65_535, timestamp: 4_000_000_000, ssrc: 0xCAFE_F00D, payloadType: 97,
        marker: false, payload: payload)
    ).get()
    #expect(plain.data.count == 12 + payload.count)
    #expect(plain.sequenceNumber == 65_535)
    #expect(plain.rtpTimestamp == 4_000_000_000)
    #expect(plain.ssrc == 0xCAFE_F00D)
    #expect(plain.payloadType == 97)
    #expect(!plain.mark)
    #expect(plain.payload == payload)

    // Extension data is zero-padded to whole 32-bit words.
    let raw = makeRTP(
      sequence: 1, timestamp: 2, ssrc: 3, payloadType: 96, marker: true, payload: payload,
      extensionProfile: 0xBEDE, extensionData: Data([1, 2, 3, 4, 5]))
    #expect(Array(raw[12..<24]) == [0xBE, 0xDE, 0x00, 0x02, 1, 2, 3, 4, 5, 0, 0, 0])
    let extended = try RawRTPPacket.parse(raw).get()
    #expect(extended.mark)
    #expect(extended.payloadType == 96)
    #expect(extended.payload == payload)

    let empty = try RawRTPPacket.parse(
      makeRTP(
        sequence: 1, timestamp: 2, ssrc: 3, payloadType: 0, marker: false, payload: payload,
        extensionProfile: 0xABAC)
    ).get()
    #expect(empty.data[0] == 0x90)
    #expect(empty.payload == payload)

    let ext = onvifReplayExtension(
      ntp: ntpTimestamp(for: Date()), cleanPoint: true, endOfSection: false,
      discontinuity: false, terminal: false, cseq: 4)
    let replay = try RawRTPPacket.parse(
      makeRTP(
        sequence: 9, timestamp: 9, ssrc: 9, payloadType: 96, marker: true, payload: payload,
        extensionProfile: ext.profile, extensionData: ext.data)
    ).get()
    #expect(replay.payloadRange.lowerBound == 12 + 4 + 12)
    #expect(replay.payload == payload)
  }

  @Test("ntpTimestamp counts era-0 seconds since 1900 with a 32-bit fraction")
  func ntpTimestamps() {
    let offset: UInt64 = 2_208_988_800
    #expect(ntpTimestamp(for: Date(timeIntervalSince1970: 0)) == offset << 32)
    #expect(
      ntpTimestamp(for: Date(timeIntervalSince1970: 1.5)) == (offset + 1) << 32 | 0x8000_0000)
    #expect(ntpTimestamp(for: Date(timeIntervalSince1970: -2_208_988_800)) == 0)
    #expect(
      ntpTimestamp(for: Date(timeIntervalSince1970: 1_767_225_600.25))
        == (offset + 1_767_225_600) << 32 | 0x4000_0000)
  }

  @Test("SDP builders produce the documented layouts")
  func sdpBuilders() throws {
    let video = try SDPParser().parse(h264VideoOnlySDP())
    #expect(video.mediaDescriptions.map(\.media) == ["video"])
    let fmtp = try #require(video.mediaDescriptions.first?.attribute("fmtp")?.value)
    #expect(fmtp.contains("packetization-mode=1"))
    #expect(fmtp.contains("sprop-parameter-sets=Z2QAM6wVFKCgL/lQ,aO48sA=="))

    let onvif = try SDPParser().parse(onvifBackchannelSDP())
    let media = onvif.mediaDescriptions
    #expect(media.map(\.media) == ["video", "audio", "application", "audio"])
    #expect(
      media.map { $0.attribute("control")?.value }
        == ["video", "audio", "metadata", "audioback"])
    #expect(media[0].attribute("recvonly") != nil)
    #expect(media[1].attribute("recvonly") != nil)
    #expect(media[2].attribute("rtpmap")?.value == "107 vnd.onvif.metadata/90000")
    #expect(media[3].fmt == "0")
    #expect(media[3].attribute("rtpmap")?.value == "0 PCMU/8000")
    #expect(media[3].attribute("sendonly") != nil)
    #expect(media[3].attribute("recvonly") == nil)
  }
}
