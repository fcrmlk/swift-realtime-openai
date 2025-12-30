import Core
import AVFAudio
import Foundation
@preconcurrency import LiveKitWebRTC
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Global Recorder (library-level)
public let webRTCAudioRecorder = WebRTCAudioRecorder()

// MARK: - WebRTCConnector

@Observable
public final class WebRTCConnector: NSObject, Connector, Sendable {

    // MARK: Errors
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

    // MARK: Public state
    public let events: AsyncThrowingStream<ServerEvent, Error>
    @MainActor public private(set) var status = RealtimeAPI.Status.disconnected

    public var isMuted: Bool { !audioTrack.isEnabled }

    // MARK: Internal
    package let audioTrack: LKRTCAudioTrack
    private let dataChannel: LKRTCDataChannel
    private let connection: LKRTCPeerConnection
    private let stream: AsyncThrowingStream<ServerEvent, Error>.Continuation

    // MARK: Factory
    private static let factory: LKRTCPeerConnectionFactory = {
        LKRTCInitializeSSL()
        return LKRTCPeerConnectionFactory()
    }()

    // MARK: Coders
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: Init
    private init(
        connection: LKRTCPeerConnection,
        audioTrack: LKRTCAudioTrack,
        dataChannel: LKRTCDataChannel
    ) {
        self.connection = connection
        self.audioTrack = audioTrack
        self.dataChannel = dataChannel
        (events, stream) = AsyncThrowingStream.makeStream(of: ServerEvent.self)
        super.init()
        connection.delegate = self
        dataChannel.delegate = self
    }

    deinit { disconnect() }

    // MARK: Connect / Disconnect

    package func connect(using request: URLRequest) async throws {
        guard connection.connectionState == .new else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw WebRTCError.missingAudioPermission
        }
        try await performHandshake(using: request)
        Self.configureAudioSession()
    }

    public func disconnect() {
        connection.close()

        if let url = webRTCAudioRecorder.stop() {
            print("🎧 Recording saved at:", url)
        }

        stream.finish()
    }

    // MARK: Send events

    public func send(event: ClientEvent) throws {
        try dataChannel.sendData(
            LKRTCDataBuffer(
                data: encoder.encode(event),
                isBinary: false
            )
        )
    }

    // MARK: Input audio (USER → SERVER)
    /// Call this when you send mic audio to Realtime API
    public func sendInputAudio(_ data: Data) throws {
        // 🔴 RECORD USER AUDIO
        webRTCAudioRecorder.appendPCM16(data)

        try send(event: .appendInputAudioBuffer(encoding: data))
    }

    public func toggleMute() {
        audioTrack.isEnabled.toggle()
    }
}

// MARK: - Creation

extension WebRTCConnector {

    public static func create(connectingTo request: URLRequest) async throws -> WebRTCConnector {
        let connector = try create()
        try await connector.connect(using: request)
        return connector
    }

    package static func create() throws -> WebRTCConnector {
        guard let connection = factory.peerConnection(
            with: LKRTCConfiguration(),
            constraints: LKRTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: nil
            ),
            delegate: nil
        ) else {
            throw WebRTCError.failedToCreatePeerConnection
        }

        let audioTrack = setupLocalAudio(for: connection)

        guard let dataChannel = connection.dataChannel(
            forLabel: "oai-events",
            configuration: LKRTCDataChannelConfiguration()
        ) else {
            throw WebRTCError.failedToCreateDataChannel
        }

        return self.init(
            connection: connection,
            audioTrack: audioTrack,
            dataChannel: dataChannel
        )
    }
}

// MARK: - Audio setup (NO recording here)

private extension WebRTCConnector {

    static func setupLocalAudio(for connection: LKRTCPeerConnection) -> LKRTCAudioTrack {

        let audioSource = factory.audioSource(
            with: LKRTCMediaConstraints(
                mandatoryConstraints: [
                    "googNoiseSuppression": "true",
                    "googHighpassFilter": "true",
                    "googEchoCancellation": "true",
                    "googAutoGainControl": "true"
                ],
                optionalConstraints: nil
            )
        )

        let track = factory.audioTrack(
            with: audioSource,
            trackId: "local_audio"
        )

        connection.add(track, streamIds: ["local_stream"])
        return track
    }

    static func configureAudioSession() {
        #if !os(macOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
            try session.setMode(.videoChat)
            try session.setActive(true)
        } catch {
            print("AVAudioSession error:", error)
        }
        #endif
    }

    func performHandshake(using request: URLRequest) async throws {
        let offer = try await Result {
            try await connection.offer(
                for: LKRTCMediaConstraints(
                    mandatoryConstraints: ["levelControl": "true"],
                    optionalConstraints: nil
                )
            )
        }
        .mapError(WebRTCError.failedToCreateSDPOffer)
        .get()

        do { try await connection.setLocalDescription(offer) }
        catch { throw WebRTCError.failedToSetLocalDescription(error) }

        let remoteSDP = try await fetchRemoteSDP(
            using: request,
            localSdp: connection.localDescription!.sdp
        )

        do {
            try await connection.setRemoteDescription(
                LKRTCSessionDescription(type: .answer, sdp: remoteSDP)
            )
        } catch {
            throw WebRTCError.failedToSetRemoteDescription(error)
        }
    }

    func fetchRemoteSDP(using request: URLRequest, localSdp: String) async throws -> String {
        var req = request
        req.httpBody = localSdp.data(using: .utf8)
        req.setValue("application/sdp", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: req)

        guard
            let http = response as? HTTPURLResponse,
            http.statusCode == 201,
            let sdp = String(data: data, encoding: .utf8)
        else {
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                throw WebRTCError.invalidEphemeralKey
            }
            throw WebRTCError.badServerResponse(response)
        }

        return sdp
    }
}

// MARK: - Delegates

extension WebRTCConnector: LKRTCPeerConnectionDelegate {
    public func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}
    public func peerConnection(_: LKRTCPeerConnection, didAdd _: LKRTCMediaStream) {}
    public func peerConnection(_: LKRTCPeerConnection, didOpen _: LKRTCDataChannel) {}
    public func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}
    public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCSignalingState) {}
    public func peerConnection(_: LKRTCPeerConnection, didGenerate _: LKRTCIceCandidate) {}
    public func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
    public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCIceGatheringState) {}

    public func peerConnection(
        _: LKRTCPeerConnection,
        didChange newState: LKRTCIceConnectionState
    ) {
        print("ICE state:", newState)
    }
}

extension WebRTCConnector: LKRTCDataChannelDelegate {

    public func dataChannel(
        _: LKRTCDataChannel,
        didReceiveMessageWith buffer: LKRTCDataBuffer
    ) {
        do {
            try stream.yield(
                decoder.decode(ServerEvent.self, from: buffer.data)
            )
        } catch {
            print("Decode error:", error)
            stream.finish(throwing: error)
        }
    }

    public func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        Task { @MainActor in
            switch dataChannel.readyState {
            case .open: status = .connected
            case .closing, .closed: status = .disconnected
            default: break
            }
        }
    }
}
