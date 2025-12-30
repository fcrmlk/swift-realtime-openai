@preconcurrency import AVFoundation

public final class WebRTCAudioRecorder: NSObject, @unchecked Sendable {

    private var audioFile: AVAudioFile?
    private let queue = DispatchQueue(label: "webrtc.audio.recorder")
    private(set) var recordedURL: URL?

    // 🔑 start WITHOUT assuming format
    public func start(with format: AVAudioFormat) {

        let url = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(
            "webrtc_session_\(Date().timeIntervalSince1970).caf"
        )

        audioFile = try? AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        recordedURL = url
        print("🎙️ Recording started:", url)
    }

    // 🔑 write buffer AS-IS
    public func append(_ buffer: AVAudioPCMBuffer) {
        queue.async {
            guard let file = self.audioFile else { return }
            do {
                try file.write(from: buffer)
            } catch {
                print("❌ Audio write failed:", error)
            }
        }
    }
    
    // MARK: - Public append helpers (Data → Recording)
    
    public func appendPCM16(
        _ data: Data,
        sampleRate: Double = 24_000,
        channels: AVAudioChannelCount = 1
    ) {
        let bytesPerFrame = Int(channels) * MemoryLayout<Int16>.size
        guard data.count >= bytesPerFrame else { return }

        let frameCount = data.count / bytesPerFrame

        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: true
        )!

        // 🔑 Start recorder on FIRST chunk
        if audioFile == nil {
            start(with: format)
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return
        }

        buffer.frameLength = buffer.frameCapacity

        // ✅ SAFE copy (AVFoundation approved)
        data.withUnsafeBytes {
            guard let src = $0.baseAddress else { return }
            memcpy(
                buffer.int16ChannelData![0],
                src,
                data.count
            )
        }

        append(buffer)
    }



    public func stop() -> URL? {
        audioFile = nil
        print("✅ Recording stopped", recordedURL)
        return recordedURL
    }
}
