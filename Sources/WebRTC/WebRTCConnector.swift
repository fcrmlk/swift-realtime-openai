import Core
import AVFAudio
import Foundation
@preconcurrency import LiveKitWebRTC
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Observable public final class WebRTCConnector: NSObject, Connector, Sendable {
	public enum WebRTCError: Error {
		case invalidEphemeralKey
		case missingAudioPermission
		case failedToCreateDataChannel
		case failedToCreatePeerConnection
		case badServerResponse(URLResponse)
		case failedToCreateSDPOffer(Swift.Error)
		case failedToSetLocalDescription(Swift.Error)
		case failedToSetRemoteDescription(Swift.Error)
	}

	public let events: AsyncThrowingStream<ServerEvent, Error>
	@MainActor public private(set) var status = RealtimeAPI.Status.disconnected

	public var isMuted: Bool {
		!audioTrack.isEnabled
	}

	package let audioTrack: LKRTCAudioTrack
	private let dataChannel: LKRTCDataChannel
	private let connection: LKRTCPeerConnection
	@ObservationIgnored nonisolated(unsafe) private var remoteAudioTrack: LKRTCAudioTrack?
	@ObservationIgnored nonisolated(unsafe) private var audioRecorder: AudioRecorder?

	private let stream: AsyncThrowingStream<ServerEvent, Error>.Continuation

	private static let factory: LKRTCPeerConnectionFactory = {
		LKRTCInitializeSSL()

		return LKRTCPeerConnectionFactory()
	}()

	private let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .convertToSnakeCase
		return encoder
	}()

	private let decoder: JSONDecoder = {
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		return decoder
	}()

	private init(connection: LKRTCPeerConnection, audioTrack: LKRTCAudioTrack, dataChannel: LKRTCDataChannel) {
		self.connection = connection
		self.audioTrack = audioTrack
		self.dataChannel = dataChannel
		(events, stream) = AsyncThrowingStream.makeStream(of: ServerEvent.self)

		super.init()

		connection.delegate = self
		dataChannel.delegate = self
	}

	deinit {
		disconnect()
	}

	package func connect(using request: URLRequest) async throws {
		guard connection.connectionState == .new else { return }

		guard AVAudioApplication.shared.recordPermission == .granted else {
			throw WebRTCError.missingAudioPermission
		}

		try await performHandshake(using: request)
	}

	public func send(event: ClientEvent) throws {
		try dataChannel.sendData(LKRTCDataBuffer(data: encoder.encode(event), isBinary: false))
	}

	public func disconnect() {
		// Stop recording if in progress
		audioRecorder?.cancelRecording()
		audioRecorder = nil
		
		connection.close()
		stream.finish()
	}

	public func toggleMute() {
		audioTrack.isEnabled.toggle()
	}
	
	/// Start recording both user and assistant audio
	/// - Returns: URLs to the temporary audio files when recording stops
	/// - Throws: RecordingError if recording cannot be started
	/// - Note: Recording may not work reliably while WebRTC is active due to audio session conflicts
	///   It's recommended to start recording after the connection is established
	public func startRecording() throws {
		guard audioRecorder == nil else {
			throw AudioRecorder.RecordingError.recordingInProgress
		}
		
		// Check if connection is established - recording works better after connection
		guard status == .connected else {
			// Still try to record, but warn that it might not work
			print("Warning: Starting recording before connection is established may fail")
		}
		
		do {
			let recorder = AudioRecorder()
			try recorder.startRecording(userTrack: audioTrack, assistantTrack: remoteAudioTrack)
			audioRecorder = recorder
		} catch {
			if let recordingError = error as? AudioRecorder.RecordingError {
				throw recordingError
			}
			throw AudioRecorder.RecordingError.failedToStartRecording
		}
	}
	
	/// Stop recording and get the file URLs
	/// - Returns: RecordingResult containing URLs to user and assistant audio files
	/// - Throws: RecordingError if no recording is in progress
	public func stopRecording() throws -> AudioRecorder.RecordingResult {
		guard let recorder = audioRecorder else {
			throw AudioRecorder.RecordingError.noRecordingInProgress
		}
		
		let result = try recorder.stopRecording()
		audioRecorder = nil
		return result
	}
	
	/// Cancel the current recording and delete temporary files
	public func cancelRecording() {
		audioRecorder?.cancelRecording()
		audioRecorder = nil
	}
	
	/// Check if recording is currently in progress
	public var isRecording: Bool {
		audioRecorder != nil
	}
}

extension WebRTCConnector {
	public static func create(connectingTo request: URLRequest) async throws -> WebRTCConnector {
		let connector = try create()
		try await connector.connect(using: request)
		return connector
	}

