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
		public let userAudioURL: URL
		public let assistantAudioURL: URL
		
		public init(userAudioURL: URL, assistantAudioURL: URL) {
			self.userAudioURL = userAudioURL
			self.assistantAudioURL = assistantAudioURL
		}
	}
	
	private var userAudioFile: AVAudioFile?
	private var assistantAudioFile: AVAudioFile?
	private var userAudioEngine: AVAudioEngine?
	private var assistantAudioEngine: AVAudioEngine?
	private var userAudioFormat: AVAudioFormat?
	private var assistantAudioFormat: AVAudioFormat?
	private var userTrack: LKRTCAudioTrack?
	private var assistantTrack: LKRTCAudioTrack?
	
	private let userAudioURL: URL
	private let assistantAudioURL: URL
	
	private let lock = NSLock()
	
    public override init() {
		// Create temporary file URLs (using CAF format for better compatibility)
		let tempDir = FileManager.default.temporaryDirectory
		let timestamp = UUID().uuidString
		userAudioURL = tempDir.appendingPathComponent("user_audio_\(timestamp).caf")
		assistantAudioURL = tempDir.appendingPathComponent("assistant_audio_\(timestamp).caf")
		
		super.init()
	}
	
	public func startRecording(userTrack: LKRTCAudioTrack, assistantTrack: LKRTCAudioTrack?) throws {
		lock.lock()
		defer { lock.unlock() }
		
		guard userAudioFile == nil && assistantAudioFile == nil else {
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
		
		// Use CAF format with linear PCM - no encoding required, avoids codec issues
		// CAF (Core Audio Format) is a container that supports PCM directly
		// Create audio files using the commonFormat initializer with AVAudioCommonFormat
		do {
			userAudioFile = try AVAudioFile(forWriting: userAudioURL, settings: [:], commonFormat: .pcmFormatInt16, interleaved: false)
			userAudioFormat = recordingFormat
			
			if assistantTrack != nil {
				assistantAudioFile = try AVAudioFile(forWriting: assistantAudioURL, settings: [:], commonFormat: .pcmFormatInt16, interleaved: false)
				assistantAudioFormat = recordingFormat
			}
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
				userAudioFile = try AVAudioFile(forWriting: userAudioURL, settings: fileSettings, commonFormat: .pcmFormatInt16, interleaved: false)
				userAudioFormat = recordingFormat
				
				if assistantTrack != nil {
					assistantAudioFile = try AVAudioFile(forWriting: assistantAudioURL, settings: fileSettings, commonFormat: .pcmFormatInt16, interleaved: false)
					assistantAudioFormat = recordingFormat
				}
			} catch {
				throw RecordingError.failedToCreateAudioFile
			}
		}
		
		// Set up audio processing for user track (local)
		try setupUserAudioRecording()
		
		// Set up audio processing for assistant track (remote) if available
		if assistantTrack != nil {
			try setupAssistantAudioRecording()
		}
	}
	
	private func setupUserAudioRecording() throws {
		// For local audio, we'll use AVAudioEngine's input node
		// This captures the microphone input that's being sent to WebRTC
		let audioEngine = AVAudioEngine()
		
		let inputNode = audioEngine.inputNode
		let inputFormat = inputNode.inputFormat(forBus: 0)
		
		// Create converter to recording format
		guard let recordingFormat = userAudioFormat,
			  let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
			throw RecordingError.failedToStartRecording
		}
		
		// Install tap on input node
		let bufferSize: AVAudioFrameCount = 4096
		inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
			self?.processUserAudioBuffer(buffer, converter: converter, recordingFormat: recordingFormat)
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
		// For remote audio, we need to capture from the remote track
		// Since WebRTC remote audio goes through the system output, we'll use a different approach
		// We'll create an audio engine and connect it to process the remote audio
		let audioEngine = AVAudioEngine()
		
		// Get a valid format for the output node
		// Use the hardware output format or default to a standard format
		let hardwareFormat = audioEngine.outputNode.outputFormat(forBus: 0)
		
		// Create a valid format for tapping - use hardware format if valid, otherwise use standard format
		let tapFormat: AVAudioFormat
		if hardwareFormat.sampleRate > 0 && hardwareFormat.channelCount > 0 {
			tapFormat = hardwareFormat
		} else {
			// Default to standard format: 48kHz, stereo, Float32
			guard let defaultFormat = AVAudioFormat(
				commonFormat: .pcmFormatFloat32,
				sampleRate: 48000.0,
				channels: 2,
				interleaved: false
			) else {
				throw RecordingError.failedToStartRecording
			}
			tapFormat = defaultFormat
		}
		
		// Create converter to recording format
		guard let recordingFormat = assistantAudioFormat,
			  let converter = AVAudioConverter(from: tapFormat, to: recordingFormat) else {
			throw RecordingError.failedToStartRecording
		}
		
		// We need to connect something to the output node to make it active
		// Create a silent player node to keep the engine running
		let playerNode = AVAudioPlayerNode()
		audioEngine.attach(playerNode)
		
		// Connect player to output (even though it won't play anything, it keeps the engine active)
		audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: tapFormat)
		audioEngine.connect(audioEngine.mainMixerNode, to: audioEngine.outputNode, format: tapFormat)
		
		// Install tap on main mixer node (this is where audio would flow)
		let bufferSize: AVAudioFrameCount = 4096
		audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { [weak self] buffer, _ in
			self?.processAssistantAudioBuffer(buffer, converter: converter, recordingFormat: recordingFormat)
		}
		
		// Start the engine
		do {
			try audioEngine.start()
			assistantAudioEngine = audioEngine
		} catch {
			throw RecordingError.failedToStartRecording
		}
	}
	
	private func processUserAudioBuffer(
		_ buffer: AVAudioPCMBuffer,
		converter: AVAudioConverter,
		recordingFormat: AVAudioFormat
	) {
		processAudioBuffer(buffer, converter: converter, recordingFormat: recordingFormat, isUser: true)
	}
	
	private func processAssistantAudioBuffer(
		_ buffer: AVAudioPCMBuffer,
		converter: AVAudioConverter,
		recordingFormat: AVAudioFormat
	) {
		processAudioBuffer(buffer, converter: converter, recordingFormat: recordingFormat, isUser: false)
	}
	
	private func processAudioBuffer(
		_ buffer: AVAudioPCMBuffer,
		converter: AVAudioConverter,
		recordingFormat: AVAudioFormat,
		isUser: Bool
	) {
		lock.lock()
		defer { lock.unlock() }
		
		guard let audioFile = isUser ? userAudioFile : assistantAudioFile else {
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
		
		guard userAudioFile != nil || assistantAudioFile != nil else {
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
		
		// Close files
		userAudioFile = nil
		assistantAudioFile = nil
		userAudioFormat = nil
		assistantAudioFormat = nil
		userAudioEngine = nil
		assistantAudioEngine = nil
		userTrack = nil
		assistantTrack = nil
		
		return RecordingResult(
			userAudioURL: userAudioURL,
			assistantAudioURL: assistantAudioURL
		)
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
		
		userAudioFile = nil
		assistantAudioFile = nil
		userAudioFormat = nil
		assistantAudioFormat = nil
		userAudioEngine = nil
		assistantAudioEngine = nil
		userTrack = nil
		assistantTrack = nil
		
		// Clean up temporary files
		try? FileManager.default.removeItem(at: userAudioURL)
		try? FileManager.default.removeItem(at: assistantAudioURL)
	}
}
