# Changelog

## Unreleased

### Breaking changes

- The package needs Swift 6.4 (Xcode 27) or later: `Package.swift` declares
  `swift-tools-version: 6.4`, up from 6.0. Swift Package Manager on an older
  toolchain refuses to resolve it.

## 0.5.0

### Breaking changes

- `RTSPError.connectionFailed` carries the Network framework error behind a
  failure: it is now `connectionFailed(String, underlying: NWError? = nil)`.
  `underlying` is `.dns` for a name that didn't resolve, `.posix` for a
  refused or unreachable host or another socket error (UDP and multicast
  sockets included), and `.tls` for a failed TLS handshake or connection; it
  is nil for failures that don't come from the network, such as a refused
  HTTP tunnel. A pattern that binds only the message,
  `case .connectionFailed(let message)`, now binds a tuple and warns; write
  `case .connectionFailed(let message, _)`.
- New `RTSPError.invalidURL(String)` for a stream or tunnel URL that
  `start()` can't use: a wrong scheme, no host or an invalid one, a bad port,
  a space or control character, an `@` after the host that may end a
  password, or a user name or password that isn't percent-encoded UTF-8.
  These were `connectionFailed` before. Their messages are unchanged, and
  `description` is the message alone, without `Connection failed: ` in
  front. A `switch` over `RTSPError` needs the new case.

### Changes

- `start()` honours task cancellation. Cancelling the task awaiting it closes
  the connection at once, without TEARDOWN, and `start()` throws
  `CancellationError`. Before, it waited out the connect deadline and each
  request's deadline (15 seconds each) and then threw `RTSPError.timeout`.
  In a task already cancelled, `start()` throws `CancellationError` without
  connecting. Cancelling the task after `start()` has returned doesn't affect
  the session.
- `play(_:)` and `pause()` honour task cancellation too: the call throws
  `CancellationError` at once instead of waiting up to 10 seconds for the
  response. A request not yet sent isn't sent. One already sent can't be taken
  back, so the session still follows the server's answer (an accepted PAUSE
  pauses it, an accepted seek moves the playback, a rejected seek is rolled
  back), except that a 401 to it isn't answered.
- A URL with an IPv4 address and a port may have an `@` after the host, as
  one with a bracketed IPv6 address and a port already could: ONVIF cameras
  report stream URIs such as `rtsp://192.0.2.5:554/live?password=Adm1n@2024`.
  With a host name and a port, such a URL is still rejected.

### Fixes

- A user name or password in the URL that holds a character `URLComponents`
  has to percent-encode itself (`"`, `<`, `>`, `[`, `\`, `]`, `^`, `` ` ``,
  `{`, `|`, `}`, a `%` that two hex digits don't follow, an `@` before the
  last one, or a `:` after the first) is decoded once. Before, the escapes
  in it, those for non-ASCII characters included, came back undecoded, and
  every request authenticated with the wrong password: `admin:£ecret|1@`
  sent `%C2%A3ecret|1`, `admin:P|ss%40word@` sent `P|ss%40word`, and
  `admin:p@ss%21@` sent `p@ss%21`. A user name or password that isn't
  percent-encoded UTF-8 is rejected whatever else it holds; `pw%E9|` was
  sent as written. A user name or password starting with U+FEFF (`%EF%BB%BF`)
  keeps it; it was dropped.
- The path and query of a URL with a user name and password, or with a
  Unicode or percent-encoded host name, reach the request line as written.
  When they held a character `URLComponents` encodes, their escapes were
  encoded a second time: `rtsp://admin:pw@cam/live/a{%20b` was requested as
  `rtsp://cam/live/a%7B%2520b`, a different resource from the one the same
  URL names without the login.
- With `credentials` passed, the URL's own user name and password are only
  removed, not decoded, so one that isn't UTF-8
  (`rtsp://admin:pw%FF@cam/s`) no longer makes `start()` throw.

## 0.4.0

### New

- RTSP over TLS. An `rtsps://` URL runs the RTSP control connection over TLS
  (Network framework), on port 322 unless the URL names one, and RTP/RTCP is
  interleaved inside that connection. A new `tls: TLSOptions` parameter on
  `RTSPClientSession.init` selects how the server certificate is verified,
  through `TLSOptions(serverTrust:)`: `.system` (the default),
  `.pinned([CertificateFingerprint])` for self-signed camera certificates,
  or `.custom` with your own `SecTrust` check.
  `CertificateFingerprint(hex:)` parses the fingerprint `openssl x509
  -fingerprint -sha256` prints. A failed handshake makes `start()` throw
  `RTSPError.connectionFailed` with a message starting `TLS handshake failed:`
  as soon as it fails, instead of after the 2-second grace period used for
  network errors, including when the server aborts the handshake after the
  client has finished its part (a TLS 1.3 server that requires a client
  certificate). A TLS error after the server has sent data reads
  `TLS connection failed:`. For a link-local IPv6 host with a zone id
  (`rtsps://[fe80::1%25en0]/`, and `https://` and `wss://` tunnels), the
  certificate is checked against the address without the zone (`fe80::1`).
- SRTP for RTSPS over UDP and multicast. With an `rtsps://` URL and
  `Transport.udp` or `.multicast`, SETUP asks for `RTP/SAVP` and sends a MIKEY
  key message in a `KeyMgmt` header (RFC 4567, RFC 3830, pre-shared key
  mode); RTP and RTCP are decrypted and authenticated with AES-CM-128 and
  HMAC-SHA1 (RFC 3711), using the keys from the server's `KeyMgmt` response
  or its SDP `a=key-mgmt`. Packets that fail authentication are dropped; the
  first such SRTP packet and the first such SRTCP packet of each stream are
  reported via `onDiagnostic`, and replayed packets are dropped without a
  report. A server key message whose policy is not
  AES-CM-128 encryption of RTP with HMAC-SHA1 authentication of RTP and RTCP
  under a 160-bit key (an 80-bit or 32-bit tag) fails SETUP. A SETUP reply whose `Transport` names a profile
  other than `RTP/SAVP` is reported via `onDiagnostic`, once per stream.
- ONVIF replay. `RTSPClientSession(..., onvif: .replay)` sends
  `Require: onvif-replay`. `start(_:)` takes `PlayOptions` for the first PLAY:
  `range` (`.npt` or `.clock` absolute time), `scale` (negative plays
  backwards), `rateControl: false` (`Rate-Control: no`), `frames` (`intra`,
  `intra/<ms>`, `predicted`) and `immediate`. `scale` must be from 0.000001
  to 1000 in magnitude (`start(_:)` and `play(_:)` throw
  `RTSPError.invalidState` before sending anything otherwise) and is sent
  as `[-]digits.digits`. Video, audio and metadata frames
  carry `replay: ReplayInfo?` with the recording time and the clean-point,
  end-of-section, discontinuity and terminal flags from the RTP header
  extension. `SessionDescription.range` gives the SDP `a=range` (`npt=` or
  `clock=`; an npt time must be digits only, without a sign, exponent or
  hex, and its minutes and seconds below 60; a clock time must be a real
  date in years 0001 to 9999, with seconds below 60 except a 23:59:60 leap
  second, and at most 9 fraction digits).