	package static func create() throws -> WebRTCConnector {
		guard let connection = factory.peerConnection(
			with: LKRTCConfiguration(),
			constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
			delegate: nil
		) else { throw WebRTCError.failedToCreatePeerConnection }

		let audioTrack = Self.setupLocalAudio(for: connection)

		guard let dataChannel = connection.dataChannel(forLabel: "oai-events", configuration: LKRTCDataChannelConfiguration()) else {
			throw WebRTCError.failedToCreateDataChannel
		}

		return self.init(connection: connection, audioTrack: audioTrack, dataChannel: dataChannel)
	}
}

private extension WebRTCConnector {
	static func setupLocalAudio(for connection: LKRTCPeerConnection) -> LKRTCAudioTrack {
		let audioSource = factory.audioSource(with: LKRTCMediaConstraints(
			mandatoryConstraints: [
				"googNoiseSuppression": "true", "googHighpassFilter": "true",
				"googEchoCancellation": "true", "googAutoGainControl": "true",
			],
			optionalConstraints: nil
		))

		return tap(factory.audioTrack(with: audioSource, trackId: "local_audio")) { audioTrack in
			connection.add(audioTrack, streamIds: ["local_stream"])
		}
	}

	func performHandshake(using request: URLRequest) async throws {
		let sdp = try await Result { try await connection.offer(for: LKRTCMediaConstraints(mandatoryConstraints: ["levelControl": "true"], optionalConstraints: nil)) }
			.mapError(WebRTCError.failedToCreateSDPOffer)
			.get()

		do { try await connection.setLocalDescription(sdp) }
		catch { throw WebRTCError.failedToSetLocalDescription(error) }

		let remoteSdp = try await fetchRemoteSDP(using: request, localSdp: connection.localDescription!.sdp)

		do { try await connection.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: remoteSdp)) }
		catch { throw WebRTCError.failedToSetRemoteDescription(error) }
	}

	private func fetchRemoteSDP(using request: URLRequest, localSdp: String) async throws -> String {
		var request = request
		request.httpBody = localSdp.data(using: .utf8)
		request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")

		let (data, response) = try await URLSession.shared.data(for: request)

		guard let response = response as? HTTPURLResponse, response.statusCode == 201, let remoteSdp = String(data: data, encoding: .utf8) else {
			if (response as? HTTPURLResponse)?.statusCode == 401 { throw WebRTCError.invalidEphemeralKey }
			throw WebRTCError.badServerResponse(response)
		}

		return remoteSdp
	}
}

extension WebRTCConnector: LKRTCPeerConnectionDelegate {
	public func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}
	
	public func peerConnection(_: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {
		// Capture remote audio track from the stream
		let audioTracks = stream.audioTracks
		if !audioTracks.isEmpty {
			remoteAudioTrack = audioTracks[0]
			
			// If recording is in progress, restart it with the remote track
			if let recorder = audioRecorder {
				// Stop current recording
				try? recorder.stopRecording()
				audioRecorder = nil
				
				// Restart with remote track
				do {
					let newRecorder = AudioRecorder()
					try newRecorder.startRecording(userTrack: audioTrack, assistantTrack: remoteAudioTrack)
					audioRecorder = newRecorder
				} catch {
					print("Failed to restart recording with remote track: \(error)")
				}
			}
		}
	}
	
	public func peerConnection(_: LKRTCPeerConnection, didOpen _: LKRTCDataChannel) {}
	
	public func peerConnection(_: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {
		// Clear remote track if it was removed
		let audioTracks = stream.audioTracks
		if audioTracks.contains(where: { $0.trackId == remoteAudioTrack?.trackId }) {
			remoteAudioTrack = nil
		}
	}
	
	public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCSignalingState) {}
	public func peerConnection(_: LKRTCPeerConnection, didGenerate _: LKRTCIceCandidate) {}
	public func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
	public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCIceGatheringState) {}

	public func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
		print("ICE Connection State changed to: \(newState)")
	}
}

extension WebRTCConnector: LKRTCDataChannelDelegate {
	public func dataChannel(_: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
		do { try stream.yield(decoder.decode(ServerEvent.self, from: buffer.data)) }
		catch {
			print("Failed to decode server event: \(String(data: buffer.data, encoding: .utf8) ?? "<invalid utf8>")")
			stream.finish(throwing: error)
		}
	}

	public func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
		Task { @MainActor [state = dataChannel.readyState] in
			switch state {
				case .open: status = .connected
				case .closing, .closed: status = .disconnected
				default: break
			}
		}
	}
}
