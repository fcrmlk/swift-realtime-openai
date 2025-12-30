@preconcurrency import AVFoundation

final class WebRTCAudioRecorder {

    private var audioFile: AVAudioFile?
    private let queue = DispatchQueue(label: "webrtc.audio.recorder")

    func start(sampleRate: Double, channels: Int) {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        )!

        let url = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(
            "webrtc_session_\(Date().timeIntervalSince1970).caf"
        )

        audioFile = try? AVAudioFile(
            forWriting: url,
            settings: format.settings
        )

        print("🎙️ WebRTC recording started:", url)
    }

    func append(_ data: UnsafeRawPointer, frames: Int, format: AVAudioFormat) {
        queue.async {
            guard let file = self.audioFile else { return }

            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
            )!

            buffer.frameLength = buffer.frameCapacity
            memcpy(buffer.int16ChannelData![0], data, frames * 2 * Int(format.channelCount))

            try? file.write(from: buffer)
        }
    }

    func stop() {
        print("✅ WebRTC recording stopped")
        audioFile = nil
    }
}