- `play(_:)` and `pause()` on a running session, for seeking, speed changes
  and pause/resume. They work while `frames()` is being iterated. After a seek
  (`range` or `immediate`), video, audio and metadata reassembly restarts,
  and packets still in flight from the previous position are dropped when
  they carry the ONVIF replay header extension, by its CSeq (once such
  packets have arrived, a PLAY's CSeq skips values whose low byte, the part
  the extension carries, one of the latest PLAYs used). Packets without the extension are held until the PLAY
  response (over UDP and multicast, the response is applied after the
  datagrams that arrived before it, as on TCP, so a backlog behind a slow
  consumer isn't taken for the new playback); then those before their
  stream's RTP-Info `seq` are dropped,
  and without RTP-Info they can't be told apart from the new playback's and
  are delivered. After a seek, all streams' new playback starts at one time,
  so audio and video stay aligned: at the RTP-Info `rtptime` of a stream
  whose new packets arrived before the PLAY response, or else where the
  furthest-ahead stream's next frame would have been (one frame interval,
  the smallest gap between its last 8 timestamps, at least one clock tick
  and at most half a second, past its highest timestamp, or the end of its
  last audio frame when that is later), with or without
  RTP-Info and including a stream that sent nothing before the seek; at 0
  when no stream sent anything before it. The
  jump in sequence numbers is not reported as loss in receiver reports,
  which keep the last sender report's timing. A seek the server rejects
  leaves the playback in flight untouched: its packets are kept while the
  PLAY is outstanding and delivered when `play()` throws, with continuous
  timestamps (up to 4096 packets or 8 MiB; beyond that, packets with the
  replay extension count as `loss` and the others go to the new playback).
  When the server accepts a seek that a later seek replaced before its
  response came, and rejects the later one, the accepted seek's playback
  starts as any seek's does. A replaced seek answered with 401 is not sent
  again with credentials, since the retry would reach the server after the
  later seek.
  Requests reach the server in CSeq order whatever the priorities of the
  tasks calling `play()` and `pause()`.
  While paused, a TCP session (plain, TLS or tunneled) sends no
  RTCP receiver reports until a PLAY sent after the PAUSE succeeds, because
  mediamtx closes a paused connection that carries interleaved data
  ("received unexpected interleaved frame"); `sendBackchannelAudio` throws
  `invalidState` while paused, and a call already sending stops before its
  next packet when `pause()` is called.
- Two-way audio (ONVIF backchannel). With `onvif: .backchannel`, the session
  sends `Require: www.onvif.org/ver20/backchannel`, sets up the first audio
  stream the camera marks `a=sendonly` whose format it can send (checked
  before the SETUP), and reports it as `SessionDescription.backchannel`. The
  backchannel's SETUP, like every request during `start()`, waits at most 15
  seconds. `sendBackchannelAudio(_:samples:startsTalkspurt:)` packetizes encoded audio into RTP and sends it over the session's transport
  (TCP-interleaved, UDP, or SRTP). `G711` converts 16-bit PCM to and from
  G.711 µ-law and A-law (the Sun reference algorithm, the one G.711's decision
  values describe). If the camera answers DESCRIBE with 551, the session
  repeats it without the backchannel tag and, when that succeeds, continues
  without two-way audio and reports it via `onDiagnostic` (with
  `onvif-replay` also required, a 551 the repeat gets too fails `start()`
  without blaming the backchannel).
  `sendBackchannelAudio(_:samples:startsTalkspurt: true)` starts a new
  talkspurt after a pause (push-to-talk): the RTP timestamp skips the silent
  time and the first packet carries the RTP marker bit (RFC 3551 section
  4.1), except for AAC, whose marker keeps its RFC 3640 meaning (the last
  packet of each access unit). The skip is counted in 64 bits, so a silence
  longer than 2^31 RTP clock ticks (12 hours at 48 kHz) skips too. A payload the codec can't carry (empty, or not a whole number of
  samples) throws `RTSPError.invalidState`. A call whose task is cancelled
  throws `CancellationError` and sends no more of its chunk. The backchannel's RTP uses the
  same SSRC as the client's receiver reports (RFC 3550 section 8: one SSRC
  per participant). For AAC, each access unit advances the RTP timestamp by
  the fmtp's `constantDuration` if given, else by the AudioSpecificConfig's
  frame length (1024, 960, 512, 480 or 256 samples) times the RTP clock
  rate's multiple of
  its core sampling rate (2048 for HE-AAC with a 24 kHz core on a 48 kHz
  clock), else by 1024.
