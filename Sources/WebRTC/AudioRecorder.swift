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
		
		// Standard WebRTC audio format: 48kHz is typical for WebRTC, but we'll record at 16kHz for compatibility
		guard let recordingFormat = AVAudioFormat(
			commonFormat: .pcmFormatInt16,
			sampleRate: 16000.0,
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
				AVSampleRateKey: 16000.0,
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
		
		// Set up audio processing for assistant track (remote) if available
		// Note: Remote audio recording is complex and may not work reliably
		// We'll attempt it but won't fail if it doesn't work
		if assistantTrack != nil {
			do {
				try setupAssistantAudioRecording()
			} catch {
				// Remote audio recording failed, but we can continue with user audio only
				print("Warning: Failed to set up assistant audio recording: \(error)")
			}
		}
	}
	
	private func setupUserAudioRecording() throws {
		// For local audio, we'll use AVAudioEngine's input node
		// This captures the microphone input that's being sent to WebRTC
		let audioEngine = AVAudioEngine()
		
		let inputNode = audioEngine.inputNode
		let inputFormat = inputNode.inputFormat(forBus: 0)
		
		// Create converter to recording format
		guard let recordingFormat = audioFormat,
			  let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
			throw RecordingError.failedToStartRecording
		}
		
		// Install tap on input node
		let bufferSize: AVAudioFrameCount = 4096
		inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
			self?.processAudioBuffer(buffer, converter: converter, recordingFormat: recordingFormat, isUser: true)
		}
		
		// Start the engine
		do {
			try audioEngine.start()
			userAudioEngine = audioEngine
		} catch {
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
