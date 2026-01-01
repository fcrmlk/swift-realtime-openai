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
		// Try to use AVAudioEngine but in a way that doesn't interfere with WebRTC
		// The key is to NOT start the engine, but instead just prepare it and use the input node
		// However, taps require the engine to be running, so this won't work either.
		//
		// Alternative: Try to capture from the WebRTC audio source directly
		// But LiveKitWebRTC doesn't expose audio buffers from the source
		//
		// For now, we'll create a minimal AVAudioEngine setup that tries to work with WebRTC
		// but may still fail due to audio session conflicts
		
		let audioEngine = AVAudioEngine()
		let inputNode = audioEngine.inputNode
		
		// Get the input format - wait for it to be valid
		var inputFormat = inputNode.inputFormat(forBus: 0)
		var attempts = 0
		while (inputFormat.sampleRate <= 0 || inputFormat.channelCount <= 0) && attempts < 20 {
			Thread.sleep(forTimeInterval: 0.1)
			inputFormat = inputNode.inputFormat(forBus: 0)
			attempts += 1
		}
		
		guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
			// Can't get valid format - WebRTC is controlling the audio session
			print("Warning: Cannot get valid audio format while WebRTC is active. Recording disabled.")
			return // Don't throw - just don't record
		}
		
		// Update recording format to match
		if let matchingFormat = AVAudioFormat(
			commonFormat: .pcmFormatInt16,
			sampleRate: inputFormat.sampleRate,
			channels: 1,
			interleaved: false
		) {
			audioFormat = matchingFormat
			// Recreate file with correct sample rate
			let fileSettings: [String: Any] = [
				AVFormatIDKey: Int(kAudioFormatLinearPCM),
				AVSampleRateKey: inputFormat.sampleRate,
				AVNumberOfChannelsKey: 1,
				AVLinearPCMBitDepthKey: 16,
				AVLinearPCMIsBigEndianKey: false,
				AVLinearPCMIsFloatKey: false,
				AVLinearPCMIsNonInterleaved: false
			]
			do {
				audioFile = try AVAudioFile(forWriting: audioURL, settings: fileSettings, commonFormat: .pcmFormatInt16, interleaved: false)
			} catch {
				print("Failed to recreate audio file with correct format: \(error)")
				return
			}
		}
		
		guard let recordingFormat = audioFormat,
			  let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
			return
		}
		
		// Install tap
		let bufferSize: AVAudioFrameCount = 1024
		inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
			guard buffer.frameLength > 0 else { return }
			self?.processAudioBuffer(buffer, converter: converter, recordingFormat: recordingFormat, isUser: true)
		}
		
		// Try to start - if it fails, we'll just not record but won't crash
		audioEngine.prepare()
		do {
			try audioEngine.start()
			userAudioEngine = audioEngine
		} catch {
			// Failed to start - remove tap and continue without recording
			inputNode.removeTap(onBus: 0)
			print("Warning: Could not start audio engine for recording: \(error)")
			print("Recording will be disabled to avoid interfering with WebRTC.")
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