- RTSP over HTTP and WebSocket tunnels: `tunnel: .http(URL)` (QuickTime HTTP
  tunneling, `http://` or `https://`) and `tunnel: .webSocket(URL)` (ONVIF RTSP
  over WebSocket, `ws://` or `wss://`). Both require `Transport.tcp`; HTTPS
  and WSS use the session's `TLSOptions`. The tunnel URL decides whether the
  connection is encrypted, so an `rtsps://` URL needs an `https://` or
  `wss://` tunnel; with `http://` or `ws://`, `start()` throws
  `RTSPError.invalidState`. A 401 on the tunnel's GET (or the WebSocket
  upgrade) is answered with the session's credentials, once more when that
  answer is refused with `stale=true` and a new nonce, and the POST carries
  the same credentials; when the server offers both Digest and Basic (on any
  of the 401s) and rejects Digest, the request is retried once with Basic,
  as RTSP requests during `start()` are. A POST the server rejects after accepting the GET ends
  `start()` or the running session at once with the cause
  (`RTSPError.connectionFailed("HTTP tunnel POST rejected: …")`, or
  `RTSPError.authenticationFailed` for a 401). Folded header lines, `\r\r\n` line endings
  and non-UTF-8 Digest challenges in the tunnel's HTTP responses are handled
  as in RTSP responses, with the same limits (64 KiB and 256 header lines).
  The WebSocket upgrade's 101 response must name only `websocket` in
  `Upgrade`, include `Upgrade` in `Connection`, carry exactly one matching
  `Sec-WebSocket-Accept`, choose no subprotocol other than `rtsp.onvif.org`
  and enable no extensions, counting every non-empty line of a repeated
  header;
  otherwise `start()` throws `RTSPError.connectionFailed("WebSocket upgrade
  rejected: …")`.
  A frame that breaks RFC 6455 (reserved bits set, an unknown opcode, a
  masked frame, a payload length not in its shortest form or with the top
  bit set, a fragmented or over-125-byte control frame, a continuation
  frame out of sequence, or a close frame with a status code outside
  1000–1003, 1007–1014 and 3000–4999 or a reason that isn't UTF-8) ends
  the session with `RTSPError.connectionFailed("WebSocket protocol error:
  …")`: the client sends a close frame with status 1002 and then closes the
  TCP connection. A text message that isn't UTF-8 gets status 1007 and a
  frame over 4 MiB 1009; text messages are otherwise read as bytes, like
  binary ones. Closing the session sends a close frame with status 1000
  before the TCP connection is closed. No frame is sent after a close
  frame. Control characters are removed from the tunnel's HTTP request headers, and
  an IPv6 zone id (`http://[fe80::1%25en0]/`) is left out of `Host` (RFC
  6874 section 4), and an internationalized host name is sent and connected
  to in its ASCII (`xn--…`) form. Errors about the tunnel URL show `***` in
  place of its user name and password.
- `Transport.multicast`: SETUP with `RTP/AVP;multicast` and receive from the
  group and ports the server assigns (a reply giving port 0, or a `port`
  with an empty part such as `5000-`, fails that SETUP: `start()` throws for
  video, and an audio or metadata stream is dropped with an `onDiagnostic`
  warning).
- Compressed ONVIF metadata. Streams with encoding `vnd.onvif.metadata.gzip`,
  `vnd.onvif.metadata.exi.onvif` and `vnd.onvif.metadata.exi.ext` are now set
  up. `PublicMetadataFrame.xml` holds the XML document: the payload for plain
  metadata, the decompressed payload for gzip, and nil for EXI, which is
  delivered undecoded in `data`. Decompressed gzip documents are limited to
  1 MiB, as uncompressed ones are; a larger one has `xml` nil (an
  uncompressed document over 1 MiB is dropped, with a warning).
- RTCP receiver reports. Over TCP-interleaved, UDP and SRTP sessions, the
  client sends an RTCP receiver report with an SDES CNAME for each received
  stream every 5 seconds on average (randomized between 2.5 and 7.5 s, RFC
  3550 section 6.3.1): packets lost (cumulative and per interval), extended
  highest sequence number, interarrival jitter, and the last sender report's
  timestamp and delay. Multicast sessions don't send reports, and none is
  sent after `stop()` (over TCP, none while paused). The jitter estimate
  skips the packet where a sender's RTP clock restarted.
- `PublicAudioCodec` is `Hashable`, so `desc.backchannel?.codec == .pcmu`
  compiles.
- `CameraViewer` accepts `rtsps://` URLs and these options:
  `--tls-sha256 <fingerprint>` (pin a camera's certificate),
  `--transport tcp|udp|multicast` (with an ONVIF device URL, `multicast`
  asks GetStreamUri for an `RTP-Multicast` stream over `UDP`, and for the
  unicast one when the device answers with an error or without a usable
  URI),
  `--tunnel <http/https/ws/wss URL>`,
  `--replay <ISO 8601 time, fractional seconds allowed>` with
  `--scale <speed>` (ONVIF replay; the window title shows each video
  frame's recording time, or each audio frame's without video), and `--talk` (two-way audio:
  hold Space to send the microphone to a G.711 backchannel; only the audio
  captured between the press and the release is sent, and the microphone
  stays open while connected, so macOS shows its indicator; Space starts
  talking only while the viewer window is key, and talking stops when the
  window loses focus, the app is deactivated, a menu opens, the window is
  moved or a live resize starts, since the Space release can't be seen
  then; while Space is held its key state is also checked every 100 ms,
  and talking stops when the screen locks, the displays or the system
  sleep, or the login session switches away; a failed send, or a microphone
  that can't restart, ends talking for the session and the window title
  says `talk stopped (send failed)` or `talk stopped (no microphone)`;
  Space presses aren't handled once the session ends; audio output and the
  microphone restart after an audio configuration change, such as a
  headset being plugged in). An ONVIF device service URL must have the form `http://host/…` or
  `https://host/…` (`http:/…` and `http:host/…` are rejected) and can carry
  the credentials as `http://user:password@…` when no username argument is
  given (they must be percent-encoded UTF-8). One with a raw `/`, `?` or `#`
  in the password, or shaped like one the library rejects for an RTSP URL
  (an `@` after the host with userinfo, a port or a `:` before it), is
  rejected with a hint to write them as `%2F`, `%3F`, `%23` and `%40`, and
  one with a port outside 1–65535 is rejected; both are printed with `***`
  for the credentials. Any other URL that can't be parsed is rejected
  without being printed. The window
  title shows when connecting fails or the session ends. Arguments after
  `--` are never options, for
  a password that starts with `--`; an unknown option is reported by its
  position, not its text, since it may be such a password; an option given twice, or given as its
  own value (`--transport --transport tcp`), is reported as given more than
  once, and an invalid `--transport` value as needing `tcp`, `udp` or
  `multicast`, and `--replay` rejects out-of-range dates and times
  (`2026-02-30T08:00:00Z`) instead of rolling them over.
- HE-AAC streams whose AudioSpecificConfig signals SBR or PS explicitly
  (audio object types 5 and 29) are set up; they used to be rejected as
  unsupported.
- Requests the server sends to the client (RFC 2326 section 10) are
  answered: 200 for OPTIONS and GET_PARAMETER, 501 Not Implemented for the
  rest. Previously such a request ended the session with a parse error.

### Changes

- Over UDP, an ICMP error an earlier datagram drew (port or host
  unreachable, as from a camera not yet listening on its RTCP port, or
  fragmentation needed) no longer stops receiving on that port, and the
  next send goes out instead of failing with "Connection refused".
- The session reads its connection from the moment `start()` succeeds, not
  from the first `frames()` call. Frames that arrive before the first
  `frames()` call are kept for it (the newest 256 items, up to 32 MiB;
  older ones are dropped and counted in the next frame's `loss`), so
  its first keyframe isn't lost; keepalives run while paused and when `frames()` is never
  iterated (two-way audio only, for example), and so do receiver reports,
  except over TCP while paused; and `play()` or `pause()` before `frames()`
  go through the same reader.
- PLAY, PAUSE, TEARDOWN and keepalives are sent to the aggregate control URL,
  the SDP's session-level `a=control` resolved against `Content-Base`
  (RFC 2326 appendix C.1.1), instead of the URL passed to the session. For
  the usual `a=control:*` that is the `Content-Base`.
- `start()` runs once per session; a second call throws
  `RTSPError.invalidState`. A failed `start()` closes the connection and UDP
  sockets it opened, and sends TEARDOWN when the server had already created
  a session. `stop()` during `start()` closes the connection at once and
  `start()` throws `RTSPError.invalidState`. A session released without
  `stop()` stops itself once no `frames()` sequence of it is left; a
  `frames()` sequence keeps its session alive.
- `user:password@` in the session URL is used as the credentials when none
  are passed, and is no longer sent in request lines, the Digest `uri` or
  error messages (including a URL missing its `//`). Percent-encode `/`, `?`,
  `#` and `@` in a user name or password (`%2F`, `%3F`, `%23`, `%40`): a raw
  `/`, `?` or `#` ends the host early, and a raw `@` followed by another `@`
  after the host ends it at the wrong one (`rtsp://admin:12345/abc@cam/`
  names host `admin`, port 12345; `rtsp://admin:p@ss/1@cam/` host `ss`;
  `rtsp://corp/alice:pw@cam/` host `corp`). A URL with an `@` after its host
  and either `user:password@`, a port on a host name or IPv4 address, or any
  `:` between the host and the last `@` is rejected rather than sent to the
  wrong host with the password in it, so an
  `@` in such a URL's path or query must be written `%40`; a user name with a
  raw `/`, `?` or `#` and no password can't be told from a path, so it isn't.
  Tunnel URLs are checked the same way, and must write any `@` after the
  host as `%40`. Errors that show a URL put `***` in
  place of everything from the scheme to its last `@` (a fullwidth `＠` or
  small `﹫` counts as one), and in place of the values of credential-like
  parameters: names that, percent-decoded and in any case, contain user,
  pass, pwd, auth, token or secret, or are usr, pw, psw, loginuse or
  loginpas, in the query (up to the next `&` or `#`) or starting a path
  segment (`/user=…`, up to the next `/`, `?` or `#`). These checks read the URL as Unicode scalars,
  as `URLComponents` does, so an `@`, `/`, `?`, `#` or `:` followed by a
  combining mark still counts. A
  URL containing a space or an ASCII control character, with or without
  `user:password@`, is rejected, CR, LF and other control characters are
  removed from the User-Agent, and a response header containing a control character is
  dropped, so no value can add a header to a request. The whole response is
  rejected when the control character could change how it is framed: a bare
  CR anywhere, one in a header name or on a line without a colon (other
  than a folded continuation line, which starts with a space or tab and
  continues the previous header), one in `Content-Length`, or one in the
  status line.
- A keepalive answered with a non-2xx status is reported as failed
  (`.warning`) instead of acknowledged. A 401 on a keepalive, `play` or
  `pause`, as when a camera expires its Digest nonce during a long session,
  is answered with the new challenge (except a seek a later seek
  replaced, which isn't sent again, a request answered after `stop()` sent
  TEARDOWN, and a 401 that would only repeat the refused credentials: Basic
  again, or Digest with the same nonce and no `stale=true`). Two requests
  refused for the same new nonce retry with consecutive `nc` values.
- Digest authentication uses the first challenge with a supported algorithm
  (MD5, MD5-sess, SHA-256, SHA-256-sess) when a camera sends several, and
  ignores challenges with other algorithms. Previously the last one won, and
  an unknown algorithm was answered with an MD5 hash under its name.
- `PublicVideoFrame.isKeyframe` is true for H.265 CRA and BLA pictures as
  well as IDR (all IRAP pictures, NAL unit types 16 to 23).
- An access unit that can't be reassembled (a malformed packet, or one the
  depacketizer rejects) is dropped whole and counted in the next frame's
  `loss`; before, its remaining packets could be delivered as a complete
  frame with `loss` 0. AAC frames dropped this way are counted the same way.
- An H.265 stream whose SDP declares `sprop-max-don-diff` greater than 0 or a
  `tx-mode` other than SRST makes `start()` throw: those streams carry
  decoding-order numbers this depacketizer doesn't handle. Before, the
  numbers were delivered as slice data.
- RTP sequence tracking recovers from a sender restart: a new SSRC is adopted
  after two consecutive packets from it (timestamps continue without a
  jump), and a sequence number more than 100 behind the expected one is
  taken as a restart and resynchronized as RFC 3550 appendix A.1 describes
  (at once over TCP, after two consecutive packets over UDP), reported as
  `loss`. Before, an SSRC change stalled the stream for the rest of the
  session and a sequence restart for up to 32768 packets. After a seek the
  session accepts the new playback's SSRC.
- After packet loss, metadata packets are dropped until one starts a new
  document, so a document missing its beginning is no longer delivered. A
  packet that starts a document (`<?xml` or a `MetadataStream` root element
  for XML, the gzip header, or for EXI the `$EXI` cookie or the EXI
  distinguishing bits) is kept, even right after a loss in the middle of the
  previous document, except that for EXI only the `$EXI` cookie counts
  there (one byte in four begins with the distinguishing bits). The first
  packet after `start()` is checked the same way: when it was the rest of a
  document (its first packets lost over UDP with no RTP-Info sequence
  number), that rest was delivered as a complete frame with `loss` 0. So is
  the first packet after a seek (`play(_:)`), which can be the rest of a
  document sent before it by a server without the ONVIF replay extension.
- `PublicVideoFrame.sps`/`pps`/`vps` are set when the frame's parameter sets
  differ from the last ones given to the consumer (at first, those in
  `SessionDescription.video`), compared when the frame is handed over, so
  the notice survives frames dropped from the queue. A seek keeps the
  parameter sets the stream was using, so frames before the next in-band
  set are not reported as a change back to the SDP's. The first video
  frame of a later `frames()` sequence carries them too, since its consumer
  may be a new decoder.
- `VideoStream` docs: `sps`/`pps`/`vps`/`resolution` come from the SDP only;
  the description doesn't change after `start()`.
- Over UDP the RTCP NAT hole-punch datagram is an RTCP receiver report with
  no report blocks (SRTCP for RTSPS) instead of an empty datagram, which
  mediamtx logged as `decode error: rtcp: invalid header`. If SRTCP
  protection fails, that stream gets no hole punch and a warning, rather
  than a plaintext report. A `stop()` during `start()` that arrived after
  the PLAY was sent could still be followed by the hole punch; now nothing
  is sent once `stop()` was called.
- `RTSPError` conforms to `LocalizedError`, so `localizedDescription` gives
  the error's description instead of Foundation's generic text.

- `frames()` buffers up to 256 items or 32 MiB for a slow consumer. When the
  buffer is full the session stops reading the TCP connection until the
  consumer catches up (with UDP or multicast, datagrams wait instead, at
  most 4096 of them and 8 MiB, the oldest dropped past that; only the count
  was bounded, so 64 KiB multicast datagrams could hold 256 MiB), instead
  of buffering without limit. Control requests (keepalives, `play`, `pause`,
  `stop`) still get through: while one awaits its response the session
  keeps reading and drops the oldest items beyond 4096 or 64 MiB, counting
  them in the next frame's `loss`.
- Only one `frames()` sequence is iterated at a time, as before, but when its
  consumer breaks out of the loop or is cancelled, a new `frames()` call now
  continues the stream. Previously later calls threw `RTSPError.invalidState`
  for as long as the session ran.

### Fixes

- Over UDP, RTP and RTCP datagrams larger than 9216 bytes were cut to 9216
  bytes without an error (Network framework's limit), so a server that
  relies on IP fragmentation delivered broken frames. The UDP socket pair
  now uses BSD sockets and receives datagrams up to the UDP maximum whole.
- `stop()` returns without the 5-second wait it used to spend on TEARDOWN
  when `start()` succeeded but `frames()` was never called.
- A second task iterating the same `frames()` sequence crashed the process
  (`attempt to await next() on more than one task`) when it asked for a
  frame while the first was waiting for one; it now gets
  `RTSPError.invalidState`.
- A camera that listed its ONVIF backchannel (audio marked `a=sendonly`
  beside `a=recvonly` streams) before its receive audio had the backchannel
  set up as the received audio, which carries nothing; the other audio
  stream is now preferred.
- A failed audio SETUP made `start()` throw; audio is optional, like metadata,
  so the session now continues without it and reports it via `onDiagnostic`.
- A video frame completed by a packet whose processing then failed was held
  back until the next packet that processed cleanly; it is now delivered at
  once.
- AAC: one bad fragment silenced the audio for the rest of a TCP session; an
  RTP clock rate twice the AudioSpecificConfig rate (HE-AAC) gave aggregated
  frames wrong timestamps; error paths dropped the preceding `loss`.
- G.723 packets carrying several frames are accepted (RFC 3551).
- H.264/H.265: the 16 MiB access-unit limit could be exceeded with NAL units
  that are only a header; an empty or short RTP payload could lose the next
  frame or its `loss`; an access unit delimiter (H.264 and H.265) or an H.265
  prefix SEI with the marker bit ended an access unit early; an H.265 PPS
  with any extension flag set, or an SPS with `sps_extension_4bits` set,
  failed to parse, so keyframes carrying it were dropped; H.265 timing info of zero was reported as a frame rate.
- RTSP parsing: an empty `Session` header crashed the client; a single
  `server_port` value was rejected (RFC 2326 allows one port); `RTP-Info`
  with a comma in a URL, or quoted URLs (RFC 7826), lost the initial sequence
  numbers; an absolute-path `a=control` (`/path`) was appended to the base
  path; a scheme-less `Content-Base` whose host is a name
  (`camera.local:554/path`) was taken literally; an empty `Content-Base` produced `rtsp://` control URLs; SDP or
  headers that aren't UTF-8 (GBK text, for example) made DESCRIBE fail, and
  now fall back to ISO Latin-1. A Digest challenge whose `realm`, `nonce` or
  `opaque` isn't UTF-8 is answered with the bytes the server sent, in the
  hash and in the `Authorization` header, so authentication succeeds.
- A `WWW-Authenticate` header holding several challenges (RFC 7235, for
  example `Basic realm="cam", Digest realm="cam", nonce="abc"`) was read as
  one challenge: with Basic first the password was sent as Basic although
  Digest was offered, and with Digest first the Basic fallback was
  unavailable. Each challenge is now read on its own, so Digest is used in
  either order and Basic stays available as the fallback. Scheme names must
  match exactly (`Digest`, `Basic`, any case); a bare token after an
  unquoted value (`qop=auth,auth-int`) continues that value.
- A 401 to a request during `start()` that carried credentials was answered
  by sending the same credentials again, each a failed login: Basic up to
  twice more (the retry, then the fallback meant for a rejected Digest), or
  Digest with the same nonce once more. Credentials refused on OPTIONS were
  sent again with DESCRIBE. A session that had switched to Basic after a
  refused Digest went back to Digest on the next 401 offering it, then fell
  back to the refused Basic. Now a request that carried Basic is retried
  only when the retry would use Digest, and one that carried Digest only
  when the challenge has a new nonce or says `stale=true`; Basic, when also
  offered, is tried once after a refused Digest unless it was already
  refused for that request; a session that switched to Basic keeps it; and
  credentials refused on OPTIONS end `start()` with
  `RTSPError.authenticationFailed`.
- A retry's own 401 was not read: during `start()` a Basic offer first made
  on the retry's 401 got no Basic fallback, and on a keepalive, `play` or
  `pause` the next request answered the challenge before it. A retry
  refused with `stale=true` and a new nonce (a nonce that expired while the
  retry was on its way) ended the request. Now every 401's challenges are
  taken in, a retry refused with `stale=true` and a new nonce is answered
  once more, and a Basic offer on any of a request's 401s allows the Basic
  fallback. A retry refused with a new nonce but without `stale=true` is
  not answered, since that refuses the password.
- A SETUP reply's `interleaved` value with an empty part (`-1`, `0-`) was
  read as a single channel, and one with a third part (`0-1-2`) had the
  third part ignored. Such a value now fails the SETUP with
  `RTSPError.sessionSetupFailed`.
- `RTP-Info` entries were matched to streams by searching every stream for
  each entry, so a response with many entries and media sections could cost
  seconds of CPU. Each entry is now one lookup, and entries past twice the
  stream count (at least 128) are ignored.
- A DESCRIBE response within the size limits (a 60 KB `Content-Base` and a
  2 MiB SDP of 35,000 tiny media sections) made the session keep a copy of
  the base URL per stream, over 2 GB, for its lifetime. Now at most 64
  media sections are read (malformed `m=` lines, which are skipped, are
  counted apart: up to 64 of them reported one by one, the rest in one
  warning), and a `Content-Base`,
  `Content-Location` or `a=control` longer than 8192 bytes is ignored (an
  `a=control` that long drops its media section), each with an
  `onDiagnostic` warning. Sections past the limit aren't stored while the
  SDP is parsed, nor attributes past the first 1024 of a section (one
  warning counts them). Repeated ignored session `a=control` lines give one
  warning, and server text quoted in a warning or error (a header value
  such as `Transport`, `Session`, `Content-Type` or `Content-Base`, an SDP
  `a=control`, `m=`, `rtpmap` or `fmtp` value, a reason phrase, or a status
  line that doesn't parse) is cut to 80 Unicode scalars; a message with an
  entry per media section names the first three and counts the rest. Each
  `a=control` line was also joined to the base URL as it was read, so a long
  `Content-Base` and an SDP repeating the line held the session for seconds;
  only the last one of a section is joined now.
- An `RTP-Info` `seq` or `ssrc` value that didn't parse made `start()` fail.
  Unparseable `seq`, `rtptime` and `ssrc` values are now ignored and the
  rest of the header is used.
- A camera that answers PLAY with the `RTP-Info` placeholder
  `seq=0;rtptime=0` while its RTP timestamps start elsewhere got frame
  timestamps hours off, by a different amount for each stream. The
  placeholder's `rtptime` is now ignored like its `seq`, so each stream
  starts at 0 with its first packet.
- A header block whose lines end in `\r\r\n`, or LF-terminated lines followed
  by a CRLF blank line, was never seen as complete: `start()` waited until
  the server closed the connection, and a keepalive timed out after 10
  seconds. A line feed followed by any number of CRs and another
  line feed now ends the header block.
- A server could make the client spend CPU quadratic in the size of a
  response by sending its headers in small pieces (one byte per TCP
  segment, for example). Header blocks are limited to 64 KiB and 256 lines,
  and once a message's header block is complete, it is parsed again only
  when its whole body (or interleaved frame) has arrived.
  RTCP compound packets are validated in linear time.
- A connection or UDP socket pair released without `close()` (for example by
  a `start()` that threw) stayed open; both now close when released.
- `CameraViewer`: copying a received audio payload whose length isn't a
  multiple of the frame size (an odd-length stereo payload) overran the
  buffer; ONVIF stream URIs containing `&amp;` (Hikvision, Dahua) were used
  without decoding the entity; a username with `&` or `<` produced malformed
  WS-Security XML.
- `CameraViewer` builds with the macOS 27 SDK, which makes
  `AVSampleBufferDisplayLayer` main-actor isolated. The example now enqueues
  each decoded frame on the main actor instead of from its streaming task.
  Before this, `swift build` and `swift test` failed on that SDK because the
  example target did not compile.
- `CameraViewer` ONVIF discovery skips a profile whose `GetStreamUri` fails
  (a metadata-only profile answers with a SOAP fault) instead of giving up
  on all of them, and reads profile tokens written in single quotes or with
  spaces around `=`. A profile whose answer has no usable stream URI is
  skipped with a log line naming it.
- An `rtsp://` URL with an internationalized host name
  (`rtsp://café.example/`) was connected to by its Unicode form, which the
  resolver isn't guaranteed to accept, and sent with it on the request line,
  which must be ASCII; the ASCII (`xn--…`) form is now used for both,
  whatever the host's case or width (`CAFÉ.example`, fullwidth letters) or
  percent-encoding (`caf%C3%A9.example`), and a non-ASCII path or query goes
  on the request line percent-encoded.
- A URL's `#fragment` was sent on the request line; it is now left out, as
  it isn't part of a request URI (RFC 3986 section 3.5).
- `RTP-Info` and `Public` sent as several header lines (one `RTP-Info` line
  per stream) were read from the first line only, so the other streams got
  no initial sequence number and RTP time, and `GET_PARAMETER` support
  listed on a later `Public` line was missed. Repeated lines are now read as
  one list (RFC 2616 section 4.2).
- A DVI4 packet's 4-byte header was counted as 8 audio samples; a packet
  with nothing after the header is now dropped and counted as lost.
- `start()` waited forever for a server that accepted the connection and
  never answered. Each request during `start()`, including the SETUP of an
  optional audio or metadata stream, now waits at most 15 seconds, then
  `start()` throws `RTSPError.timeout`.
- A 401 on TEARDOWN (a camera that expired its Digest nonce) is answered
  with the new challenge, as for keepalives, `play` and `pause`, so the
  camera's session ends instead of running until its timeout.
- A URL without a host (`rtsp:/192.168.1.10/stream`) connected to
  `localhost`; `start()` now throws `RTSPError.connectionFailed`.
- A percent-encoded control character in the URL host
  (`rtsp://127.0.0.1%00.invalid/`) cut the host short where the connection
  read it, so the session connected to `127.0.0.1`. A host name with any
  character other than letters, digits, `-`, `.` and `_` (IPv6 literals and
  their zone ids aside) is now rejected with `RTSPError.connectionFailed`.
- G.722 audio reported `sampleRate` 8000, its RTP clock rate (RFC 3551);
  it is now 16000, the rate the audio is sampled at.
- A sender whose RTP clock restarts (an RTP timestamp more than 5 seconds
  behind the previous one) made `timestamp` jump backwards (below zero when
  the step back was longer than the time played so far), with `loss` 0. Timestamps now continue from the previous packet, the jump is
  counted in `loss`, and a warning is reported once per stream.
- A header value folded onto a continuation line (a line starting with a
  space or tab, which RFC 2326 allows by way of RFC 2068) lost the
  continuation: a `WWW-Authenticate` challenge split after `realm="cam",`
  kept only the realm, and a continuation containing `:` was read as a
  separate header. Continuation lines are now joined onto the previous
  header's value with one space, and `Content-Length` is read the same way.
- SDP whose lines end in `\r\r\n`, or in a lone `\r`, parsed to no media
  streams, so DESCRIBE failed. LF, CRLF, CR CR LF and a lone CR now all end
  a line.
- An SDP `m=` line with too few fields (for example `m=audio 0 RTP/AVP` with
  no format list) failed the whole DESCRIBE. That media section is now
  dropped with an `onDiagnostic` warning and the other streams are used;
  with no stream left, DESCRIBE fails with "No parseable streams in SDP" as
  before. `SDPParser.parse` no longer throws for such a line.
- A relative `Content-Location` starting with `/` (for example `/live/ch0/`)
  produced the base URL `rtsp:///live/ch0/`. It is now resolved against the
  request URL's scheme and host (RFC 2326 section 12.15). A `Content-Base`
  of that form is resolved the same way.
- H.264/H.265: a keyframe carrying more than one PPS (or SPS/VPS), such as
  two PPS with different ids, set `sps`/`pps` on every keyframe as if the
  parameters had changed, and the stored PPS alternated between them. The
  stored parameter set is now kept when any NAL unit of that type in the
  access unit equals it; otherwise the first one in the access unit is used.
- H.264/H.265: when one RTP packet completed two frames that both brought
  new parameter sets (a STAP-A or AP carrying a new SPS/PPS and a slice at a
  new timestamp), the first frame was reported with the second frame's
  `sps`/`pps`/`vps`. Each frame now
  carries the parameter sets in effect when its access unit was completed.
- H.265: an SPS with `pic_width_in_luma_samples` or
  `pic_height_in_luma_samples` of 0 was accepted, reporting a width or
  height of 0. It is now rejected, as H.264 does: from `sprop-*` parameters
  the session falls back to in-band parameters, and in band the access unit
  is dropped with a diagnostic and the next frame reports `loss`.
- H.264/H.265: a picture followed by an SEI, SPS or PPS (H.265: VPS, SPS or
  PPS) was merged with the next picture into one frame, and an H.264 stream
  that put the marker bit on an SEI after every picture produced no frames
  until the 16 MiB access-unit limit dropped the data. The marker bit now
  ends any access unit that contains a slice. When the timestamp changes
  instead, NAL units that start an access unit (AUD, SEI, SPS, PPS; for H.265
  also VPS and prefix SEI) begin the next frame, so parameter sets sent
  before a keyframe count for that keyframe. NAL units that end one (H.264
  end of sequence, H.265 suffix SEI) stay with the picture they follow.
- H.264/H.265: `sprop-parameter-sets` and `sprop-vps`/`sprop-sps`/`sprop-pps`
  values without base64 `=` padding were ignored or rejected, so the
  parameter sets were only learned from the stream. They are now decoded.
- H.264: a stream with `packetization-mode=2` (interleaved) started, then
  failed on every packet. `start()` now throws
  `RTSPError.depacketizationError` saying interleaved mode is not supported.
- Each video and metadata packet copied the frame or document being
  assembled, so a frame in many packets cost CPU quadratic in its size: a
  keyframe of 32,000 FU-A fragments took about 6.6 s to reassemble, a
  hostile camera could stall the session (keepalives and `stop()` included)
  for many seconds with one frame, and a 1 MiB metadata document in small
  packets did the same. The AAC depacketizer also copied the access unit
  being assembled (up to 8 KiB) for each fragment. Packets are now added in
  place.
- An H.264 SPS, or an H.265 SPS or PPS, over 65,535 bytes was decoded and
  parsed in full before the size limit rejected it, and an H.264 SPS's
  `num_ref_frames_in_pic_order_cnt_cycle` (at most 255) wasn't checked, so
  a camera repeating a multi-megabyte SPS in every frame cost CPU time in
  proportion to its size on every frame, keepalives and `stop()` waiting
  meanwhile. The size is now checked first, and a larger cycle is rejected.
- A UDP SETUP reply giving port 0 (`server_port=0-1`) was used as the
  destination, so `start()` timed out after about 10 seconds; that SETUP now
  fails at once with `RTSPError.sessionSetupFailed`, which `start()` throws
  for video, and an audio or metadata stream is dropped with an
  `onDiagnostic` warning.
- H.264: `sprop-parameter-sets` listing more than one SPS or PPS (RFC 6184
  section 8.1 allows it) was rejected, so the stream waited for in-band
  parameter sets. The first of each is now used, as for H.265.
- G.711, G.722, G.726, L16, U8, DVI4 and G.723: a packet the depacketizer
  rejected (an empty payload, or a length that isn't a whole number of
  samples or frames) was not counted in `loss`, nor were the packets lost
  before it, so the next frame could report `loss` 0. The rejected packet
  now counts as one lost packet and is added, with the loss before it, to
  the next frame's `loss`, as for AAC.
- `NtpTimestamp.date` read NTP times after February 2036 (NTP era 1, where
  the seconds field wraps) as 1970-01-01. A seconds value with the top bit clear
  is now taken as era 1, as RFC 4330 section 3 recommends.
- Over UDP, a link-local IPv6 server address without a zone (`fe80::1` in
  the `source` of the SETUP reply) could not be sent to, so `start()` failed
  with `RTSPError.timeout` after about 10 seconds; it now takes the zone of
  the control connection's address.
- An H.265 fmtp with `sprop-max-don-diff` or another `sprop-` parameter that
  isn't a parameter set, and no parameter sets, made the session warn that
  its parameter sets could not be parsed.
- `AudioStream.extraData` was empty `Data` rather than nil for G.711, G.722,
  G.726, L16, U8, DVI4 and G.723, which have no decoder configuration.
- A URL whose scheme isn't `rtsp` or `rtsps` (`http://camera/stream`) was
  sent RTSP on port 554, port 0 was accepted, and a port too large for a
  64-bit integer was taken as no port (554); `start()` now throws
  `RTSPError.connectionFailed` for each before connecting.
- Two overlapping `stop()` calls each sent TEARDOWN; the second now waits for
  the first to finish.
- `CameraViewer`: a username given without a password sent no credentials
  (RTSP or ONVIF); it now uses an empty password.
- `CameraViewer` ONVIF discovery answers HTTP Digest and Basic
  authentication challenges with the username and password given; a device
  that requires HTTP authentication failed with `HTTP 401` unless the
  credentials were in the device service URL. Redirects to another scheme,
  host or port aren't followed, and a `user:password@` in a redirect's URL
  is dropped, so only the credentials given are used, and only with the
  device named.
- `CameraViewer` ONVIF discovery took the first `XAddr` in the
  GetCapabilities response as the media service, so a device that returns
  every capability (Analytics first) failed. It now uses the `XAddr` of the
  `Media` element.
- `CameraViewer` printed the URL it connects to, the ONVIF stream URLs and
  media service address it found, and error messages, with any
  `user:password@` in their URLs; the log now shows `***` in its place. A
  `user:password@` in the media service address the device returns isn't
  used; the credentials given are, and an address that isn't
  `http://host…` or `https://host…` is rejected. The media service address
  is used on the device service URL's scheme, host and port, and stream
  URIs on its host without their `user:password@`, so the credentials go
  only to the device named (a device behind NAT reports its own address).
  The log treats a fullwidth `＠`, a small `﹫`, and an `@` followed by a
  combining mark as `@`, and shows `***` for the values of query
  parameters whose names, percent-decoded and in any case, contain user,
  pass, pwd, auth, token or secret or are usr, pw, psw, loginuse or
  loginpas, and for the rest of a path segment that starts with such a
  `name=` (in a whole URL a name may hold a space). A value ends only at `&` or `#`
  (`/`, `?` or `#` in a path), or, in error text, at an ASCII space, tab or
  line break, as does a URL's `user:password@` (also written without `//`,
  as in `rtsp:admin:pw@host`); a URL with a space or control character is
  rejected before it reaches the library.
- `CameraViewer` took time quadratic in the length of what a device sent: a
  stream URI of `rtsp://host/s` followed by 4,000 `?` took 5 seconds to log,
  and 8,000 unclosed `<tt:Media>` tags 5 seconds to parse. Redaction, the
  XML helpers and entity decoding now take linear time, and a SOAP response
  larger than 1 MiB is refused.
- `CameraViewer` ended the session when VideoToolbox rejected the SDP's or
  an in-band SPS/PPS; the update is now skipped (logged once) and the
  previous parameter sets stay in use.
- `CameraViewer` wrote text from the device (profile tokens, HTTP error
  bodies) to the terminal unchanged, so a device could send it escape
  sequences, bidirectional formatting characters, or line breaks that print
  what look like log lines of its own. The log, and the failure reason in
  the window title, now write control characters other than newline and
  tab, U+2028, U+2029 and Unicode bidirectional formatting characters as
  `\u{1B}`, `\u{202E}` and the like, and the log writes line breaks
  (line feed, carriage return, NEL) the same way.
- `CameraViewer` queued every audio buffer it received, so audio that
  arrived in a burst (after a stall, or a replay faster than 1×) added
  lasting delay. Audio is now scheduled at most 0.5 s ahead; buffers that
  arrive while that much is queued are dropped, and this is logged once
  per session.
- `CameraViewer`'s window title for an audio-only stream read `no video ?`;
  it now reads `audio only (pcmu, 8000 Hz)` (the stream's codec and rate).

## 0.3.2

### Fixes

- Only include `algorithm=` in the RTSP Digest `Authorization` header when the
  camera's challenge specified one. Since 0.3.0 it was always sent (defaulting
  to `MD5`), which Reolink cameras (e.g. TrackMix PoE) reject with 401.
- Correct the `PublicVideoFrame.nalus` documentation (#9). Each element is one
  raw NAL unit with no AVCC length prefix, which is what the API has always
  returned; it was documented as length-prefixed. To build a VideoToolbox
  sample, write each NAL's 4-byte big-endian length before it. Runtime
  behavior is unchanged.

## 0.3.1

### Fixes

- Fall back to RTSP Basic authentication when a camera advertises both Digest
  and Basic but rejects Digest. Fixes TP-Link RTSP servers that offer Digest
  in `WWW-Authenticate` but only accept Basic for authenticated requests.

## 0.3.0

### Breaking changes

- `SessionDescription` now groups video and audio fields into `VideoStream?` and `AudioStream?` substructs. Replaces the flat `videoCodec` / `sps` / `pps` / `clockRate` / `audioCodec` / `audioSampleRate` / `audioChannels` / `audioExtraData` fields. A session is valid as long as any one of video, audio, or analytics metadata is set up — audio-only and metadata-only RTSP configurations (e.g. Axis cameras with `video=0`) now work end-to-end. Consumers branch on `desc.video != nil` (or `desc.audio != nil`) before configuring their decoders.

### New

- ONVIF analytics metadata stream support (`vnd.onvif.metadata` per the ONVIF Streaming Specification). Surfaced as `PublicCodecItem.metadata(PublicMetadataFrame)` in the `session.frames()` stream, with discoverability via `SessionDescription.metadataEncoding`. Best-effort: malformed metadata SDP or a failed application SETUP degrades to a diagnostic without aborting video/audio.
- Real UDP transport for RTP/RTCP. Selecting `Transport.udp` now streams end-to-end over an Apple Network-framework socket pair (an even RTP port and the consecutive odd RTCP port, negotiated via `client_port`), replacing the earlier non-functional scaffolding. A best-effort NAT hole-punch is sent toward the peer after `PLAY`.
- IPv6 support on both transports. The RTSP control connection and the UDP RTP/RTCP pair work over IPv6 peers, and a bracketed IPv6 literal in the URL host (e.g. `rtsp://[2001:db8::1]:554/stream`) is parsed correctly.
- Automatic RTSP session keepalive while streaming: sends `GET_PARAMETER` when the server advertises support, otherwise `OPTIONS`, at roughly half the negotiated session timeout, so long-running sessions aren't dropped by the camera. Each round-trip is reported via `onDiagnostic` at `.info` severity.

### Improvements

- Add visionOS 1.0 to supported platforms
- Make the `ntpUnixEpoch` constant private. It was accidentally exposed as a public top-level symbol but is only used internally; consumers should not have relied on it.
- Add a connect timeout to the RTSP TCP transport so an unreachable or refused camera fails fast instead of hanging. `NWConnection` parks refused/unreachable peers in `.waiting`, which previously burned the full timeout; these now surface the real cause after a short grace window.
- Surface transport-level failures that previously stalled or died silently: a terminal UDP receive error (e.g. an ICMP port-unreachable from a NAT'd camera) is now reported via `onDiagnostic` instead of letting the receive loop die quietly.
- Broaden `onDiagnostic` coverage of the drop/recover paths — interleaved data on an unnegotiated channel, FU-reassembly anomalies, audio/metadata SETUP or init failures, sprop parameter-set parse fallback, interleaved media a camera streams before its `PLAY` response completes, and SDP streams that fail to parse while others succeed. Each condition is rate-limited to fire once so a misbehaving camera can't flood the consumer.
- Live integration test suite: drives `RTSPClientSession` end-to-end against an `ffmpeg`-published stream relayed by `mediamtx`, exercising H.264/H.265/AAC over both RTSP-interleaved TCP and UDP, including IPv6. CI installs `ffmpeg` and `mediamtx`.

### Fixes

- Audio depacketizer init failures now null out the audio stream state (index, encoding name, clock rate, channels), mirroring the metadata-init failure path. Previously the indices stayed set while the depacketizer was nil; packets on that channel were silently dropped by the dispatch loop but `SessionDescription` could still claim the stream existed. Required to keep the "at least one usable stream" guard honest in audio-only sessions.
- Stop the codec, SDP, and RTSP parsers from trapping (crashing the process) on malformed or hostile input — out-of-range reads, bad lengths, and truncated buffers now error or are tolerated instead of aborting.
- Don't tear down the stream on a single bad packet; the packet is dropped and streaming continues.
- Bound depacketizer memory and reset depacketizer state on failure, so a malformed stream can't grow memory without limit.
- Validate the RTCP sender-report SSRC before anchoring the RTP/NTP timeline, so a stray report can't corrupt timestamps.
- Tolerate sloppy SDP and lenient H.265 `fmtp` from real cameras (Postel's law) instead of rejecting the session, and make AAC depacketization tolerant of real-camera deviations.
- Harden the session lifecycle and SETUP tolerance.
- Strengthen RTSP Digest authentication: escape quoted-string parameters correctly and fix the 401 retry path.
- Harden the H.265 depacketizer and parameter-set parsing against malformed input.
- Fix and harden H.264 SPS parsing.
- Harden RTP packet and context handling, and saturate loss counters to avoid overflow traps.
- Harden the RTSP parsers against malformed server input, and harden the session start path.
- Fix the static L16 payload clock rate to 44100 Hz.
- Ignore the RTP MARK bit on H.264 SEI packets (some cameras set it on a trailing SEI, splitting the access unit early).
- Tolerate a complete (un-fragmented) NAL that arrives inside an FU wrapper instead of erroring.
- Accept a scheme-less `Content-Base` header by resolving it against the request URL.
- Normalize audio frame data to a standalone `Data`.

## 0.2.0

### Breaking changes

- Remove `SessionIdPolicy` enum and the `sessionIdPolicy:` parameter from `RTSPClientSession.init`. Audio SETUP responses that return a different session ID are now always accepted (latest wins) instead of being a configurable choice.

### New

- `onDiagnostic` callback on `RTSPClientSession.init` for observing non-fatal anomalies (e.g. cameras deviating from spec). Emits `RTSPDiagnostic` values with `info` / `warning` / `error` severity. Initial events:
  - `warning` when a camera issues a different Session ID at audio SETUP than at video SETUP.
  - `warning` when an empty video RTP payload is received and skipped.
  - `warning` when an out-of-order RTP packet is received on TCP-interleaved transport (and dropped).

### Improvements

- Add iOS 16, tvOS 16, and macCatalyst 16 to supported platforms (Thanks @brientim)
- Lower macOS minimum from 14 to 13

### Fixes

- Stop tearing down the video stream when a camera emits an empty (or, for H.265, sub-2-byte) RTP payload. Such packets are now skipped — matches GStreamer / Live555 behavior.
- Stop tearing down the session when an out-of-order RTP packet arrives on TCP-interleaved transport. Packet is now dropped to match UDP behavior, matching FFmpeg / GStreamer / Live555 / ExoPlayer (none of which abort on this case). TCP byte-stream ordering does not imply RTP-sequence ordering — buggy camera packetizers can write packets out-of-order before muxing.

## 0.1.1

### Improvements

- Use `memchr` for zero-byte scanning in H.264 depacketizer for better performance

## 0.1.0

Initial release.

### Features

- **RTSP session management** — full DESCRIBE, SETUP, PLAY, TEARDOWN lifecycle via `RTSPClientSession`
- **RTSP message parsing and serialization** — request/response framing, interleaved data, header handling
- **SDP parsing** — media descriptions, codec parameter extraction, control URL resolution
- **RTP/RTCP** — packet parsing (RFC 3550), 32-bit timestamp wraparound, sequence tracking, loss detection, TCP interleaved channel mapping
- **H.264 depacketization** (RFC 6184) — Single NAL, FU-A, STAP-A, Annex B processing
- **H.265/HEVC depacketization** (RFC 7798) — Single NAL, AP, FU (SRST mode), full SPS/PPS/VPS parsing, HEVCDecoderConfigurationRecord
- **AAC depacketization** (RFC 3640) — AAC-hbr mode, aggregation, fragmentation, AudioSpecificConfig parsing
- **Simple audio** — PCMU, PCMA, L16, G.722, G.726, DVI4 pass-through
- **G.723.1 depacketization** — frame size validation (24/20/4 bytes)
- **Authentication** — Basic and Digest (MD5) via CryptoKit
- **Transport** — TCP interleaved and UDP via NWConnection
- **Output format** — AVCC (4-byte length-prefixed NAL units) ready for VideoToolbox
- **Camera quirk handling** — Reolink, Dahua, Hikvision, Longse, GW Security, VStarcam, Tenda, Foscam, and others
- **CameraViewer example app** — live video display with audio playback, ONVIF stream discovery
- **90 tests** across 15 suites ported from the upstream Rust test suite
