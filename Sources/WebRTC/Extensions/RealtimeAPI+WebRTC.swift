import Core
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension RealtimeAPI {
	/// Connect to the OpenAI WebRTC Realtime API with the given request.
	static func webRTC(connectingTo request: URLRequest) async throws -> RealtimeAPI {
		try RealtimeAPI(connector: await WebRTCConnector.create(connectingTo: request))
	}

	/// Connect to the OpenAI WebRTC Realtime API with the given authentication token and model.
	static func webRTC(ephemeralKey: String, model: Model = .gptRealtime) async throws -> RealtimeAPI {
		return try await webRTC(connectingTo: .webRTCConnectionRequest(ephemeralKey: ephemeralKey, model: model))
	}
	
	/// Start recording both user and assistant audio from WebRTC streams
	/// - Throws: RecordingError if recording cannot be started or connector is not WebRTC
	func startRecording() throws {
		guard let webRTCConnector = getConnector(as: WebRTCConnector.self) else {
			throw RecordingError.notWebRTCConnector
		}
		try webRTCConnector.startRecording()
	}
	
	/// Stop recording and get the file URLs
	/// - Returns: RecordingResult containing URLs to user and assistant audio files
	/// - Throws: RecordingError if no recording is in progress or connector is not WebRTC
	func stopRecording() throws -> AudioRecorder.RecordingResult {
		guard let webRTCConnector = getConnector(as: WebRTCConnector.self) else {
			throw RecordingError.notWebRTCConnector
		}
		return try webRTCConnector.stopRecording()
	}
	
	/// Cancel the current recording and delete temporary files
	func cancelRecording() {
		guard let webRTCConnector = getConnector(as: WebRTCConnector.self) else {
			return
		}
		webRTCConnector.cancelRecording()
	}
	
	/// Check if recording is currently in progress
	var isRecording: Bool {
		guard let webRTCConnector = getConnector(as: WebRTCConnector.self) else {
			return false
		}
		return webRTCConnector.isRecording
	}
	
	/// Recording errors
	enum RecordingError: Swift.Error {
		case notWebRTCConnector
	}
}
