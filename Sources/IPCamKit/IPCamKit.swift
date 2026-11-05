// IPCamKit - Swift RTSP Client Library
// A pure-Swift RTSP client for receiving and depacketizing video and audio streams.
//
// Public API:
// - RTSPClientSession: main entry point for connecting to RTSP cameras
// - Credentials: username/password for RTSP authentication
// - Transport: .tcp (RTP interleaved over the RTSP connection), .udp (separate RTP/RTCP socket pair, IPv4/IPv6)
//   or .multicast; with rtsps:// URLs, UDP and multicast media is SRTP
// - TLSOptions / CertificateFingerprint: server-certificate checks for rtsps:// (RTSP over TLS) URLs
// - RTSPTunnel: RTSP over HTTP(S) or WebSocket
// - ONVIFFeatures / PlayOptions / ReplayInfo: ONVIF replay (seek, scale, pause) and two-way audio
// - BackchannelStream / G711: the two-way audio stream and a G.711 encoder
// - SessionDescription: codec info returned from start()
// - PublicVideoFrame: depacketized video frame with raw NAL units
// - PublicAudioFrame: depacketized audio frame
// - PublicMetadataFrame: ONVIF metadata document (xml decompressed for gzip encodings)
// - VideoCodec: codec type enum (.h264, .h265)
// - PublicAudioCodec: audio codec type enum
// - RTSPError: error types
// - VideoParameters: parsed SPS/PPS codec parameters
