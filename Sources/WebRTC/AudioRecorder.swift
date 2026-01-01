import Foundation
import AVFoundation
@preconcurrency import LiveKitWebRTC

/// Records audio from WebRTC tracks to temporary files
public final class AudioRecorder: NSObject {
	public enum RecordingError: Error {
		case failedToCreateAudioFile
		case failedToStartRecording
		case recordingInProgress
		case noRecordingInProgress
		case failedToStopRecording
	}
	
	public struct RecordingResult: Sendable {
		public let audioURL: URL
		
		public init(audioURL: URL) {
			self.audioURL = audioURL
		}
	}
	
	private var audioFile: AVAudioFile?
	private var userAudioEngine: AVAudioEngine?
	private var assistantAudioEngine: AVAudioEngine?
	private var audioFormat: AVAudioFormat?
	private var userTrack: LKRTCAudioTrack?
	private var assistantTrack: LKRTCAudioTrack?
	
	private let audioURL: URL
	
	private let lock = NSLock()
	
    public override init() {
		// Create temporary file URL (using CAF format for better compatibility)
		let tempDir = FileManager.default.temporaryDirectory
		let timestamp = UUID().uuidString
		audioURL = tempDir.appendingPathComponent("conversation_audio_\(timestamp).caf")
		
		super.init()
	}
	
	public func startRecording(userTrack: LKRTCAudioTrack, assistantTrack: LKRTCAudioTrack?) throws {
		lock.lock()
		defer { lock.unlock() }
		
		guard audioFile == nil else {
			throw RecordingError.recordingInProgress
		}
		
		self.userTrack = userTrack
		self.assistantTrack = assistantTrack
		
		// Use the same sample rate as the input to avoid speed issues
		// We'll determine the actual sample rate from the input node
		// For now, use 48kHz which is standard for WebRTC
		guard let recordingFormat = AVAudioFormat(
			commonFormat: .pcmFormatInt16,
			sampleRate: 48000.0,
			channels: 1,
			interleaved: false
		) else {
			throw RecordingError.failedToCreateAudioFile
		}
		
		audioFormat = recordingFormat
		
		// Use CAF format with linear PCM - no encoding required, avoids codec issues
		// CAF (Core Audio Format) is a container that supports PCM directly
		// Create a single audio file for the merged conversation
		do {
			audioFile = try AVAudioFile(forWriting: audioURL, settings: [:], commonFormat: .pcmFormatInt16, interleaved: false)
		} catch {
			// If that fails, try with explicit settings
			let fileSettings: [String: Any] = [
				AVFormatIDKey: Int(kAudioFormatLinearPCM),
				AVSampleRateKey: 48000.0,
				AVNumberOfChannelsKey: 1,
				AVLinearPCMBitDepthKey: 16,
				AVLinearPCMIsBigEndianKey: false,
				AVLinearPCMIsFloatKey: false,
				AVLinearPCMIsNonInterleaved: false
			]
			
			do {
				audioFile = try AVAudioFile(forWriting: audioURL, settings: fileSettings, commonFormat: .pcmFormatInt16, interleaved: false)
			} catch {
				throw RecordingError.failedToCreateAudioFile
			}
		}
		
		// Set up audio processing for user track (local)
		try setupUserAudioRecording()
		
		// Note: Remote audio recording is currently disabled
		// WebRTC remote audio doesn't flow through AVAudioEngine in a way we can easily capture
		// For now, we only record user audio (microphone input)
		// TODO: Implement proper remote audio capture from WebRTC tracks if needed
	}
	
	private func setupUserAudioRecording() throws {
		// NOTE: AVAudioEngine conflicts with WebRTC's audio session management
		// Starting an AVAudioEngine while WebRTC is active causes audio session conflicts
		// This makes reliable recording difficult without interfering with WebRTC playback
		
		// For now, we'll attempt to record but it may not work reliably
		// A better solution would require accessing WebRTC's audio buffers directly
		// which isn't easily available through the LiveKitWebRTC API
		
		let audioEngine = AVAudioEngine()
		
		let inputNode = audioEngine.inputNode
		var inputFormat = inputNode.inputFormat(forBus: 0)
		
		// Wait for the audio session to be ready (WebRTC should have configured it)
		// Try multiple times with increasing delays
		var attempts = 0
		let maxAttempts = 10
		while (inputFormat.sampleRate <= 0 || inputFormat.channelCount <= 0) && attempts < maxAttempts {
			Thread.sleep(forTimeInterval: 0.2) // Wait 200ms between attempts
			inputFormat = inputNode.inputFormat(forBus: 0)
			attempts += 1
		}
		
		// Validate that we have a valid input format - if not, we can't record
		guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
			// Audio session not ready or conflicting with WebRTC
			// This is expected when WebRTC is actively using the audio session
			throw RecordingError.failedToStartRecording
		}
		
		// Use the EXACT input format for the tap - this is critical to avoid format mismatch errors
		// We'll convert to our recording format in the callback
		
