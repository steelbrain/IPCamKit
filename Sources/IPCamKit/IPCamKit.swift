// IPCamKit - Swift RTSP Client Library
// A pure-Swift RTSP client for receiving and depacketizing video and audio streams.
//
// Public API:
// - RTSPClientSession: main entry point for connecting to RTSP cameras
// - Credentials: username/password for RTSP authentication
// - Transport: .tcp (interleaved) or .udp
// - SessionDescription: codec info returned from start()
// - PublicVideoFrame: depacketized video frame with AVCC NAL units
// - PublicAudioFrame: depacketized audio frame
// - VideoCodec: codec type enum (.h264, .h265)
// - PublicAudioCodec: audio codec type enum
// - RTSPError: error types
// - VideoParameters: parsed SPS/PPS codec parameters