		// Update recording format to match input sample rate
		if let matchingFormat = AVAudioFormat(
			commonFormat: .pcmFormatInt16,
			sampleRate: inputFormat.sampleRate,
			channels: 1,
			interleaved: false
		) {
			audioFormat = matchingFormat
			// Update the audio file with the correct sample rate
			do {
				audioFile = try AVAudioFile(forWriting: audioURL, settings: [:], commonFormat: .pcmFormatInt16, interleaved: false)
			} catch {
				let fileSettings: [String: Any] = [
					AVFormatIDKey: Int(kAudioFormatLinearPCM),
					AVSampleRateKey: inputFormat.sampleRate,
					AVNumberOfChannelsKey: 1,
					AVLinearPCMBitDepthKey: 16,
					AVLinearPCMIsBigEndianKey: false,
					AVLinearPCMIsFloatKey: false,
					AVLinearPCMIsNonInterleaved: false
				]
				audioFile = try AVAudioFile(forWriting: audioURL, settings: fileSettings, commonFormat: .pcmFormatInt16, interleaved: false)
			}
		}
		
		// Create converter to recording format
		guard let recordingFormat = audioFormat,
			  let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
			throw RecordingError.failedToStartRecording
		}
		
		// CRITICAL: Install tap using the EXACT input format - format mismatch causes crash
		// Use a smaller buffer size to reduce latency
		let bufferSize: AVAudioFrameCount = 1024
		inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
			// Only process if buffer has valid data
			guard buffer.frameLength > 0, buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else {
				return
			}
			self?.processAudioBuffer(buffer, converter: converter, recordingFormat: recordingFormat, isUser: true)
		}
		
		// Prepare the engine first
		audioEngine.prepare()
		
		// Start the engine - this enables the tap
		// NOTE: Starting AVAudioEngine while WebRTC is active often fails due to audio session conflicts
		// This is a known limitation - AVAudioEngine and WebRTC both try to control the audio session
		do {
			try audioEngine.start()
			userAudioEngine = audioEngine
		} catch {
			// If starting fails, clean up and throw error
			// This is expected when WebRTC is actively using the audio session
			inputNode.removeTap(onBus: 0)
			print("Recording failed: AVAudioEngine cannot start while WebRTC is active. This is a known limitation.")
			throw RecordingError.failedToStartRecording
		}
	}
	
	private func setupAssistantAudioRecording() throws {
		// For remote audio recording, we need to capture from the WebRTC remote track
		// This is complex because WebRTC handles audio internally
		// For now, we'll skip remote audio recording as it requires more advanced setup
		// The user audio recording will still work
		
		// TODO: Implement proper remote audio capture from WebRTC tracks
		// This would require accessing the remote track's audio buffers directly
		// which may not be easily available through the LiveKitWebRTC API
		
		// For now, we'll throw an error to indicate it's not supported
		// but the caller will catch it and continue with user audio only
		throw RecordingError.failedToStartRecording
	}
	
	private func processAudioBuffer(
		_ buffer: AVAudioPCMBuffer,
		converter: AVAudioConverter,
		recordingFormat: AVAudioFormat,
		isUser: Bool
	) {
		lock.lock()
		defer { lock.unlock() }
		
		guard let audioFile = audioFile else {
			return
		}
		
		// Convert buffer to recording format
		let outputFrameCapacity = AVAudioFrameCount(
			Double(buffer.frameLength) * recordingFormat.sampleRate / buffer.format.sampleRate
		)
		
		guard let convertedBuffer = AVAudioPCMBuffer(
			pcmFormat: recordingFormat,
			frameCapacity: outputFrameCapacity
		) else {
			return
		}
		
		var error: NSError?
		let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
			outStatus.pointee = .haveData
			return buffer
		}
		
		converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
		
		if error == nil && convertedBuffer.frameLength > 0 {
			do {
				try audioFile.write(from: convertedBuffer)
			} catch {
				print("Failed to write audio buffer: \(error)")
			}
		}
	}
	
	public func stopRecording() throws -> RecordingResult {
		lock.lock()
		defer { lock.unlock() }
		
		guard audioFile != nil else {
			throw RecordingError.noRecordingInProgress
		}
		
		// Stop and remove taps
		if let engine = userAudioEngine {
			engine.inputNode.removeTap(onBus: 0)
			engine.stop()
		}
		
		if let engine = assistantAudioEngine {
			engine.mainMixerNode.removeTap(onBus: 0)
			engine.stop()
		}
		
		// Close file
		audioFile = nil
		audioFormat = nil
		userAudioEngine = nil
		assistantAudioEngine = nil
		userTrack = nil
		assistantTrack = nil
		
		return RecordingResult(audioURL: audioURL)
	}
	
	public func cancelRecording() {
		lock.lock()
		defer { lock.unlock() }
		
		if let engine = userAudioEngine {
			engine.inputNode.removeTap(onBus: 0)
			engine.stop()
		}
		
		if let engine = assistantAudioEngine {
			engine.mainMixerNode.removeTap(onBus: 0)
			engine.stop()
		}
		
		audioFile = nil
		audioFormat = nil
		userAudioEngine = nil
		assistantAudioEngine = nil
		userTrack = nil
		assistantTrack = nil
		
		// Clean up temporary file
		try? FileManager.default.removeItem(at: audioURL)
	}
}
